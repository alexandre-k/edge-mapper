import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/enrichment_diff.dart';
import '../models/osm_record.dart';
import '../services/connectivity_service.dart';
import '../services/hybrid_ai_service.dart';
import '../services/mapper_store.dart';
import '../services/offline_tile_service.dart';
import '../services/osm_export_service.dart';
import '../services/osm_publish_service.dart';
import '../services/photo_helper.dart';
import '../services/user_preferences_service.dart';
import '../theme/app_theme.dart';
import '../widgets/enrichment_diff_sheet.dart';
import '../widgets/firebase_backup_banner.dart';
import '../widgets/osm_publish_sheet.dart';
import '../widgets/responsive_layout.dart';
import 'record_detail_screen.dart';

class RecordsScreen extends StatefulWidget {
  final MapperStore store;
  final HybridAiService ai;
  final OfflineTileService tiles;
  final ConnectivityService connectivity;
  final UserPreferencesService prefs;
  final OsmPublishService osmPublish;
  final VoidCallback? onCaptureFirstPlace;

  const RecordsScreen({
    super.key,
    required this.store,
    required this.ai,
    required this.tiles,
    required this.connectivity,
    required this.prefs,
    required this.osmPublish,
    this.onCaptureFirstPlace,
  });

  @override
  State<RecordsScreen> createState() => _RecordsScreenState();
}

class _RecordsScreenState extends State<RecordsScreen> {
  RecordStatus? _filterStatus;
  String? _selectedRecordId;
  bool _isSelectionMode = false;
  final Set<String> _selectedIdsForDelete = {};

