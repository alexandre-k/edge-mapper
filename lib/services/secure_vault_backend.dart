import 'secure_vault_backend_io.dart'
    if (dart.library.js_interop) 'secure_vault_backend_web.dart';

/// Encryption protection mode for sensitive credentials (OSM OAuth tokens,
/// Gemini / Custom AI API keys, Firebase API keys, sync passphrases).
enum VaultProtectionMode {
  /// Automatic OS / browser hardware-bound AES-256-GCM encryption
  /// (AndroidKeyStore StrongBox/TEE on Android; non-extractable WebCrypto
  /// IndexedDB key on Web).
  osKeystore,

  /// W3C WebAuthn Passkey with PRF (`hmac-secret`) extension — manageable via
  /// Bitwarden Passkeys, YubiKey 5 (USB/NFC), or OS Passkeys.
  passkeyPrf,

  /// Android Hardware Keystore AES-256-GCM gated by OS Biometrics / Device Lock.
  osBiometric,

  /// PBKDF2-SHA-256 (600,000 iterations) + AES-256-GCM vault passphrase
  /// (manageable via Bitwarden password autofill on any platform).
  passphrase;

  static VaultProtectionMode fromWire(String raw) => switch (raw.trim()) {
        'passkey_prf' => VaultProtectionMode.passkeyPrf,
        'os_biometric' => VaultProtectionMode.osBiometric,
        'passphrase' => VaultProtectionMode.passphrase,
        _ => VaultProtectionMode.osKeystore,
      };

  String get wireName => switch (this) {
        VaultProtectionMode.osKeystore => 'os_keystore',
        VaultProtectionMode.passkeyPrf => 'passkey_prf',
        VaultProtectionMode.osBiometric => 'os_biometric',
        VaultProtectionMode.passphrase => 'passphrase',
      };

  String get displayLabel => switch (this) {
        VaultProtectionMode.osKeystore => 'OS Hardware / WebCrypto Keystore',
        VaultProtectionMode.passkeyPrf => 'Passkey (Bitwarden / YubiKey PRF)',
        VaultProtectionMode.osBiometric => 'Android OS Biometrics / Screen Lock',
        VaultProtectionMode.passphrase => 'Vault Passphrase (PBKDF2 + AES-256)',
      };

  bool get requiresExplicitUnlock => this != VaultProtectionMode.osKeystore;
}

class VaultStatusInfo {
  final VaultProtectionMode mode;
  final bool isLocked;
  final bool hasStoredSecrets;
  final bool supportsPasskeyPrf;
  final bool supportsOsBiometric;
  final String credentialLabel;
  final String detail;

  const VaultStatusInfo({
    required this.mode,
    required this.isLocked,
    required this.hasStoredSecrets,
    required this.supportsPasskeyPrf,
    required this.supportsOsBiometric,
    this.credentialLabel = '',
    this.detail = '',
  });
}

class VaultReadResult {
  final bool locked;
  final Map<String, String> secrets;

  const VaultReadResult({
    required this.locked,
    required this.secrets,
  });
}

abstract class SecureVaultBackend {
  Future<VaultStatusInfo> getStatus();
  Future<VaultReadResult> readAllSecrets();
  Future<void> writeAllSecrets(Map<String, String> secrets);

  Future<void> enrollPasskey({required String label});
  Future<Map<String, String>> unlockWithPasskey();

  Future<void> enableOsBiometricLock();
  Future<Map<String, String>> unlockWithOsBiometric();

  Future<void> enablePassphrase(String passphrase);
  Future<Map<String, String>> unlockWithPassphrase(String passphrase);

  Future<void> switchToOsKeystore();
  Future<void> lock();
}

SecureVaultBackend createSecureVaultBackend() => createVaultBackendImpl();
