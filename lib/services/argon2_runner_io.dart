import 'dart:isolate';
import 'dart:typed_data';

import 'e2ee_envelope_crypto.dart';

/// Native (Android/Linux/Desktop) RFC 9106 Argon2id runner.
/// Executes in a background isolate using fast 64-bit native integer math so
/// 64 MiB / 3-iteration derivations never jank the UI thread.
Future<Uint8List> deriveArgon2idPlatformImpl({
  required Uint8List password,
  required Uint8List salt,
  required int memoryKiB,
  required int iterations,
  required int parallelism,
  required int keyLength,
  Uint8List? secret,
  Uint8List? associatedData,
}) {
  final pwdCopy = Uint8List.fromList(password);
  final saltCopy = Uint8List.fromList(salt);
  final secCopy = secret != null ? Uint8List.fromList(secret) : null;
  final adCopy =
      associatedData != null ? Uint8List.fromList(associatedData) : null;

  return Isolate.run(() {
    try {
      return _argon2idNative64(
        password: pwdCopy,
        salt: saltCopy,
        memoryKiB: memoryKiB,
        iterations: iterations,
        parallelism: parallelism,
        keyLength: keyLength,
        secret: secCopy,
        associatedData: adCopy,
      );
    } finally {
      zeroize(pwdCopy);
      zeroize(saltCopy);
      zeroize(secCopy);
      zeroize(adCopy);
    }
  });
}

