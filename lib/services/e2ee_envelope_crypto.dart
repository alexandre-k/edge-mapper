import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'argon2_runner.dart';

export 'argon2_runner.dart' show Argon2Params, deriveArgon2idAsync;

/// Overwrites every byte of [buffer] in-place with zero to minimize sensitive
/// key lifetime in volatile memory.
void zeroize(Uint8List? buffer) {
  if (buffer == null || buffer.isEmpty) return;
  buffer.fillRange(0, buffer.length, 0);
}

/// Zeroizes every non-null buffer in [buffers].
void zeroizeAll(Iterable<Uint8List?> buffers) {
  for (final buf in buffers) {
    zeroize(buf);
  }
}

/// Constant-time byte-slice comparison.
bool constantTimeEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Generates [length] cryptographically secure random bytes.
Uint8List secureRandomBytes(int length, {Random? random}) {
  final rng = random ?? Random.secure();
  final out = Uint8List(length);
  for (int i = 0; i < length; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

/// Thrown when AEAD authentication tag verification fails (tampered ciphertext,
/// modified nonce, wrong key, or AAD / document path mismatch).
class E2eeAuthTagException implements Exception {
  final String message;

  const E2eeAuthTagException([
    this.message =
        'Authentication tag verification failed: wrong key, tampered ciphertext/nonce, or AAD mismatch.',
  ]);

  @override
  String toString() => message;
}

// =============================================================================
// 1. HKDF-SHA256 (RFC 5869)
// =============================================================================

class HkdfSha256 {
  static const int hashLength = 32;

  static Uint8List extract({
    required Uint8List ikm,
    Uint8List? salt,
  }) {
    final effectiveSalt =
        (salt == null || salt.isEmpty) ? Uint8List(hashLength) : salt;
    final mac = Hmac(sha256, effectiveSalt).convert(ikm);
    return Uint8List.fromList(mac.bytes);
  }

  static Uint8List expand({
    required Uint8List prk,
    required Uint8List info,
    required int length,
  }) {
    if (length <= 0 || length > 255 * hashLength) {
      throw ArgumentError.value(length, 'length', 'Invalid HKDF output length');
    }
    final blocks = (length + hashLength - 1) ~/ hashLength;
    final out = Uint8List(length);
    Uint8List prev = Uint8List(0);
    int written = 0;

    for (int counter = 1; counter <= blocks; counter++) {
      final input = Uint8List(prev.length + info.length + 1)
        ..setRange(0, prev.length, prev)
        ..setRange(prev.length, prev.length + info.length, info);
      input[prev.length + info.length] = counter;
      final t = Uint8List.fromList(Hmac(sha256, prk).convert(input).bytes);
      final take =
          (length - written) < hashLength ? (length - written) : hashLength;
      out.setRange(written, written + take, t);
      written += take;
      prev = t;
    }
    return out;
  }

  static Uint8List deriveKey({
    required Uint8List ikm,
    Uint8List? salt,
    required Uint8List info,
    int length = 32,
  }) {
    final prk = extract(ikm: ikm, salt: salt);
    try {
      return expand(prk: prk, info: info, length: length);
    } finally {
      zeroize(prk);
    }
  }
}

// =============================================================================
// 2. XChaCha20-Poly1305 (draft-irtf-cfrg-xchacha + RFC 8439)
//    100% 32-bit / 13-bit limb Web-safe & Dart-VM-safe arithmetic.
// =============================================================================

class XChaCha20Poly1305 {
  static const int keyLength = 32;
  static const int nonceLength = 24;
  static const int tagLength = 16;

  static const int _c0 = 0x61707865; // "expa"
  static const int _c1 = 0x3320646e; // "nd 3"
  static const int _c2 = 0x79622d32; // "2-by"
  static const int _c3 = 0x6b206574; // "te k"

  /// Encrypts [plaintext] with 256-bit [key], 192-bit [nonce], and [aad].
  /// Returns `ciphertext || 16-byte Poly1305 authentication tag`.
  static Uint8List encrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
    Uint8List? aad,
  }) {
    _validateKeyAndNonce(key, nonce);
    final subkey = hChaCha20(key, Uint8List.sublistView(nonce, 0, 16));
    final ietfNonce = Uint8List(12)
      ..setRange(4, 12, Uint8List.sublistView(nonce, 16, 24));
    try {
      return chacha20Poly1305Encrypt(
        key: subkey,
        nonce: ietfNonce,
        plaintext: plaintext,
        aad: aad ?? Uint8List(0),
      );
    } finally {
      zeroize(subkey);
      zeroize(ietfNonce);
    }
  }

  /// Decrypts `ciphertext || tag` using 256-bit [key], 192-bit [nonce], and [aad].
  /// Throws [E2eeAuthTagException] if tag verification fails.
  static Uint8List decrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertextWithTag,
    Uint8List? aad,
  }) {
    _validateKeyAndNonce(key, nonce);
    if (ciphertextWithTag.length < tagLength) {
      throw const E2eeAuthTagException('Ciphertext shorter than 16-byte tag.');
    }
    final subkey = hChaCha20(key, Uint8List.sublistView(nonce, 0, 16));
    final ietfNonce = Uint8List(12)
      ..setRange(4, 12, Uint8List.sublistView(nonce, 16, 24));
    try {
      return chacha20Poly1305Decrypt(
        key: subkey,
        nonce: ietfNonce,
        ciphertextWithTag: ciphertextWithTag,
        aad: aad ?? Uint8List(0),
      );
    } finally {
      zeroize(subkey);
      zeroize(ietfNonce);
    }
  }

  /// HChaCha20 subkey derivation (draft-irtf-cfrg-xchacha §2.2).
  static Uint8List hChaCha20(Uint8List key, Uint8List nonce16) {
    if (key.length != 32) {
      throw ArgumentError.value(key.length, 'key', 'Must be 32 bytes');
    }
    if (nonce16.length != 16) {
      throw ArgumentError.value(nonce16.length, 'nonce16', 'Must be 16 bytes');
    }
    final state = Uint32List(16);
    state[0] = _c0;
    state[1] = _c1;
    state[2] = _c2;
    state[3] = _c3;
    for (int i = 0; i < 8; i++) {
      state[4 + i] = _loadLe32(key, i * 4);
    }
    for (int i = 0; i < 4; i++) {
      state[12 + i] = _loadLe32(nonce16, i * 4);
    }

    for (int round = 0; round < 10; round++) {
      _qr(state, 0, 4, 8, 12);
      _qr(state, 1, 5, 9, 13);
      _qr(state, 2, 6, 10, 14);
      _qr(state, 3, 7, 11, 15);
      _qr(state, 0, 5, 10, 15);
      _qr(state, 1, 6, 11, 12);
      _qr(state, 2, 7, 8, 13);
      _qr(state, 3, 4, 9, 14);
    }

    final out = Uint8List(32);
    for (int i = 0; i < 4; i++) {
      _storeLe32(out, i * 4, state[i]);
      _storeLe32(out, 16 + i * 4, state[12 + i]);
    }
    state.fillRange(0, 16, 0);
    return out;
  }

  /// RFC 8439 ChaCha20-Poly1305 AEAD encrypt (12-byte nonce).
  static Uint8List chacha20Poly1305Encrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
    required Uint8List aad,
  }) {
    if (key.length != 32 || nonce.length != 12) {
      throw ArgumentError('ChaCha20-Poly1305 requires 32-byte key and 12-byte nonce.');
    }
    final block0 = _chacha20Block(key, 0, nonce);
    final otk = Uint8List.fromList(block0.sublist(0, 32));
    zeroize(block0);
    try {
      final ciphertext = _chacha20Xor(key, 1, nonce, plaintext);
      final tag = _computeAeadTag(otk, aad, ciphertext);
      final out = Uint8List(ciphertext.length + tagLength)
        ..setRange(0, ciphertext.length, ciphertext)
        ..setRange(ciphertext.length, ciphertext.length + tagLength, tag);
      return out;
    } finally {
      zeroize(otk);
    }
  }

  /// RFC 8439 ChaCha20-Poly1305 AEAD decrypt (12-byte nonce).
  static Uint8List chacha20Poly1305Decrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertextWithTag,
    required Uint8List aad,
  }) {
    if (key.length != 32 || nonce.length != 12) {
      throw ArgumentError('ChaCha20-Poly1305 requires 32-byte key and 12-byte nonce.');
    }
    if (ciphertextWithTag.length < tagLength) {
      throw const E2eeAuthTagException('Ciphertext shorter than 16-byte tag.');
    }
    final ctLen = ciphertextWithTag.length - tagLength;
    final ciphertext = Uint8List.sublistView(ciphertextWithTag, 0, ctLen);
    final providedTag =
        Uint8List.sublistView(ciphertextWithTag, ctLen, ciphertextWithTag.length);

    final block0 = _chacha20Block(key, 0, nonce);
    final otk = Uint8List.fromList(block0.sublist(0, 32));
    zeroize(block0);
    try {
      final expectedTag = _computeAeadTag(otk, aad, ciphertext);
      if (!constantTimeEquals(expectedTag, providedTag)) {
        throw const E2eeAuthTagException();
      }
      return _chacha20Xor(key, 1, nonce, ciphertext);
    } finally {
      zeroize(otk);
    }
  }

  static void _validateKeyAndNonce(Uint8List key, Uint8List nonce) {
    if (key.length != keyLength) {
      throw ArgumentError.value(
        key.length,
        'key',
        'XChaCha20-Poly1305 key must be 32 bytes.',
      );
    }
    if (nonce.length != nonceLength) {
      throw ArgumentError.value(
        nonce.length,
        'nonce',
        'XChaCha20-Poly1305 nonce must be 24 bytes (192 bits).',
      );
    }
  }

  static Uint8List _chacha20Block(Uint8List key, int counter, Uint8List nonce12) {
    final init = Uint32List(16);
    init[0] = _c0;
    init[1] = _c1;
    init[2] = _c2;
    init[3] = _c3;
    for (int i = 0; i < 8; i++) {
      init[4 + i] = _loadLe32(key, i * 4);
    }
    init[12] = counter & 0xffffffff;
    init[13] = _loadLe32(nonce12, 0);
    init[14] = _loadLe32(nonce12, 4);
    init[15] = _loadLe32(nonce12, 8);

    final w = Uint32List.fromList(init);
    for (int round = 0; round < 10; round++) {
      _qr(w, 0, 4, 8, 12);
      _qr(w, 1, 5, 9, 13);
      _qr(w, 2, 6, 10, 14);
      _qr(w, 3, 7, 11, 15);
      _qr(w, 0, 5, 10, 15);
      _qr(w, 1, 6, 11, 12);
      _qr(w, 2, 7, 8, 13);
      _qr(w, 3, 4, 9, 14);
    }

    final out = Uint8List(64);
    for (int i = 0; i < 16; i++) {
      _storeLe32(out, i * 4, (w[i] + init[i]) & 0xffffffff);
    }
    init.fillRange(0, 16, 0);
    w.fillRange(0, 16, 0);
    return out;
  }

  static Uint8List _chacha20Xor(
    Uint8List key,
    int initialCounter,
    Uint8List nonce12,
    Uint8List input,
  ) {
    final out = Uint8List(input.length);
    if (input.isEmpty) return out;
    int counter = initialCounter;
    for (int offset = 0; offset < input.length; offset += 64) {
      final block = _chacha20Block(key, counter, nonce12);
      counter = (counter + 1) & 0xffffffff;
      final remaining = input.length - offset;
      final n = remaining < 64 ? remaining : 64;
      for (int i = 0; i < n; i++) {
        out[offset + i] = input[offset + i] ^ block[i];
      }
      zeroize(block);
    }
    return out;
  }

  static void _qr(Uint32List s, int a, int b, int c, int d) {
    s[a] = (s[a] + s[b]) & 0xffffffff;
    s[d] = _rotl32(s[d] ^ s[a], 16);
    s[c] = (s[c] + s[d]) & 0xffffffff;
    s[b] = _rotl32(s[b] ^ s[c], 12);
    s[a] = (s[a] + s[b]) & 0xffffffff;
    s[d] = _rotl32(s[d] ^ s[a], 8);
    s[c] = (s[c] + s[d]) & 0xffffffff;
    s[b] = _rotl32(s[b] ^ s[c], 7);
  }

  static int _rotl32(int v, int n) =>
      ((v << n) | (v >>> (32 - n))) & 0xffffffff;

  static Uint8List _computeAeadTag(
    Uint8List otk,
    Uint8List aad,
    Uint8List ciphertext,
  ) {
    final aadPad = (16 - (aad.length % 16)) % 16;
    final ctPad = (16 - (ciphertext.length % 16)) % 16;
    final total = aad.length + aadPad + ciphertext.length + ctPad + 16;
    final macData = Uint8List(total);
    int pos = 0;
    macData.setRange(pos, pos + aad.length, aad);
    pos += aad.length + aadPad;
    macData.setRange(pos, pos + ciphertext.length, ciphertext);
    pos += ciphertext.length + ctPad;
    _storeLe64(macData, pos, aad.length);
    _storeLe64(macData, pos + 8, ciphertext.length);
    return poly1305Mac(otk, macData);
  }

  /// RFC 8439 Poly1305 MAC using 10 limbs of 13 bits (radix 2^13 = 8192).
  /// Max intermediate sum < 2^33 << 2^53, so it is 100% exact on both
  /// Dart VM (64-bit) and Dart2JS Web (53-bit IEEE-754 integers).
  static Uint8List poly1305Mac(Uint8List key32, Uint8List msg) {
    if (key32.length != 32) {
      throw ArgumentError.value(key32.length, 'key32', 'Must be 32 bytes');
    }
    // Clamp r (first 16 bytes)
    final rBytes = Uint8List.fromList(key32.sublist(0, 16));
    rBytes[3] &= 15;
    rBytes[7] &= 15;
    rBytes[11] &= 15;
    rBytes[15] &= 15;
    rBytes[4] &= 252;
    rBytes[8] &= 252;
    rBytes[12] &= 252;

    final r = List<int>.filled(10, 0);
    _unpack13(rBytes, 16, r, addHiBit: false);
    final r5 = List<int>.generate(10, (i) => r[i] * 5);

    final h = List<int>.filled(10, 0);
    final b = List<int>.filled(10, 0);
    final d = List<int>.filled(10, 0);
    final block = Uint8List(17);

    for (int offset = 0; offset < msg.length; offset += 16) {
      final remaining = msg.length - offset;
      final n = remaining < 16 ? remaining : 16;
      block.fillRange(0, 17, 0);
      block.setRange(0, n, msg, offset);
      block[n] = 1; // Append 0x01 hibit per RFC 8439 §2.5

      _unpack13(block, n + 1, b, addHiBit: false);
      for (int i = 0; i < 10; i++) {
        h[i] += b[i];
      }

      // Multiply h * r mod (2^130 - 5)
      for (int k = 0; k < 10; k++) {
        int acc = 0;
        for (int i = 0; i <= k; i++) {
          acc += h[i] * r[k - i];
        }
        for (int i = k + 1; i < 10; i++) {
          acc += h[i] * r5[10 + k - i];
        }
        d[k] = acc;
      }

      // Carry propagation (radix 2^13 = 8192, avoiding 32-bit JS shift truncation)
      int c = 0;
      for (int i = 0; i < 10; i++) {
        final v = d[i] + c;
        c = v ~/ 8192;
        h[i] = v - c * 8192;
      }
      final h0 = h[0] + c * 5;
      final c0 = h0 ~/ 8192;
      h[0] = h0 - c0 * 8192;
      h[1] += c0;
    }

    // Final full carry pass
    int c = 0;
    for (int i = 0; i < 10; i++) {
      final v = h[i] + c;
      c = v ~/ 8192;
      h[i] = v - c * 8192;
    }
    int wrap = h[0] + c * 5;
    c = wrap ~/ 8192;
    h[0] = wrap - c * 8192;
    for (int i = 1; i < 10; i++) {
      final v = h[i] + c;
      c = v ~/ 8192;
      h[i] = v - c * 8192;
    }

    // Constant-time conditional subtraction of p = 2^130 - 5:
    // Compute g = h + 5 - 2^130
    final g = List<int>.filled(10, 0);
    int gc = 5;
    for (int i = 0; i < 10; i++) {
      final v = h[i] + gc;
      g[i] = v & 0x1fff;
      gc = v >> 13;
    }
    // If gc == 1, h + 5 >= 2^130 -> h >= p -> pick g, else pick h
    final selectG = gc & 1;
    final maskG = -selectG;
    final maskH = ~maskG;
    for (int i = 0; i < 10; i++) {
      h[i] = (h[i] & maskH) | (g[i] & maskG);
    }

    // Repack 10 x 13-bit limbs into 16 bytes (mod 2^128) and add s = key32[16..32]
    final hBytes = Uint8List(16);
    int bitBuf = 0;
    int bitCount = 0;
    int byteIdx = 0;
    for (int i = 0; i < 10 && byteIdx < 16; i++) {
      bitBuf |= (h[i] & 0x1fff) << bitCount;
      bitCount += 13;
      while (bitCount >= 8 && byteIdx < 16) {
        hBytes[byteIdx++] = bitBuf & 0xff;
        bitBuf >>= 8;
        bitCount -= 8;
      }
    }

    final tag = Uint8List(16);
    int carry = 0;
    for (int i = 0; i < 16; i++) {
      final sum = hBytes[i] + key32[16 + i] + carry;
      tag[i] = sum & 0xff;
      carry = sum >> 8;
    }

    zeroize(rBytes);
    zeroize(block);
    zeroize(hBytes);
    return tag;
  }

  static void _unpack13(
    Uint8List bytes,
    int length,
    List<int> out10, {
    required bool addHiBit,
  }) {
    out10.fillRange(0, 10, 0);
    int bitBuf = 0;
    int bitCount = 0;
    int limbIdx = 0;
    for (int i = 0; i < length; i++) {
      bitBuf |= (bytes[i] & 0xff) << bitCount;
      bitCount += 8;
      while (bitCount >= 13 && limbIdx < 10) {
        out10[limbIdx++] = bitBuf & 0x1fff;
        bitBuf >>= 13;
        bitCount -= 13;
      }
    }
    if (bitCount > 0 && limbIdx < 10) {
      out10[limbIdx] = bitBuf & 0x1fff;
    }
    if (addHiBit) {
      out10[9] |= 1 << 11;
    }
  }
}

