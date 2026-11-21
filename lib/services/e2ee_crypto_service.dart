import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'e2ee_crypto_bridge.dart';

class E2eeEncryptedBlob {
  final String ivB64;
  final String ciphertextB64;

  const E2eeEncryptedBlob({
    required this.ivB64,
    required this.ciphertextB64,
  });
}

class E2eeDecryptionException implements Exception {
  final String message;

  const E2eeDecryptionException([
    this.message = 'Decryption failed: wrong Sync Key or corrupted/tampered ciphertext.',
  ]);

  @override
  String toString() => message;
}

/// Authenticated End-to-End Encryption (AES-256-GCM with 96-bit CSPRNG nonces
/// and Associated Data) for all Edge Mapper data persisted to Cloud Firestore.
///
/// Uses hardware-accelerated native AES-256-GCM on Android (JCA `AES/GCM/NoPadding`)
/// and Web (`crypto.subtle`) when available, and falls back seamlessly to a
/// standards-compliant pure-Dart NIST FIPS-197 / SP 800-38D AES-256-GCM
/// implementation with identical wire format across all platforms.
class E2eeCryptoService {
  static const int keyLengthBytes = 32;
  static const int ivLengthBytes = 12;
  static const int tagLengthBytes = 16;

  /// Encrypts UTF-8 [plaintext] using 256-bit [key] and UTF-8 [aad].
  static Future<E2eeEncryptedBlob> encryptString({
    required Uint8List key,
    required String plaintext,
    required String aad,
  }) async {
    _validateKey(key);
    final plainBytes = Uint8List.fromList(utf8.encode(plaintext));
    final aadBytes = Uint8List.fromList(utf8.encode(aad));

    final native = await E2eeCryptoBridge.tryNativeEncrypt(
      key: key,
      plaintext: plainBytes,
      aad: aadBytes,
    );
    if (native != null) {
      return E2eeEncryptedBlob(
        ivB64: base64Encode(native.iv),
        ciphertextB64: base64Encode(native.ciphertextWithTag),
      );
    }

    final iv = _randomIv();
    final ctWithTag = encryptAes256GcmPureDart(
      key: key,
      iv: iv,
      plaintext: plainBytes,
      aad: aadBytes,
    );
    return E2eeEncryptedBlob(
      ivB64: base64Encode(iv),
      ciphertextB64: base64Encode(ctWithTag),
    );
  }

  /// Decrypts an [E2eeEncryptedBlob] using 256-bit [key] and verifies UTF-8 [aad]
  /// and the 128-bit GCM authentication tag.
  static Future<String> decryptString({
    required Uint8List key,
    required String ivB64,
    required String ciphertextB64,
    required String aad,
  }) async {
    _validateKey(key);
    final Uint8List iv;
    final Uint8List ctWithTag;
    try {
      iv = Uint8List.fromList(base64Decode(ivB64.trim()));
      ctWithTag = Uint8List.fromList(base64Decode(ciphertextB64.trim()));
    } catch (_) {
      throw const E2eeDecryptionException('Invalid Base64 E2EE envelope.');
    }
    if (iv.length != ivLengthBytes || ctWithTag.length < tagLengthBytes) {
      throw const E2eeDecryptionException('Malformed AES-256-GCM envelope.');
    }
    final aadBytes = Uint8List.fromList(utf8.encode(aad));

    try {
      final native = await E2eeCryptoBridge.tryNativeDecrypt(
        key: key,
        iv: iv,
        ciphertextWithTag: ctWithTag,
        aad: aadBytes,
      );
      if (native != null) {
        return utf8.decode(native);
      }
    } catch (_) {
      throw const E2eeDecryptionException();
    }

    final plain = decryptAes256GcmPureDart(
      key: key,
      iv: iv,
      ciphertextWithTag: ctWithTag,
      aad: aadBytes,
    );
    return utf8.decode(plain);
  }

  /// Pure-Dart NIST SP 800-38D AES-256-GCM encryption (returns `ciphertext || tag`).
  static Uint8List encryptAes256GcmPureDart({
    required Uint8List key,
    required Uint8List iv,
    required Uint8List plaintext,
    required Uint8List aad,
  }) {
    _validateKey(key);
    if (iv.length != ivLengthBytes) {
      throw ArgumentError.value(iv.length, 'iv', 'GCM IV must be 12 bytes.');
    }
    final rk = _expandAes256Key(key);
    final h = _aes256EncryptBlock(Uint8List(16), rk);

    // J0 = IV || 0x00000001
    final j0 = Uint8List(16)..setRange(0, 12, iv);
    j0[15] = 1;

    // Encrypt plaintext with GCTR starting at inc32(J0)
    final counter = Uint8List.fromList(j0);
    _inc32(counter);
    final ciphertext = _gctr(rk, counter, plaintext);

    // Compute 128-bit authentication tag: T = GCTR(J0, GHASH(H, A, C))
    final s = _ghash(h, aad, ciphertext);
    final tagMask = _aes256EncryptBlock(j0, rk);
    final out = Uint8List(ciphertext.length + tagLengthBytes)
      ..setRange(0, ciphertext.length, ciphertext);
    for (int i = 0; i < tagLengthBytes; i++) {
      out[ciphertext.length + i] = s[i] ^ tagMask[i];
    }
    return out;
  }

