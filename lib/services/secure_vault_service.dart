import 'package:flutter/foundation.dart';

import 'secure_vault_backend.dart';

/// Encrypted credentials & secrets vault backed by:
/// - **Android**: Hardware-backed `AndroidKeyStore` AES-256-GCM (StrongBox / TEE)
///   with optional OS Biometrics / Device Lock gate or PBKDF2-SHA-256 passphrase.
/// - **Web / Linux Chrome**: W3C WebAuthn Passkey PRF (`hmac-secret`) compatible
///   with **Bitwarden Passkeys**, **YubiKey 5 (USB/NFC)**, and OS Passkeys,
///   PBKDF2-SHA-256 passphrase (Bitwarden-managed), or automatic non-extractable
///   WebCrypto AES-256-GCM key stored in IndexedDB.
///
/// Sensitive keys (OSM OAuth tokens, Gemini / Custom AI API keys, Firebase API
/// keys, sync passphrases) are NEVER stored in plaintext in SQLite or localStorage.
class SecureVaultService extends ChangeNotifier {
  final SecureVaultBackend _backend;

  VaultStatusInfo _status = const VaultStatusInfo(
    mode: VaultProtectionMode.osKeystore,
    isLocked: false,
    hasStoredSecrets: false,
    supportsPasskeyPrf: false,
    supportsOsBiometric: false,
    detail: 'Initializing encrypted vault...',
  );

  final Map<String, String> _secrets = {};
  bool _initialized = false;

  SecureVaultService({SecureVaultBackend? backend})
      : _backend = backend ?? createSecureVaultBackend();

  VaultStatusInfo get status => _status;
  VaultProtectionMode get mode => _status.mode;
  bool get isLocked => _status.isLocked;
  bool get isUnlocked => !_status.isLocked;
  bool get isInitialized => _initialized;
  bool get hasStoredSecrets => _status.hasStoredSecrets || _secrets.isNotEmpty;
  bool get supportsPasskeyPrf => _status.supportsPasskeyPrf;
  bool get supportsOsBiometric => _status.supportsOsBiometric;
  String get credentialLabel => _status.credentialLabel;
  String get protectionDetail => _status.detail;

  Map<String, String> get loadedSecrets => Map.unmodifiable(_secrets);

  String get statusLabel {
    if (isLocked) {
      return switch (mode) {
        VaultProtectionMode.passkeyPrf => 'Locked · Passkey (Bitwarden / YubiKey)',
        VaultProtectionMode.osBiometric => 'Locked · Android OS Biometrics',
        VaultProtectionMode.passphrase => 'Locked · Vault Passphrase',
        VaultProtectionMode.osKeystore => 'Locked',
      };
    }
    return switch (mode) {
      VaultProtectionMode.passkeyPrf =>
        'Unlocked · Passkey (Bitwarden / YubiKey)',
      VaultProtectionMode.osBiometric => 'Unlocked · Android OS Biometrics',
      VaultProtectionMode.passphrase => 'Unlocked · Vault Passphrase',
      VaultProtectionMode.osKeystore => 'Encrypted · OS / WebCrypto Keystore',
    };
  }

  Future<void> init() async {
    _status = await _backend.getStatus();
    if (!_status.isLocked) {
      final read = await _backend.readAllSecrets();
      _secrets
        ..clear()
        ..addAll(read.secrets);
      if (read.locked) {
        _status = await _backend.getStatus();
      }
    }
    _initialized = true;
    notifyListeners();
  }

  String getSecret(String key) => isLocked ? '' : (_secrets[key] ?? '');

  Future<void> setSecret(String key, String value) =>
      setSecrets({key: value});

  Future<void> setSecrets(Map<String, String> updates) async {
    if (isLocked) {
      throw StateError(
        'Encrypted vault is locked. Unlock with your Passkey / OS authentication before modifying sensitive credentials.',
      );
    }
    for (final entry in updates.entries) {
      final cleaned = entry.value.trim();
      if (cleaned.isEmpty) {
        _secrets.remove(entry.key);
      } else {
        _secrets[entry.key] = cleaned;
      }
    }
    await _backend.writeAllSecrets(_secrets);
    _status = await _backend.getStatus();
    notifyListeners();
  }

  static const int minPassphraseLength = 12;

  void _requireUnlockedForModeChange() {
    if (_status.isLocked) {
      throw StateError(
        'Unlock the vault before changing its protection mode.',
      );
    }
  }

  /// Enrolls a WebAuthn Passkey with `prf` (`hmac-secret`) extension—compatible
  /// with Bitwarden Passkeys, YubiKey 5 (USB/NFC), and OS Passkeys—and
  /// re-encrypts all secrets under the Passkey-derived AES-256-GCM key.
  Future<void> enrollPasskey({
    String label = 'Edge Mapper Vault (Bitwarden / YubiKey)',
  }) async {
    _requireUnlockedForModeChange();
    await _backend.enrollPasskey(label: label);
    _status = await _backend.getStatus();
    notifyListeners();
  }

  /// Prompts Bitwarden / YubiKey / OS Passkey to derive the AES-256-GCM key
  /// via WebAuthn PRF and decrypt all secrets into RAM.
  Future<void> unlockWithPasskey() async {
    final decrypted = await _backend.unlockWithPasskey();
    _secrets
      ..clear()
      ..addAll(decrypted);
    _status = await _backend.getStatus();
    notifyListeners();
  }

  /// On Android, gates Hardware Keystore decryption behind OS Biometrics /
  /// Device Screen Lock.
  Future<void> enableOsBiometricLock() async {
    _requireUnlockedForModeChange();
    await _backend.enableOsBiometricLock();
    _status = await _backend.getStatus();
    notifyListeners();
  }

  Future<void> unlockWithOsBiometric() async {
    final decrypted = await _backend.unlockWithOsBiometric();
    _secrets
      ..clear()
      ..addAll(decrypted);
    _status = await _backend.getStatus();
    notifyListeners();
  }

  /// Encrypts the vault using PBKDF2-SHA-256 (600,000 iterations) + AES-256-GCM
  /// with a user passphrase (easily stored/autofilled by Bitwarden).
  Future<void> enablePassphraseLock(String passphrase) async {
    _requireUnlockedForModeChange();
    if (passphrase.length < minPassphraseLength) {
      throw ArgumentError(
        'Passphrase must be at least $minPassphraseLength characters.',
      );
    }
    await _backend.enablePassphrase(passphrase);
    _status = await _backend.getStatus();
    notifyListeners();
  }

  Future<void> unlockWithPassphrase(String passphrase) async {
    final decrypted = await _backend.unlockWithPassphrase(passphrase);
    _secrets
      ..clear()
      ..addAll(decrypted);
    _status = await _backend.getStatus();
    notifyListeners();
  }

  /// Switches back to automatic OS / Browser Keystore AES-256-GCM encryption
  /// (secrets remain encrypted at rest without per-session unlock prompt).
  Future<void> switchToOsKeystore() async {
    _requireUnlockedForModeChange();
    await _backend.switchToOsKeystore();
    _status = await _backend.getStatus();
    notifyListeners();
  }

  /// Immediately wipes decrypted secrets from RAM and locks the vault.
  Future<void> lock() async {
    await _backend.lock();
    _status = await _backend.getStatus();
    if (_status.isLocked) {
      _secrets.clear();
    }
    notifyListeners();
  }
}