// =============================================================================
// 3. X25519 (RFC 7748) — TweetNaCl 16-limb radix-2^16 arithmetic
//    Constant-time Montgomery ladder, 100% Web-safe (max intermediate < 2^42).
// =============================================================================

class X25519KeyPair {
  final Uint8List publicKey;
  final Uint8List privateKey;

  X25519KeyPair({
    required this.publicKey,
    required this.privateKey,
  });

  String get publicKeyB64 => base64Encode(publicKey);

  /// Public non-secret fingerprint (`XXXX-XXXX-XXXX`) derived from `User_Pub`.
  String get publicFingerprint {
    final digest = sha256.convert(publicKey).bytes;
    final hex = digest
        .take(6)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return '${hex.substring(0, 4)}-${hex.substring(4, 8)}-${hex.substring(8, 12)}';
  }

  /// Zeroizes `User_Priv` in volatile RAM.
  void zeroizePrivate() {
    zeroize(privateKey);
  }
}

class X25519 {
  static const int keyLength = 32;

  static final Uint8List _basePoint = Uint8List(32)..[0] = 9;

  /// Generates a fresh RFC 7748 X25519 keypair (`User_Priv`, `User_Pub`).
  static X25519KeyPair generateKeyPair({Random? random}) {
    final priv = secureRandomBytes(keyLength, random: random);
    // Clamp per RFC 7748 §5
    priv[0] &= 248;
    priv[31] &= 127;
    priv[31] |= 64;
    final pub = publicKeyFromPrivate(priv);
    return X25519KeyPair(publicKey: pub, privateKey: priv);
  }

  /// Derives the 32-byte X25519 public key from a 32-byte private scalar.
  static Uint8List publicKeyFromPrivate(Uint8List privateKey) {
    return scalarMult(privateKey, _basePoint, allowZeroResult: false);
  }

  /// Computes RFC 7748 X25519(scalar, uCoordinate).
  /// Rejects all-zero shared secrets by default (RFC 7748 §6.1 low-order check).
  static Uint8List scalarMult(
    Uint8List scalar,
    Uint8List uCoordinate, {
    bool allowZeroResult = false,
  }) {
    if (scalar.length != keyLength) {
      throw ArgumentError.value(scalar.length, 'scalar', 'Must be 32 bytes.');
    }
    if (uCoordinate.length != keyLength) {
      throw ArgumentError.value(
        uCoordinate.length,
        'uCoordinate',
        'Must be 32 bytes.',
      );
    }

    final z = Uint8List.fromList(scalar);
    z[0] &= 248;
    z[31] &= 127;
    z[31] |= 64;

    final x = _unpack25519(uCoordinate);
    final a = List<int>.filled(16, 0)..[0] = 1;
    final b = List<int>.from(x);
    final c = List<int>.filled(16, 0);
    final d = List<int>.filled(16, 0)..[0] = 1;
    final e = List<int>.filled(16, 0);
    final f = List<int>.filled(16, 0);

    final a24 = List<int>.filled(16, 0);
    a24[0] = 0xdb41; // 121665 = 0x01db41
    a24[1] = 1;

    try {
      for (int i = 254; i >= 0; i--) {
        final r = (z[i >> 3] >> (i & 7)) & 1;
        _sel25519(a, b, r);
        _sel25519(c, d, r);

        _add25519(e, a, c);
        _sub25519(a, a, c);
        _add25519(c, b, d);
        _sub25519(b, b, d);

        _sq25519(d, e);
        _sq25519(f, a);
        _mul25519(a, c, a);
        _mul25519(c, b, e);

        _add25519(e, a, c);
        _sub25519(a, a, c);
        _sq25519(b, a);
        _sub25519(c, d, f);
        _mul25519(a, c, a24);
        _add25519(a, a, d);
        _mul25519(c, c, a);
        _mul25519(a, d, f);
        _mul25519(d, b, x);
        _sq25519(b, e);

        _sel25519(a, b, r);
        _sel25519(c, d, r);
      }

      final cInv = List<int>.filled(16, 0);
      _inv25519(cInv, c);
      final result = List<int>.filled(16, 0);
      _mul25519(result, a, cInv);
      final out = _pack25519(result);

      if (!allowZeroResult) {
        int acc = 0;
        for (int i = 0; i < 32; i++) {
          acc |= out[i];
        }
        if (acc == 0) {
          throw const E2eeAuthTagException(
            'X25519 shared secret is all-zero (low-order public key rejected).',
          );
        }
      }
      return out;
    } finally {
      zeroize(z);
    }
  }

