import 'dart:math' as math;

import '../models/hike_trail.dart';

enum HamRadioGpsFormat {
  nmea0183,
  aprs,
  gpx,
  kml,
  csv,
  unknown;

  String get label => switch (this) {
        HamRadioGpsFormat.nmea0183 => 'NMEA-0183 (Icom / Yaesu / Kenwood)',
        HamRadioGpsFormat.aprs => 'APRS Packet Log (TNC2 / Mic-E)',
        HamRadioGpsFormat.gpx => 'GPX Track (aprs.fi / Radio Export)',
        HamRadioGpsFormat.kml => 'KML Track',
        HamRadioGpsFormat.csv => 'CSV GPS Log (Anytone / DMR / aprs.fi)',
        HamRadioGpsFormat.unknown => 'Unknown Format',
      };

  String get shortLabel => switch (this) {
        HamRadioGpsFormat.nmea0183 => 'NMEA-0183',
        HamRadioGpsFormat.aprs => 'APRS',
        HamRadioGpsFormat.gpx => 'GPX',
        HamRadioGpsFormat.kml => 'KML',
        HamRadioGpsFormat.csv => 'CSV',
        HamRadioGpsFormat.unknown => 'Unknown',
      };
}

class ImportedGpsPoint {
  final double latitude;
  final double longitude;
  final double? altitudeMeters;
  final double? accuracyMeters;
  final DateTime recordedAt;
  final String? callsign;
  final String? comment;

  const ImportedGpsPoint({
    required this.latitude,
    required this.longitude,
    this.altitudeMeters,
    this.accuracyMeters,
    required this.recordedAt,
    this.callsign,
    this.comment,
  });

  TrailPoint toTrailPoint(String trailId) => TrailPoint(
        trailId: trailId,
        latitude: latitude,
        longitude: longitude,
        altitudeMeters: altitudeMeters,
        accuracyMeters: accuracyMeters,
        recordedAt: recordedAt,
      );
}

class ImportedGpsTrackResult {
  final HamRadioGpsFormat format;
  final String suggestedName;
  final List<ImportedGpsPoint> points;
  final List<String> callsigns;
  final int skippedEntries;
  final int removedDuplicates;
  final List<String> warnings;

  const ImportedGpsTrackResult({
    required this.format,
    required this.suggestedName,
    required this.points,
    this.callsigns = const [],
    this.skippedEntries = 0,
    this.removedDuplicates = 0,
    this.warnings = const [],
  });

  bool get isEmpty => points.isEmpty;

  double get totalDistanceMeters {
    if (points.length < 2) return 0;
    double sum = 0;
    for (var i = 1; i < points.length; i++) {
      sum += haversineMeters(
        points[i - 1].latitude,
        points[i - 1].longitude,
        points[i].latitude,
        points[i].longitude,
      );
    }
    return sum;
  }

  DateTime? get startedAt => points.isNotEmpty ? points.first.recordedAt : null;
  DateTime? get endedAt => points.isNotEmpty ? points.last.recordedAt : null;

  Duration get duration {
    if (points.length < 2) return Duration.zero;
    final diff = points.last.recordedAt.difference(points.first.recordedAt);
    return diff.isNegative ? Duration.zero : diff;
  }

  double? get minAltitudeMeters {
    double? best;
    for (final p in points) {
      if (p.altitudeMeters != null &&
          (best == null || p.altitudeMeters! < best)) {
        best = p.altitudeMeters;
      }
    }
    return best;
  }

  double? get maxAltitudeMeters {
    double? best;
    for (final p in points) {
      if (p.altitudeMeters != null &&
          (best == null || p.altitudeMeters! > best)) {
        best = p.altitudeMeters;
      }
    }
    return best;
  }

  /// Builds a temporary [HikeTrail] preview for map / vector preview widgets.
  HikeTrail toPreviewTrail({
    String trailId = 'preview-import',
    String? name,
    ActivityType activityType = ActivityType.hiking,
  }) {
    final now = DateTime.now();
    return HikeTrail(
      id: trailId,
      name: (name != null && name.trim().isNotEmpty)
          ? name.trim()
          : suggestedName,
      startedAt: startedAt ?? now,
      endedAt: endedAt ?? now,
      isActive: false,
      activityType: activityType,
      tags: activityType.defaultTags,
      points: points.map((p) => p.toTrailPoint(trailId)).toList(),
    );
  }
}

/// Pure-Dart GPS track importer tailored for external Ham radios & field
/// transceivers (Icom, Yaesu, Kenwood, Anytone, BTECH, APRSdroid, Direwolf,
/// aprs.fi, and handheld GPS units):
/// - NMEA-0183 (`$GPRMC`, `$GNRMC`, `$GPGGA`, `$GNGGA`, `$GPGLL`, `$GPWPL`)
/// - APRS TNC2 packets (Uncompressed, Base-91 Compressed, and Mic-E)
/// - GPX 1.0 / 1.1 (`<trkpt>`, `<rtept>`, `<wpt>`)
/// - KML (`<LineString>`, `<gx:Track>`, `<Point>`)
/// - CSV GPS logs (flexible header detection for Anytone / aprs.fi / OpenGD77)
class HamRadioGpsImportService {
  static const List<String> supportedExtensions = [
    '.nmea',
    '.log',
    '.txt',
    '.aprs',
    '.gpx',
    '.kml',
    '.csv',
    '.xml',
  ];

