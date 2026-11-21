import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Simple 2D precision displacement pad for repositioning a record pin with a
/// draggable hand handle — no cluttering vector lines or jumpy re-centering.
class FinePinPositionPad extends StatefulWidget {
  final double cameraLat;
  final double cameraLon;
  final double pinLat;
  final double pinLon;
  final double? headingDegrees;
  final void Function(double newLat, double newLon) onChanged;
  final void Function(double newLat, double newLon) onChangeEnd;

  const FinePinPositionPad({
    super.key,
    required this.cameraLat,
    required this.cameraLon,
    required this.pinLat,
    required this.pinLon,
    this.headingDegrees,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  State<FinePinPositionPad> createState() => _FinePinPositionPadState();
}

class _FinePinPositionPadState extends State<FinePinPositionPad> {
  static const List<double> _rangeOptions = [5.0, 15.0, 40.0];
  static const double _metersPerDegLat = 111320.0;

  double _rangeMeters = 15.0;
  bool _isDragging = false;

  late double _anchorLat;
  late double _anchorLon;

  @override
  void initState() {
    super.initState();
    _anchorLat = widget.pinLat;
    _anchorLon = widget.pinLon;
  }

  @override
  void didUpdateWidget(covariant FinePinPositionPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If pin coordinates changed externally (e.g. from tapping the map) outside
    // the current range while not dragging, recenter the pad smoothly on it.
    if (!_isDragging) {
      final offset = _offsetFrom(
        _anchorLat,
        _anchorLon,
        widget.pinLat,
        widget.pinLon,
      );
      if (offset.eastMeters.abs() > _rangeMeters * 1.15 ||
          offset.northMeters.abs() > _rangeMeters * 1.15) {
        _anchorLat = widget.pinLat;
        _anchorLon = widget.pinLon;
      }
    }
  }

  double _metersPerDegLon(double lat) =>
      _metersPerDegLat * math.cos(lat * math.pi / 180.0).abs().clamp(0.01, 1.0);

  ({double eastMeters, double northMeters}) _offsetFrom(
    double originLat,
    double originLon,
    double targetLat,
    double targetLon,
  ) {
    return (
      eastMeters: (targetLon - originLon) * _metersPerDegLon(originLat),
      northMeters: (targetLat - originLat) * _metersPerDegLat,
    );
  }

  ({double lat, double lon}) _applyOffset(
    double originLat,
    double originLon,
    double eastMeters,
    double northMeters,
  ) {
    final newLat = (originLat + northMeters / _metersPerDegLat).clamp(
      -89.999999,
      89.999999,
    );
    final newLon =
        (originLon + eastMeters / _metersPerDegLon(originLat)).clamp(
      -179.999999,
      179.999999,
    );
    return (lat: newLat, lon: newLon);
  }

  void _updateFromLocalPosition(
    Offset localPos,
    Size size, {
    required bool commit,
  }) {
    final halfW = size.width / 2;
    final halfH = size.height / 2;
    final scale = math.min(halfW, halfH) - 18;
    if (scale <= 10) return;

    final dxPx = (localPos.dx - halfW).clamp(-halfW + 16, halfW - 16);
    final dyPx = (localPos.dy - halfH).clamp(-halfH + 16, halfH - 16);

    final eastMeters = (dxPx / scale) * _rangeMeters;
    final northMeters = (-dyPx / scale) * _rangeMeters;

    final next = _applyOffset(_anchorLat, _anchorLon, eastMeters, northMeters);
    widget.onChanged(next.lat, next.lon);
    if (commit) {
      widget.onChangeEnd(next.lat, next.lon);
    }
  }

  void _updateByDelta(Offset deltaPx, Size size) {
    final halfW = size.width / 2;
    final halfH = size.height / 2;
    final scale = math.min(halfW, halfH) - 18;
    if (scale <= 10) return;

    final dEast = (deltaPx.dx / scale) * _rangeMeters;
    final dNorth = (-deltaPx.dy / scale) * _rangeMeters;

    final next = _applyOffset(widget.pinLat, widget.pinLon, dEast, dNorth);
    widget.onChanged(next.lat, next.lon);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final pinFromCam = _offsetFrom(
      widget.cameraLat,
      widget.cameraLon,
      widget.pinLat,
      widget.pinLon,
    );
    final pinFromAnchor = _offsetFrom(
      _anchorLat,
      _anchorLon,
      widget.pinLat,
      widget.pinLon,
    );

    String signedMeters(double v, String posDir, String negDir) {
      if (v.abs() < 0.05) return '0.0m';
      return '${v.abs().toStringAsFixed(1)}m ${v >= 0 ? posDir : negDir}';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.pan_tool_rounded, size: 15, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Reposition Pin',
                style: textTheme.labelLarge?.copyWith(fontSize: 12.5),
              ),
            ),
            Wrap(
              spacing: 4,
              children: _rangeOptions.map((r) {
                final selected = _rangeMeters == r;
                return ChoiceChip(
                  label: Text('±${r.round()}m'),
                  selected: selected,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                  onSelected: (_) => setState(() {
                    _rangeMeters = r;
                    _anchorLat = widget.pinLat;
                    _anchorLon = widget.pinLon;
                  }),
                );
              }).toList(),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        LayoutBuilder(
          builder: (context, constraints) {
            final padWidth = constraints.maxWidth;
            const padHeight = 168.0;
            final padSize = Size(padWidth, padHeight);
            final center = Offset(padWidth / 2, padHeight / 2);
            final scale = math.min(center.dx, center.dy) - 18;
            final rawHandleX =
                center.dx + (pinFromAnchor.eastMeters / _rangeMeters) * scale;
            final rawHandleY =
                center.dy - (pinFromAnchor.northMeters / _rangeMeters) * scale;
            final handlePos = Offset(
              rawHandleX.clamp(22.0, padWidth - 22.0),
              rawHandleY.clamp(22.0, padHeight - 22.0),
            );
            const handleDiameter = 36.0;

            return MouseRegion(
              cursor: _isDragging
                  ? SystemMouseCursors.grabbing
                  : SystemMouseCursors.grab,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  _updateFromLocalPosition(
                    details.localPosition,
                    padSize,
                    commit: true,
                  );
                },
                onPanStart: (_) {
                  setState(() => _isDragging = true);
                },
                onPanUpdate: (details) {
                  _updateByDelta(details.delta, padSize);
                },
                onPanEnd: (_) {
                  setState(() {
                    _isDragging = false;
                    // Re-center quietly after release if dragged near the edge
                    final off = _offsetFrom(
                      _anchorLat,
                      _anchorLon,
                      widget.pinLat,
                      widget.pinLon,
                    );
                    if (off.eastMeters.abs() > _rangeMeters * 0.78 ||
                        off.northMeters.abs() > _rangeMeters * 0.78) {
                      _anchorLat = widget.pinLat;
                      _anchorLon = widget.pinLon;
                    }
                  });
                  widget.onChangeEnd(widget.pinLat, widget.pinLon);
                },
                onPanCancel: () {
                  setState(() => _isDragging = false);
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  child: Container(
                    width: padWidth,
                    height: padHeight,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      border: Border.all(
                        color: _isDragging
                            ? scheme.primary
                            : scheme.outlineVariant,
                        width: _isDragging ? 1.6 : 1,
                      ),
                    ),
                    child: Stack(
                      children: [
                        CustomPaint(
                          size: padSize,
                          painter: _FinePinGridPainter(
                            gridColor: scheme.outlineVariant,
                            labelColor: scheme.onSurfaceVariant,
                          ),
                        ),
                        // Clear draggable hand handle showing this pad repositions the pin
                        Positioned(
                          left: handlePos.dx - handleDiameter / 2,
                          top: handlePos.dy - handleDiameter / 2,
                          child: IgnorePointer(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 100),
                              width: handleDiameter,
                              height: handleDiameter,
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: scheme.primary.withValues(
                                      alpha: _isDragging ? 0.45 : 0.28,
                                    ),
                                    blurRadius: _isDragging ? 14 : 6,
                                    spreadRadius: _isDragging ? 4 : 1,
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.pan_tool_rounded,
                                size: 18,
                                color: scheme.onPrimary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        Text(
          'Drag hand to move · ${signedMeters(pinFromCam.northMeters, 'N', 'S')} · ${signedMeters(pinFromCam.eastMeters, 'E', 'W')}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.labelSmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _FinePinGridPainter extends CustomPainter {
  final Color gridColor;
  final Color labelColor;

  const _FinePinGridPainter({
    required this.gridColor,
    required this.labelColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scale = math.min(center.dx, center.dy) - 18;
    if (scale <= 10) return;

    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.42)
      ..strokeWidth = 1;
    final stepPx = scale / 2;
    for (double x = center.dx % stepPx; x < size.width; x += stepPx) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = center.dy % stepPx; y < size.height; y += stepPx) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final axisPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.85)
      ..strokeWidth = 1.1;
    canvas.drawLine(
      Offset(0, center.dy),
      Offset(size.width, center.dy),
      axisPaint,
    );
    canvas.drawLine(
      Offset(center.dx, 0),
      Offset(center.dx, size.height),
      axisPaint,
    );

    final ringPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(center, scale * 0.5, ringPaint);
    canvas.drawCircle(center, scale, ringPaint);

    void drawLabel(String text, Offset pos) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: labelColor.withValues(alpha: 0.8),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
    }

    drawLabel('N', Offset(center.dx, 10));
    drawLabel('S', Offset(center.dx, size.height - 10));
    drawLabel('W', Offset(12, center.dy));
    drawLabel('E', Offset(size.width - 12, center.dy));
  }

  @override
  bool shouldRepaint(covariant _FinePinGridPainter oldDelegate) {
    return oldDelegate.gridColor != gridColor ||
        oldDelegate.labelColor != labelColor;
  }
}
