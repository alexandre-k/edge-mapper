import 'dart:convert';
import 'dart:js_interop';

import 'secure_vault_backend.dart';

@JS('window.edgeMapperVault.getStatus')
external JSPromise<JSString> _vaultGetStatus();

@JS('window.edgeMapperVault.readAllSecrets')
external JSPromise<JSString> _vaultReadAll();

@JS('window.edgeMapperVault.writeSecrets')
external JSPromise<JSBoolean> _vaultWriteAll(JSString secretsJson);

@JS('window.edgeMapperVault.enrollPasskey')
external JSPromise<JSBoolean> _vaultEnrollPasskey(JSString label);

@JS('window.edgeMapperVault.unlockWithPasskey')
external JSPromise<JSString> _vaultUnlockPasskey();

@JS('window.edgeMapperVault.enablePassphrase')
external JSPromise<JSBoolean> _vaultEnablePassphrase(JSString passphrase);

@JS('window.edgeMapperVault.unlockWithPassphrase')
external JSPromise<JSString> _vaultUnlockPassphrase(JSString passphrase);

@JS('window.edgeMapperVault.switchToOsKeystore')
external JSPromise<JSBoolean> _vaultSwitchToOsKeystore();

@JS('window.edgeMapperVault.lock')
external JSPromise<JSBoolean> _vaultLock();

SecureVaultBackend createVaultBackendImpl() => _WebSecureVaultBackend();

class _WebSecureVaultBackend implements SecureVaultBackend {
  Map<String, String> _parseStringMap(dynamic raw) {
    if (raw is! Map) return {};
    return raw.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
  }

  @override
  Future<VaultStatusInfo> getStatus() async {
    final raw = (await _vaultGetStatus().toDart).toDart;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return VaultStatusInfo(
      mode: VaultProtectionMode.fromWire(decoded['mode']?.toString() ?? ''),
      isLocked: decoded['isLocked'] == true,
      hasStoredSecrets: decoded['hasStoredSecrets'] == true,
      supportsPasskeyPrf: decoded['supportsPasskeyPrf'] == true,
      supportsOsBiometric: decoded['supportsOsBiometric'] == true,
      credentialLabel: decoded['credentialLabel']?.toString() ?? '',
      detail: decoded['detail']?.toString() ?? '',
    );
  }

  @override
  Future<VaultReadResult> readAllSecrets() async {
    final raw = (await _vaultReadAll().toDart).toDart;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final locked = decoded['locked'] == true;
    return VaultReadResult(
      locked: locked,
      secrets: locked ? const {} : _parseStringMap(decoded['secrets']),
    );
  }

  @override
  Future<void> writeAllSecrets(Map<String, String> secrets) async {
    await _vaultWriteAll(jsonEncode(secrets).toJS).toDart;
  }

  @override
  Future<void> enrollPasskey({required String label}) async {
    await _vaultEnrollPasskey(label.toJS).toDart;
  }

  @override
  Future<Map<String, String>> unlockWithPasskey() async {
    final raw = (await _vaultUnlockPasskey().toDart).toDart;
    return _parseStringMap(jsonDecode(raw));
  }

  @override
  Future<void> enableOsBiometricLock() async {
    throw UnsupportedError(
      'On Web, use Passkey Lock (Bitwarden / YubiKey / OS Passkey) instead.',
    );
  }

  @override
  Future<Map<String, String>> unlockWithOsBiometric() async {
    return unlockWithPasskey();
  }

  @override
  Future<void> enablePassphrase(String passphrase) async {
    await _vaultEnablePassphrase(passphrase.toJS).toDart;
  }

  @override
  Future<Map<String, String>> unlockWithPassphrase(String passphrase) async {
    final raw = (await _vaultUnlockPassphrase(passphrase.toJS).toDart).toDart;
    return _parseStringMap(jsonDecode(raw));
  }

  @override
  Future<void> switchToOsKeystore() async {
    await _vaultSwitchToOsKeystore().toDart;
  }

  @override
  Future<void> lock() async {
    await _vaultLock().toDart;
  }
}
