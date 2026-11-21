import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../data/osm_tag_standards.dart';
import '../models/enrichment_diff.dart';
import '../models/hike_trail.dart';
import '../models/osm_record.dart';
import '../services/connectivity_service.dart';
import '../services/exif_gps_reader.dart';
import '../services/gps_quality_service.dart';
import '../services/hybrid_ai_service.dart';
import '../services/mapper_store.dart';
import '../services/osm_browser_bridge.dart';
import '../services/osm_duplicate_service.dart';
import '../services/photo_helper.dart';
import '../services/sensor_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ai_update_actions_card.dart';
import '../widgets/compass_badge.dart';
import '../widgets/enrichment_diff_sheet.dart';
import '../widgets/osm_map_widget.dart';
import '../widgets/osm_mapped_feature_sheet.dart';
import '../widgets/osm_tag_selector_sheet.dart';
import '../widgets/responsive_layout.dart';

class CaptureScreen extends StatefulWidget {
  final MapperStore store;
  final SensorService sensors;
  final HybridAiService ai;
  final ConnectivityService connectivity;
  final VoidCallback onRecordSaved;
  final OsmDuplicateService? nearbyOsmService;

  const CaptureScreen({
    super.key,
    required this.store,
    required this.sensors,
    required this.ai,
    required this.connectivity,
    required this.onRecordSaved,
    this.nearbyOsmService,
  });

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _noteController = TextEditingController();
  final Uuid _uuid = const Uuid();
  late final OsmDuplicateService _nearbyOsmService =
      widget.nearbyOsmService ?? OsmDuplicateService();

  bool _showHintInput = false;
  bool _isAnalyzing = false;
  bool _isRunningDraftAi = false;
  String _analysisStep = '';
  String? _analyzingPhotoPath;
  bool _cancelAnalysis = false;
  bool _skipLocalNano = false;
  OsmRecord? _pendingDraft;
  String? _diagnosticNote;
  int _selectedDraftPhotoIdx = 0;

  List<NearbyOsmElement> _nearbyOsmPois = const [];
  bool _isLoadingNearbyOsm = false;
  bool _hasLoadedNearbyOsm = false;
  String? _nearbyOsmError;
  GeoPoint? _lastNearbyScanCenter;
  GeoPoint? _mapViewCenter;
  NearbyOsmElement? _selectedOsmFeature;
  OsmRecord? _selectedLocalPin;

  @override
  void initState() {
    super.initState();
    widget.sensors.addListener(_maybeAutoScanNearbyOsm);
    widget.connectivity.addListener(_maybeAutoScanNearbyOsm);
    _maybeAutoScanNearbyOsm();
  }

  @override
  void dispose() {
    widget.sensors.removeListener(_maybeAutoScanNearbyOsm);
    widget.connectivity.removeListener(_maybeAutoScanNearbyOsm);
    _noteController.dispose();
    super.dispose();
  }

  void _maybeAutoScanNearbyOsm() {
    if (!widget.connectivity.isOnline || _isLoadingNearbyOsm) return;
    final pos = widget.sensors.currentPosition;
    if (pos == null ||
        !OsmTagStandards.hasValidGps(pos.latitude, pos.longitude)) {
      return;
    }
    final last = _lastNearbyScanCenter;
    if (last != null) {
      final moved = haversineMeters(
        last.latitude,
        last.longitude,
        pos.latitude,
        pos.longitude,
      );
      if (moved < 65.0) return;
    }
    _scanNearbyOsm(pos.latitude, pos.longitude);
  }

  Future<void> _scanNearbyOsm(double lat, double lon) async {
    if (_isLoadingNearbyOsm || !widget.connectivity.isOnline) return;
    if (!OsmTagStandards.hasValidGps(lat, lon)) return;

    if (mounted) {
      setState(() {
        _isLoadingNearbyOsm = true;
        _nearbyOsmError = null;
      });
    }
    _lastNearbyScanCenter = GeoPoint(lat, lon);

    try {
      final result = await _nearbyOsmService.fetchSurroundingPois(
        lat: lat,
        lon: lon,
        radiusMeters: 160.0,
      );
      if (!mounted) return;
      setState(() {
        _isLoadingNearbyOsm = false;
        if (result.succeeded) {
          _nearbyOsmPois = result.elements;
          _hasLoadedNearbyOsm = true;
          _nearbyOsmError = null;
        } else {
          _nearbyOsmError = result.errorMessage;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingNearbyOsm = false;
        _nearbyOsmError = 'Could not load nearby OSM places.';
      });
    }
  }

  Future<void> _inspectAndImproveOsmFeature(NearbyOsmElement el) async {
    final improvedTags = await showOsmMappedFeatureSheet(
      context,
      element: el,
    );
    if (improvedTags == null || !mounted) return;

    final now = DateTime.now();
    final record = OsmRecord(
      id: _uuid.v4(),
      createdAt: now,
      updatedAt: now,
      latitude: el.latitude,
      longitude: el.longitude,
      extrapolatedLatitude: el.latitude,
      extrapolatedLongitude: el.longitude,
      isManualPinOverride: true,
      estimatedOffsetMeters: 0,
      osmType: el.type,
      summary: el.displayName,
      tags: improvedTags,
      aiSource: AiSource.manual,
      status: RecordStatus.readyToUpload,
      notes: 'Tag improvement for OSM ${el.type}/${el.id}',
    );
    await widget.store.saveRecord(record);
    if (!mounted) return;

    // Reflect updated tags on the map immediately
    final updatedElement = NearbyOsmElement(
      type: el.type,
      id: el.id,
      version: el.version,
      latitude: el.latitude,
      longitude: el.longitude,
      tags: improvedTags,
      nodeIds: el.nodeIds,
      geometry: el.geometry,
    );
    setState(() {
      _nearbyOsmPois = [
        for (final item in _nearbyOsmPois)
          if (item.type == el.type && item.id == el.id)
            updatedElement
          else
            item,
      ];
      _selectedOsmFeature = updatedElement;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Saved tag improvements for "${updatedElement.displayName}" locally',
        ),
        action: SnackBarAction(
          label: 'View',
          onPressed: widget.onRecordSaved,
        ),
      ),
    );
  }

  void _cancelActiveAnalysis() {
    _cancelAnalysis = true;
    widget.ai.cancelActiveLocalNano();
    if (mounted) {
      setState(() => _analysisStep = 'Cancelling...');
    }
  }

  void _escalateActiveAnalysisToCloud() {
    _skipLocalNano = true;
    widget.ai.cancelActiveLocalNano();
    if (mounted) {
      setState(() => _analysisStep = 'Switching to Firebase AI...');
    }
  }

