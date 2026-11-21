import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/hike_trail.dart';
import '../models/osm_record.dart';
import '../services/gps_quality_service.dart';
import '../services/offline_tile_service.dart';
import '../services/osm_duplicate_service.dart';

/// Interactive OpenStreetMap Slippy Tile map widget with:
/// - Persistent local disk tile cache (works 100% offline during hikes!)
/// - Parent-tile zoom fallback when offline at higher zooms
/// - Live GPS dot, accuracy circle, compass cone, and suspect-GPS warning ring
/// - Recorded route polyline (flags sudden GPS jumps in amber/red)
/// - Linked photo snapshot pins & optional camera-to-extrapolated-feature arrow
/// - Pan, +/- zoom buttons, "Center on Me", and "Download Offline Area" action
class OsmMapWidget extends StatefulWidget {
  final OfflineTileService tileService;
  final bool isOnline;
  final double? userLat;
  final double? userLon;
  final double? userAccuracyMeters;
  final double? userHeadingDegrees;
  final GpsQualityReport? gpsQuality;
  final List<TrailPoint> routePoints;
  final List<OsmRecord> pins;
  final List<NearbyOsmElement> mappedOsmFeatures;
  final bool highlightMappedCoverage;
  final NearbyOsmElement? selectedMappedFeature;
  final OsmRecord? selectedPin;
  final OsmRecord? focusRecord; // Shows camera -> extrapolated bearing arrow
  final double height;
  final int initialZoom;
  final bool showOfflineDownloadButton;
  final double downloadRadiusKm;
  final ValueChanged<OsmRecord>? onPinTap;
  final ValueChanged<NearbyOsmElement>? onMappedFeatureTap;
  final VoidCallback? onEmptyTap;
  final ValueChanged<GeoPoint>? onTapCoordinate;
  final ValueChanged<GeoPoint>? onCenterChanged;
  final bool enablePinPlacement;

  const OsmMapWidget({
    super.key,
    required this.tileService,
    required this.isOnline,
    this.userLat,
    this.userLon,
    this.userAccuracyMeters,
    this.userHeadingDegrees,
    this.gpsQuality,
    this.routePoints = const [],
    this.pins = const [],
    this.mappedOsmFeatures = const [],
    this.highlightMappedCoverage = false,
    this.selectedMappedFeature,
    this.selectedPin,
    this.focusRecord,
    this.height = 250,
    this.initialZoom = 16,
    this.showOfflineDownloadButton = true,
    this.downloadRadiusKm = 1.0,
    this.onPinTap,
    this.onMappedFeatureTap,
    this.onEmptyTap,
    this.onTapCoordinate,
    this.onCenterChanged,
    this.enablePinPlacement = false,
  });

  @override
  State<OsmMapWidget> createState() => _OsmMapWidgetState();
}

class _OsmMapWidgetState extends State<OsmMapWidget> {
  static const double _tileSize = 256.0;

  late double _centerLat;
  late double _centerLon;
  late int _zoom;
  bool _followUser = true;
  bool _hasOfflineTilesNearby = false;

  final Map<String, ui.Image> _decodedTiles = {};
  final Set<String> _loadingTiles = {};
  int _lastCacheEpoch = 0;

  @override
  void initState() {
    super.initState();
    _zoom = widget.initialZoom.clamp(11, 18);
    _lastCacheEpoch = widget.tileService.cacheEpoch;
    _initCenter();
    _checkOfflineCoverage();
  }

  void _initCenter() {
    if (widget.focusRecord != null) {
      _centerLat = widget.focusRecord!.effectiveLatitude;
      _centerLon = widget.focusRecord!.effectiveLongitude;
      _followUser = false;
    } else if (widget.routePoints.isNotEmpty) {
      final last = widget.routePoints.last;
      _centerLat = last.latitude;
      _centerLon = last.longitude;
    } else if (widget.userLat != null &&
        widget.userLon != null &&
        (widget.userLat!.abs() > 0.0001 || widget.userLon!.abs() > 0.0001)) {
      _centerLat = widget.userLat!;
      _centerLon = widget.userLon!;
    } else {
      // Friendly default (Tokyo) until GPS locks
      _centerLat = 35.6812;
      _centerLon = 139.7671;
    }
  }

