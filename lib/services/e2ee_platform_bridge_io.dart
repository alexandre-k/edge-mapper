import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'e2ee_platform_bridge.dart';

class _IoE2eePlatformBridge implements E2eePlatformBridge {
  static const MethodChannel _channel =
      MethodChannel('com.edgemapper.app/e2ee_keystore');

  bool get _isAndroid => Platform.isAndroid;

  @override
  Future<E2eePlatformCapabilities> getCapabilities() async {
    if (!_isAndroid) {
      return const E2eePlatformCapabilities(
        supportsWebAuthnPrf: false,
        supportsAndroidHardwareCache: false,
        hardwareCacheDetail: 'Volatile RAM session only on desktop IO.',
      );
    }
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('getStatus');
      return E2eePlatformCapabilities(
        supportsWebAuthnPrf: false,
        supportsAndroidHardwareCache: res?['supported'] == true,
        hardwareCacheDetail: res?['detail']?.toString() ??
            'Android Keystore AES-256-GCM (TEE/StrongBox)',
      );
    } catch (_) {
      return const E2eePlatformCapabilities(
        supportsWebAuthnPrf: false,
        supportsAndroidHardwareCache: false,
      );
    }
  }

  @override
  Future<PasskeyPrfResult> enrollPasskeyPrf({
    required String accountName,
    required String displayName,
    required Uint8List deterministicSalt,
  }) async {
    return const PasskeyPrfResult(
      webAuthnSupported: false,
      prfSupported: false,
      errorMessage:
          'WebAuthn PRF is not exposed natively on this platform. Use the Argon2id Recovery Key (Bitwarden autofill supported) — once unlocked, Android Keystore caches your key in hardware.',
    );
  }

  @override
  Future<PasskeyPrfResult> evaluatePasskeyPrf({
    required Uint8List deterministicSalt,
    String? credentialIdB64,
  }) async {
    return const PasskeyPrfResult(
      webAuthnSupported: false,
      prfSupported: false,
      errorMessage:
          'WebAuthn PRF is unavailable on this platform. Unlock using your Recovery Key.',
    );
  }

  @override
  Future<bool> cacheUserPrivLocally({
    required String uid,
    required Uint8List userPrivateKey,
    Uint8List? authSeed16,
  }) async {
    if (!_isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('cacheUserPriv', {
        'uid': uid,
        'userPrivB64': base64Encode(userPrivateKey),
        if (authSeed16 != null && authSeed16.length == 16)
          'authSeedB64': base64Encode(authSeed16),
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  CachedHardwareVault? _parseCachedResult(Map<String, dynamic>? map) {
    if (map == null) return null;
    final uid = map['uid']?.toString().trim() ?? '';
    final privB64 = map['userPrivB64']?.toString().trim() ?? '';
    if (uid.isEmpty || privB64.isEmpty) return null;
    final privBytes = Uint8List.fromList(base64Decode(privB64));
    if (privBytes.length != 32) return null;
    final seedB64 = map['authSeedB64']?.toString().trim() ?? '';
    Uint8List? seedBytes;
    if (seedB64.isNotEmpty) {
      final decoded = Uint8List.fromList(base64Decode(seedB64));
      if (decoded.length == 16) seedBytes = decoded;
    }
    return CachedHardwareVault(
      uid: uid,
      userPrivateKey: privBytes,
      authSeed16: seedBytes,
    );
  }

  @override
  Future<CachedHardwareVault?> loadCachedVault({String? uid}) async {
    if (!_isAndroid) return null;
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
        'loadCachedUserPriv',
        {if (uid != null && uid.isNotEmpty) 'uid': uid},
      );
      return _parseCachedResult(map);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<CachedHardwareVault?> unlockCachedVaultWithBiometric({
    String? uid,
  }) async {
    if (!_isAndroid) return null;
    final map = await _channel.invokeMapMethod<String, dynamic>(
      'unlockCachedUserPrivWithBiometric',
      {if (uid != null && uid.isNotEmpty) 'uid': uid},
    );
    return _parseCachedResult(map);
  }

  @override
  Future<bool> hasCachedUserPriv({String? uid}) async {
    if (!_isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('hasCachedUserPriv', {
        if (uid != null && uid.isNotEmpty) 'uid': uid,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> clearCachedUserPriv({String? uid}) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('clearCachedUserPriv', {
        if (uid != null) 'uid': uid,
      });
    } catch (_) {}
  }
}

E2eePlatformBridge createE2eePlatformBridgeImpl() => _IoE2eePlatformBridge();
