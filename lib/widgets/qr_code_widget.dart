import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class _QrVersionSpec {
  final int version;
  final int ecPerBlock;
  final int g1Blocks;
  final int g1DataCw;
  final int g2Blocks;
  final int g2DataCw;

  const _QrVersionSpec(
    this.version,
    this.ecPerBlock,
    this.g1Blocks,
    this.g1DataCw,
    this.g2Blocks,
    this.g2DataCw,
  );

  int get totalDataCw => g1Blocks * g1DataCw + g2Blocks * g2DataCw;
  int get totalBlocks => g1Blocks + g2Blocks;
  int get totalCodewords => totalDataCw + totalBlocks * ecPerBlock;

  /// Byte-mode max payload in UTF-8 bytes (4-bit mode + 8-bit count for V1..9,
  /// 16-bit count for V10..20).
  int get byteCapacity => totalDataCw - (version <= 9 ? 2 : 3);
}

/// Standards-compliant pure-Dart QR Code (ISO/IEC 18004, Byte Mode, EC Level L,
/// Versions 1–20 up to 858 UTF-8 bytes) so Bitcoin BIP-21 / BIP-321 URIs,
/// Silent Payments (BIP-352), BOLT 12 offers (`lno1...`), Lightning Addresses,
/// and BTCPay Server links render offline with zero third-party packages.
class QrMatrix {
  final int version;
  final int size;
  final List<List<bool>> modules;

  const QrMatrix({
    required this.version,
    required this.size,
    required this.modules,
  });

  /// ISO/IEC 18004 Table 9 — Error Correction Level L, Versions 1..20.
  static const List<_QrVersionSpec> _specs = [
    _QrVersionSpec(1, 7, 1, 19, 0, 0),
    _QrVersionSpec(2, 10, 1, 34, 0, 0),
    _QrVersionSpec(3, 15, 1, 55, 0, 0),
    _QrVersionSpec(4, 20, 1, 80, 0, 0),
    _QrVersionSpec(5, 26, 1, 108, 0, 0),
    _QrVersionSpec(6, 18, 2, 68, 0, 0),
    _QrVersionSpec(7, 20, 2, 78, 0, 0),
    _QrVersionSpec(8, 24, 2, 97, 0, 0),
    _QrVersionSpec(9, 30, 2, 116, 0, 0),
    _QrVersionSpec(10, 18, 2, 68, 2, 69),
    _QrVersionSpec(11, 20, 4, 81, 0, 0),
    _QrVersionSpec(12, 24, 2, 92, 2, 93),
    _QrVersionSpec(13, 26, 4, 107, 0, 0),
    _QrVersionSpec(14, 30, 3, 115, 1, 116),
    _QrVersionSpec(15, 22, 5, 87, 1, 88),
    _QrVersionSpec(16, 24, 5, 98, 1, 99),
    _QrVersionSpec(17, 28, 1, 107, 5, 108),
    _QrVersionSpec(18, 30, 5, 120, 1, 121),
    _QrVersionSpec(19, 28, 3, 113, 4, 114),
    _QrVersionSpec(20, 28, 3, 107, 5, 108),
  ];

  static int get maxByteCapacity => _specs.last.byteCapacity;

