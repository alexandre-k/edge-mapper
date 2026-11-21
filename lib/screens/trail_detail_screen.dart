import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/osm_tag_catalog.dart';
import '../models/hike_trail.dart';
import '../models/osm_record.dart';
import '../services/connectivity_service.dart';
import '../services/hybrid_ai_service.dart';
import '../services/mapper_store.dart';
import '../services/offline_tile_service.dart';
import '../services/osm_export_service.dart';
import '../services/osm_publish_service.dart';
import '../services/user_preferences_service.dart';
import '../theme/app_theme.dart';
import '../widgets/osm_map_widget.dart';
import '../widgets/osm_publish_sheet.dart';
import '../widgets/responsive_layout.dart';
import 'record_detail_screen.dart';

/// Full review & editing screen for ANY recorded walk, park stroll, hike, or route.
class TrailDetailScreen extends StatefulWidget {
  final HikeTrail initialTrail;
  final MapperStore store;
  final OfflineTileService tiles;
  final ConnectivityService connectivity;
  final UserPreferencesService prefs;
  final HybridAiService ai;
  final OsmPublishService osmPublish;

  const TrailDetailScreen({
    super.key,
    required this.initialTrail,
    required this.store,
    required this.tiles,
    required this.connectivity,
    required this.prefs,
    required this.ai,
    required this.osmPublish,
  });

  @override
  State<TrailDetailScreen> createState() => _TrailDetailScreenState();
}

class _TrailDetailScreenState extends State<TrailDetailScreen> {
  late HikeTrail _trail;
  late TextEditingController _nameController;
  bool _isGuessing = false;