  /// Pure-Dart NIST SP 800-38D AES-256-GCM decryption with constant-time tag verification.
  static Uint8List decryptAes256GcmPureDart({
    required Uint8List key,
    required Uint8List iv,
    required Uint8List ciphertextWithTag,
    required Uint8List aad,
  }) {
    _validateKey(key);
    if (iv.length != ivLengthBytes || ciphertextWithTag.length < tagLengthBytes) {
      throw const E2eeDecryptionException('Invalid AES-256-GCM input length.');
    }
    final ctLen = ciphertextWithTag.length - tagLengthBytes;
    final ciphertext = Uint8List.sublistView(ciphertextWithTag, 0, ctLen);
    final providedTag =
        Uint8List.sublistView(ciphertextWithTag, ctLen, ciphertextWithTag.length);

    final rk = _expandAes256Key(key);
    final h = _aes256EncryptBlock(Uint8List(16), rk);

    final j0 = Uint8List(16)..setRange(0, 12, iv);
    j0[15] = 1;

    final s = _ghash(h, aad, ciphertext);
    final tagMask = _aes256EncryptBlock(j0, rk);

    int diff = 0;
    for (int i = 0; i < tagLengthBytes; i++) {
      diff |= providedTag[i] ^ (s[i] ^ tagMask[i]);
    }
    if (diff != 0) {
      throw const E2eeDecryptionException();
    }

    final counter = Uint8List.fromList(j0);
    _inc32(counter);
    return _gctr(rk, counter, ciphertext);
  }

  static void _validateKey(Uint8List key) {
    if (key.length != keyLengthBytes) {
      throw ArgumentError.value(
        key.length,
        'key',
        'AES-256 key must be exactly 32 bytes.',
      );
    }
  }

  static Uint8List _randomIv() {
    final rng = Random.secure();
    final iv = Uint8List(ivLengthBytes);
    for (int i = 0; i < ivLengthBytes; i++) {
      iv[i] = rng.nextInt(256);
    }
    return iv;
  }

  // --- NIST SP 800-38D GCM Primitives (GCTR & GHASH over GF(2^128)) ---

  static void _inc32(Uint8List block) {
    int c = ((block[12] << 24) |
            (block[13] << 16) |
            (block[14] << 8) |
            block[15]) +
        1;
    block[12] = (c >> 24) & 0xff;
    block[13] = (c >> 16) & 0xff;
    block[14] = (c >> 8) & 0xff;
    block[15] = c & 0xff;
  }

  static Uint8List _gctr(Uint8List rk, Uint8List icb, Uint8List input) {
    final out = Uint8List(input.length);
    if (input.isEmpty) return out;
    final cb = Uint8List.fromList(icb);
    for (int offset = 0; offset < input.length; offset += 16) {
      final ks = _aes256EncryptBlock(cb, rk);
      final remaining = input.length - offset;
      final n = remaining < 16 ? remaining : 16;
      for (int i = 0; i < n; i++) {
        out[offset + i] = input[offset + i] ^ ks[i];
      }
      _inc32(cb);
    }
    return out;
  }

  static Uint8List _ghash(Uint8List h, Uint8List aad, Uint8List ct) {
    final y = Uint8List(16);

    void absorb(Uint8List data) {
      for (int offset = 0; offset < data.length; offset += 16) {
        final remaining = data.length - offset;
        final n = remaining < 16 ? remaining : 16;
        for (int i = 0; i < n; i++) {
          y[i] ^= data[offset + i];
        }
        _gf128MulInPlace(y, h);
      }
    }

    absorb(aad);
    absorb(ct);

    // Final length block: 64-bit big-endian bit-length of AAD || 64-bit bit-length of CT
    final lenBlock = Uint8List(16);
    _writeUint64Be(lenBlock, 0, aad.length * 8);
    _writeUint64Be(lenBlock, 8, ct.length * 8);
    for (int i = 0; i < 16; i++) {
      y[i] ^= lenBlock[i];
    }
    _gf128MulInPlace(y, h);
    return y;
  }