  /// Encodes UTF-8 [data] into a scannable QR code matrix (Error Correction L).
  static QrMatrix encode(String data) {
    var bytes = Uint8List.fromList(utf8.encode(data));
    if (bytes.length > maxByteCapacity) {
      bytes = Uint8List.sublistView(bytes, 0, maxByteCapacity);
    }

    final spec = _specs.firstWhere((s) => bytes.length <= s.byteCapacity);
    final version = spec.version;
    final size = 17 + version * 4;
    final totalDataCw = spec.totalDataCw;

    // 1. Build bit stream: Mode (0100 = Byte), Char count (8 bits V1-9, 16 bits V10+),
    //    Data bytes, Terminator, padding codewords.
    final bits = <int>[];
    void pushBits(int val, int len) {
      for (var i = len - 1; i >= 0; i--) {
        bits.add((val >> i) & 1);
      }
    }

    pushBits(0x4, 4); // Byte mode
    pushBits(bytes.length, version <= 9 ? 8 : 16);
    for (final b in bytes) {
      pushBits(b, 8);
    }
    final maxDataBits = totalDataCw * 8;
    final termLen = (maxDataBits - bits.length).clamp(0, 4);
    pushBits(0, termLen);
    while (bits.length % 8 != 0) {
      bits.add(0);
    }

    final dataBytes = <int>[];
    for (var i = 0; i < bits.length; i += 8) {
      var val = 0;
      for (var j = 0; j < 8; j++) {
        val = (val << 1) | bits[i + j];
      }
      dataBytes.add(val);
    }
    const padBytes = [0xEC, 0x11];
    var padIdx = 0;
    while (dataBytes.length < totalDataCw) {
      dataBytes.add(padBytes[padIdx % 2]);
      padIdx++;
    }

    // 2. Split into Group 1 & Group 2 RS blocks & compute Reed-Solomon EC codewords.
    final ecCount = spec.ecPerBlock;
    final dataBlocks = <List<int>>[];
    final ecBlocks = <List<int>>[];
    var offset = 0;

    for (var b = 0; b < spec.g1Blocks; b++) {
      final slice = dataBytes.sublist(offset, offset + spec.g1DataCw);
      offset += spec.g1DataCw;
      dataBlocks.add(slice);
      ecBlocks.add(_rsComputeRemainder(slice, ecCount));
    }
    for (var b = 0; b < spec.g2Blocks; b++) {
      final slice = dataBytes.sublist(offset, offset + spec.g2DataCw);
      offset += spec.g2DataCw;
      dataBlocks.add(slice);
      ecBlocks.add(_rsComputeRemainder(slice, ecCount));
    }

    // Interleave data codewords across all blocks, then EC codewords.
    final finalCodewords = <int>[];
    final maxBlockDataCw =
        spec.g2Blocks > 0 ? spec.g2DataCw : spec.g1DataCw;
    for (var i = 0; i < maxBlockDataCw; i++) {
      for (final block in dataBlocks) {
        if (i < block.length) {
          finalCodewords.add(block[i]);
        }
      }
    }
    for (var i = 0; i < ecCount; i++) {
      for (final block in ecBlocks) {
        finalCodewords.add(block[i]);
      }
    }
    assert(finalCodewords.length == spec.totalCodewords);

    // 3. Place function patterns
    final matrix = List.generate(size, (_) => List<bool>.filled(size, false));
    final isFunc = List.generate(size, (_) => List<bool>.filled(size, false));

    void setFunc(int r, int c, bool dark) {
      if (r < 0 || r >= size || c < 0 || c >= size) return;
      matrix[r][c] = dark;
      isFunc[r][c] = true;
    }

    void drawFinder(int top, int left) {
      for (var dr = -1; dr <= 7; dr++) {
        for (var dc = -1; dc <= 7; dc++) {
          final r = top + dr;
          final c = left + dc;
          if (r < 0 || r >= size || c < 0 || c >= size) continue;
          final inOuter = dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6;
          final isBorder = dr == 0 || dr == 6 || dc == 0 || dc == 6;
          final isInner = dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4;
          setFunc(r, c, inOuter && (isBorder || isInner));
        }
      }
    }

    drawFinder(0, 0);
    drawFinder(0, size - 7);
    drawFinder(size - 7, 0);

    // Timing patterns
    for (var i = 8; i < size - 8; i++) {
      setFunc(6, i, i % 2 == 0);
      setFunc(i, 6, i % 2 == 0);
    }

    // Alignment patterns (Versions 2..20): skip only the 3 finder pattern corners,
    // NOT intersections with the timing patterns along row 6 / col 6.
    final alignCoords = _alignmentCenters(version);
    final lastIdx = alignCoords.length - 1;
    for (var i = 0; i < alignCoords.length; i++) {
      for (var j = 0; j < alignCoords.length; j++) {
        if ((i == 0 && j == 0) ||
            (i == 0 && j == lastIdx) ||
            (i == lastIdx && j == 0)) {
          continue;
        }
        final ar = alignCoords[i];
        final ac = alignCoords[j];
        for (var dr = -2; dr <= 2; dr++) {
          for (var dc = -2; dc <= 2; dc++) {
            final dark = dr == -2 ||
                dr == 2 ||
                dc == -2 ||
                dc == 2 ||
                (dr == 0 && dc == 0);
            setFunc(ar + dr, ac + dc, dark);
          }
        }
      }
    }

    // Reserve format info areas + dark module
    for (var i = 0; i <= 8; i++) {
      if (!isFunc[8][i]) setFunc(8, i, false);
      if (!isFunc[i][8]) setFunc(i, 8, false);
    }
    for (var i = size - 8; i < size; i++) {
      setFunc(8, i, false);
      setFunc(i, 8, false);
    }
    setFunc(size - 8, 8, true); // Dark module

    // Reserve version info for Version 7+
    if (version >= 7) {
      final verBits = _versionInfoBits(version);
      for (var i = 0; i < 18; i++) {
        final bit = ((verBits >> i) & 1) == 1;
        final a = size - 11 + (i % 3);
        final b = i ~/ 3;
        setFunc(b, a, bit);
        setFunc(a, b, bit);
      }
    }

    // 4. Place data bits in zigzag columns
    var bitIndex = 0;
    final totalBits = finalCodewords.length * 8;
    var upward = true;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5; // Skip vertical timing column
      for (var vert = 0; vert < size; vert++) {
        final r = upward ? (size - 1 - vert) : vert;
        for (var j = 0; j < 2; j++) {
          final c = right - j;
          if (!isFunc[r][c]) {
            var dark = false;
            if (bitIndex < totalBits) {
              dark =
                  ((finalCodewords[bitIndex >> 3] >> (7 - (bitIndex & 7))) &
                          1) ==
                      1;
              bitIndex++;
            }
            matrix[r][c] = dark;
          }
        }
      }
      upward = !upward;
    }

