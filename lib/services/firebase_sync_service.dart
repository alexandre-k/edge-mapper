import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../attest_gate_provider.dart';
import '../models/hike_trail.dart';
import '../models/osm_record.dart';
import 'app_env_config.dart';
import 'e2ee_envelope_crypto.dart';
import 'e2ee_platform_bridge.dart';
import 'firebase_bootstrap.dart';
import 'photo_helper.dart';
import 'user_preferences_service.dart';

class FirebaseAuthRequiredException implements Exception {
  final String message;

  const FirebaseAuthRequiredException([
    this.message =
        'Sign in and unlock your E2EE Vault (Passkey or Recovery Key) to sync.',
  ]);

  @override
  String toString() => message;
}

class PrfUnsupportedException implements Exception {
  final String message;

  const PrfUnsupportedException([
    this.message =
        'This authenticator does not support WebAuthn PRF. Use your Argon2id Recovery Key instead.',
  ]);

  @override
  String toString() => message;
}

class KeyringSetupResult {
  final UserKeyring keyring;
  final String recoveryKey;
  final bool prfEnrolled;
  final bool androidHardwareCached;
  final String? prfFallbackMessage;

  const KeyringSetupResult({
    required this.keyring,
    required this.recoveryKey,
    required this.prfEnrolled,
    required this.androidHardwareCached,
    this.prfFallbackMessage,
  });
}

class SharedItemSummary {
  final String itemId;
  final String itemType;
  final String ownerUid;
  final List<String> recipientUids;

  const SharedItemSummary({
    required this.itemId,
    required this.itemType,
    required this.ownerUid,
    required this.recipientUids,
  });
}

class DecryptedSharedLink {
  final String shareId;
  final String itemType;
  final RemoteOsmRecord? record;
  final HikeTrail? trail;

  const DecryptedSharedLink({
    required this.shareId,
    required this.itemType,
    this.record,
    this.trail,
  });
}

class FirebaseSyncResult {
  final int recordsSynced;
  final int trailsSynced;
  final int recordsPulled;
  final int trailsPulled;
  final int recordsDeleted;
  final int trailsDeleted;
  final int photosSynced;
  final List<String> errors;

  const FirebaseSyncResult({
    required this.recordsSynced,
    required this.trailsSynced,
    this.recordsPulled = 0,
    this.trailsPulled = 0,
    this.recordsDeleted = 0,
    this.trailsDeleted = 0,
    this.photosSynced = 0,
    this.errors = const [],
  });

  int get totalPushed => recordsSynced + trailsSynced;
  int get totalPulled => recordsPulled + trailsPulled;
  int get totalDeleted => recordsDeleted + trailsDeleted;
  int get totalSynced => totalPushed + totalPulled + totalDeleted;
  bool get hasErrors => errors.isNotEmpty;
}

class CloudWipeResult {
  final int recordsDeleted;
  final int trailsDeleted;
  final List<String> errors;

  const CloudWipeResult({
    required this.recordsDeleted,
    required this.trailsDeleted,
    this.errors = const [],
  });

  int get totalDeleted => recordsDeleted + trailsDeleted;
  bool get hasErrors => errors.isNotEmpty;
}

class RemoteOsmRecord {
  final OsmRecord record;
  final String? photoDataUri;
  final String? ownerUid;
  final List<String> recipientUids;

  const RemoteOsmRecord({
    required this.record,
    this.photoDataUri,
    this.ownerUid,
    this.recipientUids = const [],
  });
}

/// Zero-Knowledge End-to-End Encrypted (E2EE) Cloud Storage & Selective Sharing
/// layer for Firebase Firestore:
///
/// - **Payload Encryption (`Item_DEK`)**: `XChaCha20-Poly1305` (256-bit random
///   key, 192-bit random nonce) with document-path + version AAD
///   (`items/{itemId}|v1`).
/// - **User Identity & Asymmetric Key Wrapping**: `X25519` keypair
///   (`User_Pub`, `User_Priv`). Every `Item_DEK` is wrapped with an ephemeral
///   `X25519` sealed-box / HPKE-style construction to one or more recipient
///   `X25519` public keys (personal items = 1-recipient list `[User_Pub]`).
/// - **Zero-Config Cross-Device Root Unlock**: WebAuthn `prf` extension
///   (`app-vault-root-v1`) → `HKDF-SHA256` (`PRF_Root_Key`) wrapping `User_Priv`
///   in `users/{uid}/security/keyring` (`wrapped_priv_prf`).
/// - **Fallback Recovery Slot**: `Argon2id` (64 MB memory, 3 iterations) from
///   a portable high-entropy Recovery Key wrapping `User_Priv` in
///   `users/{uid}/security/keyring` (`wrapped_priv_recovery`).
/// - **Local Hardware Caching (Android)**: Wraps `User_Priv` locally with an
///   Android Keystore `AES-256-GCM` key (`setRandomizedEncryptionRequired(true)`)
///   so daily app unlocks require zero Passkey dialogs.
/// - **Optional Link Sharing**: `shares/{shareId}` with `Item_DEK` strictly in
///   the URL `#k=` fragment.
class FirebaseSyncService extends ChangeNotifier {
  final UserPreferencesService prefs;
  final http.Client _client;
  final E2eePlatformBridge _platformBridge;
  final String? Function()? _uidOverride;
  final String? Function()? _projectIdOverride;
  final Future<String?> Function({bool forceRefresh})? _idTokenOverride;
  final Future<void> Function(
    DerivedVaultAuthCredentials creds, {
    required bool createNew,
  })? _vaultAuthOverride;
  final Future<void> Function()? _authSignOutOverride;

  StreamSubscription<User?>? _authSub;

  /// Volatile RAM-only unlocked user X25519 keypair + 16-byte vault auth seed
  /// (both are zeroized immediately on lock, sign-out, or dispose).
  X25519KeyPair? _unlockedKeyPair;
  Uint8List? _activeAuthSeed16;
  UserKeyring? _remoteKeyring;
  bool _remoteKeyringChecked = false;
  bool _unlockedViaHardwareCache = false;
  bool _hasAndroidHardwareCache = false;
  bool _explicitlyLocked = false;
  // Lightweight REST Auth session for Android (avoids native firebase-auth reCAPTCHA SDK)
  String? _restUid;
  String? _restEmail;
  String? _restIdToken;
  String? _restRefreshToken;
  DateTime? _restTokenExpiry;
  static final RegExp _safeSegmentPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  E2eePlatformCapabilities _capabilities = const E2eePlatformCapabilities(
    supportsWebAuthnPrf: false,
    supportsAndroidHardwareCache: false,
  );

  FirebaseSyncService({
    required this.prefs,
    http.Client? client,
    E2eePlatformBridge? platformBridge,
    String? Function()? uidOverride,
    String? Function()? projectIdOverride,
    Future<String?> Function({bool forceRefresh})? idTokenOverride,
    Future<void> Function(
      DerivedVaultAuthCredentials creds, {
      required bool createNew,
    })? vaultAuthOverride,
    Future<void> Function()? authSignOutOverride,
  })  : _client = client ?? http.Client(),
        _platformBridge = platformBridge ?? createE2eePlatformBridge(),
        _uidOverride = uidOverride,
        _projectIdOverride = projectIdOverride,
        _idTokenOverride = idTokenOverride,
        _vaultAuthOverride = vaultAuthOverride,
        _authSignOutOverride = authSignOutOverride {
    _attachAuthListener();
    prefs.addListener(_handlePrefsChange);
  }

  void _handlePrefsChange() {
    notifyListeners();
  }