  static List<int> _unpack25519(Uint8List n) {
    final o = List<int>.filled(16, 0);
    for (int i = 0; i < 16; i++) {
      o[i] = n[2 * i] + (n[2 * i + 1] << 8);
    }
    o[15] &= 0x7fff; // RFC 7748 §5: mask most significant bit
    return o;
  }

  static void _carry25519(List<int> o) {
    for (int i = 0; i < 16; i++) {
      final v = o[i];
      final int c = v >= 0 ? (v ~/ 65536) : -((-v + 65535) ~/ 65536);
      o[i] = v - c * 65536;
      if (i < 15) {
        o[i + 1] += c;
      } else {
        o[0] += c * 38;
      }
    }
  }

  static void _sel25519(List<int> p, List<int> q, int b) {
    final c = ~(b - 1);
    for (int i = 0; i < 16; i++) {
      final t = c & (p[i] ^ q[i]);
      p[i] ^= t;
      q[i] ^= t;
    }
  }

  static void _add25519(List<int> o, List<int> a, List<int> b) {
    for (int i = 0; i < 16; i++) {
      o[i] = a[i] + b[i];
    }
  }

  static void _sub25519(List<int> o, List<int> a, List<int> b) {
    for (int i = 0; i < 16; i++) {
      o[i] = a[i] - b[i];
    }
  }

  static void _mul25519(List<int> o, List<int> a, List<int> b) {
    final t = List<int>.filled(31, 0);
    for (int i = 0; i < 16; i++) {
      final ai = a[i];
      for (int j = 0; j < 16; j++) {
        t[i + j] += ai * b[j];
      }
    }
    for (int i = 0; i < 15; i++) {
      t[i] += 38 * t[i + 16];
    }
    for (int i = 0; i < 16; i++) {
      o[i] = t[i];
    }
    _carry25519(o);
    _carry25519(o);
  }

  static void _sq25519(List<int> o, List<int> a) => _mul25519(o, a, a);

  static void _inv25519(List<int> o, List<int> i) {
    final c = List<int>.from(i);
    for (int a = 253; a >= 0; a--) {
      _sq25519(c, c);
      if (a != 2 && a != 4) {
        _mul25519(c, c, i);
      }
    }
    for (int j = 0; j < 16; j++) {
      o[j] = c[j];
    }
  }

  static Uint8List _pack25519(List<int> n) {
    final t = List<int>.from(n);
    _carry25519(t);
    _carry25519(t);
    _carry25519(t);
    final m = List<int>.filled(16, 0);
    for (int j = 0; j < 2; j++) {
      m[0] = t[0] - 0xffed;
      for (int i = 1; i < 15; i++) {
        m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
        m[i - 1] &= 0xffff;
      }
      m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
      final b = (m[15] >> 16) & 1;
      m[14] &= 0xffff;
      _sel25519(t, m, 1 - b);
    }
    final out = Uint8List(32);
    for (int i = 0; i < 16; i++) {
      out[2 * i] = t[i] & 0xff;
      out[2 * i + 1] = (t[i] >> 8) & 0xff;
    }
    return out;
  }
}

// =============================================================================
// 4. Blake2b (RFC 7693) & Argon2id (RFC 9106) — 100% 32-bit Web-safe
// =============================================================================

class Blake2b {
  static const List<int> _ivLo = [
    0xf3bcc908,
    0x84caa73b,
    0xfe94f82b,
    0x5f1d36f1,
    0xade682d1,
    0x2b3e6c1f,
    0xfb41bd6b,
    0x137e2179,
  ];
  static const List<int> _ivHi = [
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];