  Future<PhotoLocationMeta> _buildPhotoLocationMeta(
    String photoPath, {
    required bool fromGallery,
    required DateTime capturedAt,
    required double? fallbackLat,
    required double? fallbackLon,
    required double? fallbackAcc,
    required double? fallbackAlt,
    required double? fallbackHeading,
  }) async {
    if (fromGallery) {
      try {
        final bytes = await readPhotoBytes(photoPath);
        final exif = ExifGpsReader.extractFromBytes(bytes);
        if (exif != null) {
          return PhotoLocationMeta(
            photoPath: photoPath,
            latitude: exif.latitude,
            longitude: exif.longitude,
            accuracyMeters: exif.accuracyMeters,
            altitudeMeters: exif.altitudeMeters,
            headingDegrees: exif.headingDegrees,
            sourceLabel: 'Photo EXIF',
            capturedAt: capturedAt,
          );
        }
      } catch (_) {}
    }

    final hasLive = fallbackLat != null &&
        fallbackLon != null &&
        OsmTagStandards.hasValidGps(fallbackLat, fallbackLon);
    return PhotoLocationMeta(
      photoPath: photoPath,
      latitude: hasLive ? fallbackLat : null,
      longitude: hasLive ? fallbackLon : null,
      accuracyMeters: hasLive ? fallbackAcc : null,
      altitudeMeters: hasLive ? fallbackAlt : null,
      headingDegrees: fallbackHeading,
      sourceLabel: hasLive ? (fromGallery ? 'Device GPS' : 'Live GPS') : 'No GPS',
      capturedAt: capturedAt,
    );
  }