  void _attachAuthListener() {
    if (_uidOverride != null || !kIsWeb) return;
    if (!FirebaseBootstrap.isConfigured || Firebase.apps.isEmpty) return;
    try {
      _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
        if (user == null || user.isAnonymous) {
          _clearVolatileKeyPair();
          _remoteKeyring = null;
          _remoteKeyringChecked = false;
        } else {
          // ignore: unawaited_futures
          refreshSessionAndTryAutoUnlock();
        }
        notifyListeners();
      });
    } catch (e) {
      debugPrint('[EdgeMapper] FirebaseAuth listener skipped: $e');
    }
  }

  User? get _currentFirebaseUser {
    if (!FirebaseBootstrap.isConfigured || Firebase.apps.isEmpty) return null;
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null || user.isAnonymous) return null;
      return user;
    } catch (_) {
      return null;
    }
  }

  /// Authenticated non-anonymous Firebase UID owning this user's E2EE vault.
  String? get currentUid {
    if (_uidOverride != null) {
      final uid = _uidOverride.call()?.trim();
      return (uid != null && uid.isNotEmpty) ? uid : null;
    }
    if (!kIsWeb) return _restUid;
    return _currentFirebaseUser?.uid;
  }

  String? get activeProjectId {
    final override = _projectIdOverride?.call()?.trim();
    if (override != null && override.isNotEmpty) return override;
    if (FirebaseBootstrap.isConfigured && Firebase.apps.isNotEmpty) {
      return Firebase.app().options.projectId;
    }
    return null;
  }

  bool get isConfigured =>
      activeProjectId != null && activeProjectId!.trim().isNotEmpty;

  bool get isAuthAvailable =>
      _vaultAuthOverride != null ||
      (FirebaseBootstrap.isConfigured && Firebase.apps.isNotEmpty);

  bool get isSignedIn => currentUid != null && currentUid!.isNotEmpty;

  /// True when `User_Priv` is unwrapped and held in volatile RAM.
  bool get isVaultUnlocked => _unlockedKeyPair != null;

  /// True when Firebase is configured, user is signed in, AND `User_Priv` is
  /// unlocked in volatile memory.
  bool get canSyncNow => isConfigured && isSignedIn && isVaultUnlocked;

  E2eePlatformCapabilities get capabilities => _capabilities;
  bool get supportsWebAuthnPrf => _capabilities.supportsWebAuthnPrf;
  bool get supportsAndroidHardwareCache =>
      _capabilities.supportsAndroidHardwareCache;
  bool get hasAndroidHardwareCache => _hasAndroidHardwareCache;
  bool get unlockedViaHardwareCache => _unlockedViaHardwareCache;

  /// True when this device already owns a vault key (either currently unlocked
  /// in RAM, sealed in Android Hardware Keystore, or bound to a local Passkey
  /// credential ID). Enforces at most one generated key per device so an
  /// existing user always reuses their vault and encrypted data.
  bool get hasDeviceKey =>
      isVaultUnlocked ||
      _hasAndroidHardwareCache ||
      prefs.e2eePasskeyCredentialId.isNotEmpty;

  UserKeyring? get remoteKeyring => _remoteKeyring;
  bool get hasCheckedRemoteKeyring => _remoteKeyringChecked;
  bool get hasRemoteKeyring => _remoteKeyring != null;
  bool get hasPrfSlot => _remoteKeyring?.hasPrfSlot == true;
  bool get hasRecoverySlot => _remoteKeyring?.hasRecoverySlot == true;

  /// Plaintext Base64 `X25519` public key (`User_Pub`) for display.
  String? get publicKeyB64 =>
      _unlockedKeyPair?.publicKeyB64 ?? _remoteKeyring?.x25519PublicKeyB64;

  /// Whether the compact cross-device X25519 Sync Key (`emx1-...`) can be
  /// exported as a QR code or copied right now.
  bool get canExportX25519SyncKey =>
      _unlockedKeyPair != null &&
      _activeAuthSeed16 != null &&
      _activeAuthSeed16!.length == 16;

  /// Builds the compact `emx1-...` X25519 Sync Key (`authSeed16 || User_Priv` +
  /// 24-bit checksum) strictly on demand for QR display or copy to another
  /// device owned by the same user. Returns `null` if locked.
  String? exportX25519SyncKey() {
    final kp = _unlockedKeyPair;
    final seed = _activeAuthSeed16;
    if (kp == null || seed == null || seed.length != 16) return null;
    return E2eeEnvelopeCrypto.encodeX25519SyncKey(
      authSeed16: seed,
      userPrivateKey: kp.privateKey,
    );
  }

  /// Non-secret public key fingerprint (`XXXX-XXXX-XXXX`) for UI display.
  String? get activeKeyFingerprint {
    final kp = _unlockedKeyPair;
    if (kp != null) return kp.publicFingerprint;
    final pubB64 = _remoteKeyring?.x25519PublicKeyB64;
    if (pubB64 != null && pubB64.isNotEmpty) {
      try {
        final pub = Uint8List.fromList(base64Decode(pubB64));
        return X25519KeyPair(publicKey: pub, privateKey: Uint8List(32))
            .publicFingerprint;
      } catch (_) {}
    }
    return null;
  }

  void _clearVolatileKeyPair() {
    _unlockedKeyPair?.zeroizePrivate();
    _unlockedKeyPair = null;
    zeroize(_activeAuthSeed16);
    _activeAuthSeed16 = null;
    _unlockedViaHardwareCache = false;
  }

  /// Injects an unlocked keypair strictly for unit testing.
  @visibleForTesting
  void setUnlockedKeyPairForTest(
    X25519KeyPair keyPair, {
    Uint8List? authSeed16,
  }) {
    _clearVolatileKeyPair();
    _unlockedKeyPair = X25519KeyPair(
      publicKey: Uint8List.fromList(keyPair.publicKey),
      privateKey: Uint8List.fromList(keyPair.privateKey),
    );
    _activeAuthSeed16 = authSeed16 != null
        ? Uint8List.fromList(authSeed16)
        : secureRandomBytes(16);
    notifyListeners();
  }

  /// Initializes platform capabilities and, on Android, checks local Android
  /// Keystore cache (silently unwrapping `User_Priv` on daily launches when
  /// signed in so zero Passkey or Recovery Key dialog is required).
  Future<void> refreshSessionAndTryAutoUnlock() async {
    _capabilities = await _platformBridge.getCapabilities();
    final uid = currentUid;

    if (_capabilities.supportsAndroidHardwareCache) {
      // Check device-wide hardware cache (uid: null) so this device always
      // recognizes an existing vault key even if Firebase Auth is signed out.
      _hasAndroidHardwareCache = await _platformBridge.hasCachedUserPriv();
    } else {
      _hasAndroidHardwareCache = false;
    }

    if (uid == null || uid.isEmpty) {
      _clearVolatileKeyPair();
      _remoteKeyring = null;
      _remoteKeyringChecked = false;
      notifyListeners();
      return;
    }

    if (_capabilities.supportsAndroidHardwareCache &&
        !isVaultUnlocked &&
        !_explicitlyLocked &&
        _hasAndroidHardwareCache) {
      // Only auto-unwrap if the device keystore cache is non-biometric; when
      // biometric-bound, `loadCachedVault` returns null so the user must
      // explicitly confirm via `unlockWithAndroidKeystore()`.
      final cached = await _platformBridge.loadCachedVault(uid: uid);
      if (cached != null && cached.userPrivateKey.length == 32) {
        final pub = X25519.publicKeyFromPrivate(cached.userPrivateKey);
        _unlockedKeyPair = X25519KeyPair(
          publicKey: pub,
          privateKey: cached.userPrivateKey,
        );
        _activeAuthSeed16 = cached.authSeed16;
        _unlockedViaHardwareCache = true;
      }
    }

    if (isConfigured) {
      try {
        _remoteKeyring = await fetchUserKeyring(uid);
        _remoteKeyringChecked = true;
      } catch (e) {
        debugPrint('[EdgeMapper] Keyring check skipped: $e');
      }
    }
    notifyListeners();
  }

  /// Primary Android unlock: authenticates with Android Fingerprint / Screen
  /// Lock (`BiometricPrompt`) and unwraps `(authSeed16, User_Priv)` from
  /// Android Keystore `AES-256-GCM` (`setRandomizedEncryptionRequired(true)`).
  Future<void> unlockWithAndroidKeystore() async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured in this build.');
    }
    final cached = await _platformBridge.unlockCachedVaultWithBiometric(
      uid: currentUid,
    );
    if (cached == null) {
      throw StateError(
        'No vault is cached in Android Keystore yet. Create a new vault or link an existing X25519 key.',
      );
    }
    try {
      if (!isSignedIn && cached.authSeed16 != null) {
        final authCreds =
            E2eeEnvelopeCrypto.deriveVaultAuthCredentials(cached.authSeed16!);
        await _authenticateInternalVault(authCreds, createNew: false);
      }
      final uid = currentUid ?? cached.uid;
      final pub = X25519.publicKeyFromPrivate(cached.userPrivateKey);
      _clearVolatileKeyPair();
      _unlockedKeyPair = X25519KeyPair(
        publicKey: pub,
        privateKey: Uint8List.fromList(cached.userPrivateKey),
      );
      _activeAuthSeed16 = cached.authSeed16 != null
          ? Uint8List.fromList(cached.authSeed16!)
          : null;
      _hasAndroidHardwareCache = true;
      _unlockedViaHardwareCache = true;
      try {
        _remoteKeyring = await fetchUserKeyring(uid);
        _remoteKeyringChecked = true;
      } catch (_) {}
      notifyListeners();
    } finally {
      cached.zeroizeSecrets();
    }
  }

  // --- Single-Step Zero-Config Passkey (PRF) & Fallback Recovery Key Auth ---

  Future<void> _authenticateInternalVault(
    DerivedVaultAuthCredentials creds, {
    required bool createNew,
  }) async {
    if (!isAuthAvailable) {
      throw StateError(
        'Firebase Auth is not initialized. Configure Firebase in .env first.',
      );
    }
    if (_vaultAuthOverride != null) {
      await _vaultAuthOverride.call(creds, createNew: createNew);
      return;
    }

    // Android: use Identity Toolkit REST API directly (bypasses native Android reCAPTCHA SDK)
    if (!kIsWeb) {
      await _authenticateViaRest(creds, createNew: createNew);
      return;
    }

    // Web: keep standard FirebaseAuth SDK (uses reCAPTCHA web provider)
    try {
      if (createNew) {
        try {
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
            email: creds.internalHandle,
            password: creds.internalSecret,
          );
          return;
        } on FirebaseAuthException catch (e) {
          if (e.code == 'email-already-in-use') {
            await FirebaseAuth.instance.signInWithEmailAndPassword(
              email: creds.internalHandle,
              password: creds.internalSecret,
            );
            return;
          }
          rethrow;
        }
      }
      try {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: creds.internalHandle,
          password: creds.internalSecret,
        );
      } on FirebaseAuthException catch (e) {
        if (e.code == 'user-not-found' || e.code == 'invalid-credential') {
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
            email: creds.internalHandle,
            password: creds.internalSecret,
          );
        } else {
          rethrow;
        }
      }
    } on FirebaseAuthException catch (e) {
      throw Exception(_friendlyAuthError(e));
    }
  }

  Future<void> _authenticateViaRest(
    DerivedVaultAuthCredentials creds, {
    required bool createNew,
  }) async {
    final apiKey = Firebase.app().options.apiKey;

    Future<http.Response> postAuth(String endpoint) async {
      final uri = Uri.https(
        'identitytoolkit.googleapis.com',
        '/v1/accounts:$endpoint',
        {'key': apiKey},
      );
      final appCheck = await AttestGateAppCheck.getHeaderToken();
      return _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              if (appCheck != null && appCheck.isNotEmpty)
                'X-Firebase-AppCheck': appCheck,
            },
            body: jsonEncode({
              'email': creds.internalHandle,
              'password': creds.internalSecret,
              'returnSecureToken': true,
            }),
          )
          .timeout(const Duration(seconds: 20));
    }

    var resp = await postAuth(createNew ? 'signUp' : 'signInWithPassword');
    if (resp.statusCode >= 400) {
      final errMsg = _compactError(resp.body).toUpperCase();
      if (createNew && errMsg.contains('EMAIL_EXISTS')) {
        resp = await postAuth('signInWithPassword');
      } else if (!createNew &&
          (errMsg.contains('EMAIL_NOT_FOUND') ||
              errMsg.contains('INVALID_LOGIN_CREDENTIALS'))) {
        resp = await postAuth('signUp');
      }
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('Firebase Auth REST error: ${_compactError(resp.body)}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    _restUid = data['localId']?.toString();
    _restEmail = creds.internalHandle;
    _restIdToken = data['idToken']?.toString();
    _restRefreshToken = data['refreshToken']?.toString();
    final expiresIn = int.tryParse(data['expiresIn']?.toString() ?? '') ?? 3600;
    _restTokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));
  }

  Future<String?> _getRestIdToken({bool forceRefresh = false}) async {
    if (_restIdToken != null &&
        !forceRefresh &&
        _restTokenExpiry != null &&
        DateTime.now().isBefore(_restTokenExpiry!)) {
      return _restIdToken;
    }
    final refresh = _restRefreshToken;
    if (refresh == null || refresh.isEmpty) return _restIdToken;

    final apiKey = Firebase.app().options.apiKey;
    final uri = Uri.https('securetoken.googleapis.com', '/v1/token', {'key': apiKey});
    final resp = await _client
        .post(
          uri,
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: 'grant_type=refresh_token&refresh_token=${Uri.encodeQueryComponent(refresh)}',
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      _restIdToken = data['id_token']?.toString();
      _restRefreshToken = data['refresh_token']?.toString() ?? refresh;
      final expiresIn = int.tryParse(data['expires_in']?.toString() ?? '') ?? 3600;
      _restTokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));
    }
    return _restIdToken;
  }

  /// 1-Tap Zero-Config Vault Creation with WebAuthn Passkey (`prf`):
  /// - No email or password required.
  /// - Creates a discoverable Passkey with deterministic salt `app-vault-root-v1`.
  /// - Derives internal Firebase session + `PRF_Root_Key` via `HKDF-SHA256`.
  /// - Generates an `X25519` keypair (`User_Pub`, `User_Priv`), wraps `User_Priv`
  ///   under BOTH `wrapped_priv_prf` AND a portable Argon2id (64 MB / 3 iter)
  ///   Fallback Recovery Key (`wrapped_priv_recovery`) carrying the same vault
  ///   identity seed so non-PRF devices (e.g. Android) recover the exact same vault!
  Future<KeyringSetupResult> createVaultWithPasskeyPrf({
    Argon2Params argon2Params = Argon2Params.defaultProduction,
  }) async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured in this build.');
    }
    // Enforce single key per device: if this browser already enrolled a Passkey,
    // unlock and reuse that existing Passkey & data instead of creating a duplicate.
    if (prefs.e2eePasskeyCredentialId.isNotEmpty) {
      await signInAndUnlockWithPasskeyPrf();
      final uid = _requireUid();
      final existing = _remoteKeyring ??
          UserKeyring(
            uid: uid,
            x25519PublicKeyB64: publicKeyB64 ?? '',
          );
      return KeyringSetupResult(
        keyring: existing,
        recoveryKey: '',
        prfEnrolled: true,
        androidHardwareCached: _hasAndroidHardwareCache,
      );
    }
    final displayHandle = prefs.explorerHandle.trim().isNotEmpty &&
            prefs.explorerHandle.trim() != 'You'
        ? prefs.explorerHandle.trim()
        : 'Edge Mapper Vault';

    final prfRes = await _platformBridge.enrollPasskeyPrf(
      accountName: displayHandle,
      displayName: displayHandle,
      deterministicSalt: E2eeEnvelopeCrypto.prfEvalSaltBytes,
    );
    Uint8List? authSeed;
    try {
      if (!prfRes.prfSupported || !prfRes.hasPrfOutput) {
        throw PrfUnsupportedException(
          prfRes.errorMessage ??
              'This authenticator does not support WebAuthn PRF. Use the Recovery Key option below instead.',
        );
      }
      final prfOutput = prfRes.prfOutput!;
      if (prfRes.credentialIdB64 != null &&
          prfRes.credentialIdB64!.trim().isNotEmpty) {
        await prefs.setE2eePasskeyCredentialId(prfRes.credentialIdB64!);
      }
      authSeed = E2eeEnvelopeCrypto.deriveAuthSeedFromPrf(prfOutput);
      final authCreds = E2eeEnvelopeCrypto.deriveVaultAuthCredentials(authSeed);
      await _authenticateInternalVault(authCreds, createNew: true);
      final uid = _requireUid();

      // If this exact Passkey already owns a cloud keyring, unlock it seamlessly!
      final existingKeyring = await fetchUserKeyring(uid);
      if (existingKeyring != null && existingKeyring.hasPrfSlot) {
        final unwrappedPriv = E2eeEnvelopeCrypto.unwrapUserPrivWithPrf(
          uid: uid,
          slot: existingKeyring.wrappedPrivPrf!,
          prfOutput: prfOutput,
        );
        await _activateUnlockedPrivateKey(
          uid: uid,
          keyring: existingKeyring,
          privateKey: unwrappedPriv,
          authSeed16: authSeed,
        );
        return KeyringSetupResult(
          keyring: existingKeyring,
          recoveryKey: '',
          prfEnrolled: true,
          androidHardwareCached: _hasAndroidHardwareCache,
        );
      }

      final recoveryKey =
          E2eeEnvelopeCrypto.generateRecoveryKey(authSeed16: authSeed);
      final keyPair = X25519.generateKeyPair();
      try {
        final prfSlot = E2eeEnvelopeCrypto.wrapUserPrivWithPrf(
          uid: uid,
          userPrivateKey: keyPair.privateKey,
          prfOutput: prfOutput,
        );
        final recoverySlot =
            await E2eeEnvelopeCrypto.wrapUserPrivWithRecoveryKey(
          uid: uid,
          userPrivateKey: keyPair.privateKey,
          recoveryKey: recoveryKey,
          params: argon2Params,
        );
        final keyring = UserKeyring(
          uid: uid,
          x25519PublicKeyB64: keyPair.publicKeyB64,
          wrappedPrivPrf: prfSlot,
          wrappedPrivRecovery: recoverySlot,
        );
        await _uploadUserKeyring(keyring);

        _clearVolatileKeyPair();
        _unlockedKeyPair = keyPair;
        _activeAuthSeed16 = Uint8List.fromList(authSeed);
        _remoteKeyring = keyring;
        _remoteKeyringChecked = true;
        _unlockedViaHardwareCache = false;

        final cached = await _platformBridge.cacheUserPrivLocally(
          uid: uid,
          userPrivateKey: keyPair.privateKey,
          authSeed16: authSeed,
        );
        _hasAndroidHardwareCache = cached;
        notifyListeners();

        return KeyringSetupResult(
          keyring: keyring,
          recoveryKey: recoveryKey,
          prfEnrolled: true,
          androidHardwareCached: cached,
        );
      } catch (_) {
        keyPair.zeroizePrivate();
        rethrow;
      }
    } finally {
      zeroize(prfRes.prfOutput);
      zeroize(authSeed);
    }
  }

  /// 1-Tap Zero-Config Cross-Device Sign-In & Root Unlock via WebAuthn `prf`:
  /// Works on a brand-new second computer with NO email, NO password, and NO
  /// prior setup — uses the synced Passkey to authenticate AND derive
  /// `PRF_Root_Key` via `HKDF-SHA256` to unwrap `User_Priv` from
  /// `users/{uid}/security/keyring`.
  Future<void> signInAndUnlockWithPasskeyPrf() async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured in this build.');
    }
    final prfRes = await _platformBridge.evaluatePasskeyPrf(
      deterministicSalt: E2eeEnvelopeCrypto.prfEvalSaltBytes,
      credentialIdB64: prefs.e2eePasskeyCredentialId.isNotEmpty
          ? prefs.e2eePasskeyCredentialId
          : null,
    );
    Uint8List? authSeed;
    try {
      if (!prfRes.prfSupported || !prfRes.hasPrfOutput) {
        throw PrfUnsupportedException(
          prfRes.errorMessage ??
              'Authenticator does not support WebAuthn PRF. Unlock with your Recovery Key instead.',
        );
      }
      final prfOutput = prfRes.prfOutput!;
      if (prfRes.credentialIdB64 != null &&
          prfRes.credentialIdB64!.trim().isNotEmpty) {
        await prefs.setE2eePasskeyCredentialId(prfRes.credentialIdB64!);
      }
      authSeed = E2eeEnvelopeCrypto.deriveAuthSeedFromPrf(prfOutput);
      final authCreds =
          E2eeEnvelopeCrypto.deriveVaultAuthCredentials(authSeed);
      final currentEmail =
          (kIsWeb ? _currentFirebaseUser?.email : _restEmail)?.toLowerCase();
      if (!isSignedIn ||
          (currentEmail != null &&
              currentEmail != authCreds.internalHandle.toLowerCase())) {
        if (isSignedIn) {
          await signOutAndLock(clearHardwareCache: false);
        }
        await _authenticateInternalVault(authCreds, createNew: false);
      }
      final uid = _requireUid();
      final keyring = await fetchUserKeyring(uid);
      if (keyring == null || !keyring.hasPrfSlot) {
        throw const PrfUnsupportedException(
          'No cloud keyring found for this Passkey yet. Tap "Create New Vault with Passkey" or use your Recovery Key.',
        );
      }
      final unwrappedPriv = E2eeEnvelopeCrypto.unwrapUserPrivWithPrf(
        uid: uid,
        slot: keyring.wrappedPrivPrf!,
        prfOutput: prfOutput,
      );
      await _activateUnlockedPrivateKey(
        uid: uid,
        keyring: keyring,
        privateKey: unwrappedPriv,
        authSeed16: authSeed,
      );
    } finally {
      zeroize(prfRes.prfOutput);
      zeroize(authSeed);
    }
  }

  /// Convenience alias for unlocking with WebAuthn Passkey PRF.
  Future<void> unlockWithPasskeyPrf() => signInAndUnlockWithPasskeyPrf();

  /// Single-entry device vault initializer: enforces at most ONE generated key
  /// per device. If this device already has a key (Android Keystore or local
  /// Passkey), unlocks & reuses that existing key and all its cloud data.
  Future<KeyringSetupResult> initializeDeviceVault({
    Argon2Params argon2Params = Argon2Params.defaultProduction,
  }) async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured in this build.');
    }
    if (isVaultUnlocked) {
      final uid = _requireUid();
      return KeyringSetupResult(
        keyring: _remoteKeyring ??
            UserKeyring(uid: uid, x25519PublicKeyB64: publicKeyB64 ?? ''),
        recoveryKey: '',
        prfEnrolled: hasPrfSlot,
        androidHardwareCached: _hasAndroidHardwareCache,
      );
    }
    // Check live hardware cache first so a device NEVER generates a second key
    if (_capabilities.supportsAndroidHardwareCache &&
        await _platformBridge.hasCachedUserPriv()) {
      await unlockWithAndroidKeystore();
      final uid = _requireUid();
      return KeyringSetupResult(
        keyring: _remoteKeyring ??
            UserKeyring(uid: uid, x25519PublicKeyB64: publicKeyB64 ?? ''),
        recoveryKey: '',
        prfEnrolled: hasPrfSlot,
        androidHardwareCached: true,
      );
    }
    if (_capabilities.supportsWebAuthnPrf) {
      if (prefs.e2eePasskeyCredentialId.isNotEmpty) {
        await signInAndUnlockWithPasskeyPrf();
        final uid = _requireUid();
        return KeyringSetupResult(
          keyring: _remoteKeyring ??
              UserKeyring(uid: uid, x25519PublicKeyB64: publicKeyB64 ?? ''),
          recoveryKey: '',
          prfEnrolled: true,
          androidHardwareCached: _hasAndroidHardwareCache,
        );
      }
      return createVaultWithPasskeyPrf(argon2Params: argon2Params);
    }
    return createVaultWithRecoveryKey(argon2Params: argon2Params);
  }

  /// Fallback Vault Creation using a portable high-entropy Recovery Key
  /// (`emr1-...`) wrapped via Argon2id (64 MB memory, 3 iterations) — for
  /// Android devices or authenticators without WebAuthn `prf` support.
  Future<KeyringSetupResult> createVaultWithRecoveryKey({
    String? customRecoveryKey,
    Argon2Params argon2Params = Argon2Params.defaultProduction,
  }) async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured in this build.');
    }
    // Enforce single key per device: if Android Keystore already holds a key
    // and caller did not provide a specific custom recovery key, reuse it!
    if ((customRecoveryKey == null || customRecoveryKey.trim().isEmpty) &&
        _capabilities.supportsAndroidHardwareCache &&
        await _platformBridge.hasCachedUserPriv()) {
      await unlockWithAndroidKeystore();
      final uid = _requireUid();
      return KeyringSetupResult(
        keyring: _remoteKeyring ??
            UserKeyring(uid: uid, x25519PublicKeyB64: publicKeyB64 ?? ''),
        recoveryKey: '',
        prfEnrolled: hasPrfSlot,
        androidHardwareCached: true,
      );
    }

    final rawKey = (customRecoveryKey != null &&
            customRecoveryKey.trim().isNotEmpty)
        ? customRecoveryKey.trim()
        : E2eeEnvelopeCrypto.generateRecoveryKey();
    final parsed = E2eeEnvelopeCrypto.parseRecoveryKey(rawKey);
    try {
      await _authenticateInternalVault(parsed.authCredentials, createNew: true);
      final uid = _requireUid();

      // Recognize existing user: if a cloud keyring already exists for this UID,
      // unwrap and reuse it instead of generating a new keypair & stranding data.
      final existingKeyring = await fetchUserKeyring(uid);
      if (existingKeyring != null && existingKeyring.hasRecoverySlot) {
        final unwrappedPriv =
            await E2eeEnvelopeCrypto.unwrapUserPrivWithRecoveryKey(
          uid: uid,
          slot: existingKeyring.wrappedPrivRecovery!,
          recoveryKey: parsed.canonicalKey,
        );
        await _activateUnlockedPrivateKey(
          uid: uid,
          keyring: existingKeyring,
          privateKey: unwrappedPriv,
          authSeed16: parsed.authSeed16,
        );
        return KeyringSetupResult(
          keyring: existingKeyring,
          recoveryKey: parsed.canonicalKey,
          prfEnrolled: existingKeyring.hasPrfSlot,
          androidHardwareCached: _hasAndroidHardwareCache,
        );
      }

      final keyPair = X25519.generateKeyPair();
      try {
        final recoverySlot =
            await E2eeEnvelopeCrypto.wrapUserPrivWithRecoveryKey(
          uid: uid,
          userPrivateKey: keyPair.privateKey,
          recoveryKey: parsed.canonicalKey,
          params: argon2Params,
        );
        final keyring = UserKeyring(
          uid: uid,
          x25519PublicKeyB64: keyPair.publicKeyB64,
          wrappedPrivPrf: null,
          wrappedPrivRecovery: recoverySlot,
        );
        await _uploadUserKeyring(keyring);

        _clearVolatileKeyPair();
        _unlockedKeyPair = keyPair;
        _activeAuthSeed16 = Uint8List.fromList(parsed.authSeed16);
        _remoteKeyring = keyring;
        _remoteKeyringChecked = true;
        _unlockedViaHardwareCache = false;

        final cached = await _platformBridge.cacheUserPrivLocally(
          uid: uid,
          userPrivateKey: keyPair.privateKey,
          authSeed16: parsed.authSeed16,
        );
        _hasAndroidHardwareCache = cached;
        notifyListeners();

        return KeyringSetupResult(
          keyring: keyring,
          recoveryKey: parsed.canonicalKey,
          prfEnrolled: false,
          androidHardwareCached: cached,
        );
      } catch (_) {
        keyPair.zeroizePrivate();
        rethrow;
      }
    } finally {
      parsed.zeroizeSecrets();
    }
  }

  /// Single-Step Fallback Recovery Slot Sign-In & Unlock via Argon2id
  /// (64 MB memory, 3 iterations) from the portable Recovery Key (`emr1-...`).
  /// Signs into the exact same Firebase `uid` as the Passkey (zero email or
  /// password!) and caches `User_Priv` in Android Hardware Keystore on Android.
  Future<void> signInAndUnlockWithRecoveryKey(String recoveryKey) async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured in this build.');
    }
    final parsed = E2eeEnvelopeCrypto.parseRecoveryKey(recoveryKey);
    try {
      final currentEmail =
          (kIsWeb ? _currentFirebaseUser?.email : _restEmail)?.toLowerCase();
      if (!isSignedIn ||
          (currentEmail != null &&
              currentEmail != parsed.authCredentials.internalHandle.toLowerCase())) {
        if (isSignedIn) {
          await signOutAndLock(clearHardwareCache: false);
        }
        await _authenticateInternalVault(
          parsed.authCredentials,
          createNew: false,
        );
      }
      final uid = _requireUid();
      final keyring = await fetchUserKeyring(uid);
      if (keyring == null || !keyring.hasRecoverySlot) {
        throw StateError(
          'No cloud keyring found for this Recovery Key. Check that you entered the right key.',
        );
      }
      final unwrappedPriv =
          await E2eeEnvelopeCrypto.unwrapUserPrivWithRecoveryKey(
        uid: uid,
        slot: keyring.wrappedPrivRecovery!,
        recoveryKey: parsed.canonicalKey,
      );
      await _activateUnlockedPrivateKey(
        uid: uid,
        keyring: keyring,
        privateKey: unwrappedPriv,
        authSeed16: parsed.authSeed16,
      );
    } finally {
      parsed.zeroizeSecrets();
    }
  }

  /// Fast cross-device link using an `emx1-...` X25519 Sync Key copied or
  /// scanned as QR from another device owned by the same user:
  /// signs into the exact same Firebase `uid`, verifies against
  /// `users/{uid}/security/keyring`, caches into Android Keystore on Android,
  /// and unlocks Firestore sync immediately.
  Future<void> signInAndUnlockWithX25519SyncKey(String rawKey) async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured in this build.');
    }
    final parsed = E2eeEnvelopeCrypto.parseX25519SyncKey(rawKey);
    try {
      await _authenticateInternalVault(
        parsed.authCredentials,
        createNew: false,
      );
      final uid = _requireUid();
      var keyring = await fetchUserKeyring(uid);
      if (keyring != null) {
        if (!constantTimeEquals(parsed.userPublicKey, keyring.publicKeyBytes)) {
          throw const E2eeAuthTagException(
            'X25519 Sync Key does not match this vault public key.',
          );
        }
      } else {
        // Ensure keyring exists in Firestore if migrating/linking an offline vault
        keyring = UserKeyring(
          uid: uid,
          x25519PublicKeyB64: base64Encode(parsed.userPublicKey),
        );
        await _uploadUserKeyring(keyring);
      }
      await _activateUnlockedPrivateKey(
        uid: uid,
        keyring: keyring,
        privateKey: Uint8List.fromList(parsed.userPrivateKey),
        authSeed16: parsed.authSeed16,
      );
    } finally {
      parsed.zeroizeSecrets();
    }
  }

  /// Smart single-field key unlock: accepts EITHER a direct cross-device
  /// X25519 Sync Key (`emx1-...`) OR an optional Bitwarden Argon2id Recovery
  /// Key (`emr1-...`).
  Future<void> signInAndUnlockWithAnyKey(String rawKey) {
    final trimmed = rawKey.trim();
    if (trimmed.toLowerCase().startsWith('emx1-')) {
      return signInAndUnlockWithX25519SyncKey(trimmed);
    }
    return signInAndUnlockWithRecoveryKey(trimmed);
  }

  /// Convenience alias for unlocking with Recovery Key.
  Future<void> unlockWithRecoveryKey(String recoveryKey) =>
      signInAndUnlockWithRecoveryKey(recoveryKey);

  /// Attaches (or updates) a WebAuthn `prf` Passkey slot on an already
  /// unlocked keyring without rotating `User_Priv`.
  Future<void> attachPasskeyPrfToUnlockedKeyring() async {
    final uid = _requireUid();
    final kp = _requireUnlockedKeyPair();
    final existing = _remoteKeyring ?? await fetchUserKeyring(uid);
    if (existing == null) {
      throw StateError('Initialize your E2EE keyring first.');
    }

    final label = 'Edge Mapper Vault (${kp.publicFingerprint})';
    final prfRes = await _platformBridge.enrollPasskeyPrf(
      accountName: label,
      displayName: label,
      deterministicSalt: E2eeEnvelopeCrypto.prfEvalSaltBytes,
    );
    try {
      if (!prfRes.prfSupported || !prfRes.hasPrfOutput) {
        throw PrfUnsupportedException(
          prfRes.errorMessage ??
              'Authenticator does not support WebAuthn PRF.',
        );
      }
      if (prfRes.credentialIdB64 != null &&
          prfRes.credentialIdB64!.trim().isNotEmpty) {
        await prefs.setE2eePasskeyCredentialId(prfRes.credentialIdB64!);
      }
      final prfSlot = E2eeEnvelopeCrypto.wrapUserPrivWithPrf(
        uid: uid,
        userPrivateKey: kp.privateKey,
        prfOutput: prfRes.prfOutput!,
      );
      final updated = UserKeyring(
        uid: uid,
        x25519PublicKeyB64: kp.publicKeyB64,
        wrappedPrivPrf: prfSlot,
        wrappedPrivRecovery: existing.wrappedPrivRecovery,
      );
      await _uploadUserKeyring(updated);
      _remoteKeyring = updated;
      notifyListeners();
    } finally {
      zeroize(prfRes.prfOutput);
    }
  }

  /// Re-wraps `User_Priv` under a fresh Argon2id Recovery Key slot while
  /// preserving the active `authSeed16` so the rotated key continues signing
  /// into the exact same Firebase UID on other devices.
  Future<String> rotateRecoveryKeyOnUnlockedKeyring({
    String? newRecoveryKey,
    Argon2Params argon2Params = Argon2Params.defaultProduction,
  }) async {
    final uid = _requireUid();
    final kp = _requireUnlockedKeyPair();
    final existing = _remoteKeyring ?? await fetchUserKeyring(uid);
    final String effectiveKey;
    if (newRecoveryKey != null && newRecoveryKey.trim().isNotEmpty) {
      effectiveKey = E2eeEnvelopeCrypto.normalizeRecoveryKey(newRecoveryKey);
    } else {
      final seed = _activeAuthSeed16;
      if (seed == null || seed.length != 16) {
        throw StateError(
          'Cannot rotate Recovery Key without an active vault identity seed. '
          'Unlock using your current Recovery Key or Passkey first.',
        );
      }
      effectiveKey = E2eeEnvelopeCrypto.generateRecoveryKey(authSeed16: seed);
    }

    final recoverySlot =
        await E2eeEnvelopeCrypto.wrapUserPrivWithRecoveryKey(
      uid: uid,
      userPrivateKey: kp.privateKey,
      recoveryKey: effectiveKey,
      params: argon2Params,
    );
    final updated = UserKeyring(
      uid: uid,
      x25519PublicKeyB64: kp.publicKeyB64,
      wrappedPrivPrf: existing?.wrappedPrivPrf,
      wrappedPrivRecovery: recoverySlot,
    );
    await _uploadUserKeyring(updated);
    _remoteKeyring = updated;
    notifyListeners();
    return effectiveKey;
  }

  Future<void> _activateUnlockedPrivateKey({
    required String uid,
    required UserKeyring keyring,
    required Uint8List privateKey,
    Uint8List? authSeed16,
  }) async {
    try {
      final derivedPub = X25519.publicKeyFromPrivate(privateKey);
      if (!constantTimeEquals(derivedPub, keyring.publicKeyBytes)) {
        zeroize(privateKey);
        throw const E2eeAuthTagException(
          'Unwrapped private key does not match the keyring public key.',
        );
      }
      _explicitlyLocked = false;
      _clearVolatileKeyPair();
      _unlockedKeyPair = X25519KeyPair(
        publicKey: derivedPub,
        privateKey: privateKey,
      );
      _activeAuthSeed16 =
          authSeed16 != null ? Uint8List.fromList(authSeed16) : null;
      _remoteKeyring = keyring;
      _remoteKeyringChecked = true;
      _unlockedViaHardwareCache = false;

      _hasAndroidHardwareCache = await _platformBridge.cacheUserPrivLocally(
        uid: uid,
        userPrivateKey: privateKey,
        authSeed16: authSeed16,
      );
      notifyListeners();
    } catch (_) {
      zeroize(privateKey);
      rethrow;
    }
  }

  /// Immediately wipes `User_Priv` from volatile RAM without signing out of
  /// Firebase Auth (so the user can re-unlock with Passkey or Recovery Key).
  void lockVault() {
    _explicitlyLocked = true;
    _clearVolatileKeyPair();
    notifyListeners();
  }