  @override
  void initState() {
    super.initState();
    _trail = widget.initialTrail;
    _nameController = TextEditingController(text: _trail.name);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveTrail(HikeTrail updated) async {
    await widget.store.updateTrail(updated);
    if (!mounted) return;
    setState(() {
      _trail = updated;
      if (_nameController.text != updated.name) {
        _nameController.text = updated.name;
      }
    });
  }

  Future<void> _pickOsmAttribute({
    required String tagKey,
    required String title,
    required List<(String, String)> options,
  }) async {
    final searchCtrl = TextEditingController();
    final selected = await showAdaptiveSheet<String>(
      context: context,
      desktopMaxWidth: 480,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final q = searchCtrl.text.trim().toLowerCase();
          final filtered = options
              .where(
                (o) =>
                    q.isEmpty ||
                    o.$1.toLowerCase().contains(q) ||
                    o.$2.toLowerCase().contains(q),
              )
              .toList();

          return AdaptiveModalScrollContainer(
            initialChildSize: 0.72,
            minChildSize: 0.45,
            builder: (_, scrollCtrl) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(ctx)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 19),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: searchCtrl,
                    onChanged: (_) => setSheetState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'Search all OSM values...',
                      prefixIcon: Icon(Icons.search_rounded),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    controller: scrollCtrl,
                    itemCount: filtered.length,
                    itemBuilder: (_, idx) {
                      final opt = filtered[idx];
                      final isCurrent = _trail.tags[tagKey] == opt.$1;
                      return ListTile(
                        dense: true,
                        title: Text(
                          opt.$1,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(opt.$2),
                        trailing: isCurrent
                            ? const Icon(
                                Icons.check_circle_rounded,
                                color: Color(0xFF059669),
                              )
                            : null,
                        onTap: () => Navigator.pop(ctx, opt.$1),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    searchCtrl.dispose();

    if (selected != null) {
      final nextTags = Map<String, String>.from(_trail.tags)
        ..[tagKey] = selected;
      await _saveTrail(_trail.copyWith(tags: nextTags));
    }
  }

  Future<void> _guessLocationNow() async {
    if (!widget.connectivity.isOnline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Go online to auto-guess route context from OSM.'),
        ),
      );
      return;
    }
    setState(() => _isGuessing = true);
    try {
      final guessed = await widget.store.guessTrailLocation(_trail);
      if (!mounted) return;
      if (guessed != null) {
        setState(() {
          _trail = guessed;
          _nameController.text = guessed.name;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Guessed "${guessed.name}" (${guessed.activityType.label})',
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No location match returned for these coordinates.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isGuessing = false);
    }
  }

  Future<void> _deleteTrail() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Route?'),
        content: Text(
          'Permanently remove "${_trail.name}"? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await widget.store.deleteTrail(_trail.id);
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _export(String format, List<OsmRecord> linked) async {
    final safeName = _trail.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final baseName = safeName.isEmpty ? 'edge_mapper_route' : safeName;
    if (format == 'gpx') {
      final gpx = OsmExportService.buildGpx(records: linked, trails: [_trail]);
      await OsmExportService.shareExport(
        content: gpx,
        fileName: '$baseName.gpx',
        subject: 'Edge Mapper GPX: ${_trail.name}',
      );
    } else if (format == 'osm') {
      final osm =
          OsmExportService.buildOsmXml(records: linked, trails: [_trail]);
      await OsmExportService.shareExport(
        content: osm,
        fileName: '$baseName.osm',
        subject: 'Edge Mapper OSM XML: ${_trail.name}',
      );
    } else {
      final geo =
          OsmExportService.buildGeoJson(records: linked, trails: [_trail]);
      await OsmExportService.shareExport(
        content: geo,
        fileName: '$baseName.geojson',
        subject: 'Edge Mapper GeoJSON: ${_trail.name}',
      );
    }
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(2)} km';
    return '${meters.toStringAsFixed(0)} m';
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '${h}h ${m}m' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final linkedRecords =
        widget.store.records.where((r) => r.trailId == _trail.id).toList();
    final jumpCount = _trail.suspectJumpCount;
    final avgAcc = _trail.averageAccuracyMeters;

    return Scaffold(
      appBar: AppBar(
        title: Text(_trail.name),
        actions: [
          IconButton(
            tooltip: 'Publish to OpenStreetMap',
            onPressed: () => showOsmPublishSheet(
              context,
              osm: widget.osmPublish,
              store: widget.store,
              prefs: widget.prefs,
              connectivity: widget.connectivity,
              trail: _trail,
              linkedTrailRecords: linkedRecords,
            ),
            icon: const Icon(Icons.publish_rounded),
          ),
          IconButton(
            tooltip: 'Delete route',
            onPressed: _deleteTrail,
            icon: Icon(
              Icons.delete_outline_rounded,
              size: 21,
              color: scheme.error,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'More actions',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (action) async {
              await _export(action, linkedRecords);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'osm',
                child: Row(
                  children: [
                    Icon(Icons.ios_share_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('Export OSM XML (.osm)'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'gpx',
                child: Row(
                  children: [
                    Icon(Icons.route_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('Export GPX (.gpx)'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'geojson',
                child: Row(
                  children: [
                    Icon(Icons.data_object_rounded, size: 18),
                    SizedBox(width: 10),
                    Text('Export GeoJSON'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isTwoCol = constraints.maxWidth >= AppBreakpoints.expanded;

          Widget buildMapAndStatsColumn() => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.lg),
                    child: OsmMapWidget(
                      tileService: widget.tiles,
                      isOnline: widget.connectivity.isOnline,
                      routePoints: _trail.points,
                      pins: linkedRecords,
                      height: isTwoCol ? 320 : 250,
                      initialZoom: 16,
                      downloadRadiusKm: widget.prefs.offlineMapRadiusKm,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),

                  if (jumpCount > 0)
                    InlineNoticeBanner(
                      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                      tone: NoticeTone.danger,
                      icon: Icons.warning_amber_rounded,
                      title: '$jumpCount suspected GPS jump(s) detected',
                      detail:
                          'Highlighted in red on the map. Inspect waypoints to clean up noisy points.',
                    ),

                  SurfacePanel(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            Expanded(
                              child: MetricStatTile(
                                label: 'Distance',
                                value: _formatDistance(
                                  _trail.totalDistanceMeters,
                                ),
                              ),
                            ),
                            Expanded(
                              child: MetricStatTile(
                                label: 'Duration',
                                value: _formatDuration(_trail.duration),
                              ),
                            ),
                            Expanded(
                              child: MetricStatTile(
                                label: 'Avg Speed',
                                value:
                                    '${_trail.averageSpeedKmh.toStringAsFixed(1)} km/h',
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 22),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            Expanded(
                              child: MetricStatTile(
                                label: 'Elevation',
                                value:
                                    '+${_trail.elevationGainMeters.toStringAsFixed(0)}m / -${_trail.elevationLossMeters.toStringAsFixed(0)}m',
                              ),
                            ),
                            Expanded(
                              child: MetricStatTile(
                                label: 'Points',
                                value: '${_trail.points.length}',
                              ),
                            ),
                            Expanded(
                              child: MetricStatTile(
                                label: 'Accuracy',
                                value: avgAcc != null
                                    ? '±${avgAcc.toStringAsFixed(0)}m'
                                    : '--',
                              ),
                            ),
                          ],
                        ),
                        if (_trail.locationContext.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.location_on_outlined,
                                size: 15,
                                color: scheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  _trail.locationContext,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );

          Widget buildEditorColumn() => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SurfacePanel(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SectionLabel('Route Details'),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _nameController,
                                decoration: const InputDecoration(
                                  labelText: 'Route Name',
                                  isDense: true,
                                ),
                                onSubmitted: (v) {
                                  if (v.trim().isNotEmpty) {
                                    _saveTrail(_trail.copyWith(name: v.trim()));
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonal(
                              onPressed: () {
                                final trimmed = _nameController.text.trim();
                                if (trimmed.isNotEmpty) {
                                  _saveTrail(_trail.copyWith(name: trimmed));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Route name updated'),
                                    ),
                                  );
                                }
                              },
                              child: const Text('Save'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<ActivityType>(
                                isExpanded: true,
                                initialValue: _trail.activityType,
                                decoration: const InputDecoration(
                                  labelText: 'Activity Type',
                                  isDense: true,
                                ),
                                items: ActivityType.values
                                    .map(
                                      (a) => DropdownMenuItem(
                                        value: a,
                                        child: Text(
                                          a.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) {
                                  if (v != null) {
                                    _saveTrail(_trail.copyWith(activityType: v));
                                  }
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: _isGuessing ? null : _guessLocationNow,
                              icon: _isGuessing
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.auto_awesome_outlined,
                                      size: 16,
                                    ),
                              label: const Text('Guess'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  SurfacePanel(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SectionLabel('OSM Route Tags'),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            ActionChip(
                              label: Text(
                                'highway=${_trail.tags['highway'] ?? 'pick'}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _pickOsmAttribute(
                                tagKey: 'highway',
                                title: 'Select OSM highway',
                                options: OsmTagCatalog.allHighwayValues,
                              ),
                            ),
                            ActionChip(
                              label: Text(
                                'surface=${_trail.tags['surface'] ?? 'pick'}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _pickOsmAttribute(
                                tagKey: 'surface',
                                title: 'Select OSM surface',
                                options: OsmTagCatalog.allSurfaceValues,
                              ),
                            ),
                            ActionChip(
                              label: Text(
                                'smoothness=${_trail.tags['smoothness'] ?? 'add'}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _pickOsmAttribute(
                                tagKey: 'smoothness',
                                title: 'Select OSM smoothness',
                                options: OsmTagCatalog.allSmoothnessValues,
                              ),
                            ),
                            ActionChip(
                              label: Text(
                                'sac_scale=${_trail.tags['sac_scale'] ?? 'add'}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _pickOsmAttribute(
                                tagKey: 'sac_scale',
                                title: 'Select OSM sac_scale',
                                options: OsmTagCatalog.allSacScaleValues,
                              ),
                            ),
                            ActionChip(
                              label: Text(
                                'visibility=${_trail.tags['trail_visibility'] ?? 'add'}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _pickOsmAttribute(
                                tagKey: 'trail_visibility',
                                title: 'Select OSM trail_visibility',
                                options: OsmTagCatalog.allTrailVisibilityValues,
                              ),
                            ),
                            ActionChip(
                              label: Text(
                                'wheelchair=${_trail.tags['wheelchair'] ?? 'add'}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _pickOsmAttribute(
                                tagKey: 'wheelchair',
                                title: 'Wheelchair accessibility',
                                options: const [
                                  ('yes', 'Fully wheelchair accessible'),
                                  ('limited', 'Limited accessibility'),
                                  ('no', 'Not wheelchair accessible'),
                                ],
                              ),
                            ),
                            ActionChip(
                              label: Text(
                                'lit=${_trail.tags['lit'] ?? 'add'}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _pickOsmAttribute(
                                tagKey: 'lit',
                                title: 'Lighting at night',
                                options: const [
                                  ('yes', 'Lit at night'),
                                  ('no', 'Not lit'),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  if (linkedRecords.isNotEmpty) ...[
                    SurfacePanel(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SectionLabel(
                            'Linked Pins (${linkedRecords.length})',
                          ),
                          const SizedBox(height: 6),
                          ...linkedRecords.map(
                            (rec) => ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                Icons.place_outlined,
                                color: scheme.primary,
                                size: 20,
                              ),
                              title: Text(
                                rec.displayName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(rec.primaryCategoryTag),
                              trailing: const Icon(
                                Icons.chevron_right_rounded,
                                size: 18,
                              ),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => RecordDetailScreen(
                                      initialRecord: rec,
                                      store: widget.store,
                                      ai: widget.ai,
                                      tiles: widget.tiles,
                                      connectivity: widget.connectivity,
                                      prefs: widget.prefs,
                                      osmPublish: widget.osmPublish,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  FilledButton.icon(
                    onPressed: () => showOsmPublishSheet(
                      context,
                      osm: widget.osmPublish,
                      store: widget.store,
                      prefs: widget.prefs,
                      connectivity: widget.connectivity,
                      trail: _trail,
                      linkedTrailRecords: linkedRecords,
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    icon: const Icon(Icons.publish_rounded, size: 19),
                    label: const Text('Publish Route to OpenStreetMap'),
                  ),
                  const SizedBox(height: 12),

                  SurfacePanel(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      shape: const Border(),
                      title: Text(
                        'GPS Waypoints (${_trail.points.length})',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                      subtitle: Text(
                        'Inspect or remove noisy GPS points',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontSize: 11.5,
                            ),
                      ),
                      children: _trail.points.asMap().entries.map((entry) {
                        final idx = entry.key;
                        final pt = entry.value;
                        final time = DateFormat('HH:mm:ss').format(pt.recordedAt);
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Text(
                            '${idx + 1}',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: scheme.onSurfaceVariant,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                          title: Text(
                            '${pt.latitude.toStringAsFixed(5)}, ${pt.longitude.toStringAsFixed(5)}',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                          subtitle: Text(
                            '$time · ±${pt.accuracyMeters?.toStringAsFixed(0) ?? '?'}m · Alt ${pt.altitudeMeters?.toStringAsFixed(0) ?? '?'}m',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: pt.id != null
                              ? IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 18,
                                  ),
                                  onPressed: () async {
                                    await widget.store
                                        .removeTrailPoint(_trail.id, pt.id!);
                                    final refreshed = widget.store.trails
                                        .where((t) => t.id == _trail.id)
                                        .toList();
                                    if (mounted && refreshed.isNotEmpty) {
                                      setState(() => _trail = refreshed.first);
                                    }
                                  },
                                )
                              : null,
                        );
                      }).toList(),
                    ),
                  ),
                ],
              );

          if (isTwoCol) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: (constraints.maxWidth * 0.45).clamp(340.0, 480.0),
                        child: buildMapAndStatsColumn(),
                      ),
                      const SizedBox(width: 22),
                      Expanded(child: buildEditorColumn()),
                    ],
                  ),
                ),
              ),
            );
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    buildMapAndStatsColumn(),
                    const SizedBox(height: 12),
                    buildEditorColumn(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: BottomActionDock(
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _export('gpx', linkedRecords),
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: const Text('Export GPX'),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: () => showOsmPublishSheet(
                  context,
                  osm: widget.osmPublish,
                  store: widget.store,
                  prefs: widget.prefs,
                  connectivity: widget.connectivity,
                  trail: _trail,
                  linkedTrailRecords: linkedRecords,
                ),
                icon: const Icon(Icons.publish_rounded, size: 19),
                label: const Text('Publish to OSM'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
