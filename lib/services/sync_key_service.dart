import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Parsed & validated private Sync Key (`emk1-...`) along with deterministic
/// domain-separated credentials derived via HMAC-SHA256.
class DerivedSyncKeyCredentials {
  /// Canonical formatted private key (`emk1-XXXXXXXX-...`), kept secret by the user.
  final String canonicalKey;

  /// Safe public key identifier (`XXXX-XXXX-XXXX`) derived via SHA-256 for UI display.
  final String fingerprint;

  /// Deterministic internal Firebase Auth handle (RFC 2606 `.invalid` domain,
  /// never exposed to the user as an email).
  final String internalIdentity;

  /// 256-bit HMAC-SHA256 derived secret for Firebase Auth verification.
  final String derivedSecret;

  /// 256-bit domain-separated AES-256-GCM key used strictly for client-side
  /// End-to-End Encryption (E2EE) of all Firestore records, photos, and routes.
  final Uint8List dataEncryptionKey;

  const DerivedSyncKeyCredentials({
    required this.canonicalKey,
    required this.fingerprint,
    required this.internalIdentity,
    required this.derivedSecret,
    required this.dataEncryptionKey,
  });
}

/// Cryptographic private-token identity engine for Edge Mapper Cloud Sync.
///
/// Generates a single 256-bit CSPRNG private token (`emk1-...`) with a 24-bit
/// SHA-256 typo-detection checksum:
/// - **32 bytes** (256-bit) cryptographically random secret
/// - **3 bytes** (24-bit) SHA-256 checksum
/// - Encoded as **56** RFC 4648 Base32 characters (`A-Z`, `2-7`), grouped as
///   `emk1-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX`.
///
/// From that single token, deterministic HMAC-SHA256 domain-separated
/// credentials authenticate directly against Firebase Auth so the same token
/// maps to the exact same Firebase `uid` across Android, GrapheneOS, and Web
/// while Firestore rules strictly isolate `/users/{uid}/...` per owner.
class SyncKeyService {
  static const String keyPrefix = 'emk1';
  static const int _secretByteLength = 32;
  static const int _checksumByteLength = 3;
  static const int _totalByteLength = _secretByteLength + _checksumByteLength;
  static const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  static final Map<String, int> _base32Lookup = {
    for (int i = 0; i < _base32Alphabet.length; i++) _base32Alphabet[i]: i,
  };

  /// Generates a brand-new 256-bit cryptographically random private Sync Key.
  static String generateKey({Random? random}) {
    final rng = random ?? Random.secure();
    final secret = Uint8List(_secretByteLength);
    for (int i = 0; i < _secretByteLength; i++) {
      secret[i] = rng.nextInt(256);
    }
    return encodeKeyFromSecretBytes(secret);
  }

  /// Encodes a 32-byte raw secret into canonical `emk1-...` format with checksum.
  static String encodeKeyFromSecretBytes(Uint8List secretBytes) {
    if (secretBytes.length != _secretByteLength) {
      throw ArgumentError.value(
        secretBytes.length,
        'secretBytes',
        'Must be exactly $_secretByteLength bytes (256 bits).',
      );
    }
    final checksum = _computeChecksum(secretBytes);
    final payload = Uint8List(_totalByteLength)
      ..setRange(0, _secretByteLength, secretBytes)
      ..setRange(_secretByteLength, _totalByteLength, checksum);
    final encoded = _base32Encode(payload);
    return _formatCanonical(encoded);
  }

