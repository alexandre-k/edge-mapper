import 'dart:typed_data';

import 'e2ee_crypto_bridge_io.dart'
    if (dart.library.js_interop) 'e2ee_crypto_bridge_web.dart';

class NativeAesGcmResult {
  final Uint8List iv;
  final Uint8List ciphertextWithTag;

  const NativeAesGcmResult({
    required this.iv,
    required this.ciphertextWithTag,
  });
}

/// Optional platform hardware-accelerated AES-256-GCM bridge
/// (Android JCA hardware crypto / WebCrypto `crypto.subtle`).
/// Returns `null` when unavailable (e.g. headless unit tests), in which case
/// [E2eeCryptoService] seamlessly uses its NIST-verified pure-Dart AES-256-GCM.
class E2eeCryptoBridge {
  static Future<NativeAesGcmResult?> tryNativeEncrypt({
    required Uint8List key,
    required Uint8List plaintext,
    required Uint8List aad,
  }) =>
      tryNativeEncryptImpl(key: key, plaintext: plaintext, aad: aad);

  static Future<Uint8List?> tryNativeDecrypt({
    required Uint8List key,
    required Uint8List iv,
    required Uint8List ciphertextWithTag,
    required Uint8List aad,
  }) =>
      tryNativeDecryptImpl(
        key: key,
        iv: iv,
        ciphertextWithTag: ciphertextWithTag,
        aad: aad,
      );
}
