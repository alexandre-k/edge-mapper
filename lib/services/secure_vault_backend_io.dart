import 'dart:convert';

import 'package:flutter/services.dart';

import 'secure_vault_backend.dart';

SecureVaultBackend createVaultBackendImpl() => _AndroidSecureVaultBackend();

class _AndroidSecureVaultBackend implements SecureVaultBackend {
  static const MethodChannel _channel =
      MethodChannel('com.edgemapper.app/secure_vault');

  // Headless / test VM fallback when Android MethodChannel is unavailable
  bool _useMemoryFallback = false;
  final Map<String, String> _memSecrets = {};
  VaultProtectionMode _memMode = VaultProtectionMode.osKeystore;
  bool _memLocked = false;
  String? _memPassphrase;

  Map<String, String> _parseSecretsMap(String rawJson) {
    if (rawJson.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map) {
        return decoded.map(
          (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
        );
      }
    } catch (_) {}
    return {};
  }

  @override
  Future<VaultStatusInfo> getStatus() async {
    if (!_useMemoryFallback) {
      try {
        final raw = await _channel.invokeMethod<dynamic>('getStatus');
        if (raw is Map) {
          return VaultStatusInfo(
            mode: VaultProtectionMode.fromWire(raw['mode']?.toString() ?? ''),
            isLocked: raw['isLocked'] == true,
            hasStoredSecrets: raw['hasStoredSecrets'] == true,
            supportsPasskeyPrf: raw['supportsPasskeyPrf'] == true,
            supportsOsBiometric: raw['supportsOsBiometric'] == true,
            credentialLabel: raw['credentialLabel']?.toString() ?? '',
            detail: raw['detail']?.toString() ?? '',
          );
        }
      } on MissingPluginException {
        _useMemoryFallback = true;
      } catch (e) {
        // Fail closed (locked) on unexpected platform errors rather than
        // pretending the vault is unlocked.
        return VaultStatusInfo(
          mode: VaultProtectionMode.osKeystore,
          isLocked: true,
          hasStoredSecrets: true,
          supportsPasskeyPrf: false,
          supportsOsBiometric: false,
          detail: 'Secure vault temporarily unavailable: $e',
        );
      }
    }

    return VaultStatusInfo(
      mode: _memMode,
      isLocked: _memLocked,
      hasStoredSecrets: _memSecrets.isNotEmpty,
      supportsPasskeyPrf: false,
      supportsOsBiometric: false,
      detail: 'In-memory test vault (OS Keystore unavailable on this runtime)',
    );
  }

  @override
  Future<VaultReadResult> readAllSecrets() async {
    if (!_useMemoryFallback) {
      try {
        final raw = await _channel.invokeMethod<dynamic>('readAllSecrets');
        if (raw is Map) {
          final locked = raw['locked'] == true;
          final jsonStr = raw['secretsJson']?.toString() ?? '{}';
          return VaultReadResult(
            locked: locked,
            secrets: locked ? const {} : _parseSecretsMap(jsonStr),
          );
        }
      } on MissingPluginException {
        _useMemoryFallback = true;
      }
    }

    return VaultReadResult(
      locked: _memLocked,
      secrets: _memLocked ? const {} : Map<String, String>.from(_memSecrets),
    );
  }

  @override
  Future<void> writeAllSecrets(Map<String, String> secrets) async {
    if (!_useMemoryFallback) {
      try {
        await _channel.invokeMethod<bool>(
          'writeSecrets',
          {'secretsJson': jsonEncode(secrets)},
        );
        return;
      } on MissingPluginException {
        _useMemoryFallback = true;
      }
    }
    if (_memLocked) {
      throw StateError('Vault is locked.');
    }
    _memSecrets
      ..clear()
      ..addAll(secrets);
  }

  @override
  Future<void> enrollPasskey({required String label}) async {
    throw UnsupportedError(
      'On Android, use OS Biometric / Passkey Screen Lock (hardware-backed AndroidKeyStore) or Vault Passphrase.',
    );
  }

