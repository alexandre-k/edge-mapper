import 'dart:convert';
import 'dart:typed_data';

import 'package:edge_mapper/models/hike_trail.dart';
import 'package:edge_mapper/models/osm_record.dart';
import 'package:edge_mapper/services/connectivity_service.dart';
import 'package:edge_mapper/services/e2ee_envelope_crypto.dart';
import 'package:edge_mapper/services/e2ee_platform_bridge.dart';
import 'package:edge_mapper/services/firebase_sync_service.dart';
import 'package:edge_mapper/services/hybrid_ai_service.dart';
import 'package:edge_mapper/services/local_db_service.dart';
import 'package:edge_mapper/services/mapper_store.dart';
import 'package:edge_mapper/services/offline_tile_service.dart';
import 'package:edge_mapper/services/sensor_service.dart';
import 'package:edge_mapper/services/user_preferences_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Uint8List _hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s+'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class _FakeE2eePlatformBridge implements E2eePlatformBridge {
  bool prfSupported;
  bool androidCacheSupported;
  Uint8List? prfSecretToReturn;
  final Map<String, CachedHardwareVault> _androidKeystoreCache = {};

  _FakeE2eePlatformBridge({
    this.prfSupported = true,
    this.androidCacheSupported = false,
    this.prfSecretToReturn,
  });

  @override
  Future<E2eePlatformCapabilities> getCapabilities() async =>
      E2eePlatformCapabilities(
        supportsWebAuthnPrf: prfSupported,
        supportsAndroidHardwareCache: androidCacheSupported,
        hardwareCacheDetail: androidCacheSupported
            ? 'Fake Android Keystore AES-256-GCM'
            : 'Web volatile RAM',
      );

  @override
  Future<PasskeyPrfResult> enrollPasskeyPrf({
    required String accountName,
    required String displayName,
    required Uint8List deterministicSalt,
  }) async {
    if (!prfSupported || prfSecretToReturn == null) {
      return const PasskeyPrfResult(
        webAuthnSupported: true,
        prfSupported: false,
        errorMessage: 'Authenticator lacks WebAuthn PRF support.',
      );
    }
    return PasskeyPrfResult(
      webAuthnSupported: true,
      prfSupported: true,
      credentialIdB64: base64Encode(utf8.encode('fake-cred-id')),
      prfOutput: Uint8List.fromList(prfSecretToReturn!),
    );
  }

  @override
  Future<PasskeyPrfResult> evaluatePasskeyPrf({
    required Uint8List deterministicSalt,
    String? credentialIdB64,
  }) async {
    if (!prfSupported || prfSecretToReturn == null) {
      return const PasskeyPrfResult(
        webAuthnSupported: true,
        prfSupported: false,
        errorMessage: 'Authenticator lacks WebAuthn PRF support.',
      );
    }
    return PasskeyPrfResult(
      webAuthnSupported: true,
      prfSupported: true,
      credentialIdB64: base64Encode(utf8.encode('fake-cred-id')),
      prfOutput: Uint8List.fromList(prfSecretToReturn!),
    );
  }

  @override
  Future<bool> cacheUserPrivLocally({
    required String uid,
    required Uint8List userPrivateKey,
    Uint8List? authSeed16,
  }) async {
    if (!androidCacheSupported) return false;
    _androidKeystoreCache[uid] = CachedHardwareVault(
      uid: uid,
      userPrivateKey: Uint8List.fromList(userPrivateKey),
      authSeed16: authSeed16 != null ? Uint8List.fromList(authSeed16) : null,
    );
    return true;
  }

  CachedHardwareVault? _cloneCached(String? uid) {
    if (!androidCacheSupported || _androidKeystoreCache.isEmpty) return null;
    final found = (uid != null && uid.isNotEmpty)
        ? _androidKeystoreCache[uid]
        : _androidKeystoreCache.values.first;
    if (found == null) return null;
    return CachedHardwareVault(
      uid: found.uid,
      userPrivateKey: Uint8List.fromList(found.userPrivateKey),
      authSeed16:
          found.authSeed16 != null ? Uint8List.fromList(found.authSeed16!) : null,
    );
  }

  @override
  Future<CachedHardwareVault?> loadCachedVault({String? uid}) async =>
      _cloneCached(uid);

  @override
  Future<CachedHardwareVault?> unlockCachedVaultWithBiometric({
    String? uid,
  }) async =>
      _cloneCached(uid);

  @override
  Future<bool> hasCachedUserPriv({String? uid}) async {
    if (!androidCacheSupported) return false;
    if (uid == null || uid.isEmpty) return _androidKeystoreCache.isNotEmpty;
    return _androidKeystoreCache.containsKey(uid);
  }

  @override
  Future<void> clearCachedUserPriv({String? uid}) async {
    if (uid != null) {
      _androidKeystoreCache.remove(uid);
    } else {
      _androidKeystoreCache.clear();
    }
  }
}

/// In-memory Firestore REST simulator supporting `users/{uid}/security/keyring`,
/// `items/{itemId}`, `:runQuery` (ARRAY_CONTAINS on `recipient_uids`), and
/// `shares/{shareId}`.
class _FakeFirestoreRest {
  final Map<String, Map<String, dynamic>> docs = {};
  final List<http.Request> requests = [];

  MockClient createClient() {
    return MockClient((req) async {
      requests.add(req);
      final path = req.url.path;

      // Structured query (`:runQuery`)
      if (req.method == 'POST' && path.endsWith(':runQuery')) {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final sq = body['structuredQuery'] as Map<String, dynamic>;
        final collectionId =
            (sq['from'] as List).first['collectionId'].toString();
        final filter = sq['where']['fieldFilter'] as Map<String, dynamic>;
        final fieldPath = filter['field']['fieldPath'].toString();
        final targetUid = filter['value']['stringValue'].toString();

        final rows = <Map<String, dynamic>>[];
        docs.forEach((docPath, doc) {
          if (!docPath.contains('/documents/$collectionId/')) return;
          final fields = doc['fields'] as Map<String, dynamic>;
          final values =
              (fields[fieldPath]?['arrayValue']?['values'] as List?) ??
                  const [];
          final contains = values.any((v) => v['stringValue'] == targetUid);
          if (contains) {
            rows.add({'document': doc});
          }
        });
        return http.Response(jsonEncode(rows), 200);
      }

      if (req.method == 'PATCH') {
        final parsed = jsonDecode(req.body) as Map<String, dynamic>;
        final newFields =
            Map<String, dynamic>.from(parsed['fields'] as Map<String, dynamic>);
        final mask = req.url.queryParametersAll['updateMask.fieldPaths'];
        final existing = docs[path];
        if (existing != null && mask != null && mask.isNotEmpty) {
          final merged = Map<String, dynamic>.from(
            existing['fields'] as Map<String, dynamic>,
          );
          for (final field in mask) {
            if (newFields.containsKey(field)) {
              merged[field] = newFields[field];
            }
          }
          docs[path] = {'name': path, 'fields': merged};
        } else {
          docs[path] = {'name': path, 'fields': newFields};
        }
        return http.Response(jsonEncode(docs[path]), 200);
      }

      if (req.method == 'GET') {
        final doc = docs[path];
        if (doc != null) {
          return http.Response(jsonEncode(doc), 200);
        }
        // Collection listing support (e.g. legacy users/{uid}/osm_records & trails)
        final prefix = '$path/';
        final matched = docs.entries
            .where((e) => e.key.startsWith(prefix))
            .map((e) => e.value)
            .toList();
        if (matched.isNotEmpty) {
          return http.Response(jsonEncode({'documents': matched}), 200);
        }
        return http.Response('{"error":{"message":"Not found"}}', 404);
      }

      if (req.method == 'DELETE') {
        docs.remove(path);
        return http.Response('{}', 200);
      }

      return http.Response('{}', 200);
    });
  }
}