  Future<void> _captureAndAnalyze({
    required ImageSource? source,
    bool pickMultipleFromGallery = false,
    bool forceCloud = false,
  }) async {
    final savedPhotoPaths = <String>[];
    final isGallery = pickMultipleFromGallery || source == ImageSource.gallery;
    if (pickMultipleFromGallery) {
      final pickedList = await _picker.pickMultiImage(
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (pickedList.isEmpty) return;
      for (final xfile in pickedList.take(6)) {
        savedPhotoPaths.add(await widget.store.persistPickedPhotoFile(xfile));
      }
    } else if (source != null) {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (picked == null) return;
      savedPhotoPaths.add(await widget.store.persistPickedPhotoFile(picked));
    }

    await _analyzePhotoSet(
      savedPhotoPaths,
      forceCloud: forceCloud,
      newlyAddedPaths: savedPhotoPaths,
      newlyAddedFromGallery: isGallery,
    );
  }

  /// Appends 1+ additional camera or gallery photos to the active draft and
  /// re-runs AI to merge all angles/features into a single rich OSM record!
  Future<void> _addMorePhotosToDraft({
    required ImageSource source,
    bool pickMultiple = false,
  }) async {
    final draft = _pendingDraft;
    if (draft == null) return;

    final addedPaths = <String>[];
    final isGallery = pickMultiple || source == ImageSource.gallery;
    if (pickMultiple) {
      final pickedList = await _picker.pickMultiImage(
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (pickedList.isEmpty) return;
      for (final xfile in pickedList.take(6)) {
        addedPaths.add(await widget.store.persistPickedPhotoFile(xfile));
      }
    } else {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (picked == null) return;
      addedPaths.add(await widget.store.persistPickedPhotoFile(picked));
    }

    final combined = <String>[
      ...draft.allPhotoPaths,
      ...addedPaths,
    ].take(6).toList();

    await _analyzePhotoSet(
      combined,
      existingDraft: draft,
      newlyAddedPaths: addedPaths,
      newlyAddedFromGallery: isGallery,
    );
  }

  Future<void> _analyzePhotoSet(
    List<String> savedPhotoPaths, {
    bool forceCloud = false,
    OsmRecord? existingDraft,
    List<String> newlyAddedPaths = const [],
    bool newlyAddedFromGallery = false,
  }) async {
    final primaryPhoto =
        savedPhotoPaths.isNotEmpty ? savedPhotoPaths.first : null;
    final shutterTime = DateTime.now();

    setState(() {
      _isAnalyzing = true;
      _cancelAnalysis = false;
      _skipLocalNano = forceCloud;
      _analyzingPhotoPath = primaryPhoto;
      _analysisStep = savedPhotoPaths.length > 1
          ? 'Preparing ${savedPhotoPaths.length} photos for AI merge...'
          : 'Reading location...';
      _diagnosticNote = null;
    });

    try {
      final liveHeading = widget.sensors.headingDegrees;
      final pos = widget.sensors.currentPosition ??
          (kIsWeb
              ? await widget.sensors
                  .refreshCurrentPosition()
                  .timeout(const Duration(seconds: 2), onTimeout: () => null)
              : await widget.sensors.refreshCurrentPosition());

      if (_cancelAnalysis || !mounted) return;

      // Build per-photo GPS metadata (preserving existing photo locations when appending)
      final photoLocsByPath = <String, PhotoLocationMeta>{
        if (existingDraft != null)
          for (final m in existingDraft.photoLocations) m.photoPath: m,
      };
      for (final p in savedPhotoPaths) {
        if (!photoLocsByPath.containsKey(p)) {
          final isNew = newlyAddedPaths.contains(p);
          photoLocsByPath[p] = await _buildPhotoLocationMeta(
            p,
            fromGallery: isNew ? newlyAddedFromGallery : false,
            capturedAt: shutterTime,
            fallbackLat: pos?.latitude,
            fallbackLon: pos?.longitude,
            fallbackAcc: pos?.accuracy,
            fallbackAlt: pos?.altitude,
            fallbackHeading: liveHeading,
          );
        }
      }
      final orderedPhotoLocations = savedPhotoPaths
          .map((p) => photoLocsByPath[p])
          .whereType<PhotoLocationMeta>()
          .toList();

      // Determine primary location photo index (default existing index or first photo with valid GPS)
      int primaryIdx = existingDraft?.effectivePrimaryPhotoIndex ?? 0;
      if (existingDraft == null && orderedPhotoLocations.isNotEmpty) {
        final firstWithCoords =
            orderedPhotoLocations.indexWhere((m) => m.hasCoordinates);
        if (firstWithCoords >= 0) primaryIdx = firstWithCoords;
      }
      if (savedPhotoPaths.isNotEmpty) {
        primaryIdx = primaryIdx.clamp(0, savedPhotoPaths.length - 1);
      } else {
        primaryIdx = 0;
      }

      final primaryMeta = primaryIdx < orderedPhotoLocations.length
          ? orderedPhotoLocations[primaryIdx]
          : null;

      final lat = (primaryMeta != null && primaryMeta.hasCoordinates)
          ? primaryMeta.latitude!
          : (existingDraft?.latitude ?? pos?.latitude ?? 0.0);
      final lon = (primaryMeta != null && primaryMeta.hasCoordinates)
          ? primaryMeta.longitude!
          : (existingDraft?.longitude ?? pos?.longitude ?? 0.0);
      final heading = (primaryMeta != null && primaryMeta.hasCoordinates)
          ? primaryMeta.headingDegrees
          : (existingDraft?.headingDegrees ?? liveHeading);
      final accuracy = (primaryMeta != null && primaryMeta.hasCoordinates)
          ? primaryMeta.accuracyMeters
          : (existingDraft?.accuracyMeters ?? pos?.accuracy);
      final altitude = (primaryMeta != null && primaryMeta.hasCoordinates)
          ? (primaryMeta.altitudeMeters ?? pos?.altitude)
          : (existingDraft?.altitudeMeters ?? pos?.altitude);

      final activeTrail = widget.store.activeTrail;
      final inference = await widget.ai.analyzeSnapshot(
        photoPath: primaryPhoto,
        photoPaths: savedPhotoPaths,
        latitude: lat,
        longitude: lon,
        headingDegrees: heading,
        altitudeMeters: altitude,
        userHint: _noteController.text.trim().isNotEmpty
            ? _noteController.text.trim()
            : existingDraft?.notes,
        isOnTrail: (existingDraft?.trailId ?? activeTrail?.id) != null,
        forceCloud: _skipLocalNano,
        shouldCancel: () => _cancelAnalysis,
        onStatusUpdate: (step) {
          if (!mounted) return;
          setState(() => _analysisStep = step);
        },
      );

      if (_cancelAnalysis || !mounted) return;

      final extrapolated = existingDraft?.isManualPinOverride == true
          ? GeoPoint(
              existingDraft!.effectiveLatitude,
              existingDraft.effectiveLongitude,
            )
          : ((heading != null && OsmTagStandards.hasValidGps(lat, lon))
              ? extrapolateCoordinate(
                  latitude: lat,
                  longitude: lon,
                  bearingDegrees: heading,
                  distanceMeters: inference.estimatedOffsetMeters,
                )
              : GeoPoint(lat, lon));

      // If merging into an existing draft, preserve any manually-added tags not overwritten by AI
      final mergedTags = existingDraft != null
          ? (Map<String, String>.from(existingDraft.tags)
            ..addAll(inference.tags))
          : inference.tags;

      final draft = OsmRecord(
        id: existingDraft?.id ?? _uuid.v4(),
        createdAt: existingDraft?.createdAt ?? shutterTime,
        photoPath: primaryPhoto,
        photoPaths: savedPhotoPaths,
        photoLocations: orderedPhotoLocations,
        primaryLocationPhotoIndex: primaryIdx,
        isManualPinOverride: existingDraft?.isManualPinOverride ?? false,
        latitude: lat,
        longitude: lon,
        accuracyMeters: accuracy,
        altitudeMeters: altitude,
        headingDegrees: heading,
        extrapolatedLatitude: extrapolated.latitude,
        extrapolatedLongitude: extrapolated.longitude,
        estimatedOffsetMeters: inference.estimatedOffsetMeters,
        distanceReasoning: inference.distanceReasoning,
        osmType: inference.osmType,
        summary: inference.summary,
        detectedLanguage: inference.detectedLanguage,
        tags: mergedTags,
        detectedLabels: inference.detectedLabels,
        tagCandidates: {
          if (existingDraft != null) ...existingDraft.tagCandidates,
          ...inference.tagCandidates,
        },
        aiSource: inference.aiSource,
        status: inference.aiSource.isCloudAi
            ? RecordStatus.aiEnriched
            : RecordStatus.draftOffline,
        trailId: existingDraft?.trailId ?? activeTrail?.id,
      );

      // Auto-save every new capture (and photo merge) locally immediately
      await widget.store.saveRecord(draft);

      if (!mounted) return;
      final cloudErr = widget.ai.lastCloudError;
      final nanoErr = widget.ai.lastNanoError;
      final noteParts = <String>[
        if (savedPhotoPaths.length > 1)
          'Merged ${savedPhotoPaths.length} photos into 1 POI',
        if (inference.diagnosticNote.isNotEmpty) inference.diagnosticNote,
        if (inference.aiSource != AiSource.geminiNano && nanoErr != null)
          'Nano 4 skipped: $nanoErr',
        if (!inference.aiSource.isCloudAi && cloudErr != null)
          'Cloud fallback: $cloudErr',
      ];
      setState(() {
        _pendingDraft = draft;
        _selectedDraftPhotoIdx = primaryIdx;
        _diagnosticNote = noteParts.join(' | ');
      });
    } on AiBatchCancelledException {
      // User tapped Cancel — exit quietly
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not analyze photo: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
          _analysisStep = '';
          _analyzingPhotoPath = null;
        });
      }
    }
  }

  Future<void> _persistActiveRecord(OsmRecord updated) async {
    setState(() => _pendingDraft = updated);
    await widget.store.saveRecord(updated);
  }

  Future<void> _runAiOnPendingDraft(
    AiUpdateMode mode, {
    bool forceCloud = false,
  }) async {
    final draft = _pendingDraft;
    if (draft == null) return;

    setState(() => _isRunningDraftAi = true);
    try {
      final diff = await widget.ai.proposeAiUpdate(
        draft,
        mode: mode,
        forceCloud: forceCloud,
      );
      if (!mounted) return;
      final approved = await showEnrichmentDiffSheet(context, diff: diff);
      if (approved != null && mounted) {
        await _persistActiveRecord(approved);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Applied ${mode.shortLabel} recommendations!')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            'AI update unavailable: ${HybridAiService.formatCloudError(e)}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _isRunningDraftAi = false);
    }
  }

  void _dismissActiveCapture() {
    setState(() {
      _pendingDraft = null;
      _showHintInput = false;
      _diagnosticNote = null;
      _noteController.clear();
    });
  }

  Future<void> _deleteActiveCapture() async {
    final draft = _pendingDraft;
    if (draft == null) return;
    await widget.store.deleteRecord(draft.id);
    if (!mounted) return;
    _dismissActiveCapture();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Removed "${draft.displayName}"')),
    );
  }

  Future<void> _addTagToPendingDraft() async {
    final draft = _pendingDraft;
    if (draft == null) return;

    final chosen = await showOsmTagSelectorSheet(context, record: draft);
    if (chosen != null && mounted) {
      final updatedTags = Map<String, String>.from(draft.tags)
        ..[chosen.key] = chosen.value;
      await _persistActiveRecord(draft.copyWith(tags: updatedTags));
    }
  }

  void _updateDraftDistance(double newMeters) {
    final draft = _pendingDraft;
    if (draft == null) return;
    final extrap = draft.headingDegrees != null
        ? extrapolateCoordinate(
            latitude: draft.latitude,
            longitude: draft.longitude,
            bearingDegrees: draft.headingDegrees!,
            distanceMeters: newMeters,
          )
        : GeoPoint(draft.latitude, draft.longitude);
    setState(() {
      _pendingDraft = draft.copyWith(
        estimatedOffsetMeters: newMeters,
        extrapolatedLatitude: extrap.latitude,
        extrapolatedLongitude: extrap.longitude,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semanticColors;
    final textTheme = Theme.of(context).textTheme;
    final width = MediaQuery.sizeOf(context).width;
    final isSplitLayout = width >= AppBreakpoints.expanded;
    final isCompact = AppBreakpoints.isCompact(context);

    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.sensors,
        widget.store,
        widget.ai,
        widget.connectivity,
      ]),
      builder: (context, _) {
        final pos = widget.sensors.currentPosition;
        final gpsQuality = widget.sensors.gpsQuality;
        final heading = widget.sensors.headingDegrees;
        final activeTrail = widget.store.activeTrail;
        final recentRecords = widget.store.records.take(4).toList();

        Widget buildCaptureColumn() => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isCompact) ...[
                  const ScreenHeader(
                    title: 'Capture Place',
                    subtitle:
                        'Photo, GPS, and compass heading turn directly into OpenStreetMap tags.',
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],

                if (activeTrail != null)
                  InlineNoticeBanner(
                    margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                    tone: NoticeTone.danger,
                    icon: Icons.fiber_manual_record_rounded,
                    title: 'Recording ${activeTrail.name}',
                    detail: 'New captures link to this route automatically.',
                  ),

                // Single GPS & Compass Telemetry Card (with anchored Retry / Refresh action)
                Builder(
                  builder: (context) {
                    final hasWarning = gpsQuality.level.shouldAdvertiseWarning;
                    final isDanger =
                        gpsQuality.level == GpsQualityLevel.suspect;
                    final statusColor = !hasWarning
                        ? semantic.success
                        : (isDanger ? semantic.danger : semantic.warning);

                    return SurfacePanel(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: AppSpacing.sm,
                      ),
                      borderColor: hasWarning
                          ? statusColor.withValues(alpha: 0.45)
                          : null,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          CompassBadge(headingDegrees: heading, size: 50),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: statusColor,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        gpsQuality.level.shortLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.labelMedium?.copyWith(
                                          color: hasWarning
                                              ? statusColor
                                              : scheme.onSurfaceVariant,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                if (pos != null) ...[
                                  Text(
                                    '${pos.latitude.toStringAsFixed(5)}, ${pos.longitude.toStringAsFixed(5)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.titleSmall?.copyWith(
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    '±${pos.accuracy.toStringAsFixed(0)}m · Alt ${pos.altitude.toStringAsFixed(0)}m',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.bodySmall,
                                  ),
                                ] else
                                  Text(
                                    widget.sensors.locationError ??
                                        'Waiting for GPS location...',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.bodySmall,
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          if (hasWarning)
                            FilledButton.tonalIcon(
                              onPressed: widget
                                  .sensors.ensureLocationPermissionAndFix,
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                minimumSize: const Size(0, 38),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                foregroundColor: statusColor,
                                backgroundColor:
                                    statusColor.withValues(alpha: 0.14),
                              ),
                              icon: const Icon(Icons.refresh_rounded, size: 16),
                              label: const Text('Retry'),
                            )
                          else
                            IconButton.filledTonal(
                              tooltip: 'Refresh GPS',
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(
                                minWidth: 38,
                                minHeight: 38,
                              ),
                              onPressed: widget
                                  .sensors.ensureLocationPermissionAndFix,
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                            ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: AppSpacing.sm),

                // Capture Controls (tablet/desktop) & Optional AI Hint
                SurfacePanel(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: isCompact ? AppSpacing.xs : AppSpacing.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!isCompact) ...[
                        FilledButton.icon(
                          onPressed: _isAnalyzing
                              ? null
                              : () => _captureAndAnalyze(
                                    source: kIsWeb
                                        ? ImageSource.gallery
                                        : ImageSource.camera,
                                  ),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(double.infinity, 48),
                          ),
                          icon: _isAnalyzing
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: scheme.onPrimary,
                                  ),
                                )
                              : const Icon(
                                  kIsWeb
                                      ? Icons.add_photo_alternate_outlined
                                      : Icons.camera_alt_outlined,
                                  size: 20,
                                ),
                          label: Text(
                            _isAnalyzing
                                ? 'Analyzing...'
                                : (kIsWeb ? 'Choose Photo' : 'Take Photo'),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _isAnalyzing
                                    ? null
                                    : () => _captureAndAnalyze(
                                          source: ImageSource.gallery,
                                          pickMultipleFromGallery: true,
                                        ),
                                icon: const Icon(
                                  Icons.collections_outlined,
                                  size: 18,
                                ),
                                label: const Text('Multi-Photo'),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _isAnalyzing
                                    ? null
                                    : () => _captureAndAnalyze(source: null),
                                icon: const Icon(
                                  Icons.push_pin_outlined,
                                  size: 18,
                                ),
                                label: const Text('Quick Pin'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.xs),
                      ],
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () =>
                              setState(() => _showHintInput = !_showHintInput),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          icon: Icon(
                            _showHintInput || _noteController.text.isNotEmpty
                                ? Icons.edit_note_rounded
                                : Icons.add_comment_outlined,
                            size: 16,
                          ),
                          label: Text(
                            _noteController.text.trim().isNotEmpty
                                ? 'Hint set'
                                : (_showHintInput ? 'Hide hint' : 'Add hint'),
                          ),
                        ),
                      ),
                      if (_showHintInput ||
                          _noteController.text.trim().isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xs),
                        TextField(
                          controller: _noteController,
                          textInputAction: TextInputAction.done,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: 'Optional place name or AI hint...',
                            prefixIcon:
                                const Icon(Icons.edit_note_rounded, size: 20),
                            suffixIcon: _noteController.text.isNotEmpty
                                ? IconButton(
                                    tooltip: 'Clear hint',
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 18,
                                    ),
                                    onPressed: () {
                                      _noteController.clear();
                                      setState(() {});
                                    },
                                  )
                                : null,
                            isDense: true,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                if (!isSplitLayout) ...[
                  if (_isAnalyzing) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _buildProgressPanel(context),
                  ],
                  if (_pendingDraft != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    _buildPendingDraftCard(context, _pendingDraft!),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  _buildSurroundingMapCard(
                    context,
                    userLat: pos?.latitude,
                    userLon: pos?.longitude,
                    userAccuracyMeters: pos?.accuracy,
                    gpsQuality: gpsQuality,
                    heading: heading,
                    isCompact: isCompact,
                  ),
                ],
              ],
            );

        Widget buildRightWorkspace() {
          if (_isAnalyzing) {
            return _buildProgressPanel(context);
          }
          if (_pendingDraft != null) {
            return _buildPendingDraftCard(context, _pendingDraft!);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSurroundingMapCard(
                context,
                userLat: pos?.latitude,
                userLon: pos?.longitude,
                userAccuracyMeters: pos?.accuracy,
                gpsQuality: gpsQuality,
                heading: heading,
                isCompact: false,
              ),
              const SizedBox(height: AppSpacing.md),
              SurfacePanel(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SectionLabel(
                      recentRecords.isEmpty
                          ? 'Capture Preview'
                          : 'Recent Captures',
                      trailing: recentRecords.isNotEmpty
                          ? TextButton(
                              onPressed: widget.onRecordSaved,
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              child: const Text('View all'),
                            )
                          : null,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    if (recentRecords.isEmpty)
                      const EmptyStateCard(
                        icon: Icons.add_location_alt_outlined,
                        title: 'No active capture',
                        description:
                            'Take a photo or create a Quick Pin on the left — captures save locally automatically.',
                      )
                    else
                      ...recentRecords.map(
                        (r) => InkWell(
                          onTap: widget.onRecordSaved,
                          borderRadius: BorderRadius.circular(AppRadii.md),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: AppSpacing.xs,
                              horizontal: AppSpacing.xxs,
                            ),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.sm),
                                  child: photoExists(r.photoPath)
                                      ? buildPhotoWidget(
                                          r.photoPath!,
                                          width: 50,
                                          height: 50,
                                        )
                                      : Container(
                                          width: 50,
                                          height: 50,
                                          color: scheme.surfaceContainerHigh,
                                          child: Icon(
                                            Icons.place_outlined,
                                            size: 20,
                                            color: scheme.onSurfaceVariant,
                                          ),
                                        ),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        r.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.titleSmall,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        widget.store.placeLabelForRecord(r),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 20,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        }

        if (isSplitLayout) {
          final leftWidth = (width * 0.36).clamp(340.0, 420.0);
          return SingleChildScrollView(
            padding: EdgeInsets.all(AppBreakpoints.horizontalPadding(context)),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1120),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: leftWidth, child: buildCaptureColumn()),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(child: buildRightWorkspace()),
                  ],
                ),
              ),
            ),
          );
        }

        final hPad = AppBreakpoints.horizontalPadding(context);
        final scrollableBody = SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            hPad,
            AppSpacing.sm,
            hPad,
            isCompact ? AppSpacing.md : AppSpacing.xl,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: buildCaptureColumn(),
            ),
          ),
        );

        if (!isCompact) return scrollableBody;

        // Compact phone: anchor primary capture/draft actions in the bottom thumb zone
        return Column(
          children: [
            Expanded(child: scrollableBody),
            BottomActionDock(
              safeAreaBottom: false,
              child: _pendingDraft != null
                  ? Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _deleteActiveCapture,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: scheme.error,
                              side: BorderSide(
                                color: scheme.error.withValues(alpha: 0.45),
                              ),
                            ),
                            child: const Text('Delete'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          flex: 2,
                          child: FilledButton.icon(
                            onPressed: _dismissActiveCapture,
                            icon: const Icon(Icons.check_rounded, size: 19),
                            label: const Text('Done'),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        IconButton.outlined(
                          tooltip: 'Multi-Photo from Gallery',
                          onPressed: _isAnalyzing
                              ? null
                              : () => _captureAndAnalyze(
                                    source: ImageSource.gallery,
                                    pickMultipleFromGallery: true,
                                  ),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            side: BorderSide(color: scheme.outlineVariant),
                          ),
                          icon: const Icon(
                            Icons.collections_outlined,
                            size: 21,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        IconButton.outlined(
                          tooltip: 'Quick Pin (No Photo)',
                          onPressed: _isAnalyzing
                              ? null
                              : () => _captureAndAnalyze(source: null),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            side: BorderSide(color: scheme.outlineVariant),
                          ),
                          icon: const Icon(
                            Icons.push_pin_outlined,
                            size: 21,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _isAnalyzing
                                ? null
                                : () => _captureAndAnalyze(
                                      source: kIsWeb
                                          ? ImageSource.gallery
                                          : ImageSource.camera,
                                    ),
                            icon: _isAnalyzing
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: scheme.onPrimary,
                                    ),
                                  )
                                : const Icon(
                                    kIsWeb
                                        ? Icons.add_photo_alternate_outlined
                                        : Icons.camera_alt_outlined,
                                    size: 20,
                                  ),
                            label: Text(
                              _isAnalyzing
                                  ? 'Analyzing...'
                                  : (kIsWeb ? 'Choose Photo' : 'Take Photo'),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSurroundingMapCard(
    BuildContext context, {
    required double? userLat,
    required double? userLon,
    required double? userAccuracyMeters,
    required GpsQualityReport gpsQuality,
    required double? heading,
    required bool isCompact,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semanticColors;
    final textTheme = Theme.of(context).textTheme;
    final isOnline = widget.connectivity.isOnline;
    final allRecords = widget.store.records;

    final hasGps = userLat != null &&
        userLon != null &&
        OsmTagStandards.hasValidGps(userLat, userLon);
    final scanTarget = _mapViewCenter ??
        (hasGps ? GeoPoint(userLat, userLon) : const GeoPoint(35.6812, 139.7671));

    // Count user captures within ~500m of current view/GPS for quick clarity
    int nearbyYoursCount = 0;
    for (final r in allRecords) {
      if (!OsmTagStandards.hasValidGps(
        r.effectiveLatitude,
        r.effectiveLongitude,
      )) {
        continue;
      }
      final d = haversineMeters(
        scanTarget.latitude,
        scanTarget.longitude,
        r.effectiveLatitude,
        r.effectiveLongitude,
      );
      if (d <= 500.0) nearbyYoursCount++;
    }

    final pannedAway = _mapViewCenter != null &&
        _lastNearbyScanCenter != null &&
        haversineMeters(
              _mapViewCenter!.latitude,
              _mapViewCenter!.longitude,
              _lastNearbyScanCenter!.latitude,
              _lastNearbyScanCenter!.longitude,
            ) >
            75.0;

    return SurfacePanel(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.explore_outlined,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Mapped Nearby',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (_isLoadingNearbyOsm)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.primary,
                    ),
                  ),
                )
              else if (_hasLoadedNearbyOsm) ...[
                SubtleTag(
                  icon: Icons.check_circle_rounded,
                  label: '${_nearbyOsmPois.length} OSM',
                  tint: semantic.success,
                ),
                if (nearbyYoursCount > 0) ...[
                  const SizedBox(width: 4),
                  SubtleTag(
                    label: '$nearbyYoursCount yours',
                    tint: const Color(0xFFEA580C),
                  ),
                ],
              ] else if (!isOnline)
                SubtleTag(
                  label: 'Offline',
                  tint: scheme.onSurfaceVariant,
                ),
              if (isOnline)
                IconButton(
                  tooltip: pannedAway || !_hasLoadedNearbyOsm
                      ? 'Scan this map area on OpenStreetMap'
                      : 'Refresh nearby OpenStreetMap places',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  padding: EdgeInsets.zero,
                  onPressed: _isLoadingNearbyOsm
                      ? null
                      : () => _scanNearbyOsm(
                            scanTarget.latitude,
                            scanTarget.longitude,
                          ),
                  icon: Icon(
                    pannedAway || !_hasLoadedNearbyOsm
                        ? Icons.radar_rounded
                        : Icons.refresh_rounded,
                    size: 18,
                    color: pannedAway || !_hasLoadedNearbyOsm
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          OsmMapWidget(
            tileService: widget.store.tiles,
            isOnline: isOnline,
            userLat: userLat,
            userLon: userLon,
            userAccuracyMeters: userAccuracyMeters,
            userHeadingDegrees: heading,
            gpsQuality: gpsQuality,
            pins: allRecords,
            mappedOsmFeatures: _nearbyOsmPois,
            highlightMappedCoverage: true,
            selectedMappedFeature: _selectedOsmFeature,
            selectedPin: _selectedLocalPin,
            height: isCompact ? 236 : 272,
            initialZoom: 17,
            showOfflineDownloadButton: false,
            onCenterChanged: (center) {
              setState(() => _mapViewCenter = center);
            },
            onMappedFeatureTap: (el) {
              setState(() {
                _selectedOsmFeature = el;
                _selectedLocalPin = null;
              });
            },
            onPinTap: (rec) {
              setState(() {
                _selectedLocalPin = rec;
                _selectedOsmFeature = null;
              });
            },
            onEmptyTap: () {
              if (_selectedOsmFeature != null || _selectedLocalPin != null) {
                setState(() {
                  _selectedOsmFeature = null;
                  _selectedLocalPin = null;
                });
              }
            },
          ),
          if (_selectedOsmFeature != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Builder(
              builder: (context) {
                final el = _selectedOsmFeature!;
                final isBldgOnly = el.isBuilding && !el.isPoi;
                final accent =
                    isBldgOnly ? const Color(0xFF0284C7) : semantic.success;
                final missing = el.missingRecommendedKeys;
                final tagEntries = el.tags.entries.toList();
                final previewEntries = tagEntries.take(8).toList();

                return Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.38),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isBldgOnly
                                ? Icons.apartment_rounded
                                : Icons.check_circle_rounded,
                            size: 18,
                            color: accent,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  el.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.titleSmall,
                                ),
                                Text(
                                  '${isBldgOnly ? 'Building' : 'Point / POI'} · ${el.type}/${el.id} · ${el.tags.length} tag${el.tags.length == 1 ? '' : 's'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            padding: EdgeInsets.zero,
                            onPressed: () =>
                                setState(() => _selectedOsmFeature = null),
                            icon: const Icon(Icons.close_rounded, size: 16),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: [
                          for (final t in previewEntries)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.surfaceContainerLowest,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: scheme.outlineVariant,
                                ),
                              ),
                              child: Text(
                                '${t.key}=${t.value}',
                                style: textTheme.labelSmall?.copyWith(
                                  color: scheme.onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (tagEntries.length > previewEntries.length)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '+${tagEntries.length - previewEntries.length} more',
                                style: textTheme.labelSmall?.copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (missing.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Text(
                          'Could add: ${missing.take(4).join(', ')}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: () => _inspectAndImproveOsmFeature(el),
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(double.infinity, 38),
                        ),
                        icon: const Icon(Icons.add_circle_outline_rounded, size: 17),
                        label: const Text('Add / Improve Tags'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ] else if (_selectedLocalPin != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFEA580C).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppRadii.sm),
                border: Border.all(
                  color: const Color(0xFFEA580C).withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.location_on_rounded,
                    size: 16,
                    color: Color(0xFFEA580C),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedLocalPin!.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelLarge,
                        ),
                        Text(
                          'Your capture · ${widget.store.placeLabelForRecord(_selectedLocalPin!)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onRecordSaved,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('View'),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: () => setState(() => _selectedLocalPin = null),
                    icon: const Icon(Icons.close_rounded, size: 16),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const _MapLegendDot(
                color: Color(0xFF059669),
                label: 'POI',
                showCheck: true,
              ),
              const _MapLegendDot(
                color: Color(0xFF0284C7),
                label: 'Building',
                isSquare: true,
              ),
              const _MapLegendDot(
                color: Color(0xFFEA580C),
                label: 'Yours',
              ),
              Text(
                _nearbyOsmError != null
                    ? 'Tap scan to retry OSM'
                    : (!isOnline
                        ? 'Offline · local captures'
                        : (_hasLoadedNearbyOsm
                            ? 'Tap any point or building to inspect tags'
                            : 'Tap scan icon to load OSM features')),
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressPanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SurfacePanel(
      padding: const EdgeInsets.all(14),
      borderColor: scheme.primary.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (photoExists(_analyzingPhotoPath)) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: buildPhotoWidget(
                    _analyzingPhotoPath!,
                    width: 48,
                    height: 48,
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _analysisStep.isNotEmpty
                          ? _analysisStep
                          : 'Analyzing photo...',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.ai.canUseAnyCloudAi && !_skipLocalNano)
                TextButton.icon(
                  onPressed: _escalateActiveAnalysisToCloud,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.cloud_outlined, size: 15),
                  label: const Text('Use Cloud AI'),
                ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: _cancelActiveAnalysis,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: scheme.error,
                ),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPendingDraftCard(BuildContext context, OsmRecord draft) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semanticColors;
    final textTheme = Theme.of(context).textTheme;
    final headingText = draft.headingDegrees != null
        ? '${draft.headingDegrees!.round()}° ${cardinalDirection(draft.headingDegrees)}'
        : 'no compass';

    return SurfacePanel(
      padding: const EdgeInsets.all(AppSpacing.md),
      borderColor: scheme.primary.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (photoExists(draft.photoPath))
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  child: buildPhotoWidget(
                    draft.photoPath!,
                    width: 72,
                    height: 72,
                  ),
                ),
              if (photoExists(draft.photoPath))
                const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        SubtleTag(
                          icon: Icons.check_circle_outline_rounded,
                          label: 'Saved locally',
                          tint: semantic.success,
                        ),
                        SubtleTag(
                          label: draft.aiSource.shortLabel,
                          tint: scheme.primary,
                        ),
                        SubtleTag(
                          label: draft.detectedLanguage.toUpperCase(),
                        ),
                        if (draft.allPhotoPaths.length > 1)
                          SubtleTag(
                            icon: Icons.collections_outlined,
                            label: '${draft.allPhotoPaths.length} Merged',
                            tint: semantic.info,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      draft.displayName,
                      style: textTheme.titleMedium,
                    ),
                    Text(
                      '${draft.estimatedOffsetMeters.toStringAsFixed(0)}m ahead · $headingText',
                      style: textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Multi-Photo Strip with explicit Main Location indicator & selector
          const SizedBox(height: 10),
          Builder(
            builder: (context) {
              final photos = draft.allPhotoPaths;
              final mainIdx = draft.effectivePrimaryPhotoIndex;
              final safeSel = photos.isEmpty
                  ? 0
                  : _selectedDraftPhotoIdx.clamp(0, photos.length - 1);
              final selMeta = draft.locationMetaForPhoto(safeSel);
              final isViewingMain =
                  safeSel == mainIdx && !draft.isManualPinOverride;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 68,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (var i = 0; i < photos.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: GestureDetector(
                              onTap: () =>
                                  setState(() => _selectedDraftPhotoIdx = i),
                              child: Stack(
                                children: [
                                  Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: i == mainIdx &&
                                                !draft.isManualPinOverride
                                            ? const Color(0xFF059669)
                                            : (i == safeSel
                                                ? scheme.primary
                                                : scheme.outlineVariant),
                                        width: (i == mainIdx || i == safeSel)
                                            ? 2.2
                                            : 1,
                                      ),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: buildPhotoWidget(
                                        photos[i],
                                        width: 62,
                                        height: 62,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: 3,
                                    top: 3,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black
                                            .withValues(alpha: 0.68),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        '#${i + 1}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (i == mainIdx &&
                                      !draft.isManualPinOverride)
                                    Positioned(
                                      left: 3,
                                      bottom: 3,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 1.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF059669),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.location_on_rounded,
                                              size: 9.5,
                                              color: Colors.white,
                                            ),
                                            SizedBox(width: 1),
                                            Text(
                                              'GPS',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 8.5,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  if (photos.length > 1)
                                    Positioned(
                                      right: 2,
                                      top: 2,
                                      child: InkWell(
                                        onTap: () {
                                          final removedPath = photos[i];
                                          final remaining =
                                              List<String>.from(photos)
                                                ..removeAt(i);
                                          final remainingLocs = draft
                                              .photoLocations
                                              .where(
                                                (m) =>
                                                    m.photoPath != removedPath,
                                              )
                                              .toList();
                                          var nextPrimary = mainIdx;
                                          if (i == mainIdx) {
                                            nextPrimary = 0;
                                          } else if (i < mainIdx) {
                                            nextPrimary = mainIdx - 1;
                                          }
                                          final nextDraft = draft.copyWith(
                                            photoPaths: remaining,
                                            photoPath: remaining.isNotEmpty
                                                ? remaining.first
                                                : null,
                                            photoLocations: remainingLocs,
                                            primaryLocationPhotoIndex:
                                                nextPrimary,
                                          );
                                          final updatedDraft = i == mainIdx
                                              ? nextDraft
                                                  .selectMainLocationPhoto(0)
                                              : nextDraft;
                                          _persistActiveRecord(updatedDraft);
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.all(2),
                                          decoration: const BoxDecoration(
                                            color: Colors.black54,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            Icons.close_rounded,
                                            size: 12,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        if (photos.length < 6) ...[
                          if (!kIsWeb)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: OutlinedButton.icon(
                                onPressed: _isAnalyzing
                                    ? null
                                    : () => _addMorePhotosToDraft(
                                          source: ImageSource.camera,
                                        ),
                                icon: const Icon(
                                  Icons.add_a_photo_outlined,
                                  size: 16,
                                ),
                                label: const Text('+ Snap Angle'),
                              ),
                            ),
                          OutlinedButton.icon(
                            onPressed: _isAnalyzing
                                ? null
                                : () => _addMorePhotosToDraft(
                                      source: ImageSource.gallery,
                                      pickMultiple: true,
                                    ),
                            icon: const Icon(
                              Icons.add_photo_alternate_outlined,
                              size: 16,
                            ),
                            label: const Text('+ Add Photos & Merge'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (photos.length > 1) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: isViewingMain
                            ? const Color(0xFF059669).withValues(alpha: 0.08)
                            : scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isViewingMain
                              ? const Color(0xFF059669).withValues(alpha: 0.4)
                              : scheme.outlineVariant,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.location_on_rounded,
                            size: 15,
                            color: isViewingMain
                                ? const Color(0xFF059669)
                                : scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              isViewingMain
                                  ? 'Using Photo #${safeSel + 1} for main POI coordinates (${selMeta?.sourceLabel ?? 'GPS'})'
                                  : selMeta != null && selMeta.hasCoordinates
                                      ? 'Photo #${safeSel + 1}: ${selMeta.sourceLabel} (${selMeta.latitude!.toStringAsFixed(5)}, ${selMeta.longitude!.toStringAsFixed(5)})'
                                      : 'Photo #${safeSel + 1}: no separate GPS stored (main: Photo #${mainIdx + 1})',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (!isViewingMain &&
                              selMeta != null &&
                              selMeta.hasCoordinates)
                            FilledButton.tonal(
                              onPressed: () {
                                _persistActiveRecord(
                                  draft.selectMainLocationPhoto(safeSel),
                                );
                              },
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                              ),
                              child: Text('Use Photo #${safeSel + 1}'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          ),

            // Distance estimation reasoning + GPS & Calculation error summary + quick fine-tune slider
            if (draft.distanceReasoning.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                draft.distanceReasoning,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
            Builder(
              builder: (context) {
                final u = draft.positionUncertainty;
                final tone = switch (u.severity) {
                  PositionUncertaintySeverity.highPrecision =>
                    NoticeTone.success,
                  PositionUncertaintySeverity.moderate => NoticeTone.warning,
                  PositionUncertaintySeverity.needsCorrection =>
                    NoticeTone.danger,
                };
                final gpsTxt = u.gpsMeasurementErrorMeters != null
                    ? '±${u.gpsMeasurementErrorMeters!.toStringAsFixed(0)}m'
                    : 'unknown';
                final calcTxt =
                    '±${u.extrapolationCalcErrorMeters.toStringAsFixed(1)}m';
                final totalTxt =
                    '±${u.totalCombinedErrorMeters.toStringAsFixed(1)}m';
                return InlineNoticeBanner(
                  margin: const EdgeInsets.only(top: AppSpacing.xs),
                  tone: tone,
                  icon: Icons.my_location_rounded,
                  title: 'Position error $totalTxt (${u.severity.label})',
                  detail: 'GPS: $gpsTxt · Distance/compass calc: $calcTxt',
                );
              },
            ),
            Row(
              children: [
                const Icon(Icons.straighten_rounded, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Distance: ${draft.estimatedOffsetMeters.toStringAsFixed(0)} m',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: draft.estimatedOffsetMeters.clamp(1.0, 100.0),
                    min: 1.0,
                    max: 100.0,
                    divisions: 99,
                    label: '${draft.estimatedOffsetMeters.toStringAsFixed(0)}m',
                    onChanged: _updateDraftDistance,
                    onChangeEnd: (_) {
                      final active = _pendingDraft;
                      if (active != null) {
                        _persistActiveRecord(active);
                      }
                    },
                  ),
                ),
              ],
            ),

            if (_diagnosticNote != null && _diagnosticNote!.isNotEmpty) ...[
              Text(
                _diagnosticNote!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
              ),
              const SizedBox(height: 6),
            ],

            // Clear AI Update options: Add Missing Tags vs Reset & Re-analyze
            if (widget.ai.canUseAnyCloudAi ||
                (widget.ai.canUseLocalNano &&
                    draft.aiSource != AiSource.geminiNano)) ...[
              const SizedBox(height: 6),
              AiUpdateActionsCard(
                compact: true,
                canUseLocalNano: widget.ai.canUseLocalNano &&
                    draft.aiSource != AiSource.geminiNano,
                canUseCloudAi: widget.ai.canUseAnyCloudAi,
                defaultUseNano: !widget.ai.canUseAnyCloudAi,
                isRunning: _isRunningDraftAi,
                onRun: (mode, forceCloud) => _runAiOnPendingDraft(
                  mode,
                  forceCloud: forceCloud,
                ),
              ),
            ],

            const SizedBox(height: 8),
            Builder(
              builder: (context) {
                final split = OsmTagStandards.splitTagsForDisplay(draft.tags);
                final publishable = split.publishable;
                final localOnly = split.localOnly;
                final hasGps = OsmTagStandards.hasValidGps(
                  draft.effectiveLatitude,
                  draft.effectiveLongitude,
                );
                final deprecated = OsmTagStandards.findDeprecatedTags(
                  publishable,
                  hasGpsFix: hasGps,
                );
                final deprecatedKeys = deprecated.map((d) => d.key).toSet();

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'OSM Tags (${publishable.length})',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelLarge
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              Text(
                                'Published to OSM · tap a tag to open OSM Wiki',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        if (deprecated.any((d) => d.canAutoFix))
                          TextButton(
                            onPressed: () {
                              final next = OsmTagStandards.modernizeTags(
                                draft.tags,
                                hasGpsFix: hasGps,
                                stripLocalOnly: false,
                              );
                              _persistActiveRecord(draft.copyWith(tags: next));
                            },
                            child: const Text('Auto-Fix'),
                          ),
                        TextButton.icon(
                          onPressed: _addTagToPendingDraft,
                          icon: const Icon(Icons.add_rounded, size: 16),
                          label: const Text('Tag'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: publishable.entries.map((e) {
                        final isDep = deprecatedKeys.contains(e.key);
                        return InputChip(
                          avatar: isDep
                              ? const Icon(
                                  Icons.warning_amber_rounded,
                                  size: 15,
                                  color: Color(0xFFB45309),
                                )
                              : null,
                          tooltip: isDep
                              ? 'Deprecated OSM tag — tap to view OSM Wiki'
                              : 'Tap to check OSM Wiki docs',
                          label: Text(
                            '${e.key}=${e.value}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          onPressed: () => openExternalUrl(
                            OsmTagStandards.wikiUrlForTag(e.key, e.value),
                          ),
                          onDeleted: () {
                            final next = Map<String, String>.from(draft.tags)
                              ..remove(e.key);
                            _persistActiveRecord(draft.copyWith(tags: next));
                          },
                        );
                      }).toList(),
                    ),
                    if (localOnly.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Local metadata only (not published to OSM):',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: localOnly.entries.map((e) {
                          return InputChip(
                            avatar: Icon(
                              Icons.visibility_off_outlined,
                              size: 14,
                              color: scheme.onSurfaceVariant,
                            ),
                            label: Text(
                              '${e.key}=${e.value}',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            onDeleted: () {
                              final next = Map<String, String>.from(draft.tags)
                                ..remove(e.key);
                              _persistActiveRecord(draft.copyWith(tags: next));
                            },
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                );
              },
            ),
            if (!AppBreakpoints.isCompact(context)) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _deleteActiveCapture,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.error,
                        side: BorderSide(
                          color: scheme.error.withValues(alpha: 0.45),
                        ),
                      ),
                      child: const Text('Delete'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _dismissActiveCapture,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Done'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
    );
  }
}

class _MapLegendDot extends StatelessWidget {
  final Color color;
  final String label;
  final bool showCheck;
  final bool isSquare;

  const _MapLegendDot({
    required this.color,
    required this.label,
    this.showCheck = false,
    this.isSquare = false,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: isSquare ? color.withValues(alpha: 0.22) : color,
            shape: isSquare ? BoxShape.rectangle : BoxShape.circle,
            borderRadius: isSquare ? BorderRadius.circular(3) : null,
            border: Border.all(
              color: isSquare ? color : Colors.white,
              width: 1.5,
            ),
            boxShadow: isSquare
                ? null
                : [
                    BoxShadow(
                      color: color.withValues(alpha: 0.45),
                      blurRadius: 3,
                    ),
                  ],
          ),
          child: showCheck
              ? const Icon(Icons.check_rounded, size: 9, color: Colors.white)
              : (isSquare
                  ? null
                  : Center(
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                    )),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}
