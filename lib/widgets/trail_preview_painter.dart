import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/hike_trail.dart';
import '../models/osm_record.dart';

/// 100% offline vector canvas rendering the live GPS hiking track and linked
/// OSM photo snapshots without needing internet map tiles.
class TrailPreviewCard extends StatelessWidget {
  final List<TrailPoint> points;
  final List<OsmRecord> linkedRecords;

  const TrailPreviewCard({
    super.key,
    required this.points,
    this.linkedRecords = const [],
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 170,
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: points.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.route_rounded,
                    size: 34,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'GPS trail path will draw here offline as you walk',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: CustomPaint(
                painter: _TrailPreviewPainter(
                  points: points,
                  linkedRecords: linkedRecords,
                  lineColor: scheme.primary,
                  gridColor: scheme.outlineVariant.withValues(alpha: 0.35),
                  pinColor: const Color(0xFFD84315),
                ),
              ),
            ),
    );
  }
}

class _TrailPreviewPainter extends CustomPainter {
  final List<TrailPoint> points;
  final List<OsmRecord> linkedRecords;
  final Color lineColor;
  final Color gridColor;
  final Color pinColor;

  _TrailPreviewPainter({
    required this.points,
    required this.linkedRecords,
    required this.lineColor,
    required this.gridColor,
    required this.pinColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Subtle topographic grid lines
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * (i / 4);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      final x = size.width * (i / 4);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    if (points.isEmpty) return;

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLon = points.first.longitude;
    double maxLon = points.first.longitude;

    for (final pt in points) {
      minLat = math.min(minLat, pt.latitude);
      maxLat = math.max(maxLat, pt.latitude);
      minLon = math.min(minLon, pt.longitude);
      maxLon = math.max(maxLon, pt.longitude);
    }
    for (final rec in linkedRecords) {
      minLat = math.min(minLat, rec.effectiveLatitude);
      maxLat = math.max(maxLat, rec.effectiveLatitude);
      minLon = math.min(minLon, rec.effectiveLongitude);
      maxLon = math.max(maxLon, rec.effectiveLongitude);
    }

    const pad = 22.0;
    final drawW = size.width - pad * 2;
    final drawH = size.height - pad * 2;
    final latSpan = math.max(maxLat - minLat, 0.0002);
    final lonSpan = math.max(maxLon - minLon, 0.0002);

    // Keep aspect ratio accurate using cos(midLat)
    final midLatRad = ((minLat + maxLat) / 2.0) * math.pi / 180.0;
    final lonMetersSpan = lonSpan * math.cos(midLatRad);
    final scale = math.min(drawW / math.max(lonMetersSpan, 1e-6), drawH / latSpan);

    final scaledW = lonMetersSpan * scale;
    final scaledH = latSpan * scale;
    final offsetX = pad + (drawW - scaledW) / 2;
    final offsetY = pad + (drawH - scaledH) / 2;

    Offset project(double lat, double lon) {
      final x = offsetX + ((lon - minLon) * math.cos(midLatRad)) * scale;
      final y = offsetY + (maxLat - lat) * scale;
      return Offset(x, y);
    }

    if (points.length >= 2) {
      final path = Path();
      final first = project(points.first.latitude, points.first.longitude);
      path.moveTo(first.dx, first.dy);
      for (var i = 1; i < points.length; i++) {
        final p = project(points[i].latitude, points[i].longitude);
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = lineColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    // Start marker (green)
    final startPos = project(points.first.latitude, points.first.longitude);
    canvas.drawCircle(startPos, 5.5, Paint()..color = Colors.green);

    // Latest / current marker (blue dot with white halo)
    final endPos = project(points.last.latitude, points.last.longitude);
    canvas.drawCircle(endPos, 7.5, Paint()..color = Colors.white);
    canvas.drawCircle(endPos, 5.5, Paint()..color = lineColor);

    // Linked OSM photo pins
    for (final rec in linkedRecords) {
      final pos = project(rec.effectiveLatitude, rec.effectiveLongitude);
      canvas.drawCircle(pos, 6.0, Paint()..color = Colors.white);
      canvas.drawCircle(pos, 4.2, Paint()..color = pinColor);
    }
  }

  @override
  bool shouldRepaint(covariant _TrailPreviewPainter oldDelegate) {
    return oldDelegate.points.length != points.length ||
        oldDelegate.linkedRecords.length != linkedRecords.length;
  }
}
