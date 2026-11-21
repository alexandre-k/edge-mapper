import 'dart:typed_data';

import 'e2ee_platform_bridge_io.dart'
    if (dart.library.js_interop) 'e2ee_platform_bridge_web.dart';

/// Result of a WebAuthn `prf` extension evaluation or enrollment.
class PasskeyPrfResult {
  /// Whether WebAuthn is available in the current browser/platform context.
  final bool webAuthnSupported;

  /// Whether the selected authenticator reported `getClientExtensionResults().prf`
  /// support (`enabled === true` and/or returned deterministic PRF bytes).
  final bool prfSupported;

  /// Base64 credential ID (optional hint for faster future prompts).
  final String? credentialIdB64;

  /// Deterministic 32-byte PRF output (caller MUST zeroize after deriving `PRF_Root_Key`).
  final Uint8List? prfOutput;

  /// Human-readable error or fallback guidance when [prfSupported] is false.
  final String? errorMessage;

  const PasskeyPrfResult({
    required this.webAuthnSupported,
    required this.prfSupported,
    this.credentialIdB64,
    this.prfOutput,
    this.errorMessage,
  });

  bool get hasPrfOutput => prfOutput != null && prfOutput!.length >= 16;
}

/// Platform capabilities for zero-config Passkey PRF and local hardware caching.
class E2eePlatformCapabilities {
  final bool supportsWebAuthnPrf;
  final bool supportsAndroidHardwareCache;
  final String hardwareCacheDetail;

  const E2eePlatformCapabilities({
    required this.supportsWebAuthnPrf,
    required this.supportsAndroidHardwareCache,
    this.hardwareCacheDetail = '',
  });
}

/// Payload cached inside Android Hardware Keystore (`AES-256-GCM`,
/// `setRandomizedEncryptionRequired(true)`).
class CachedHardwareVault {
  final String uid;
  final Uint8List userPrivateKey;
  final Uint8List? authSeed16;

  const CachedHardwareVault({
    required this.uid,
    required this.userPrivateKey,
    this.authSeed16,
  });

  void zeroizeSecrets() {
    userPrivateKey.fillRange(0, userPrivateKey.length, 0);
    if (authSeed16 != null) {
      authSeed16!.fillRange(0, authSeed16!.length, 0);
    }
  }
}

/// Cross-platform bridge for:
/// 1. **WebAuthn `prf` extension** (desktop/web Passkey zero-config root unlock
///    with `getClientExtensionResults().prf` capability detection).
/// 2. **Android Keystore `AES-256-GCM` local hardware cache**
///    (`AES/GCM/NoPadding`, `setRandomizedEncryptionRequired(true)`, TEE/StrongBox)
///    for caching `User_Priv` (and optional `authSeed16`) locally so daily
///    Android unlocks only need Android Keystore / Fingerprint.
abstract class E2eePlatformBridge {
  Future<E2eePlatformCapabilities> getCapabilities();

  Future<PasskeyPrfResult> enrollPasskeyPrf({
    required String accountName,
    required String displayName,
    required Uint8List deterministicSalt,
  });

  Future<PasskeyPrfResult> evaluatePasskeyPrf({
    required Uint8List deterministicSalt,
    String? credentialIdB64,
  });

  /// Wraps `User_Priv` (32 bytes) and optional `authSeed16` (16 bytes) locally
  /// using Android Keystore `AES-256-GCM` (`setRandomizedEncryptionRequired(true)`).
  Future<bool> cacheUserPrivLocally({
    required String uid,
    required Uint8List userPrivateKey,
    Uint8List? authSeed16,
  });

  /// Unwraps cached `User_Priv` (and optional `authSeed16`) from Android Keystore
  /// silently for daily app launches without triggering a Passkey dialog.
  Future<CachedHardwareVault?> loadCachedVault({String? uid});

  /// Unwraps cached `User_Priv` (and optional `authSeed16`) from Android Keystore
  /// after verifying Android OS Biometrics / Fingerprint (`BiometricPrompt`).
  Future<CachedHardwareVault?> unlockCachedVaultWithBiometric({String? uid});

  /// Returns `true` if a hardware-wrapped vault exists locally (for [uid] if given,
  /// or any cached vault if [uid] is null).
  Future<bool> hasCachedUserPriv({String? uid});

  /// Deletes the locally cached hardware-wrapped vault (on forget/reset).
  Future<void> clearCachedUserPriv({String? uid});
}

E2eePlatformBridge createE2eePlatformBridge() => createE2eePlatformBridgeImpl();
