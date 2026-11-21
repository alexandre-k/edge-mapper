import 'dart:typed_data';

/// GPS coordinates and optional telemetry extracted from a JPEG photo's EXIF APP1 block.
class ExifGpsData {
  final double latitude;
  final double longitude;
  final double? altitudeMeters;
  final double? headingDegrees;
  final double? accuracyMeters;

  const ExifGpsData({
    required this.latitude,
    required this.longitude,
    this.altitudeMeters,
    this.headingDegrees,
    this.accuracyMeters,
  });
}

/// Pure-Dart, zero-dependency JPEG EXIF GPS reader (works identically on Android & Web).
/// Extracts `GPSLatitude`, `GPSLongitude`, `GPSAltitude`, `GPSImgDirection`,
/// and `GPSHPositioningError` (EXIF 2.31 horizontal accuracy in meters).
class ExifGpsReader {
  ExifGpsReader._();

  static ExifGpsData? extractFromBytes(Uint8List? bytes) {
    if (bytes == null || bytes.length < 16) return null;
    // JPEG SOI marker: 0xFF 0xD8
    if (bytes[0] != 0xFF || bytes[1] != 0xD8) return null;

    int offset = 2;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset] != 0xFF) break;
      // Skip fill 0xFF bytes
      while (offset < bytes.length && bytes[offset] == 0xFF) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];

      // SOS (0xDA) or EOI (0xD9) -> end of metadata headers
      if (marker == 0xDA || marker == 0xD9) break;
      // Standalone markers without length
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;

      if (offset + 2 > bytes.length) break;
      final segLength = (bytes[offset] << 8) | bytes[offset + 1];
      if (segLength < 2 || offset + segLength > bytes.length) break;

      // APP1 (0xE1) starting with "Exif\0\0"
      if (marker == 0xE1 && segLength >= 16) {
        final payloadStart = offset + 2;
        if (bytes[payloadStart] == 0x45 && // E
            bytes[payloadStart + 1] == 0x78 && // x
            bytes[payloadStart + 2] == 0x69 && // i
            bytes[payloadStart + 3] == 0x66 && // f
            bytes[payloadStart + 4] == 0x00 &&
            bytes[payloadStart + 5] == 0x00) {
          final tiffStart = payloadStart + 6;
          final tiffLen = segLength - 8;
          if (tiffLen >= 8 && tiffStart + tiffLen <= bytes.length) {
            return _parseTiffGps(bytes, tiffStart, tiffLen);
          }
        }
      }

      offset += segLength;
    }

    return null;
  }

  static ExifGpsData? _parseTiffGps(
    Uint8List bytes,
    int tiffStart,
    int tiffLen,
  ) {
    final bd = ByteData.sublistView(bytes, tiffStart, tiffStart + tiffLen);
    if (bd.lengthInBytes < 8) return null;

    final b0 = bd.getUint8(0);
    final b1 = bd.getUint8(1);
    final Endian endian;
    if (b0 == 0x49 && b1 == 0x49) {
      endian = Endian.little; // 'II'
    } else if (b0 == 0x4D && b1 == 0x4D) {
      endian = Endian.big; // 'MM'
    } else {
      return null;
    }

    if (bd.getUint16(2, endian) != 0x002A) return null;
    final ifd0Offset = bd.getUint32(4, endian);
    if (ifd0Offset + 2 > bd.lengthInBytes) return null;

    // Locate GPSInfoIFDPointer (tag 0x8825) inside IFD0
    final entryCount = bd.getUint16(ifd0Offset, endian);
    int? gpsIfdOffset;
    for (int i = 0; i < entryCount; i++) {
      final entryPos = ifd0Offset + 2 + i * 12;
      if (entryPos + 12 > bd.lengthInBytes) break;
      final tag = bd.getUint16(entryPos, endian);
      if (tag == 0x8825) {
        gpsIfdOffset = bd.getUint32(entryPos + 8, endian);
        break;
      }
    }
    if (gpsIfdOffset == null || gpsIfdOffset + 2 > bd.lengthInBytes) {
      return null;
    }

    final gpsCount = bd.getUint16(gpsIfdOffset, endian);
    String? latRef;
    String? lonRef;
    double? latDeg;
    double? lonDeg;
    int altRef = 0;
    double? altitude;
    double? heading;
    double? hError;

    for (int i = 0; i < gpsCount; i++) {
      final entryPos = gpsIfdOffset + 2 + i * 12;
      if (entryPos + 12 > bd.lengthInBytes) break;
      final tag = bd.getUint16(entryPos, endian);
      final type = bd.getUint16(entryPos + 2, endian);
      final count = bd.getUint32(entryPos + 4, endian);

      switch (tag) {
        case 0x0001: // GPSLatitudeRef (ASCII)
          latRef = _readAsciiFirstChar(bd, entryPos, count, endian);
          break;
        case 0x0002: // GPSLatitude (3 RATIONALs)
          if (type == 5 && count >= 3) {
            latDeg = _readDmsRational(bd, bd.getUint32(entryPos + 8, endian), endian);
          }
          break;
        case 0x0003: // GPSLongitudeRef (ASCII)
          lonRef = _readAsciiFirstChar(bd, entryPos, count, endian);
          break;
        case 0x0004: // GPSLongitude (3 RATIONALs)
          if (type == 5 && count >= 3) {
            lonDeg = _readDmsRational(bd, bd.getUint32(entryPos + 8, endian), endian);
          }
          break;
        case 0x0005: // GPSAltitudeRef (BYTE: 0=above sea level, 1=below)
          altRef = bd.getUint8(entryPos + 8);
          break;
        case 0x0006: // GPSAltitude (1 RATIONAL)
          if (type == 5 && count >= 1) {
            altitude = _readRational(bd, bd.getUint32(entryPos + 8, endian), endian);
          }
          break;
        case 0x0011: // GPSImgDirection (1 RATIONAL, degrees 0..359.99)
          if (type == 5 && count >= 1) {
            final dir = _readRational(bd, bd.getUint32(entryPos + 8, endian), endian);
            if (dir != null && dir >= 0 && dir <= 360) heading = dir % 360;
          }
          break;
        case 0x001F: // GPSHPositioningError (1 RATIONAL, meters)
          if (type == 5 && count >= 1) {
            final err = _readRational(bd, bd.getUint32(entryPos + 8, endian), endian);
            if (err != null && err > 0 && err < 5000) hError = err;
          }
          break;
      }
    }

    if (latDeg == null || lonDeg == null) return null;
    if (latDeg.isNaN || lonDeg.isNaN) return null;

    var finalLat = latDeg;
    var finalLon = lonDeg;
    if (latRef?.toUpperCase() == 'S') finalLat = -finalLat.abs();
    if (lonRef?.toUpperCase() == 'W') finalLon = -finalLon.abs();

    if (finalLat.abs() > 90 || finalLon.abs() > 180) return null;
    if (finalLat.abs() < 0.0001 && finalLon.abs() < 0.0001) return null;

    final finalAlt = altitude != null ? (altRef == 1 ? -altitude : altitude) : null;

    return ExifGpsData(
      latitude: finalLat,
      longitude: finalLon,
      altitudeMeters: finalAlt,
      headingDegrees: heading,
      accuracyMeters: hError,
    );
  }

  static String? _readAsciiFirstChar(
    ByteData bd,
    int entryPos,
    int count,
    Endian endian,
  ) {
    if (count == 0) return null;
    final int charOffset =
        count <= 4 ? entryPos + 8 : bd.getUint32(entryPos + 8, endian);
    if (charOffset < 0 || charOffset >= bd.lengthInBytes) return null;
    final code = bd.getUint8(charOffset);
    if (code == 0) return null;
    return String.fromCharCode(code);
  }

  static double? _readRational(ByteData bd, int offset, Endian endian) {
    if (offset < 0 || offset + 8 > bd.lengthInBytes) return null;
    final num = bd.getUint32(offset, endian);
    final den = bd.getUint32(offset + 4, endian);
    if (den == 0) return null;
    return num / den;
  }

  static double? _readDmsRational(ByteData bd, int offset, Endian endian) {
    if (offset < 0 || offset + 24 > bd.lengthInBytes) return null;
    final d = _readRational(bd, offset, endian);
    final m = _readRational(bd, offset + 8, endian);
    final s = _readRational(bd, offset + 16, endian);
    if (d == null || m == null || s == null) return null;
    return d + (m / 60.0) + (s / 3600.0);
  }
}