  /// Detects the GPS log format from [content] and optional [fileName].
  static HamRadioGpsFormat detectFormat(String content, {String? fileName}) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return HamRadioGpsFormat.unknown;
    final lower = trimmed.toLowerCase();
    final ext = (fileName ?? '').toLowerCase();

    if (lower.contains('<gpx') ||
        lower.contains('<trkpt') ||
        lower.contains('<rtept') ||
        ext.endsWith('.gpx')) {
      return HamRadioGpsFormat.gpx;
    }
    if (lower.contains('<kml') ||
        lower.contains('<gx:track') ||
        (lower.contains('<coordinates>') && lower.contains('<placemark')) ||
        ext.endsWith('.kml')) {
      return HamRadioGpsFormat.kml;
    }
    if (RegExp(
      r'\$G[PNLAB](RMC|GGA|GLL|WPL),',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      return HamRadioGpsFormat.nmea0183;
    }
    // APRS TNC2 packet pattern: CALLSIGN>DEST[,PATH]:INFO
    if (RegExp(
      r'''[A-Z0-9]{3,9}(?:-\d{1,2})?>[A-Z0-9-]{3,9}[^:\r\n]*:[!=/@`']''',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      return HamRadioGpsFormat.aprs;
    }
    if (ext.endsWith('.csv') || _looksLikeCsvGps(trimmed)) {
      return HamRadioGpsFormat.csv;
    }
    if (ext.endsWith('.nmea')) return HamRadioGpsFormat.nmea0183;
    if (ext.endsWith('.aprs')) return HamRadioGpsFormat.aprs;
    return HamRadioGpsFormat.unknown;
  }

  static bool _looksLikeCsvGps(String text) {
    final firstLines = text
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .take(5)
        .toList();
    if (firstLines.isEmpty) return false;
    final header = firstLines.first.toLowerCase();
    return (header.contains('lat') &&
            (header.contains('lon') || header.contains('lng'))) ||
        (firstLines.length >= 2 &&
            firstLines.first.contains(',') &&
            RegExp(r'-?\d{1,2}\.\d+,-?\d{1,3}\.\d+').hasMatch(firstLines[1]));
  }

  static const int maxImportChars = 12 * 1024 * 1024;
  static const int maxImportedPoints = 250000;

  static double? _finiteOrNull(double? v) =>
      (v != null && v.isFinite) ? v : null;

  /// Auto-detects format and parses raw GPS log [content] from an external Ham
  /// radio or GPS export into an [ImportedGpsTrackResult].
  ///
  /// - [callsignFilter]: optional station callsign filter for multi-station APRS/CSV logs.
  /// - [deduplicateClosePoints]: removes consecutive duplicate fixes < 1 meter apart.
  static ImportedGpsTrackResult parse(
    String content, {
    String? fileName,
    String? callsignFilter,
    bool deduplicateClosePoints = true,
  }) {
    if (content.length > maxImportChars) {
      return const ImportedGpsTrackResult(
        format: HamRadioGpsFormat.unknown,
        suggestedName: 'Imported Radio Track',
        points: [],
        warnings: ['GPS log exceeds the 12 MB import size limit.'],
      );
    }
    final format = detectFormat(content, fileName: fileName);
    final raw = switch (format) {
      HamRadioGpsFormat.nmea0183 => _parseNmea(content, fileName: fileName),
      HamRadioGpsFormat.aprs => _parseAprs(content, fileName: fileName),
      HamRadioGpsFormat.gpx => _parseGpx(content, fileName: fileName),
      HamRadioGpsFormat.kml => _parseKml(content, fileName: fileName),
      HamRadioGpsFormat.csv => _parseCsv(content, fileName: fileName),
      HamRadioGpsFormat.unknown => const ImportedGpsTrackResult(
          format: HamRadioGpsFormat.unknown,
          suggestedName: 'Imported Radio Track',
          points: [],
          warnings: [
            'Unrecognized GPS format. Supported: NMEA-0183 (.nmea/.log/.txt), APRS TNC2 / Mic-E, GPX, KML, and CSV.',
          ],
        ),
    };

    final warnings = List<String>.from(raw.warnings);
    var filteredPoints = raw.points
        .where((p) => p.latitude.isFinite && p.longitude.isFinite)
        .map(
          (p) => (p.altitudeMeters != null && !p.altitudeMeters!.isFinite) ||
                  (p.accuracyMeters != null && !p.accuracyMeters!.isFinite)
              ? ImportedGpsPoint(
                  latitude: p.latitude,
                  longitude: p.longitude,
                  altitudeMeters: _finiteOrNull(p.altitudeMeters),
                  accuracyMeters: _finiteOrNull(p.accuracyMeters),
                  recordedAt: p.recordedAt,
                  callsign: p.callsign,
                  comment: p.comment,
                )
              : p,
        )
        .toList();
    if (filteredPoints.length > maxImportedPoints) {
      filteredPoints = filteredPoints.sublist(0, maxImportedPoints);
      warnings.add(
        'Track truncated to $maxImportedPoints points to protect device memory.',
      );
    }
    final normalizedCall = callsignFilter?.trim().toUpperCase();
    if (normalizedCall != null && normalizedCall.isNotEmpty) {
      filteredPoints = filteredPoints
          .where((p) => (p.callsign ?? '').toUpperCase() == normalizedCall)
          .toList();
    }

    int removedDup = 0;
    if (deduplicateClosePoints && filteredPoints.length > 1) {
      final deduped = <ImportedGpsPoint>[filteredPoints.first];
      for (var i = 1; i < filteredPoints.length; i++) {
        final prev = deduped.last;
        final cur = filteredPoints[i];
        final dist = haversineMeters(
          prev.latitude,
          prev.longitude,
          cur.latitude,
          cur.longitude,
        );
        if (dist < 1.0 &&
            (cur.altitudeMeters == null ||
                prev.altitudeMeters == cur.altitudeMeters)) {
          removedDup++;
          continue;
        }
        deduped.add(cur);
      }
      filteredPoints = deduped;
    }

    if (filteredPoints.length >= 2) {
      int jumpCount = 0;
      for (var i = 1; i < filteredPoints.length; i++) {
        final dist = haversineMeters(
          filteredPoints[i - 1].latitude,
          filteredPoints[i - 1].longitude,
          filteredPoints[i].latitude,
          filteredPoints[i].longitude,
        );
        if (dist > 500.0) jumpCount++;
      }
      if (jumpCount > 0) {
        warnings.add(
          'Detected $jumpCount large GPS jump${jumpCount == 1 ? '' : 's'} (>500m) — you can clean individual points after importing.',
        );
      }
    }

    var suggestedName = raw.suggestedName;
    if (normalizedCall != null &&
        normalizedCall.isNotEmpty &&
        !suggestedName.toUpperCase().contains(normalizedCall)) {
      suggestedName = '$suggestedName ($normalizedCall)';
    }

    return ImportedGpsTrackResult(
      format: raw.format,
      suggestedName: suggestedName,
      points: filteredPoints,
      callsigns: raw.callsigns,
      skippedEntries: raw.skippedEntries,
      removedDuplicates: removedDup,
      warnings: warnings,
    );
  }

  static bool _isValidCoordinate(double lat, double lon) {
    if (!lat.isFinite || !lon.isFinite) return false;
    if (lat.abs() > 90.0 || lon.abs() > 180.0) return false;
    if (lat.abs() < 0.0001 && lon.abs() < 0.0001) return false; // Null Island
    return true;
  }

  static String _stemName(String? fileName, String fallback) {
    if (fileName == null || fileName.trim().isEmpty) return fallback;
    final base = fileName.trim().split(RegExp(r'[/\\]')).last;
    final dot = base.lastIndexOf('.');
    final stem = (dot > 0 ? base.substring(0, dot) : base)
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .trim();
    return stem.isEmpty ? fallback : stem;
  }

  // ---------------------------------------------------------------------------
  // 1. NMEA-0183 Parser (Icom ID-51/52/IC-705, Yaesu FT5DR/FT3DR, Kenwood TH-D74/D75)
  // ---------------------------------------------------------------------------

  static bool verifyNmeaChecksum(String sentence) {
    final starIdx = sentence.lastIndexOf('*');
    if (starIdx < 0) return true; // Checksum optional in some loggers
    final dollarIdx = sentence.indexOf(r'$');
    if (dollarIdx < 0 || starIdx <= dollarIdx + 1) return false;
    final expectedHex = sentence
        .substring(starIdx + 1)
        .trim()
        .replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    if (expectedHex.length < 2) return false;
    int xorSum = 0;
    for (var i = dollarIdx + 1; i < starIdx; i++) {
      xorSum ^= sentence.codeUnitAt(i);
    }
    final actualHex = xorSum.toRadixString(16).toUpperCase().padLeft(2, '0');
    return actualHex == expectedHex.substring(0, 2).toUpperCase();
  }

  static double? _parseNmeaCoord(String raw, String hemi) {
    final s = raw.trim();
    final dot = s.indexOf('.');
    if (dot < 3) return null;
    final degStr = s.substring(0, dot - 2);
    final minStr = s.substring(dot - 2);
    final deg = int.tryParse(degStr);
    final min = double.tryParse(minStr);
    if (deg == null || min == null) return null;
    var val = deg + (min / 60.0);
    final h = hemi.trim().toUpperCase();
    if (h == 'S' || h == 'W') val = -val;
    return val;
  }

  static DateTime _buildNmeaUtcTime(String hhmmss, DateTime dateBase) {
    final clean = hhmmss.trim();
    if (clean.length < 6) return dateBase;
    final h = int.tryParse(clean.substring(0, 2)) ?? 0;
    final m = int.tryParse(clean.substring(2, 4)) ?? 0;
    final s = int.tryParse(clean.substring(4, 6)) ?? 0;
    int ms = 0;
    final dot = clean.indexOf('.');
    if (dot >= 0 && dot + 1 < clean.length) {
      final frac = clean.substring(dot + 1).padRight(3, '0').substring(0, 3);
      ms = int.tryParse(frac) ?? 0;
    }
    return DateTime.utc(dateBase.year, dateBase.month, dateBase.day, h, m, s, ms);
  }

  static DateTime? _parseNmeaDate(String ddmmyy) {
    final clean = ddmmyy.trim();
    if (clean.length != 6) return null;
    final day = int.tryParse(clean.substring(0, 2));
    final month = int.tryParse(clean.substring(2, 4));
    final yy = int.tryParse(clean.substring(4, 6));
    if (day == null || month == null || yy == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final year = yy >= 80 ? 1900 + yy : 2000 + yy;
    return DateTime.utc(year, month, day);
  }

  static ImportedGpsTrackResult _parseNmea(String content, {String? fileName}) {
    final lines = content.split(RegExp(r'\r?\n'));
    final points = <ImportedGpsPoint>[];
    int skipped = 0;
    DateTime currentDate = DateTime.now().toUtc();
    String? lastTimeKey;

    for (final rawLine in lines) {
      final dollar = rawLine.indexOf(r'$');
      if (dollar < 0) continue;
      final line = rawLine.substring(dollar).trim();
      if (!verifyNmeaChecksum(line)) {
        skipped++;
        continue;
      }
      final body = line.contains('*')
          ? line.substring(0, line.lastIndexOf('*'))
          : line;
      final fields = body.split(',');
      if (fields.length < 6) continue;
      final sentenceType = fields[0].toUpperCase();

      if (sentenceType.endsWith('RMC') && fields.length >= 10) {
        final status = fields[2].trim().toUpperCase();
        if (status != 'A') {
          skipped++;
          continue;
        }
        final lat = _parseNmeaCoord(fields[3], fields[4]);
        final lon = _parseNmeaCoord(fields[5], fields[6]);
        if (lat == null || lon == null || !_isValidCoordinate(lat, lon)) {
          skipped++;
          continue;
        }
        final parsedDate = _parseNmeaDate(fields[9]);
        if (parsedDate != null) currentDate = parsedDate;
        final timeStr = fields[1].trim();
        final ts = _buildNmeaUtcTime(timeStr, currentDate);
        final timeKey = timeStr.length >= 6 ? timeStr.substring(0, 6) : null;

        // If GGA for the same second just arrived, enrich it with RMC's exact date
        if (timeKey != null &&
            timeKey == lastTimeKey &&
            points.isNotEmpty) {
          final prev = points.last;
          points[points.length - 1] = ImportedGpsPoint(
            latitude: prev.latitude,
            longitude: prev.longitude,
            altitudeMeters: prev.altitudeMeters,
            accuracyMeters: prev.accuracyMeters,
            recordedAt: ts,
          );
        } else {
          points.add(
            ImportedGpsPoint(
              latitude: lat,
              longitude: lon,
              recordedAt: ts,
            ),
          );
          lastTimeKey = timeKey;
        }
      } else if (sentenceType.endsWith('GGA') && fields.length >= 10) {
        final fixQuality = int.tryParse(fields[6].trim()) ?? 0;
        if (fixQuality <= 0) {
          skipped++;
          continue;
        }
        final lat = _parseNmeaCoord(fields[2], fields[3]);
        final lon = _parseNmeaCoord(fields[4], fields[5]);
        if (lat == null || lon == null || !_isValidCoordinate(lat, lon)) {
          skipped++;
          continue;
        }
        final hdop = double.tryParse(fields[8].trim());
        final accuracy =
            hdop != null && hdop > 0 ? (hdop * 5.0).clamp(2.0, 100.0) : null;
        double? alt = double.tryParse(fields[9].trim());
        if (alt != null &&
            fields.length > 10 &&
            fields[10].trim().toUpperCase() == 'F') {
          alt *= 0.3048;
        }
        final timeStr = fields[1].trim();
        final ts = _buildNmeaUtcTime(timeStr, currentDate);
        final timeKey = timeStr.length >= 6 ? timeStr.substring(0, 6) : null;

        // Merge altitude & HDOP onto the matching RMC point from the same second
        if (timeKey != null &&
            timeKey == lastTimeKey &&
            points.isNotEmpty) {
          final prev = points.last;
          points[points.length - 1] = ImportedGpsPoint(
            latitude: lat,
            longitude: lon,
            altitudeMeters: alt ?? prev.altitudeMeters,
            accuracyMeters: accuracy ?? prev.accuracyMeters,
            recordedAt: prev.recordedAt,
          );
        } else {
          points.add(
            ImportedGpsPoint(
              latitude: lat,
              longitude: lon,
              altitudeMeters: alt,
              accuracyMeters: accuracy,
              recordedAt: ts,
            ),
          );
          lastTimeKey = timeKey;
        }
      } else if (sentenceType.endsWith('GLL') && fields.length >= 7) {
        final status = fields[6].trim().toUpperCase();
        if (status != 'A') {
          skipped++;
          continue;
        }
        final lat = _parseNmeaCoord(fields[1], fields[2]);
        final lon = _parseNmeaCoord(fields[3], fields[4]);
        if (lat == null || lon == null || !_isValidCoordinate(lat, lon)) {
          skipped++;
          continue;
        }
        final timeStr = fields[5].trim();
        final timeKey = timeStr.length >= 6 ? timeStr.substring(0, 6) : null;
        if (timeKey != null && timeKey == lastTimeKey) continue;
        points.add(
          ImportedGpsPoint(
            latitude: lat,
            longitude: lon,
            recordedAt: _buildNmeaUtcTime(timeStr, currentDate),
          ),
        );
        lastTimeKey = timeKey;
      } else if (sentenceType.endsWith('WPL') && fields.length >= 5) {
        final lat = _parseNmeaCoord(fields[1], fields[2]);
        final lon = _parseNmeaCoord(fields[3], fields[4]);
        if (lat == null || lon == null || !_isValidCoordinate(lat, lon)) {
          skipped++;
          continue;
        }
        final wptName = fields.length >= 6 ? fields[5].trim() : null;
        points.add(
          ImportedGpsPoint(
            latitude: lat,
            longitude: lon,
            recordedAt: currentDate.add(Duration(seconds: points.length)),
            comment: wptName,
          ),
        );
      }
    }

    return ImportedGpsTrackResult(
      format: HamRadioGpsFormat.nmea0183,
      suggestedName: _stemName(fileName, 'Ham Radio NMEA Track'),
      points: points,
      skippedEntries: skipped,
    );
  }

  // ---------------------------------------------------------------------------
  // 2. APRS TNC2 Packet Parser (Uncompressed, Base-91 Compressed, & Mic-E)
  // ---------------------------------------------------------------------------

  static DateTime? _extractLinePrefixTimestamp(String line) {
    // ISO 8601 prefix e.g. 2026-11-23T09:15:00Z or 2026-11-23 09:15:00
    final isoMatch = RegExp(
      r'(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)',
    ).firstMatch(line);
    if (isoMatch != null) {
      final raw = isoMatch.group(1)!.replaceFirst(' ', 'T');
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed.toUtc();
    }
    return null;
  }

  static DateTime? _parseAprsInlineTimestamp(String ts7, DateTime refUtc) {
    if (ts7.length != 7) return null;
    final suffix = ts7[6];
    final a = int.tryParse(ts7.substring(0, 2));
    final b = int.tryParse(ts7.substring(2, 4));
    final c = int.tryParse(ts7.substring(4, 6));
    if (a == null || b == null || c == null) return null;
    if (suffix == 'z' || suffix == '/') {
      // DDHHMMz (day, hour, minute UTC)
      return DateTime.utc(refUtc.year, refUtc.month, a.clamp(1, 31), b % 24, c % 60);
    }
    if (suffix == 'h') {
      // HHMMSSh (hour, minute, second UTC)
      return DateTime.utc(
        refUtc.year,
        refUtc.month,
        refUtc.day,
        a % 24,
        b % 60,
        c % 60,
      );
    }
    return null;
  }

  static double? _parseAprsAltitudeFeetToMeters(String text) {
    final m = RegExp(r'/A=(-?\d{6})').firstMatch(text);
    if (m == null) return null;
    final feet = int.tryParse(m.group(1)!);
    if (feet == null) return null;
    return feet * 0.3048;
  }

  /// Decodes APRS 1.01 Mic-E position packet (Yaesu FT5DR/FT3DR, Kenwood TH-D74/D75,
  /// Anytone AT-D878UV).
  static ({double lat, double lon, double? altMeters})? _decodeMicE(
    String destCall,
    String info,
  ) {
    // Strip optional SSID from destination callsign
    final cleanDest = destCall.split('-').first.trim().toUpperCase();
    if (cleanDest.length != 6 || info.length < 9) return null;

    final digits = <int>[];
    for (var i = 0; i < 6; i++) {
      final code = cleanDest.codeUnitAt(i);
      if (code >= 48 && code <= 57) {
        digits.add(code - 48); // '0'..'9'
      } else if (code >= 65 && code <= 74) {
        digits.add(code - 65); // 'A'..'J'
      } else if (code >= 80 && code <= 89) {
        digits.add(code - 80); // 'P'..'Y'
      } else if (code == 75 || code == 76 || code == 90) {
        digits.add(0); // 'K', 'L', 'Z' -> ambiguity space
      } else {
        return null;
      }
    }

    final c3 = cleanDest.codeUnitAt(3);
    final c4 = cleanDest.codeUnitAt(4);
    final c5 = cleanDest.codeUnitAt(5);
    final isNorth = c3 >= 80 && c3 <= 90; // 'P'..'Z'
    final lonOffset = (c4 >= 80 && c4 <= 90) ? 100 : 0;
    final isWest = c5 >= 80 && c5 <= 90; // 'P'..'Z'

    final latDeg = digits[0] * 10 + digits[1];
    final latMin = digits[2] * 10 + digits[3] + (digits[4] * 10 + digits[5]) / 100.0;
    var lat = latDeg + latMin / 60.0;
    if (!isNorth) lat = -lat;

    // Information field bytes 1, 2, 3 encode longitude (after '`' or '\'')
    int d = info.codeUnitAt(1) - 28 + lonOffset;
    if (d >= 180 && d <= 189) {
      d -= 80;
    } else if (d >= 190 && d <= 199) {
      d -= 190;
    }
    int m = info.codeUnitAt(2) - 28;
    if (m >= 60) m -= 60;
    final h = info.codeUnitAt(3) - 28;
    if (d < 0 || d > 180 || m < 0 || m >= 60 || h < 0 || h >= 100) return null;

    var lon = d + (m + h / 100.0) / 60.0;
    if (isWest) lon = -lon;

    // Optional base-91 Mic-E altitude (`xxx}` anywhere in comment starting at index 9)
    double? altMeters;
    if (info.length > 9) {
      final tail = info.substring(9);
      final closeIdx = tail.indexOf('}');
      if (closeIdx >= 3) {
        final a = tail.codeUnitAt(closeIdx - 3) - 33;
        final b = tail.codeUnitAt(closeIdx - 2) - 33;
        final c = tail.codeUnitAt(closeIdx - 1) - 33;
        if (a >= 0 && a < 91 && b >= 0 && b < 91 && c >= 0 && c < 91) {
          altMeters = (a * 8281 + b * 91 + c - 10000).toDouble();
        }
      }
    }

    if (!_isValidCoordinate(lat, lon)) return null;
    return (lat: lat, lon: lon, altMeters: altMeters);
  }

  /// Decodes APRS Base-91 Compressed Position (`/` + YYYY + XXXX + sym + csT).
  static ({double lat, double lon, double? altMeters})? _decodeCompressedAprs(
    String payload,
  ) {
    if (payload.length < 13) return null;
    final table = payload[0];
    if (table != '/' &&
        table != r'\' &&
        !RegExp(r'[A-Za-j0-9]').hasMatch(table)) {
      return null;
    }
    int decodeBase91(String s) {
      int v = 0;
      for (var i = 0; i < 4; i++) {
        final c = s.codeUnitAt(i) - 33;
        if (c < 0 || c >= 91) return -1;
        v = v * 91 + c;
      }
      return v;
    }

    final y = decodeBase91(payload.substring(1, 5));
    final x = decodeBase91(payload.substring(5, 9));
    if (y < 0 || x < 0) return null;
    final lat = 90.0 - y / 380926.0;
    final lon = -180.0 + x / 190463.0;
    if (!_isValidCoordinate(lat, lon)) return null;

    double? altMeters;
    final cChar = payload.codeUnitAt(10);
    final sChar = payload.codeUnitAt(11);
    final tChar = payload.codeUnitAt(12);
    if (cChar >= 33 && cChar <= 123 && sChar >= 33 && sChar <= 123 && tChar >= 33) {
      final tBits = tChar - 33;
      if ((tBits & 0x18) == 0x10) {
        final exp = (cChar - 33) * 91 + (sChar - 33);
        if (exp >= 0 && exp <= 50000) {
          final computed = math.pow(1.002, exp).toDouble() * 0.3048;
          if (computed.isFinite && computed >= -500 && computed <= 100000) {
            altMeters = computed;
          }
        }
      }
    }

    return (lat: lat, lon: lon, altMeters: altMeters);
  }

  static ImportedGpsTrackResult _parseAprs(String content, {String? fileName}) {
    final lines = content.split(RegExp(r'\r?\n'));
    final points = <ImportedGpsPoint>[];
    final callsigns = <String>{};
    int skipped = 0;
    final baseNow = DateTime.now().toUtc();

    final packetRegex = RegExp(
      r'([A-Z0-9]{3,9}(?:-\d{1,2})?)>([A-Z0-9-]{3,9})[^:\r\n]*:(.*)$',
      caseSensitive: false,
    );
    final uncompressedPosRegex = RegExp(
      r'^(\d{4}\.\d{2})([NS]).(\d{5}\.\d{2})([EW])',
      caseSensitive: false,
    );

    for (final rawLine in lines) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final m = packetRegex.firstMatch(trimmed);
      if (m == null) continue;

      final callsign = m.group(1)!.toUpperCase();
      final dest = m.group(2)!.toUpperCase();
      final info = m.group(3)!;
      if (info.isEmpty) continue;

      final prefixTs = _extractLinePrefixTimestamp(trimmed);
      DateTime ts = prefixTs ?? baseNow.add(Duration(seconds: points.length * 30));

      final dti = info[0];
      double? lat;
      double? lon;
      double? alt;

      if (dti == '`' || dti == "'") {
        // Mic-E packet
        final decoded = _decodeMicE(dest, info);
        if (decoded == null) {
          skipped++;
          continue;
        }
        lat = decoded.lat;
        lon = decoded.lon;
        alt = decoded.altMeters;
      } else if (dti == '!' || dti == '=' || dti == '/' || dti == '@') {
        var payload = info.substring(1);
        if ((dti == '/' || dti == '@') && payload.length >= 7) {
          final inlineTs =
              _parseAprsInlineTimestamp(payload.substring(0, 7), prefixTs ?? baseNow);
          if (inlineTs != null && prefixTs == null) {
            ts = inlineTs;
          }
          payload = payload.substring(7);
        }

        final posMatch = uncompressedPosRegex.firstMatch(payload);
        if (posMatch != null) {
          lat = _parseNmeaCoord(posMatch.group(1)!, posMatch.group(2)!);
          lon = _parseNmeaCoord(posMatch.group(3)!, posMatch.group(4)!);
          alt = _parseAprsAltitudeFeetToMeters(payload);
        } else {
          final comp = _decodeCompressedAprs(payload);
          if (comp != null) {
            lat = comp.lat;
            lon = comp.lon;
            alt = comp.altMeters ?? _parseAprsAltitudeFeetToMeters(payload);
          }
        }
      } else {
        continue;
      }

      if (lat == null || lon == null || !_isValidCoordinate(lat, lon)) {
        skipped++;
        continue;
      }

      callsigns.add(callsign);
      points.add(
        ImportedGpsPoint(
          latitude: lat,
          longitude: lon,
          altitudeMeters: alt,
          recordedAt: ts,
          callsign: callsign,
        ),
      );
    }

    final sortedCalls = callsigns.toList()..sort();
    final defaultName = sortedCalls.length == 1
        ? 'APRS Track (${sortedCalls.first})'
        : _stemName(fileName, 'APRS Ham Radio Track');

    return ImportedGpsTrackResult(
      format: HamRadioGpsFormat.aprs,
      suggestedName: defaultName,
      points: points,
      callsigns: sortedCalls,
      skippedEntries: skipped,
    );
  }

  // ---------------------------------------------------------------------------
  // 3. GPX 1.0 / 1.1 Parser
  // ---------------------------------------------------------------------------

  static ImportedGpsTrackResult _parseGpx(String content, {String? fileName}) {
    final points = <ImportedGpsPoint>[];
    int skipped = 0;

    final nameMatch = RegExp(
      r'<trk>[\s\S]*?<name>(?:<!\[CDATA\[)?([^<\]]+)(?:\]\]>)?</name>',
      caseSensitive: false,
    ).firstMatch(content);
    final trackName = nameMatch?.group(1)?.trim();

    final ptRegex = RegExp(
      r'<(trkpt|rtept|wpt)\b([^>]*)>([\s\S]*?)</\1>|<(trkpt|rtept|wpt)\b([^>]*)/>',
      caseSensitive: false,
    );
    final latAttr = RegExp(r'''lat\s*=\s*["']([^"']+)["']''', caseSensitive: false);
    final lonAttr = RegExp(r'''lon\s*=\s*["']([^"']+)["']''', caseSensitive: false);
    final eleTag = RegExp(r'<ele>\s*([^<]+?)\s*</ele>', caseSensitive: false);
    final timeTag = RegExp(r'<time>\s*([^<]+?)\s*</time>', caseSensitive: false);
    final hdopTag = RegExp(r'<hdop>\s*([^<]+?)\s*</hdop>', caseSensitive: false);

    final fallbackNow = DateTime.now().toUtc();
    for (final m in ptRegex.allMatches(content)) {
      final attrs = (m.group(2) ?? m.group(5) ?? '');
      final inner = m.group(3) ?? '';
      final lat = double.tryParse(latAttr.firstMatch(attrs)?.group(1) ?? '');
      final lon = double.tryParse(lonAttr.firstMatch(attrs)?.group(1) ?? '');
      if (lat == null || lon == null || !_isValidCoordinate(lat, lon)) {
        skipped++;
        continue;
      }
      final ele = double.tryParse(eleTag.firstMatch(inner)?.group(1) ?? '');
      final hdop = double.tryParse(hdopTag.firstMatch(inner)?.group(1) ?? '');
      final accuracy =
          hdop != null && hdop > 0 ? (hdop * 5.0).clamp(2.0, 100.0) : null;
      final ts = DateTime.tryParse(timeTag.firstMatch(inner)?.group(1) ?? '')
              ?.toUtc() ??
          fallbackNow.add(Duration(seconds: points.length));
      points.add(
        ImportedGpsPoint(
          latitude: lat,
          longitude: lon,
          altitudeMeters: ele,
          accuracyMeters: accuracy,
          recordedAt: ts,
        ),
      );
    }

    return ImportedGpsTrackResult(
      format: HamRadioGpsFormat.gpx,
      suggestedName: (trackName != null && trackName.isNotEmpty)
          ? trackName
          : _stemName(fileName, 'Imported GPX Route'),
      points: points,
      skippedEntries: skipped,
    );
  }

  // ---------------------------------------------------------------------------
  // 4. KML Parser (<LineString>, <gx:Track>, <Point>)
  // ---------------------------------------------------------------------------

  static ImportedGpsTrackResult _parseKml(String content, {String? fileName}) {
    final points = <ImportedGpsPoint>[];
    int skipped = 0;
    final fallbackNow = DateTime.now().toUtc();

    final nameMatch = RegExp(
      r'<name>(?:<!\[CDATA\[)?([^<\]]+)(?:\]\]>)?</name>',
      caseSensitive: false,
    ).firstMatch(content);
    final trackName = nameMatch?.group(1)?.trim();

    // 4a. <gx:Track> with paired <when> + <gx:coord>lon lat alt</gx:coord>
    final gxTracks = RegExp(
      r'<gx:Track\b[^>]*>([\s\S]*?)</gx:Track>',
      caseSensitive: false,
    ).allMatches(content);
    for (final trk in gxTracks) {
      final body = trk.group(1) ?? '';
      final whens = RegExp(r'<when>\s*([^<]+?)\s*</when>', caseSensitive: false)
          .allMatches(body)
          .map((m) => DateTime.tryParse(m.group(1)!.trim())?.toUtc())
          .toList();
      final coords = RegExp(
        r'<gx:coord>\s*([^<]+?)\s*</gx:coord>',
        caseSensitive: false,
      ).allMatches(body).toList();
      for (var i = 0; i < coords.length; i++) {
        final parts = coords[i].group(1)!.trim().split(RegExp(r'\s+'));
        if (parts.length < 2) {
          skipped++;
          continue;
        }
        final lon = double.tryParse(parts[0]);
        final lat = double.tryParse(parts[1]);
        final alt = parts.length >= 3 ? double.tryParse(parts[2]) : null;
        if (lat == null || lon == null || !_isValidCoordinate(lat, lon)) {
          skipped++;
          continue;
        }
        final ts = (i < whens.length ? whens[i] : null) ??
            fallbackNow.add(Duration(seconds: points.length));
        points.add(
          ImportedGpsPoint(
            latitude: lat,
            longitude: lon,
            altitudeMeters: alt,
            recordedAt: ts,
          ),
        );
      }
    }

    // 4b. Standard KML <coordinates>lon,lat[,alt] ...</coordinates>
    if (points.isEmpty) {
      final coordBlocks = RegExp(
        r'<coordinates>\s*([\s\S]*?)\s*</coordinates>',
        caseSensitive: false,
      ).allMatches(content);
      for (final block in coordBlocks) {
        final tuples = block.group(1)!.trim().split(RegExp(r'\s+'));
        for (final tuple in tuples) {
          if (tuple.trim().isEmpty) continue;
          final parts = tuple.split(',');
          if (parts.length < 2) {
            skipped++;
            continue;
          }
          final lon = double.tryParse(parts[0].trim());
          final lat = double.tryParse(parts[1].trim());
          final alt =
              parts.length >= 3 ? double.tryParse(parts[2].trim()) : null;
          if (lat == null || lon == null || !_isValidCoordinate(lat, lon)) {
            skipped++;
            continue;
          }
          points.add(
            ImportedGpsPoint(
              latitude: lat,
              longitude: lon,
              altitudeMeters: alt,
              recordedAt: fallbackNow.add(Duration(seconds: points.length)),
            ),
          );
        }
      }
    }

    return ImportedGpsTrackResult(
      format: HamRadioGpsFormat.kml,
      suggestedName: (trackName != null && trackName.isNotEmpty)
          ? trackName
          : _stemName(fileName, 'Imported KML Route'),
      points: points,
      skippedEntries: skipped,
    );
  }

  // ---------------------------------------------------------------------------
  // 5. CSV GPS Log Parser (Anytone AT-D878UV, BTECH, aprs.fi CSV, OpenGD77)
  // ---------------------------------------------------------------------------

  static List<String> _splitCsvLine(String line, String delim) {
    final result = <String>[];
    final buf = StringBuffer();
    bool inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
      } else if (ch == delim && !inQuotes) {
        result.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    result.add(buf.toString().trim());
    return result;
  }

  static ImportedGpsTrackResult _parseCsv(String content, {String? fileName}) {
    final lines = content
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
    if (lines.isEmpty) {
      return ImportedGpsTrackResult(
        format: HamRadioGpsFormat.csv,
        suggestedName: _stemName(fileName, 'Imported CSV Route'),
        points: const [],
      );
    }

    final firstLine = lines.first;
    final delim = firstLine.contains('\t')
        ? '\t'
        : (firstLine.contains(';') && !firstLine.contains(',') ? ';' : ',');
    final firstCols =
        _splitCsvLine(firstLine, delim).map((c) => c.toLowerCase()).toList();

    int latCol = -1;
    int lonCol = -1;
    int altCol = -1;
    int timeCol = -1;
    int dateCol = -1;
    int hdopCol = -1;
    int callCol = -1;

    bool hasHeader = false;
    for (var i = 0; i < firstCols.length; i++) {
      final h = firstCols[i];
      if (h == 'lat' || h == 'latitude' || h.contains('lat')) {
        latCol = i;
        hasHeader = true;
      } else if (h == 'lon' ||
          h == 'lng' ||
          h == 'long' ||
          h == 'longitude' ||
          h.contains('lon')) {
        lonCol = i;
        hasHeader = true;
      } else if (h.contains('alt') || h == 'ele' || h.contains('elevation')) {
        altCol = i;
      } else if (h == 'date') {
        dateCol = i;
      } else if (h.contains('time') || h == 'utc' || h == 'datetime') {
        timeCol = i;
      } else if (h.contains('hdop') || h.contains('acc')) {
        hdopCol = i;
      } else if (h.contains('call') || h == 'station' || h == 'src' || h == 'name') {
        callCol = i;
      }
    }

    if (!hasHeader && firstCols.length >= 2) {
      // Headerless lat,lon[,alt[,time]] fallback
      latCol = 0;
      lonCol = 1;
      if (firstCols.length >= 3) altCol = 2;
      if (firstCols.length >= 4) timeCol = 3;
    }

    final points = <ImportedGpsPoint>[];
    final callsigns = <String>{};
    int skipped = 0;
    final fallbackNow = DateTime.now().toUtc();

    for (var rowIdx = hasHeader ? 1 : 0; rowIdx < lines.length; rowIdx++) {
      final cols = _splitCsvLine(lines[rowIdx], delim);
      if (latCol < 0 ||
          lonCol < 0 ||
          latCol >= cols.length ||
          lonCol >= cols.length) {
        skipped++;
        continue;
      }
      final lat = double.tryParse(cols[latCol]);
      final lon = double.tryParse(cols[lonCol]);
      if (lat == null || lon == null || !_isValidCoordinate(lat, lon)) {
        skipped++;
        continue;
      }
      final alt = (altCol >= 0 && altCol < cols.length)
          ? _finiteOrNull(double.tryParse(cols[altCol]))
          : null;
      final acc = (hdopCol >= 0 && hdopCol < cols.length)
          ? _finiteOrNull(double.tryParse(cols[hdopCol]))
          : null;

      DateTime? ts;
      if (timeCol >= 0 && timeCol < cols.length) {
        final rawTime = cols[timeCol];
        final combined = (dateCol >= 0 &&
                dateCol < cols.length &&
                !rawTime.contains('-'))
            ? '${cols[dateCol]}T$rawTime'
            : rawTime.replaceFirst(' ', 'T');
        final epoch = int.tryParse(rawTime);
        if (epoch != null && epoch > 1000000000) {
          ts = DateTime.fromMillisecondsSinceEpoch(
            epoch > 100000000000 ? epoch : epoch * 1000,
            isUtc: true,
          );
        } else {
          ts = DateTime.tryParse(combined)?.toUtc();
        }
      }

      String? call;
      if (callCol >= 0 && callCol < cols.length && cols[callCol].isNotEmpty) {
        call = cols[callCol].toUpperCase();
        callsigns.add(call);
      }

      points.add(
        ImportedGpsPoint(
          latitude: lat,
          longitude: lon,
          altitudeMeters: alt,
          accuracyMeters: acc,
          recordedAt: ts ?? fallbackNow.add(Duration(seconds: points.length)),
          callsign: call,
        ),
      );
    }

    final sortedCalls = callsigns.toList()..sort();
    return ImportedGpsTrackResult(
      format: HamRadioGpsFormat.csv,
      suggestedName: _stemName(fileName, 'Ham Radio CSV Track'),
      points: points,
      callsigns: sortedCalls,
      skippedEntries: skipped,
    );
  }
}