  static const List<List<int>> _sigma = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
    [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
    [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
    [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
    [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
  ];

  /// Computes unkeyed Blake2b with digest length [outLen] (1..64 bytes).
  static Uint8List hash(Uint8List input, {int outLen = 64}) {
    if (outLen < 1 || outLen > 64) {
      throw ArgumentError.value(outLen, 'outLen', 'Must be 1..64');
    }
    final hLo = Uint32List.fromList(_ivLo);
    final hHi = Uint32List.fromList(_ivHi);
    hLo[0] ^= 0x01010000 ^ outLen;

    final block = Uint8List(128);
    int tLo = 0;
    int tHi = 0;

    int offset = 0;
    while (input.length - offset > 128) {
      final newTLo = (tLo + 128) & 0xffffffff;
      if (newTLo < tLo) tHi = (tHi + 1) & 0xffffffff;
      tLo = newTLo;
      _compress(hLo, hHi, input, offset, tLo, tHi, false);
      offset += 128;
    }

    final remaining = input.length - offset;
    block.fillRange(0, 128, 0);
    if (remaining > 0) {
      block.setRange(0, remaining, input, offset);
    }
    final newTLo = (tLo + remaining) & 0xffffffff;
    if (newTLo < tLo) tHi = (tHi + 1) & 0xffffffff;
    tLo = newTLo;
    _compress(hLo, hHi, block, 0, tLo, tHi, true);

    final out = Uint8List(outLen);
    for (int i = 0; i < outLen; i++) {
      final word = i >> 3;
      final byteInWord = i & 7;
      final v = byteInWord < 4
          ? (hLo[word] >>> (byteInWord * 8))
          : (hHi[word] >>> ((byteInWord - 4) * 8));
      out[i] = v & 0xff;
    }
    return out;
  }

  static void _compress(
    Uint32List hLo,
    Uint32List hHi,
    Uint8List block,
    int blockOff,
    int tLo,
    int tHi,
    bool isLast,
  ) {
    final vLo = Uint32List(16);
    final vHi = Uint32List(16);
    for (int i = 0; i < 8; i++) {
      vLo[i] = hLo[i];
      vHi[i] = hHi[i];
      vLo[8 + i] = _ivLo[i];
      vHi[8 + i] = _ivHi[i];
    }
    vLo[12] ^= tLo;
    vHi[12] ^= tHi;
    if (isLast) {
      vLo[14] ^= 0xffffffff;
      vHi[14] ^= 0xffffffff;
    }

    final mLo = Uint32List(16);
    final mHi = Uint32List(16);
    for (int i = 0; i < 16; i++) {
      final base = blockOff + i * 8;
      mLo[i] = _loadLe32(block, base);
      mHi[i] = _loadLe32(block, base + 4);
    }

    for (int r = 0; r < 12; r++) {
      final s = _sigma[r];
      _g(vLo, vHi, 0, 4, 8, 12, mLo[s[0]], mHi[s[0]], mLo[s[1]], mHi[s[1]]);
      _g(vLo, vHi, 1, 5, 9, 13, mLo[s[2]], mHi[s[2]], mLo[s[3]], mHi[s[3]]);
      _g(vLo, vHi, 2, 6, 10, 14, mLo[s[4]], mHi[s[4]], mLo[s[5]], mHi[s[5]]);
      _g(vLo, vHi, 3, 7, 11, 15, mLo[s[6]], mHi[s[6]], mLo[s[7]], mHi[s[7]]);
      _g(vLo, vHi, 0, 5, 10, 15, mLo[s[8]], mHi[s[8]], mLo[s[9]], mHi[s[9]]);
      _g(vLo, vHi, 1, 6, 11, 12, mLo[s[10]], mHi[s[10]], mLo[s[11]], mHi[s[11]]);
      _g(vLo, vHi, 2, 7, 8, 13, mLo[s[12]], mHi[s[12]], mLo[s[13]], mHi[s[13]]);
      _g(vLo, vHi, 3, 4, 9, 14, mLo[s[14]], mHi[s[14]], mLo[s[15]], mHi[s[15]]);
    }

    for (int i = 0; i < 8; i++) {
      hLo[i] ^= vLo[i] ^ vLo[8 + i];
      hHi[i] ^= vHi[i] ^ vHi[8 + i];
    }
  }

  static void _g(
    Uint32List vLo,
    Uint32List vHi,
    int a,
    int b,
    int c,
    int d,
    int xLo,
    int xHi,
    int yLo,
    int yHi,
  ) {
    int aLo = vLo[a];
    int aHi = vHi[a];
    int bLo = vLo[b];
    int bHi = vHi[b];
    int cLo = vLo[c];
    int cHi = vHi[c];
    int dLo = vLo[d];
    int dHi = vHi[d];

    // a = a + b + x
    int sum = aLo + bLo;
    int carry = sum > 0xffffffff ? 1 : 0;
    aLo = sum & 0xffffffff;
    aHi = (aHi + bHi + carry) & 0xffffffff;
    sum = aLo + xLo;
    carry = sum > 0xffffffff ? 1 : 0;
    aLo = sum & 0xffffffff;
    aHi = (aHi + xHi + carry) & 0xffffffff;

    // d = rotr64(d ^ a, 32)
    int tLo = dLo ^ aLo;
    int tHi = dHi ^ aHi;
    dLo = tHi;
    dHi = tLo;

    // c = c + d
    sum = cLo + dLo;
    carry = sum > 0xffffffff ? 1 : 0;
    cLo = sum & 0xffffffff;
    cHi = (cHi + dHi + carry) & 0xffffffff;

    // b = rotr64(b ^ c, 24)
    tLo = bLo ^ cLo;
    tHi = bHi ^ cHi;
    bLo = ((tLo >>> 24) | (tHi << 8)) & 0xffffffff;
    bHi = ((tHi >>> 24) | (tLo << 8)) & 0xffffffff;

    // a = a + b + y
    sum = aLo + bLo;
    carry = sum > 0xffffffff ? 1 : 0;
    aLo = sum & 0xffffffff;
    aHi = (aHi + bHi + carry) & 0xffffffff;
    sum = aLo + yLo;
    carry = sum > 0xffffffff ? 1 : 0;
    aLo = sum & 0xffffffff;
    aHi = (aHi + yHi + carry) & 0xffffffff;

    // d = rotr64(d ^ a, 16)
    tLo = dLo ^ aLo;
    tHi = dHi ^ aHi;
    dLo = ((tLo >>> 16) | (tHi << 16)) & 0xffffffff;
    dHi = ((tHi >>> 16) | (tLo << 16)) & 0xffffffff;

    // c = c + d
    sum = cLo + dLo;
    carry = sum > 0xffffffff ? 1 : 0;
    cLo = sum & 0xffffffff;
    cHi = (cHi + dHi + carry) & 0xffffffff;

    // b = rotr64(b ^ c, 63) == rotl64(b ^ c, 1)
    tLo = bLo ^ cLo;
    tHi = bHi ^ cHi;
    bLo = ((tLo << 1) | (tHi >>> 31)) & 0xffffffff;
    bHi = ((tHi << 1) | (tLo >>> 31)) & 0xffffffff;

    vLo[a] = aLo;
    vHi[a] = aHi;
    vLo[b] = bLo;
    vHi[b] = bHi;
    vLo[c] = cLo;
    vHi[c] = cHi;
    vLo[d] = dLo;
    vHi[d] = dHi;
  }
}

class Argon2id {
  /// Asynchronous RFC 9106 Argon2id key derivation (runs in a background Isolate
  /// on native platforms; 32-bit Web-safe on Flutter Web).
  static Future<Uint8List> deriveKey({
    required Uint8List password,
    required Uint8List salt,
    Argon2Params params = Argon2Params.defaultProduction,
    Uint8List? secret,
    Uint8List? associatedData,
  }) {
    return deriveArgon2idAsync(
      password: password,
      salt: salt,
      params: params,
      secret: secret,
      associatedData: associatedData,
    );
  }

  /// Computes RFC 9106 initial 64-byte H0 digest.
  static Uint8List computeH0({
    required Uint8List password,
    required Uint8List salt,
    required int memoryKiB,
    required int iterations,
    required int parallelism,
    required int keyLength,
    Uint8List? secret,
    Uint8List? associatedData,
  }) {
    final sec = secret ?? Uint8List(0);
    final ad = associatedData ?? Uint8List(0);
    final total =
        4 * 10 + password.length + salt.length + sec.length + ad.length;
    final buf = Uint8List(total);
    int pos = 0;
    void writeU32(int v) {
      _storeLe32(buf, pos, v);
      pos += 4;
    }

    writeU32(parallelism);
    writeU32(keyLength);
    writeU32(memoryKiB);
    writeU32(iterations);
    writeU32(0x13); // Version 19
    writeU32(2); // Type = Argon2id (2)
    writeU32(password.length);
    buf.setRange(pos, pos + password.length, password);
    pos += password.length;
    writeU32(salt.length);
    buf.setRange(pos, pos + salt.length, salt);
    pos += salt.length;
    writeU32(sec.length);
    buf.setRange(pos, pos + sec.length, sec);
    pos += sec.length;
    writeU32(ad.length);
    buf.setRange(pos, pos + ad.length, ad);

    try {
      return Blake2b.hash(buf, outLen: 64);
    } finally {
      zeroize(buf);
    }
  }

  /// RFC 9106 §3.3 variable-length Blake2b hash function `H'`.
  static Uint8List blake2bLong(Uint8List input, int outLen) {
    final prefixed = Uint8List(4 + input.length);
    _storeLe32(prefixed, 0, outLen);
    prefixed.setRange(4, prefixed.length, input);
    if (outLen <= 64) {
      return Blake2b.hash(prefixed, outLen: outLen);
    }
    final out = Uint8List(outLen);
    var v = Blake2b.hash(prefixed, outLen: 64);
    out.setRange(0, 32, v);
    int written = 32;
    while (outLen - written > 64) {
      v = Blake2b.hash(v, outLen: 64);
      out.setRange(written, written + 32, v);
      written += 32;
    }
    final last = Blake2b.hash(v, outLen: outLen - written);
    out.setRange(written, outLen, last);
    return out;
  }

  /// 100% 32-bit safe RFC 9106 Argon2id implementation (runs identically on
  /// Dart2JS Web and Dart VM).
  static Uint8List deriveKeyPure32({
    required Uint8List password,
    required Uint8List salt,
    Argon2Params params = Argon2Params.defaultProduction,
    Uint8List? secret,
    Uint8List? associatedData,
  }) {
    final parallelism = params.parallelism;
    final iterations = params.iterations;
    final memoryKiB = params.memoryKiB;
    final keyLength = params.keyLength;

    if (parallelism < 1 || iterations < 1 || memoryKiB < 8 * parallelism || keyLength < 4) {
      throw ArgumentError('Invalid Argon2id parameters.');
    }

    final h0 = computeH0(
      password: password,
      salt: salt,
      memoryKiB: memoryKiB,
      iterations: iterations,
      parallelism: parallelism,
      keyLength: keyLength,
      secret: secret,
      associatedData: associatedData,
    );

    final segmentLength = memoryKiB ~/ (4 * parallelism);
    final laneLength = segmentLength * 4;
    final totalBlocks = laneLength * parallelism;

    // Flat 32-bit word buffer: 256 uint32s (128 (lo,hi) uint64 pairs = 1024 bytes) per block.
    final memory = Uint32List(totalBlocks * 256);
    final zeroBlock = Uint32List(256);
    final inputBlock = Uint32List(256);
    final addressBlock = Uint32List(256);
    final tmpR = Uint32List(256);
    final tmpZ = Uint32List(256);

    try {
      final seedBuf = Uint8List(72);
      seedBuf.setRange(0, 64, h0);
      for (int lane = 0; lane < parallelism; lane++) {
        _storeLe32(seedBuf, 68, lane);

        _storeLe32(seedBuf, 64, 0);
        final b0 = blake2bLong(seedBuf, 1024);
        _bytesToWords32(b0, memory, (lane * laneLength) * 256);

        _storeLe32(seedBuf, 64, 1);
        final b1 = blake2bLong(seedBuf, 1024);
        _bytesToWords32(b1, memory, (lane * laneLength + 1) * 256);
      }

      for (int pass = 0; pass < iterations; pass++) {
        for (int slice = 0; slice < 4; slice++) {
          for (int lane = 0; lane < parallelism; lane++) {
            final dataIndependent = pass == 0 && slice < 2;
            int addressCounter = 0;
            int addressOffset = 128;

            if (dataIndependent) {
              inputBlock.fillRange(0, 256, 0);
              inputBlock[0] = pass;
              inputBlock[2] = lane;
              inputBlock[4] = slice;
              inputBlock[6] = totalBlocks;
              inputBlock[8] = iterations;
              inputBlock[10] = 2; // Argon2id type = 2
            }

            final startIndex = (pass == 0 && slice == 0) ? 2 : 0;
            final laneBase = lane * laneLength;

            for (int index = startIndex; index < segmentLength; index++) {
              final currOffset = slice * segmentLength + index;
              final prevOffset =
                  currOffset == 0 ? laneLength - 1 : currOffset - 1;
              final prevBase = (laneBase + prevOffset) * 256;
              final currBase = (laneBase + currOffset) * 256;

              int j1;
              int j2;
              if (dataIndependent) {
                if (addressOffset >= 128) {
                  addressCounter++;
                  inputBlock[12] = addressCounter;
                  _compress32(
                    zeroBlock,
                    0,
                    inputBlock,
                    0,
                    addressBlock,
                    0,
                    false,
                    tmpR,
                    tmpZ,
                  );
                  _compress32(
                    zeroBlock,
                    0,
                    addressBlock,
                    0,
                    addressBlock,
                    0,
                    false,
                    tmpR,
                    tmpZ,
                  );
                  addressOffset = 0;
                }
                j1 = addressBlock[addressOffset * 2];
                j2 = addressBlock[addressOffset * 2 + 1];
                addressOffset++;
              } else {
                j1 = memory[prevBase];
                j2 = memory[prevBase + 1];
              }

              final refLane =
                  (pass == 0 && slice == 0) ? lane : (j2 % parallelism);

              int refAreaSize;
              if (pass == 0) {
                if (slice == 0) {
                  refAreaSize = index - 1;
                } else if (refLane == lane) {
                  refAreaSize = slice * segmentLength + index - 1;
                } else {
                  refAreaSize =
                      slice * segmentLength + (index == 0 ? -1 : 0);
                }
              } else {
                if (refLane == lane) {
                  refAreaSize = laneLength - segmentLength + index - 1;
                } else {
                  refAreaSize =
                      laneLength - segmentLength + (index == 0 ? -1 : 0);
                }
              }

              // Exact 32x32 -> high-32 product safe in 53-bit JS integers!
              final x = _mulHiU32(j1, j1);
              final y = _mulHiU32(refAreaSize, x);
              final relPos = refAreaSize - 1 - y;

              int startPos = 0;
              if (pass != 0) {
                startPos = slice == 3 ? 0 : (slice + 1) * segmentLength;
              }
              final refIndex = (startPos + relPos) % laneLength;
              final refBase = (refLane * laneLength + refIndex) * 256;

              _compress32(
                memory,
                prevBase,
                memory,
                refBase,
                memory,
                currBase,
                pass != 0,
                tmpR,
                tmpZ,
              );
            }
          }
        }
      }

      final finalBlock = Uint32List(256);
      for (int lane = 0; lane < parallelism; lane++) {
        final lastBase = (lane * laneLength + laneLength - 1) * 256;
        for (int i = 0; i < 256; i++) {
          finalBlock[i] ^= memory[lastBase + i];
        }
      }
      final finalBytes = _words32ToBytes(finalBlock);
      final out = blake2bLong(finalBytes, keyLength);
      zeroize(finalBytes);
      finalBlock.fillRange(0, 256, 0);
      return out;
    } finally {
      zeroize(h0);
      memory.fillRange(0, memory.length, 0);
      inputBlock.fillRange(0, 256, 0);
      addressBlock.fillRange(0, 256, 0);
      tmpR.fillRange(0, 256, 0);
      tmpZ.fillRange(0, 256, 0);
    }
  }

  /// Exact high 32 bits of unsigned `a * b` using 16-bit limbs (100% Web-safe).
  static int _mulHiU32(int a, int b) {
    final a0 = a & 0xffff;
    final a1 = a >>> 16;
    final b0 = b & 0xffff;
    final b1 = b >>> 16;
    final lo = a0 * b0;
    final mid1 = a1 * b0 + (lo >>> 16);
    final mid2 = a0 * b1 + (mid1 & 0xffff);
    return (a1 * b1 + (mid1 >>> 16) + (mid2 >>> 16)) & 0xffffffff;
  }

  /// Adds `a + b + 2 * (lo32(a) * lo32(b))` mod 2^64 using 32-bit pairs.
  static void _fBlaMka32(Uint32List v, int aIdx, int bIdx) {
    final aOff = aIdx * 2;
    final bOff = bIdx * 2;
    final aLo = v[aOff];
    final aHi = v[aOff + 1];
    final bLo = v[bOff];
    final bHi = v[bOff + 1];

    // Exact 32x32 -> 64-bit unsigned product (pLo, pHi)
    final a0 = aLo & 0xffff;
    final a1 = aLo >>> 16;
    final b0 = bLo & 0xffff;
    final b1 = bLo >>> 16;
    final lolo = a0 * b0;
    final mid1 = a1 * b0 + (lolo >>> 16);
    final mid2 = a0 * b1 + (mid1 & 0xffff);
    final pLo = ((mid2 & 0xffff) << 16) | (lolo & 0xffff);
    final pHi = (a1 * b1 + (mid1 >>> 16) + (mid2 >>> 16)) & 0xffffffff;

    // 2 * product
    final twoPLo = (pLo << 1) & 0xffffffff;
    final twoPHi = ((pHi << 1) | (pLo >>> 31)) & 0xffffffff;

    // a + b + 2*product
    final sumLo = aLo + bLo + twoPLo;
    final carry = sumLo ~/ 4294967296;
    v[aOff] = sumLo & 0xffffffff;
    v[aOff + 1] = (aHi + bHi + twoPHi + carry) & 0xffffffff;
  }

  static void _gb32(Uint32List v, int a, int b, int c, int d) {
    final aOff = a * 2;
    final bOff = b * 2;
    final cOff = c * 2;
    final dOff = d * 2;

    _fBlaMka32(v, a, b);
    // d = rotr64(d ^ a, 32)
    int tLo = v[dOff] ^ v[aOff];
    int tHi = v[dOff + 1] ^ v[aOff + 1];
    v[dOff] = tHi;
    v[dOff + 1] = tLo;

    _fBlaMka32(v, c, d);
    // b = rotr64(b ^ c, 24)
    tLo = v[bOff] ^ v[cOff];
    tHi = v[bOff + 1] ^ v[cOff + 1];
    v[bOff] = ((tLo >>> 24) | (tHi << 8)) & 0xffffffff;
    v[bOff + 1] = ((tHi >>> 24) | (tLo << 8)) & 0xffffffff;

    _fBlaMka32(v, a, b);
    // d = rotr64(d ^ a, 16)
    tLo = v[dOff] ^ v[aOff];
    tHi = v[dOff + 1] ^ v[aOff + 1];
    v[dOff] = ((tLo >>> 16) | (tHi << 16)) & 0xffffffff;
    v[dOff + 1] = ((tHi >>> 16) | (tLo << 16)) & 0xffffffff;

    _fBlaMka32(v, c, d);
    // b = rotr64(b ^ c, 63) == rotl64(b ^ c, 1)
    tLo = v[bOff] ^ v[cOff];
    tHi = v[bOff + 1] ^ v[cOff + 1];
    v[bOff] = ((tLo << 1) | (tHi >>> 31)) & 0xffffffff;
    v[bOff + 1] = ((tHi << 1) | (tLo >>> 31)) & 0xffffffff;
  }

  static void _p32(
    Uint32List v,
    int v0,
    int v1,
    int v2,
    int v3,
    int v4,
    int v5,
    int v6,
    int v7,
    int v8,
    int v9,
    int v10,
    int v11,
    int v12,
    int v13,
    int v14,
    int v15,
  ) {
    _gb32(v, v0, v4, v8, v12);
    _gb32(v, v1, v5, v9, v13);
    _gb32(v, v2, v6, v10, v14);
    _gb32(v, v3, v7, v11, v15);
    _gb32(v, v0, v5, v10, v15);
    _gb32(v, v1, v6, v11, v12);
    _gb32(v, v2, v7, v8, v13);
    _gb32(v, v3, v4, v9, v14);
  }

  static void _compress32(
    Uint32List xBuf,
    int xOff,
    Uint32List yBuf,
    int yOff,
    Uint32List outBuf,
    int outOff,
    bool xorOut,
    Uint32List r,
    Uint32List z,
  ) {
    for (int i = 0; i < 256; i++) {
      final v = xBuf[xOff + i] ^ yBuf[yOff + i];
      r[i] = v;
      z[i] = v;
    }

    for (int row = 0; row < 8; row++) {
      final b = row * 16;
      _p32(
        z,
        b + 0,
        b + 1,
        b + 2,
        b + 3,
        b + 4,
        b + 5,
        b + 6,
        b + 7,
        b + 8,
        b + 9,
        b + 10,
        b + 11,
        b + 12,
        b + 13,
        b + 14,
        b + 15,
      );
    }

    for (int col = 0; col < 8; col++) {
      final c = col * 2;
      _p32(
        z,
        c + 0,
        c + 1,
        c + 16,
        c + 17,
        c + 32,
        c + 33,
        c + 48,
        c + 49,
        c + 64,
        c + 65,
        c + 80,
        c + 81,
        c + 96,
        c + 97,
        c + 112,
        c + 113,
      );
    }

    if (xorOut) {
      for (int i = 0; i < 256; i++) {
        outBuf[outOff + i] ^= r[i] ^ z[i];
      }
    } else {
      for (int i = 0; i < 256; i++) {
        outBuf[outOff + i] = r[i] ^ z[i];
      }
    }
  }

  static void _bytesToWords32(Uint8List src, Uint32List dst, int dstOff) {
    for (int i = 0; i < 256; i++) {
      dst[dstOff + i] = _loadLe32(src, i * 4);
    }
  }

  static Uint8List _words32ToBytes(Uint32List src) {
    final out = Uint8List(1024);
    for (int i = 0; i < 256; i++) {
      _storeLe32(out, i * 4, src[i]);
    }
    return out;
  }
}

// =============================================================================
// 5. High-Level Zero-Knowledge Envelope Encryption, Keyring & Link Sharing
// =============================================================================

/// Ephemeral X25519 + XChaCha20-Poly1305 wrapped `Item_DEK` envelope for a
/// single recipient in `items/{itemId}.recipients[recipientUid]`.
class WrappedDekEnvelope {
  final String epkB64;
  final String nonceB64;
  final String ciphertextB64;

  const WrappedDekEnvelope({
    required this.epkB64,
    required this.nonceB64,
    required this.ciphertextB64,
  });

  Map<String, dynamic> toJson() => {
        'epk': epkB64,
        'nonce': nonceB64,
        'ciphertext': ciphertextB64,
      };

  factory WrappedDekEnvelope.fromJson(Map<String, dynamic> json) {
    return WrappedDekEnvelope(
      epkB64: json['epk']?.toString() ?? '',
      nonceB64: json['nonce']?.toString() ?? '',
      ciphertextB64: json['ciphertext']?.toString() ?? '',
    );
  }
}

/// Encrypted Firestore item document (`items/{itemId}`):
/// - `ciphertext`: Base64 `XChaCha20-Poly1305` ciphertext+tag bound to AAD
///   `{documentPath}|v{schemaVersion}`
/// - `nonce`: Base64 24-byte `XChaCha20` nonce
/// - `recipients`: `{ [recipientUid]: WrappedDekEnvelope }`
class EncryptedItemEnvelope {
  final String documentPath;
  final int schemaVersion;
  final String ciphertextB64;
  final String nonceB64;
  final Map<String, WrappedDekEnvelope> recipients;

  const EncryptedItemEnvelope({
    required this.documentPath,
    this.schemaVersion = 1,
    required this.ciphertextB64,
    required this.nonceB64,
    required this.recipients,
  });

  EncryptedItemEnvelope copyWith({
    String? documentPath,
    int? schemaVersion,
    String? ciphertextB64,
    String? nonceB64,
    Map<String, WrappedDekEnvelope>? recipients,
  }) {
    return EncryptedItemEnvelope(
      documentPath: documentPath ?? this.documentPath,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      ciphertextB64: ciphertextB64 ?? this.ciphertextB64,
      nonceB64: nonceB64 ?? this.nonceB64,
      recipients: recipients ?? this.recipients,
    );
  }
}

/// `wrapped_priv_prf` slot in `users/{uid}/security/keyring`.
class WrappedPrfKeySlot {
  final String ciphertextB64;
  final String nonceB64;
  final String saltB64;

  const WrappedPrfKeySlot({
    required this.ciphertextB64,
    required this.nonceB64,
    required this.saltB64,
  });

  Map<String, dynamic> toJson() => {
        'ciphertext': ciphertextB64,
        'nonce': nonceB64,
        'salt': saltB64,
      };

  factory WrappedPrfKeySlot.fromJson(Map<String, dynamic> json) {
    return WrappedPrfKeySlot(
      ciphertextB64: json['ciphertext']?.toString() ?? '',
      nonceB64: json['nonce']?.toString() ?? '',
      saltB64: json['salt']?.toString() ?? '',
    );
  }
}

/// `wrapped_priv_recovery` slot in `users/{uid}/security/keyring`.
class WrappedRecoveryKeySlot {
  final String ciphertextB64;
  final String nonceB64;
  final String kdfSaltB64;
  final Argon2Params kdfParams;

  const WrappedRecoveryKeySlot({
    required this.ciphertextB64,
    required this.nonceB64,
    required this.kdfSaltB64,
    required this.kdfParams,
  });

  Map<String, dynamic> toJson() => {
        'ciphertext': ciphertextB64,
        'nonce': nonceB64,
        'kdf_salt': kdfSaltB64,
        'kdf_params': kdfParams.toJson(),
      };

  factory WrappedRecoveryKeySlot.fromJson(Map<String, dynamic> json) {
    final rawParams = json['kdf_params'];
    return WrappedRecoveryKeySlot(
      ciphertextB64: json['ciphertext']?.toString() ?? '',
      nonceB64: json['nonce']?.toString() ?? '',
      kdfSaltB64: json['kdf_salt']?.toString() ?? '',
      kdfParams: rawParams is Map
          ? Argon2Params.fromJson(Map<String, dynamic>.from(rawParams))
          : Argon2Params.defaultProduction,
    );
  }
}

/// Represents Firestore document `users/{uid}/security/keyring`.
class UserKeyring {
  final String uid;
  final String x25519PublicKeyB64;
  final WrappedPrfKeySlot? wrappedPrivPrf;
  final WrappedRecoveryKeySlot? wrappedPrivRecovery;

  const UserKeyring({
    required this.uid,
    required this.x25519PublicKeyB64,
    this.wrappedPrivPrf,
    this.wrappedPrivRecovery,
  });

  Uint8List get publicKeyBytes =>
      Uint8List.fromList(base64Decode(x25519PublicKeyB64));

  bool get hasPrfSlot =>
      wrappedPrivPrf != null &&
      wrappedPrivPrf!.ciphertextB64.isNotEmpty &&
      wrappedPrivPrf!.nonceB64.isNotEmpty;

  bool get hasRecoverySlot =>
      wrappedPrivRecovery != null &&
      wrappedPrivRecovery!.ciphertextB64.isNotEmpty &&
      wrappedPrivRecovery!.nonceB64.isNotEmpty;
}

/// Encrypted payload + fragment-only URL for optional link sharing (`shares/{shareId}`).
class ShareLinkBundle {
  final String shareId;
  final String ciphertextB64;
  final String nonceB64;
  final String shareUrl;

  const ShareLinkBundle({
    required this.shareId,
    required this.ciphertextB64,
    required this.nonceB64,
    required this.shareUrl,
  });
}

class ParsedShareLink {
  final String shareId;
  final Uint8List itemDek;

  const ParsedShareLink({
    required this.shareId,
    required this.itemDek,
  });

  void zeroizeKey() => zeroize(itemDek);
}

/// Internal deterministic Firebase Auth session handle & secret derived from a
/// 16-byte `authSeed` (which is itself derived from WebAuthn `prf` output via
/// HKDF-SHA256 and embedded inside the user's 256-bit portable Recovery Key).
/// Never exposed to the user as an email or password.
class DerivedVaultAuthCredentials {
  final String internalHandle;
  final String internalSecret;
  final String vaultFingerprint;

  const DerivedVaultAuthCredentials({
    required this.internalHandle,
    required this.internalSecret,
    required this.vaultFingerprint,
  });
}

class ParsedRecoveryKey {
  final String canonicalKey;
  final Uint8List authSeed16;
  final Uint8List recoveryEntropy16;
  final DerivedVaultAuthCredentials authCredentials;

  const ParsedRecoveryKey({
    required this.canonicalKey,
    required this.authSeed16,
    required this.recoveryEntropy16,
    required this.authCredentials,
  });

  void zeroizeSecrets() {
    zeroize(authSeed16);
    zeroize(recoveryEntropy16);
  }
}

/// Decoded direct cross-device X25519 Sync Key (`emx1-...`) containing the
/// 16-byte vault auth seed + 32-byte `User_Priv` (X25519 private scalar) +
/// 24-bit SHA-256 typo checksum for fast QR / copy-paste device linking.
class ParsedX25519SyncKey {
  final String canonicalKey;
  final Uint8List authSeed16;
  final Uint8List userPrivateKey;
  final Uint8List userPublicKey;
  final DerivedVaultAuthCredentials authCredentials;

  const ParsedX25519SyncKey({
    required this.canonicalKey,
    required this.authSeed16,
    required this.userPrivateKey,
    required this.userPublicKey,
    required this.authCredentials,
  });

  void zeroizeSecrets() {
    zeroize(authSeed16);
    zeroize(userPrivateKey);
  }
}

class E2eeEnvelopeCrypto {
  /// Deterministic app salt passed to WebAuthn `prf.eval.first` and HKDF.
  static const String prfAppSaltLabel = 'app-vault-root-v1';
  static const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  static final Map<String, int> _base32Lookup = {
    for (int i = 0; i < _base32Alphabet.length; i++) _base32Alphabet[i]: i,
  };

  /// Deterministic 32-byte input for WebAuthn `prf.eval.first`.
  static Uint8List get prfEvalSaltBytes =>
      Uint8List.fromList(sha256.convert(utf8.encode(prfAppSaltLabel)).bytes);

  static String formatItemAad(String documentPath, {int schemaVersion = 1}) =>
      '${documentPath.trim()}|v$schemaVersion';

  static String formatWrapAad(
    String documentPath,
    String recipientUid, {
    int schemaVersion = 1,
  }) =>
      'wrap|x25519-xchacha20poly1305|v$schemaVersion|${documentPath.trim()}|${recipientUid.trim()}';

  static String formatKeyringSlotAad(String uid, String slotName) =>
      'users/${uid.trim()}/security/keyring|$slotName|v1';

  static String formatShareAad(String shareId, {int schemaVersion = 1}) =>
      'shares/${shareId.trim()}|v$schemaVersion';

  /// Derives the 16-byte deterministic vault `authSeed` from a WebAuthn `prf`
  /// output via domain-separated HKDF-SHA256 (completely independent of
  /// `PRF_Root_Key`).
  static Uint8List deriveAuthSeedFromPrf(Uint8List prfOutput) {
    if (prfOutput.length < 16) {
      throw ArgumentError('WebAuthn PRF output must be at least 16 bytes.');
    }
    return HkdfSha256.deriveKey(
      ikm: prfOutput,
      salt: Uint8List.fromList(utf8.encode(prfAppSaltLabel)),
      info: Uint8List.fromList(utf8.encode('edge-mapper:vault-auth-seed:v2')),
      length: 16,
    );
  }

  /// Derives deterministic internal Firebase Auth credentials from a 16-byte
  /// `authSeed` so both Passkey (PRF) and Fallback Recovery Key authenticate
  /// to the exact same Firebase `uid` across devices with zero email/password.
  static DerivedVaultAuthCredentials deriveVaultAuthCredentials(
    Uint8List authSeed16,
  ) {
    if (authSeed16.length != 16) {
      throw ArgumentError.value(
        authSeed16.length,
        'authSeed16',
        'authSeed must be exactly 16 bytes.',
      );
    }
    final salt = Uint8List.fromList(utf8.encode(prfAppSaltLabel));
    final idBytes = HkdfSha256.deriveKey(
      ikm: authSeed16,
      salt: salt,
      info: Uint8List.fromList(utf8.encode('edge-mapper:vault-auth-handle:v2')),
      length: 16,
    );
    final secretBytes = HkdfSha256.deriveKey(
      ikm: authSeed16,
      salt: salt,
      info: Uint8List.fromList(utf8.encode('edge-mapper:vault-auth-secret:v2')),
      length: 32,
    );
    final fpBytes = sha256.convert([
      ...utf8.encode('edge-mapper:vault-fp:v2:'),
      ...authSeed16,
    ]).bytes;
    try {
      final idHex =
          idBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final fpHex = fpBytes
          .take(6)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();
      return DerivedVaultAuthCredentials(
        internalHandle: 'emv2-${idHex.substring(0, 24)}@vault.edgemapper.invalid',
        internalSecret: base64UrlEncode(secretBytes).replaceAll('=', ''),
        vaultFingerprint:
            '${fpHex.substring(0, 4)}-${fpHex.substring(4, 8)}-${fpHex.substring(8, 12)}',
      );
    } finally {
      zeroize(idBytes);
      zeroize(secretBytes);
    }
  }

  /// Generates a portable high-entropy 256-bit Recovery Key (`emr1-XXXX-...`):
  /// `[authSeed (16 bytes) || recoveryEntropy (16 bytes) || checksum (3 bytes)]`.
  /// When [authSeed16] is provided (e.g. derived from Passkey PRF), both the
  /// Passkey and the Recovery Key authenticate to the exact same Firebase `uid`!
  static String generateRecoveryKey({
    Uint8List? authSeed16,
    Random? random,
  }) {
    final seed = authSeed16 != null
        ? Uint8List.fromList(authSeed16)
        : secureRandomBytes(16, random: random);
    if (seed.length != 16) {
      zeroize(seed);
      throw ArgumentError('authSeed16 must be 16 bytes.');
    }
    final entropy = secureRandomBytes(16, random: random);
    final raw = Uint8List(32)
      ..setRange(0, 16, seed)
      ..setRange(16, 32, entropy);
    try {
      final check = sha256.convert([
        ...utf8.encode('edge-mapper:recovery-key:v1:'),
        ...raw,
      ]).bytes;
      final full = Uint8List(35)
        ..setRange(0, 32, raw)
        ..setRange(32, 35, check.sublist(0, 3));
      final sb = StringBuffer();
      int buf = 0;
      int bits = 0;
      for (final byte in full) {
        buf = (buf << 8) | (byte & 0xff);
        bits += 8;
        while (bits >= 5) {
          bits -= 5;
          sb.write(_base32Alphabet[(buf >> bits) & 0x1f]);
        }
      }
      if (bits > 0) {
        sb.write(_base32Alphabet[(buf << (5 - bits)) & 0x1f]);
      }
      final chars = sb.toString();
      final out = StringBuffer('emr1');
      for (int i = 0; i < chars.length; i += 8) {
        out.write('-');
        final end = (i + 8) > chars.length ? chars.length : i + 8;
        out.write(chars.substring(i, end));
      }
      zeroize(full);
      return out.toString();
    } finally {
      zeroize(seed);
      zeroize(entropy);
      zeroize(raw);
    }
  }

  /// Validates and parses an `emr1-...` Recovery Key (verifying its 24-bit
  /// SHA-256 typo checksum) and extracts its `authSeed16` + Firebase Auth creds.
  static ParsedRecoveryKey parseRecoveryKey(String rawKey) {
    final compact = rawKey
        .trim()
        .replaceAll(RegExp(r'[\s\-_]+'), '')
        .toUpperCase();
    if (!compact.startsWith('EMR1')) {
      throw const FormatException(
        'Invalid Recovery Key: must start with "emr1-".',
      );
    }
    final body = compact.substring(4);
    if (body.length != 56) {
      throw const FormatException(
        'Invalid Recovery Key length. Paste or autofill the full emr1-... key.',
      );
    }
    final out = <int>[];
    int buf = 0;
    int bits = 0;
    for (int i = 0; i < body.length; i++) {
      final val = _base32Lookup[body[i]];
      if (val == null) {
        throw FormatException('Invalid character "${body[i]}" in Recovery Key.');
      }
      buf = (buf << 5) | val;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buf >> bits) & 0xff);
      }
    }
    if (out.length != 35) {
      throw const FormatException('Invalid Recovery Key encoding.');
    }
    final bytes = Uint8List.fromList(out);
    final raw = Uint8List.sublistView(bytes, 0, 32);
    final providedCheck = Uint8List.sublistView(bytes, 32, 35);
    final expectedCheck = Uint8List.fromList(
      sha256.convert([
        ...utf8.encode('edge-mapper:recovery-key:v1:'),
        ...raw,
      ]).bytes.sublist(0, 3),
    );
    if (!constantTimeEquals(providedCheck, expectedCheck)) {
      zeroize(bytes);
      throw const FormatException(
        'Invalid Recovery Key checksum. Double-check for a typo or missing character.',
      );
    }
    final authSeed16 = Uint8List.fromList(raw.sublist(0, 16));
    final recoveryEntropy16 = Uint8List.fromList(raw.sublist(16, 32));
    zeroize(bytes);
    final canonical = normalizeRecoveryKey(rawKey);
    final authCreds = deriveVaultAuthCredentials(authSeed16);
    return ParsedRecoveryKey(
      canonicalKey: canonical,
      authSeed16: authSeed16,
      recoveryEntropy16: recoveryEntropy16,
      authCredentials: authCreds,
    );
  }

