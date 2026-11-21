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
import '../services/sensor_service.dart';
import '../services/user_preferences_service.dart';
import '../theme/app_theme.dart';
import '../widgets/firebase_backup_banner.dart';
import '../widgets/gps_warning_banner.dart';
import '../widgets/ham_radio_import_sheet.dart';
import '../widgets/osm_map_widget.dart';
import '../widgets/osm_publish_sheet.dart';
import '../widgets/responsive_layout.dart';
import 'trail_detail_screen.dart';

class TrailScreen extends StatefulWidget {
  final MapperStore store;
  final SensorService sensors;
  final OfflineTileService tiles;
  final ConnectivityService connectivity;
  final UserPreferencesService prefs;
  final HybridAiService ai;
  final OsmPublishService osmPublish;
  final VoidCallback onSnapAlongTrail;

  const TrailScreen({
    super.key,
    required this.store,
    required this.sensors,
    required this.tiles,
    required this.connectivity,
    required this.prefs,
    required this.ai,
    required this.osmPublish,
    required this.onSnapAlongTrail,
  });

  @override
  State<TrailScreen> createState() => _TrailScreenState();
}

class _TrailScreenState extends State<TrailScreen> {
  final TextEditingController _trailNameController = TextEditingController();
  ActivityType _selectedActivity = ActivityType.parkStroll;
  String _selectedHighway = 'footway';
  String _selectedSurface = 'compacted';
  String? _selectedSmoothness;
  String? _selectedLit;
  String? _selectedWheelchair;
  bool _showOptionalTags = false;
  bool _showCustomNameField = false;
  bool _isGuessingLocation = false;
  bool _isSelectionMode = false;
  final Set<String> _selectedTrailIdsForDelete = {};