  @override
  void didUpdateWidget(covariant OsmMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_followUser &&
        widget.userLat != null &&
        widget.userLon != null &&
        (widget.userLat!.abs() > 0.0001 || widget.userLon!.abs() > 0.0001)) {
      _centerLat = widget.userLat!;
      _centerLon = widget.userLon!;
    } else if (widget.focusRecord != null &&
        (oldWidget.focusRecord?.effectiveLatitude !=
                widget.focusRecord?.effectiveLatitude ||
            oldWidget.focusRecord?.effectiveLongitude !=
                widget.focusRecord?.effectiveLongitude)) {
      _centerLat = widget.focusRecord!.effectiveLatitude;
      _centerLon = widget.focusRecord!.effectiveLongitude;
    }
    if (oldWidget.isOnline != widget.isOnline) {
      _checkOfflineCoverage();
    }
  }

  @override
  void dispose() {
    for (final img in _decodedTiles.values) {
      img.dispose();
    }
    _decodedTiles.clear();
    super.dispose();
  }

  Future<void> _checkOfflineCoverage() async {
    final covered = await widget.tileService.hasOfflineCoverageAt(
      _centerLat,
      _centerLon,
    );
    if (mounted && covered != _hasOfflineTilesNearby) {
      setState(() => _hasOfflineTilesNearby = covered);
    }
  }

  void _ensureTileLoaded(TileCoord coord) {
    final style = widget.tileService.style;
    final key = '${style.cacheDirName}/$coord';
    if (_decodedTiles.containsKey(key) || _loadingTiles.contains(key)) return;
    _loadingTiles.add(key);

    widget.tileService
        .getTile(coord, allowNetwork: widget.isOnline, styleOverride: style)
        .then((bytes) async {
      if (bytes == null) {
        // Offline zoom fallback: try parent tile (z-1) if cached on disk!
        if (!widget.isOnline && coord.z > 12) {
          final parent = TileCoord(coord.z - 1, coord.x >> 1, coord.y >> 1);
          _ensureTileLoaded(parent);
        }
        return;
      }
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        codec.dispose();
        if (!mounted) {
          frame.image.dispose();
          return;
        }
        setState(() {
          if (_decodedTiles.length > 90) {
            final oldestKey = _decodedTiles.keys.first;
            _decodedTiles.remove(oldestKey)?.dispose();
          }
          _decodedTiles[key] = frame.image;
          _hasOfflineTilesNearby = true;
        });
      } catch (_) {}
    }).whenComplete(() {
      _loadingTiles.remove(key);
    });
  }

  void _panByPixels(Offset delta) {
    final n = math.pow(2.0, _zoom).toDouble();
    final (cx, cy) =
        OfflineTileService.latLonToTileFractional(_centerLat, _centerLon, _zoom);
    final nextX = (cx - delta.dx / _tileSize).clamp(0.0, n);
    final nextY = (cy - delta.dy / _tileSize).clamp(0.0, n);

    final nextLon = nextX / n * 360.0 - 180.0;
    final latRad =
        math.atan(_sinh(math.pi * (1.0 - 2.0 * nextY / n)));
    final nextLat = (latRad * 180.0 / math.pi).clamp(-85.0, 85.0);

    setState(() {
      _followUser = false;
      _centerLat = nextLat;
      _centerLon = nextLon;
    });
    widget.onCenterChanged?.call(GeoPoint(nextLat, nextLon));
  }

  double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2.0;

  Offset _latLonToCanvas(double lat, double lon, Size size) {
    final (centerTileX, centerTileY) =
        OfflineTileService.latLonToTileFractional(_centerLat, _centerLon, _zoom);
    final (tx, ty) =
        OfflineTileService.latLonToTileFractional(lat, lon, _zoom);
    return Offset(
      size.width / 2 + (tx - centerTileX) * _tileSize,
      size.height / 2 + (ty - centerTileY) * _tileSize,
    );
  }

  static bool _pointInPolygon(Offset pt, List<Offset> polygon) {
    if (polygon.length < 3) return false;
    var inside = false;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final xi = polygon[i].dx;
      final yi = polygon[i].dy;
      final xj = polygon[j].dx;
      final yj = polygon[j].dy;
      final intersect = ((yi > pt.dy) != (yj > pt.dy)) &&
          (pt.dx < (xj - xi) * (pt.dy - yi) / ((yj - yi) == 0 ? 1e-9 : (yj - yi)) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  static double _polygonArea(List<Offset> polygon) {
    if (polygon.length < 3) return double.infinity;
    double sum = 0;
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      sum += (polygon[j].dx + polygon[i].dx) * (polygon[j].dy - polygon[i].dy);
    }
    return sum.abs() * 0.5;
  }

  void _handleMapTap(Offset localPos, Size size) {
    if (widget.enablePinPlacement && widget.onTapCoordinate != null) {
      final pt = _canvasPointToLatLon(localPos, size);
      widget.onTapCoordinate!(pt);
      return;
    }

    // 1. Prioritize your own local captures (orange pins)
    if (widget.onPinTap != null) {
      OsmRecord? bestPin;
      double bestDist = 28.0;
      for (final rec in widget.pins) {
        if (rec.effectiveLatitude.abs() < 0.0001 &&
            rec.effectiveLongitude.abs() < 0.0001) {
          continue;
        }
        final pt = _latLonToCanvas(
          rec.effectiveLatitude,
          rec.effectiveLongitude,
          size,
        );
        final d = (pt - localPos).distance;
        if (d <= bestDist) {
          bestDist = d;
          bestPin = rec;
        }
      }
      if (bestPin != null) {
        widget.onPinTap!(bestPin);
        return;
      }
    }

    // 2. Mapped OpenStreetMap points (POIs) & buildings (polygons)
    if (widget.onMappedFeatureTap != null) {
      // 2a. Point POIs first (so a shop node inside a building wins over the building)
      NearbyOsmElement? bestPointPoi;
      double bestPointDist = 26.0;
      for (final el in widget.mappedOsmFeatures) {
        if (el.hasPolygonGeometry && !el.isPoi) continue;
        final pt = _latLonToCanvas(el.latitude, el.longitude, size);
        final d = (pt - localPos).distance;
        if (d <= bestPointDist) {
          bestPointDist = d;
          bestPointPoi = el;
        }
      }
      if (bestPointPoi != null) {
        widget.onMappedFeatureTap!(bestPointPoi);
        return;
      }

      // 2b. Exact point-in-polygon match for mapped buildings & areas (smallest enclosing wins)
      NearbyOsmElement? bestPoly;
      double bestPolyArea = double.infinity;
      for (final el in widget.mappedOsmFeatures) {
        if (!el.hasPolygonGeometry) continue;
        final poly = [
          for (final g in el.geometry) _latLonToCanvas(g.latitude, g.longitude, size),
        ];
        if (_pointInPolygon(localPos, poly)) {
          final area = _polygonArea(poly);
          if (area < bestPolyArea) {
            bestPolyArea = area;
            bestPoly = el;
          }
        }
      }
      if (bestPoly != null) {
        widget.onMappedFeatureTap!(bestPoly);
        return;
      }

      // 2c. Fallback: nearest building centroid within generous touch radius
      NearbyOsmElement? nearestCentroid;
      double nearestCentroidDist = 24.0;
      for (final el in widget.mappedOsmFeatures) {
        final pt = _latLonToCanvas(el.latitude, el.longitude, size);
        final d = (pt - localPos).distance;
        if (d <= nearestCentroidDist) {
          nearestCentroidDist = d;
          nearestCentroid = el;
        }
      }
      if (nearestCentroid != null) {
        widget.onMappedFeatureTap!(nearestCentroid);
        return;
      }
    }

    widget.onEmptyTap?.call();
  }

  GeoPoint _canvasPointToLatLon(Offset localPos, Size size) {
    final n = math.pow(2.0, _zoom).toDouble();
    final (cx, cy) =
        OfflineTileService.latLonToTileFractional(_centerLat, _centerLon, _zoom);
    final tx = (cx + (localPos.dx - size.width / 2) / _tileSize).clamp(0.0, n);
    final ty = (cy + (localPos.dy - size.height / 2) / _tileSize).clamp(0.0, n);
    final lon = tx / n * 360.0 - 180.0;
    final latRad = math.atan(_sinh(math.pi * (1.0 - 2.0 * ty / n)));
    final lat = (latRad * 180.0 / math.pi).clamp(-85.0, 85.0);
    return GeoPoint(lat, lon);
  }

  void _recenter() {
    setState(() {
      if (widget.focusRecord != null) {
        _centerLat = widget.focusRecord!.effectiveLatitude;
        _centerLon = widget.focusRecord!.effectiveLongitude;
        _followUser = false;
      } else if (widget.userLat != null &&
          widget.userLon != null &&
          (widget.userLat!.abs() > 0.0001 || widget.userLon!.abs() > 0.0001)) {
        _centerLat = widget.userLat!;
        _centerLon = widget.userLon!;
        _followUser = true;
      } else if (widget.routePoints.isNotEmpty) {
        _centerLat = widget.routePoints.last.latitude;
        _centerLon = widget.routePoints.last.longitude;
      }
    });
    widget.onCenterChanged?.call(GeoPoint(_centerLat, _centerLon));
  }

  Future<void> _downloadOfflineArea() async {
    if (!widget.isOnline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Go online briefly to download new map tiles for offline hiking.',
          ),
        ),
      );
      return;
    }

    final count = await widget.tileService.downloadRegion(
      centerLat: _centerLat,
      centerLon: _centerLon,
      radiusKm: widget.downloadRadiusKm,
    );
    if (!mounted) return;
    setState(() => _hasOfflineTilesNearby = count > 0 || _hasOfflineTilesNearby);
    final warning = widget.tileService.lastDownloadWarning;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          warning ??
              'Offline map ready! Cached $count tiles (${widget.downloadRadiusKm.toStringAsFixed(1)} km radius).',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final suspectGps = widget.gpsQuality?.level.shouldAdvertiseWarning == true;

    return ListenableBuilder(
      listenable: widget.tileService,
      builder: (context, _) {
        if (_lastCacheEpoch != widget.tileService.cacheEpoch) {
          _lastCacheEpoch = widget.tileService.cacheEpoch;
          for (final img in _decodedTiles.values) {
            img.dispose();
          }
          _decodedTiles.clear();
          _loadingTiles.clear();
        }
        final isDownloading = widget.tileService.isDownloadingRegion;

        return ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Container(
            height: widget.height,
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFFE8F1EC),
              border: Border.all(
                color: suspectGps
                    ? const Color(0xFFDC2626)
                    : scheme.outlineVariant,
                width: suspectGps ? 2.0 : 1.0,
              ),
              borderRadius: BorderRadius.circular(18),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                _requestVisibleTiles(size);

                return Stack(
                  children: [
                    // Interactive map canvas
                    MouseRegion(
                      cursor: widget.enablePinPlacement &&
                              widget.onTapCoordinate != null
                          ? SystemMouseCursors.precise
                          : (widget.onMappedFeatureTap != null ||
                                  widget.onPinTap != null
                              ? SystemMouseCursors.click
                              : SystemMouseCursors.grab),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (widget.enablePinPlacement &&
                                    widget.onTapCoordinate != null) ||
                                widget.onPinTap != null ||
                                widget.onMappedFeatureTap != null ||
                                widget.onEmptyTap != null
                            ? (details) =>
                                _handleMapTap(details.localPosition, size)
                            : null,
                        onPanUpdate: (details) => _panByPixels(details.delta),
                        onDoubleTap: (widget.enablePinPlacement ||
                                widget.onMappedFeatureTap != null ||
                                widget.onPinTap != null)
                            ? null
                            : () {
                                if (_zoom < 18) setState(() => _zoom++);
                              },
                        child: CustomPaint(
                          size: size,
                          painter: _OsmSlippyMapPainter(
                            centerLat: _centerLat,
                            centerLon: _centerLon,
                            zoom: _zoom,
                            styleKey: widget.tileService.style.cacheDirName,
                            decodedTiles: _decodedTiles,
                            userLat: widget.userLat,
                            userLon: widget.userLon,
                            userAccuracyMeters: widget.userAccuracyMeters,
                            userHeadingDegrees: widget.userHeadingDegrees,
                            suspectGps: suspectGps,
                            routePoints: widget.routePoints,
                            pins: widget.pins,
                            mappedOsmFeatures: widget.mappedOsmFeatures,
                            highlightMappedCoverage:
                                widget.highlightMappedCoverage,
                            selectedMappedFeature: widget.selectedMappedFeature,
                            selectedPin: widget.selectedPin,
                            focusRecord: widget.focusRecord,
                          ),
                        ),
                      ),
                    ),
                    if (widget.enablePinPlacement &&
                        widget.onTapCoordinate != null)
                      Positioned(
                        bottom: 8,
                        left: 8,
                        child: IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF047857)
                                  .withValues(alpha: 0.92),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.touch_app_rounded,
                                  size: 14,
                                  color: Colors.white,
                                ),
                                SizedBox(width: 5),
                                Text(
                                  'Tap map to place exact POI pin',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                    // Top-left status badge (Offline Ready / Online OSM / Suspect GPS)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.68),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  widget.isOnline
                                      ? Icons.map_rounded
                                      : (_hasOfflineTilesNearby
                                          ? Icons.offline_pin_rounded
                                          : Icons.grid_on_rounded),
                                  size: 13,
                                  color: widget.isOnline
                                      ? const Color(0xFF34D399)
                                      : (_hasOfflineTilesNearby
                                          ? const Color(0xFFFDE047)
                                          : Colors.orangeAccent),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  widget.isOnline
                                      ? 'OSM Live • ${widget.tileService.cacheStats.tileCount} cached'
                                      : (_hasOfflineTilesNearby
                                          ? 'Offline OSM Map Ready'
                                          : 'Offline Vector Grid'),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (suspectGps) ...[
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFDC2626),
                                borderRadius: BorderRadius.circular(99),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.warning_amber_rounded,
                                    size: 13,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    widget.gpsQuality?.level.shortLabel ??
                                        'Suspect GPS!',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                    // Right-side map controls (+, -, recenter)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Column(
                        children: [
                          _MapControlBtn(
                            icon: Icons.add_rounded,
                            tooltip: 'Zoom in',
                            onTap: _zoom < 18
                                ? () => setState(() => _zoom++)
                                : null,
                          ),
                          const SizedBox(height: 5),
                          _MapControlBtn(
                            icon: Icons.remove_rounded,
                            tooltip: 'Zoom out',
                            onTap: _zoom > 11
                                ? () => setState(() => _zoom--)
                                : null,
                          ),
                          const SizedBox(height: 5),
                          _MapControlBtn(
                            icon: Icons.my_location_rounded,
                            tooltip: 'Center on GPS',
                            highlight: _followUser,
                            onTap: _recenter,
                          ),
                          const SizedBox(height: 5),
                          _MapControlBtn(
                            icon: switch (widget.tileService.style) {
                              MapTileStyle.osmStreets => Icons.layers_rounded,
                              MapTileStyle.topo => Icons.terrain_rounded,
                              MapTileStyle.satellite =>
                                Icons.satellite_alt_rounded,
                            },
                            tooltip:
                                'Switch map style (${widget.tileService.style.label})',
                            highlight: widget.tileService.style !=
                                MapTileStyle.osmStreets,
                            onTap: widget.tileService.toggleStyle,
                          ),
                        ],
                      ),
                    ),

                    // Bottom-left offline area pre-download button
                    if (widget.showOfflineDownloadButton)
                      Positioned(
                        bottom: 8,
                        left: 8,
                        child: isDownloading
                            ? Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.78),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Color(0xFF34D399),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      widget.tileService.isRateLimitPaused
                                          ? 'Rate-limited — pausing (${widget.tileService.downloadDone}/${widget.tileService.downloadTotal})...'
                                          : 'Caching ${widget.tileService.downloadDone}/${widget.tileService.downloadTotal} tiles...',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : Material(
                                color: Colors.white.withValues(alpha: 0.92),
                                borderRadius: BorderRadius.circular(99),
                                elevation: 2,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(99),
                                  onTap: _downloadOfflineArea,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.download_for_offline_rounded,
                                          size: 15,
                                          color: widget.isOnline
                                              ? const Color(0xFF059669)
                                              : Colors.grey,
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          'Cache Area (${widget.downloadRadiusKm.toStringAsFixed(1)}km)',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w800,
                                            color: widget.isOnline
                                                ? const Color(0xFF065F46)
                                                : Colors.grey.shade700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                      ),

                    // Bottom-right OpenStreetMap attribution
                    Positioned(
                      bottom: 6,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          widget.tileService.style.attribution,
                          style: const TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF334155),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _requestVisibleTiles(Size size) {
    final (cx, cy) =
        OfflineTileService.latLonToTileFractional(_centerLat, _centerLon, _zoom);
    final halfW = (size.width / 2) / _tileSize;
    final halfH = (size.height / 2) / _tileSize;
    final maxTile = (1 << _zoom) - 1;

    final minX = (cx - halfW).floor().clamp(0, maxTile);
    final maxX = (cx + halfW).floor().clamp(0, maxTile);
    final minY = (cy - halfH).floor().clamp(0, maxTile);
    final maxY = (cy + halfH).floor().clamp(0, maxTile);

    for (int x = minX; x <= maxX; x++) {
      for (int y = minY; y <= maxY; y++) {
        _ensureTileLoaded(TileCoord(_zoom, x, y));
      }
    }
  }
}