  /// Returns `true` if [rawKey] is a syntactically valid `emk1-...` key with a
  /// matching 24-bit checksum.
  static bool isValidKey(String rawKey) {
    try {
      deriveCredentials(rawKey);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Validates [rawKey] (case-insensitive, ignoring whitespace/hyphens) and
  /// derives deterministic Firebase Auth credentials + public fingerprint.
  static DerivedSyncKeyCredentials deriveCredentials(String rawKey) {
    final secretBytes = _decodeAndVerifySecretBytes(rawKey);
    try {
      final canonicalKey = encodeKeyFromSecretBytes(secretBytes);

      final identityMac = Hmac(sha256, secretBytes)
          .convert(utf8.encode('edge-mapper:sync-identity:v1'))
          .bytes;
      final accountTag = _toHex(identityMac).substring(0, 24);
      final internalIdentity = 'em-$accountTag@key.edgemapper.invalid';

      final secretMac = Hmac(sha256, secretBytes)
          .convert(utf8.encode('edge-mapper:sync-secret:v1'))
          .bytes;
      final derivedSecret = base64UrlEncode(secretMac).replaceAll('=', '');

      final dataKeyMac = Hmac(sha256, secretBytes)
          .convert(utf8.encode('edge-mapper:firestore-e2ee-key:v1'))
          .bytes;
      final dataEncryptionKey = Uint8List.fromList(dataKeyMac);

      final fpDigest = sha256.convert([
        ...utf8.encode('edge-mapper:key-fingerprint:v1:'),
        ...secretBytes,
      ]).bytes;
      final fpHex = _toHex(fpDigest).substring(0, 12).toUpperCase();
      final fingerprint =
          '${fpHex.substring(0, 4)}-${fpHex.substring(4, 8)}-${fpHex.substring(8, 12)}';

      return DerivedSyncKeyCredentials(
        canonicalKey: canonicalKey,
        fingerprint: fingerprint,
        internalIdentity: internalIdentity,
        derivedSecret: derivedSecret,
        dataEncryptionKey: dataEncryptionKey,
      );
    } finally {
      for (var i = 0; i < secretBytes.length; i++) {
        secretBytes[i] = 0;
      }
    }
  }

  /// Derives the 256-bit AES-256-GCM Firestore E2EE key directly from [rawKey].
  static Uint8List deriveDataEncryptionKey(String rawKey) =>
      deriveCredentials(rawKey).dataEncryptionKey;

  /// Masks a Sync Key for safe preview (shows prefix & last 4 chars only).
  static String maskKey(String rawKey) {
    final trimmed = rawKey.trim();
    if (trimmed.length <= 12) return '••••';
    return '${trimmed.substring(0, 9)}…${trimmed.substring(trimmed.length - 4)}';
  }

  static Uint8List _decodeAndVerifySecretBytes(String rawKey) {
    final compact = rawKey
        .trim()
        .replaceAll(RegExp(r'[\s\-_]+'), '')
        .toUpperCase();
    final prefixUpper = keyPrefix.toUpperCase();
    if (!compact.startsWith(prefixUpper)) {
      throw const FormatException(
        'Invalid Sync Key: must start with "$keyPrefix-".',
      );
    }
    final body = compact.substring(prefixUpper.length);
    if (body.length != 56) {
      throw const FormatException(
        'Invalid Sync Key length. Check that the entire token was pasted.',
      );
    }
    final bytes = _base32Decode(body);
    if (bytes.length != _totalByteLength) {
      throw const FormatException('Invalid Sync Key encoding.');
    }
    final secret = Uint8List.sublistView(bytes, 0, _secretByteLength);
    final providedChecksum =
        Uint8List.sublistView(bytes, _secretByteLength, _totalByteLength);
    final expectedChecksum = _computeChecksum(secret);
    int diff = 0;
    for (int i = 0; i < _checksumByteLength; i++) {
      diff |= providedChecksum[i] ^ expectedChecksum[i];
    }
    if (diff != 0) {
      throw const FormatException(
        'Invalid Sync Key checksum. Double-check for a typo or missing character.',
      );
    }
    return secret;
  }

  static Uint8List _computeChecksum(Uint8List secretBytes) {
    final digest = sha256.convert([
      ...utf8.encode('edge-mapper:key-checksum:v1:'),
      ...secretBytes,
    ]).bytes;
    return Uint8List.fromList(digest.sublist(0, _checksumByteLength));
  }

  static String _formatCanonical(String base32Chars) {
    final buf = StringBuffer(keyPrefix);
    for (int i = 0; i < base32Chars.length; i += 8) {
      buf.write('-');
      final end = (i + 8) > base32Chars.length ? base32Chars.length : i + 8;
      buf.write(base32Chars.substring(i, end));
    }
    return buf.toString();
  }

  static String _base32Encode(Uint8List bytes) {
    final out = StringBuffer();
    int buffer = 0;
    int bitsLeft = 0;
    for (final byte in bytes) {
      buffer = (buffer << 8) | (byte & 0xff);
      bitsLeft += 8;
      while (bitsLeft >= 5) {
        bitsLeft -= 5;
        out.write(_base32Alphabet[(buffer >> bitsLeft) & 0x1f]);
      }
    }
    if (bitsLeft > 0) {
      out.write(_base32Alphabet[(buffer << (5 - bitsLeft)) & 0x1f]);
    }
    return out.toString();
  }

  static Uint8List _base32Decode(String input) {
    final out = <int>[];
    int buffer = 0;
    int bitsLeft = 0;
    for (int i = 0; i < input.length; i++) {
      final ch = input[i];
      final val = _base32Lookup[ch];
      if (val == null) {
        throw FormatException('Invalid character "$ch" in Sync Key.');
      }
      buffer = (buffer << 5) | val;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        out.add((buffer >> bitsLeft) & 0xff);
      }
    }
    return Uint8List.fromList(out);
  }

  static String _toHex(List<int> bytes) {
    final buf = StringBuffer();
    for (final b in bytes) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }
}