  void _toggleSelectionMode({bool? enable}) {
    setState(() {
      _isSelectionMode = enable ?? !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedIdsForDelete.clear();
      }
    });
  }

  void _toggleRecordSelection(String id) {
    setState(() {
      if (_selectedIdsForDelete.contains(id)) {
        _selectedIdsForDelete.remove(id);
      } else {
        _selectedIdsForDelete.add(id);
      }
    });
  }

  Future<void> _confirmAndDeleteRecord(OsmRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Record?'),
        content: Text(
          'Remove "${record.displayName}" from your records? This cannot be undone.',
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

    await widget.store.deleteRecord(record.id);
    if (!mounted) return;
    setState(() {
      if (_selectedRecordId == record.id) _selectedRecordId = null;
      _selectedIdsForDelete.remove(record.id);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Removed "${record.displayName}"')),
    );
  }

  Future<void> _confirmAndDeleteSelected() async {
    final count = _selectedIdsForDelete.length;
    if (count == 0) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $count Record${count == 1 ? '' : 's'}?'),
        content: Text(
          'Permanently remove the $count selected record${count == 1 ? '' : 's'} and attached photos? This cannot be undone.',
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

    final toDelete = Set<String>.from(_selectedIdsForDelete);
    await widget.store.deleteRecords(toDelete);
    if (!mounted) return;
    setState(() {
      if (_selectedRecordId != null && toDelete.contains(_selectedRecordId)) {
        _selectedRecordId = null;
      }
      _selectedIdsForDelete.clear();
      _isSelectionMode = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Removed $count record${count == 1 ? '' : 's'}.'),
      ),
    );
  }

  Future<void> _openPendingBatchReview({int failedCount = 0}) async {
    if (widget.store.pendingBatchDiffs.isEmpty) return;
    await showBatchEnrichmentDiffSheet(
      context,
      store: widget.store,
    );
    if (!mounted) return;

    final remainingCount = widget.store.pendingBatchDiffs.length;

    final parts = <String>[
      if (remainingCount > 0)
        '$remainingCount AI recommendation(s) saved — tap Review to continue.',
      if (failedCount > 0)
        '$failedCount draft(s) failed — tap Enrich to retry remaining drafts.',
    ];
    if (parts.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        content: Text(parts.join(' ')),
      ),
    );
  }

  Future<void> _batchEnrichWithDiffReview(AiUpdateMode mode) async {
    final diffs = await widget.store.generateBatchEnrichmentDiffs(mode: mode);
    if (!mounted) return;
    final failedCount = widget.store.batchEnrichFailed;
    final wasCancelled = widget.store.batchEnrichCancelled;

    if (diffs.isEmpty) {
      final err = widget.store.lastBatchEnrichError;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 7),
          content: Text(
            wasCancelled
                ? 'Batch AI enrichment stopped before any results were returned.'
                : err != null
                    ? 'AI enrichment failed: $err'
                    : 'No AI enrichment recommendations returned.',
          ),
        ),
      );
      return;
    }

    await _openPendingBatchReview(failedCount: failedCount);
  }

  Future<void> _exportCollection(String format) async {
    final records = widget.store.records;
    final trails = widget.store.trails;
    if (records.isEmpty && trails.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing to export yet.')),
      );
      return;
    }

    final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    if (format == 'osm') {
      final xml =
          OsmExportService.buildOsmXml(records: records, trails: trails);
      await OsmExportService.shareExport(
        content: xml,
        fileName: 'edge_mapper_$stamp.osm',
        subject: 'Edge Mapper OSM Collection (${records.length} records)',
      );
    } else if (format == 'gpx') {
      final gpx = OsmExportService.buildGpx(records: records, trails: trails);
      await OsmExportService.shareExport(
        content: gpx,
        fileName: 'edge_mapper_$stamp.gpx',
        subject: 'Edge Mapper GPX Export',
      );
    } else {
      final geo =
          OsmExportService.buildGeoJson(records: records, trails: trails);
      await OsmExportService.shareExport(
        content: geo,
        fileName: 'edge_mapper_$stamp.geojson',
        subject: 'Edge Mapper GeoJSON Export',
      );
    }
  }

  void _openRecord(OsmRecord record, {required bool isMasterDetail}) {
    if (isMasterDetail) {
      setState(() => _selectedRecordId = record.id);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RecordDetailScreen(
          initialRecord: record,
          store: widget.store,
          ai: widget.ai,
          tiles: widget.tiles,
          connectivity: widget.connectivity,
          prefs: widget.prefs,
          osmPublish: widget.osmPublish,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semanticColors;
    final textTheme = Theme.of(context).textTheme;
    final sizeClass = AppBreakpoints.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final textScale = AppBreakpoints.textScale(context);
    final isMasterDetail = sizeClass == ScreenSizeClass.expanded;
    final isTabletGrid = sizeClass == ScreenSizeClass.medium;
    final isCompact = sizeClass == ScreenSizeClass.compact;

    return ListenableBuilder(
      listenable: Listenable.merge([widget.store, widget.ai]),
      builder: (context, _) {
        final allRecords = widget.store.records;
        final offlineDrafts = widget.store.offlineDraftRecords;
        final pendingDiffs = widget.store.pendingBatchDiffs;
        final filtered = _filterStatus == null
            ? allRecords
            : allRecords.where((r) => r.status == _filterStatus).toList();

        OsmRecord? selectedRecord;
        if (isMasterDetail && filtered.isNotEmpty) {
          selectedRecord = filtered.firstWhere(
            (r) => r.id == _selectedRecordId,
            orElse: () => filtered.first,
          );
        }

        Widget buildListPane() => Column(
              children: [
                // Header bar on tablet/desktop (compact phone AppBar already displays "Records")
                if (!isCompact)
                  Container(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      10,
                      AppSpacing.xs,
                      10,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLowest,
                      border: Border(
                        bottom: BorderSide(color: scheme.outlineVariant),
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(
                          'Records',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        SubtleTag(label: '${allRecords.length}'),
                        const Spacer(),
                        IconButton(
                          tooltip: _isSelectionMode
                              ? 'Done selecting'
                              : 'Select records',
                          icon: Icon(
                            _isSelectionMode
                                ? Icons.close_rounded
                                : Icons.checklist_rounded,
                            size: 20,
                            color: _isSelectionMode ? scheme.primary : null,
                          ),
                          onPressed: allRecords.isEmpty
                              ? null
                              : () => _toggleSelectionMode(),
                        ),
                        IconButton(
                          tooltip: 'Publish to OpenStreetMap',
                          icon: const Icon(Icons.publish_rounded, size: 20),
                          onPressed: allRecords.isEmpty
                              ? null
                              : () => showOsmPublishSheet(
                                    context,
                                    osm: widget.osmPublish,
                                    store: widget.store,
                                    prefs: widget.prefs,
                                    connectivity: widget.connectivity,
                                    initialRecords: filtered.isNotEmpty
                                        ? filtered
                                        : allRecords,
                                  ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'Export collection',
                          icon: const Icon(Icons.ios_share_rounded, size: 19),
                          onSelected: _exportCollection,
                          itemBuilder: (_) => const [
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
                    ),
                  ),

                FirebaseBackupBanner(store: widget.store),

                // Pending AI review notice
                if (pendingDiffs.isNotEmpty && !widget.store.isEnrichingBatch)
                  InlineNoticeBanner(
                    margin: const EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      10,
                      AppSpacing.md,
                      0,
                    ),
                    tone: NoticeTone.info,
                    icon: Icons.rate_review_outlined,
                    title: '${pendingDiffs.length} AI review ready',
                    action: FilledButton(
                      onPressed: _openPendingBatchReview,
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      child: const Text('Review'),
                    ),
                    onDismiss: widget.store.clearPendingBatchDiffs,
                  ),

                // Batch AI enrichment strip (Nano 4 or Cloud AI)
                if (offlineDrafts.isNotEmpty && widget.ai.canEnrichRecords)
                  SurfacePanel(
                    margin: const EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      10,
                      AppSpacing.md,
                      0,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: 10,
                    ),
                    radius: AppRadii.md,
                    child: widget.store.isEnrichingBatch
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LinearProgressIndicator(
                                value: widget.store.batchEnrichTotal > 0
                                    ? widget.store.batchEnrichDone /
                                        widget.store.batchEnrichTotal
                                    : null,
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      widget.store.batchEnrichStatus.isNotEmpty
                                          ? widget.store.batchEnrichStatus
                                          : '${widget.store.batchEnrichDone}/${widget.store.batchEnrichTotal}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.labelMedium,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: widget.store.batchEnrichCancelled
                                        ? null
                                        : widget.store.cancelBatchEnrichment,
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    child: Text(
                                      widget.store.batchEnrichCancelled
                                          ? 'Stopping'
                                          : 'Stop',
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    widget.ai.willEnrichUseNanoFirst
                                        ? Icons.bolt_rounded
                                        : Icons.auto_awesome_outlined,
                                    size: 18,
                                    color: scheme.primary,
                                  ),
                                  const SizedBox(width: AppSpacing.xs),
                                  Expanded(
                                    child: Text(
                                      widget.ai.willEnrichUseNanoFirst
                                          ? '${offlineDrafts.length} local · Nano 4'
                                          : '${offlineDrafts.length} local · Cloud AI',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.labelLarge,
                                    ),
                                  ),
                                  Tooltip(
                                    message:
                                        'Keeps your existing tags and only fills missing ones',
                                    child: FilledButton.icon(
                                      onPressed: () =>
                                          _batchEnrichWithDiffReview(
                                        AiUpdateMode.enrichMerge,
                                      ),
                                      style: FilledButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        minimumSize: const Size(0, 34),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.playlist_add_rounded,
                                        size: 15,
                                      ),
                                      label: const Text('Add Missing'),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Tooltip(
                                    message:
                                        'Clears existing tags and re-analyzes everything from scratch',
                                    child: OutlinedButton.icon(
                                      onPressed: () =>
                                          _batchEnrichWithDiffReview(
                                        AiUpdateMode.overwriteAll,
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        minimumSize: const Size(0, 34),
                                        foregroundColor: semantic.warning,
                                        side: BorderSide(
                                          color: semantic.warning
                                              .withValues(alpha: 0.45),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 9,
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.restart_alt_rounded,
                                        size: 15,
                                      ),
                                      label: const Text('Reset All'),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Add Missing keeps existing tags · Reset All rebuilds from scratch',
                                style: textTheme.labelSmall,
                              ),
                            ],
                          ),
                  ),

                // Dedicated unobstructed filter chip strip
                SizedBox(
                  height: 50,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.xs,
                    ),
                    children: [
                      ChoiceChip(
                        label: Text('All (${allRecords.length})'),
                        selected: _filterStatus == null,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(() => _filterStatus = null),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      ChoiceChip(
                        label: const Text('Enriched'),
                        selected: _filterStatus == RecordStatus.aiEnriched,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(
                          () => _filterStatus = RecordStatus.aiEnriched,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      ChoiceChip(
                        label: const Text('Submitted'),
                        selected: _filterStatus == RecordStatus.uploaded,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(
                          () => _filterStatus = RecordStatus.uploaded,
                        ),
                      ),
                    ],
                  ),
                ),

                // Multi-select removal bar on non-compact screens (compact uses thumb dock)
                if (_isSelectionMode && !isCompact)
                  Container(
                    margin: const EdgeInsets.fromLTRB(
                      AppSpacing.md,
                      0,
                      AppSpacing.md,
                      AppSpacing.xs,
                    ),
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
                          '${_selectedIdsForDelete.length} selected',
                          style: textTheme.labelLarge?.copyWith(
                            color: semantic.onDangerContainer,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              final visibleIds =
                                  filtered.map((r) => r.id).toSet();
                              if (_selectedIdsForDelete
                                      .containsAll(visibleIds) &&
                                  visibleIds.isNotEmpty) {
                                _selectedIdsForDelete.removeAll(visibleIds);
                              } else {
                                _selectedIdsForDelete.addAll(visibleIds);
                              }
                            });
                          },
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          child: Text(
                            filtered.isNotEmpty &&
                                    _selectedIdsForDelete.containsAll(
                                      filtered.map((r) => r.id),
                                    )
                                ? 'Clear'
                                : 'Select All',
                          ),
                        ),
                        const SizedBox(width: 4),
                        FilledButton.icon(
                          onPressed: _selectedIdsForDelete.isEmpty
                              ? null
                              : _confirmAndDeleteSelected,
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
                            'Remove (${_selectedIdsForDelete.length})',
                          ),
                        ),
                      ],
                    ),
                  ),

                // Records List / Grid
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: EmptyStateCard(
                            icon: Icons.layers_outlined,
                            title: allRecords.isEmpty
                                ? 'No records yet'
                                : 'No matching records',
                            description: allRecords.isEmpty
                                ? 'Capture a place to inspect photos, edit tags, and publish to OpenStreetMap.'
                                : 'Switch the status filter above to view your other saved places.',
                            action: allRecords.isEmpty &&
                                    widget.onCaptureFirstPlace != null
                                ? FilledButton.icon(
                                    onPressed: widget.onCaptureFirstPlace,
                                    icon: const Icon(
                                      Icons.add_a_photo_outlined,
                                      size: 18,
                                    ),
                                    label: const Text('Capture Place'),
                                  )
                                : null,
                          ),
                        )
                      : isTabletGrid
                          ? GridView.builder(
                              padding: const EdgeInsets.fromLTRB(
                                AppSpacing.md,
                                4,
                                AppSpacing.md,
                                AppSpacing.lg,
                              ),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: 10,
                                crossAxisSpacing: 10,
                                mainAxisExtent: 104 * textScale,
                              ),
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final record = filtered[index];
                                final isChecked =
                                    _selectedIdsForDelete.contains(record.id);
                                return _RecordCard(
                                  record: record,
                                  placeLabel:
                                      widget.store.placeLabelForRecord(record),
                                  selected: _isSelectionMode && isChecked,
                                  selectionMode: _isSelectionMode,
                                  checked: isChecked,
                                  onTap: () => _isSelectionMode
                                      ? _toggleRecordSelection(record.id)
                                      : _openRecord(
                                          record,
                                          isMasterDetail: false,
                                        ),
                                  onLongPress: _isSelectionMode
                                      ? null
                                      : () {
                                          _toggleSelectionMode(enable: true);
                                          _toggleRecordSelection(record.id);
                                        },
                                  onDelete: () =>
                                      _confirmAndDeleteRecord(record),
                                );
                              },
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(
                                AppSpacing.md,
                                4,
                                AppSpacing.md,
                                AppSpacing.lg,
                              ),
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: AppSpacing.xs),
                              itemBuilder: (context, index) {
                                final record = filtered[index];
                                final isChecked =
                                    _selectedIdsForDelete.contains(record.id);
                                final isSelected = _isSelectionMode
                                    ? isChecked
                                    : (isMasterDetail &&
                                        selectedRecord?.id == record.id);
                                return _RecordCard(
                                  record: record,
                                  placeLabel:
                                      widget.store.placeLabelForRecord(record),
                                  selected: isSelected,
                                  selectionMode: _isSelectionMode,
                                  checked: isChecked,
                                  onTap: () => _isSelectionMode
                                      ? _toggleRecordSelection(record.id)
                                      : _openRecord(
                                          record,
                                          isMasterDetail: isMasterDetail,
                                        ),
                                  onLongPress: _isSelectionMode
                                      ? null
                                      : () {
                                          _toggleSelectionMode(enable: true);
                                          _toggleRecordSelection(record.id);
                                        },
                                  onDelete: () =>
                                      _confirmAndDeleteRecord(record),
                                );
                              },
                            ),
                ),
                // Compact phone thumb-zone dock for Publish / Export / Multi-select
                if (isCompact && allRecords.isNotEmpty)
                  BottomActionDock(
                    safeAreaBottom: false,
                    child: _isSelectionMode
                        ? Row(
                            children: [
                              TextButton(
                                onPressed: () => _toggleSelectionMode(
                                  enable: false,
                                ),
                                child: const Text('Cancel'),
                              ),
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    final visibleIds =
                                        filtered.map((r) => r.id).toSet();
                                    if (_selectedIdsForDelete
                                            .containsAll(visibleIds) &&
                                        visibleIds.isNotEmpty) {
                                      _selectedIdsForDelete
                                          .removeAll(visibleIds);
                                    } else {
                                      _selectedIdsForDelete.addAll(visibleIds);
                                    }
                                  });
                                },
                                child: Text(
                                  filtered.isNotEmpty &&
                                          _selectedIdsForDelete.containsAll(
                                            filtered.map((r) => r.id),
                                          )
                                      ? 'Clear'
                                      : 'All',
                                ),
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: _selectedIdsForDelete.isEmpty
                                      ? null
                                      : _confirmAndDeleteSelected,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: scheme.error,
                                    foregroundColor: scheme.onError,
                                  ),
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 18,
                                  ),
                                  label: Text(
                                    'Remove (${_selectedIdsForDelete.length})',
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              IconButton.outlined(
                                tooltip: 'Select records',
                                onPressed: () =>
                                    _toggleSelectionMode(enable: true),
                                icon: const Icon(
                                  Icons.checklist_rounded,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              PopupMenuButton<String>(
                                tooltip: 'Export collection',
                                onSelected: _exportCollection,
                                itemBuilder: (_) => const [
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
                                child: Container(
                                  height: 44,
                                  width: 44,
                                  decoration: BoxDecoration(
                                    borderRadius:
                                        BorderRadius.circular(AppRadii.md),
                                    border: Border.all(
                                      color: scheme.outlineVariant,
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.ios_share_rounded,
                                    size: 19,
                                    color: scheme.onSurface,
                                  ),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: () => showOsmPublishSheet(
                                    context,
                                    osm: widget.osmPublish,
                                    store: widget.store,
                                    prefs: widget.prefs,
                                    connectivity: widget.connectivity,
                                    initialRecords: filtered.isNotEmpty
                                        ? filtered
                                        : allRecords,
                                  ),
                                  icon: const Icon(
                                    Icons.publish_rounded,
                                    size: 19,
                                  ),
                                  label: const Text('Publish to OSM'),
                                ),
                              ),
                            ],
                          ),
                  ),
              ],
            );

        if (isMasterDetail) {
          final masterWidth = (width * 0.34).clamp(340.0, 410.0);
          return Row(
            children: [
              SizedBox(
                width: masterWidth,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: buildListPane(),
                ),
              ),
              Expanded(
                child: selectedRecord == null
                    ? const Center(
                        child: EmptyStateCard(
                          icon: Icons.touch_app_outlined,
                          title: 'Select a record',
                          description:
                              'Choose any place from the list to inspect photos, adjust the map pin, or edit OpenStreetMap tags.',
                        ),
                      )
                    : RecordDetailScreen(
                        key: ValueKey(selectedRecord.id),
                        initialRecord: selectedRecord,
                        store: widget.store,
                        ai: widget.ai,
                        tiles: widget.tiles,
                        connectivity: widget.connectivity,
                        prefs: widget.prefs,
                        osmPublish: widget.osmPublish,
                        embedded: true,
                        onDeleted: () =>
                            setState(() => _selectedRecordId = null),
                      ),
              ),
            ],
          );
        }

        return buildListPane();
      },
    );
  }
}