class _MapControlBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool highlight;

  const _MapControlBtn({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: highlight
          ? const Color(0xFF059669)
          : Colors.white.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              icon,
              size: 18,
              color: highlight
                  ? Colors.white
                  : (onTap != null ? const Color(0xFF1E293B) : Colors.grey),
            ),
          ),
        ),
      ),
    );
  }
}

class _OsmSlippyMapPainter extends CustomPainter {
  static const double _tileSize = 256.0;

  final double centerLat;
  final double centerLon;
  final int zoom;
  final String styleKey;
  final Map<String, ui.Image> decodedTiles;
  final double? userLat;
  final double? userLon;
  final double? userAccuracyMeters;
  final double? userHeadingDegrees;
  final bool suspectGps;
  final List<TrailPoint> routePoints;
  final List<OsmRecord> pins;
  final List<NearbyOsmElement> mappedOsmFeatures;
  final bool highlightMappedCoverage;
  final NearbyOsmElement? selectedMappedFeature;
  final OsmRecord? selectedPin;
  final OsmRecord? focusRecord;

  _OsmSlippyMapPainter({
    required this.centerLat,
    required this.centerLon,
    required this.zoom,
    required this.styleKey,
    required this.decodedTiles,
    required this.userLat,
    required this.userLon,
    required this.userAccuracyMeters,
    required this.userHeadingDegrees,
    required this.suspectGps,
    required this.routePoints,
    required this.pins,
    required this.mappedOsmFeatures,
    required this.highlightMappedCoverage,
    required this.selectedMappedFeature,
    required this.selectedPin,
    required this.focusRecord,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final (centerTileX, centerTileY) =
        OfflineTileService.latLonToTileFractional(centerLat, centerLon, zoom);

    Offset latLonToCanvas(double lat, double lon) {
      final (tx, ty) =
          OfflineTileService.latLonToTileFractional(lat, lon, zoom);
      return Offset(
        size.width / 2 + (tx - centerTileX) * _tileSize,
        size.height / 2 + (ty - centerTileY) * _tileSize,
      );
    }

    // 1. Subtle topographic grid background (visible if tiles aren't cached yet)
    final gridPaint = Paint()
      ..color = const Color(0xFFCBD5E1).withValues(alpha: 0.55)
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y < size.height; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // 2. Draw OSM raster tiles (with parent-tile overzoom fallback when offline!)
    final halfW = (size.width / 2) / _tileSize;
    final halfH = (size.height / 2) / _tileSize;
    final maxTile = (1 << zoom) - 1;

    final minX = (centerTileX - halfW).floor().clamp(0, maxTile);
    final maxX = (centerTileX + halfW).floor().clamp(0, maxTile);
    final minY = (centerTileY - halfH).floor().clamp(0, maxTile);
    final maxY = (centerTileY + halfH).floor().clamp(0, maxTile);

    final tilePaint = Paint()..filterQuality = FilterQuality.low;

    for (int x = minX; x <= maxX; x++) {
      for (int y = minY; y <= maxY; y++) {
        final left = size.width / 2 + (x - centerTileX) * _tileSize;
        final top = size.height / 2 + (y - centerTileY) * _tileSize;
        final dstRect = Rect.fromLTWH(left, top, _tileSize, _tileSize);

        final exact = decodedTiles['$styleKey/$zoom/$x/$y'];
        if (exact != null) {
          canvas.drawImageRect(
            exact,
            Rect.fromLTWH(
              0,
              0,
              exact.width.toDouble(),
              exact.height.toDouble(),
            ),
            dstRect,
            tilePaint,
          );
        } else {
          // Try parent tile at zoom-1 or zoom-2 for seamless offline zoom
          for (int dz = 1; dz <= 2; dz++) {
            final pz = zoom - dz;
            if (pz < 10) break;
            final px = x >> dz;
            final py = y >> dz;
            final parent = decodedTiles['$styleKey/$pz/$px/$py'];
            if (parent != null) {
              final factor = 1 << dz;
              final subW = parent.width / factor;
              final subH = parent.height / factor;
              final subX = (x % factor) * subW;
              final subY = (y % factor) * subH;
              canvas.drawImageRect(
                parent,
                Rect.fromLTWH(subX, subY, subW, subH),
                dstRect,
                tilePaint,
              );
              break;
            }
          }
        }
      }
    }

    // 3. Draw recorded route polyline (highlighting suspect GPS jumps in red/orange)
    if (routePoints.length >= 2) {
      final normalPaint = Paint()
        ..color = const Color(0xFF059669)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final jumpPaint = Paint()
        ..color = const Color(0xFFDC2626)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round;

      for (int i = 1; i < routePoints.length; i++) {
        final prev = routePoints[i - 1];
        final curr = routePoints[i];
        final p1 = latLonToCanvas(prev.latitude, prev.longitude);
        final p2 = latLonToCanvas(curr.latitude, curr.longitude);

        final dist = haversineMeters(
          prev.latitude,
          prev.longitude,
          curr.latitude,
          curr.longitude,
        );
        final dt = math.max(
          curr.recordedAt.difference(prev.recordedAt).inMilliseconds / 1000.0,
          0.5,
        );
        final isJump = dist / dt > 45.0 || (dist > 150.0 && dt <= 3.0);

        if (isJump) {
          canvas.drawLine(p1, p2, jumpPaint);
        } else {
          canvas.drawLine(p1, p2, borderPaint);
          canvas.drawLine(p1, p2, normalPaint);
        }
      }

      // Start & End markers
      final startPt =
          latLonToCanvas(routePoints.first.latitude, routePoints.first.longitude);
      canvas.drawCircle(startPt, 7, Paint()..color = Colors.white);
      canvas.drawCircle(startPt, 5, Paint()..color = const Color(0xFF16A34A));

      final endPt =
          latLonToCanvas(routePoints.last.latitude, routePoints.last.longitude);
      canvas.drawCircle(endPt, 7, Paint()..color = Colors.white);
      canvas.drawCircle(endPt, 5, Paint()..color = const Color(0xFFF97316));
    }

    // 4. Focus record camera -> extrapolated feature bearing vector + GPS & calculation error rings
    if (focusRecord != null) {
      final rec = focusRecord!;
      final cam = latLonToCanvas(rec.latitude, rec.longitude);
      final target = latLonToCanvas(
        rec.effectiveLatitude,
        rec.effectiveLongitude,
      );
      final metersPerPx = math.max(
        156543.03392 *
            math.cos(rec.effectiveLatitude * math.pi / 180.0) /
            math.pow(2, zoom),
        0.01,
      );
      final uncertainty = rec.positionUncertainty;

      // 4a. Camera GPS measurement error ring (blue translucent halo)
      if (!rec.isManualPinOverride &&
          uncertainty.gpsMeasurementErrorMeters != null) {
        final gpsRadiusPx =
            (uncertainty.gpsMeasurementErrorMeters! / metersPerPx)
                .clamp(10.0, 90.0);
        canvas.drawCircle(
          cam,
          gpsRadiusPx,
          Paint()..color = const Color(0xFF0EA5E9).withValues(alpha: 0.14),
        );
        canvas.drawCircle(
          cam,
          gpsRadiusPx,
          Paint()
            ..color = const Color(0xFF0EA5E9).withValues(alpha: 0.45)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2,
        );
      }

      // 4b. Combined POI position uncertainty ring (amber/red when large, emerald when manually placed)
      final pinColor = rec.isManualPinOverride
          ? const Color(0xFF059669)
          : const Color(0xFFF97316);
      final errRingColor = switch (uncertainty.severity) {
        PositionUncertaintySeverity.highPrecision => const Color(0xFF059669),
        PositionUncertaintySeverity.moderate => const Color(0xFFD97706),
        PositionUncertaintySeverity.needsCorrection => const Color(0xFFDC2626),
      };
      if (!rec.isManualPinOverride) {
        final totalRadiusPx =
            (uncertainty.totalCombinedErrorMeters / metersPerPx)
                .clamp(12.0, 105.0);
        canvas.drawCircle(
          target,
          totalRadiusPx,
          Paint()..color = errRingColor.withValues(alpha: 0.15),
        );
        canvas.drawCircle(
          target,
          totalRadiusPx,
          Paint()
            ..color = errRingColor.withValues(alpha: 0.72)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
      }

      canvas.drawLine(
        cam,
        target,
        Paint()
          ..color = pinColor
          ..strokeWidth = 2.8
          ..strokeCap = StrokeCap.round,
      );
      // Camera dot (blue)
      canvas.drawCircle(cam, 6.0, Paint()..color = Colors.white);
      canvas.drawCircle(cam, 4.0, Paint()..color = const Color(0xFF0EA5E9));
      // Feature pin (vibrant coral or emerald for manually corrected pin)
      canvas.drawCircle(target, 9, Paint()..color = Colors.white);
      canvas.drawCircle(target, 6.5, Paint()..color = pinColor);
    }

    // 5. Surrounding mapped OpenStreetMap buildings, POIs & local photo snapshot pins
    final visiblePolygons = <({NearbyOsmElement el, List<Offset> poly, Offset center})>[];
    final visibleOsmPois = <({NearbyOsmElement el, Offset pt})>[];
    if (mappedOsmFeatures.isNotEmpty) {
      for (final el in mappedOsmFeatures) {
        final pt = latLonToCanvas(el.latitude, el.longitude);
        if (el.hasPolygonGeometry) {
          final poly = <Offset>[];
          double minX = double.infinity;
          double maxX = double.negativeInfinity;
          double minY = double.infinity;
          double maxY = double.negativeInfinity;
          for (final g in el.geometry) {
            final p = latLonToCanvas(g.latitude, g.longitude);
            poly.add(p);
            if (p.dx < minX) minX = p.dx;
            if (p.dx > maxX) maxX = p.dx;
            if (p.dy < minY) minY = p.dy;
            if (p.dy > maxY) maxY = p.dy;
          }
          if (maxX >= -12 &&
              minX <= size.width + 12 &&
              maxY >= -12 &&
              minY <= size.height + 12) {
            visiblePolygons.add((el: el, poly: poly, center: pt));
          }
        }
        if (el.isPoi || !el.hasPolygonGeometry) {
          if (pt.dx >= -28 &&
              pt.dx <= size.width + 28 &&
              pt.dy >= -28 &&
              pt.dy <= size.height + 28) {
            visibleOsmPois.add((el: el, pt: pt));
          }
        }
      }
    }

    final visiblePins = <({OsmRecord rec, Offset pt})>[];
    for (final rec in pins) {
      if (rec.effectiveLatitude.abs() < 0.0001 &&
          rec.effectiveLongitude.abs() < 0.0001) {
        continue;
      }
      final pt = latLonToCanvas(rec.effectiveLatitude, rec.effectiveLongitude);
      if (pt.dx < -28 ||
          pt.dx > size.width + 28 ||
          pt.dy < -28 ||
          pt.dy > size.height + 28) {
        continue;
      }
      visiblePins.add((rec: rec, pt: pt));
    }

    // 5a-0. Mapped Building & Area Polygons (drawn first so POI dots stay on top)
    if (visiblePolygons.isNotEmpty) {
      for (final item in visiblePolygons) {
        final isSel = selectedMappedFeature != null &&
            selectedMappedFeature!.type == item.el.type &&
            selectedMappedFeature!.id == item.el.id;
        final isPoiBldg = item.el.isPoi;
        final path = Path()..addPolygon(item.poly, true);

        final fillColor = isSel
            ? const Color(0xFF0284C7).withValues(alpha: 0.36)
            : (isPoiBldg
                ? const Color(0xFF10B981).withValues(alpha: 0.22)
                : const Color(0xFF0EA5E9).withValues(alpha: 0.18));
        final strokeColor = isSel
            ? const Color(0xFF0369A1)
            : (isPoiBldg
                ? const Color(0xFF059669).withValues(alpha: 0.85)
                : const Color(0xFF0284C7).withValues(alpha: 0.78));

        canvas.drawPath(path, Paint()..color = fillColor);
        if (isSel) {
          canvas.drawPath(
            path,
            Paint()
              ..color = Colors.white.withValues(alpha: 0.92)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 4.6
              ..strokeJoin = StrokeJoin.round,
          );
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = strokeColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = isSel ? 2.6 : 1.5
            ..strokeJoin = StrokeJoin.round,
        );

        // Subtle center dot on non-POI buildings when zoomed in so they look tap-selectable
        if (!isPoiBldg && (zoom >= 17 || isSel)) {
          canvas.drawCircle(
            item.center,
            isSel ? 5.5 : 3.5,
            Paint()..color = Colors.white,
          );
          canvas.drawCircle(
            item.center,
            isSel ? 3.8 : 2.3,
            Paint()..color = strokeColor,
          );
        }
      }
    }

    // 5a. Coverage glow halos so already-mapped POI clusters stand out instantly
    if (highlightMappedCoverage && zoom >= 15) {
      final osmAuraFill = Paint()
        ..color = const Color(0xFF10B981).withValues(alpha: 0.20);
      final osmAuraStroke = Paint()
        ..color = const Color(0xFF059669).withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      final auraRadius = zoom >= 17 ? 18.0 : 13.0;
      for (final item in visibleOsmPois) {
        canvas.drawCircle(item.pt, auraRadius, osmAuraFill);
        canvas.drawCircle(item.pt, auraRadius, osmAuraStroke);
      }

      final pinAuraFill = Paint()
        ..color = const Color(0xFFF97316).withValues(alpha: 0.22);
      final pinAuraStroke = Paint()
        ..color = const Color(0xFFEA580C).withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      final pinAuraRadius = zoom >= 17 ? 20.0 : 14.5;
      for (final item in visiblePins) {
        canvas.drawCircle(item.pt, pinAuraRadius, pinAuraFill);
        canvas.drawCircle(item.pt, pinAuraRadius, pinAuraStroke);
      }
    }

    // 5b. Bold emerald checkmarked badges for already-mapped OSM POIs
    if (visibleOsmPois.isNotEmpty) {
      final darkOutline = Paint()
        ..color = const Color(0xFF064E3B).withValues(alpha: 0.72);
      final whiteRing = Paint()..color = Colors.white;
      final osmFill = Paint()..color = const Color(0xFF059669);
      final osmSelectedFill = Paint()..color = const Color(0xFF047857);
      final checkPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.9
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      for (final item in visibleOsmPois) {
        final isSel = selectedMappedFeature != null &&
            selectedMappedFeature!.type == item.el.type &&
            selectedMappedFeature!.id == item.el.id;
        final r = isSel ? 11.5 : 8.5;
        canvas.drawCircle(item.pt, r + 2.2, darkOutline);
        canvas.drawCircle(item.pt, r + 1.2, whiteRing);
        canvas.drawCircle(item.pt, r - 0.5, isSel ? osmSelectedFill : osmFill);

        // Crisp white checkmark inside the badge
        final s = isSel ? 1.2 : 0.92;
        final path = Path()
          ..moveTo(item.pt.dx - 3.6 * s, item.pt.dy + 0.2 * s)
          ..lineTo(item.pt.dx - 1.0 * s, item.pt.dy + 2.8 * s)
          ..lineTo(item.pt.dx + 4.0 * s, item.pt.dy - 2.6 * s);
        canvas.drawPath(path, checkPaint);
      }
    }

    // 5c. Local Edge Mapper capture pins (vibrant coral-orange, unmistakable)
    for (final item in visiblePins) {
      final isSel = selectedPin != null && selectedPin!.id == item.rec.id;
      if (highlightMappedCoverage) {
        final r = isSel ? 12.5 : 9.5;
        canvas.drawCircle(
          item.pt,
          r + 2.4,
          Paint()..color = const Color(0xFF7C2D12).withValues(alpha: 0.75),
        );
        canvas.drawCircle(item.pt, r + 1.3, Paint()..color = Colors.white);
        canvas.drawCircle(
          item.pt,
          r - 0.5,
          Paint()..color = const Color(0xFFEA580C),
        );
        canvas.drawCircle(item.pt, isSel ? 4.0 : 3.0, Paint()..color = Colors.white);
      } else {
        canvas.drawCircle(item.pt, 7.5, Paint()..color = Colors.white);
        canvas.drawCircle(
          item.pt,
          5.5,
          Paint()..color = const Color(0xFFF97316),
        );
      }
    }

    // 5d. Collision-free compact name pills when zoomed in or marker selected
    if (highlightMappedCoverage && (zoom >= 17 || selectedMappedFeature != null || selectedPin != null)) {
      final placedLabelRects = <Rect>[];
      int drawnLabels = 0;

      void tryDrawLabel({
        required Offset anchor,
        required String rawText,
        required Color borderColor,
        required Color textColor,
        bool force = false,
      }) {
        if (!force && drawnLabels >= 22) return;
        final trimmed = rawText.trim();
        if (trimmed.isEmpty) return;
        final text =
            trimmed.length > 18 ? '${trimmed.substring(0, 17)}…' : trimmed;
        final tp = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              color: textColor,
              fontSize: 10.0,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();

        const padH = 5.5;
        const padV = 2.5;
        final pillW = tp.width + padH * 2;
        final pillH = tp.height + padV * 2;
        final rect = Rect.fromLTWH(
          anchor.dx - pillW / 2,
          anchor.dy + 12.5,
          pillW,
          pillH,
        );

        if (rect.left < 4 ||
            rect.right > size.width - 4 ||
            rect.top < 4 ||
            rect.bottom > size.height - 4) {
          return;
        }
        final inflated = rect.inflate(2.0);
        if (!force && placedLabelRects.any((r) => r.overlaps(inflated))) {
          return;
        }
        placedLabelRects.add(rect);
        drawnLabels++;

        final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
        canvas.drawRRect(
          rrect,
          Paint()..color = Colors.white.withValues(alpha: 0.94),
        );
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = borderColor.withValues(alpha: 0.78)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0,
        );
        tp.paint(canvas, Offset(rect.left + padH, rect.top + padV));
      }

      if (selectedPin != null) {
        for (final item in visiblePins) {
          if (item.rec.id == selectedPin!.id) {
            tryDrawLabel(
              anchor: item.pt,
              rawText: item.rec.displayName,
              borderColor: const Color(0xFFEA580C),
              textColor: const Color(0xFF9A3412),
              force: true,
            );
          }
        }
      }
      if (selectedMappedFeature != null) {
        final sel = selectedMappedFeature!;
        final selPt = latLonToCanvas(sel.latitude, sel.longitude);
        final isBldgOnly = sel.isBuilding && !sel.isPoi;
        tryDrawLabel(
          anchor: selPt,
          rawText: sel.displayName,
          borderColor:
              isBldgOnly ? const Color(0xFF0284C7) : const Color(0xFF059669),
          textColor:
              isBldgOnly ? const Color(0xFF0369A1) : const Color(0xFF065F46),
          force: true,
        );
      }
      if (zoom >= 17) {
        for (final item in visiblePins) {
          tryDrawLabel(
            anchor: item.pt,
            rawText: item.rec.displayName,
            borderColor: const Color(0xFFEA580C),
            textColor: const Color(0xFF9A3412),
          );
        }
        for (final item in visibleOsmPois) {
          tryDrawLabel(
            anchor: item.pt,
            rawText: item.el.displayName,
            borderColor: const Color(0xFF059669),
            textColor: const Color(0xFF065F46),
          );
        }
      }
    }

    // 6. Live user GPS dot + accuracy circle + compass heading cone
    if (userLat != null &&
        userLon != null &&
        (userLat!.abs() > 0.0001 || userLon!.abs() > 0.0001)) {
      final pos = latLonToCanvas(userLat!, userLon!);

      // Meters per pixel at this zoom & latitude
      final metersPerPx =
          156543.03392 * math.cos(userLat! * math.pi / 180.0) / math.pow(2, zoom);
      final accRadiusPx =
          ((userAccuracyMeters ?? 10.0) / math.max(metersPerPx, 0.01))
              .clamp(12.0, 95.0);

      final haloColor =
          suspectGps ? const Color(0xFFDC2626) : const Color(0xFF0EA5E9);

      canvas.drawCircle(
        pos,
        accRadiusPx,
        Paint()..color = haloColor.withValues(alpha: 0.18),
      );
      canvas.drawCircle(
        pos,
        accRadiusPx,
        Paint()
          ..color = haloColor.withValues(alpha: 0.65)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );

      // Compass heading cone
      if (userHeadingDegrees != null) {
        final rad = (userHeadingDegrees! - 90.0) * math.pi / 180.0;
        final conePath = Path()
          ..moveTo(pos.dx, pos.dy)
          ..arcTo(
            Rect.fromCircle(center: pos, radius: 26),
            rad - 0.35,
            0.70,
            false,
          )
          ..close();
        canvas.drawPath(
          conePath,
          Paint()..color = haloColor.withValues(alpha: 0.35),
        );
      }

      // User blue/red dot
      canvas.drawCircle(pos, 8.5, Paint()..color = Colors.white);
      canvas.drawCircle(pos, 6.0, Paint()..color = haloColor);
    }
  }

  @override
  bool shouldRepaint(covariant _OsmSlippyMapPainter oldDelegate) => true;
}