  void _toggleSelectionMode({bool? enable}) {
    setState(() {
      _isSelectionMode = enable ?? !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedTrailIdsForDelete.clear();
      }
    });
  }

  void _toggleTrailSelection(String id) {
    setState(() {
      if (_selectedTrailIdsForDelete.contains(id)) {
        _selectedTrailIdsForDelete.remove(id);
      } else {
        _selectedTrailIdsForDelete.add(id);
      }
    });
  }

  Future<void> _confirmAndDeleteTrail(HikeTrail trail) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Route?'),
        content: Text(
          'Remove "${trail.name}" from your routes? This cannot be undone.',
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

    await widget.store.deleteTrail(trail.id);
    if (!mounted) return;
    setState(() {
      _selectedTrailIdsForDelete.remove(trail.id);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Removed "${trail.name}"')),
    );
  }

  Future<void> _confirmAndDeleteSelectedTrails() async {
    final count = _selectedTrailIdsForDelete.length;
    if (count == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $count Route${count == 1 ? '' : 's'}?'),
        content: Text(
          'Permanently remove the $count selected route${count == 1 ? '' : 's'}? This cannot be undone.',
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
            child: Text('Remove ($count)'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final toDelete = Set<String>.from(_selectedTrailIdsForDelete);
    await widget.store.deleteTrails(toDelete);
    if (!mounted) return;
    setState(() {
      _selectedTrailIdsForDelete.clear();
      _isSelectionMode = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Removed $count route${count == 1 ? '' : 's'}.'),
      ),
    );
  }

  @override
  void dispose() {
    _trailNameController.dispose();
    super.dispose();
  }

  void _selectActivity(ActivityType type) {
    setState(() {
      _selectedActivity = type;
      _selectedHighway = type.defaultHighway;
      _selectedSurface = type.defaultSurface;
    });
  }

  Future<void> _autoGuessFromCurrentLocation() async {
    if (!widget.connectivity.isOnline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Offline right now — Edge Mapper will auto-guess your route once you go back online!',
          ),
        ),
      );
      return;
    }

    setState(() => _isGuessingLocation = true);
    try {
      final guess = await widget.store.guessCurrentLocationContext();
      if (!mounted) return;
      if (guess != null) {
        setState(() {
          _selectedActivity = guess.activityType;
          _selectedHighway = guess.highway;
          _selectedSurface = guess.surface;
          if (_trailNameController.text.trim().isEmpty) {
            _trailNameController.text = guess.suggestedRouteName;
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Guessed: ${guess.suggestedRouteName} (${guess.activityType.label})',
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Waiting for GPS fix before guessing location.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isGuessingLocation = false);
    }
  }

  Future<void> _pickSearchableOption({
    required String title,
    required List<(String, String)> options,
    required String? currentValue,
    required ValueChanged<String> onSelected,
  }) async {
    final searchCtrl = TextEditingController();
    final chosen = await showAdaptiveSheet<String>(
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
                  child: ModalSheetHeader(
                    title: title,
                    onClose: () => Navigator.pop(ctx),
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
                        trailing: currentValue == opt.$1
                            ? Icon(
                                Icons.check_circle_rounded,
                                color: ctx.semanticColors.success,
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
    if (chosen != null) onSelected(chosen);
  }

  Future<void> _startNewRoute() async {
    final tags = Map<String, String>.from(_selectedActivity.defaultTags);
    tags['highway'] = _selectedHighway;
    tags['surface'] = _selectedSurface;
    if (_selectedSmoothness != null) tags['smoothness'] = _selectedSmoothness!;
    if (_selectedLit != null) tags['lit'] = _selectedLit!;
    if (_selectedWheelchair != null) tags['wheelchair'] = _selectedWheelchair!;

    await widget.store.startTrail(
      name: _trailNameController.text.trim(),
      activityType: _selectedActivity,
      tags: tags,
    );
    _trailNameController.clear();
  }

  Future<void> _finishActiveRoute() async {
    await widget.store.stopActiveTrail();
  }

  Future<void> _openHamRadioImport() async {
    final imported = await showHamRadioImportSheet(
      context,
      store: widget.store,
      initialActivity: _selectedActivity,
    );
    if (!mounted || imported == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Imported "${imported.name}" (${imported.points.length} pts · ${_formatDistance(imported.totalDistanceMeters)})!',
        ),
        action: SnackBarAction(
          label: 'Review',
          onPressed: () => _openTrailDetail(imported),
        ),
      ),
    );
    _openTrailDetail(imported);
  }

  void _openTrailDetail(HikeTrail trail) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TrailDetailScreen(
          initialTrail: trail,
          store: widget.store,
          tiles: widget.tiles,
          connectivity: widget.connectivity,
          prefs: widget.prefs,
          ai: widget.ai,
          osmPublish: widget.osmPublish,
        ),
      ),
    );
  }

  Future<void> _exportTrail(HikeTrail trail, String format) async {
    final linked =
        widget.store.records.where((r) => r.trailId == trail.id).toList();
    final safeName = trail.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final baseName = safeName.isEmpty ? 'edge_mapper_route' : safeName;

    if (format == 'gpx') {
      final gpx = OsmExportService.buildGpx(records: linked, trails: [trail]);
      await OsmExportService.shareExport(
        content: gpx,
        fileName: '$baseName.gpx',
        subject: 'Edge Mapper GPX: ${trail.name}',
      );
    } else if (format == 'osm') {
      final osm =
          OsmExportService.buildOsmXml(records: linked, trails: [trail]);
      await OsmExportService.shareExport(
        content: osm,
        fileName: '$baseName.osm',
        subject: 'Edge Mapper OSM XML: ${trail.name}',
      );
    } else {
      final geo =
          OsmExportService.buildGeoJson(records: linked, trails: [trail]);
      await OsmExportService.shareExport(
        content: geo,
        fileName: '$baseName.geojson',
        subject: 'Edge Mapper GeoJSON: ${trail.name}',
      );
    }
  }

  IconData _iconForActivity(ActivityType type) => switch (type) {
        ActivityType.urbanWalk => Icons.directions_walk_rounded,
        ActivityType.parkStroll => Icons.park_rounded,
        ActivityType.hiking => Icons.hiking_rounded,
        ActivityType.natureWalk => Icons.forest_rounded,
        ActivityType.cycling => Icons.directions_bike_rounded,
        ActivityType.running => Icons.directions_run_rounded,
        ActivityType.wheelchair => Icons.accessible_rounded,
        ActivityType.stairway => Icons.stairs_rounded,
        ActivityType.sharedTrack => Icons.agriculture_rounded,
      };

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
    final semantic = context.semanticColors;
    final textTheme = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    final isSplitLayout = width >= AppBreakpoints.expanded;
    final isCompact = AppBreakpoints.isCompact(context);
    final optionalTagsSetCount = [
      _selectedSmoothness,
      _selectedWheelchair,
      _selectedLit,
    ].whereType<String>().length;

    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.store,
        widget.sensors,
        widget.connectivity,
        widget.prefs,
      ]),
      builder: (context, _) {
        final active = widget.store.activeTrail;
        final savedTrails =
            widget.store.trails.where((t) => !t.isActive).toList();
        final activeLinkedRecords = active == null
            ? const <OsmRecord>[]
            : widget.store.records
                .where((r) => r.trailId == active.id)
                .toList();
        final pos = widget.sensors.currentPosition;
        final gpsQuality = widget.sensors.gpsQuality;

        Widget buildMap({required double height}) => OsmMapWidget(
              tileService: widget.tiles,
              isOnline: widget.connectivity.isOnline,
              userLat: pos?.latitude,
              userLon: pos?.longitude,
              userAccuracyMeters: pos?.accuracy,
              userHeadingDegrees: widget.sensors.headingDegrees,
              gpsQuality: gpsQuality,
              routePoints: active?.points ?? const [],
              pins: activeLinkedRecords,
              height: height,
              downloadRadiusKm: widget.prefs.offlineMapRadiusKm,
            );

        Widget buildControlsAndList({required bool includeInlineMap}) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GpsWarningBanner(
                  report: gpsQuality,
                  onRefreshGps: widget.sensors.ensureLocationPermissionAndFix,
                ),

                if (includeInlineMap) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.lg),
                    child: buildMap(height: active != null ? 240 : 204),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],

                // Active Route Recorder OR Start New Route Panel
                SurfacePanel(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  borderColor: active != null
                      ? scheme.primary.withValues(alpha: 0.45)
                      : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            active != null
                                ? Icons.fiber_manual_record_rounded
                                : _iconForActivity(_selectedActivity),
                            size: active != null ? 14 : 20,
                            color: active != null
                                ? semantic.danger
                                : scheme.primary,
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          Expanded(
                            child: Text(
                              active != null
                                  ? 'Recording · ${active.name}'
                                  : 'New Route',
                              style: textTheme.titleMedium,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      if (active != null) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            MetricStatTile(
                              label: 'Distance',
                              value: _formatDistance(
                                active.totalDistanceMeters,
                              ),
                            ),
                            MetricStatTile(
                              label: 'Duration',
                              value: _formatDuration(active.duration),
                            ),
                            MetricStatTile(
                              label: 'Points',
                              value: '${active.points.length}',
                            ),
                            MetricStatTile(
                              label: 'Pins',
                              value: '${activeLinkedRecords.length}',
                            ),
                          ],
                        ),
                        if (!isCompact) ...[
                          const SizedBox(height: AppSpacing.md),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.tonalIcon(
                                  onPressed: widget.onSnapAlongTrail,
                                  icon: const Icon(
                                    Icons.camera_alt_outlined,
                                    size: 18,
                                  ),
                                  label: const Text('Capture Pin'),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: widget.store.addManualTrailWaypoint,
                                  icon: const Icon(
                                    Icons.my_location_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Mark Point'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: semantic.danger,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _finishActiveRoute,
                            icon: const Icon(
                              Icons.stop_circle_outlined,
                              size: 19,
                            ),
                            label: const Text('Finish & Save Route'),
                          ),
                        ],
                      ] else ...[
                        SizedBox(
                          height: 36,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: ActivityType.values.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: AppSpacing.xs),
                            itemBuilder: (_, idx) {
                              final act = ActivityType.values[idx];
                              return ChoiceChip(
                                avatar: Icon(_iconForActivity(act), size: 16),
                                label: Text(act.shortLabel),
                                visualDensity: VisualDensity.compact,
                                selected: _selectedActivity == act,
                                onSelected: (_) => _selectActivity(act),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        if (_showCustomNameField ||
                            _trailNameController.text.trim().isNotEmpty)
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _trailNameController,
                                  textInputAction: TextInputAction.done,
                                  onChanged: (_) => setState(() {}),
                                  decoration: InputDecoration(
                                    hintText: 'Route name (auto-named if blank)',
                                    isDense: true,
                                    suffixIcon: IconButton(
                                      tooltip: 'Done',
                                      icon: const Icon(
                                        Icons.check_rounded,
                                        size: 18,
                                      ),
                                      onPressed: () => setState(
                                        () => _showCustomNameField = false,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              IconButton.outlined(
                                tooltip: 'Guess route name & type from GPS',
                                onPressed: _isGuessingLocation
                                    ? null
                                    : _autoGuessFromCurrentLocation,
                                icon: _isGuessingLocation
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.auto_awesome_outlined,
                                        size: 19,
                                      ),
                              ),
                            ],
                          )
                        else
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerLow,
                              borderRadius: BorderRadius.circular(AppRadii.md),
                              border: Border.all(color: scheme.outlineVariant),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.auto_awesome_outlined,
                                  size: 16,
                                  color: scheme.primary,
                                ),
                                const SizedBox(width: AppSpacing.xs),
                                Expanded(
                                  child: Text(
                                    'Auto-named ${_selectedActivity.shortLabel}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurface,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: _isGuessingLocation
                                      ? null
                                      : _autoGuessFromCurrentLocation,
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                  ),
                                  child: Text(
                                    _isGuessingLocation
                                        ? 'Guessing...'
                                        : 'Guess',
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Rename route',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => setState(
                                    () => _showCustomNameField = true,
                                  ),
                                  icon: Icon(
                                    Icons.edit_outlined,
                                    size: 17,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: 6,
                          children: [
                            ActionChip(
                              label: Text('highway=$_selectedHighway'),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _pickSearchableOption(
                                title: 'OSM Highway Type',
                                options: OsmTagCatalog.allHighwayValues,
                                currentValue: _selectedHighway,
                                onSelected: (v) =>
                                    setState(() => _selectedHighway = v),
                              ),
                            ),
                            ActionChip(
                              label: Text('surface=$_selectedSurface'),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => _pickSearchableOption(
                                title: 'OSM Surface',
                                options: OsmTagCatalog.allSurfaceValues,
                                currentValue: _selectedSurface,
                                onSelected: (v) =>
                                    setState(() => _selectedSurface = v),
                              ),
                            ),
                            if (_showOptionalTags ||
                                _selectedSmoothness != null)
                              ActionChip(
                                label: Text(
                                  _selectedSmoothness != null
                                      ? 'smoothness=$_selectedSmoothness'
                                      : '+ smoothness',
                                ),
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _pickSearchableOption(
                                  title: 'OSM Smoothness',
                                  options: OsmTagCatalog.allSmoothnessValues,
                                  currentValue: _selectedSmoothness,
                                  onSelected: (v) =>
                                      setState(() => _selectedSmoothness = v),
                                ),
                              ),
                            if (_showOptionalTags ||
                                _selectedWheelchair != null)
                              ActionChip(
                                label: Text(
                                  _selectedWheelchair != null
                                      ? 'wheelchair=$_selectedWheelchair'
                                      : '+ wheelchair',
                                ),
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _pickSearchableOption(
                                  title: 'Wheelchair Accessibility',
                                  options: const [
                                    ('yes', 'Wheelchair accessible'),
                                    ('limited', 'Limited accessibility'),
                                    ('no', 'Not accessible'),
                                  ],
                                  currentValue: _selectedWheelchair,
                                  onSelected: (v) =>
                                      setState(() => _selectedWheelchair = v),
                                ),
                              ),
                            if (_showOptionalTags || _selectedLit != null)
                              ActionChip(
                                label: Text(
                                  _selectedLit != null
                                      ? 'lit=$_selectedLit'
                                      : '+ lit',
                                ),
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _pickSearchableOption(
                                  title: 'Street / Path Lighting',
                                  options: const [
                                    ('yes', 'Lit at night'),
                                    ('no', 'Unlit at night'),
                                  ],
                                  currentValue: _selectedLit,
                                  onSelected: (v) =>
                                      setState(() => _selectedLit = v),
                                ),
                              ),
                            ActionChip(
                              avatar: Icon(
                                _showOptionalTags
                                    ? Icons.expand_less_rounded
                                    : Icons.tune_rounded,
                                size: 15,
                              ),
                              label: Text(
                                _showOptionalTags
                                    ? 'Less tags'
                                    : (optionalTagsSetCount > 0
                                        ? 'More tags ($optionalTagsSetCount)'
                                        : 'More tags'),
                              ),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => setState(
                                () => _showOptionalTags = !_showOptionalTags,
                              ),
                            ),
                          ],
                        ),
                        if (!isCompact) ...[
                          const SizedBox(height: AppSpacing.md),
                          FilledButton.icon(
                            onPressed: _startNewRoute,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(double.infinity, 48),
                            ),
                            icon:
                                const Icon(Icons.play_arrow_rounded, size: 20),
                            label: Text(
                              'Start ${_selectedActivity.shortLabel}',
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: AppSpacing.lg),
                SectionLabel(
                  'Saved Routes (${savedTrails.length})',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (savedTrails.isNotEmpty)
                        IconButton(
                          tooltip: _isSelectionMode
                              ? 'Done selecting'
                              : 'Select routes',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _toggleSelectionMode(),
                          icon: Icon(
                            _isSelectionMode
                                ? Icons.close_rounded
                                : Icons.checklist_rounded,
                            size: 19,
                            color: _isSelectionMode ? scheme.primary : null,
                          ),
                        ),
                      TextButton.icon(
                        onPressed: _openHamRadioImport,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(
                          Icons.settings_input_antenna_rounded,
                          size: 16,
                        ),
                        label: const Text('Import GPS'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),

                // Multi-select removal bar on non-compact screens (compact uses thumb dock)
                if (_isSelectionMode && !isCompact && savedTrails.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: AppSpacing.xs),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: semantic.dangerContainer,
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      border: Border.all(
                        color: semantic.danger.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(
                          '${_selectedTrailIdsForDelete.length} selected',
                          style: textTheme.labelLarge?.copyWith(
                            color: semantic.onDangerContainer,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              final visibleIds =
                                  savedTrails.map((t) => t.id).toSet();
                              if (_selectedTrailIdsForDelete
                                      .containsAll(visibleIds) &&
                                  visibleIds.isNotEmpty) {
                                _selectedTrailIdsForDelete
                                    .removeAll(visibleIds);
                              } else {
                                _selectedTrailIdsForDelete.addAll(visibleIds);
                              }
                            });
                          },
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          child: Text(
                            _selectedTrailIdsForDelete.containsAll(
                              savedTrails.map((t) => t.id),
                            )
                                ? 'Clear'
                                : 'Select All',
                          ),
                        ),
                        const SizedBox(width: 4),
                        FilledButton.icon(
                          onPressed: _selectedTrailIdsForDelete.isEmpty
                              ? null
                              : _confirmAndDeleteSelectedTrails,
                          style: FilledButton.styleFrom(
                            backgroundColor: scheme.error,
                            foregroundColor: scheme.onError,
                            visualDensity: VisualDensity.compact,
                            minimumSize: const Size(0, 34),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 16,
                          ),
                          label: Text(
                            'Remove (${_selectedTrailIdsForDelete.length})',
                          ),
                        ),
                      ],
                    ),
                  ),

                if (savedTrails.isEmpty)
                  SurfacePanel(
                    padding: EdgeInsets.zero,
                    child: EmptyStateCard(
                      icon: Icons.route_outlined,
                      title: 'No routes recorded yet',
                      description:
                          'Start a walk, stroll, or hike above, or import an external GPS track (NMEA, APRS, GPX, KML, CSV).',
                      action: OutlinedButton.icon(
                        onPressed: _openHamRadioImport,
                        icon: const Icon(
                          Icons.settings_input_antenna_rounded,
                          size: 17,
                        ),
                        label: const Text('Import External GPS Track'),
                      ),
                    ),
                  )
                else
                  ...savedTrails.map((trail) {
                    final linkedCount = widget.store.records
                        .where((r) => r.trailId == trail.id)
                        .length;
                    final dateStr =
                        DateFormat('MMM d · HH:mm').format(trail.startedAt);
                    final isChecked =
                        _selectedTrailIdsForDelete.contains(trail.id);
                    final isSelected = _isSelectionMode && isChecked;
                    return Container(
                      margin: const EdgeInsets.only(bottom: AppSpacing.xs),
                      child: Material(
                        color: isSelected
                            ? scheme.primaryContainer.withValues(alpha: 0.35)
                            : scheme.surfaceContainerLowest,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadii.md),
                          side: BorderSide(
                            color: isSelected
                                ? scheme.primary
                                : scheme.outlineVariant,
                            width: isSelected ? 1.5 : 1,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => _isSelectionMode
                              ? _toggleTrailSelection(trail.id)
                              : _openTrailDetail(trail),
                          onLongPress: _isSelectionMode
                              ? null
                              : () {
                                  _toggleSelectionMode(enable: true);
                                  _toggleTrailSelection(trail.id);
                                },
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.sm),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    if (_isSelectionMode) ...[
                                      Checkbox(
                                        value: isChecked,
                                        onChanged: (_) =>
                                            _toggleTrailSelection(trail.id),
                                        visualDensity: VisualDensity.compact,
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      const SizedBox(width: 2),
                                    ],
                                    Container(
                                      width: 38,
                                      height: 38,
                                      decoration: BoxDecoration(
                                        color: scheme.primary
                                            .withValues(alpha: 0.1),
                                        borderRadius:
                                            BorderRadius.circular(AppRadii.sm),
                                      ),
                                      child: Icon(
                                        _iconForActivity(trail.activityType),
                                        size: 19,
                                        color: scheme.primary,
                                      ),
                                    ),
                                    const SizedBox(width: AppSpacing.sm),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            trail.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: textTheme.titleSmall,
                                          ),
                                          const SizedBox(height: 1),
                                          Text(
                                            '${trail.activityType.shortLabel} · $dateStr',
                                            style: textTheme.bodySmall,
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (!_isSelectionMode) ...[
                                      IconButton(
                                        tooltip: 'Remove route',
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () =>
                                            _confirmAndDeleteTrail(trail),
                                        icon: Icon(
                                          Icons.delete_outline_rounded,
                                          size: 19,
                                          color: scheme.onSurfaceVariant
                                              .withValues(alpha: 0.75),
                                        ),
                                      ),
                                      PopupMenuButton<String>(
                                        iconSize: 20,
                                        onSelected: (action) {
                                          if (action == 'review') {
                                            _openTrailDetail(trail);
                                          } else if (action == 'publish_osm') {
                                            final linked = widget.store.records
                                                .where(
                                                  (r) => r.trailId == trail.id,
                                                )
                                                .toList();
                                            showOsmPublishSheet(
                                              context,
                                              osm: widget.osmPublish,
                                              store: widget.store,
                                              prefs: widget.prefs,
                                              connectivity: widget.connectivity,
                                              trail: trail,
                                              linkedTrailRecords: linked,
                                            );
                                          } else {
                                            _exportTrail(trail, action);
                                          }
                                        },
                                        itemBuilder: (_) => const [
                                          PopupMenuItem(
                                            value: 'review',
                                            child: Text('Review & Edit'),
                                          ),
                                          PopupMenuItem(
                                            value: 'publish_osm',
                                            child: Text(
                                              'Publish to OpenStreetMap',
                                            ),
                                          ),
                                          PopupMenuDivider(),
                                          PopupMenuItem(
                                            value: 'osm',
                                            child: Text('Export OSM XML (.osm)'),
                                          ),
                                          PopupMenuItem(
                                            value: 'gpx',
                                            child: Text('Export GPX (.gpx)'),
                                          ),
                                          PopupMenuItem(
                                            value: 'geojson',
                                            child: Text('Export GeoJSON'),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: AppSpacing.xs),
                                Text(
                                  '${_formatDistance(trail.totalDistanceMeters)} · '
                                  '${trail.points.length} pts · '
                                  '+${trail.elevationGainMeters.toStringAsFixed(0)}m · '
                                  '$linkedCount pins'
                                  '${trail.needsLocationGuess ? ' · Pending guess' : ''}',
                                  style: textTheme.bodySmall?.copyWith(
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
              ],
            );

        if (isSplitLayout) {
          final inspectorWidth = (width * 0.36).clamp(340.0, 420.0);
          return Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: LayoutBuilder(
                    builder: (context, constraints) => ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.lg),
                      child: buildMap(height: constraints.maxHeight),
                    ),
                  ),
                ),
              ),
              Container(
                width: inspectorWidth,
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border(
                    left: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                child: Column(
                  children: [
                    FirebaseBackupBanner(store: widget.store),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: buildControlsAndList(includeInlineMap: false),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }

        final hPad = AppBreakpoints.horizontalPadding(context);
        final scrollable = SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            0,
            4,
            0,
            isCompact ? AppSpacing.md : AppSpacing.xl,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 660),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FirebaseBackupBanner(store: widget.store),
                  Padding(
                    padding: EdgeInsets.fromLTRB(hPad, AppSpacing.sm, hPad, 0),
                    child: buildControlsAndList(includeInlineMap: true),
                  ),
                ],
              ),
            ),
          ),
        );

        if (!isCompact) return scrollable;

        // Compact phone: sticky thumb-zone controls (multi-select removal mirrors RecordsScreen!)
        return Column(
          children: [
            Expanded(child: scrollable),
            BottomActionDock(
              safeAreaBottom: false,
              child: _isSelectionMode
                  ? Row(
                      children: [
                        TextButton(
                          onPressed: () =>
                              _toggleSelectionMode(enable: false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              final visibleIds =
                                  savedTrails.map((t) => t.id).toSet();
                              if (_selectedTrailIdsForDelete
                                      .containsAll(visibleIds) &&
                                  visibleIds.isNotEmpty) {
                                _selectedTrailIdsForDelete
                                    .removeAll(visibleIds);
                              } else {
                                _selectedTrailIdsForDelete.addAll(visibleIds);
                              }
                            });
                          },
                          child: Text(
                            savedTrails.isNotEmpty &&
                                    _selectedTrailIdsForDelete.containsAll(
                                      savedTrails.map((t) => t.id),
                                    )
                                ? 'Clear'
                                : 'All',
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _selectedTrailIdsForDelete.isEmpty
                                ? null
                                : _confirmAndDeleteSelectedTrails,
                            style: FilledButton.styleFrom(
                              backgroundColor: scheme.error,
                              foregroundColor: scheme.onError,
                            ),
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                            ),
                            label: Text(
                              'Remove (${_selectedTrailIdsForDelete.length})',
                            ),
                          ),
                        ),
                      ],
                    )
                  : active != null
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.tonalIcon(
                                    onPressed: widget.onSnapAlongTrail,
                                    style: FilledButton.styleFrom(
                                      minimumSize: const Size(0, 44),
                                    ),
                                    icon: const Icon(
                                      Icons.camera_alt_outlined,
                                      size: 18,
                                    ),
                                    label: const Text('Capture Pin'),
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.xs),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed:
                                        widget.store.addManualTrailWaypoint,
                                    style: OutlinedButton.styleFrom(
                                      minimumSize: const Size(0, 44),
                                    ),
                                    icon: const Icon(
                                      Icons.my_location_rounded,
                                      size: 18,
                                    ),
                                    label: const Text('Mark Point'),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: semantic.danger,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: _finishActiveRoute,
                              icon: const Icon(
                                Icons.stop_circle_outlined,
                                size: 19,
                              ),
                              label: const Text('Finish & Save Route'),
                            ),
                          ],
                        )
                      : SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _startNewRoute,
                            icon: const Icon(Icons.play_arrow_rounded, size: 21),
                            label: Text('Start ${_selectedActivity.shortLabel}'),
                          ),
                        ),
            ),
          ],
        );
      },
    );
  }
}
