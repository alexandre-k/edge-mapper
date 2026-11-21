import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'e2ee_platform_bridge.dart';

@JS('edgeMapperPasskeyPrf.isSupported')
external bool? _jsPrfIsSupported();

@JS('edgeMapperPasskeyPrf.createPasskeyWithPrf')
external JSPromise<JSString> _jsCreatePasskeyWithPrf(
  JSString accountName,
  JSString displayName,
  JSString saltB64,
);

@JS('edgeMapperPasskeyPrf.getPrfOutput')
external JSPromise<JSString> _jsGetPrfOutput(
  JSString saltB64,
  JSString credentialIdB64,
);

class _WebE2eePlatformBridge implements E2eePlatformBridge {
  @override
  Future<E2eePlatformCapabilities> getCapabilities() async {
    bool supported = false;
    try {
      supported = _jsPrfIsSupported() == true;
    } catch (_) {
      supported = false;
    }
    return E2eePlatformCapabilities(
      supportsWebAuthnPrf: supported,
      supportsAndroidHardwareCache: false,
      hardwareCacheDetail: 'Web volatile memory session (keys cleared on lock/reload).',
    );
  }

  @override
  Future<PasskeyPrfResult> enrollPasskeyPrf({
    required String accountName,
    required String displayName,
    required Uint8List deterministicSalt,
  }) async {
    try {
      final raw = (await _jsCreatePasskeyWithPrf(
        accountName.toJS,
        displayName.toJS,
        base64Encode(deterministicSalt).toJS,
      ).toDart)
          .toDart;
      return _parsePrfResult(raw);
    } catch (e) {
      return PasskeyPrfResult(
        webAuthnSupported: true,
        prfSupported: false,
        errorMessage: 'Passkey PRF enrollment failed: $e',
      );
    }
  }

  @override
  Future<PasskeyPrfResult> evaluatePasskeyPrf({
    required Uint8List deterministicSalt,
    String? credentialIdB64,
  }) async {
    try {
      final raw = (await _jsGetPrfOutput(
        base64Encode(deterministicSalt).toJS,
        (credentialIdB64 ?? '').toJS,
      ).toDart)
          .toDart;
      return _parsePrfResult(raw);
    } catch (e) {
      return PasskeyPrfResult(
        webAuthnSupported: true,
        prfSupported: false,
        errorMessage: 'Passkey PRF unlock failed: $e',
      );
    }
  }

  PasskeyPrfResult _parsePrfResult(String jsonStr) {
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    final webAuthnSupported = map['webAuthnSupported'] == true;
    final prfSupported = map['prfSupported'] == true;
    final credId = map['credentialIdB64']?.toString();
    final prfB64 = map['prfOutputB64']?.toString() ?? '';
    Uint8List? prfBytes;
    if (prfB64.isNotEmpty) {
      prfBytes = Uint8List.fromList(base64Decode(prfB64));
    }
    return PasskeyPrfResult(
      webAuthnSupported: webAuthnSupported,
      prfSupported: prfSupported && prfBytes != null && prfBytes.length >= 16,
      credentialIdB64: (credId != null && credId.isNotEmpty) ? credId : null,
      prfOutput: prfBytes,
      errorMessage: map['error']?.toString(),
    );
  }

  @override
  Future<bool> cacheUserPrivLocally({
    required String uid,
    required Uint8List userPrivateKey,
    Uint8List? authSeed16,
  }) async =>
      false;

  @override
  Future<CachedHardwareVault?> loadCachedVault({String? uid}) async => null;

  @override
  Future<CachedHardwareVault?> unlockCachedVaultWithBiometric({
    String? uid,
  }) async =>
      null;

  @override
  Future<bool> hasCachedUserPriv({String? uid}) async => false;

  @override
  Future<void> clearCachedUserPriv({String? uid}) async {}
}

E2eePlatformBridge createE2eePlatformBridgeImpl() => _WebE2eePlatformBridge();
