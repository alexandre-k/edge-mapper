import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'e2ee_crypto_bridge.dart';

const _e2eeChannel = MethodChannel('com.edgemapper.app/secure_vault');

Future<NativeAesGcmResult?> tryNativeEncryptImpl({
  required Uint8List key,
  required Uint8List plaintext,
  required Uint8List aad,
}) async {
  try {
    final res = await _e2eeChannel.invokeMapMethod<String, dynamic>(
      'e2eeEncrypt',
      {
        'keyB64': base64Encode(key),
        'plainB64': base64Encode(plaintext),
        'aadB64': base64Encode(aad),
      },
    );
    if (res == null) return null;
    final ivB64 = res['ivB64']?.toString();
    final ctB64 = res['ctB64']?.toString();
    if (ivB64 == null || ctB64 == null) return null;
    return NativeAesGcmResult(
      iv: Uint8List.fromList(base64Decode(ivB64)),
      ciphertextWithTag: Uint8List.fromList(base64Decode(ctB64)),
    );
  } on MissingPluginException {
    return null;
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
  try {
    final plainB64 = await _e2eeChannel.invokeMethod<String>(
      'e2eeDecrypt',
      {
        'keyB64': base64Encode(key),
        'ivB64': base64Encode(iv),
        'ctB64': base64Encode(ciphertextWithTag),
        'aadB64': base64Encode(aad),
      },
    );
    if (plainB64 == null) return null;
    return Uint8List.fromList(base64Decode(plainB64));
  } on MissingPluginException {
    return null;
  } on PlatformException {
    rethrow;
  } catch (_) {
    return null;
  }
}