class _RecordCard extends StatelessWidget {
  final OsmRecord record;
  final String placeLabel;
  final bool selected;
  final bool selectionMode;
  final bool checked;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onDelete;

  const _RecordCard({
    required this.record,
    required this.placeLabel,
    required this.selected,
    this.selectionMode = false,
    this.checked = false,
    required this.onTap,
    this.onLongPress,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final hasPhoto = photoExists(record.photoPath);
    final photoCount = record.allPhotoPaths.length;
    final isRecentlyUpdated =
        record.updatedAt.difference(record.createdAt).inMinutes >= 2;
    final timeStr = isRecentlyUpdated
        ? DateFormat('HH:mm').format(record.updatedAt)
        : DateFormat('MMM d').format(record.createdAt);

    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.08)
          : scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.4 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 6, 11),
          child: Row(
            children: [
              if (selectionMode) ...[
                Checkbox(
                  value: checked,
                  visualDensity: VisualDensity.compact,
                  onChanged: (_) => onTap(),
                ),
                const SizedBox(width: 2),
              ],
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                    child: hasPhoto
                        ? buildPhotoWidget(
                            record.photoPath!,
                            width: 60,
                            height: 60,
                          )
                        : Container(
                            width: 60,
                            height: 60,
                            color: scheme.surfaceContainerHigh,
                            child: Icon(
                              Icons.place_outlined,
                              color: scheme.onSurfaceVariant,
                              size: 22,
                            ),
                          ),
                  ),
                  if (photoCount > 1)
                    Positioned(
                      right: 3,
                      bottom: 3,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '$photoCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            record.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleSmall,
                          ),
                        ),
                        if (record.status == RecordStatus.uploaded)
                          Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: Tooltip(
                              message: 'Published to OpenStreetMap',
                              child: Icon(
                                Icons.public_rounded,
                                size: 15,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                        Text(
                          timeStr,
                          style: textTheme.labelSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            placeLabel,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!selectionMode)
                IconButton(
                  tooltip: 'Remove record',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDelete,
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 19,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
