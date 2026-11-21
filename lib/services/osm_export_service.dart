import 'dart:convert';

import '../data/osm_tag_standards.dart';
import '../models/hike_trail.dart';
import '../models/osm_record.dart';
import 'app_env_config.dart';
import 'export_share.dart';

/// Serializes Edge Mapper records and hiking tracks into OpenStreetMap XML (.osm),
/// GPX 1.1 (.gpx), and GeoJSON (.geojson) for JOSM, Vespucci, or OSM upload.
class OsmExportService {
  static String buildOsmXml({
    List<OsmRecord> records = const [],
    List<HikeTrail> trails = const [],
  }) {
    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln('<osm version="0.6" generator="${_xmlEscape(AppEnvConfig.osmGenerator)}">');

    var nextNodeId = -1;
    var nextWayId = -1;

    for (final record in records) {
      final nodeId = nextNodeId--;
      final hasGps = OsmTagStandards.hasValidGps(
        record.effectiveLatitude,
        record.effectiveLongitude,
      );
      final publishableTags = OsmTagStandards.filterPublishableTags(
        record.tags,
        hasGpsFix: hasGps,
      );
      publishableTags.putIfAbsent(
        'source',
        () => OsmTagStandards.recommendedSource(hasGpsFix: hasGps),
      );
      buf.writeln(
        '  <node id="$nodeId" action="modify" visible="true" '
        'lat="${record.effectiveLatitude.toStringAsFixed(7)}" '
        'lon="${record.effectiveLongitude.toStringAsFixed(7)}">',
      );
      for (final entry in publishableTags.entries) {
        buf.writeln(
          '    <tag k="${_xmlEscape(entry.key)}" v="${_xmlEscape(entry.value)}" />',
        );
      }
      buf.writeln('  </node>');
    }

    for (final trail in trails) {
      if (trail.points.length < 2) continue;
      final wayNodeIds = <int>[];
      for (final pt in trail.points) {
        final nid = nextNodeId--;
        wayNodeIds.add(nid);
        buf.writeln(
          '  <node id="$nid" action="modify" visible="true" '
          'lat="${pt.latitude.toStringAsFixed(7)}" '
          'lon="${pt.longitude.toStringAsFixed(7)}" />',
        );
      }
      final wid = nextWayId--;
      final wayTags = OsmTagStandards.filterPublishableTags(
        trail.tags,
        hasGpsFix: true,
      );
      wayTags.putIfAbsent(
        'source',
        () => OsmTagStandards.recommendedSource(hasGpsFix: true),
      );
      buf.writeln('  <way id="$wid" action="modify" visible="true">');
      for (final nid in wayNodeIds) {
        buf.writeln('    <nd ref="$nid" />');
      }
      if (trail.name.trim().isNotEmpty && !wayTags.containsKey('name')) {
        buf.writeln('    <tag k="name" v="${_xmlEscape(trail.name.trim())}" />');
      }
      for (final entry in wayTags.entries) {
        buf.writeln(
          '    <tag k="${_xmlEscape(entry.key)}" v="${_xmlEscape(entry.value)}" />',
        );
      }
      buf.writeln('  </way>');
    }

    buf.writeln('</osm>');
    return buf.toString();
  }

  static String buildGpx({
    List<OsmRecord> records = const [],
    List<HikeTrail> trails = const [],
  }) {
    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln(
      '<gpx version="1.1" creator="${_xmlEscape(AppEnvConfig.osmGenerator)}" '
      'xmlns="http://www.topografix.com/GPX/1/1">',
    );

    for (final record in records) {
      buf.writeln(
        '  <wpt lat="${record.effectiveLatitude.toStringAsFixed(7)}" '
        'lon="${record.effectiveLongitude.toStringAsFixed(7)}">',
      );
      if (record.altitudeMeters != null) {
        buf.writeln('    <ele>${record.altitudeMeters!.toStringAsFixed(1)}</ele>');
      }
      buf.writeln('    <time>${record.createdAt.toUtc().toIso8601String()}</time>');
      buf.writeln('    <name>${_xmlEscape(record.displayName)}</name>');
      final tagSummary =
          record.tags.entries.map((e) => '${e.key}=${e.value}').join('; ');
      buf.writeln('    <desc>${_xmlEscape(tagSummary)}</desc>');
      buf.writeln('  </wpt>');
    }

    for (final trail in trails) {
      if (trail.points.isEmpty) continue;
      buf.writeln('  <trk>');
      buf.writeln('    <name>${_xmlEscape(trail.name)}</name>');
      buf.writeln('    <trkseg>');
      for (final pt in trail.points) {
        buf.writeln(
          '      <trkpt lat="${pt.latitude.toStringAsFixed(7)}" '
          'lon="${pt.longitude.toStringAsFixed(7)}">',
        );
        if (pt.altitudeMeters != null) {
          buf.writeln('        <ele>${pt.altitudeMeters!.toStringAsFixed(1)}</ele>');
        }
        buf.writeln('        <time>${pt.recordedAt.toUtc().toIso8601String()}</time>');
        buf.writeln('      </trkpt>');
      }
      buf.writeln('    </trkseg>');
      buf.writeln('  </trk>');
    }

    buf.writeln('</gpx>');
    return buf.toString();
  }

  static String buildGeoJson({
    List<OsmRecord> records = const [],
    List<HikeTrail> trails = const [],
  }) {
    final features = <Map<String, dynamic>>[];

    for (final record in records) {
      features.add({
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [
            record.effectiveLongitude,
            record.effectiveLatitude,
            if (record.altitudeMeters != null) record.altitudeMeters,
          ],
        },
        'properties': {
          'id': record.id,
          'summary': record.summary,
          'ai_source': record.aiSource.name,
          'status': record.status.name,
          'detected_language': record.detectedLanguage,
          'heading_degrees': record.headingDegrees,
          'camera_latitude': record.latitude,
          'camera_longitude': record.longitude,
          'estimated_offset_meters': record.estimatedOffsetMeters,
          'created_at': record.createdAt.toIso8601String(),
          'osm_tags': record.tags,
        },
      });
    }

    for (final trail in trails) {
      if (trail.points.length < 2) continue;
      features.add({
        'type': 'Feature',
        'geometry': {
          'type': 'LineString',
          'coordinates': trail.points
              .map(
                (pt) => [
                  pt.longitude,
                  pt.latitude,
                  if (pt.altitudeMeters != null) pt.altitudeMeters,
                ],
              )
              .toList(),
        },
        'properties': {
          'id': trail.id,
          'name': trail.name,
          'started_at': trail.startedAt.toIso8601String(),
          'ended_at': trail.endedAt?.toIso8601String(),
          'distance_meters': trail.totalDistanceMeters,
          'osm_tags': trail.tags,
        },
      });
    }

    return const JsonEncoder.withIndent('  ').convert({
      'type': 'FeatureCollection',
      'features': features,
    });
  }

  static Future<void> shareExport({
    required String content,
    required String fileName,
    required String subject,
  }) =>
      shareOrDownloadExport(
        content: content,
        fileName: fileName,
        subject: subject,
      );

  static String _xmlEscape(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
