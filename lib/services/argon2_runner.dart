import 'dart:typed_data';

import 'argon2_runner_io.dart'
    if (dart.library.js_interop) 'argon2_runner_web.dart';

/// RFC 9106 Argon2id parameters.
/// Production default: 64 MiB memory (65536 KiB), 3 iterations, 1 lane, 32-byte key.
class Argon2Params {
  final int memoryKiB;
  final int iterations;
  final int parallelism;
  final int keyLength;

  const Argon2Params({
    this.memoryKiB = 65536, // 64 MiB
    this.iterations = 3,
    this.parallelism = 1,
    this.keyLength = 32,
  });

  static const Argon2Params defaultProduction = Argon2Params(
    memoryKiB: 65536,
    iterations: 3,
    parallelism: 1,
    keyLength: 32,
  );

  static const int minMemoryKiB = 8;
  static const int maxMemoryKiB = 262144; // 256 MiB ceiling against client OOM DoS
  static const int minIterations = 1;
  static const int maxIterations = 16;
  static const int minParallelism = 1;
  static const int maxParallelism = 4;

  /// Validates untrusted [Argon2Params] (e.g., deserialized from Firestore)
  /// against strict resource bounds to prevent client OOM/CPU DoS.
  void validateBounds({int requiredKeyLength = 32}) {
    if (memoryKiB < minMemoryKiB || memoryKiB > maxMemoryKiB) {
      throw RangeError.range(
        memoryKiB,
        minMemoryKiB,
        maxMemoryKiB,
        'memoryKiB',
        'Argon2id memoryKiB out of safe bounds',
      );
    }
    if (iterations < minIterations || iterations > maxIterations) {
      throw RangeError.range(
        iterations,
        minIterations,
        maxIterations,
        'iterations',
        'Argon2id iterations out of safe bounds',
      );
    }
    if (parallelism < minParallelism || parallelism > maxParallelism) {
      throw RangeError.range(
        parallelism,
        minParallelism,
        maxParallelism,
        'parallelism',
        'Argon2id parallelism out of safe bounds',
      );
    }
    if (keyLength != requiredKeyLength) {
      throw RangeError.value(
        keyLength,
        'keyLength',
        'Argon2id keyLength must equal $requiredKeyLength bytes',
      );
    }
  }

  Map<String, dynamic> toJson() => {
        'alg': 'argon2id',
        'm': memoryKiB,
        't': iterations,
        'p': parallelism,
        'dkLen': keyLength,
      };

  factory Argon2Params.fromJson(Map<String, dynamic> json) {
    final m = (json['m'] as num?)?.toInt() ?? 65536;
    final t = (json['t'] as num?)?.toInt() ?? 3;
    final p = (json['p'] as num?)?.toInt() ?? 1;
    final dkLen = (json['dkLen'] as num?)?.toInt() ?? 32;
    return Argon2Params(
      memoryKiB: m,
      iterations: t,
      parallelism: p,
      keyLength: dkLen,
    );
  }
}

/// Derives a key using RFC 9106 Argon2id off the main UI isolate on native
/// platforms (Android/Linux/Desktop) and using Web-safe 32-bit arithmetic on Web.
Future<Uint8List> deriveArgon2idAsync({
  required Uint8List password,
  required Uint8List salt,
  Argon2Params params = Argon2Params.defaultProduction,
  Uint8List? secret,
  Uint8List? associatedData,
}) {
  return deriveArgon2idPlatformImpl(
    password: password,
    salt: salt,
    memoryKiB: params.memoryKiB,
    iterations: params.iterations,
    parallelism: params.parallelism,
    keyLength: params.keyLength,
    secret: secret,
    associatedData: associatedData,
  );
}
