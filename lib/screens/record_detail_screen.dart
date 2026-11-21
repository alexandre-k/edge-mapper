import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../data/osm_tag_standards.dart';
import '../models/enrichment_diff.dart';
import '../models/osm_record.dart';
import '../services/connectivity_service.dart';
import '../services/exif_gps_reader.dart';
import '../services/hybrid_ai_service.dart';
import '../services/location_context_service.dart';
import '../services/mapper_store.dart';
import '../services/offline_tile_service.dart';
import '../services/osm_browser_bridge.dart';
import '../services/osm_export_service.dart';
import '../services/osm_publish_service.dart';
import '../services/photo_helper.dart';
import '../services/user_preferences_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ai_update_actions_card.dart';
import '../widgets/enrichment_diff_sheet.dart';
import '../widgets/fine_pin_position_pad.dart';
import '../widgets/osm_map_widget.dart';
import '../widgets/osm_publish_sheet.dart';
import '../widgets/osm_tag_selector_sheet.dart';
import '../widgets/responsive_layout.dart';

class RecordDetailScreen extends StatefulWidget {
  final OsmRecord initialRecord;
  final MapperStore store;
  final HybridAiService ai;
  final OfflineTileService tiles;
  final ConnectivityService connectivity;
  final UserPreferencesService prefs;
  final OsmPublishService osmPublish;
  final bool embedded;
  final VoidCallback? onDeleted;

  const RecordDetailScreen({
    super.key,
    required this.initialRecord,
    required this.store,
    required this.ai,
    required this.tiles,
    required this.connectivity,
    required this.prefs,
    required this.osmPublish,
    this.embedded = false,
    this.onDeleted,
  });

  @override
  State<RecordDetailScreen> createState() => _RecordDetailScreenState();
}

class _RecordDetailScreenState extends State<RecordDetailScreen> {
  final ImagePicker _picker = ImagePicker();
  late OsmRecord _record;
  int _selectedPhotoIdx = 0;
  bool _isPlacingPinOnMap = false;
  bool _isRunningAi = false;
  bool _cancelAi = false;
  String _aiProgressStep = '';

  @override
  void initState() {
    super.initState();
    _record = widget.initialRecord;
    _selectedPhotoIdx = _record.effectivePrimaryPhotoIndex;
  }