  static bool isValidRecoveryKey(String rawKey) {
    try {
      final parsed = parseRecoveryKey(rawKey);
      parsed.zeroizeSecrets();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Encodes `(authSeed16 || User_Priv)` + 24-bit SHA-256 checksum into a
  /// compact QR- and clipboard-friendly cross-device X25519 Sync Key (`emx1-...`).
  static String encodeX25519SyncKey({
    required Uint8List authSeed16,
    required Uint8List userPrivateKey,
  }) {
    if (authSeed16.length != 16) {
      throw ArgumentError.value(authSeed16.length, 'authSeed16', 'Must be 16 bytes.');
    }
    if (userPrivateKey.length != 32) {
      throw ArgumentError.value(
        userPrivateKey.length,
        'userPrivateKey',
        'Must be 32 bytes.',
      );
    }
    final payload = Uint8List(48)
      ..setRange(0, 16, authSeed16)
      ..setRange(16, 48, userPrivateKey);
    final check = sha256.convert([
      ...utf8.encode('edge-mapper:x25519-sync-key:v1:'),
      ...payload,
    ]).bytes;
    final full = Uint8List(51)
      ..setRange(0, 48, payload)
      ..setRange(48, 51, check.sublist(0, 3));
    try {
      final encoded = base64UrlEncode(full).replaceAll('=', '');
      return 'emx1-$encoded';
    } finally {
      zeroize(payload);
      zeroize(full);
    }
  }

  /// Validates and parses an `emx1-...` cross-device X25519 Sync Key.
  static ParsedX25519SyncKey parseX25519SyncKey(String rawKey) {
    final compact = rawKey.trim().replaceAll(RegExp(r'\s+'), '');
    if (!compact.toLowerCase().startsWith('emx1-')) {
      throw const FormatException(
        'Invalid X25519 Sync Key: must start with "emx1-".',
      );
    }
    final body = compact.substring(5);
    final Uint8List bytes;
    try {
      bytes = Uint8List.fromList(base64Url.decode(base64Url.normalize(body)));
    } catch (_) {
      throw const FormatException('Invalid X25519 Sync Key encoding.');
    }
    if (bytes.length != 51) {
      zeroize(bytes);
      throw const FormatException(
        'Invalid X25519 Sync Key length. Make sure the full emx1-... key was copied or scanned.',
      );
    }
    final payload = Uint8List.sublistView(bytes, 0, 48);
    final providedCheck = Uint8List.sublistView(bytes, 48, 51);
    final expectedCheck = Uint8List.fromList(
      sha256.convert([
        ...utf8.encode('edge-mapper:x25519-sync-key:v1:'),
        ...payload,
      ]).bytes.sublist(0, 3),
    );
    if (!constantTimeEquals(providedCheck, expectedCheck)) {
      zeroize(bytes);
      throw const FormatException(
        'Invalid X25519 Sync Key checksum. Double-check for a typo or missing character.',
      );
    }
    final authSeed16 = Uint8List.fromList(payload.sublist(0, 16));
    final userPriv = Uint8List.fromList(payload.sublist(16, 48));
    zeroize(bytes);
    final userPub = X25519.publicKeyFromPrivate(userPriv);
    final authCreds = deriveVaultAuthCredentials(authSeed16);
    return ParsedX25519SyncKey(
      canonicalKey: 'emx1-$body',
      authSeed16: authSeed16,
      userPrivateKey: userPriv,
      userPublicKey: userPub,
      authCredentials: authCreds,
    );
  }

  static bool isValidX25519SyncKey(String rawKey) {
    try {
      final parsed = parseX25519SyncKey(rawKey);
      parsed.zeroizeSecrets();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Normalizes a recovery key before Argon2id derivation (trims outer spaces;
  /// normalizes `emr1-...` keys case-insensitively while leaving custom
  /// passphrases exact).
  static String normalizeRecoveryKey(String raw) {
    final trimmed = raw.trim();
    if (trimmed.toLowerCase().startsWith('emr1')) {
      final compact = trimmed
          .replaceAll(RegExp(r'[\s\-_]+'), '')
          .toUpperCase();
      if (compact.length == 60 && compact.startsWith('EMR1')) {
        final body = compact.substring(4);
        final out = StringBuffer('emr1');
        for (int i = 0; i < body.length; i += 8) {
          out.write('-');
          final end = (i + 8) > body.length ? body.length : i + 8;
          out.write(body.substring(i, end));
        }
        return out.toString();
      }
    }
    return trimmed;
  }

  // --- Key Wrapping (Ephemeral X25519 Sealed-Box / HPKE-style) ---

  /// Wraps a 32-byte [itemDek] for [recipientPublicKey] using an ephemeral
  /// X25519 keypair + HKDF-SHA256 + XChaCha20-Poly1305 bound to [documentPath]
  /// and [recipientUid].
  static WrappedDekEnvelope wrapItemDek({
    required Uint8List itemDek,
    required Uint8List recipientPublicKey,
    required String documentPath,
    required String recipientUid,
    int schemaVersion = 1,
    Random? random,
  }) {
    if (itemDek.length != 32) {
      throw ArgumentError.value(itemDek.length, 'itemDek', 'Must be 32 bytes.');
    }
    final eph = X25519.generateKeyPair(random: random);
    Uint8List? sharedSecret;
    Uint8List? wrapKey;
    try {
      sharedSecret = X25519.scalarMult(eph.privateKey, recipientPublicKey);
      final hkdfSalt = Uint8List(64)
        ..setRange(0, 32, eph.publicKey)
        ..setRange(32, 64, recipientPublicKey);
      wrapKey = HkdfSha256.deriveKey(
        ikm: sharedSecret,
        salt: hkdfSalt,
        info: Uint8List.fromList(
          utf8.encode('edge-mapper:hpke-x25519-xchacha20poly1305:v1'),
        ),
        length: 32,
      );
      final nonce = secureRandomBytes(
        XChaCha20Poly1305.nonceLength,
        random: random,
      );
      final aad = Uint8List.fromList(
        utf8.encode(
          formatWrapAad(
            documentPath,
            recipientUid,
            schemaVersion: schemaVersion,
          ),
        ),
      );
      final wrapped = XChaCha20Poly1305.encrypt(
        key: wrapKey,
        nonce: nonce,
        plaintext: itemDek,
        aad: aad,
      );
      return WrappedDekEnvelope(
        epkB64: base64Encode(eph.publicKey),
        nonceB64: base64Encode(nonce),
        ciphertextB64: base64Encode(wrapped),
      );
    } finally {
      eph.zeroizePrivate();
      zeroize(sharedSecret);
      zeroize(wrapKey);
    }
  }

  /// Unwraps a 32-byte `Item_DEK` using the recipient's `User_Priv`.
  static Uint8List unwrapItemDek({
    required WrappedDekEnvelope envelope,
    required Uint8List recipientPrivateKey,
    Uint8List? recipientPublicKey,
    required String documentPath,
    required String recipientUid,
    int schemaVersion = 1,
  }) {
    final Uint8List ephPub;
    final Uint8List nonce;
    final Uint8List ciphertextWithTag;
    try {
      ephPub = Uint8List.fromList(base64Decode(envelope.epkB64.trim()));
      nonce = Uint8List.fromList(base64Decode(envelope.nonceB64.trim()));
      ciphertextWithTag =
          Uint8List.fromList(base64Decode(envelope.ciphertextB64.trim()));
    } catch (_) {
      throw const E2eeAuthTagException('Malformed wrapped Item_DEK envelope.');
    }
    if (ephPub.length != 32 ||
        nonce.length != XChaCha20Poly1305.nonceLength ||
        ciphertextWithTag.length != 32 + XChaCha20Poly1305.tagLength) {
      throw const E2eeAuthTagException('Invalid wrapped Item_DEK field lengths.');
    }

    final pubBytes =
        recipientPublicKey ?? X25519.publicKeyFromPrivate(recipientPrivateKey);
    Uint8List? sharedSecret;
    Uint8List? wrapKey;
    try {
      sharedSecret = X25519.scalarMult(recipientPrivateKey, ephPub);
      final hkdfSalt = Uint8List(64)
        ..setRange(0, 32, ephPub)
        ..setRange(32, 64, pubBytes);
      wrapKey = HkdfSha256.deriveKey(
        ikm: sharedSecret,
        salt: hkdfSalt,
        info: Uint8List.fromList(
          utf8.encode('edge-mapper:hpke-x25519-xchacha20poly1305:v1'),
        ),
        length: 32,
      );
      final aad = Uint8List.fromList(
        utf8.encode(
          formatWrapAad(
            documentPath,
            recipientUid,
            schemaVersion: schemaVersion,
          ),
        ),
      );
      return XChaCha20Poly1305.decrypt(
        key: wrapKey,
        nonce: nonce,
        ciphertextWithTag: ciphertextWithTag,
        aad: aad,
      );
    } finally {
      zeroize(sharedSecret);
      zeroize(wrapKey);
    }
  }

  // --- Item Payload Envelope Encryption ---

  /// Encrypts [plaintext] using a random 256-bit `Item_DEK` (or [existingDek]),
  /// 192-bit random nonce, and AAD `{documentPath}|v{schemaVersion}`, wrapping
  /// `Item_DEK` for every recipient in [recipientPublicKeys].
  ///
  /// Personal items are simply a 1-recipient map `{ ownerUid: ownerPublicKey }`.
  static EncryptedItemEnvelope encryptItem({
    required Uint8List plaintext,
    required String documentPath,
    required Map<String, Uint8List> recipientPublicKeys,
    Uint8List? existingDek,
    int schemaVersion = 1,
    Random? random,
  }) {
    if (recipientPublicKeys.isEmpty) {
      throw ArgumentError('At least one recipient public key is required.');
    }
    final ownsDek = existingDek == null;
    final itemDek = existingDek ?? secureRandomBytes(32, random: random);
    try {
      final nonce =
          secureRandomBytes(XChaCha20Poly1305.nonceLength, random: random);
      final aad = Uint8List.fromList(
        utf8.encode(formatItemAad(documentPath, schemaVersion: schemaVersion)),
      );
      final ct = XChaCha20Poly1305.encrypt(
        key: itemDek,
        nonce: nonce,
        plaintext: plaintext,
        aad: aad,
      );
      final wrappedMap = <String, WrappedDekEnvelope>{};
      for (final entry in recipientPublicKeys.entries) {
        wrappedMap[entry.key] = wrapItemDek(
          itemDek: itemDek,
          recipientPublicKey: entry.value,
          documentPath: documentPath,
          recipientUid: entry.key,
          schemaVersion: schemaVersion,
          random: random,
        );
      }
      return EncryptedItemEnvelope(
        documentPath: documentPath,
        schemaVersion: schemaVersion,
        ciphertextB64: base64Encode(ct),
        nonceB64: base64Encode(nonce),
        recipients: wrappedMap,
      );
    } finally {
      if (ownsDek) {
        zeroize(itemDek);
      }
    }
  }

  /// Decrypts an [EncryptedItemEnvelope] for [recipientUid] using their
  /// `User_Priv`, verifying the AAD against [expectedDocumentPath].
  static Uint8List decryptItem({
    required EncryptedItemEnvelope envelope,
    required String recipientUid,
    required Uint8List recipientPrivateKey,
    Uint8List? recipientPublicKey,
    String? expectedDocumentPath,
  }) {
    final docPath = expectedDocumentPath ?? envelope.documentPath;
    final wrappedDek = envelope.recipients[recipientUid];
    if (wrappedDek == null) {
      throw E2eeAuthTagException(
        'No wrapped Item_DEK found for recipient "$recipientUid".',
      );
    }
    final Uint8List nonce;
    final Uint8List ctWithTag;
    try {
      nonce = Uint8List.fromList(base64Decode(envelope.nonceB64.trim()));
      ctWithTag =
          Uint8List.fromList(base64Decode(envelope.ciphertextB64.trim()));
    } catch (_) {
      throw const E2eeAuthTagException('Malformed item ciphertext or nonce.');
    }

    final itemDek = unwrapItemDek(
      envelope: wrappedDek,
      recipientPrivateKey: recipientPrivateKey,
      recipientPublicKey: recipientPublicKey,
      documentPath: docPath,
      recipientUid: recipientUid,
      schemaVersion: envelope.schemaVersion,
    );
    try {
      final aad = Uint8List.fromList(
        utf8.encode(
          formatItemAad(docPath, schemaVersion: envelope.schemaVersion),
        ),
      );
      return XChaCha20Poly1305.decrypt(
        key: itemDek,
        nonce: nonce,
        ciphertextWithTag: ctWithTag,
        aad: aad,
      );
    } finally {
      zeroize(itemDek);
    }
  }

  /// Grants access to a new collaborator by unwrapping `Item_DEK` with the
  /// owner's `User_Priv` and adding a freshly wrapped envelope for
  /// [newRecipientUid].
  static EncryptedItemEnvelope addRecipientToEnvelope({
    required EncryptedItemEnvelope envelope,
    required String ownerUid,
    required Uint8List ownerPrivateKey,
    Uint8List? ownerPublicKey,
    required String newRecipientUid,
    required Uint8List newRecipientPublicKey,
    Random? random,
  }) {
    final ownerWrapped = envelope.recipients[ownerUid];
    if (ownerWrapped == null) {
      throw const E2eeAuthTagException(
        'Owner does not have a wrapped Item_DEK on this item.',
      );
    }
    final itemDek = unwrapItemDek(
      envelope: ownerWrapped,
      recipientPrivateKey: ownerPrivateKey,
      recipientPublicKey: ownerPublicKey,
      documentPath: envelope.documentPath,
      recipientUid: ownerUid,
      schemaVersion: envelope.schemaVersion,
    );
    try {
      final newWrapped = wrapItemDek(
        itemDek: itemDek,
        recipientPublicKey: newRecipientPublicKey,
        documentPath: envelope.documentPath,
        recipientUid: newRecipientUid,
        schemaVersion: envelope.schemaVersion,
        random: random,
      );
      return envelope.copyWith(
        recipients: {
          ...envelope.recipients,
          newRecipientUid: newWrapped,
        },
      );
    } finally {
      zeroize(itemDek);
    }
  }

  /// Key rotation on revocation: generates a brand-new 256-bit `Item_DEK` and
  /// 192-bit nonce, re-encrypts [newPlaintext] under the new key with AAD
  /// `{documentPath}|v{schemaVersion}`, and wraps ONLY for
  /// [remainingRecipientPublicKeys] — cryptographically excluding all revoked
  /// recipients from decrypting future writes.
  static EncryptedItemEnvelope rotateItemKeyForRevocation({
    required Uint8List newPlaintext,
    required String documentPath,
    required Map<String, Uint8List> remainingRecipientPublicKeys,
    int schemaVersion = 1,
    Random? random,
  }) {
    return encryptItem(
      plaintext: newPlaintext,
      documentPath: documentPath,
      recipientPublicKeys: remainingRecipientPublicKeys,
      schemaVersion: schemaVersion,
      random: random,
    );
  }

  // --- Keyring Root Unlock Slots (WebAuthn PRF & Argon2id Recovery Key) ---

  /// Derives `PRF_Root_Key` (32 bytes) from a 32-byte deterministic WebAuthn
  /// PRF output via `HKDF-SHA256`.
  static Uint8List derivePrfRootKey({
    required Uint8List prfOutput,
    Uint8List? salt,
  }) {
    if (prfOutput.length < 16) {
      throw ArgumentError('WebAuthn PRF output must be at least 16 bytes.');
    }
    final effectiveSalt =
        salt ?? Uint8List.fromList(utf8.encode(prfAppSaltLabel));
    return HkdfSha256.deriveKey(
      ikm: prfOutput,
      salt: effectiveSalt,
      info: Uint8List.fromList(utf8.encode('edge-mapper:prf-root-key:v1')),
      length: 32,
    );
  }

  /// Wraps `User_Priv` into `wrapped_priv_prf` using `PRF_Root_Key`.
  static WrappedPrfKeySlot wrapUserPrivWithPrf({
    required String uid,
    required Uint8List userPrivateKey,
    required Uint8List prfOutput,
    Uint8List? salt,
    Random? random,
  }) {
    if (userPrivateKey.length != 32) {
      throw ArgumentError('User_Priv must be 32 bytes.');
    }
    final slotSalt = salt ?? Uint8List.fromList(utf8.encode(prfAppSaltLabel));
    final prfRootKey = derivePrfRootKey(prfOutput: prfOutput, salt: slotSalt);
    try {
      final nonce =
          secureRandomBytes(XChaCha20Poly1305.nonceLength, random: random);
      final aad =
          Uint8List.fromList(utf8.encode(formatKeyringSlotAad(uid, 'prf')));
      final ct = XChaCha20Poly1305.encrypt(
        key: prfRootKey,
        nonce: nonce,
        plaintext: userPrivateKey,
        aad: aad,
      );
      return WrappedPrfKeySlot(
        ciphertextB64: base64Encode(ct),
        nonceB64: base64Encode(nonce),
        saltB64: base64Encode(slotSalt),
      );
    } finally {
      zeroize(prfRootKey);
    }
  }

  /// Unwraps `User_Priv` from `wrapped_priv_prf` using the deterministic
  /// WebAuthn PRF output.
  static Uint8List unwrapUserPrivWithPrf({
    required String uid,
    required WrappedPrfKeySlot slot,
    required Uint8List prfOutput,
  }) {
    final slotSalt = Uint8List.fromList(base64Decode(slot.saltB64.trim()));
    final nonce = Uint8List.fromList(base64Decode(slot.nonceB64.trim()));
    final ct = Uint8List.fromList(base64Decode(slot.ciphertextB64.trim()));
    final prfRootKey = derivePrfRootKey(prfOutput: prfOutput, salt: slotSalt);
    try {
      final aad =
          Uint8List.fromList(utf8.encode(formatKeyringSlotAad(uid, 'prf')));
      return XChaCha20Poly1305.decrypt(
        key: prfRootKey,
        nonce: nonce,
        ciphertextWithTag: ct,
        aad: aad,
      );
    } finally {
      zeroize(prfRootKey);
    }
  }

  /// Wraps `User_Priv` into `wrapped_priv_recovery` using Argon2id (default
  /// 64 MiB memory, 3 iterations) from a portable high-entropy Recovery Key.
  static Future<WrappedRecoveryKeySlot> wrapUserPrivWithRecoveryKey({
    required String uid,
    required Uint8List userPrivateKey,
    required String recoveryKey,
    Argon2Params params = Argon2Params.defaultProduction,
    Random? random,
  }) async {
    if (userPrivateKey.length != 32) {
      throw ArgumentError('User_Priv must be 32 bytes.');
    }
    final normalized = normalizeRecoveryKey(recoveryKey);
    if (normalized.isEmpty) {
      throw ArgumentError('Recovery key cannot be empty.');
    }
    final pwdBytes = Uint8List.fromList(utf8.encode(normalized));
    final kdfSalt = secureRandomBytes(16, random: random);
    Uint8List? recoveryKek;
    try {
      recoveryKek = await Argon2id.deriveKey(
        password: pwdBytes,
        salt: kdfSalt,
        params: params,
      );
      final nonce =
          secureRandomBytes(XChaCha20Poly1305.nonceLength, random: random);
      final aad = Uint8List.fromList(
        utf8.encode(formatKeyringSlotAad(uid, 'recovery')),
      );
      final ct = XChaCha20Poly1305.encrypt(
        key: recoveryKek,
        nonce: nonce,
        plaintext: userPrivateKey,
        aad: aad,
      );
      return WrappedRecoveryKeySlot(
        ciphertextB64: base64Encode(ct),
        nonceB64: base64Encode(nonce),
        kdfSaltB64: base64Encode(kdfSalt),
        kdfParams: params,
      );
    } finally {
      zeroize(pwdBytes);
      zeroize(recoveryKek);
    }
  }

  static final RegExp _safeShareIdPattern = RegExp(r'^[A-Za-z0-9_-]{8,128}$');

  /// Unwraps `User_Priv` from `wrapped_priv_recovery` using Argon2id.
  static Future<Uint8List> unwrapUserPrivWithRecoveryKey({
    required String uid,
    required WrappedRecoveryKeySlot slot,
    required String recoveryKey,
  }) async {
    // Bound untrusted Firestore KDF parameters before allocating Argon2id memory.
    slot.kdfParams.validateBounds(requiredKeyLength: 32);
    final normalized = normalizeRecoveryKey(recoveryKey);
    final pwdBytes = Uint8List.fromList(utf8.encode(normalized));
    final kdfSalt = Uint8List.fromList(base64Decode(slot.kdfSaltB64.trim()));
    final nonce = Uint8List.fromList(base64Decode(slot.nonceB64.trim()));
    final ct = Uint8List.fromList(base64Decode(slot.ciphertextB64.trim()));
    Uint8List? recoveryKek;
    try {
      recoveryKek = await Argon2id.deriveKey(
        password: pwdBytes,
        salt: kdfSalt,
        params: slot.kdfParams,
      );
      final aad = Uint8List.fromList(
        utf8.encode(formatKeyringSlotAad(uid, 'recovery')),
      );
      return XChaCha20Poly1305.decrypt(
        key: recoveryKek,
        nonce: nonce,
        ciphertextWithTag: ct,
        aad: aad,
      );
    } finally {
      zeroize(pwdBytes);
      zeroize(recoveryKek);
    }
  }

  // --- Optional Link Sharing (`shares/{shareId}#k={base64url_item_dek}`) ---

  /// Encrypts [plaintext] with a random 256-bit `Item_DEK` and places the key
  /// strictly in the URL fragment (`#k=...`) so it is never transmitted to the
  /// server in HTTP requests.
  static ShareLinkBundle createShareLinkBundle({
    required Uint8List plaintext,
    required String shareId,
    String domain = 'edgemapper.app',
    int schemaVersion = 1,
    Random? random,
  }) {
    final cleanShareId = shareId.trim();
    if (!_safeShareIdPattern.hasMatch(cleanShareId)) {
      throw ArgumentError('Invalid shareId format.');
    }
    final itemDek = secureRandomBytes(32, random: random);
    try {
      final nonce =
          secureRandomBytes(XChaCha20Poly1305.nonceLength, random: random);
      final aad = Uint8List.fromList(
        utf8.encode(formatShareAad(cleanShareId, schemaVersion: schemaVersion)),
      );
      final ct = XChaCha20Poly1305.encrypt(
        key: itemDek,
        nonce: nonce,
        plaintext: plaintext,
        aad: aad,
      );
      final keyB64Url = base64UrlEncode(itemDek).replaceAll('=', '');
      final cleanDomain = domain
          .trim()
          .replaceFirst(RegExp(r'^https?://'), '')
          .replaceAll(RegExp(r'/+$'), '');
      final url = 'https://$cleanDomain/s/$cleanShareId#k=$keyB64Url';
      return ShareLinkBundle(
        shareId: cleanShareId,
        ciphertextB64: base64Encode(ct),
        nonceB64: base64Encode(nonce),
        shareUrl: url,
      );
    } finally {
      zeroize(itemDek);
    }
  }

  /// Parses `https://<domain>/s/{shareId}#k={base64url_item_dek}`, enforcing
  /// HTTPS scheme, safe `shareId`, and that the key is strictly in the URL
  /// fragment (never in query parameters).
  static ParsedShareLink parseShareUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('Share URL must be a valid https:// URL.');
    }
    if (uri.queryParameters.containsKey('k')) {
      throw const FormatException(
        'Unsafe share link: encryption key must only appear in the URL #fragment, never in query parameters.',
      );
    }
    final segs = uri.pathSegments;
    final sIdx = segs.indexOf('s');
    if (sIdx < 0 || sIdx + 1 >= segs.length || segs[sIdx + 1].trim().isEmpty) {
      throw const FormatException('Share URL missing /s/{shareId} path.');
    }
    final shareId = segs[sIdx + 1].trim();
    if (!_safeShareIdPattern.hasMatch(shareId)) {
      throw const FormatException(
        'Share URL contains an invalid shareId (possible path traversal).',
      );
    }
    final frag = uri.fragment.trim();
    String? keyPart;
    for (final part in frag.split('&')) {
      if (part.startsWith('k=')) {
        keyPart = part.substring(2).trim();
        break;
      }
    }
    if (keyPart == null || keyPart.isEmpty) {
      throw const FormatException('Share URL missing #k= encryption key fragment.');
    }
    final padded = base64Url.normalize(keyPart);
    final dek = Uint8List.fromList(base64Url.decode(padded));
    if (dek.length != 32) {
      zeroize(dek);
      throw const FormatException('Share URL #k= key must decode to 32 bytes.');
    }
    return ParsedShareLink(shareId: shareId, itemDek: dek);
  }

  /// Decrypts a `shares/{shareId}` payload using the fragment `Item_DEK`.
  static Uint8List decryptSharePayload({
    required String shareId,
    required String ciphertextB64,
    required String nonceB64,
    required Uint8List itemDek,
    int schemaVersion = 1,
  }) {
    final nonce = Uint8List.fromList(base64Decode(nonceB64.trim()));
    final ct = Uint8List.fromList(base64Decode(ciphertextB64.trim()));
    final aad = Uint8List.fromList(
      utf8.encode(formatShareAad(shareId, schemaVersion: schemaVersion)),
    );
    return XChaCha20Poly1305.decrypt(
      key: itemDek,
      nonce: nonce,
      ciphertextWithTag: ct,
      aad: aad,
    );
  }
}

int _loadLe32(Uint8List src, int offset) =>
    (src[offset] & 0xff) |
    ((src[offset + 1] & 0xff) << 8) |
    ((src[offset + 2] & 0xff) << 16) |
    ((src[offset + 3] & 0xff) << 24);

void _storeLe32(Uint8List dst, int offset, int v) {
  dst[offset] = v & 0xff;
  dst[offset + 1] = (v >>> 8) & 0xff;
  dst[offset + 2] = (v >>> 16) & 0xff;
  dst[offset + 3] = (v >>> 24) & 0xff;
}

void _storeLe64(Uint8List dst, int offset, int value) {
  final lo = value & 0xffffffff;
  final hi = (value ~/ 4294967296) & 0xffffffff;
  _storeLe32(dst, offset, lo);
  _storeLe32(dst, offset + 4, hi);
}
