import 'dart:typed_data';

import 'e2ee_envelope_crypto.dart';

/// Web (Dart2JS) RFC 9106 Argon2id runner using 100% 32-bit safe arithmetic.
Future<Uint8List> deriveArgon2idPlatformImpl({
  required Uint8List password,
  required Uint8List salt,
  required int memoryKiB,
  required int iterations,
  required int parallelism,
  required int keyLength,
  Uint8List? secret,
  Uint8List? associatedData,
}) async {
  // Yield once so loading spinner renders before heavy KDF computation.
  await Future<void>.delayed(Duration.zero);
  return Argon2id.deriveKeyPure32(
    password: password,
    salt: salt,
    params: Argon2Params(
      memoryKiB: memoryKiB,
      iterations: iterations,
      parallelism: parallelism,
      keyLength: keyLength,
    ),
    secret: secret,
    associatedData: associatedData,
  );
}