  @override
  void didUpdateWidget(covariant RecordDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialRecord.id != _record.id ||
        widget.initialRecord.updatedAt != _record.updatedAt ||
        widget.initialRecord.photoPath != _record.photoPath ||
        widget.initialRecord.status != _record.status) {
      _record = widget.initialRecord;
    }
  }

  Future<void> _persistChanges({OsmRecord? override}) async {
    final updated = override ?? _record;
    await widget.store.saveRecord(updated);
    if (!mounted) return;
    setState(() => _record = updated);
  }

  /// Opens the probability-sorted OSM Tag Selector (no plain text box needed!).
  Future<void> _pickOsmTag() async {
    final chosen = await showOsmTagSelectorSheet(context, record: _record);
    if (chosen == null) return;
    final tags = Map<String, String>.from(_record.tags)
      ..[chosen.key] = chosen.value;
    await _persistChanges(override: _record.copyWith(tags: tags));
  }

  static List<String> _quickValuesForOsmKey(String key) =>
      switch (key.trim().toLowerCase()) {
        'wheelchair' => const ['yes', 'limited', 'no'],
        'lit' ||
        'toilets' ||
        'outdoor_seating' ||
        'indoor_seating' ||
        'takeaway' ||
        'delivery' ||
        'bench' ||
        'covered' ||
        'shelter' ||
        'fee' ||
        'internet_access' =>
          const ['yes', 'no'],
        'access' => const ['yes', 'customers', 'permissive', 'private', 'no'],
        'surface' => const ['asphalt', 'paved', 'concrete', 'gravel', 'dirt', 'wood'],
        'smoothness' => const ['excellent', 'good', 'intermediate', 'bad'],
        'bicycle_parking' => const ['stands', 'rack', 'wall_loops', 'shed'],
        'opening_hours' => const ['24/7', 'Mo-Fr 09:00-18:00', 'Mo-Su 08:00-20:00'],
        _ => const [],
      };

  /// Allows editing an existing tag's value cleanly when tapped, with 1-tap
  /// quick values for common OSM keys, an OSM Wiki link, and `opening_hours` tips.
  Future<void> _editExistingTag(String existingKey, String existingValue) async {
    final valCtrl = TextEditingController(text: existingValue);
    final wikiUrl = OsmTagStandards.wikiUrlForTag(existingKey, existingValue);
    final isOpeningHours = existingKey.trim().toLowerCase() == 'opening_hours';
    final quickValues = _quickValuesForOsmKey(existingKey);
    final depNotices = OsmTagStandards.findDeprecatedTags(
      {existingKey: existingValue},
      hasGpsFix: OsmTagStandards.hasValidGps(
        _record.effectiveLatitude,
        _record.effectiveLongitude,
      ),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Row(
            children: [
              Expanded(child: Text('Edit "$existingKey"')),
              IconButton(
                tooltip: 'Check OSM Wiki documentation',
                icon: const Icon(Icons.menu_book_outlined, size: 20),
                onPressed: () => openExternalUrl(wikiUrl),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (depNotices.isNotEmpty) ...[
                InlineNoticeBanner(
                  margin: const EdgeInsets.only(bottom: 10),
                  tone: NoticeTone.warning,
                  icon: Icons.warning_amber_rounded,
                  title: depNotices.first.reason,
                ),
              ],
              if (quickValues.isNotEmpty) ...[
                const SectionLabel('Quick Pick'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: quickValues.map((v) {
                    return ChoiceChip(
                      label: Text(v),
                      visualDensity: VisualDensity.compact,
                      selected: valCtrl.text.trim() == v,
                      onSelected: (_) {
                        setDialogState(() => valCtrl.text = v);
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: valCtrl,
                autofocus: quickValues.isEmpty,
                onChanged: (_) => setDialogState(() {}),
                decoration: InputDecoration(
                  labelText: 'Tag Value',
                  helperText: isOpeningHours
                      ? 'Put days before hours, e.g. Tu-Su 09:00-18:00 or Mo-Fr 09:00-18:00; We off'
                      : null,
                  helperMaxLines: 2,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && valCtrl.text.trim().isNotEmpty) {
      final rawVal = valCtrl.text.trim();
      final nextVal = isOpeningHours
          ? OsmTagStandards.normalizeOpeningHours(rawVal)
          : rawVal;
      final tags = Map<String, String>.from(_record.tags)
        ..[existingKey] = nextVal;
      await _persistChanges(override: _record.copyWith(tags: tags));
    }
    valCtrl.dispose();
  }

  Future<void> _modernizeDeprecatedTags() async {
    final hasGps = OsmTagStandards.hasValidGps(
      _record.effectiveLatitude,
      _record.effectiveLongitude,
    );
    final updatedTags = OsmTagStandards.modernizeTags(
      _record.tags,
      hasGpsFix: hasGps,
      stripLocalOnly: false,
    );
    await _persistChanges(override: _record.copyWith(tags: updatedTags));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Updated tags to current OpenStreetMap Wiki standards.'),
      ),
    );
  }

  /// Dual-language helper: lets the mapper easily duplicate/set the name in BOTH
  /// the country's local language AND the user's preferred/confident language.
  Future<void> _editDualLanguageNames() async {
    final countryLang = LocationContextService.guessCountryLanguageOffline(
      _record.latitude,
      _record.longitude,
    );
    final primaryLang = widget.prefs.primaryLanguage;
    final secondaryLang = widget.prefs.secondaryLanguage;

    String selectedLocalLang =
        _record.detectedLanguage.isNotEmpty ? _record.detectedLanguage : countryLang;
    String selectedUserLang = primaryLang != selectedLocalLang
        ? primaryLang
        : secondaryLang;

    final localCtrl = TextEditingController(
      text: _record.tags['name:$selectedLocalLang'] ?? _record.tags['name'] ?? '',
    );
    final userCtrl = TextEditingController(
      text: _record.tags['name:$selectedUserLang'] ??
          _record.tags['name:$secondaryLang'] ??
          _record.tags['name:en'] ??
          '',
    );

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Dual-Language OSM Names'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tag both the local country language and your preferred language:',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: UserPreferencesService.supportedLanguages
                          .any((l) => l.code == selectedLocalLang)
                      ? selectedLocalLang
                      : 'en',
                  decoration: const InputDecoration(
                    labelText: 'Country / Local Language',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: UserPreferencesService.supportedLanguages
                      .map(
                        (l) => DropdownMenuItem(
                          value: l.code,
                          child: Text(l.displayLabel),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDialogState(() => selectedLocalLang = v);
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: localCtrl,
                  decoration: InputDecoration(
                    labelText: 'Local Name (name & name:$selectedLocalLang)',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: UserPreferencesService.supportedLanguages
                          .any((l) => l.code == selectedUserLang)
                      ? selectedUserLang
                      : 'en',
                  decoration: const InputDecoration(
                    labelText: 'Your Language (Confident / Fallback)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: UserPreferencesService.supportedLanguages
                      .map(
                        (l) => DropdownMenuItem(
                          value: l.code,
                          child: Text(l.displayLabel),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setDialogState(() => selectedUserLang = v);
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: userCtrl,
                  decoration: InputDecoration(
                    labelText: 'Translated / User Name (name:$selectedUserLang)',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Apply Both'),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      final tags = Map<String, String>.from(_record.tags);
      final localVal = localCtrl.text.trim();
      final userVal = userCtrl.text.trim();
      if (localVal.isNotEmpty) {
        tags['name'] = localVal;
        tags['name:$selectedLocalLang'] = localVal;
      }
      if (userVal.isNotEmpty) {
        tags['name:$selectedUserLang'] = userVal;
        tags.putIfAbsent('name', () => userVal);
      }
      await _persistChanges(
        override: _record.copyWith(
          tags: tags,
          detectedLanguage: selectedLocalLang,
        ),
      );
    }
    localCtrl.dispose();
    userCtrl.dispose();
  }

  void _cancelActiveAi() {
    _cancelAi = true;
    widget.ai.cancelActiveLocalNano();
    if (mounted) {
      setState(() => _aiProgressStep = 'Cancelling...');
    }
  }

  /// Runs AI (on-device Gemini Nano 4 or Cloud AI) in either
  /// [AiUpdateMode.enrichMerge] or [AiUpdateMode.overwriteAll], then ALWAYS
  /// shows the Before/After Diff confirmation sheet before applying!
  Future<void> _runAiWithDiff(
    AiUpdateMode mode, {
    bool forceCloud = false,
  }) async {
    setState(() {
      _isRunningAi = true;
      _cancelAi = false;
      _aiProgressStep = forceCloud || !widget.ai.willEnrichUseNanoFirst
          ? 'Analyzing with Cloud AI...'
          : 'Starting Gemini Nano 4...';
    });
    try {
      await _persistChanges();
      final diff = await widget.ai.proposeAiUpdate(
        _record,
        mode: mode,
        forceCloud: forceCloud,
        shouldCancel: () => _cancelAi,
        onStatusUpdate: (step) {
          if (!mounted) return;
          setState(() => _aiProgressStep = step);
        },
      );
      if (!mounted || _cancelAi) return;
      final approved = await showEnrichmentDiffSheet(context, diff: diff);
      if (approved != null) {
        await widget.store.saveRecord(approved);
        if (!mounted) return;
        setState(() {
          _record = approved;
        });
      }
    } on AiBatchCancelledException {
      // User tapped Cancel — exit quietly
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            'AI update failed: ${HybridAiService.formatCloudError(e)}',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isRunningAi = false;
          _aiProgressStep = '';
        });
      }
    }
  }

  void _nudgePinCoordinates(double newLat, double newLon) {
    setState(() {
      _record = _record.withManualPinCoordinates(newLat, newLon);
    });
  }

  Future<void> _commitPinCoordinates(double newLat, double newLon) async {
    final updated = _record.withManualPinCoordinates(newLat, newLon);
    await _persistChanges(override: updated);
  }

  Future<void> _selectMainLocationPhoto(int photoIndex) async {
    final updated = _record.selectMainLocationPhoto(photoIndex);
    await _persistChanges(override: updated);
    if (!mounted) return;
    setState(() => _isPlacingPinOnMap = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Main POI coordinates updated to Photo #${photoIndex + 1}.',
        ),
      ),
    );
  }

  Future<void> _applyManualPinFromMap(GeoPoint pt) async {
    final updated = _record.withManualPinCoordinates(pt.latitude, pt.longitude);
    await _persistChanges(override: updated);
    if (!mounted) return;
    setState(() => _isPlacingPinOnMap = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Pin moved to ${pt.latitude.toStringAsFixed(6)}, ${pt.longitude.toStringAsFixed(6)}',
        ),
      ),
    );
  }

  Future<void> _editCoordinatesManually() async {
    final latCtrl = TextEditingController(
      text: _record.effectiveLatitude.toStringAsFixed(6),
    );
    final lonCtrl = TextEditingController(
      text: _record.effectiveLongitude.toStringAsFixed(6),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Correct POI Coordinates'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter exact latitude and longitude (WGS84 decimal degrees) to override GPS & calculation error:',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: latCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(
                labelText: 'Latitude',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: lonCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: const InputDecoration(
                labelText: 'Longitude',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    final lat = double.tryParse(latCtrl.text.trim());
    final lon = double.tryParse(lonCtrl.text.trim());
    latCtrl.dispose();
    lonCtrl.dispose();

    if (ok == true &&
        lat != null &&
        lon != null &&
        OsmTagStandards.hasValidGps(lat, lon)) {
      await _applyManualPinFromMap(GeoPoint(lat, lon));
    }
  }

  Future<void> _exportSingleOsm() async {
    await _persistChanges();
    final xml = OsmExportService.buildOsmXml(records: [_record]);
    final safeId = _record.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    final shortId = safeId.length > 8
        ? safeId.substring(0, 8)
        : (safeId.isEmpty ? 'record' : safeId);
    await OsmExportService.shareExport(
      content: xml,
      fileName: 'edge_mapper_$shortId.osm',
      subject: 'OSM Record: ${_record.displayName}',
    );
  }

  Future<void> _publishToOsm() async {
    await _persistChanges();
    if (!mounted) return;
    final published = await showOsmPublishSheet(
      context,
      osm: widget.osmPublish,
      store: widget.store,
      prefs: widget.prefs,
      connectivity: widget.connectivity,
      initialRecords: [_record],
    );
    if (published == true && mounted) {
      final refreshed =
          widget.store.records.where((r) => r.id == _record.id).toList();
      if (refreshed.isNotEmpty) {
        setState(() => _record = refreshed.first);
      }
    }
  }

  Future<void> _copyTagsToClipboard() async {
    final text =
        _record.tags.entries.map((e) => '${e.key}=${e.value}').join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('OSM tags copied to clipboard')),
    );
  }

  Future<void> _deleteRecord() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Record?'),
        content: Text(
          'Permanently remove "${_record.displayName}" and its attached photos? This cannot be undone.',
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

    await widget.store.deleteRecord(_record.id);
    if (!mounted) return;
    if (widget.embedded) {
      widget.onDeleted?.call();
    } else {
      Navigator.pop(context);
    }
  }

  List<Widget> _buildHeaderActions() {
    final scheme = Theme.of(context).colorScheme;
    return [
      IconButton(
        tooltip: 'Delete record',
        onPressed: _deleteRecord,
        icon: Icon(
          Icons.delete_outline_rounded,
          size: 21,
          color: scheme.error,
        ),
      ),
      PopupMenuButton<String>(
        tooltip: 'More actions',
        icon: const Icon(Icons.more_vert_rounded, size: 21),
        onSelected: (action) {
          switch (action) {
            case 'copy':
              _copyTagsToClipboard();
            case 'export':
              _exportSingleOsm();
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'copy',
            child: Row(
              children: [
                Icon(Icons.copy_rounded, size: 18),
                SizedBox(width: 10),
                Text('Copy OSM tags'),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'export',
            child: Row(
              children: [
                Icon(Icons.ios_share_rounded, size: 18),
                SizedBox(width: 10),
                Text('Export .osm XML'),
              ],
            ),
          ),
        ],
      ),
    ];
  }

  Future<void> _addPhotosAndMerge({
    required ImageSource source,
    bool pickMultiple = false,
  }) async {
    final added = <String>[];
    final isGallery = pickMultiple || source == ImageSource.gallery;
    if (pickMultiple) {
      final list = await _picker.pickMultiImage(
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (list.isEmpty) return;
      for (final x in list.take(6)) {
        added.add(await widget.store.persistPickedPhotoFile(x));
      }
    } else {
      final x = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (x == null) return;
      added.add(await widget.store.persistPickedPhotoFile(x));
    }

    final livePos = widget.store.sensors.currentPosition;
    final liveHeading = widget.store.sensors.headingDegrees;
    final now = DateTime.now();

    // Preserve existing photo location metadata (seeding primary photo if legacy)
    final locsByPath = <String, PhotoLocationMeta>{
      for (final m in _record.photoLocations) m.photoPath: m,
    };
    if (_record.allPhotoPaths.isNotEmpty) {
      final firstPath = _record.allPhotoPaths[_record.effectivePrimaryPhotoIndex];
      locsByPath.putIfAbsent(
        firstPath,
        () => PhotoLocationMeta(
          photoPath: firstPath,
          latitude: _record.latitude,
          longitude: _record.longitude,
          accuracyMeters: _record.accuracyMeters,
          altitudeMeters: _record.altitudeMeters,
          headingDegrees: _record.headingDegrees,
          sourceLabel: 'Live GPS',
          capturedAt: _record.createdAt,
        ),
      );
    }

    for (final p in added) {
      ExifGpsData? exif;
      if (isGallery) {
        try {
          exif = ExifGpsReader.extractFromBytes(await readPhotoBytes(p));
        } catch (_) {}
      }
      if (exif != null) {
        locsByPath[p] = PhotoLocationMeta(
          photoPath: p,
          latitude: exif.latitude,
          longitude: exif.longitude,
          accuracyMeters: exif.accuracyMeters,
          altitudeMeters: exif.altitudeMeters,
          headingDegrees: exif.headingDegrees,
          sourceLabel: 'Photo EXIF',
          capturedAt: now,
        );
      } else if (!isGallery &&
          livePos != null &&
          OsmTagStandards.hasValidGps(livePos.latitude, livePos.longitude)) {
        locsByPath[p] = PhotoLocationMeta(
          photoPath: p,
          latitude: livePos.latitude,
          longitude: livePos.longitude,
          accuracyMeters: livePos.accuracy,
          altitudeMeters: livePos.altitude,
          headingDegrees: liveHeading,
          sourceLabel: 'Live GPS',
          capturedAt: now,
        );
      } else {
        locsByPath[p] = PhotoLocationMeta(
          photoPath: p,
          sourceLabel: 'No EXIF GPS',
          capturedAt: now,
        );
      }
    }

    final nextPhotos = <String>[..._record.allPhotoPaths, ...added].take(6).toList();
    final nextLocations = nextPhotos
        .map((p) => locsByPath[p])
        .whereType<PhotoLocationMeta>()
        .toList();
    final updated = _record.copyWith(
      photoPaths: nextPhotos,
      photoPath: nextPhotos.isNotEmpty ? nextPhotos.first : null,
      photoLocations: nextLocations,
    );
    await _persistChanges(override: updated);
    if (!mounted) return;
    if (widget.ai.canEnrichRecords) {
      await _runAiWithDiff(AiUpdateMode.enrichMerge);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added ${added.length} photo(s) (${nextPhotos.length} total).',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final headingText = _record.headingDegrees != null
        ? '${_record.headingDegrees!.round()}° ${cardinalDirection(_record.headingDegrees)}'
        : 'N/A';

    final existingPhotos =
        _record.allPhotoPaths.where((p) => photoExists(p)).toList();
    final safeIdx = existingPhotos.isEmpty
        ? 0
        : _selectedPhotoIdx.clamp(0, existingPhotos.length - 1);

    Widget buildMediaAndLocationColumn() => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (existingPhotos.isNotEmpty) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: buildPhotoWidget(
                  existingPhotos[safeIdx],
                  height: 230,
                  width: double.infinity,
                ),
              ),
              const SizedBox(height: 8),
            ],

            // Multi-Photo Strip with Main Location Badge & Selector
            Builder(
              builder: (context) {
                final mainIdx = _record.effectivePrimaryPhotoIndex;
                final selectedPath =
                    existingPhotos.isNotEmpty ? existingPhotos[safeIdx] : null;
                final fullIdx = selectedPath != null
                    ? _record.allPhotoPaths.indexOf(selectedPath)
                    : 0;
                final effectiveFullIdx = fullIdx >= 0 ? fullIdx : 0;
                final selMeta = _record.locationMetaForPhoto(effectiveFullIdx);
                final isSelectedMain =
                    effectiveFullIdx == mainIdx && !_record.isManualPinOverride;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 60,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (var i = 0; i < existingPhotos.length; i++)
                            Builder(
                              builder: (context) {
                                final pIdx = _record.allPhotoPaths
                                    .indexOf(existingPhotos[i]);
                                final isMainThumb = pIdx == mainIdx &&
                                    !_record.isManualPinOverride;
                                final isViewing = i == safeIdx;
                                return Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: InkWell(
                                    onTap: () =>
                                        setState(() => _selectedPhotoIdx = i),
                                    borderRadius: BorderRadius.circular(8),
                                    child: Stack(
                                      children: [
                                        Container(
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(9),
                                            border: Border.all(
                                              color: isMainThumb
                                                  ? const Color(0xFF059669)
                                                  : (isViewing
                                                      ? scheme.primary
                                                      : scheme.outlineVariant),
                                              width: (isMainThumb || isViewing)
                                                  ? 2.2
                                                  : 1,
                                            ),
                                          ),
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(7),
                                            child: buildPhotoWidget(
                                              existingPhotos[i],
                                              width: 54,
                                              height: 54,
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
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              '#${i + 1}',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 9,
                                                fontWeight: FontWeight.w800,
                                              ),
                                            ),
                                          ),
                                        ),
                                        if (isMainThumb)
                                          Positioned(
                                            left: 3,
                                            bottom: 3,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 4,
                                                vertical: 1,
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
                                                    size: 9,
                                                    color: Colors.white,
                                                  ),
                                                  SizedBox(width: 1),
                                                  Text(
                                                    'MAIN',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 8,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          if (_record.allPhotoPaths.length < 6) ...[
                            if (!kIsWeb)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: OutlinedButton.icon(
                                  onPressed: _isRunningAi
                                      ? null
                                      : () => _addPhotosAndMerge(
                                            source: ImageSource.camera,
                                          ),
                                  icon: const Icon(
                                    Icons.add_a_photo_outlined,
                                    size: 15,
                                  ),
                                  label: const Text('+ Camera'),
                                ),
                              ),
                            OutlinedButton.icon(
                              onPressed: _isRunningAi
                                  ? null
                                  : () => _addPhotosAndMerge(
                                        source: ImageSource.gallery,
                                        pickMultiple: true,
                                      ),
                              icon: const Icon(
                                Icons.collections_outlined,
                                size: 15,
                              ),
                              label: const Text('+ Add Photos & AI Merge'),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (existingPhotos.length > 1 ||
                        _record.isManualPinOverride) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isSelectedMain
                              ? const Color(0xFF059669).withValues(alpha: 0.08)
                              : scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSelectedMain
                                ? const Color(0xFF059669).withValues(alpha: 0.4)
                                : scheme.outlineVariant,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _record.isManualPinOverride
                                  ? Icons.edit_location_alt_rounded
                                  : Icons.location_on_rounded,
                              size: 16,
                              color: isSelectedMain ||
                                      _record.isManualPinOverride
                                  ? const Color(0xFF059669)
                                  : scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isSelectedMain
                                        ? 'Photo #${safeIdx + 1} is the main POI location source'
                                        : _record.isManualPinOverride
                                            ? 'Manual map pin active (viewing Photo #${safeIdx + 1})'
                                            : 'Viewing Photo #${safeIdx + 1} · Main location is Photo #${mainIdx + 1}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    selMeta != null && selMeta.hasCoordinates
                                        ? '${selMeta.sourceLabel}: ${selMeta.latitude!.toStringAsFixed(5)}, ${selMeta.longitude!.toStringAsFixed(5)}'
                                            '${selMeta.accuracyMeters != null ? ' (±${selMeta.accuracyMeters!.toStringAsFixed(0)}m)' : ''}'
                                        : 'No separate GPS/EXIF stored on Photo #${safeIdx + 1}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            if (!isSelectedMain &&
                                selMeta != null &&
                                selMeta.hasCoordinates) ...[
                              const SizedBox(width: 6),
                              FilledButton.tonal(
                                onPressed: () =>
                                    _selectMainLocationPhoto(effectiveFullIdx),
                                style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                                child: Text('Use #${safeIdx + 1} as Main'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 12),

            // Mini OSM Map showing Camera -> Extrapolated Feature Pin + Error Rings + Tap-to-Correct
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: OsmMapWidget(
                tileService: widget.tiles,
                isOnline: widget.connectivity.isOnline,
                focusRecord: _record,
                height: 210,
                initialZoom: 18,
                showOfflineDownloadButton: false,
                enablePinPlacement: _isPlacingPinOnMap,
                onTapCoordinate: _applyManualPinFromMap,
              ),
            ),
            const SizedBox(height: 12),

            // Spatial Extrapolation, Error Breakdown & Correction Card
            Builder(
              builder: (context) {
                final u = _record.positionUncertainty;
                final errColor = switch (u.severity) {
                  PositionUncertaintySeverity.highPrecision =>
                    const Color(0xFF059669),
                  PositionUncertaintySeverity.moderate =>
                    const Color(0xFFD97706),
                  PositionUncertaintySeverity.needsCorrection =>
                    const Color(0xFFDC2626),
                };

                return SurfacePanel(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: SectionLabel('Location & Position Error'),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: errColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(99),
                              border: Border.all(
                                color: errColor.withValues(alpha: 0.45),
                              ),
                            ),
                            child: Text(
                              u.isManualOverride
                                  ? 'Manual Pin (~±2m)'
                                  : '±${u.totalCombinedErrorMeters.toStringAsFixed(1)}m · ${u.severity.label}',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: errColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _record.isManualPinOverride
                            ? 'POI Pin (manually corrected on map)'
                            : 'POI Pin (+${_record.estimatedOffsetMeters.toStringAsFixed(0)}m · $headingText · from Photo #${_record.effectivePrimaryPhotoIndex + 1})',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${_record.effectiveLatitude.toStringAsFixed(6)}, ${_record.effectiveLongitude.toStringAsFixed(6)}',
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Camera GPS (Photo #${_record.effectivePrimaryPhotoIndex + 1}): '
                        '${_record.latitude.toStringAsFixed(5)}, ${_record.longitude.toStringAsFixed(5)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontSize: 11.5,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                      ),
                      const SizedBox(height: 8),

                      // Explicit GPS Measurement vs Extrapolation Calculation Error Breakdown
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: errColor.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: errColor.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              u.isManualOverride
                                  ? 'Manually corrected on OSM map (replaces GPS & extrapolation estimate).'
                                  : 'Error breakdown (shown as rings on map above):',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: errColor,
                              ),
                            ),
                            if (!u.isManualOverride) ...[
                              const SizedBox(height: 4),
                              Text(
                                '• GPS measurement error: '
                                '${u.gpsMeasurementErrorMeters != null ? '±${u.gpsMeasurementErrorMeters!.toStringAsFixed(1)} m' : 'Unknown (assumed ~10 m)'}',
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              Text(
                                '• Calculation error (${_record.estimatedOffsetMeters.toStringAsFixed(0)}m offset & compass): '
                                '±${u.extrapolationCalcErrorMeters.toStringAsFixed(1)} m '
                                '(distance ±${u.distanceCalcErrorMeters.toStringAsFixed(1)}m, bearing ±${u.bearingCalcErrorMeters.toStringAsFixed(1)}m)',
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              Text(
                                '• Total estimated uncertainty: ±${u.totalCombinedErrorMeters.toStringAsFixed(1)} m',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),

                      // User Pin Correction Actions
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: () => setState(
                              () => _isPlacingPinOnMap = !_isPlacingPinOnMap,
                            ),
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              backgroundColor: _isPlacingPinOnMap
                                  ? const Color(0xFF059669)
                                  : null,
                              foregroundColor:
                                  _isPlacingPinOnMap ? Colors.white : null,
                            ),
                            icon: Icon(
                              _isPlacingPinOnMap
                                  ? Icons.check_rounded
                                  : Icons.edit_location_alt_outlined,
                              size: 16,
                            ),
                            label: Text(
                              _isPlacingPinOnMap
                                  ? 'Tap Map Above...'
                                  : 'Adjust Pin on Map',
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: _editCoordinatesManually,
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.my_location_rounded, size: 15),
                            label: const Text('Edit Lat/Lon'),
                          ),
                          if (_record.isManualPinOverride)
                            TextButton.icon(
                              onPressed: () => _selectMainLocationPhoto(
                                _record.effectivePrimaryPhotoIndex,
                              ),
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: const Icon(Icons.restore_rounded, size: 15),
                              label: Text(
                                'Reset to Photo #${_record.effectivePrimaryPhotoIndex + 1}',
                              ),
                            ),
                        ],
                      ),

                      const SizedBox(height: AppSpacing.sm),
                      FinePinPositionPad(
                        cameraLat: _record.latitude,
                        cameraLon: _record.longitude,
                        pinLat: _record.effectiveLatitude,
                        pinLon: _record.effectiveLongitude,
                        headingDegrees: _record.headingDegrees,
                        onChanged: _nudgePinCoordinates,
                        onChangeEnd: _commitPinCoordinates,
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        );

    Widget buildEditorColumn() => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Clear AI Update options: Add Missing Tags vs Reset & Re-analyze
            if (widget.ai.canEnrichRecords) ...[
              AiUpdateActionsCard(
                canUseLocalNano: widget.ai.canUseLocalNano,
                canUseCloudAi: widget.ai.canUseAnyCloudAi,
                defaultUseNano: widget.ai.willEnrichUseNanoFirst,
                isRunning: _isRunningAi,
                progressStep: _aiProgressStep,
                onCancel: _cancelActiveAi,
                onRun: (mode, forceCloud) => _runAiWithDiff(
                  mode,
                  forceCloud: forceCloud,
                ),
              ),
              const SizedBox(height: 12),
            ] else ...[
              SurfacePanel(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                child: Row(
                  children: [
                    Icon(
                      Icons.cloud_off_rounded,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.connectivity.isOffline
                            ? 'Offline · AI enrichment paused (Nano 4 unavailable)'
                            : 'AI off (${widget.prefs.aiProviderMode.label})',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // OSM Tags Editor (clearly separating published OSM tags vs local-only metadata)
            Builder(
              builder: (context) {
                final split = OsmTagStandards.splitTagsForDisplay(_record.tags);
                final publishableTags = split.publishable;
                final localOnlyTags = split.localOnly;
                final hasGps = OsmTagStandards.hasValidGps(
                  _record.effectiveLatitude,
                  _record.effectiveLongitude,
                );
                final deprecatedNotices = OsmTagStandards.findDeprecatedTags(
                  publishableTags,
                  hasGpsFix: hasGps,
                );
                final deprecatedByKey = {
                  for (final n in deprecatedNotices) n.key: n,
                };
                final hasAutoFixable =
                    deprecatedNotices.any((n) => n.canAutoFix);

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SurfacePanel(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Expanded(
                                child: SectionLabel('OSM Tags'),
                              ),
                              TextButton.icon(
                                onPressed: _editDualLanguageNames,
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                ),
                                icon: const Icon(
                                  Icons.translate_rounded,
                                  size: 15,
                                ),
                                label: const Text('Languages'),
                              ),
                              const SizedBox(width: 4),
                              FilledButton.tonalIcon(
                                onPressed: _pickOsmTag,
                                style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  minimumSize: const Size(0, 36),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                ),
                                icon: const Icon(Icons.add_rounded, size: 16),
                                label: const Text('Add Tag'),
                              ),
                            ],
                          ),
                          if (deprecatedNotices.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFD97706)
                                    .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFFD97706)
                                      .withValues(alpha: 0.45),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.warning_amber_rounded,
                                    size: 18,
                                    color: Color(0xFFB45309),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '${deprecatedNotices.length} deprecated or non-existent OSM tag${deprecatedNotices.length == 1 ? '' : 's'} detected.',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFFB45309),
                                      ),
                                    ),
                                  ),
                                  if (hasAutoFixable)
                                    FilledButton.tonal(
                                      onPressed: _modernizeDeprecatedTags,
                                      style: FilledButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      child: const Text('Auto-Fix'),
                                    ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          ...publishableTags.entries.map((entry) {
                            final dep = deprecatedByKey[entry.key];
                            final wikiUrl = OsmTagStandards.wikiUrlForTag(
                              entry.key,
                              entry.value,
                            );
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Material(
                                color: dep != null
                                    ? context.semanticColors.warningContainer
                                    : scheme.surfaceContainerLow,
                                shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(AppRadii.md),
                                  side: BorderSide(
                                    color: dep != null
                                        ? context.semanticColors.warning
                                            .withValues(alpha: 0.45)
                                        : scheme.outlineVariant
                                            .withValues(alpha: 0.7),
                                  ),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.only(
                                  left: 12,
                                  right: 4,
                                ),
                                title: Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        entry.key,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 12.5,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    ),
                                    if (dep != null) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFD97706)
                                              .withValues(alpha: 0.18),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'DEPRECATED',
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFFB45309),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      entry.value,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                    if (dep != null)
                                      Text(
                                        'Recommended: ${dep.replacementSummary}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFFB45309),
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                  ],
                                ),
                                onTap: () =>
                                    _editExistingTag(entry.key, entry.value),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: 'Check OSM Wiki documentation',
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(
                                        Icons.menu_book_outlined,
                                        size: 17,
                                        color: scheme.primary,
                                      ),
                                      onPressed: () =>
                                          openExternalUrl(wikiUrl),
                                    ),
                                    IconButton(
                                      tooltip: 'Remove tag',
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(
                                        Icons.close_rounded,
                                        size: 17,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                      onPressed: () async {
                                        final next = Map<String, String>.from(
                                          _record.tags,
                                        )..remove(entry.key);
                                        await _persistChanges(
                                          override:
                                              _record.copyWith(tags: next),
                                        );
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                          }),
                        ],
                      ),
                    ),
                    if (localOnlyTags.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      SurfacePanel(
                        padding: const EdgeInsets.all(12),
                        borderColor:
                            scheme.outlineVariant.withValues(alpha: 0.8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.visibility_off_outlined,
                                  size: 16,
                                  color: scheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Not Published to OSM (${localOnlyTags.length})',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () async {
                                    final next = Map<String, String>.from(
                                      _record.tags,
                                    )..removeWhere(
                                        (k, _) => localOnlyTags.containsKey(k),
                                      );
                                    await _persistChanges(
                                      override: _record.copyWith(tags: next),
                                    );
                                  },
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  child: const Text('Clear'),
                                ),
                              ],
                            ),
                            Text(
                              'Local capture metadata only — excluded when uploading to OpenStreetMap.',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: localOnlyTags.entries
                                  .map(
                                    (e) => InputChip(
                                      avatar: Icon(
                                        Icons.lock_outline_rounded,
                                        size: 14,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                      label: Text(
                                        '${e.key}=${e.value}',
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 11.5,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                      onDeleted: () async {
                                        final next = Map<String, String>.from(
                                          _record.tags,
                                        )..remove(e.key);
                                        await _persistChanges(
                                          override:
                                              _record.copyWith(tags: next),
                                        );
                                      },
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        );

    final workflowStepIndex = switch (_record.status) {
      RecordStatus.draftOffline => 0,
      RecordStatus.aiEnriched || RecordStatus.readyToUpload => 1,
      RecordStatus.uploaded => 2,
    };

    final bodyContent = ListenableBuilder(
      listenable: Listenable.merge([widget.ai, widget.connectivity]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final isTwoCol = constraints.maxWidth >= 760;
          final progressHeader = SurfacePanel(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: 10,
            ),
            radius: AppRadii.md,
            child: WorkflowStepStrip(
              steps: const ['Captured', 'Enriched', 'Published'],
              activeIndex: workflowStepIndex,
            ),
          );

          if (isTwoCol) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      progressHeader,
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: (constraints.maxWidth * 0.42)
                                .clamp(320.0, 440.0),
                            child: buildMediaAndLocationColumn(),
                          ),
                          const SizedBox(width: 22),
                          Expanded(child: buildEditorColumn()),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    progressHeader,
                    buildMediaAndLocationColumn(),
                    const SizedBox(height: 12),
                    buildEditorColumn(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    final publishDock = BottomActionDock(
      safeAreaBottom: !widget.embedded,
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _publishToOsm,
          icon: Icon(
            _record.status == RecordStatus.uploaded
                ? Icons.public_rounded
                : Icons.publish_rounded,
            size: 19,
          ),
          label: Text(
            _record.status == RecordStatus.uploaded
                ? 'Published · Update'
                : 'Publish to OSM',
          ),
        ),
      ),
    );

    if (widget.embedded) {
      return Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _record.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ..._buildHeaderActions(),
              ],
            ),
          ),
          Expanded(child: bodyContent),
          publishDock,
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_record.displayName),
        actions: _buildHeaderActions(),
      ),
      body: bodyContent,
      bottomNavigationBar: publishDock,
    );
  }
}
