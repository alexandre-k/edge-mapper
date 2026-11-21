import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'e2ee_crypto_bridge.dart';

@JS('window.edgeMapperE2ee.encrypt')
external JSPromise<JSString> _webE2eeEncrypt(
  JSString keyB64,
  JSString plainB64,
  JSString aadB64,
);

@JS('window.edgeMapperE2ee.decrypt')
external JSPromise<JSString> _webE2eeDecrypt(
  JSString keyB64,
  JSString ivB64,
  JSString ctB64,
  JSString aadB64,
);

Future<NativeAesGcmResult?> tryNativeEncryptImpl({
  required Uint8List key,
  required Uint8List plaintext,
  required Uint8List aad,
}) async {
  try {
    final raw = (await _webE2eeEncrypt(
      base64Encode(key).toJS,
      base64Encode(plaintext).toJS,
      base64Encode(aad).toJS,
    ).toDart)
        .toDart;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final ivB64 = decoded['ivB64']?.toString();
    final ctB64 = decoded['ctB64']?.toString();
    if (ivB64 == null || ctB64 == null) return null;
    return NativeAesGcmResult(
      iv: Uint8List.fromList(base64Decode(ivB64)),
      ciphertextWithTag: Uint8List.fromList(base64Decode(ctB64)),
    );
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> tryNativeDecryptImpl({
  required Uint8List key,
  required Uint8List iv,
  required Uint8List ciphertextWithTag,
  required Uint8List aad,
}) async {
  final raw = (await _webE2eeDecrypt(
    base64Encode(key).toJS,
    base64Encode(iv).toJS,
    base64Encode(ciphertextWithTag).toJS,
    base64Encode(aad).toJS,
  ).toDart)
      .toDart;
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  if (decoded['ok'] != true) {
    throw const FormatException(
      'E2EE decryption failed: invalid Sync Key or tampered Firestore ciphertext.',
    );
  }
  final plainB64 = decoded['plainB64']?.toString() ?? '';
  return Uint8List.fromList(base64Decode(plainB64));
}
