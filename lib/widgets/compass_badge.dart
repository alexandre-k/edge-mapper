import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/osm_record.dart';

class CompassBadge extends StatelessWidget {
  final double? headingDegrees;
  final double size;

  const CompassBadge({
    super.key,
    required this.headingDegrees,
    this.size = 64,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final heading = headingDegrees;
    final cardinal = cardinalDirection(heading);
    final degText = heading != null
        ? '${heading.round().toString().padLeft(3, '0')}°'
        : '---°';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _CompassDialPainter(
              headingDegrees: heading,
              ringColor: colorScheme.outlineVariant,
              northColor: colorScheme.error,
              needleColor: colorScheme.primary,
            ),
            child: Center(
              child: Text(
                cardinal,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontSize: (size * 0.22).clamp(11.0, 16.0),
                      fontWeight: FontWeight.w800,
                      color: colorScheme.onSurface,
                    ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          degText,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
        ),
      ],
    );
  }
}

class _CompassDialPainter extends CustomPainter {
  final double? headingDegrees;
  final Color ringColor;
  final Color northColor;
  final Color needleColor;

  _CompassDialPainter({
    required this.headingDegrees,
    required this.ringColor,
    required this.northColor,
    required this.needleColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) / 2) - 4;

    final ringPaint = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2;
    canvas.drawCircle(center, radius, ringPaint);

    // Draw cardinal ticks
    for (var i = 0; i < 8; i++) {
      final angle = (i * 45.0 - 90.0) * math.pi / 180.0;
      final isMajor = i % 2 == 0;
      final inner = radius - (isMajor ? 6.0 : 3.5);
      final p1 = Offset(
        center.dx + inner * math.cos(angle),
        center.dy + inner * math.sin(angle),
      );
      final p2 = Offset(
        center.dx + radius * math.cos(angle),
        center.dy + radius * math.sin(angle),
      );
      final tickPaint = Paint()
        ..color = i == 0 ? northColor : ringColor
        ..strokeWidth = isMajor ? 2.2 : 1.2;
      canvas.drawLine(p1, p2, tickPaint);
    }

    if (headingDegrees == null) return;

    // Draw heading arrow pointing in the compass bearing direction
    final rad = (headingDegrees! - 90.0) * math.pi / 180.0;
    final tip = Offset(
      center.dx + (radius - 2) * math.cos(rad),
      center.dy + (radius - 2) * math.sin(rad),
    );
    final baseLeft = Offset(
      center.dx + (radius - 13) * math.cos(rad - 0.25),
      center.dy + (radius - 13) * math.sin(rad - 0.25),
    );
    final baseRight = Offset(
      center.dx + (radius - 13) * math.cos(rad + 0.25),
      center.dy + (radius - 13) * math.sin(rad + 0.25),
    );

    final arrowPath = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(baseLeft.dx, baseLeft.dy)
      ..lineTo(baseRight.dx, baseRight.dy)
      ..close();

    canvas.drawPath(
      arrowPath,
      Paint()
        ..color = needleColor
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _CompassDialPainter oldDelegate) {
    return oldDelegate.headingDegrees != headingDegrees ||
        oldDelegate.ringColor != ringColor ||
        oldDelegate.northColor != northColor ||
        oldDelegate.needleColor != needleColor;
  }
}