void main() {
  group('RFC Standards Test Vectors (HKDF, XChaCha20-Poly1305, X25519, Blake2b, Argon2id)', () {
    test('HKDF-SHA256 matches RFC 5869 Test Case 1', () {
      final ikm = _hexToBytes('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b');
      final salt = _hexToBytes('000102030405060708090a0b0c');
      final info = _hexToBytes('f0f1f2f3f4f5f6f7f8f9');
      final okm = HkdfSha256.deriveKey(
        ikm: ikm,
        salt: salt,
        info: info,
        length: 42,
      );
      expect(
        _bytesToHex(okm),
        equals(
          '3cb25f25faacd57a90434f64d0362f2a'
          '2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
          '34007208d5b887185865',
        ),
      );
    });

    test('Poly1305 matches RFC 8439 §2.5.2 & XChaCha20-Poly1305 matches draft-irtf-cfrg-xchacha §A.3.1', () {
      // RFC 8439 §2.5.2 Poly1305 vector
      final pKey = _hexToBytes(
        '85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b',
      );
      final pMsg = Uint8List.fromList(
        utf8.encode('Cryptographic Forum Research Group'),
      );
      expect(
        _bytesToHex(XChaCha20Poly1305.poly1305Mac(pKey, pMsg)),
        equals('a8061dc1305136c6c22b8baf0c0127a9'),
      );

      // draft-irtf-cfrg-xchacha §2.2.1 HChaCha20 test vector
      final hKey = _hexToBytes(
        '000102030405060708090a0b0c0d0e0f'
        '101112131415161718191a1b1c1d1e1f',
      );
      final hNonce = _hexToBytes('000000090000004a0000000031415927');
      expect(
        _bytesToHex(XChaCha20Poly1305.hChaCha20(hKey, hNonce)),
        equals(
          '82413b4227b27bfed30e42508a877d73'
          'a0f9e4d58a74a853c12ec41326d3ecdc',
        ),
      );

      // draft-irtf-cfrg-xchacha §A.3.1 AEAD_XChaCha20_Poly1305 test vector
      final key = _hexToBytes(
        '808182838485868788898a8b8c8d8e8f'
        '909192939495969798999a9b9c9d9e9f',
      );
      final nonce = _hexToBytes(
        '404142434445464748494a4b4c4d4e4f'
        '5051525354555657',
      );
      final aad = _hexToBytes('50515253c0c1c2c3c4c5c6c7');
      final plaintext = Uint8List.fromList(
        utf8.encode(
          "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.",
        ),
      );

      final ctAndTag = XChaCha20Poly1305.encrypt(
        key: key,
        nonce: nonce,
        plaintext: plaintext,
        aad: aad,
      );
      final ctHex =
          _bytesToHex(Uint8List.sublistView(ctAndTag, 0, plaintext.length));
      final tagHex =
          _bytesToHex(Uint8List.sublistView(ctAndTag, plaintext.length));

      expect(
        ctHex,
        equals(
          'bd6d179d3e83d43b9576579493c0e939'
          '572a1700252bfaccbed2902c21396cbb'
          '731c7f1b0b4aa6440bf3a82f4eda7e39'
          'ae64c6708c54c216cb96b72e1213b452'
          '2f8c9ba40db5d945b11b69b982c1bb9e'
          '3f3fac2bc369488f76b2383565d3fff9'
          '21f9664c97637da9768812f615c68b13'
          'b52e',
        ),
      );
      expect(tagHex, equals('c0875924c1c7987947deafd8780acf49'));

      final decrypted = XChaCha20Poly1305.decrypt(
        key: key,
        nonce: nonce,
        ciphertextWithTag: ctAndTag,
        aad: aad,
      );
      expect(decrypted, equals(plaintext));
    });

    test('X25519 matches RFC 7748 §6.1 Diffie-Hellman vector and rejects low-order points', () {
      final alicePriv = _hexToBytes(
        '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a',
      );
      final expectedAlicePub =
          '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a';
      final bobPriv = _hexToBytes(
        '5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb',
      );
      final expectedBobPub =
          'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f';
      final expectedShared =
          '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742';

      final alicePub = X25519.publicKeyFromPrivate(alicePriv);
      final bobPub = X25519.publicKeyFromPrivate(bobPriv);
      expect(_bytesToHex(alicePub), equals(expectedAlicePub));
      expect(_bytesToHex(bobPub), equals(expectedBobPub));

      final sharedA = X25519.scalarMult(alicePriv, bobPub);
      final sharedB = X25519.scalarMult(bobPriv, alicePub);
      expect(_bytesToHex(sharedA), equals(expectedShared));
      expect(_bytesToHex(sharedB), equals(expectedShared));

      // All-zero low-order public key MUST be rejected
      expect(
        () => X25519.scalarMult(alicePriv, Uint8List(32)),
        throwsA(isA<E2eeAuthTagException>()),
      );
    });

    test('Blake2b-512 matches RFC 7693 and Argon2id matches RFC 9106 §5.3 on BOTH 64-bit native & 32-bit Web engines', () async {
      // RFC 7693 Appendix A: Blake2b-512("abc")
      final b2 = Blake2b.hash(Uint8List.fromList(utf8.encode('abc')), outLen: 64);
      expect(
        _bytesToHex(b2),
        equals(
          'ba80a53f981c4d0d6a2797b69f12f6e9'
          '4c212f14685ac4b74b12bb6fdbffa2d1'
          '7d87c5392aab792dc252d5de4533cc95'
          '18d38aa8dbf1925ab92386edd4009923',
        ),
      );

      // RFC 9106 §5.3 Argon2id Official Test Vector:
      // t=3, p=4, m=32 KiB, dkLen=32, pwd=0x01*32, salt=0x02*16, secret=0x03*8, ad=0x04*12
      final pwd = Uint8List.fromList(List.filled(32, 0x01));
      final salt = Uint8List.fromList(List.filled(16, 0x02));
      final secret = Uint8List.fromList(List.filled(8, 0x03));
      final ad = Uint8List.fromList(List.filled(12, 0x04));
      const rfcParams = Argon2Params(
        memoryKiB: 32,
        iterations: 3,
        parallelism: 4,
        keyLength: 32,
      );
      const expectedTagHex =
          '0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659';

      // Verify 64-bit Isolate native engine
      final nativeTag = await Argon2id.deriveKey(
        password: pwd,
        salt: salt,
        params: rfcParams,
        secret: secret,
        associatedData: ad,
      );
      expect(_bytesToHex(nativeTag), equals(expectedTagHex));

      // Verify 32-bit Web-safe engine produces bit-for-bit identical output
      final webSafeTag = Argon2id.deriveKeyPure32(
        password: pwd,
        salt: salt,
        params: rfcParams,
        secret: secret,
        associatedData: ad,
      );
      expect(_bytesToHex(webSafeTag), equals(expectedTagHex));
    });
  });

  group('Envelope Encryption, Tamper Detection, Multi-Recipient Sharing & Revocation', () {
    test('1. Round-trip encryption/decryption of payloads, Item_DEK envelopes, PRF & Argon2id slots, and #k= share links', () async {
      final alice = X25519.generateKeyPair();
      const docPath = 'users/alice/items/item-001';
      final plaintext = Uint8List.fromList(
        utf8.encode('{"title":"Hidden Waterfall","lat":35.6251,"lon":139.2435}'),
      );

      // Personal 1-recipient item envelope
      final envelope = E2eeEnvelopeCrypto.encryptItem(
        plaintext: plaintext,
        documentPath: docPath,
        recipientPublicKeys: {'alice': alice.publicKey},
      );
      expect(envelope.recipients.keys, equals(['alice']));
      expect(base64Decode(envelope.nonceB64).length, equals(24)); // 192-bit nonce
      expect(
        envelope.ciphertextB64,
        isNot(contains('Hidden Waterfall')),
      );

      final decrypted = E2eeEnvelopeCrypto.decryptItem(
        envelope: envelope,
        recipientUid: 'alice',
        recipientPrivateKey: alice.privateKey,
        recipientPublicKey: alice.publicKey,
        expectedDocumentPath: docPath,
      );
      expect(decrypted, equals(plaintext));

      // WebAuthn PRF slot round-trip
      final prfOutput = secureRandomBytes(32);
      final prfSlot = E2eeEnvelopeCrypto.wrapUserPrivWithPrf(
        uid: 'alice',
        userPrivateKey: alice.privateKey,
        prfOutput: prfOutput,
      );
      final unwrappedFromPrf = E2eeEnvelopeCrypto.unwrapUserPrivWithPrf(
        uid: 'alice',
        slot: prfSlot,
        prfOutput: prfOutput,
      );
      expect(unwrappedFromPrf, equals(alice.privateKey));

      // Production Argon2id (64 MB memory, 3 iterations) Recovery Key slot round-trip!
      final recoveryKey = E2eeEnvelopeCrypto.generateRecoveryKey();
      expect(recoveryKey, startsWith('emr1-'));
      final recoverySlot =
          await E2eeEnvelopeCrypto.wrapUserPrivWithRecoveryKey(
        uid: 'alice',
        userPrivateKey: alice.privateKey,
        recoveryKey: recoveryKey,
        params: Argon2Params.defaultProduction, // 64 MiB, 3 iterations
      );
      expect(recoverySlot.kdfParams.memoryKiB, equals(65536));
      expect(recoverySlot.kdfParams.iterations, equals(3));

      final unwrappedFromRecovery =
          await E2eeEnvelopeCrypto.unwrapUserPrivWithRecoveryKey(
        uid: 'alice',
        slot: recoverySlot,
        recoveryKey: recoveryKey.toLowerCase().replaceAll('-', ' '),
      );
      expect(unwrappedFromRecovery, equals(alice.privateKey));

      // Wrong recovery key MUST fail tag authentication
      await expectLater(
        () => E2eeEnvelopeCrypto.unwrapUserPrivWithRecoveryKey(
          uid: 'alice',
          slot: recoverySlot,
          recoveryKey: E2eeEnvelopeCrypto.generateRecoveryKey(),
        ),
        throwsA(isA<E2eeAuthTagException>()),
      );

      // Optional link sharing: key strictly in URL #k= fragment
      final shareBundle = E2eeEnvelopeCrypto.createShareLinkBundle(
        plaintext: plaintext,
        shareId: 'share-xyz-123',
        domain: 'edgemapper.app',
      );
      expect(
        shareBundle.shareUrl,
        startsWith('https://edgemapper.app/s/share-xyz-123#k='),
      );
      final parsedUri = Uri.parse(shareBundle.shareUrl);
      expect(parsedUri.queryParameters.containsKey('k'), isFalse);
      expect(parsedUri.fragment, startsWith('k='));

      final parsedShare = E2eeEnvelopeCrypto.parseShareUrl(shareBundle.shareUrl);
      final decShare = E2eeEnvelopeCrypto.decryptSharePayload(
        shareId: parsedShare.shareId,
        ciphertextB64: shareBundle.ciphertextB64,
        nonceB64: shareBundle.nonceB64,
        itemDek: parsedShare.itemDek,
      );
      expect(decShare, equals(plaintext));
      parsedShare.zeroizeKey();

      // Reject unsafe query-string ?k= links
      expect(
        () => E2eeEnvelopeCrypto.parseShareUrl(
          'https://edgemapper.app/s/share-xyz-123?k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        ),
        throwsA(isA<FormatException>()),
      );

      // Zeroization wipes private key bytes in volatile memory
      alice.zeroizePrivate();
      expect(alice.privateKey.every((b) => b == 0), isTrue);
    });

    test('2. Tamper detection: 1-byte ciphertext flip, 1-byte nonce flip, or document path (AAD) swap MUST fail with authentication tag error', () {
      final alice = X25519.generateKeyPair();
      const docPathA = 'items/item-alpha';
      const docPathB = 'items/item-beta';
      final plaintext = Uint8List.fromList(utf8.encode('Top-secret trail note'));

      final envelope = E2eeEnvelopeCrypto.encryptItem(
        plaintext: plaintext,
        documentPath: docPathA,
        recipientPublicKeys: {'alice': alice.publicKey},
      );

      // (a) Modify 1 byte of ciphertext -> E2eeAuthTagException
      final tamperedCt = Uint8List.fromList(base64Decode(envelope.ciphertextB64));
      tamperedCt[0] ^= 0x01;
      expect(
        () => E2eeEnvelopeCrypto.decryptItem(
          envelope: envelope.copyWith(ciphertextB64: base64Encode(tamperedCt)),
          recipientUid: 'alice',
          recipientPrivateKey: alice.privateKey,
          expectedDocumentPath: docPathA,
        ),
        throwsA(isA<E2eeAuthTagException>()),
      );

      // (b) Modify 1 byte of 24-byte nonce -> E2eeAuthTagException
      final tamperedNonce = Uint8List.fromList(base64Decode(envelope.nonceB64));
      tamperedNonce[12] ^= 0x80;
      expect(
        () => E2eeEnvelopeCrypto.decryptItem(
          envelope: envelope.copyWith(nonceB64: base64Encode(tamperedNonce)),
          recipientUid: 'alice',
          recipientPrivateKey: alice.privateKey,
          expectedDocumentPath: docPathA,
        ),
        throwsA(isA<E2eeAuthTagException>()),
      );

      // (c) Change Firestore document path (AAD mismatch / ciphertext replay swap) -> E2eeAuthTagException
      expect(
        () => E2eeEnvelopeCrypto.decryptItem(
          envelope: envelope,
          recipientUid: 'alice',
          recipientPrivateKey: alice.privateKey,
          expectedDocumentPath: docPathB,
        ),
        throwsA(isA<E2eeAuthTagException>()),
      );

      // (d) Even if attacker directly unwraps valid Item_DEK and replays raw payload to docPathB -> AAD fails
      final dek = E2eeEnvelopeCrypto.unwrapItemDek(
        envelope: envelope.recipients['alice']!,
        recipientPrivateKey: alice.privateKey,
        documentPath: docPathA,
        recipientUid: 'alice',
      );
      expect(
        () => XChaCha20Poly1305.decrypt(
          key: dek,
          nonce: Uint8List.fromList(base64Decode(envelope.nonceB64)),
          ciphertextWithTag:
              Uint8List.fromList(base64Decode(envelope.ciphertextB64)),
          aad: Uint8List.fromList(
            utf8.encode(E2eeEnvelopeCrypto.formatItemAad(docPathB)),
          ),
        ),
        throwsA(isA<E2eeAuthTagException>()),
      );
      zeroize(dek);
      alice.zeroizePrivate();
    });

    test('3. Multi-recipient sharing: Alice encrypts an item, wraps Item_DEK for Bob X25519 pubkey, and Bob decrypts using his unwrapped User_Priv', () {
      final alice = X25519.generateKeyPair();
      final bob = X25519.generateKeyPair();
      final mallory = X25519.generateKeyPair();
      const docPath = 'items/shared-ridge-trail';
      final secretPayload = Uint8List.fromList(
        utf8.encode('{"name":"Secret Alpine Hut","elevation":2480}'),
      );

      // Alice encrypts personal item first (1-recipient list [Alice_Pub])
      final personalEnvelope = E2eeEnvelopeCrypto.encryptItem(
        plaintext: secretPayload,
        documentPath: docPath,
        recipientPublicKeys: {'alice': alice.publicKey},
      );

      // Alice shares the item with Bob by wrapping Item_DEK to Bob_Pub
      final sharedEnvelope = E2eeEnvelopeCrypto.addRecipientToEnvelope(
        envelope: personalEnvelope,
        ownerUid: 'alice',
        ownerPrivateKey: alice.privateKey,
        ownerPublicKey: alice.publicKey,
        newRecipientUid: 'bob',
        newRecipientPublicKey: bob.publicKey,
      );

      // Wrap Bob's User_Priv in a PRF slot and unwrap it (simulating Bob's login)
      final bobPrf = secureRandomBytes(32);
      final bobPrfSlot = E2eeEnvelopeCrypto.wrapUserPrivWithPrf(
        uid: 'bob',
        userPrivateKey: bob.privateKey,
        prfOutput: bobPrf,
      );
      final bobUnwrappedPriv = E2eeEnvelopeCrypto.unwrapUserPrivWithPrf(
        uid: 'bob',
        slot: bobPrfSlot,
        prfOutput: bobPrf,
      );

      // Bob decrypts Alice's shared item with his unwrapped User_Priv!
      final bobDecrypted = E2eeEnvelopeCrypto.decryptItem(
        envelope: sharedEnvelope,
        recipientUid: 'bob',
        recipientPrivateKey: bobUnwrappedPriv,
        expectedDocumentPath: docPath,
      );
      expect(bobDecrypted, equals(secretPayload));

      // Mallory cannot decrypt Bob's wrapped envelope with Mallory's private key
      expect(
        () => E2eeEnvelopeCrypto.decryptItem(
          envelope: sharedEnvelope,
          recipientUid: 'bob',
          recipientPrivateKey: mallory.privateKey,
          expectedDocumentPath: docPath,
        ),
        throwsA(isA<E2eeAuthTagException>()),
      );

      zeroize(bobUnwrappedPriv);
      alice.zeroizePrivate();
      bob.zeroizePrivate();
      mallory.zeroizePrivate();
    });

    test('4. Key rotation on revocation: rotating Item_DEK excludes removed recipient (Bob) from all future writes while remaining recipients (Alice & Carol) keep access', () {
      final alice = X25519.generateKeyPair();
      final bob = X25519.generateKeyPair();
      final carol = X25519.generateKeyPair();
      const docPath = 'items/team-expedition-log';

      final v1Plaintext = Uint8List.fromList(utf8.encode('Version 1: Shared with Bob & Carol'));
      final v2Plaintext = Uint8List.fromList(utf8.encode('Version 2: Bob has been revoked'));

      // Initial write shared with Alice, Bob, and Carol
      final v1Env = E2eeEnvelopeCrypto.encryptItem(
        plaintext: v1Plaintext,
        documentPath: docPath,
        recipientPublicKeys: {
          'alice': alice.publicKey,
          'bob': bob.publicKey,
          'carol': carol.publicKey,
        },
      );

      // Bob caches the old v1 Item_DEK before revocation
      final bobOldDek = E2eeEnvelopeCrypto.unwrapItemDek(
        envelope: v1Env.recipients['bob']!,
        recipientPrivateKey: bob.privateKey,
        documentPath: docPath,
        recipientUid: 'bob',
      );
      expect(
        E2eeEnvelopeCrypto.decryptItem(
          envelope: v1Env,
          recipientUid: 'bob',
          recipientPrivateKey: bob.privateKey,
        ),
        equals(v1Plaintext),
      );

      // Alice revokes Bob -> rotates Item_DEK and re-encrypts v2 ONLY for Alice & Carol
      final v2Env = E2eeEnvelopeCrypto.rotateItemKeyForRevocation(
        newPlaintext: v2Plaintext,
        documentPath: docPath,
        remainingRecipientPublicKeys: {
          'alice': alice.publicKey,
          'carol': carol.publicKey,
        },
      );

      // Bob is removed from recipients map
      expect(v2Env.recipients.containsKey('bob'), isFalse);
      expect(v2Env.recipients.keys.toSet(), equals({'alice', 'carol'}));

      // Alice and Carol both decrypt v2 cleanly
      expect(
        E2eeEnvelopeCrypto.decryptItem(
          envelope: v2Env,
          recipientUid: 'alice',
          recipientPrivateKey: alice.privateKey,
        ),
        equals(v2Plaintext),
      );
      expect(
        E2eeEnvelopeCrypto.decryptItem(
          envelope: v2Env,
          recipientUid: 'carol',
          recipientPrivateKey: carol.privateKey,
        ),
        equals(v2Plaintext),
      );

      // Bob CANNOT decrypt v2 via recipients map
      expect(
        () => E2eeEnvelopeCrypto.decryptItem(
          envelope: v2Env,
          recipientUid: 'bob',
          recipientPrivateKey: bob.privateKey,
        ),
        throwsA(isA<E2eeAuthTagException>()),
      );

      // Bob CANNOT decrypt v2 ciphertext even using his previously captured v1 Item_DEK!
      expect(
        () => XChaCha20Poly1305.decrypt(
          key: bobOldDek,
          nonce: Uint8List.fromList(base64Decode(v2Env.nonceB64)),
          ciphertextWithTag: Uint8List.fromList(base64Decode(v2Env.ciphertextB64)),
          aad: Uint8List.fromList(
            utf8.encode(E2eeEnvelopeCrypto.formatItemAad(docPath)),
          ),
        ),
        throwsA(isA<E2eeAuthTagException>()),
      );

      zeroize(bobOldDek);
      alice.zeroizePrivate();
      bob.zeroizePrivate();
      carol.zeroizePrivate();
    });
  });

  group('End-to-End FirebaseSyncService Cross-Device Sync, Keyring, Android Cache & Selective Sharing', () {
    const fastArgon2ForTest = Argon2Params(
      memoryKiB: 64,
      iterations: 1,
      parallelism: 1,
      keyLength: 32,
    );

    test('Full passwordless flow: Device A 1-tap Passkey PRF setup -> Device B zero-config 1-tap Passkey PRF login (no email/password) -> Android fallback Recovery Key login (same UID) -> Android hardware auto-unlock -> Share with Bob -> Revoke Bob -> Share Link', () async {
      final fakeFs = _FakeFirestoreRest();
      final client = fakeFs.createClient();
      final alicePrfSecret = secureRandomBytes(32);

      // Deterministic UID map simulating Firebase Auth internal handle -> UID
      final handleToUid = <String, String>{};
      String uidForHandle(String handle) =>
          handleToUid.putIfAbsent(handle, () => 'uid-${handleToUid.length + 1}');

      // --- Alice on Computer A (Web with WebAuthn PRF — ZERO email/password!) ---
      String? aliceUidA;
      final bridgeA = _FakeE2eePlatformBridge(
        prfSupported: true,
        androidCacheSupported: false,
        prfSecretToReturn: alicePrfSecret,
      );
      final aliceDeviceA = FirebaseSyncService(
        prefs: UserPreferencesService(),
        client: client,
        platformBridge: bridgeA,
        uidOverride: () => aliceUidA,
        projectIdOverride: () => 'test-e2ee-proj',
        idTokenOverride: ({bool forceRefresh = false}) async => 'jwt-alice',
        vaultAuthOverride: (creds, {required bool createNew}) async {
          aliceUidA = uidForHandle(creds.internalHandle);
        },
        authSignOutOverride: () async => aliceUidA = null,
      );

      final setupRes = await aliceDeviceA.createVaultWithPasskeyPrf(
        argon2Params: fastArgon2ForTest,
      );
      expect(setupRes.prfEnrolled, isTrue);
      expect(setupRes.recoveryKey, startsWith('emr1-'));
      expect(aliceDeviceA.isSignedIn, isTrue);
      expect(aliceDeviceA.isVaultUnlocked, isTrue);
      final aliceUid = aliceDeviceA.currentUid!;
      expect(
        fakeFs.docs.containsKey(
          '/v1/projects/test-e2ee-proj/databases/(default)/documents/users/$aliceUid/security/keyring',
        ),
        isTrue,
      );

      // Alice syncs a record (with photo) + a trail
      final record = OsmRecord(
        id: 'rec-takao-1',
        createdAt: DateTime.utc(2026, 11, 25, 10, 0),
        latitude: 35.6251,
        longitude: 139.2435,
        summary: 'Mt. Takao Trailhead',
        tags: const {'tourism': 'information', 'name:ja': '高尾山登山口'},
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.aiEnriched,
      );
      final trail = HikeTrail(
        id: 'trail-yoyogi-1',
        name: 'Yoyogi Park Walk',
        startedAt: DateTime.utc(2026, 11, 25, 8, 0),
        isActive: false,
        tags: const {'highway': 'footway'},
        points: [
          TrailPoint(
            trailId: 'trail-yoyogi-1',
            latitude: 35.6717,
            longitude: 139.6949,
            recordedAt: DateTime.utc(2026, 11, 25, 8, 5),
          ),
        ],
      );

      await aliceDeviceA.syncRecord(
        record,
        photoDataUriOverride: 'data:image/jpeg;base64,SECRETPHOTO',
      );
      await aliceDeviceA.syncTrail(trail);

      // Verify ZERO plaintext leaked to Firestore items/
      final rawRecDoc = jsonEncode(
        fakeFs.docs[
            '/v1/projects/test-e2ee-proj/databases/(default)/documents/items/rec_rec-takao-1'],
      );
      expect(rawRecDoc, isNot(contains('高尾山登山口')));
      expect(rawRecDoc, isNot(contains('SECRETPHOTO')));

      // --- Alice on Computer B (Starts SIGNED OUT, ZERO email/password — 1-Tap Passkey PRF Login!) ---
      String? aliceUidB;
      final bridgeB = _FakeE2eePlatformBridge(
        prfSupported: true,
        prfSecretToReturn: alicePrfSecret,
      );
      final aliceDeviceB = FirebaseSyncService(
        prefs: UserPreferencesService(),
        client: client,
        platformBridge: bridgeB,
        uidOverride: () => aliceUidB,
        projectIdOverride: () => 'test-e2ee-proj',
        idTokenOverride: ({bool forceRefresh = false}) async => 'jwt-alice',
        vaultAuthOverride: (creds, {required bool createNew}) async {
          aliceUidB = uidForHandle(creds.internalHandle);
        },
      );
      expect(aliceDeviceB.isSignedIn, isFalse);
      expect(aliceDeviceB.isVaultUnlocked, isFalse);

      await aliceDeviceB.signInAndUnlockWithPasskeyPrf();
      expect(aliceDeviceB.isSignedIn, isTrue);
      expect(aliceDeviceB.currentUid, equals(aliceUid));
      expect(aliceDeviceB.isVaultUnlocked, isTrue);

      final pulledRecsB = await aliceDeviceB.fetchAllRecords();
      final pulledTrailsB = await aliceDeviceB.fetchAllTrails();
      expect(pulledRecsB.length, equals(1));
      expect(pulledRecsB.first.record.tags['name:ja'], equals('高尾山登山口'));
      expect(
        pulledRecsB.first.photoDataUri,
        equals('data:image/jpeg;base64,SECRETPHOTO'),
      );
      expect(pulledTrailsB.length, equals(1));
      expect(pulledTrailsB.first.name, equals('Yoyogi Park Walk'));

      // --- Alice on Android Phone (Starts SIGNED OUT, no PRF -> Fallback Recovery Key signs into EXACT same UID + caches in Android Keystore!) ---
      String? aliceUidAndroid;
      final bridgeAndroid = _FakeE2eePlatformBridge(
        prfSupported: false,
        androidCacheSupported: true,
      );
      final aliceAndroid = FirebaseSyncService(
        prefs: UserPreferencesService(),
        client: client,
        platformBridge: bridgeAndroid,
        uidOverride: () => aliceUidAndroid,
        projectIdOverride: () => 'test-e2ee-proj',
        idTokenOverride: ({bool forceRefresh = false}) async => 'jwt-alice',
        vaultAuthOverride: (creds, {required bool createNew}) async {
          aliceUidAndroid = uidForHandle(creds.internalHandle);
        },
      );
      // PRF fails gracefully with PrfUnsupportedException
      await expectLater(
        () => aliceAndroid.signInAndUnlockWithPasskeyPrf(),
        throwsA(isA<PrfUnsupportedException>()),
      );
      // Fallback Recovery Key signs into the EXACT SAME UID and unwraps User_Priv via Argon2id!
      await aliceAndroid.signInAndUnlockWithRecoveryKey(setupRes.recoveryKey);
      expect(aliceAndroid.currentUid, equals(aliceUid));
      expect(aliceAndroid.isVaultUnlocked, isTrue);
      expect(aliceAndroid.hasAndroidHardwareCache, isTrue);

      // Simulate daily app restart on Android -> unlocks silently via Android Keystore with ZERO Passkey prompt!
      final aliceAndroidRestart = FirebaseSyncService(
        prefs: UserPreferencesService(),
        client: client,
        platformBridge: bridgeAndroid,
        uidOverride: () => aliceUid,
        projectIdOverride: () => 'test-e2ee-proj',
        idTokenOverride: ({bool forceRefresh = false}) async => 'jwt-alice',
      );
      await aliceAndroidRestart.refreshSessionAndTryAutoUnlock();
      expect(aliceAndroidRestart.isVaultUnlocked, isTrue);
      expect(aliceAndroidRestart.unlockedViaHardwareCache, isTrue);

      // Lock on Android -> unlock directly with Android Keystore / Fingerprint ONLY (no recovery key!)
      aliceAndroidRestart.lockVault();
      expect(aliceAndroidRestart.isVaultUnlocked, isFalse);
      await aliceAndroidRestart.unlockWithAndroidKeystore();
      expect(aliceAndroidRestart.isVaultUnlocked, isTrue);

      // Export compact X25519 Sync Key (QR / Copy) from Android -> link a second desktop device instantaneously!
      final x25519TransferKey = aliceAndroidRestart.exportX25519SyncKey();
      expect(x25519TransferKey, isNotNull);
      expect(x25519TransferKey, startsWith('emx1-'));
      expect(E2eeEnvelopeCrypto.isValidX25519SyncKey(x25519TransferKey!), isTrue);

      String? aliceUidDeviceC;
      final aliceDeviceC = FirebaseSyncService(
        prefs: UserPreferencesService(),
        client: client,
        platformBridge: _FakeE2eePlatformBridge(prfSupported: false),
        uidOverride: () => aliceUidDeviceC,
        projectIdOverride: () => 'test-e2ee-proj',
        idTokenOverride: ({bool forceRefresh = false}) async => 'jwt-alice',
        vaultAuthOverride: (creds, {required bool createNew}) async {
          aliceUidDeviceC = uidForHandle(creds.internalHandle);
        },
      );
      await aliceDeviceC.signInAndUnlockWithAnyKey(x25519TransferKey);
      expect(aliceDeviceC.currentUid, equals(aliceUid));
      expect(aliceDeviceC.isVaultUnlocked, isTrue);
      final pulledOnDeviceC = await aliceDeviceC.fetchAllRecords();
      expect(pulledOnDeviceC.length, equals(1));
      expect(pulledOnDeviceC.first.record.tags['name:ja'], equals('高尾山登山口'));
      expect(
        pulledOnDeviceC.first.photoDataUri,
        equals('data:image/jpeg;base64,SECRETPHOTO'),
      );

      // --- Multi-Recipient Sharing with Bob & Revocation with Key Rotation ---
      String? bobUid;
      final bobService = FirebaseSyncService(
        prefs: UserPreferencesService(),
        client: client,
        platformBridge: _FakeE2eePlatformBridge(prfSupported: false),
        uidOverride: () => bobUid,
        projectIdOverride: () => 'test-e2ee-proj',
        idTokenOverride: ({bool forceRefresh = false}) async => 'jwt-bob',
        vaultAuthOverride: (creds, {required bool createNew}) async {
          bobUid = uidForHandle(creds.internalHandle);
        },
      );
      await bobService.createVaultWithRecoveryKey(
        argon2Params: fastArgon2ForTest,
      );
      expect(bobUid, isNotNull);
      expect(bobUid, isNot(equals(aliceUid)));

      // Initially Bob sees 0 records
      expect(await bobService.fetchAllRecords(), isEmpty);

      // Alice shares `rec_rec-takao-1` with Bob (fetches Bob's X25519 pubkey from users/{bobUid}/security/keyring!)
      await aliceDeviceA.shareItemWithRecipient(
        itemId: FirebaseSyncService.recordItemId(record.id),
        recipientUid: bobUid!,
      );

      // Bob now pulls and decrypts Alice's record & photo!
      final bobPulled = await bobService.fetchAllRecords();
      expect(bobPulled.length, equals(1));
      expect(bobPulled.first.record.tags['name:ja'], equals('高尾山登山口'));
      expect(
        bobPulled.first.photoDataUri,
        equals('data:image/jpeg;base64,SECRETPHOTO'),
      );

      // Alice revokes Bob -> rotates Item_DEK & excludes Bob!
      await aliceDeviceA.revokeRecipientAndRotateKey(
        itemId: FirebaseSyncService.recordItemId(record.id),
        revokedRecipientUid: bobUid!,
      );
      expect(await bobService.fetchAllRecords(), isEmpty);
      // Alice can still decrypt her own record + photo after rotation!
      final aliceAfterRevoke = await aliceDeviceA.fetchAllRecords();
      expect(aliceAfterRevoke.length, equals(1));
      expect(
        aliceAfterRevoke.first.photoDataUri,
        equals('data:image/jpeg;base64,SECRETPHOTO'),
      );

      // --- Optional Link Sharing (`shares/{shareId}#k={base64url_item_dek}`) ---
      final linkBundle = await aliceDeviceA.createShareLinkForRecord(
        record,
        photoDataUriOverride: 'data:image/jpeg;base64,LINKPHOTO',
      );
      expect(linkBundle.shareUrl, contains('#k='));
      final opened = await bobService.openShareLink(linkBundle.shareUrl);
      expect(opened.record?.record.tags['name:ja'], equals('高尾山登山口'));
      expect(
        opened.record?.photoDataUri,
        equals('data:image/jpeg;base64,LINKPHOTO'),
      );

      // Locking wipes volatile keypair from RAM
      aliceDeviceA.lockVault();
      expect(aliceDeviceA.isVaultUnlocked, isFalse);
      expect(
        () => aliceDeviceA.fetchAllRecords(),
        throwsA(isA<FirebaseAuthRequiredException>()),
      );
    });

    test('Migrates & purges legacy plaintext users/{uid}/osm_records and users/{uid}/trails into E2EE items/{itemId}', () async {
      final fakeFs = _FakeFirestoreRest();
      final client = fakeFs.createClient();
      const uid = 'uid-legacy-user';

      final legacyRec = OsmRecord(
        id: 'legacy-rec-1',
        createdAt: DateTime.utc(2026, 11, 20, 9, 0),
        latitude: 35.6812,
        longitude: 139.7671,
        summary: 'Legacy Plaintext Cafe',
        tags: const {'amenity': 'cafe', 'name': 'Unencrypted Cafe'},
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.aiEnriched,
      );
      final legacyTrail = HikeTrail(
        id: 'legacy-trail-1',
        name: 'Legacy Unencrypted Walk',
        startedAt: DateTime.utc(2026, 11, 20, 8, 0),
        isActive: false,
        tags: const {'highway': 'footway'},
        points: [
          TrailPoint(
            trailId: 'legacy-trail-1',
            latitude: 35.6812,
            longitude: 139.7671,
            recordedAt: DateTime.utc(2026, 11, 20, 8, 5),
          ),
        ],
      );

      const legacyRecPath =
          '/v1/projects/test-e2ee-proj/databases/(default)/documents/users/$uid/osm_records/legacy-rec-1';
      const legacyTrailPath =
          '/v1/projects/test-e2ee-proj/databases/(default)/documents/users/$uid/trails/legacy-trail-1';
      fakeFs.docs[legacyRecPath] = {
        'name': legacyRecPath,
        'fields': FirebaseSyncService.encodeRecordToFirestoreFields(
          legacyRec,
          ownerUid: uid,
          photoDataUri: 'data:image/jpeg;base64,LEGACYPHOTO',
        ),
      };
      fakeFs.docs[legacyTrailPath] = {
        'name': legacyTrailPath,
        'fields': FirebaseSyncService.encodeTrailToFirestoreFields(
          legacyTrail,
          ownerUid: uid,
        ),
      };

      final fb = FirebaseSyncService(
        prefs: UserPreferencesService(),
        client: client,
        uidOverride: () => uid,
        projectIdOverride: () => 'test-e2ee-proj',
        idTokenOverride: ({bool forceRefresh = false}) async => 'jwt-legacy',
      );
      fb.setUnlockedKeyPairForTest(X25519.generateKeyPair());

      final res = await fb.migrateAndPurgeLegacyPlaintextCollections();
      expect(res.migratedRecords, equals(1));
      expect(res.migratedTrails, equals(1));
      expect(res.deletedLegacy, equals(2));

      // Legacy plaintext docs MUST be completely deleted from users/{uid}/osm_records & trails!
      expect(fakeFs.docs.containsKey(legacyRecPath), isFalse);
      expect(fakeFs.docs.containsKey(legacyTrailPath), isFalse);

      // New E2EE docs MUST exist under items/ with ZERO plaintext!
      const e2eeRecPath =
          '/v1/projects/test-e2ee-proj/databases/(default)/documents/items/rec_legacy-rec-1';
      const e2eeTrailPath =
          '/v1/projects/test-e2ee-proj/databases/(default)/documents/items/trail_legacy-trail-1';
      expect(fakeFs.docs.containsKey(e2eeRecPath), isTrue);
      expect(fakeFs.docs.containsKey(e2eeTrailPath), isTrue);
      expect(jsonEncode(fakeFs.docs[e2eeRecPath]), isNot(contains('Unencrypted Cafe')));
      expect(jsonEncode(fakeFs.docs[e2eeRecPath]), isNot(contains('LEGACYPHOTO')));
      expect(
        jsonEncode(fakeFs.docs[e2eeTrailPath]),
        isNot(contains('Legacy Unencrypted Walk')),
      );

      // Decrypted pull recovers all migrated data cleanly
      final recs = await fb.fetchAllRecords();
      final trails = await fb.fetchAllTrails();
      expect(recs.length, equals(1));
      expect(recs.first.record.tags['name'], equals('Unencrypted Cafe'));
      expect(recs.first.photoDataUri, equals('data:image/jpeg;base64,LEGACYPHOTO'));
      expect(trails.length, equals(1));
      expect(trails.first.name, equals('Legacy Unencrypted Walk'));
    });

    test('SensorService configures Android Foreground Service + WakeLock for minimized background trail recording', () {
      final settings = SensorService.buildTrailLocationSettings(
        distanceFilterMeters: 5,
        trailName: 'Mt. Takao Loop',
        forceAndroidForTest: true,
      );
      expect(settings, isA<AndroidSettings>());
      final android = settings as AndroidSettings;
      expect(android.accuracy, equals(LocationAccuracy.best));
      expect(android.distanceFilter, equals(5));
      expect(android.foregroundNotificationConfig, isNotNull);
      expect(android.foregroundNotificationConfig!.enableWakeLock, isTrue);
      expect(android.foregroundNotificationConfig!.setOngoing, isTrue);
      expect(
        android.foregroundNotificationConfig!.notificationTitle,
        equals('Recording Route'),
      );
      expect(
        android.foregroundNotificationConfig!.notificationText,
        contains('Mt. Takao Loop'),
      );
    });

    test('Enforces single key per device: re-initializing on Android or Web reuses the existing device key & user data instead of creating a duplicate', () async {
      final fakeFs = _FakeFirestoreRest();
      final client = fakeFs.createClient();
      final handleToUid = <String, String>{};
      String uidForHandle(String handle) =>
          handleToUid.putIfAbsent(handle, () => 'uid-single-${handleToUid.length + 1}');

      // --- Android device: generates key ONCE, then always reuses the same key & UID ---
      String? androidUid;
      final androidBridge = _FakeE2eePlatformBridge(
        prfSupported: false,
        androidCacheSupported: true,
      );
      final androidFb = FirebaseSyncService(
        prefs: UserPreferencesService(),
        client: client,
        platformBridge: androidBridge,
        uidOverride: () => androidUid,
        projectIdOverride: () => 'test-e2ee-proj',
        idTokenOverride: ({bool forceRefresh = false}) async => 'jwt-android',
        vaultAuthOverride: (creds, {required bool createNew}) async {
          androidUid = uidForHandle(creds.internalHandle);
        },
        authSignOutOverride: () async => androidUid = null,
      );
      await androidFb.refreshSessionAndTryAutoUnlock();
      expect(androidFb.hasDeviceKey, isFalse);

      final firstInit = await androidFb.initializeDeviceVault(
        argon2Params: fastArgon2ForTest,
      );
      final originalUid = androidFb.currentUid!;
      final originalPubKey = firstInit.keyring.x25519PublicKeyB64;
      expect(androidFb.hasDeviceKey, isTrue);

      // Simulate app closed (volatile key cleared, Firebase auth signed out)
      androidFb.lockVault();
      androidUid = null;
      await androidFb.refreshSessionAndTryAutoUnlock();
      expect(androidFb.hasDeviceKey, isTrue);
      expect(androidFb.isVaultUnlocked, isFalse);

      // Calling initializeDeviceVault() or createVaultWithRecoveryKey() again MUST reuse the same key & UID!
      final secondInit = await androidFb.initializeDeviceVault(
        argon2Params: fastArgon2ForTest,
      );
      expect(androidFb.currentUid, equals(originalUid));
      expect(secondInit.keyring.x25519PublicKeyB64, equals(originalPubKey));
      expect(handleToUid.length, equals(1));

      // --- Web Passkey PRF device: stores credentialId and reuses same Passkey on repeat init ---
      String? webUid;
      final webPrfSecret = secureRandomBytes(32);
      final webPrefs = UserPreferencesService();
      final webBridge = _FakeE2eePlatformBridge(
        prfSupported: true,
        androidCacheSupported: false,
        prfSecretToReturn: webPrfSecret,
      );
      final webFb = FirebaseSyncService(
        prefs: webPrefs,
        client: client,
        platformBridge: webBridge,
        uidOverride: () => webUid,
        projectIdOverride: () => 'test-e2ee-proj',
        idTokenOverride: ({bool forceRefresh = false}) async => 'jwt-web',
        vaultAuthOverride: (creds, {required bool createNew}) async {
          webUid = uidForHandle(creds.internalHandle);
        },
      );
      await webFb.refreshSessionAndTryAutoUnlock();
      expect(webFb.hasDeviceKey, isFalse);

      final webFirst = await webFb.initializeDeviceVault(
        argon2Params: fastArgon2ForTest,
      );
      expect(webPrefs.e2eePasskeyCredentialId, isNotEmpty);
      expect(webFb.hasDeviceKey, isTrue);

      webFb.lockVault();
      webUid = null;
      expect(webFb.hasDeviceKey, isTrue);

      final webSecond = await webFb.initializeDeviceVault(
        argon2Params: fastArgon2ForTest,
      );
      expect(webSecond.keyring.x25519PublicKeyB64, equals(webFirst.keyring.x25519PublicKeyB64));
      expect(handleToUid.length, equals(2));
    });

    test('Single smart Sync button automatically uploads local files missing from Firestore even when marked synced locally, and skips files already present', () async {
      final fakeFs = _FakeFirestoreRest();
      final client = fakeFs.createClient();
      const uid = 'uid-smart-sync';

      final prefs = UserPreferencesService();
      final db = _InMemorySyncDb();
      await db.init();
      final connectivity = ConnectivityService(initialHasNetwork: true);
      final sensors = SensorService();
      final ai = HybridAiService(connectivity: connectivity, prefs: prefs);
      final tiles = OfflineTileService();
      final fb = FirebaseSyncService(
        prefs: prefs,
        client: client,
        uidOverride: () => uid,
        projectIdOverride: () => 'test-e2ee-proj',
        idTokenOverride: ({bool forceRefresh = false}) async => 'jwt-sync',
      );
      fb.setUnlockedKeyPairForTest(X25519.generateKeyPair());

      final store = MapperStore(
        db: db,
        sensors: sensors,
        ai: ai,
        connectivity: connectivity,
        prefs: prefs,
        firebaseSync: fb,
        tiles: tiles,
      );
      await store.init();

      // Record A is marked firebaseSyncedAt locally, AND is NOT yet in Firestore!
      final recMissingInCloud = OsmRecord(
        id: 'rec-missing-cloud',
        createdAt: DateTime.utc(2026, 11, 25, 9, 0),
        updatedAt: DateTime.utc(2026, 11, 25, 9, 0),
        latitude: 35.6812,
        longitude: 139.7671,
        summary: 'Station Entrance',
        tags: const {'railway': 'subway_entrance', 'name': 'Exit A1'},
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.aiEnriched,
        firebaseSyncedAt: DateTime.utc(2026, 11, 24),
      );
      // Record B is already synced AND already in Firestore!
      final recAlreadyInCloud = OsmRecord(
        id: 'rec-already-cloud',
        createdAt: DateTime.utc(2026, 11, 25, 10, 0),
        updatedAt: DateTime.utc(2026, 11, 25, 10, 0),
        latitude: 35.6820,
        longitude: 139.7680,
        summary: 'Corner Cafe',
        tags: const {'amenity': 'cafe', 'name': 'Already Backed Up'},
        aiSource: AiSource.firebaseCloud,
        status: RecordStatus.aiEnriched,
        firebaseSyncedAt: DateTime.utc(2026, 11, 25, 10, 1),
      );
      await fb.syncRecord(recAlreadyInCloud);
      await db.upsertRecord(recMissingInCloud);
      await db.upsertRecord(recAlreadyInCloud);
      await store.reload();

      // One single sync call without forceUploadAll:
      // MUST detect rec-missing-cloud is absent from Firestore and upload ONLY that 1 record!
      final syncRes = await store.syncAllUnsyncedToFirebase();
      expect(syncRes.hasErrors, isFalse);
      expect(syncRes.recordsSynced, equals(1));
      expect(
        fakeFs.docs.containsKey(
          '/v1/projects/test-e2ee-proj/databases/(default)/documents/items/rec_rec-missing-cloud',
        ),
        isTrue,
      );

      // Running Sync again when Firestore already has both records uploads 0!
      final secondSync = await store.syncAllUnsyncedToFirebase();
      expect(secondSync.hasErrors, isFalse);
      expect(secondSync.recordsSynced, equals(0));

      // Removing a record AND a trail locally queues remote deletions so the Sync icon suggests syncing
      final syncedTrail = HikeTrail(
        id: 'trail-to-delete',
        name: 'Park Loop',
        startedAt: DateTime.utc(2026, 11, 25, 7, 0),
        isActive: false,
        tags: const {'highway': 'footway'},
        firebaseSyncedAt: DateTime.utc(2026, 11, 25, 7, 30),
        points: [
          TrailPoint(
            trailId: 'trail-to-delete',
            latitude: 35.68,
            longitude: 139.76,
            recordedAt: DateTime.utc(2026, 11, 25, 7, 5),
          ),
        ],
      );
      await fb.syncTrail(syncedTrail);
      await db.upsertTrail(syncedTrail);
      await store.reload();
      expect(store.totalUnsyncedCount, equals(0));

      await store.deleteRecord('rec-already-cloud');
      await store.deleteTrail('trail-to-delete');

      expect(store.hasPendingRemoteDeletes, isTrue);
      expect(store.pendingRemoteDeleteCount, equals(2));
      expect(store.totalUnsyncedCount, equals(2));

      // Passive pull MUST NOT resurrect deleted items before user taps Sync
      await store.pullFromFirebase();
      expect(store.records.any((r) => r.id == 'rec-already-cloud'), isFalse);
      expect(store.trails.any((t) => t.id == 'trail-to-delete'), isFalse);
      expect(
        fakeFs.docs.containsKey(
          '/v1/projects/test-e2ee-proj/databases/(default)/documents/items/rec_rec-already-cloud',
        ),
        isTrue,
      );

      // Tapping Sync deletes both items on Firestore and clears the Sync badge back to 0!
      final deleteSync = await store.syncAllUnsyncedToFirebase();
      expect(deleteSync.hasErrors, isFalse);
      expect(deleteSync.recordsDeleted, equals(1));
      expect(deleteSync.trailsDeleted, equals(1));
      expect(deleteSync.totalDeleted, equals(2));
      expect(store.hasPendingRemoteDeletes, isFalse);
      expect(store.totalUnsyncedCount, equals(0));
      expect(
        fakeFs.docs.containsKey(
          '/v1/projects/test-e2ee-proj/databases/(default)/documents/items/rec_rec-already-cloud',
        ),
        isFalse,
      );
      expect(
        fakeFs.docs.containsKey(
          '/v1/projects/test-e2ee-proj/databases/(default)/documents/items/trail_trail-to-delete',
        ),
        isFalse,
      );

      // Deleting a trail that was NEVER uploaded to Firestore succeeds cleanly
      // without issuing a DELETE on a non-existent document (which would 403 in Firestore Rules!)
      int deleteCallsForMissing = 0;
      final strictDeleteClient = MockClient((req) async {
        if (req.method == 'GET') {
          return http.Response('{"error":{"code":404}}', 404);
        }
        if (req.method == 'DELETE') {
          deleteCallsForMissing++;
          return http.Response(
            '{"error":{"code":403,"message":"Missing or insufficient permissions."}}',
            403,
          );
        }
        return http.Response('{}', 200);
      });
      final strictFb = FirebaseSyncService(
        prefs: prefs,
        client: strictDeleteClient,
        uidOverride: () => uid,
        projectIdOverride: () => 'test-e2ee-proj',
        idTokenOverride: ({bool forceRefresh = false}) async => 'jwt-sync',
      );
      await strictFb.deleteTrail('never-uploaded-trail-id');
      expect(deleteCallsForMissing, equals(0));
    });

    test('MapperStore.init never auto-starts route recording on launch even if a stale active trail exists in DB', () async {
      final db = _InMemorySyncDb();
      await db.init();
      final prefs = UserPreferencesService();
      final connectivity = ConnectivityService(initialHasNetwork: false);
      final sensors = SensorService();
      final ai = HybridAiService(connectivity: connectivity, prefs: prefs);
      final tiles = OfflineTileService();
      final fb = FirebaseSyncService(prefs: prefs);

      // Seed a stale trail left with isActive: true from a previous killed session
      final staleWithPoints = HikeTrail(
        id: 'stale-active-trail',
        name: 'Interrupted Walk',
        startedAt: DateTime.utc(2026, 11, 25, 8, 0),
        isActive: true,
        tags: const {'highway': 'footway'},
        points: [
          TrailPoint(
            trailId: 'stale-active-trail',
            latitude: 35.68,
            longitude: 139.76,
            recordedAt: DateTime.utc(2026, 11, 25, 8, 12),
          ),
        ],
      );
      final staleEmpty = HikeTrail(
        id: 'stale-empty-trail',
        name: 'Empty Interrupted Walk',
        startedAt: DateTime.utc(2026, 11, 25, 9, 0),
        isActive: true,
        tags: const {'highway': 'footway'},
        points: const [],
      );
      await db.upsertTrail(staleWithPoints);
      await db.upsertTrail(staleEmpty);

      final store = MapperStore(
        db: db,
        sensors: sensors,
        ai: ai,
        connectivity: connectivity,
        prefs: prefs,
        firebaseSync: fb,
        tiles: tiles,
      );
      await store.init();

      // App MUST NOT auto-start recording on launch
      expect(store.isRecordingTrail, isFalse);
      expect(store.activeTrail, isNull);
      expect(sensors.isBackgroundTrailTracking, isFalse);

      // Trail with points is safely finalized as a saved route; empty stale trail is cleaned up
      expect(store.trails.length, equals(1));
      expect(store.trails.first.id, equals('stale-active-trail'));
      expect(store.trails.first.isActive, isFalse);
      expect(
        store.trails.first.endedAt,
        equals(DateTime.utc(2026, 11, 25, 8, 12)),
      );
    });
  });
}

class _InMemorySyncDb extends LocalDbService {
  final Map<String, OsmRecord> _records = {};
  final Map<String, HikeTrail> _trails = {};
  final Map<String, String> _settings = {};

  @override
  Future<void> init() async {}

  @override
  Future<void> upsertRecord(OsmRecord record) async {
    _records[record.id] = record;
  }

  @override
  Future<List<OsmRecord>> getAllRecords() async => _records.values.toList();

  @override
  Future<void> deleteRecord(String id) async {
    _records.remove(id);
  }

  @override
  Future<void> upsertTrail(HikeTrail trail) async {
    _trails[trail.id] = trail;
  }

  @override
  Future<void> deleteTrail(String trailId) async {
    _trails.remove(trailId);
  }

  @override
  Future<void> replaceTrailPoints(
    String trailId,
    List<TrailPoint> points,
  ) async {
    final existing = _trails[trailId];
    if (existing != null) {
      _trails[trailId] = existing.copyWith(points: points);
    }
  }

  @override
  Future<List<HikeTrail>> getAllTrails() async => _trails.values.toList();

  @override
  Future<Map<String, String>> getAllSettings() async =>
      Map<String, String>.from(_settings);

  @override
  Future<void> setSetting(String key, String value) async {
    _settings[key] = value;
  }
}