Uint8List _argon2idNative64({
  required Uint8List password,
  required Uint8List salt,
  required int memoryKiB,
  required int iterations,
  required int parallelism,
  required int keyLength,
  Uint8List? secret,
  Uint8List? associatedData,
}) {
  if (parallelism < 1) {
    throw ArgumentError.value(parallelism, 'parallelism', 'Must be >= 1');
  }
  if (iterations < 1) {
    throw ArgumentError.value(iterations, 'iterations', 'Must be >= 1');
  }
  if (memoryKiB < 8 * parallelism) {
    throw ArgumentError.value(
      memoryKiB,
      'memoryKiB',
      'Must be >= 8 * parallelism',
    );
  }
  if (keyLength < 4) {
    throw ArgumentError.value(keyLength, 'keyLength', 'Must be >= 4');
  }

  final h0 = Argon2id.computeH0(
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

  // Flat 64-bit word buffer: 128 uint64 words (1024 bytes) per block.
  final memory = Uint64List(totalBlocks * 128);
  final zeroBlock = Uint64List(128);
  final inputBlock = Uint64List(128);
  final addressBlock = Uint64List(128);
  final tmpR = Uint64List(128);
  final tmpZ = Uint64List(128);

  try {
    // Initialize first two blocks per lane: B[i][0] = H'(H0 || 0 || i), B[i][1] = H'(H0 || 1 || i)
    final seedBuf = Uint8List(72);
    seedBuf.setRange(0, 64, h0);
    for (int lane = 0; lane < parallelism; lane++) {
      _putLe32(seedBuf, 68, lane);

      _putLe32(seedBuf, 64, 0);
      final b0 = Argon2id.blake2bLong(seedBuf, 1024);
      _bytesToWords64(b0, memory, (lane * laneLength) * 128);

      _putLe32(seedBuf, 64, 1);
      final b1 = Argon2id.blake2bLong(seedBuf, 1024);
      _bytesToWords64(b1, memory, (lane * laneLength + 1) * 128);
    }

    for (int pass = 0; pass < iterations; pass++) {
      for (int slice = 0; slice < 4; slice++) {
        for (int lane = 0; lane < parallelism; lane++) {
          final dataIndependent = pass == 0 && slice < 2;
          int addressCounter = 0;
          int addressOffset = 128; // force generation on first index

          if (dataIndependent) {
            inputBlock.fillRange(0, 128, 0);
            inputBlock[0] = pass;
            inputBlock[1] = lane;
            inputBlock[2] = slice;
            inputBlock[3] = totalBlocks;
            inputBlock[4] = iterations;
            inputBlock[5] = 2; // Argon2id type = 2
          }

          final startIndex = (pass == 0 && slice == 0) ? 2 : 0;
          final laneBase = lane * laneLength;

          for (int index = startIndex; index < segmentLength; index++) {
            final currOffset = slice * segmentLength + index;
            final prevOffset =
                currOffset == 0 ? laneLength - 1 : currOffset - 1;
            final prevWordBase = (laneBase + prevOffset) * 128;
            final currWordBase = (laneBase + currOffset) * 128;

            int j1;
            int j2;
            if (dataIndependent) {
              if (addressOffset >= 128) {
                addressCounter++;
                inputBlock[6] = addressCounter;
                _compress64(
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
                _compress64(
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
              final pseudoRand = addressBlock[addressOffset++];
              j1 = pseudoRand & 0xffffffff;
              j2 = (pseudoRand >>> 32) & 0xffffffff;
            } else {
              final pseudoRand = memory[prevWordBase];
              j1 = pseudoRand & 0xffffffff;
              j2 = (pseudoRand >>> 32) & 0xffffffff;
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

            // RFC 9106 §3.4.2 mapping J1 to reference block index
            int relPos = (j1 * j1) >>> 32;
            relPos = refAreaSize - 1 - ((refAreaSize * relPos) >>> 32);

            int startPos = 0;
            if (pass != 0) {
              startPos =
                  slice == 3 ? 0 : (slice + 1) * segmentLength;
            }
            final refIndex = (startPos + relPos) % laneLength;
            final refWordBase = (refLane * laneLength + refIndex) * 128;

            _compress64(
              memory,
              prevWordBase,
              memory,
              refWordBase,
              memory,
              currWordBase,
              pass != 0,
              tmpR,
              tmpZ,
            );
          }
        }
      }
    }

    // Final block C = XOR of last block of each lane
    final finalBlock = Uint64List(128);
    for (int lane = 0; lane < parallelism; lane++) {
      final lastBase = (lane * laneLength + laneLength - 1) * 128;
      for (int i = 0; i < 128; i++) {
        finalBlock[i] ^= memory[lastBase + i];
      }
    }
    final finalBytes = _words64ToBytes(finalBlock);
    final out = Argon2id.blake2bLong(finalBytes, keyLength);
    zeroize(finalBytes);
    finalBlock.fillRange(0, 128, 0);
    return out;
  } finally {
    zeroize(h0);
    memory.fillRange(0, memory.length, 0);
    inputBlock.fillRange(0, 128, 0);
    addressBlock.fillRange(0, 128, 0);
    tmpR.fillRange(0, 128, 0);
    tmpZ.fillRange(0, 128, 0);
  }
}

@pragma('vm:prefer-inline')
int _rotr64(int x, int n) => (x >>> n) | (x << (64 - n));

@pragma('vm:prefer-inline')
void _gb64(Uint64List v, int a, int b, int c, int d) {
  int va = v[a];
  int vb = v[b];
  int vc = v[c];
  int vd = v[d];

  va = va + vb + 2 * (va & 0xffffffff) * (vb & 0xffffffff);
  vd = _rotr64(vd ^ va, 32);
  vc = vc + vd + 2 * (vc & 0xffffffff) * (vd & 0xffffffff);
  vb = _rotr64(vb ^ vc, 24);
  va = va + vb + 2 * (va & 0xffffffff) * (vb & 0xffffffff);
  vd = _rotr64(vd ^ va, 16);
  vc = vc + vd + 2 * (vc & 0xffffffff) * (vd & 0xffffffff);
  vb = _rotr64(vb ^ vc, 63);

  v[a] = va;
  v[b] = vb;
  v[c] = vc;
  v[d] = vd;
}

@pragma('vm:prefer-inline')
void _p64(
  Uint64List v,
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
  _gb64(v, v0, v4, v8, v12);
  _gb64(v, v1, v5, v9, v13);
  _gb64(v, v2, v6, v10, v14);
  _gb64(v, v3, v7, v11, v15);
  _gb64(v, v0, v5, v10, v15);
  _gb64(v, v1, v6, v11, v12);
  _gb64(v, v2, v7, v8, v13);
  _gb64(v, v3, v4, v9, v14);
}

void _compress64(
  Uint64List xBuf,
  int xOff,
  Uint64List yBuf,
  int yOff,
  Uint64List outBuf,
  int outOff,
  bool xorOut,
  Uint64List r,
  Uint64List z,
) {
  for (int i = 0; i < 128; i++) {
    final v = xBuf[xOff + i] ^ yBuf[yOff + i];
    r[i] = v;
    z[i] = v;
  }

  // Row-wise P (8 rows of 16 uint64 words)
  for (int row = 0; row < 8; row++) {
    final b = row * 16;
    _p64(
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

  // Column-wise P (8 columns, each taking 2 consecutive uint64 words from each row)
  for (int col = 0; col < 8; col++) {
    final c = col * 2;
    _p64(
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
    for (int i = 0; i < 128; i++) {
      outBuf[outOff + i] ^= r[i] ^ z[i];
    }
  } else {
    for (int i = 0; i < 128; i++) {
      outBuf[outOff + i] = r[i] ^ z[i];
    }
  }
}

void _putLe32(Uint8List dst, int offset, int v) {
  dst[offset] = v & 0xff;
  dst[offset + 1] = (v >>> 8) & 0xff;
  dst[offset + 2] = (v >>> 16) & 0xff;
  dst[offset + 3] = (v >>> 24) & 0xff;
}

void _bytesToWords64(Uint8List src, Uint64List dst, int dstOff) {
  final bd = ByteData.sublistView(src);
  for (int i = 0; i < 128; i++) {
    dst[dstOff + i] = bd.getUint64(i * 8, Endian.little);
  }
}

Uint8List _words64ToBytes(Uint64List src) {
  final out = Uint8List(1024);
  final bd = ByteData.sublistView(out);
  for (int i = 0; i < 128; i++) {
    bd.setUint64(i * 8, src[i], Endian.little);
  }
  return out;
}