/// Signs out of Firebase Auth, zeroizes all volatile keys in RAM, and clears
  /// the Android Keystore hardware cache when [clearHardwareCache] is true.
  Future<void> signOutAndLock({bool clearHardwareCache = true}) async {
    final uid = currentUid;
    _clearVolatileKeyPair();
    _remoteKeyring = null;
    _remoteKeyringChecked = false;
    _restUid = null;
    _restEmail = null;
    _restIdToken = null;
    _restRefreshToken = null;
    _restTokenExpiry = null;
    if (clearHardwareCache) {
      await _platformBridge.clearCachedUserPriv(uid: uid);
      _hasAndroidHardwareCache = false;
    }
    if (_authSignOutOverride != null) {
      await _authSignOutOverride.call();
    } else if (kIsWeb &&
        FirebaseBootstrap.isConfigured &&
        Firebase.apps.isNotEmpty) {
      await FirebaseAuth.instance.signOut();
    }
    notifyListeners();
  }

  /// Fetches `users/{uid}/security/keyring` from Firestore.
  Future<UserKeyring?> fetchUserKeyring(String uid) async {
    if (!isConfigured) return null;
    final uri = _documentUri('users/$uid/security', 'keyring');
    final resp = await _sendWithAppCheckRetry(
      'GET users/$uid/security/keyring',
      (headers) => _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 20)),
    );
    if (resp.statusCode == 404) return null;
    final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(_friendlyFirestoreError(resp.statusCode, bodyText));
    }
    final decoded = jsonDecode(bodyText) as Map<String, dynamic>;
    final fields = decoded['fields'] as Map<String, dynamic>?;
    if (fields == null) return null;
    return decodeKeyringFromFirestoreFields(uid, fields);
  }

  /// Fetches another collaborator's plaintext `X25519` public key from
  /// `users/{recipientUid}/public/key` for selective sharing.
  ///
  /// Public keys live in a dedicated document separate from
  /// `users/{uid}/security/keyring` so collaborators can never read each
  /// other's encrypted private-key slots or KDF salts.
  Future<Uint8List> fetchRecipientPublicKey(String recipientUid) async {
    final cleanUid = recipientUid.trim();
    if (!_safeSegmentPattern.hasMatch(cleanUid)) {
      throw ArgumentError('Invalid recipient UID format.');
    }
    final uri = _documentUri('users/$cleanUid/public', 'key');
    final resp = await _sendWithAppCheckRetry(
      'GET users/$cleanUid/public/key',
      (headers) => _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 20)),
    );
    String? pubB64;
    if (resp.statusCode == 200) {
      final decoded =
          jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true))
              as Map<String, dynamic>;
      final fields = decoded['fields'] as Map<String, dynamic>?;
      pubB64 = _readString(fields?['x25519_public_key']);
    } else if (resp.statusCode == 404 && cleanUid == currentUid) {
      final ownKeyring = await fetchUserKeyring(cleanUid);
      pubB64 = ownKeyring?.x25519PublicKeyB64;
    } else if (resp.statusCode != 404) {
      final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
      throw Exception(_friendlyFirestoreError(resp.statusCode, bodyText));
    }

    if (pubB64 == null || pubB64.isEmpty) {
      throw StateError(
        'Collaborator "$cleanUid" has not published a public E2EE key yet.',
      );
    }
    final pub = Uint8List.fromList(base64Decode(pubB64.trim()));
    if (pub.length != X25519.keyLength) {
      throw StateError('Invalid X25519 public key length for "$cleanUid".');
    }
    return pub;
  }

  Future<void> _uploadUserKeyring(UserKeyring keyring) async {
    // 1. Write private encrypted keyring (`users/{uid}/security/keyring` — owner-only)
    final keyringUri = _documentUri('users/${keyring.uid}/security', 'keyring');
    final keyringBody = jsonEncode({
      'fields': encodeKeyringToFirestoreFields(keyring),
    });
    final resp = await _sendWithAppCheckRetry(
      'PATCH users/${keyring.uid}/security/keyring',
      (headers) => _client
          .patch(keyringUri, headers: headers, body: keyringBody)
          .timeout(const Duration(seconds: 25)),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(_friendlyFirestoreError(resp.statusCode, resp.body));
    }

    // 2. Publish ONLY the non-secret X25519 public key to `users/{uid}/public/key`
    final pubUri = _documentUri('users/${keyring.uid}/public', 'key');
    final pubBody = jsonEncode({
      'fields': {
        'x25519_public_key': _fsString(keyring.x25519PublicKeyB64),
        'updated_at': _fsTimestamp(DateTime.now().toUtc()),
      },
    });
    final pubResp = await _sendWithAppCheckRetry(
      'PATCH users/${keyring.uid}/public/key',
      (headers) => _client
          .patch(pubUri, headers: headers, body: pubBody)
          .timeout(const Duration(seconds: 25)),
    );
    if (pubResp.statusCode < 200 || pubResp.statusCode >= 300) {
      throw Exception(
        _friendlyFirestoreError(pubResp.statusCode, pubResp.body),
      );
    }
  }

  // --- Step 3: E2EE Items (`items/{itemId}`) Sync & Selective Sharing ---

  static String recordItemId(String recordId) => 'rec_$recordId';
  static String trailItemId(String trailId) => 'trail_$trailId';
  static String itemDocumentPath(String itemId) => 'items/$itemId';

  /// Encrypts [record] (and optional compressed JPEG photo) with a random
  /// 256-bit `Item_DEK`, 192-bit nonce, and AAD `items/rec_{id}|v1`, wraps
  /// `Item_DEK` for the owner (and any existing/additional recipients), and
  /// uploads ONLY ciphertext to `items/rec_{id}`.
  Future<bool> syncRecord(
    OsmRecord record, {
    String? photoDataUriOverride,
    Map<String, Uint8List>? extraRecipientPublicKeys,
  }) async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured in this build.');
    }
    final uid = _requireUid();
    final kp = _requireUnlockedKeyPair();
    final itemId = recordItemId(record.id);
    final docPath = itemDocumentPath(itemId);

    String? photoDataUri =
        photoDataUriOverride ?? await readPhotoAsDataUri(record.photoPath);

    // Preserve existing Item_DEK & shared recipients when updating an existing
    // remote document so collaborators are never silently dropped and remote
    // encrypted photos remain decryptable during metadata-only updates.
    Uint8List? reusedDek;
    Map<String, WrappedDekEnvelope>? preservedRecipients;
    if (extraRecipientPublicKeys == null) {
      final existing = await _fetchRawItemDocument(itemId);
      if (existing != null) {
        final hasRemotePhoto = existing['photo_ciphertext'] != null;
        try {
          final parsedEnv = decodeEncryptedItemEnvelope(docPath, existing);
          if (parsedEnv != null && parsedEnv.recipients.containsKey(uid)) {
            reusedDek = E2eeEnvelopeCrypto.unwrapItemDek(
              envelope: parsedEnv.recipients[uid]!,
              recipientPrivateKey: kp.privateKey,
              recipientPublicKey: kp.publicKey,
              documentPath: docPath,
              recipientUid: uid,
              schemaVersion: parsedEnv.schemaVersion,
            );
            preservedRecipients = parsedEnv.recipients;
          }
        } catch (e) {
          if (photoDataUri == null && hasRemotePhoto) {
            throw StateError(
              'Cannot perform metadata-only update without decrypting the existing remote Item_DEK (would orphan remote encrypted photo): $e',
            );
          }
        }
      }
    }

    final recipientPubs = <String, Uint8List>{
      uid: kp.publicKey,
      ...?extraRecipientPublicKeys,
    };

    try {
      Future<http.Response> sendPatch(String? photoUri) async {
        final fields = encodeEncryptedRecordItemFields(
          record: record,
          ownerUid: uid,
          recipientPublicKeys: recipientPubs,
          existingDek: reusedDek,
          preservedRecipients:
              extraRecipientPublicKeys == null ? preservedRecipients : null,
          photoDataUri: photoUri,
        );
        final uri = _documentUri(
          'items',
          itemId,
          updateMaskFieldPaths: photoUri == null ? fields.keys.toList() : null,
        );
        final body = jsonEncode({'fields': fields});
        return _sendWithAppCheckRetry(
          'PATCH $docPath',
          (headers) => _client
              .patch(uri, headers: headers, body: body)
              .timeout(const Duration(seconds: 45)),
        );
      }

      var resp = await sendPatch(photoDataUri);
      if (resp.statusCode == 400 &&
          photoDataUri != null &&
          photoDataUriOverride == null &&
          resp.body.toLowerCase().contains('size')) {
        photoDataUri = await readPhotoAsDataUri(
          record.photoPath,
          maxRawBytes: 180 * 1024,
        );
        resp = await sendPatch(photoDataUri);
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception(_friendlyFirestoreError(resp.statusCode, resp.body));
      }
      return photoDataUri != null && photoDataUri.isNotEmpty;
    } finally {
      zeroize(reusedDek);
    }
  }

  /// Encrypts [trail] with a random 256-bit `Item_DEK`, 192-bit nonce, and AAD
  /// `items/trail_{id}|v1` and uploads to `items/trail_{id}`.
  Future<void> syncTrail(
    HikeTrail trail, {
    Map<String, Uint8List>? extraRecipientPublicKeys,
  }) async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured in this build.');
    }
    final uid = _requireUid();
    final kp = _requireUnlockedKeyPair();
    final itemId = trailItemId(trail.id);
    final docPath = itemDocumentPath(itemId);

    Uint8List? reusedDek;
    Map<String, WrappedDekEnvelope>? preservedRecipients;
    if (extraRecipientPublicKeys == null) {
      try {
        final existing = await _fetchRawItemDocument(itemId);
        if (existing != null) {
          final parsedEnv = decodeEncryptedItemEnvelope(docPath, existing);
          if (parsedEnv != null && parsedEnv.recipients.containsKey(uid)) {
            reusedDek = E2eeEnvelopeCrypto.unwrapItemDek(
              envelope: parsedEnv.recipients[uid]!,
              recipientPrivateKey: kp.privateKey,
              recipientPublicKey: kp.publicKey,
              documentPath: docPath,
              recipientUid: uid,
              schemaVersion: parsedEnv.schemaVersion,
            );
            preservedRecipients = parsedEnv.recipients;
          }
        }
      } catch (_) {}
    }

    final recipientPubs = <String, Uint8List>{
      uid: kp.publicKey,
      ...?extraRecipientPublicKeys,
    };

    try {
      final fields = encodeEncryptedTrailItemFields(
        trail: trail,
        ownerUid: uid,
        recipientPublicKeys: recipientPubs,
        existingDek: reusedDek,
        preservedRecipients:
            extraRecipientPublicKeys == null ? preservedRecipients : null,
      );
      final uri = _documentUri('items', itemId);
      final body = jsonEncode({'fields': fields});

      final resp = await _sendWithAppCheckRetry(
        'PATCH $docPath',
        (headers) => _client
            .patch(uri, headers: headers, body: body)
            .timeout(const Duration(seconds: 30)),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception(_friendlyFirestoreError(resp.statusCode, resp.body));
      }
    } finally {
      zeroize(reusedDek);
    }
  }

  /// Pulls all encrypted OSM records accessible to the signed-in user (both
  /// personal 1-recipient items and items selectively shared with this user).
  Future<List<RemoteOsmRecord>> fetchAllRecords() async {
    if (!isConfigured) return const [];
    final uid = _requireUid();
    final kp = _requireUnlockedKeyPair();
    final docs = await _queryAccessibleItems(uid);
    final result = <RemoteOsmRecord>[];
    for (final doc in docs) {
      final fields = doc['fields'] as Map<String, dynamic>?;
      if (fields == null) continue;
      if (_readString(fields['item_type']) != 'osm_record') continue;
      final itemId = (doc['name']?.toString() ?? '').split('/').last;
      if (itemId.isEmpty) continue;
      final parsed = decodeEncryptedRecordItemFields(
        itemId: itemId,
        fields: fields,
        recipientUid: uid,
        recipientPrivateKey: kp.privateKey,
        recipientPublicKey: kp.publicKey,
      );
      if (parsed != null) result.add(parsed);
    }
    return result;
  }

  /// Pulls all encrypted routes/trails accessible to the signed-in user.
  Future<List<HikeTrail>> fetchAllTrails() async {
    if (!isConfigured) return const [];
    final uid = _requireUid();
    final kp = _requireUnlockedKeyPair();
    final docs = await _queryAccessibleItems(uid);
    final result = <HikeTrail>[];
    for (final doc in docs) {
      final fields = doc['fields'] as Map<String, dynamic>?;
      if (fields == null) continue;
      if (_readString(fields['item_type']) != 'trail') continue;
      final itemId = (doc['name']?.toString() ?? '').split('/').last;
      if (itemId.isEmpty) continue;
      final parsed = decodeEncryptedTrailItemFields(
        itemId: itemId,
        fields: fields,
        recipientUid: uid,
        recipientPrivateKey: kp.privateKey,
        recipientPublicKey: kp.publicKey,
      );
      if (parsed != null) result.add(parsed);
    }
    return result;
  }

  /// Lists metadata for items owned by or shared with the current user.
  Future<List<SharedItemSummary>> listAccessibleItemSummaries() async {
    if (!isConfigured) return const [];
    final uid = _requireUid();
    final docs = await _queryAccessibleItems(uid);
    final out = <SharedItemSummary>[];
    for (final doc in docs) {
      final fields = doc['fields'] as Map<String, dynamic>?;
      if (fields == null) continue;
      final itemId = (doc['name']?.toString() ?? '').split('/').last;
      final itemType = _readString(fields['item_type']) ?? 'unknown';
      final ownerUid = _readString(fields['owner_uid']) ?? '';
      final recips = _readStringArray(fields['recipient_uids']);
      out.add(
        SharedItemSummary(
          itemId: itemId,
          itemType: itemType,
          ownerUid: ownerUid,
          recipientUids: recips,
        ),
      );
    }
    return out;
  }

  /// Granular multi-recipient sharing: unwraps `Item_DEK` using the owner's
  /// `User_Priv`, wraps `Item_DEK` for the collaborator's `X25519` public key,
  /// and adds them to `items/{itemId}.recipients`.
  Future<void> shareItemWithRecipient({
    required String itemId,
    required String recipientUid,
    String? recipientPublicKeyB64Override,
  }) async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured.');
    }
    final ownerUid = _requireUid();
    final kp = _requireUnlockedKeyPair();
    final cleanRecipientUid = recipientUid.trim();
    if (cleanRecipientUid.isEmpty) {
      throw ArgumentError('Recipient UID cannot be empty.');
    }
    final docPath = itemDocumentPath(itemId);
    final rawFields = await _fetchRawItemDocument(itemId);
    if (rawFields == null) {
      throw StateError('Item "$itemId" was not found in Firestore. Sync it first.');
    }
    final envelope = decodeEncryptedItemEnvelope(docPath, rawFields);
    if (envelope == null) {
      throw StateError('Item "$itemId" is missing valid E2EE fields.');
    }

    final Uint8List recipientPub;
    if (recipientPublicKeyB64Override != null &&
        recipientPublicKeyB64Override.trim().isNotEmpty) {
      recipientPub = Uint8List.fromList(
        base64Decode(recipientPublicKeyB64Override.trim()),
      );
      if (recipientPub.length != X25519.keyLength) {
        throw ArgumentError('Recipient X25519 public key must be 32 bytes.');
      }
    } else {
      recipientPub = await fetchRecipientPublicKey(cleanRecipientUid);
    }

    final updatedEnvelope = E2eeEnvelopeCrypto.addRecipientToEnvelope(
      envelope: envelope,
      ownerUid: ownerUid,
      ownerPrivateKey: kp.privateKey,
      ownerPublicKey: kp.publicKey,
      newRecipientUid: cleanRecipientUid,
      newRecipientPublicKey: recipientPub,
    );

    final patchFields = <String, dynamic>{
      'recipients': _encodeRecipientsMap(updatedEnvelope.recipients),
      'recipient_uids': _encodeStringArray(updatedEnvelope.recipients.keys.toList()),
      'updated_at': _fsTimestamp(DateTime.now().toUtc()),
    };
    final uri = _documentUri(
      'items',
      itemId,
      updateMaskFieldPaths: patchFields.keys.toList(),
    );
    final resp = await _sendWithAppCheckRetry(
      'PATCH $docPath (share)',
      (headers) => _client
          .patch(uri, headers: headers, body: jsonEncode({'fields': patchFields}))
          .timeout(const Duration(seconds: 25)),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(_friendlyFirestoreError(resp.statusCode, resp.body));
    }
  }

  /// Key rotation on revocation: decrypts `items/{itemId}` (and its encrypted
  /// photo if present), rotates to a brand-new 256-bit `Item_DEK` + fresh
  /// 192-bit nonces, re-encrypts everything under the new key, and wraps the
  /// new `Item_DEK` ONLY for remaining recipients (cryptographically excluding
  /// [revokedRecipientUid] from all future writes).
  Future<void> revokeRecipientAndRotateKey({
    required String itemId,
    required String revokedRecipientUid,
    Map<String, Uint8List>? remainingRecipientPublicKeysOverride,
  }) async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured.');
    }
    final ownerUid = _requireUid();
    final kp = _requireUnlockedKeyPair();
    final cleanRevoked = revokedRecipientUid.trim();
    if (cleanRevoked == ownerUid) {
      throw ArgumentError('Cannot revoke the item owner.');
    }

    final docPath = itemDocumentPath(itemId);
    final rawFields = await _fetchRawItemDocument(itemId);
    if (rawFields == null) {
      throw StateError('Item "$itemId" was not found in Firestore.');
    }
    final existingEnv = decodeEncryptedItemEnvelope(docPath, rawFields);
    if (existingEnv == null) {
      throw StateError('Item "$itemId" has invalid E2EE fields.');
    }

    // Decrypt existing payload + optional photo with old Item_DEK
    final oldDek = E2eeEnvelopeCrypto.unwrapItemDek(
      envelope: existingEnv.recipients[ownerUid]!,
      recipientPrivateKey: kp.privateKey,
      recipientPublicKey: kp.publicKey,
      documentPath: docPath,
      recipientUid: ownerUid,
      schemaVersion: existingEnv.schemaVersion,
    );
    Uint8List? plainPayload;
    Uint8List? plainPhoto;
    Uint8List? newDek;
    try {
      plainPayload = XChaCha20Poly1305.decrypt(
        key: oldDek,
        nonce: Uint8List.fromList(base64Decode(existingEnv.nonceB64)),
        ciphertextWithTag:
            Uint8List.fromList(base64Decode(existingEnv.ciphertextB64)),
        aad: Uint8List.fromList(
          utf8.encode(
            E2eeEnvelopeCrypto.formatItemAad(
              docPath,
              schemaVersion: existingEnv.schemaVersion,
            ),
          ),
        ),
      );
      final photoCtB64 = _readString(rawFields['photo_ciphertext']);
      final photoNonceB64 = _readString(rawFields['photo_nonce']);
      if (photoCtB64 != null && photoNonceB64 != null) {
        plainPhoto = XChaCha20Poly1305.decrypt(
          key: oldDek,
          nonce: Uint8List.fromList(base64Decode(photoNonceB64)),
          ciphertextWithTag: Uint8List.fromList(base64Decode(photoCtB64)),
          aad: Uint8List.fromList(
            utf8.encode(
              E2eeEnvelopeCrypto.formatItemAad(
                '$docPath/photo',
                schemaVersion: existingEnv.schemaVersion,
              ),
            ),
          ),
        );
      }

      // Resolve remaining active recipients (excluding revokedRecipientUid)
      final remainingPubs = <String, Uint8List>{
        ownerUid: kp.publicKey,
      };
      if (remainingRecipientPublicKeysOverride != null) {
        for (final entry in remainingRecipientPublicKeysOverride.entries) {
          if (entry.key != cleanRevoked) {
            remainingPubs[entry.key] = entry.value;
          }
        }
      } else {
        for (final uid in existingEnv.recipients.keys) {
          if (uid == ownerUid || uid == cleanRevoked) continue;
          remainingPubs[uid] = await fetchRecipientPublicKey(uid);
        }
      }

      // Rotate to a brand-new 256-bit Item_DEK
      newDek = secureRandomBytes(32);
      final rotatedEnv = E2eeEnvelopeCrypto.encryptItem(
        plaintext: plainPayload,
        documentPath: docPath,
        recipientPublicKeys: remainingPubs,
        existingDek: newDek,
        schemaVersion: existingEnv.schemaVersion,
      );

      String? newPhotoNonceB64;
      String? newPhotoCtB64;
      if (plainPhoto != null) {
        final photoNonce = secureRandomBytes(XChaCha20Poly1305.nonceLength);
        final photoCt = XChaCha20Poly1305.encrypt(
          key: newDek,
          nonce: photoNonce,
          plaintext: plainPhoto,
          aad: Uint8List.fromList(
            utf8.encode(
              E2eeEnvelopeCrypto.formatItemAad(
                '$docPath/photo',
                schemaVersion: existingEnv.schemaVersion,
              ),
            ),
          ),
        );
        newPhotoNonceB64 = base64Encode(photoNonce);
        newPhotoCtB64 = base64Encode(photoCt);
      }

      final updatedFields = <String, dynamic>{
        'owner_uid': _fsString(ownerUid),
        'item_type': _fsString(_readString(rawFields['item_type']) ?? 'osm_record'),
        'schema_version': {'integerValue': '${rotatedEnv.schemaVersion}'},
        'ciphertext': _fsString(rotatedEnv.ciphertextB64),
        'nonce': _fsString(rotatedEnv.nonceB64),
        'recipients': _encodeRecipientsMap(rotatedEnv.recipients),
        'recipient_uids': _encodeStringArray(rotatedEnv.recipients.keys.toList()),
        if (newPhotoNonceB64 != null) 'photo_nonce': _fsString(newPhotoNonceB64),
        if (newPhotoCtB64 != null) 'photo_ciphertext': _fsString(newPhotoCtB64),
        'updated_at': _fsTimestamp(DateTime.now().toUtc()),
      };

      final uri = _documentUri('items', itemId);
      final resp = await _sendWithAppCheckRetry(
        'PATCH $docPath (revoke+rotate)',
        (headers) => _client
            .patch(uri, headers: headers, body: jsonEncode({'fields': updatedFields}))
            .timeout(const Duration(seconds: 30)),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception(_friendlyFirestoreError(resp.statusCode, resp.body));
      }
    } finally {
      zeroizeAll([oldDek, newDek, plainPayload, plainPhoto]);
    }
  }

  // --- Step 4: Optional Link Sharing (`shares/{shareId}#k={base64url_item_dek}`) ---

  /// Creates an optional zero-knowledge share link for [record] where the
  /// 256-bit `Item_DEK` is placed strictly in the URL `#k=` fragment.
  Future<ShareLinkBundle> createShareLinkForRecord(
    OsmRecord record, {
    String? photoDataUriOverride,
    String? domain,
  }) async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured.');
    }
    final ownerUid = _requireUid();
    final photoUri =
        photoDataUriOverride ?? await readPhotoAsDataUri(record.photoPath);
    final payloadJson = jsonEncode({
      'item_type': 'osm_record',
      'record': encodeRecordToFirestoreFields(
        record,
        ownerUid: ownerUid,
        photoDataUri: photoUri,
      ),
    });
    return _uploadSharePayload(
      ownerUid: ownerUid,
      itemType: 'osm_record',
      plaintext: Uint8List.fromList(utf8.encode(payloadJson)),
      domain: domain ?? AppEnvConfig.shareDomain,
    );
  }

  /// Creates an optional zero-knowledge share link for [trail].
  Future<ShareLinkBundle> createShareLinkForTrail(
    HikeTrail trail, {
    String? domain,
  }) async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured.');
    }
    final ownerUid = _requireUid();
    final payloadJson = jsonEncode({
      'item_type': 'trail',
      'trail': encodeTrailToFirestoreFields(trail, ownerUid: ownerUid),
    });
    return _uploadSharePayload(
      ownerUid: ownerUid,
      itemType: 'trail',
      plaintext: Uint8List.fromList(utf8.encode(payloadJson)),
      domain: domain ?? AppEnvConfig.shareDomain,
    );
  }

  Future<ShareLinkBundle> _uploadSharePayload({
    required String ownerUid,
    required String itemType,
    required Uint8List plaintext,
    required String domain,
  }) async {
    final shareId = const Uuid().v4().replaceAll('-', '');
    final bundle = E2eeEnvelopeCrypto.createShareLinkBundle(
      plaintext: plaintext,
      shareId: shareId,
      domain: domain,
    );
    // Do NOT publish private `item_id` in plaintext on public `shares/{shareId}`.
    final fields = <String, dynamic>{
      'owner_uid': _fsString(ownerUid),
      'item_type': _fsString(itemType),
      'schema_version': const {'integerValue': '1'},
      'ciphertext': _fsString(bundle.ciphertextB64),
      'nonce': _fsString(bundle.nonceB64),
      'created_at': _fsTimestamp(DateTime.now().toUtc()),
    };
    final uri = _documentUri('shares', shareId);
    final resp = await _sendWithAppCheckRetry(
      'PATCH shares/$shareId',
      (headers) => _client
          .patch(uri, headers: headers, body: jsonEncode({'fields': fields}))
          .timeout(const Duration(seconds: 30)),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(_friendlyFirestoreError(resp.statusCode, resp.body));
    }
    return bundle;
  }

  /// Fetches `shares/{shareId}` from Firestore and decrypts it locally using
  /// the `#k=` fragment `Item_DEK` (which is never transmitted to the server).
  Future<DecryptedSharedLink> openShareLink(String shareUrl) async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured.');
    }
    final parsed = E2eeEnvelopeCrypto.parseShareUrl(shareUrl);
    try {
      final uri = _documentUri('shares', parsed.shareId);
      final resp = await _sendWithAppCheckRetry(
        'GET shares/${parsed.shareId}',
        (headers) => _client
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 25)),
      );
      if (resp.statusCode == 404) {
        throw StateError('Share link not found or has been revoked.');
      }
      final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception(_friendlyFirestoreError(resp.statusCode, bodyText));
      }
      final decoded = jsonDecode(bodyText) as Map<String, dynamic>;
      final fields = decoded['fields'] as Map<String, dynamic>? ?? const {};
      final ctB64 = _readString(fields['ciphertext']) ?? '';
      final nonceB64 = _readString(fields['nonce']) ?? '';
      final schemaVersion =
          int.tryParse(fields['schema_version']?['integerValue']?.toString() ?? '') ??
              1;
      final plainBytes = E2eeEnvelopeCrypto.decryptSharePayload(
        shareId: parsed.shareId,
        ciphertextB64: ctB64,
        nonceB64: nonceB64,
        itemDek: parsed.itemDek,
        schemaVersion: schemaVersion,
      );
      final Map<String, dynamic> payload;
      try {
        payload =
            jsonDecode(utf8.decode(plainBytes)) as Map<String, dynamic>;
      } finally {
        zeroize(plainBytes);
      }
      final itemType = payload['item_type']?.toString() ?? 'osm_record';
      if (itemType == 'trail' && payload['trail'] is Map) {
        final trail = decodeTrailFromFirestoreFields(
          Map<String, dynamic>.from(payload['trail'] as Map),
        );
        return DecryptedSharedLink(
          shareId: parsed.shareId,
          itemType: 'trail',
          trail: trail,
        );
      }
      final rec = payload['record'] is Map
          ? decodeRecordFromFirestoreFields(
              Map<String, dynamic>.from(payload['record'] as Map),
            )
          : null;
      return DecryptedSharedLink(
        shareId: parsed.shareId,
        itemType: 'osm_record',
        record: rec,
      );
    } finally {
      parsed.zeroizeKey();
    }
  }

  Future<void> revokeShareLink(String shareId) async {
    if (!isConfigured) return;
    _requireUid();
    final uri = _documentUri('shares', shareId.trim());
    final resp = await _sendWithAppCheckRetry(
      'DELETE shares/$shareId',
      (headers) => _client
          .delete(uri, headers: headers)
          .timeout(const Duration(seconds: 15)),
    );
    if (resp.statusCode == 404) return;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(_friendlyFirestoreError(resp.statusCode, resp.body));
    }
  }

  // --- Delete (Single & Full Cloud Wipe) ---

  Future<void> deleteRecord(String recordId) =>
      _deleteItem(recordItemId(recordId));

  Future<void> deleteTrail(String trailId) =>
      _deleteItem(trailItemId(trailId));

  Future<void> _deleteItem(String itemId) async {
    if (!isConfigured) return;
    final uid = _requireUid();

    // Check existence first via GET (where `allow get` permits `resource == null`
    // and returns HTTP 404). Sending DELETE directly to a non-existent document
    // causes Firestore Rules evaluating `resource.data.owner_uid` to fail with
    // 403 Missing or insufficient permissions.
    final existing = await _fetchRawItemDocument(itemId);
    if (existing == null) return;
    final ownerField = existing['owner_uid'];
    final ownerUid = ownerField is Map
        ? (ownerField['stringValue']?.toString().trim() ?? '')
        : '';
    if (ownerUid.isNotEmpty && ownerUid != uid) return;

    final uri = _documentUri('items', itemId);
    final resp = await _sendWithAppCheckRetry(
      'DELETE items/$itemId',
      (headers) => _client
          .delete(uri, headers: headers)
          .timeout(const Duration(seconds: 12)),
    );
    if (resp.statusCode == 404) return;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(_friendlyFirestoreError(resp.statusCode, resp.body));
    }
  }

  /// Migrates any legacy unencrypted documents sitting under
  /// `users/{uid}/osm_records` or `users/{uid}/trails` into E2EE
  /// `items/{itemId}` (`XChaCha20-Poly1305` + `X25519`), then permanently
  /// deletes the plaintext legacy documents from Firestore.
  Future<({int migratedRecords, int migratedTrails, int deletedLegacy})>
      migrateAndPurgeLegacyPlaintextCollections() async {
    if (!isConfigured || !isSignedIn || !isVaultUnlocked) {
      return (migratedRecords: 0, migratedTrails: 0, deletedLegacy: 0);
    }
    final uid = _requireUid();
    int migratedRecords = 0;
    int migratedTrails = 0;
    int deletedLegacy = 0;

    // 1. Legacy users/{uid}/osm_records
    final legacyRecDocs = await _listRawCollectionDocs('users/$uid/osm_records');
    for (final doc in legacyRecDocs) {
      final fields = doc['fields'] as Map<String, dynamic>?;
      final docId = (doc['name']?.toString() ?? '').split('/').last.trim();
      if (docId.isEmpty) continue;
      try {
        if (fields == null || fields['e2eeVersion'] != null) {
          // Skip legacy v1 E2EE documents without deleting them so encrypted
          // backups are never silently lost.
          continue;
        }
        final parsed = decodeRecordFromFirestoreFields(
          fields,
          fallbackId: docId,
        );
        if (parsed != null) {
          final existingE2ee =
              await _fetchRawItemDocument(recordItemId(parsed.record.id));
          if (existingE2ee == null) {
            await syncRecord(
              parsed.record,
              photoDataUriOverride: parsed.photoDataUri,
            );
            migratedRecords++;
          }
        }
        await _deleteRawDocument('users/$uid/osm_records', docId);
        deletedLegacy++;
      } catch (e) {
        debugPrint('[EdgeMapper] Legacy record purge skipped ($docId): $e');
      }
    }

    // 2. Legacy users/{uid}/trails
    final legacyTrailDocs = await _listRawCollectionDocs('users/$uid/trails');
    for (final doc in legacyTrailDocs) {
      final fields = doc['fields'] as Map<String, dynamic>?;
      final docId = (doc['name']?.toString() ?? '').split('/').last.trim();
      if (docId.isEmpty) continue;
      try {
        if (fields == null || fields['e2eeVersion'] != null) {
          continue;
        }
        final parsed = decodeTrailFromFirestoreFields(
          fields,
          fallbackId: docId,
        );
        if (parsed != null) {
          final existingE2ee =
              await _fetchRawItemDocument(trailItemId(parsed.id));
          if (existingE2ee == null) {
            await syncTrail(parsed);
            migratedTrails++;
          }
        }
        await _deleteRawDocument('users/$uid/trails', docId);
        deletedLegacy++;
      } catch (e) {
        debugPrint('[EdgeMapper] Legacy trail purge skipped ($docId): $e');
      }
    }

    return (
      migratedRecords: migratedRecords,
      migratedTrails: migratedTrails,
      deletedLegacy: deletedLegacy,
    );
  }

  Future<List<Map<String, dynamic>>> _listRawCollectionDocs(
    String collectionPath,
  ) async {
    final projectId = activeProjectId!;
    final out = <Map<String, dynamic>>[];
    String? pageToken;
    try {
      do {
        final query = <String, String>{
          'pageSize': '50',
          if (pageToken != null && pageToken.isNotEmpty) 'pageToken': pageToken,
        };
        final uri = Uri.https(
          'firestore.googleapis.com',
          '/v1/projects/$projectId/databases/(default)/documents/$collectionPath',
          query,
        );
        final resp = await _sendWithAppCheckRetry(
          'GET $collectionPath',
          (headers) => _client
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 25)),
        );
        if (resp.statusCode == 404 || resp.statusCode == 403) return out;
        if (resp.statusCode < 200 || resp.statusCode >= 300) return out;
        final decoded =
            jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true))
                as Map<String, dynamic>;
        final docs = decoded['documents'] as List? ?? const [];
        for (final d in docs) {
          if (d is Map) out.add(Map<String, dynamic>.from(d));
        }
        pageToken = decoded['nextPageToken']?.toString();
      } while (pageToken != null && pageToken.isNotEmpty);
    } catch (_) {}
    return out;
  }

  Future<void> _deleteRawDocument(String collectionPath, String docId) async {
    final uri = _documentUri(collectionPath, docId);
    final resp = await _sendWithAppCheckRetry(
      'DELETE $collectionPath/$docId',
      (headers) => _client
          .delete(uri, headers: headers)
          .timeout(const Duration(seconds: 12)),
    );
    if (resp.statusCode == 404) return;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(_friendlyFirestoreError(resp.statusCode, resp.body));
    }
  }

  /// Permanently deletes ALL encrypted items owned by the current user in
  /// Cloud Firestore (`items/{itemId}`), plus any legacy plaintext documents
  /// under `users/{uid}/osm_records` and `users/{uid}/trails`, leaving local
  /// device data untouched.
  Future<CloudWipeResult> deleteAllCloudData() async {
    if (!isConfigured) {
      throw StateError('Firebase project is not configured in this build.');
    }
    final uid = _requireUid();
    final errors = <String>[];
    int recordsDeleted = 0;
    int trailsDeleted = 0;

    final docs = await _queryAccessibleItems(uid);
    final ownedItems = <({String id, String type})>[];
    for (final doc in docs) {
      final fields = doc['fields'] as Map<String, dynamic>?;
      if (fields == null) continue;
      if (_readString(fields['owner_uid']) != uid) continue;
      final itemId = (doc['name']?.toString() ?? '').split('/').last.trim();
      final itemType = _readString(fields['item_type']) ?? 'osm_record';
      if (itemId.isNotEmpty) {
        ownedItems.add((id: itemId, type: itemType));
      }
    }

    const batchSize = 5;
    for (int i = 0; i < ownedItems.length; i += batchSize) {
      final chunk = ownedItems.sublist(
        i,
        (i + batchSize) > ownedItems.length ? ownedItems.length : i + batchSize,
      );
      await Future.wait(
        chunk.map((item) async {
          try {
            await _deleteItem(item.id);
            if (item.type == 'trail') {
              trailsDeleted++;
            } else {
              recordsDeleted++;
            }
          } catch (e) {
            errors.add('Delete ${item.id}: $e');
          }
        }),
      );
    }

    // Also delete any legacy unencrypted docs under users/{uid}/osm_records & trails
    for (final doc in await _listRawCollectionDocs('users/$uid/osm_records')) {
      final docId = (doc['name']?.toString() ?? '').split('/').last.trim();
      if (docId.isEmpty) continue;
      try {
        await _deleteRawDocument('users/$uid/osm_records', docId);
        recordsDeleted++;
      } catch (e) {
        errors.add('Delete legacy record $docId: $e');
      }
    }
    for (final doc in await _listRawCollectionDocs('users/$uid/trails')) {
      final docId = (doc['name']?.toString() ?? '').split('/').last.trim();
      if (docId.isEmpty) continue;
      try {
        await _deleteRawDocument('users/$uid/trails', docId);
        trailsDeleted++;
      } catch (e) {
        errors.add('Delete legacy trail $docId: $e');
      }
    }

    return CloudWipeResult(
      recordsDeleted: recordsDeleted,
      trailsDeleted: trailsDeleted,
      errors: errors,
    );
  }

  // --- Firestore REST Helpers ---

  String _requireUid() {
    final uid = currentUid;
    if (uid == null || uid.isEmpty) {
      throw const FirebaseAuthRequiredException();
    }
    return uid;
  }

  X25519KeyPair _requireUnlockedKeyPair() {
    final kp = _unlockedKeyPair;
    if (kp == null) {
      throw const FirebaseAuthRequiredException(
        'Unlock your E2EE Vault with Passkey (PRF) or your Recovery Key first.',
      );
    }
    return kp;
  }

  Future<Map<String, dynamic>?> _fetchRawItemDocument(String itemId) async {
    final uri = _documentUri('items', itemId);
    final resp = await _sendWithAppCheckRetry(
      'GET items/$itemId',
      (headers) => _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 20)),
    );
    if (resp.statusCode == 404) return null;
    final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(_friendlyFirestoreError(resp.statusCode, bodyText));
    }
    final decoded = jsonDecode(bodyText) as Map<String, dynamic>;
    return decoded['fields'] as Map<String, dynamic>?;
  }

  /// Queries all `items` documents where `recipient_uids` array contains [uid].
  Future<List<Map<String, dynamic>>> _queryAccessibleItems(String uid) async {
    final projectId = activeProjectId!;
    final uri = Uri.https(
      'firestore.googleapis.com',
      '/v1/projects/$projectId/databases/(default)/documents:runQuery',
    );
    final queryBody = jsonEncode({
      'structuredQuery': {
        'from': [
          {'collectionId': 'items'},
        ],
        'where': {
          'fieldFilter': {
            'field': {'fieldPath': 'recipient_uids'},
            'op': 'ARRAY_CONTAINS',
            'value': {'stringValue': uid},
          },
        },
      },
    });
    final resp = await _sendWithAppCheckRetry(
      'POST :runQuery items',
      (headers) => _client
          .post(uri, headers: headers, body: queryBody)
          .timeout(const Duration(seconds: 45)),
    );
    if (resp.statusCode == 404) return const [];
    final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(_friendlyFirestoreError(resp.statusCode, bodyText));
    }
    final decoded = jsonDecode(bodyText);
    if (decoded is! List) return const [];
    final docs = <Map<String, dynamic>>[];
    for (final row in decoded) {
      if (row is Map && row['document'] is Map) {
        docs.add(Map<String, dynamic>.from(row['document'] as Map));
      }
    }
    return docs;
  }

  Future<Map<String, String>> buildAuthHeaders({
    bool forceRefreshAppCheck = false,
    bool forceRefreshAuth = false,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };

    if (_idTokenOverride != null) {
      final token = await _idTokenOverride.call(forceRefresh: forceRefreshAuth);
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    } else if (FirebaseBootstrap.isConfigured && Firebase.apps.isNotEmpty) {
      final appId = Firebase.app().options.appId;
      if (appId.isNotEmpty) {
        headers['x-firebase-gmpid'] = appId;
      }

      try {
        if (!kIsWeb) {
          final token = await _getRestIdToken(forceRefresh: forceRefreshAuth);
          if (token != null && token.isNotEmpty) {
            headers['Authorization'] = 'Bearer $token';
          }
        } else {
          final user = _currentFirebaseUser;
          if (user != null) {
            final token = await user.getIdToken(forceRefreshAuth);
            if (token != null && token.isNotEmpty) {
              headers['Authorization'] = 'Bearer $token';
            }
          }
        }
      } catch (e) {
        debugPrint('[EdgeMapper] Firestore Auth ID token error: $e');
      }

      final appCheckToken = await AttestGateAppCheck.getHeaderToken(
        forceRefresh: forceRefreshAppCheck,
      );
      if (appCheckToken != null && appCheckToken.isNotEmpty) {
        headers['X-Firebase-AppCheck'] = appCheckToken;
      }
    }
    return headers;
  }

  Future<http.Response> _sendWithAppCheckRetry(
    String operation,
    Future<http.Response> Function(Map<String, String> headers) request,
  ) async {
    final headers = await buildAuthHeaders();
    if (AttestGateAppCheck.isInitialized &&
        !headers.containsKey('X-Firebase-AppCheck') &&
        AttestGateAppCheck.lastHeaderTokenError != null) {
      throw Exception(
        'App Check token unavailable before Firestore $operation: ${AttestGateAppCheck.lastHeaderTokenError}',
      );
    }
    final resp = await request(headers);
    if ((resp.statusCode == 401 || resp.statusCode == 403) &&
        (AttestGateAppCheck.isInitialized ||
            headers.containsKey('Authorization'))) {
      final refreshedHeaders = await buildAuthHeaders(
        forceRefreshAppCheck: true,
        forceRefreshAuth: true,
      );
      if (AttestGateAppCheck.isInitialized &&
          !refreshedHeaders.containsKey('X-Firebase-AppCheck') &&
          AttestGateAppCheck.lastHeaderTokenError != null) {
        throw Exception(
          'App Check token refresh failed during Firestore $operation: ${AttestGateAppCheck.lastHeaderTokenError}',
        );
      }
      final appCheckChanged = refreshedHeaders['X-Firebase-AppCheck'] != null &&
          refreshedHeaders['X-Firebase-AppCheck'] !=
              headers['X-Firebase-AppCheck'];
      final authChanged = refreshedHeaders['Authorization'] != null &&
          refreshedHeaders['Authorization'] != headers['Authorization'];
      if (appCheckChanged || authChanged) {
        return request(refreshedHeaders);
      }
    }
    return resp;
  }

  Uri _documentUri(
    String collectionPath,
    String docId, {
    List<String>? updateMaskFieldPaths,
  }) {
    final projectId = activeProjectId!;
    final cleanDocId = docId.trim();
    if (!_safeSegmentPattern.hasMatch(cleanDocId)) {
      throw ArgumentError.value(docId, 'docId', 'Invalid Firestore document ID.');
    }
    final colSegs = collectionPath.split('/');
    if (colSegs.isEmpty ||
        colSegs.any((s) => !_safeSegmentPattern.hasMatch(s))) {
      throw ArgumentError.value(
        collectionPath,
        'collectionPath',
        'Invalid Firestore collection path.',
      );
    }
    final path =
        '/v1/projects/$projectId/databases/(default)/documents/$collectionPath/$cleanDocId';
    if (updateMaskFieldPaths == null || updateMaskFieldPaths.isEmpty) {
      return Uri.https('firestore.googleapis.com', path);
    }
    return Uri.https(
      'firestore.googleapis.com',
      path,
      {'updateMask.fieldPaths': updateMaskFieldPaths},
    );
  }

  @override
  void dispose() {
    _clearVolatileKeyPair();
    prefs.removeListener(_handlePrefsChange);
    _authSub?.cancel();
    super.dispose();
  }

  // --- Firestore Envelope Serializers & Deserializers ---

  static Map<String, dynamic> encodeKeyringToFirestoreFields(
    UserKeyring keyring,
  ) {
    return {
      'x25519_public_key': _fsString(keyring.x25519PublicKeyB64),
      if (keyring.wrappedPrivPrf != null)
        'wrapped_priv_prf': {
          'mapValue': {
            'fields': {
              'ciphertext': _fsString(keyring.wrappedPrivPrf!.ciphertextB64),
              'nonce': _fsString(keyring.wrappedPrivPrf!.nonceB64),
              'salt': _fsString(keyring.wrappedPrivPrf!.saltB64),
            },
          },
        },
      if (keyring.wrappedPrivRecovery != null)
        'wrapped_priv_recovery': {
          'mapValue': {
            'fields': {
              'ciphertext':
                  _fsString(keyring.wrappedPrivRecovery!.ciphertextB64),
              'nonce': _fsString(keyring.wrappedPrivRecovery!.nonceB64),
              'kdf_salt': _fsString(keyring.wrappedPrivRecovery!.kdfSaltB64),
              'kdf_params': {
                'mapValue': {
                  'fields': {
                    'alg': _fsString('argon2id'),
                    'm': {
                      'integerValue':
                          '${keyring.wrappedPrivRecovery!.kdfParams.memoryKiB}',
                    },
                    't': {
                      'integerValue':
                          '${keyring.wrappedPrivRecovery!.kdfParams.iterations}',
                    },
                    'p': {
                      'integerValue':
                          '${keyring.wrappedPrivRecovery!.kdfParams.parallelism}',
                    },
                    'dkLen': {
                      'integerValue':
                          '${keyring.wrappedPrivRecovery!.kdfParams.keyLength}',
                    },
                  },
                },
              },
            },
          },
        },
      'updated_at': _fsTimestamp(DateTime.now().toUtc()),
    };
  }

  static UserKeyring? decodeKeyringFromFirestoreFields(
    String uid,
    Map<String, dynamic> fields,
  ) {
    final pubKey = _readString(fields['x25519_public_key']);
    if (pubKey == null || pubKey.isEmpty) return null;

    WrappedPrfKeySlot? prfSlot;
    final prfMap = fields['wrapped_priv_prf']?['mapValue']?['fields'];
    if (prfMap is Map) {
      final ct = _readString(prfMap['ciphertext']) ?? '';
      final nonce = _readString(prfMap['nonce']) ?? '';
      final salt = _readString(prfMap['salt']) ?? '';
      if (ct.isNotEmpty && nonce.isNotEmpty && salt.isNotEmpty) {
        prfSlot = WrappedPrfKeySlot(
          ciphertextB64: ct,
          nonceB64: nonce,
          saltB64: salt,
        );
      }
    }

    WrappedRecoveryKeySlot? recSlot;
    final recMap = fields['wrapped_priv_recovery']?['mapValue']?['fields'];
    if (recMap is Map) {
      final ct = _readString(recMap['ciphertext']) ?? '';
      final nonce = _readString(recMap['nonce']) ?? '';
      final kdfSalt = _readString(recMap['kdf_salt']) ?? '';
      final pMap = recMap['kdf_params']?['mapValue']?['fields'];
      final params = pMap is Map
          ? Argon2Params(
              memoryKiB: _readInt(pMap['m']) ?? 65536,
              iterations: _readInt(pMap['t']) ?? 3,
              parallelism: _readInt(pMap['p']) ?? 1,
              keyLength: _readInt(pMap['dkLen']) ?? 32,
            )
          : Argon2Params.defaultProduction;
      if (ct.isNotEmpty && nonce.isNotEmpty && kdfSalt.isNotEmpty) {
        // Reject out-of-bounds untrusted KDF parameters from Firestore.
        params.validateBounds(requiredKeyLength: 32);
        recSlot = WrappedRecoveryKeySlot(
          ciphertextB64: ct,
          nonceB64: nonce,
          kdfSaltB64: kdfSalt,
          kdfParams: params,
        );
      }
    }

    return UserKeyring(
      uid: uid,
      x25519PublicKeyB64: pubKey,
      wrappedPrivPrf: prfSlot,
      wrappedPrivRecovery: recSlot,
    );
  }

  /// Encrypts an [OsmRecord] (and optional [photoDataUri] separately under the
  /// same `Item_DEK` with AAD `items/rec_{id}/photo|v1`) into `items/{itemId}`
  /// Firestore REST fields.
  static Map<String, dynamic> encodeEncryptedRecordItemFields({
    required OsmRecord record,
    required String ownerUid,
    required Map<String, Uint8List> recipientPublicKeys,
    Uint8List? existingDek,
    Map<String, WrappedDekEnvelope>? preservedRecipients,
    String? photoDataUri,
    int schemaVersion = 1,
  }) {
    final itemId = recordItemId(record.id);
    final docPath = itemDocumentPath(itemId);
    final ownsDek = existingDek == null;
    final itemDek = existingDek ?? secureRandomBytes(32);

    try {
      final metaJson = jsonEncode(
        encodeRecordToFirestoreFields(record, ownerUid: ownerUid),
      );
      final metaBytes = Uint8List.fromList(utf8.encode(metaJson));
      final envelope = preservedRecipients != null
          ? EncryptedItemEnvelope(
              documentPath: docPath,
              schemaVersion: schemaVersion,
              nonceB64: () {
                final n = secureRandomBytes(XChaCha20Poly1305.nonceLength);
                return base64Encode(n);
              }(),
              ciphertextB64: '',
              recipients: preservedRecipients,
            )
          : E2eeEnvelopeCrypto.encryptItem(
              plaintext: metaBytes,
              documentPath: docPath,
              recipientPublicKeys: recipientPublicKeys,
              existingDek: itemDek,
              schemaVersion: schemaVersion,
            );

      final String nonceB64;
      final String ctB64;
      if (preservedRecipients != null) {
        final n = Uint8List.fromList(base64Decode(envelope.nonceB64));
        final ct = XChaCha20Poly1305.encrypt(
          key: itemDek,
          nonce: n,
          plaintext: metaBytes,
          aad: Uint8List.fromList(
            utf8.encode(
              E2eeEnvelopeCrypto.formatItemAad(
                docPath,
                schemaVersion: schemaVersion,
              ),
            ),
          ),
        );
        nonceB64 = envelope.nonceB64;
        ctB64 = base64Encode(ct);
      } else {
        nonceB64 = envelope.nonceB64;
        ctB64 = envelope.ciphertextB64;
      }
      zeroize(metaBytes);

      String? photoNonceB64;
      String? photoCtB64;
      if (photoDataUri != null && photoDataUri.isNotEmpty) {
        final photoNonce = secureRandomBytes(XChaCha20Poly1305.nonceLength);
        final photoBytes = Uint8List.fromList(utf8.encode(photoDataUri));
        final photoCt = XChaCha20Poly1305.encrypt(
          key: itemDek,
          nonce: photoNonce,
          plaintext: photoBytes,
          aad: Uint8List.fromList(
            utf8.encode(
              E2eeEnvelopeCrypto.formatItemAad(
                '$docPath/photo',
                schemaVersion: schemaVersion,
              ),
            ),
          ),
        );
        zeroize(photoBytes);
        photoNonceB64 = base64Encode(photoNonce);
        photoCtB64 = base64Encode(photoCt);
      }

      return {
        'owner_uid': _fsString(ownerUid),
        'item_type': _fsString('osm_record'),
        'schema_version': {'integerValue': '$schemaVersion'},
        'ciphertext': _fsString(ctB64),
        'nonce': _fsString(nonceB64),
        'recipients': _encodeRecipientsMap(envelope.recipients),
        'recipient_uids': _encodeStringArray(envelope.recipients.keys.toList()),
        if (photoNonceB64 != null) 'photo_nonce': _fsString(photoNonceB64),
        if (photoCtB64 != null) 'photo_ciphertext': _fsString(photoCtB64),
        'updated_at': _fsTimestamp(record.updatedAt),
      };
    } finally {
      if (ownsDek) zeroize(itemDek);
    }
  }

  static RemoteOsmRecord? decodeEncryptedRecordItemFields({
    required String itemId,
    required Map<String, dynamic> fields,
    required String recipientUid,
    required Uint8List recipientPrivateKey,
    Uint8List? recipientPublicKey,
  }) {
    final docPath = itemDocumentPath(itemId);
    final env = decodeEncryptedItemEnvelope(docPath, fields);
    if (env == null) return null;
    final wrapped = env.recipients[recipientUid];
    if (wrapped == null) return null;

    final itemDek = E2eeEnvelopeCrypto.unwrapItemDek(
      envelope: wrapped,
      recipientPrivateKey: recipientPrivateKey,
      recipientPublicKey: recipientPublicKey,
      documentPath: docPath,
      recipientUid: recipientUid,
      schemaVersion: env.schemaVersion,
    );
    try {
      final metaPlain = XChaCha20Poly1305.decrypt(
        key: itemDek,
        nonce: Uint8List.fromList(base64Decode(env.nonceB64)),
        ciphertextWithTag: Uint8List.fromList(base64Decode(env.ciphertextB64)),
        aad: Uint8List.fromList(
          utf8.encode(
            E2eeEnvelopeCrypto.formatItemAad(
              docPath,
              schemaVersion: env.schemaVersion,
            ),
          ),
        ),
      );
      final Map<String, dynamic> metaMap;
      try {
        metaMap =
            Map<String, dynamic>.from(jsonDecode(utf8.decode(metaPlain)) as Map);
      } finally {
        zeroize(metaPlain);
      }

      final fallbackRecordId =
          itemId.startsWith('rec_') ? itemId.substring(4) : itemId;
      final parsedMeta = decodeRecordFromFirestoreFields(
        metaMap,
        fallbackId: fallbackRecordId,
      );
      if (parsedMeta == null) return null;

      String? photoDataUri = parsedMeta.photoDataUri;
      final photoNonceB64 = _readString(fields['photo_nonce']);
      final photoCtB64 = _readString(fields['photo_ciphertext']);
      if (photoNonceB64 != null && photoCtB64 != null) {
        final photoPlain = XChaCha20Poly1305.decrypt(
          key: itemDek,
          nonce: Uint8List.fromList(base64Decode(photoNonceB64)),
          ciphertextWithTag: Uint8List.fromList(base64Decode(photoCtB64)),
          aad: Uint8List.fromList(
            utf8.encode(
              E2eeEnvelopeCrypto.formatItemAad(
                '$docPath/photo',
                schemaVersion: env.schemaVersion,
              ),
            ),
          ),
        );
        try {
          photoDataUri = utf8.decode(photoPlain);
        } finally {
          zeroize(photoPlain);
        }
      }

      return RemoteOsmRecord(
        record: parsedMeta.record,
        photoDataUri: photoDataUri,
        ownerUid: _readString(fields['owner_uid']),
        recipientUids: env.recipients.keys.toList(),
      );
    } finally {
      zeroize(itemDek);
    }
  }

  static Map<String, dynamic> encodeEncryptedTrailItemFields({
    required HikeTrail trail,
    required String ownerUid,
    required Map<String, Uint8List> recipientPublicKeys,
    Uint8List? existingDek,
    Map<String, WrappedDekEnvelope>? preservedRecipients,
    int schemaVersion = 1,
  }) {
    final itemId = trailItemId(trail.id);
    final docPath = itemDocumentPath(itemId);
    final payloadBytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode(encodeTrailToFirestoreFields(trail, ownerUid: ownerUid)),
      ),
    );
    final itemDek = existingDek != null
        ? Uint8List.fromList(existingDek)
        : secureRandomBytes(32);
    try {
      final nonce = secureRandomBytes(XChaCha20Poly1305.nonceLength);
      final aad = Uint8List.fromList(
        utf8.encode(
          E2eeEnvelopeCrypto.formatItemAad(
            docPath,
            schemaVersion: schemaVersion,
          ),
        ),
      );
      final ct = XChaCha20Poly1305.encrypt(
        key: itemDek,
        nonce: nonce,
        plaintext: payloadBytes,
        aad: aad,
      );
      final recipients = <String, WrappedDekEnvelope>{};
      if (existingDek != null &&
          preservedRecipients != null &&
          preservedRecipients.isNotEmpty) {
        recipients.addAll(preservedRecipients);
      } else {
        for (final entry in recipientPublicKeys.entries) {
          recipients[entry.key] = E2eeEnvelopeCrypto.wrapItemDek(
            itemDek: itemDek,
            recipientPublicKey: entry.value,
            documentPath: docPath,
            recipientUid: entry.key,
            schemaVersion: schemaVersion,
          );
        }
      }
      return {
        'owner_uid': _fsString(ownerUid),
        'item_type': _fsString('trail'),
        'schema_version': {'integerValue': '$schemaVersion'},
        'ciphertext': _fsString(base64Encode(ct)),
        'nonce': _fsString(base64Encode(nonce)),
        'recipients': _encodeRecipientsMap(recipients),
        'recipient_uids': _encodeStringArray(recipients.keys.toList()),
        'updated_at': _fsTimestamp(DateTime.now().toUtc()),
      };
    } finally {
      zeroize(payloadBytes);
      zeroize(itemDek);
    }
  }

  static HikeTrail? decodeEncryptedTrailItemFields({
    required String itemId,
    required Map<String, dynamic> fields,
    required String recipientUid,
    required Uint8List recipientPrivateKey,
    Uint8List? recipientPublicKey,
  }) {
    final docPath = itemDocumentPath(itemId);
    final env = decodeEncryptedItemEnvelope(docPath, fields);
    if (env == null) return null;
    final plainBytes = E2eeEnvelopeCrypto.decryptItem(
      envelope: env,
      recipientUid: recipientUid,
      recipientPrivateKey: recipientPrivateKey,
      recipientPublicKey: recipientPublicKey,
      expectedDocumentPath: docPath,
    );
    try {
      final trailFields =
          Map<String, dynamic>.from(jsonDecode(utf8.decode(plainBytes)) as Map);
      final fallbackTrailId =
          itemId.startsWith('trail_') ? itemId.substring(6) : itemId;
      return decodeTrailFromFirestoreFields(
        trailFields,
        fallbackId: fallbackTrailId,
      );
    } finally {
      zeroize(plainBytes);
    }
  }

  static EncryptedItemEnvelope? decodeEncryptedItemEnvelope(
    String documentPath,
    Map<String, dynamic> fields,
  ) {
    final ctB64 = _readString(fields['ciphertext']);
    final nonceB64 = _readString(fields['nonce']);
    final schemaVersion = _readInt(fields['schema_version']) ?? 1;
    if (ctB64 == null || nonceB64 == null) return null;

    final recipients = <String, WrappedDekEnvelope>{};
    final rawRecips = fields['recipients']?['mapValue']?['fields'];
    if (rawRecips is Map) {
      rawRecips.forEach((uid, val) {
        final envFields =
            val is Map ? (val['mapValue'] is Map ? val['mapValue']['fields'] : null) : null;
        if (envFields is Map) {
          final epk = _readString(envFields['epk']) ?? '';
          final n = _readString(envFields['nonce']) ?? '';
          final ct = _readString(envFields['ciphertext']) ?? '';
          if (epk.isNotEmpty && n.isNotEmpty && ct.isNotEmpty) {
            recipients[uid.toString()] = WrappedDekEnvelope(
              epkB64: epk,
              nonceB64: n,
              ciphertextB64: ct,
            );
          }
        }
      });
    }
    if (recipients.isEmpty) return null;

    return EncryptedItemEnvelope(
      documentPath: documentPath,
      schemaVersion: schemaVersion,
      ciphertextB64: ctB64,
      nonceB64: nonceB64,
      recipients: recipients,
    );
  }

  static Map<String, dynamic> _encodeRecipientsMap(
    Map<String, WrappedDekEnvelope> recipients,
  ) {
    return {
      'mapValue': {
        'fields': {
          for (final entry in recipients.entries)
            entry.key: {
              'mapValue': {
                'fields': {
                  'epk': _fsString(entry.value.epkB64),
                  'nonce': _fsString(entry.value.nonceB64),
                  'ciphertext': _fsString(entry.value.ciphertextB64),
                },
              },
            },
        },
      },
    };
  }

  static Map<String, dynamic> _encodeStringArray(List<String> values) => {
        'arrayValue': {
          'values': values.map(_fsString).toList(),
        },
      };

  static List<String> _readStringArray(dynamic field) {
    final arrayVal = field is Map ? field['arrayValue'] : null;
    final raw = arrayVal is Map ? arrayVal['values'] : null;
    if (raw is! List) return const [];
    return raw.map(_readString).whereType<String>().toList();
  }

  static String _friendlyAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-credential':
      case 'wrong-password':
      case 'user-not-found':
        return 'Incorrect email or password.';
      case 'email-already-in-use':
        return 'An account with this email already exists. Switch to Sign In.';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'operation-not-allowed':
        return 'Enable Email/Password in Firebase Console → Authentication → Sign-in method.';
      case 'too-many-requests':
        return 'Too many attempts. Wait a moment and try again.';
      case 'network-request-failed':
        return 'Network error while contacting Firebase Auth.';
      default:
        return e.message ?? 'Authentication failed (${e.code}).';
    }
  }

  static String _friendlyFirestoreError(int statusCode, String body) {
    final compact = _compactError(body);
    final lower = compact.toLowerCase();
    if (statusCode == 404 ||
        lower.contains('database (default) does not exist')) {
      return 'Firestore database not created yet in Firebase Console.';
    }
    if (lower.contains('app check')) {
      return 'Firestore App Check blocked access ($statusCode): $compact';
    }
    if (statusCode == 403 &&
        lower.contains('missing or insufficient permissions')) {
      return 'Firestore blocked access (403: $compact). Ensure Firestore Rules allow users/{uid}/security/keyring, items/{itemId}, and shares/{shareId}.';
    }
    return 'Firestore error ($statusCode): $compact';
  }

  static String _compactError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['error'] is Map) {
        return decoded['error']['message']?.toString() ?? body;
      }
    } catch (_) {}
    return body.length > 180 ? '${body.substring(0, 180)}...' : body;
  }

  // --- Pure-Dart Record & Trail JSON Field Serializers (Encrypted inside Ciphertext) ---

  static Map<String, dynamic> encodeRecordToFirestoreFields(
    OsmRecord record, {
    String? photoDataUri,
    String? ownerUid,
  }) {
    return {
      if (ownerUid != null && ownerUid.isNotEmpty) 'uid': _fsString(ownerUid),
      'id': _fsString(record.id),
      'createdAt': _fsTimestamp(record.createdAt),
      'updatedAt': _fsTimestamp(record.updatedAt),
      'latitude': _fsDouble(record.latitude),
      'longitude': _fsDouble(record.longitude),
      if (record.accuracyMeters != null)
        'accuracyMeters': _fsDouble(record.accuracyMeters!),
      if (record.altitudeMeters != null)
        'altitudeMeters': _fsDouble(record.altitudeMeters!),
      if (record.headingDegrees != null)
        'headingDegrees': _fsDouble(record.headingDegrees!),
      'effectiveLatitude': _fsDouble(record.effectiveLatitude),
      'effectiveLongitude': _fsDouble(record.effectiveLongitude),
      'primaryLocationPhotoIndex': {
        'integerValue': '${record.primaryLocationPhotoIndex}',
      },
      'isManualPinOverride': {'booleanValue': record.isManualPinOverride},
      'estimatedOffsetMeters': _fsDouble(record.estimatedOffsetMeters),
      'distanceReasoning': _fsString(record.distanceReasoning),
      'osmType': _fsString(record.osmType),
      'summary': _fsString(record.summary),
      'detectedLanguage': _fsString(record.detectedLanguage),
      'aiSource': _fsString(record.aiSource.name),
      'status': _fsString(record.status.name),
      if (record.trailId != null) 'trailId': _fsString(record.trailId!),
      'notes': _fsString(record.notes),
      if (photoDataUri != null && photoDataUri.isNotEmpty)
        'photoDataUri': _fsString(photoDataUri),
      'tags': {
        'mapValue': {
          'fields': {
            for (final e in record.tags.entries) e.key: _fsString(e.value),
          },
        },
      },
      'detectedLabels': {
        'arrayValue': {
          'values': record.detectedLabels.map(_fsString).toList(),
        },
      },
      'tagCandidates': {
        'mapValue': {
          'fields': {
            for (final e in record.tagCandidates.entries)
              e.key: _fsDouble(e.value),
          },
        },
      },
    };
  }

  static RemoteOsmRecord? decodeRecordFromFirestoreFields(
    Map<String, dynamic> fields, {
    String? fallbackId,
  }) {
    final id = _readString(fields['id']) ?? fallbackId;
    final lat = _readDouble(fields['latitude']);
    final lon = _readDouble(fields['longitude']);
    if (id == null || id.isEmpty || lat == null || lon == null) return null;

    final createdAt = _readTimestamp(fields['createdAt']) ?? DateTime.now();
    final updatedAt = _readTimestamp(fields['updatedAt']) ?? createdAt;
    final effLat = _readDouble(fields['effectiveLatitude']);
    final effLon = _readDouble(fields['effectiveLongitude']);

    final tags = <String, String>{};
    final rawTags = fields['tags']?['mapValue']?['fields'];
    if (rawTags is Map) {
      rawTags.forEach((k, v) {
        final str = _readString(v);
        if (str != null) tags[k.toString()] = str;
      });
    }

    final labels = <String>[];
    final rawLabels = fields['detectedLabels']?['arrayValue']?['values'];
    if (rawLabels is List) {
      for (final item in rawLabels) {
        final str = _readString(item);
        if (str != null) labels.add(str);
      }
    }

    final candidates = <String, double>{};
    final rawCandidates = fields['tagCandidates']?['mapValue']?['fields'];
    if (rawCandidates is Map) {
      rawCandidates.forEach((k, v) {
        final val = _readDouble(v);
        if (val != null) candidates[k.toString()] = val;
      });
    }

    final record = OsmRecord(
      id: id,
      createdAt: createdAt.toLocal(),
      updatedAt: updatedAt.toLocal(),
      latitude: lat,
      longitude: lon,
      primaryLocationPhotoIndex:
          _readInt(fields['primaryLocationPhotoIndex']) ?? 0,
      isManualPinOverride:
          fields['isManualPinOverride']?['booleanValue'] == true,
      accuracyMeters: _readDouble(fields['accuracyMeters']),
      altitudeMeters: _readDouble(fields['altitudeMeters']),
      headingDegrees: _readDouble(fields['headingDegrees']),
      extrapolatedLatitude: effLat,
      extrapolatedLongitude: effLon,
      estimatedOffsetMeters:
          _readDouble(fields['estimatedOffsetMeters']) ?? 6.0,
      distanceReasoning: _readString(fields['distanceReasoning']) ?? '',
      osmType: _readString(fields['osmType']) ?? 'node',
      summary: _readString(fields['summary']) ?? 'OSM Feature',
      detectedLanguage: _readString(fields['detectedLanguage']) ?? 'en',
      tags: tags,
      detectedLabels: labels,
      tagCandidates: candidates,
      aiSource: AiSource.fromString(_readString(fields['aiSource'])),
      status: RecordStatus.fromString(_readString(fields['status'])),
      trailId: _readString(fields['trailId']),
      notes: _readString(fields['notes']) ?? '',
      firebaseSyncedAt: DateTime.now().toUtc(),
    );

    return RemoteOsmRecord(
      record: record,
      photoDataUri: _readString(fields['photoDataUri']),
    );
  }

  static Map<String, dynamic> encodeTrailToFirestoreFields(
    HikeTrail trail, {
    String? ownerUid,
  }) {
    final pts = trail.points;
    final step = pts.length > 2000 ? (pts.length / 2000).ceil() : 1;
    final encodedPoints = <Map<String, dynamic>>[];
    for (int i = 0; i < pts.length; i += step) {
      final pt = pts[i];
      encodedPoints.add({
        'mapValue': {
          'fields': {
            'lat': _fsDouble(pt.latitude),
            'lon': _fsDouble(pt.longitude),
            if (pt.altitudeMeters != null) 'alt': _fsDouble(pt.altitudeMeters!),
            if (pt.accuracyMeters != null) 'acc': _fsDouble(pt.accuracyMeters!),
            't': _fsTimestamp(pt.recordedAt),
          },
        },
      });
    }

    return {
      if (ownerUid != null && ownerUid.isNotEmpty) 'uid': _fsString(ownerUid),
      'id': _fsString(trail.id),
      'name': _fsString(trail.name),
      'activityType': _fsString(trail.activityType.name),
      'startedAt': _fsTimestamp(trail.startedAt),
      if (trail.endedAt != null) 'endedAt': _fsTimestamp(trail.endedAt!),
      'distanceMeters': _fsDouble(trail.totalDistanceMeters),
      'elevationGainMeters': _fsDouble(trail.elevationGainMeters),
      'locationContext': _fsString(trail.locationContext),
      'tags': {
        'mapValue': {
          'fields': {
            for (final e in trail.tags.entries) e.key: _fsString(e.value),
          },
        },
      },
      'points': {
        'arrayValue': {
          'values': encodedPoints,
        },
      },
      'updatedAt': _fsTimestamp(DateTime.now().toUtc()),
    };
  }

  static HikeTrail? decodeTrailFromFirestoreFields(
    Map<String, dynamic> fields, {
    String? fallbackId,
  }) {
    final id = _readString(fields['id']) ?? fallbackId;
    if (id == null || id.isEmpty) return null;

    final startedAt = _readTimestamp(fields['startedAt']) ?? DateTime.now();
    final endedAt = _readTimestamp(fields['endedAt']);

    final tags = <String, String>{};
    final rawTags = fields['tags']?['mapValue']?['fields'];
    if (rawTags is Map) {
      rawTags.forEach((k, v) {
        final str = _readString(v);
        if (str != null) tags[k.toString()] = str;
      });
    }

    final points = <TrailPoint>[];
    final rawPts = fields['points']?['arrayValue']?['values'];
    if (rawPts is List) {
      for (final item in rawPts) {
        final mapVal = item is Map ? item['mapValue'] : null;
        final f = mapVal is Map ? mapVal['fields'] : null;
        if (f is Map) {
          final lat = _readDouble(f['lat']);
          final lon = _readDouble(f['lon']);
          if (lat != null && lon != null) {
            points.add(
              TrailPoint(
                trailId: id,
                latitude: lat,
                longitude: lon,
                altitudeMeters: _readDouble(f['alt']),
                accuracyMeters: _readDouble(f['acc']),
                recordedAt: (_readTimestamp(f['t']) ?? startedAt).toLocal(),
              ),
            );
          }
        }
      }
    }

    return HikeTrail(
      id: id,
      name: _readString(fields['name']) ?? 'Synced Route',
      startedAt: startedAt.toLocal(),
      endedAt: endedAt?.toLocal(),
      isActive: false,
      activityType: ActivityType.fromString(_readString(fields['activityType'])),
      tags: tags,
      points: points,
      needsLocationGuess: false,
      locationContext: _readString(fields['locationContext']) ?? '',
      firebaseSyncedAt: DateTime.now().toUtc(),
    );
  }

  static Map<String, dynamic> _fsString(String value) => {'stringValue': value};
  static Map<String, dynamic> _fsDouble(double value) => {'doubleValue': value};
  static Map<String, dynamic> _fsTimestamp(DateTime value) => {
        'timestampValue': value.toUtc().toIso8601String(),
      };

  static String? _readString(dynamic field) {
    if (field is Map && field['stringValue'] != null) {
      return field['stringValue'].toString();
    }
    return null;
  }

  static int? _readInt(dynamic field) {
    if (field is Map) {
      final i = field['integerValue'];
      if (i is int) return i;
      if (i is num) return i.toInt();
      if (i is String) return int.tryParse(i);
    }
    return null;
  }

  static double? _readDouble(dynamic field) {
    if (field is Map) {
      final d = field['doubleValue'];
      if (d is num) return d.toDouble();
      if (d is String) return double.tryParse(d);
      final i = field['integerValue'];
      if (i is num) return i.toDouble();
      if (i is String) return double.tryParse(i);
    }
    return null;
  }

  static DateTime? _readTimestamp(dynamic field) {
    if (field is Map && field['timestampValue'] != null) {
      return DateTime.tryParse(field['timestampValue'].toString());
    }
    return null;
  }
}