  @override
  Future<Map<String, String>> unlockWithPasskey() async {
    return unlockWithOsBiometric();
  }

  @override
  Future<void> enableOsBiometricLock() async {
    if (!_useMemoryFallback) {
      try {
        await _channel.invokeMethod<bool>('enableOsBiometricLock');
        return;
      } on PlatformException catch (e) {
        throw Exception(e.message ?? 'Could not enable OS biometric lock.');
      } on MissingPluginException {
        _useMemoryFallback = true;
      }
    }
    if (_memLocked) {
      throw StateError('Vault is locked.');
    }
    _memMode = VaultProtectionMode.osBiometric;
    _memLocked = false;
  }

  @override
  Future<Map<String, String>> unlockWithOsBiometric() async {
    if (!_useMemoryFallback) {
      try {
        final raw = await _channel.invokeMethod<String>('unlockWithOsBiometric');
        return _parseSecretsMap(raw ?? '{}');
      } on PlatformException catch (e) {
        throw Exception(e.message ?? 'OS authentication failed.');
      } on MissingPluginException {
        _useMemoryFallback = true;
      }
    }
    _memLocked = false;
    return Map<String, String>.from(_memSecrets);
  }

  @override
  Future<void> enablePassphrase(String passphrase) async {
    if (!_useMemoryFallback) {
      try {
        await _channel.invokeMethod<bool>(
          'enablePassphrase',
          {'passphrase': passphrase},
        );
        return;
      } on PlatformException catch (e) {
        throw Exception(e.message ?? 'Could not enable passphrase lock.');
      } on MissingPluginException {
        _useMemoryFallback = true;
      }
    }
    if (_memLocked) {
      throw StateError('Vault is locked.');
    }
    if (passphrase.length < 12) {
      throw ArgumentError('Passphrase must be at least 12 characters.');
    }
    _memMode = VaultProtectionMode.passphrase;
    _memPassphrase = passphrase;
    _memLocked = false;
  }

  static bool _constantTimeStringEquals(String a, String b) {
    final aBytes = utf8.encode(a);
    final bBytes = utf8.encode(b);
    var diff = aBytes.length ^ bBytes.length;
    final len = aBytes.length < bBytes.length ? aBytes.length : bBytes.length;
    for (var i = 0; i < len; i++) {
      diff |= aBytes[i] ^ bBytes[i];
    }
    return diff == 0;
  }

  @override
  Future<Map<String, String>> unlockWithPassphrase(String passphrase) async {
    if (!_useMemoryFallback) {
      try {
        final raw = await _channel.invokeMethod<String>(
          'unlockWithPassphrase',
          {'passphrase': passphrase},
        );
        return _parseSecretsMap(raw ?? '{}');
      } on PlatformException catch (e) {
        throw Exception(e.message ?? 'Incorrect vault passphrase.');
      } on MissingPluginException {
        _useMemoryFallback = true;
      }
    }
    if (_memPassphrase == null ||
        !_constantTimeStringEquals(passphrase, _memPassphrase!)) {
      throw Exception('Incorrect vault passphrase.');
    }
    _memLocked = false;
    return Map<String, String>.from(_memSecrets);
  }

  @override
  Future<void> switchToOsKeystore() async {
    if (!_useMemoryFallback) {
      try {
        await _channel.invokeMethod<bool>('switchToOsKeystore');
        return;
      } on PlatformException catch (e) {
        throw Exception(e.message ?? 'Could not switch vault mode.');
      } on MissingPluginException {
        _useMemoryFallback = true;
      }
    }
    if (_memLocked) {
      throw StateError('Vault is locked.');
    }
    _memMode = VaultProtectionMode.osKeystore;
    _memPassphrase = null;
    _memLocked = false;
  }

  @override
  Future<void> lock() async {
    if (!_useMemoryFallback) {
      try {
        await _channel.invokeMethod<bool>('lock');
        return;
      } on MissingPluginException {
        _useMemoryFallback = true;
      }
    }
    if (_memMode.requiresExplicitUnlock) {
      _memLocked = true;
    }
  }
}