  static void _writeUint64Be(Uint8List dst, int offset, int value) {
    final hi = (value ~/ 4294967296) & 0xffffffff;
    final lo = value & 0xffffffff;
    dst[offset + 0] = (hi >> 24) & 0xff;
    dst[offset + 1] = (hi >> 16) & 0xff;
    dst[offset + 2] = (hi >> 8) & 0xff;
    dst[offset + 3] = hi & 0xff;
    dst[offset + 4] = (lo >> 24) & 0xff;
    dst[offset + 5] = (lo >> 16) & 0xff;
    dst[offset + 6] = (lo >> 8) & 0xff;
    dst[offset + 7] = lo & 0xff;
  }

  static void _gf128MulInPlace(Uint8List x, Uint8List h) {
    final z = Uint8List(16);
    final v = Uint8List.fromList(h);
    for (int i = 0; i < 128; i++) {
      if ((x[i >> 3] & (0x80 >> (i & 7))) != 0) {
        for (int j = 0; j < 16; j++) {
          z[j] ^= v[j];
        }
      }
      final lsb = (v[15] & 1) != 0;
      for (int j = 15; j > 0; j--) {
        v[j] = ((v[j] >> 1) | ((v[j - 1] & 1) << 7)) & 0xff;
      }
      v[0] = (v[0] >> 1) & 0xff;
      if (lsb) {
        v[0] ^= 0xe1; // R = 11100001 || 0^120
      }
    }
    x.setAll(0, z);
  }

  // --- NIST FIPS-197 AES-256 Block Cipher ---

  static const List<int> _sbox = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
  ];

  static const List<int> _rcon = [
    0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40,
  ];

  static Uint8List _expandAes256Key(Uint8List key) {
    // 14 rounds + 1 = 15 round keys = 240 bytes
    final rk = Uint8List(240)..setRange(0, 32, key);
    int rconIdx = 1;
    int bytesGenerated = 32;
    final temp = Uint8List(4);
    while (bytesGenerated < 240) {
      for (int i = 0; i < 4; i++) {
        temp[i] = rk[bytesGenerated - 4 + i];
      }
      if (bytesGenerated % 32 == 0) {
        final t0 = temp[0];
        temp[0] = _sbox[temp[1]] ^ _rcon[rconIdx++];
        temp[1] = _sbox[temp[2]];
        temp[2] = _sbox[temp[3]];
        temp[3] = _sbox[t0];
      } else if (bytesGenerated % 32 == 16) {
        temp[0] = _sbox[temp[0]];
        temp[1] = _sbox[temp[1]];
        temp[2] = _sbox[temp[2]];
        temp[3] = _sbox[temp[3]];
      }
      for (int i = 0; i < 4; i++) {
        rk[bytesGenerated] = rk[bytesGenerated - 32] ^ temp[i];
        bytesGenerated++;
      }
    }
    return rk;
  }

  static int _xtime(int a) => ((a << 1) ^ ((a & 0x80) != 0 ? 0x1b : 0)) & 0xff;

  static Uint8List _aes256EncryptBlock(Uint8List input, Uint8List rk) {
    final s = Uint8List.fromList(input);
    // Initial AddRoundKey
    for (int i = 0; i < 16; i++) {
      s[i] ^= rk[i];
    }

    for (int round = 1; round <= 14; round++) {
      // SubBytes
      for (int i = 0; i < 16; i++) {
        s[i] = _sbox[s[i]];
      }

      // ShiftRows (column-major state)
      int t = s[1];
      s[1] = s[5];
      s[5] = s[9];
      s[9] = s[13];
      s[13] = t;

      t = s[2];
      s[2] = s[10];
      s[10] = t;
      t = s[6];
      s[6] = s[14];
      s[14] = t;

      t = s[15];
      s[15] = s[11];
      s[11] = s[7];
      s[7] = s[3];
      s[3] = t;

      // MixColumns (skip on final round 14)
      if (round < 14) {
        for (int c = 0; c < 4; c++) {
          final i = c * 4;
          final a0 = s[i];
          final a1 = s[i + 1];
          final a2 = s[i + 2];
          final a3 = s[i + 3];
          final xorAll = a0 ^ a1 ^ a2 ^ a3;
          s[i] = a0 ^ xorAll ^ _xtime(a0 ^ a1);
          s[i + 1] = a1 ^ xorAll ^ _xtime(a1 ^ a2);
          s[i + 2] = a2 ^ xorAll ^ _xtime(a2 ^ a3);
          s[i + 3] = a3 ^ xorAll ^ _xtime(a3 ^ a0);
        }
      }

      // AddRoundKey
      final rkOff = round * 16;
      for (int i = 0; i < 16; i++) {
        s[i] ^= rk[rkOff + i];
      }
    }
    return s;
  }
}