    // 5. Apply Mask 0 ((r + c) % 2 == 0) & write format info for EC-L (01) + Mask 0 (000)
    const maskPattern = 0;
    for (var r = 0; r < size; r++) {
      for (var c = 0; c < size; c++) {
        if (!isFunc[r][c] && ((r + c) % 2 == 0)) {
          matrix[r][c] = !matrix[r][c];
        }
      }
    }

    // Format bits for EC Level L (01) + Mask 0 (000) -> 15-bit BCH + XOR 0x5412
    final formatBits = _formatInfoBits(0x01, maskPattern);
    for (var i = 0; i <= 5; i++) {
      matrix[8][i] = ((formatBits >> (14 - i)) & 1) == 1;
    }
    matrix[8][7] = ((formatBits >> 8) & 1) == 1;
    matrix[8][8] = ((formatBits >> 7) & 1) == 1;
    matrix[7][8] = ((formatBits >> 6) & 1) == 1;
    for (var i = 9; i < 15; i++) {
      matrix[14 - i][8] = ((formatBits >> (14 - i)) & 1) == 1;
    }
    for (var i = 0; i < 8; i++) {
      matrix[size - 1 - i][8] = ((formatBits >> (14 - i)) & 1) == 1;
    }
    for (var i = 8; i < 15; i++) {
      matrix[8][size - 15 + i] = ((formatBits >> (14 - i)) & 1) == 1;
    }
    matrix[size - 8][8] = true;

    return QrMatrix(version: version, size: size, modules: matrix);
  }

  static List<int> _alignmentCenters(int version) {
    return switch (version) {
      1 => const [],
      2 => const [6, 18],
      3 => const [6, 22],
      4 => const [6, 26],
      5 => const [6, 30],
      6 => const [6, 34],
      7 => const [6, 22, 38],
      8 => const [6, 24, 42],
      9 => const [6, 26, 46],
      10 => const [6, 28, 50],
      11 => const [6, 30, 54],
      12 => const [6, 32, 58],
      13 => const [6, 34, 62],
      14 => const [6, 26, 46, 66],
      15 => const [6, 26, 48, 70],
      16 => const [6, 26, 50, 74],
      17 => const [6, 30, 54, 78],
      18 => const [6, 30, 56, 82],
      19 => const [6, 30, 58, 86],
      20 => const [6, 34, 62, 90],
      _ => const [],
    };
  }

  static int _formatInfoBits(int ecLevelBits, int mask) {
    final data = (ecLevelBits << 3) | mask;
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ (((rem >> 9) & 1) * 0x537);
    }
    return ((data << 10) | rem) ^ 0x5412;
  }

  static int _versionInfoBits(int version) {
    var rem = version;
    for (var i = 0; i < 12; i++) {
      rem = (rem << 1) ^ (((rem >> 11) & 1) * 0x1F25);
    }
    return (version << 12) | rem;
  }

  static int _gfMul(int x, int y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = (z << 1) ^ (((z >> 7) & 1) * 0x11D);
      z ^= ((y >> i) & 1) * x;
    }
    return z;
  }

  static List<int> _rsGenerator(int degree) {
    var result = List<int>.filled(degree, 0);
    result[degree - 1] = 1;
    var root = 1;
    for (var i = 0; i < degree; i++) {
      for (var j = 0; j < degree; j++) {
        result[j] = _gfMul(result[j], root);
        if (j + 1 < degree) result[j] ^= result[j + 1];
      }
      root = _gfMul(root, 0x02);
    }
    return result;
  }

  static List<int> _rsComputeRemainder(List<int> data, int degree) {
    final gen = _rsGenerator(degree);
    final result = List<int>.filled(degree, 0, growable: true);
    for (final b in data) {
      final factor = b ^ result[0];
      result.removeAt(0);
      result.add(0);
      for (var i = 0; i < degree; i++) {
        result[i] ^= _gfMul(gen[i], factor);
      }
    }
    return result;
  }
}

/// Crisp offline QR code widget rendered with a white quiet zone for reliable scanning.
class QrCodeWidget extends StatelessWidget {
  final String data;
  final double size;
  final Color foregroundColor;
  final Color backgroundColor;

  const QrCodeWidget({
    super.key,
    required this.data,
    this.size = 190,
    this.foregroundColor = Colors.black,
    this.backgroundColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    final matrix = QrMatrix.encode(data);
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black12),
      ),
      child: CustomPaint(
        painter: _QrPainter(matrix: matrix, color: foregroundColor),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  final QrMatrix matrix;
  final Color color;

  const _QrPainter({required this.matrix, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final moduleSize = size.width / matrix.size;
    for (var r = 0; r < matrix.size; r++) {
      for (var c = 0; c < matrix.size; c++) {
        if (matrix.modules[r][c]) {
          canvas.drawRect(
            Rect.fromLTWH(
              c * moduleSize,
              r * moduleSize,
              moduleSize + 0.35,
              moduleSize + 0.35,
            ),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter oldDelegate) =>
      oldDelegate.matrix != matrix || oldDelegate.color != color;
}
