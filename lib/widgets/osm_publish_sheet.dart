import 'package:flutter/material.dart';

import '../data/osm_tag_standards.dart';
import '../models/hike_trail.dart';
import '../models/osm_record.dart';
import '../services/connectivity_service.dart';
import '../services/mapper_store.dart';
import '../services/osm_browser_bridge.dart';
import '../services/osm_duplicate_service.dart';
import '../services/osm_export_service.dart';
import '../services/osm_publish_service.dart';
import '../services/osm_tag_verifier_service.dart';
import '../services/user_preferences_service.dart';
import 'osm_auth_sheet.dart';
import 'responsive_layout.dart';

enum _TrailUploadMode { gpxTrace, osmWay }

Future<bool?> showOsmPublishSheet(
  BuildContext context, {
  required OsmPublishService osm,
  required MapperStore store,
  required UserPreferencesService prefs,
  required ConnectivityService connectivity,
  List<OsmRecord> initialRecords = const [],
  HikeTrail? trail,
  List<OsmRecord> linkedTrailRecords = const [],
  OsmDuplicateService? duplicateService,
  OsmTagVerifierService? tagVerifier,
}) {
  return showAdaptiveSheet<bool>(
    context: context,
    desktopMaxWidth: 580,
    builder: (_) => OsmPublishSheet(
      osm: osm,
      store: store,
      prefs: prefs,
      connectivity: connectivity,
      initialRecords: initialRecords,
      trail: trail,
      linkedTrailRecords: linkedTrailRecords,
      duplicateService: duplicateService,
      tagVerifier: tagVerifier,
    ),
  );
}

class OsmPublishSheet extends StatefulWidget {
  final OsmPublishService osm;
  final MapperStore store;
  final UserPreferencesService prefs;
  final ConnectivityService connectivity;
  final List<OsmRecord> initialRecords;
  final HikeTrail? trail;
  final List<OsmRecord> linkedTrailRecords;
  final OsmDuplicateService? duplicateService;
  final OsmTagVerifierService? tagVerifier;

  const OsmPublishSheet({
    super.key,
    required this.osm,
    required this.store,
    required this.prefs,
    required this.connectivity,
    this.initialRecords = const [],
    this.trail,
    this.linkedTrailRecords = const [],
    this.duplicateService,
    this.tagVerifier,
  });

  @override
  State<OsmPublishSheet> createState() => _OsmPublishSheetState();
}

class _OsmPublishSheetState extends State<OsmPublishSheet> {
  late TextEditingController _commentCtrl;
  late Set<String> _selectedRecordIds;
  _TrailUploadMode _trailMode = _TrailUploadMode.gpxTrace;
  String _gpxVisibility = 'identifiable';
  bool _includeLinkedRecords = true;

  bool _isPublishing = false;
  String _progressText = '';
  String? _errorText;
  OsmPublishResult? _publishResult;
  OsmGpxUploadResult? _gpxResult;

  late final OsmDuplicateService _duplicateService =
      widget.duplicateService ?? OsmDuplicateService();
  late final OsmTagVerifierService _tagVerifier =
      widget.tagVerifier ?? OsmTagVerifierService();
  bool _isCheckingDuplicates = false;
  DuplicateCheckReport? _duplicateReport;
  bool _acknowledgedServerWarning = false;

  bool _isVerifyingTags = false;
  PublishTagVerificationReport? _tagVerificationReport;
  final Map<String, OsmRecord> _recordOverrides = {};

  /// Per record: whether to push tag additions/updates/removals to the chosen existing OSM object.
  final Map<String, bool> _mergeEnabledByRecordId = {};

  /// Per record: user-chosen (or auto-matched) target OSM object (point, building, way) to merge with.
  final Map<String, DuplicateMatch> _selectedMatchByRecordId = {};

  /// Per record: exact subset of tag keys the user selected to add/update on OSM.
  final Map<String, Set<String>> _selectedMergeTagKeys = {};

  /// Per record: exact subset of upstream OSM tag keys the user marked for deletion.
  final Map<String, Set<String>> _selectedRemoveTagKeys = {};

  /// Per record: whether to expand all upstream OSM tags for optional upstream deletion.
  final Map<String, bool> _showAllUpstreamTagsToRemove = {};

  /// Toggle inside the XML preview panel: Git-style diff (default) vs raw XML.
  bool _showRawXml = false;

  @override
  void initState() {
    super.initState();
    final defaultRecords = widget.initialRecords;
    if (defaultRecords.length == 1) {
      _selectedRecordIds = {defaultRecords.first.id};
    } else {
      // Pre-select ready/enriched records that haven't been uploaded yet
      final unuploaded = defaultRecords
          .where((r) => r.status != RecordStatus.uploaded)
          .map((r) => r.id)
          .toSet();
      _selectedRecordIds = unuploaded.isNotEmpty
          ? unuploaded
          : defaultRecords.map((r) => r.id).toSet();
    }

    final defaultComment = _buildDefaultComment();
    _commentCtrl = TextEditingController(text: defaultComment);

    // Automatically scan for OSM duplicates AND verify tags against OSM standards/Taginfo!
    // ignore: unawaited_futures
    _runPrePublishChecks(autoDeselectDuplicates: true);
  }

  OsmRecord _effectiveRecord(OsmRecord rec) => _recordOverrides[rec.id] ?? rec;

  Future<void> _runPrePublishChecks({bool autoDeselectDuplicates = true}) async {
    await _runDuplicateCheck(autoDeselectDuplicates: autoDeselectDuplicates);
    if (!mounted) return;
    await _runTagVerification();
  }

  Future<void> _runTagVerification() async {
    final isTrail = widget.trail != null;
    if (isTrail && _trailMode == _TrailUploadMode.gpxTrace) {
      if (mounted) {
        setState(() {
          _isVerifyingTags = false;
          _tagVerificationReport = const PublishTagVerificationReport(
            ranOnline: false,
            taginfoReachable: true,
            findings: [],
          );
        });
      }
      return;
    }

    final items = <({String id, String label, Map<String, String> tags})>[];
    for (final rec in _activeRecords) {
      items.add((id: rec.id, label: rec.displayName, tags: rec.tags));
    }
    if (widget.trail != null) {
      items.add((
        id: 'trail:${widget.trail!.id}',
        label: widget.trail!.name,
        tags: widget.trail!.tags,
      ));
    }
    for (final upd in _activeTagUpdates) {
      items.add((
        id: 'update:${upd.sourceRecordId ?? '${upd.elementType}/${upd.elementId}'}',
        label: '${upd.elementType}/${upd.elementId}',
        tags: upd.selectedNewTags,
      ));
    }

    if (items.isEmpty) {
      if (mounted) {
        setState(() {
          _isVerifyingTags = false;
          _tagVerificationReport = PublishTagVerificationReport(
            ranOnline: widget.connectivity.isOnline,
            taginfoReachable: widget.connectivity.isOnline,
            findings: const [],
          );
        });
      }
      return;
    }

    setState(() => _isVerifyingTags = true);
    try {
      final report = await _tagVerifier.verifyTagsForPublish(
        items: items,
        isOnline: widget.connectivity.isOnline,
      );
      if (!mounted) return;
      setState(() => _tagVerificationReport = report);
    } finally {
      if (mounted) setState(() => _isVerifyingTags = false);
    }
  }

  Future<void> _removeConfirmedInvalidTags() async {
    final report = _tagVerificationReport;
    if (report == null || !report.hasConfirmedInvalid) return;

    final invalidByRecord = <String, Set<String>>{};
    final invalidByUpdateRecord = <String, Set<String>>{};

    for (final finding in report.confirmedInvalid) {
      if (finding.itemId.startsWith('update:')) {
        final recId = finding.itemId.substring('update:'.length);
        invalidByUpdateRecord
            .putIfAbsent(recId, () => <String>{})
            .add(finding.key);
      } else if (!finding.itemId.startsWith('trail:')) {
        invalidByRecord
            .putIfAbsent(finding.itemId, () => <String>{})
            .add(finding.key);
      }
    }

    for (final entry in invalidByRecord.entries) {
      final allCandidates = [
        ...widget.initialRecords,
        ...widget.linkedTrailRecords,
      ];
      OsmRecord? target;
      for (final r in allCandidates) {
        if (r.id == entry.key) {
          target = _effectiveRecord(r);
          break;
        }
      }
      if (target == null) continue;
      final updatedTags = Map<String, String>.from(target.tags);
      for (final badKey in entry.value) {
        updatedTags.remove(badKey);
      }
      final updatedRecord = target.copyWith(tags: updatedTags);
      _recordOverrides[target.id] = updatedRecord;
      await widget.store.saveRecord(updatedRecord, touchUpdatedAt: false);
    }

    if (mounted) {
      setState(() {
        for (final entry in invalidByUpdateRecord.entries) {
          final current = _selectedMergeTagKeys[entry.key];
          if (current != null) {
            _selectedMergeTagKeys[entry.key] =
                Set<String>.from(current)..removeAll(entry.value);
          }
        }
      });
      await _runTagVerification();
    }
  }

  Future<void> _runDuplicateCheck({bool autoDeselectDuplicates = true}) async {
    final recordsToScan = (widget.trail != null
            ? widget.linkedTrailRecords
            : widget.initialRecords)
        .map(_effectiveRecord)
        .toList();
    if (recordsToScan.isEmpty && widget.trail == null) return;

    setState(() {
      _isCheckingDuplicates = true;
      _acknowledgedServerWarning = false;
    });
    try {
      final report = await _duplicateService.checkDuplicates(
        records: recordsToScan,
        trail: widget.trail,
        isOnline: widget.connectivity.isOnline,
        osmApiBaseUrl: widget.osm.apiBaseUrl,
      );
      if (!mounted) return;
      setState(() {
        _duplicateReport = report;
        _mergeEnabledByRecordId.clear();
        _selectedMatchByRecordId.clear();
        _selectedMergeTagKeys.clear();
        _selectedRemoveTagKeys.clear();
        _showAllUpstreamTagsToRemove.clear();
        if (autoDeselectDuplicates && report.duplicateRecordIds.isNotEmpty) {
          _selectedRecordIds.removeAll(report.duplicateRecordIds);
        }
        // Pre-populate tag additions & modified-tag updates for matched remote OSM POIs
        for (final status in report.recordStatuses) {
          final match = status.strongestMatch;
          if (status.isDuplicate && match != null && match.isRemoteOsmElement) {
            final recId = status.record.id;
            _selectedMatchByRecordId[recId] = match;
            final preselected = <String>{
              ...match.newTagsAvailable.keys,
              ...match.differingTagsAvailable.map((d) => d.key),
            };
            _selectedMergeTagKeys[recId] = preselected;
            _selectedRemoveTagKeys[recId] = <String>{};
            _mergeEnabledByRecordId[recId] =
                preselected.isNotEmpty || match.upstreamOnlyTags.isNotEmpty;
          }
        }
      });
    } finally {
      if (mounted) setState(() => _isCheckingDuplicates = false);
    }
  }

  DuplicateMatch? _effectiveMatchFor(RecordDuplicateStatus status) {
    return _selectedMatchByRecordId[status.record.id] ?? status.strongestMatch;
  }

  /// Collects all unique remote OSM candidate objects (matched + nearby points & buildings)
  /// that the mapper can select to merge tags with.
  List<NearbyOsmElement> _candidateElementsFor(RecordDuplicateStatus status) {
    final seen = <String>{};
    final list = <NearbyOsmElement>[];
    for (final m in status.matches) {
      final el = m.existingElement;
      if (el != null && m.isRemoteOsmElement) {
        final key = '${el.type}/${el.id}';
        if (seen.add(key)) list.add(el);
      }
    }
    for (final el in status.nearbyCandidates) {
      final key = '${el.type}/${el.id}';
      if (seen.add(key)) list.add(el);
    }
    final customEl = _selectedMatchByRecordId[status.record.id]?.existingElement;
    if (customEl != null) {
      final key = '${customEl.type}/${customEl.id}';
      if (seen.add(key)) list.add(customEl);
    }
    return list;
  }

  void _selectTargetElementForRecord(
    RecordDuplicateStatus status,
    NearbyOsmElement? element,
  ) {
    final recId = status.record.id;
    setState(() {
      if (element == null) {
        _selectedMatchByRecordId.remove(recId);
        _mergeEnabledByRecordId[recId] = false;
        _selectedMergeTagKeys.remove(recId);
        _selectedRemoveTagKeys.remove(recId);
        _selectedRecordIds.add(recId);
        return;
      }

      // Reuse an existing DuplicateMatch if present, else compute tag diff for this chosen node/building
      DuplicateMatch? chosen;
      for (final m in status.matches) {
        if (m.existingOsmType == element.type &&
            m.existingOsmId == element.id &&
            m.existingElement != null) {
          chosen = m;
          break;
        }
      }
      chosen ??= OsmDuplicateService.buildMatchForElement(status.record, element);

      _selectedMatchByRecordId[recId] = chosen;
      final preselected = <String>{
        ...chosen.newTagsAvailable.keys,
        ...chosen.differingTagsAvailable.map((d) => d.key),
      };
      _selectedMergeTagKeys[recId] = preselected;
      _selectedRemoveTagKeys[recId] = <String>{};
      _mergeEnabledByRecordId[recId] = true;
      _selectedRecordIds.remove(recId);
    });
    // ignore: unawaited_futures
    _runTagVerification();
  }

  List<OsmElementTagUpdate> get _activeTagUpdates {
    final report = _duplicateReport;
    if (report == null) return const [];
    final updates = <OsmElementTagUpdate>[];

    for (final status in report.recordStatuses) {
      final recId = status.record.id;
      if (_mergeEnabledByRecordId[recId] != true) continue;
      // Do not also create a new node if the user manually re-checked it as new
      if (_selectedRecordIds.contains(recId)) continue;

      final match = _effectiveMatchFor(status);
      final elem = match?.existingElement;
      if (match == null || elem == null || !match.isRemoteOsmElement) continue;

      final chosenKeys = _selectedMergeTagKeys[recId] ?? const <String>{};
      final removedKeys = Set<String>.from(
        _selectedRemoveTagKeys[recId] ?? const <String>{},
      );

      final selectedNewTags = <String, String>{};
      for (final e in match.newTagsAvailable.entries) {
        if (chosenKeys.contains(e.key) && !removedKeys.contains(e.key)) {
          selectedNewTags[e.key] = e.value;
        }
      }
      for (final d in match.differingTagsAvailable) {
        if (chosenKeys.contains(d.key) && !removedKeys.contains(d.key)) {
          selectedNewTags[d.key] = d.proposedValue;
        }
      }
      if (selectedNewTags.isEmpty && removedKeys.isEmpty) continue;

      updates.add(
        OsmElementTagUpdate(
          elementType: elem.type,
          elementId: elem.id,
          version: elem.version,
          latitude: elem.latitude,
          longitude: elem.longitude,
          nodeIds: elem.nodeIds,
          existingTags: elem.tags,
          selectedNewTags: selectedNewTags,
          removedTagKeys: removedKeys,
          sourceRecordId: recId,
        ),
      );
    }

    return updates;
  }

  void _keepOnlyNonDuplicates() {
    final report = _duplicateReport;
    if (report == null) return;
    setState(() {
      _selectedRecordIds =
          report.nonDuplicateRecords.map((r) => r.id).toSet();
    });
  }

  String _buildDefaultComment() {
    if (widget.trail != null) {
      return 'Add ${widget.trail!.activityType.shortLabel.toLowerCase()} "${widget.trail!.name}" via Edge Mapper';
    }
    if (widget.initialRecords.length == 1) {
      final rec = widget.initialRecords.first;
      return 'Add ${rec.displayName} (${rec.primaryCategoryTag}) via Edge Mapper';
    }
    return widget.prefs.osmChangesetComment;
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  List<OsmRecord> get _activeRecords {
    if (widget.trail != null) {
      return _includeLinkedRecords
          ? widget.linkedTrailRecords.map(_effectiveRecord).toList()
          : const [];
    }
    return widget.initialRecords
        .where((r) => _selectedRecordIds.contains(r.id))
        .map(_effectiveRecord)
        .toList();
  }

  Future<void> _publishNow() async {
    if (!widget.connectivity.isOnline) {
      setState(() => _errorText = 'Go online before publishing to OpenStreetMap.');
      return;
    }

    setState(() {
      _isPublishing = true;
      _errorText = null;
      _progressText = 'Preparing upload...';
    });

    try {
      final comment = _commentCtrl.text.trim();
      await widget.prefs.setOsmChangesetComment(comment);

      if (widget.trail != null && _trailMode == _TrailUploadMode.gpxTrace) {
        final res = await widget.osm.uploadTrailGpxTrace(
          trail: widget.trail!,
          linkedRecords: _activeRecords,
          description: comment,
          visibility: _gpxVisibility,
          onProgress: (step) {
            if (mounted) setState(() => _progressText = step);
          },
        );
        if (!mounted) return;
        setState(() => _gpxResult = res);
      } else {
        final recordsToPush = _activeRecords;
        final trailsToPush =
            widget.trail != null ? [widget.trail!] : const <HikeTrail>[];
        final tagUpdatesToPush = _activeTagUpdates;
        final res = await widget.osm.publishChangeset(
          records: recordsToPush,
          trails: trailsToPush,
          tagUpdates: tagUpdatesToPush,
          changesetComment: comment,
          onProgress: (step) {
            if (mounted) setState(() => _progressText = step);
          },
        );

        // Only mark local records as Submitted when published to Live OSM
        // (sandbox uploads stay editable so users can still publish live!).
        if (!res.isSandbox) {
          final uploadedIds = <String>{
            ...recordsToPush.map((r) => r.id),
            ...tagUpdatesToPush
                .map((u) => u.sourceRecordId)
                .whereType<String>(),
          };
          for (final rec in widget.initialRecords) {
            if (uploadedIds.contains(rec.id)) {
              await widget.store.saveRecord(
                rec.copyWith(status: RecordStatus.uploaded),
                touchUpdatedAt: false,
              );
            }
          }
        }

        if (!mounted) return;
        setState(() => _publishResult = res);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() {
          _isPublishing = false;
          _progressText = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.osm,
        widget.prefs,
        widget.connectivity,
      ]),
      builder: (context, _) {
        final isAuthed = widget.osm.isAuthenticated;
        final isSandbox = widget.osm.isSandbox;
        final isTrail = widget.trail != null;
        final selectedRecords = _activeRecords;
        final selectedTrails =
            isTrail ? [widget.trail!] : const <HikeTrail>[];
        final activeTagUpdates = _activeTagUpdates;

        final issues = OsmPublishService.validateForPublish(
          records: (isTrail && _trailMode == _TrailUploadMode.gpxTrace)
              ? const []
              : selectedRecords,
          trails: selectedTrails,
          tagUpdates: (isTrail && _trailMode == _TrailUploadMode.gpxTrace)
              ? const []
              : activeTagUpdates,
        );
        final hasConfirmedInvalidTags =
            _tagVerificationReport?.hasConfirmedInvalid == true;
        final hasBlocking =
            issues.any((i) => i.isBlocking) || hasConfirmedInvalidTags;
        final needsServerWarningAck =
            _duplicateReport?.outcome == DuplicateCheckOutcome.serverWarning &&
                !_acknowledgedServerWarning;

        final isWide = AppBreakpoints.isWide(context);
        return AdaptiveModalScrollContainer(
          initialChildSize: 0.86,
          builder: (context, scrollCtrl) => SingleChildScrollView(
            controller: scrollCtrl,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isWide)
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Icon(
                        Icons.cloud_upload_rounded,
                        color: scheme.primary,
                        size: 25,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Publish to OpenStreetMap',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(
                          context,
                          _publishResult != null || _gpxResult != null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Success State
                  if (_publishResult != null || _gpxResult != null) ...[
                    _buildSuccessCard(context),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Done'),
                    ),
                  ] else ...[
                    // Server & Account Bar
                    Card(
                      elevation: 0,
                      color: (isSandbox
                              ? const Color(0xFFD97706)
                              : const Color(0xFF059669))
                          .withValues(alpha: 0.1),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: (isSandbox
                                  ? const Color(0xFFD97706)
                                  : const Color(0xFF059669))
                              .withValues(alpha: 0.4),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Icon(
                              isSandbox
                                  ? Icons.science_rounded
                                  : Icons.public_rounded,
                              color: isSandbox
                                  ? const Color(0xFFB45309)
                                  : const Color(0xFF047857),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.osm.serverLabel,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13.5,
                                    ),
                                  ),
                                  Text(
                                    isAuthed
                                        ? 'Signed in as ${widget.osm.username.isNotEmpty ? widget.osm.username : 'OSM user'}'
                                        : 'Not signed in — connect your OSM account',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            FilledButton.tonal(
                              onPressed: _isPublishing
                                  ? null
                                  : () => showOsmAuthSheet(
                                        context,
                                        osm: widget.osm,
                                        prefs: widget.prefs,
                                      ),
                              child: Text(isAuthed ? 'Account' : 'Sign In'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Pre-Upload OpenStreetMap Duplicate Check Panel
                    _buildDuplicateCheckBanner(context, isTrail: isTrail),
                    const SizedBox(height: 12),

                    // Trail upload mode selector (GPX trace vs OSM Way)
                    if (isTrail) ...[
                      SegmentedButton<_TrailUploadMode>(
                        segments: const [
                          ButtonSegment(
                            value: _TrailUploadMode.gpxTrace,
                            icon: Icon(Icons.route_rounded, size: 16),
                            label: Text('GPX Trace (Rec.)'),
                          ),
                          ButtonSegment(
                            value: _TrailUploadMode.osmWay,
                            icon: Icon(Icons.edit_road_rounded, size: 16),
                            label: Text('OSM Map Way'),
                          ),
                        ],
                        selected: {_trailMode},
                        onSelectionChanged: (s) =>
                            setState(() => _trailMode = s.first),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _trailMode == _TrailUploadMode.gpxTrace
                            ? 'Uploads your GPS track to OSM Public GPS Traces (best for raw GPS logs without risking duplicate map ways).'
                            : 'Creates a new OSM way directly on the map with your highway/surface tags.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 10),
                      if (_trailMode == _TrailUploadMode.gpxTrace)
                        DropdownButtonFormField<String>(
                          initialValue: _gpxVisibility,
                          decoration: const InputDecoration(
                            labelText: 'GPX Trace Visibility',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'identifiable',
                              child: Text('Identifiable (Recommended for OSM)'),
                            ),
                            DropdownMenuItem(
                              value: 'trackable',
                              child: Text('Trackable (anonymous timestamps)'),
                            ),
                            DropdownMenuItem(
                              value: 'public',
                              child: Text('Public'),
                            ),
                            DropdownMenuItem(
                              value: 'private',
                              child: Text('Private'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _gpxVisibility = v);
                          },
                        ),
                      if (widget.linkedTrailRecords.isNotEmpty)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          value: _includeLinkedRecords,
                          onChanged: (v) => setState(
                            () => _includeLinkedRecords = v ?? true,
                          ),
                          title: Text(
                            'Include ${widget.linkedTrailRecords.length} linked POI discovery(s)',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                    ],

                    // Multi-record picker when publishing from RecordsScreen
                    if (!isTrail && widget.initialRecords.length > 1) ...[
                      Row(
                        children: [
                          Text(
                            'Select Records (${selectedRecords.length}/${widget.initialRecords.length})',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () {
                              setState(() {
                                if (_selectedRecordIds.length ==
                                    widget.initialRecords.length) {
                                  _selectedRecordIds.clear();
                                } else {
                                  _selectedRecordIds = widget.initialRecords
                                      .map((r) => r.id)
                                      .toSet();
                                }
                              });
                            },
                            child: Text(
                              _selectedRecordIds.length ==
                                      widget.initialRecords.length
                                  ? 'Clear All'
                                  : 'Select All',
                            ),
                          ),
                        ],
                      ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 200),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: widget.initialRecords.length,
                          itemBuilder: (_, idx) {
                            final rec = widget.initialRecords[idx];
                            final checked = _selectedRecordIds.contains(rec.id);
                            final dupStatus =
                                _duplicateReport?.statusForRecord(rec.id);
                            final isDup = dupStatus?.isDuplicate == true;
                            final match = dupStatus?.strongestMatch;
                            return CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              value: checked,
                              onChanged: (v) {
                                setState(() {
                                  if (v == true) {
                                    _selectedRecordIds.add(rec.id);
                                  } else {
                                    _selectedRecordIds.remove(rec.id);
                                  }
                                });
                              },
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      rec.displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  if (isDup) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFDC2626)
                                            .withValues(alpha: 0.14),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Text(
                                        'DUPLICATE',
                                        style: TextStyle(
                                          color: Color(0xFFB91C1C),
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              subtitle: Text(
                                isDup && match != null
                                    ? 'Matches OSM ${match.osmRef} "${match.existingName}" (${match.distanceMeters.round()}m)'
                                    : '${rec.primaryCategoryTag} • ${rec.status.label}',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: isDup ? const Color(0xFFB91C1C) : null,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],

                    // Changeset Comment / Description
                    TextField(
                      controller: _commentCtrl,
                      maxLines: 2,
                      decoration: InputDecoration(
                        labelText: (isTrail &&
                                _trailMode == _TrailUploadMode.gpxTrace)
                            ? 'GPX Trace Description'
                            : 'OSM Changeset Comment (required)',
                        hintText: 'Describe what you surveyed on the ground',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Note if any local-only metadata tags are present & excluded from OSM upload
                    Builder(
                      builder: (context) {
                        final excludedKeys = <String>{};
                        for (final r in selectedRecords) {
                          excludedKeys.addAll(
                            OsmTagStandards.splitTagsForDisplay(r.tags)
                                .localOnly
                                .keys,
                          );
                        }
                        if (excludedKeys.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.visibility_off_outlined,
                                size: 16,
                                color: scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Local-only tags excluded from OSM upload: ${excludedKeys.join(', ')}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        fontSize: 11.5,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),

                    // Validation Issues
                    for (final issue in issues)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: (issue.isBlocking
                                  ? const Color(0xFFDC2626)
                                  : const Color(0xFFD97706))
                              .withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: (issue.isBlocking
                                    ? const Color(0xFFDC2626)
                                    : const Color(0xFFD97706))
                                .withValues(alpha: 0.45),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              issue.isBlocking
                                  ? Icons.error_outline_rounded
                                  : Icons.warning_amber_rounded,
                              size: 18,
                              color: issue.isBlocking
                                  ? const Color(0xFFB91C1C)
                                  : const Color(0xFFB45309),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    issue.title,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 12.5,
                                      color: issue.isBlocking
                                          ? const Color(0xFFB91C1C)
                                          : const Color(0xFFB45309),
                                    ),
                                  ),
                                  Text(
                                    issue.detail,
                                    style: const TextStyle(fontSize: 11.5),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                    // Pre-Publish AI Hallucination Review & OSM Tag Verification Banner
                    _buildHallucinationReviewBanner(
                      context,
                      selectedRecords: selectedRecords,
                      activeTagUpdates: activeTagUpdates,
                      isTrailGpxOnly:
                          isTrail && _trailMode == _TrailUploadMode.gpxTrace,
                    ),
                    const SizedBox(height: 8),

                    // Expandable XML Payload Preview (Git-style green/red diff by default)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text(
                        (isTrail && _trailMode == _TrailUploadMode.gpxTrace)
                            ? 'Preview GPX XML'
                            : 'Preview OsmChange XML Diff (${selectedRecords.length} new${activeTagUpdates.isNotEmpty ? ', ${activeTagUpdates.length} update(s)' : ''}${isTrail ? ' + 1 way' : ''})',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      children: [
                        if (isTrail && _trailMode == _TrailUploadMode.gpxTrace)
                          Container(
                            width: double.infinity,
                            constraints: const BoxConstraints(maxHeight: 200),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest
                                  .withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: SingleChildScrollView(
                              child: SelectableText(
                                OsmExportService.buildGpx(
                                  records: selectedRecords,
                                  trails: selectedTrails,
                                ),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          )
                        else
                          _buildOsmXmlDiffPreview(
                            context,
                            records: selectedRecords,
                            trails: selectedTrails,
                            tagUpdates: activeTagUpdates,
                          ),
                      ],
                    ),

                    if (_errorText != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDC2626).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color:
                                const Color(0xFFDC2626).withValues(alpha: 0.45),
                          ),
                        ),
                        child: Text(
                          _errorText!,
                          style: const TextStyle(
                            color: Color(0xFFB91C1C),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],

                    if (_isPublishing && _progressText.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      const LinearProgressIndicator(),
                      const SizedBox(height: 6),
                      Text(
                        _progressText,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],

                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: (!isAuthed ||
                              hasBlocking ||
                              _isPublishing ||
                              _isCheckingDuplicates ||
                              _isVerifyingTags ||
                              needsServerWarningAck ||
                              widget.connectivity.isOffline)
                          ? null
                          : _publishNow,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: _isPublishing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.publish_rounded),
                      label: Text(
                        !isAuthed
                            ? 'Sign In to OpenStreetMap First'
                            : widget.connectivity.isOffline
                                ? 'Go Online to Publish'
                                : (_isCheckingDuplicates || _isVerifyingTags)
                                    ? 'Checking OpenStreetMap...'
                                    : hasConfirmedInvalidTags
                                        ? 'Fix or Remove Invalid Tag(s) Above'
                                        : needsServerWarningAck
                                            ? 'Retry Check or Confirm Warning Above'
                                            : (isTrail &&
                                                    _trailMode ==
                                                        _TrailUploadMode.gpxTrace)
                                                ? 'Upload GPX Trace to ${widget.osm.serverLabel}'
                                                : (selectedRecords.isEmpty &&
                                                        selectedTrails.isEmpty &&
                                                        activeTagUpdates.isNotEmpty)
                                                    ? 'Update Existing OSM POI${activeTagUpdates.length == 1 ? '' : 's'}'
                                                    : activeTagUpdates.isNotEmpty
                                                        ? 'Publish ${selectedRecords.length} New + ${activeTagUpdates.length} Updated POI(s)'
                                                        : 'Publish Changeset to ${widget.osm.serverLabel}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ],
              ),
          ),
        );
      },
    );
  }

  Widget _buildHallucinationReviewBanner(
    BuildContext context, {
    required List<OsmRecord> selectedRecords,
    required List<OsmElementTagUpdate> activeTagUpdates,
    required bool isTrailGpxOnly,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final report = _tagVerificationReport;
    final confirmedInvalid = report?.confirmedInvalid ?? const [];
    final unverified = report?.unverifiedWarnings ?? const [];

    // Count items that include AI-generated or AI-enriched tags
    final allInvolvedRecords = <String, OsmRecord>{};
    for (final rec in selectedRecords) {
      allInvolvedRecords[rec.id] = rec;
    }
    for (final upd in activeTagUpdates) {
      final srcId = upd.sourceRecordId;
      if (srcId == null) continue;
      for (final r in widget.initialRecords) {
        if (r.id == srcId) {
          allInvolvedRecords[srcId] = _effectiveRecord(r);
          break;
        }
      }
    }
    final aiAssistedCount = allInvolvedRecords.values
        .where((r) => r.aiSource != AiSource.manual)
        .length;

    final Color accent;
    final IconData icon;
    final String statusBadge;
    if (_isVerifyingTags) {
      accent = scheme.primary;
      icon = Icons.manage_search_rounded;
      statusBadge = 'Verifying...';
    } else if (confirmedInvalid.isNotEmpty) {
      accent = const Color(0xFFDC2626);
      icon = Icons.error_outline_rounded;
      statusBadge = '${confirmedInvalid.length} Invalid Tag${confirmedInvalid.length == 1 ? '' : 's'}';
    } else if (unverified.isNotEmpty) {
      accent = const Color(0xFFD97706);
      icon = Icons.fact_check_outlined;
      statusBadge = 'Review Unverified';
    } else {
      accent = const Color(0xFFD97706);
      icon = Icons.fact_check_rounded;
      statusBadge = isTrailGpxOnly ? 'GPX Track' : 'Tags Checked';
    }

    final Color badgeBg = confirmedInvalid.isNotEmpty
        ? const Color(0xFFDC2626).withValues(alpha: 0.14)
        : (unverified.isEmpty && !_isVerifyingTags && !isTrailGpxOnly
            ? const Color(0xFF059669).withValues(alpha: 0.14)
            : accent.withValues(alpha: 0.14));
    final Color badgeFg = confirmedInvalid.isNotEmpty
        ? const Color(0xFFB91C1C)
        : (unverified.isEmpty && !_isVerifyingTags && !isTrailGpxOnly
            ? const Color(0xFF047857)
            : const Color(0xFFB45309));

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.42)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  confirmedInvalid.isNotEmpty
                      ? 'Invalid / Hallucinated OSM Tag(s) Detected'
                      : 'Review Before Publishing — Possible AI Hallucinations',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                    color: confirmedInvalid.isNotEmpty
                        ? const Color(0xFFB91C1C)
                        : const Color(0xFFB45309),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  statusBadge,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: badgeFg,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (_isVerifyingTags) ...[
            const Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Verifying OSM tag keys & values against OpenStreetMap Taginfo...',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],
          if (confirmedInvalid.isNotEmpty) ...[
            for (final f in confirmedInvalid)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '• ',
                      style: TextStyle(
                        color: Color(0xFFB91C1C),
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${f.key}=${f.value} (${f.itemLabel}): ${f.reason}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFFB91C1C),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _removeConfirmedInvalidTags,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor:
                        const Color(0xFFDC2626).withValues(alpha: 0.14),
                    foregroundColor: const Color(0xFFB91C1C),
                  ),
                  icon: const Icon(Icons.auto_fix_high_rounded, size: 15),
                  label: const Text('Remove Invalid Tag(s)'),
                ),
                TextButton.icon(
                  onPressed: _runTagVerification,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 15),
                  label: const Text('Re-check Taginfo'),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],
          if (unverified.isNotEmpty) ...[
            Text(
              'Could not verify ${unverified.length} tag(s) on live OSM Taginfo — double-check manually:',
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFFB45309),
              ),
            ),
            const SizedBox(height: 3),
            for (final f in unverified)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '• ${f.key}=${f.value} (${f.itemLabel})',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ),
            const SizedBox(height: 6),
          ],
          Text(
            aiAssistedCount > 0
                ? '$aiAssistedCount item${aiAssistedCount == 1 ? '' : 's'} include AI-assisted tags. Even after automated OSM tag checks, AI can still hallucinate or misread place names, opening hours, categories, addresses, or attributes. Please review every tag and the XML diff below against what you observed on the ground before publishing.'
                : 'Automated checks catch invalid OSM tag syntax, but cannot guarantee real-world accuracy. Please review all tags, names, and locations in the XML diff below for possible hallucinations or inaccuracies before publishing to OpenStreetMap.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 11.5,
                  height: 1.35,
                  color: scheme.onSurface,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildDuplicateCheckBanner(
    BuildContext context, {
    required bool isTrail,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final report = _duplicateReport;

    if (_isCheckingDuplicates) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Checking OpenStreetMap for duplicate POIs & tracks...',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    }

    if (report == null) return const SizedBox.shrink();

    final outcome = report.outcome;
    final Color accent;
    final IconData statusIcon;
    final String headline;

    switch (outcome) {
      case DuplicateCheckOutcome.passed:
        accent = const Color(0xFF059669);
        statusIcon = Icons.verified_rounded;
        headline =
            'Duplicate Check Passed (${report.remoteSourceLabel.isNotEmpty ? report.remoteSourceLabel : 'OSM'}) — Ready to add new POI.';
      case DuplicateCheckOutcome.serverWarning:
        accent = const Color(0xFFD97706);
        statusIcon = Icons.warning_amber_rounded;
        headline = 'Duplicate Check Warning — Could not verify with OSM!';
      case DuplicateCheckOutcome.duplicatesFound:
        final hasRemoteUpdates = report.recordStatuses.any(
          (s) => s.isDuplicate && s.strongestMatch?.isRemoteOsmElement == true,
        );
        final hasTagDiffs = report.recordStatuses.any(
          (s) => s.isDuplicate && s.strongestMatch?.hasTagChanges == true,
        );
        if (hasRemoteUpdates && hasTagDiffs) {
          accent = const Color(0xFF0F766E);
          statusIcon = Icons.sync_alt_rounded;
          headline =
              'Existing OSM POI Matched (${report.duplicateRecords.length}) — Review Tag Differences';
        } else if (hasRemoteUpdates) {
          accent = const Color(0xFFD97706);
          statusIcon = Icons.edit_note_rounded;
          headline =
              'Existing OSM POI Matched (${report.duplicateRecords.length}) — Up to Date (or Remove Upstream Tags)';
        } else {
          accent = const Color(0xFFDC2626);
          statusIcon = Icons.content_copy_rounded;
          headline =
              'Already Registered on OSM (${report.duplicateRecords.length} POI${report.duplicateRecords.length == 1 ? '' : 's'}${report.trailStatus?.isDuplicate == true ? ' + track' : ''})';
        }
    }

    return Material(
      color: accent.withValues(alpha: 0.09),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: accent.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(statusIcon, size: 19, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  headline,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                    color: accent,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Retry OSM Duplicate & Tag Check',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                onPressed: () =>
                    _runPrePublishChecks(autoDeselectDuplicates: true),
              ),
            ],
          ),

          // Server / Network failure warning (NEVER presented as passed!)
          if (outcome == DuplicateCheckOutcome.serverWarning) ...[
            const SizedBox(height: 4),
            Text(
              report.warningMessage ??
                  'OpenStreetMap servers did not respond. Duplicates could not be verified.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 11.5,
                    color: scheme.onSurface,
                  ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: () =>
                      _runPrePublishChecks(autoDeselectDuplicates: true),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 15),
                  label: const Text('Retry OSM Check'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: _acknowledgedServerWarning,
              onChanged: (v) =>
                  setState(() => _acknowledgedServerWarning = v ?? false),
              title: const Text(
                'I understand the duplicate check failed — allow publishing anyway',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
            ),
          ],

          // Duplicate / user-selected existing OSM targets + selective tag merge UI
          if (report.recordStatuses.any(
            (s) => s.isDuplicate || _selectedMatchByRecordId.containsKey(s.record.id),
          )) ...[
            if (report.warningMessage != null) ...[
              const SizedBox(height: 2),
              Text(
                report.warningMessage!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
            const SizedBox(height: 8),
            for (final status in report.recordStatuses.where(
              (s) =>
                  s.isDuplicate ||
                  _selectedMatchByRecordId.containsKey(s.record.id),
            ))
              _buildExistingOsmMatchCard(context, status),
            if (report.nonDuplicateRecords.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    'Keeping ${report.nonDuplicateRecords.length} unique new record(s).',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _keepOnlyNonDuplicates,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Keep Only Unique'),
                  ),
                ],
              ),
            ],
          ],

          // Also let mappers link a non-duplicate record to an existing nearby building/point!
          for (final status in report.recordStatuses.where(
            (s) =>
                !s.isDuplicate &&
                !_selectedMatchByRecordId.containsKey(s.record.id) &&
                s.nearbyCandidates.isNotEmpty,
          )) ...[
            const SizedBox(height: 8),
            _buildNearbyMergePickerCard(context, status),
          ],

          if (isTrail && report.trailStatus?.isDuplicate == true) ...[
            const SizedBox(height: 6),
            Text(
              '• Track "${report.trailStatus!.trail.name}": ${report.trailStatus!.matches.first.reason}',
              style: const TextStyle(fontSize: 11.5),
            ),
            if (_trailMode == _TrailUploadMode.osmWay) ...[
              const SizedBox(height: 6),
              FilledButton.tonal(
                onPressed: () =>
                    setState(() => _trailMode = _TrailUploadMode.gpxTrace),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Switch to Safe GPX Trace Instead'),
              ),
            ],
          ],
        ],
      ),
      ),
    );
  }

  Widget _buildOsmXmlDiffPreview(
    BuildContext context, {
    required List<OsmRecord> records,
    required List<HikeTrail> trails,
    required List<OsmElementTagUpdate> tagUpdates,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final diffLines = OsmPublishService.buildOsmChangeDiffLines(
      changesetId: 0,
      records: records,
      trails: trails,
      tagUpdates: tagUpdates,
    );
    final addedCount =
        diffLines.where((l) => l.kind == XmlDiffLineKind.added).length;
    final removedCount =
        diffLines.where((l) => l.kind == XmlDiffLineKind.removed).length;

    final addBg = const Color(0xFF16A34A).withValues(alpha: isDark ? 0.22 : 0.13);
    final addFg = isDark ? const Color(0xFF4ADE80) : const Color(0xFF15803D);
    final remBg = const Color(0xFFDC2626).withValues(alpha: isDark ? 0.24 : 0.13);
    final remFg = isDark ? const Color(0xFFF87171) : const Color(0xFFB91C1C);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: addBg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '+$addedCount added',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: addFg,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: remBg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '-$removedCount removed',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: remFg,
                ),
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() => _showRawXml = !_showRawXml),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(
                _showRawXml ? 'Show Git Diff' : 'Raw XML',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: _showRawXml
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    OsmPublishService.buildOsmChangeXml(
                      changesetId: 0,
                      records: records,
                      trails: trails,
                      tagUpdates: tagUpdates,
                    ),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                )
              : SelectionArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: IntrinsicWidth(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final line in diffLines)
                              Container(
                                color: switch (line.kind) {
                                  XmlDiffLineKind.added => addBg,
                                  XmlDiffLineKind.removed => remBg,
                                  XmlDiffLineKind.context => Colors.transparent,
                                },
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 1.5,
                                ),
                                child: Text(
                                  '${switch (line.kind) {
                                    XmlDiffLineKind.added => '+ ',
                                    XmlDiffLineKind.removed => '- ',
                                    XmlDiffLineKind.context => '  ',
                                  }}${line.text}',
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    height: 1.35,
                                    fontWeight: line.kind == XmlDiffLineKind.context
                                        ? FontWeight.w400
                                        : FontWeight.w700,
                                    color: switch (line.kind) {
                                      XmlDiffLineKind.added => addFg,
                                      XmlDiffLineKind.removed => remFg,
                                      XmlDiffLineKind.context =>
                                        scheme.onSurface.withValues(alpha: 0.8),
                                    },
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildNearbyMergePickerCard(
    BuildContext context,
    RecordDuplicateStatus status,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final candidates = _candidateElementsFor(status);
    if (candidates.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.merge_type_rounded, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Merge "${status.record.displayName}" into a nearby OSM object instead?',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            initialValue: '__create_new__',
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Target OSM node or building',
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            items: [
              const DropdownMenuItem<String>(
                value: '__create_new__',
                child: Text(
                  'Create new standalone point (default)',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12),
                ),
              ),
              for (final el in candidates)
                DropdownMenuItem<String>(
                  value: '${el.type}/${el.id}',
                  child: Row(
                    children: [
                      Icon(
                        el.isBuilding && !el.isPoi
                            ? Icons.apartment_rounded
                            : Icons.place_rounded,
                        size: 15,
                        color: el.isBuilding && !el.isPoi
                            ? const Color(0xFF0284C7)
                            : const Color(0xFF059669),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${el.displayName} (${el.type}/${el.id} · ${el.primaryCategory})',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            onChanged: (val) {
              if (val == null || val == '__create_new__') {
                _selectTargetElementForRecord(status, null);
                return;
              }
              final chosen = candidates.firstWhere(
                (e) => '${e.type}/${e.id}' == val,
              );
              _selectTargetElementForRecord(status, chosen);
            },
          ),
        ],
      ),
    );
  }

  /// Explicitly displays what is ALREADY registered on OpenStreetMap for a
  /// matched or selected POI/building, lets the user pick which nearby OSM
  /// node/building to target, and selectively merge/modify/remove tags!
  Widget _buildExistingOsmMatchCard(
    BuildContext context,
    RecordDuplicateStatus status,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final match = _effectiveMatchFor(status)!;
    final recId = status.record.id;
    final candidates = _candidateElementsFor(status);
    final currentTargetKey = match.isRemoteOsmElement
        ? '${match.existingOsmType}/${match.existingOsmId}'
        : null;
    final existingTags = match.existingTags;
    final mergeEnabled = _mergeEnabledByRecordId[recId] == true;
    final selectedKeys = _selectedMergeTagKeys[recId] ?? <String>{};
    final removedKeys = _selectedRemoveTagKeys[recId] ?? <String>{};
    final showAllToRemove = _showAllUpstreamTagsToRemove[recId] == true;
    final deprecatedUpstreamKeys = OsmTagStandards.findDeprecatedTags(
      existingTags,
    ).map((n) => n.key).toSet();
    final totalSelectedChanges = selectedKeys.length + removedKeys.length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${match.existingName} (${match.osmRef})',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                  ),
                ),
              ),
              if (match.isRemoteOsmElement)
                TextButton.icon(
                  onPressed: () => openExternalUrl(
                    '${widget.osm.webBaseUrl}/${match.existingOsmType}/${match.existingOsmId}',
                  ),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  icon: const Icon(Icons.open_in_new_rounded, size: 13),
                  label: const Text('View OSM', style: TextStyle(fontSize: 11)),
                ),
            ],
          ),
          Text(
            match.reason,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
          ),

          // Allow picking the exact existing OSM point, building, or way to merge tags with
          if (candidates.isNotEmpty) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: ValueKey('target-$recId-${currentTargetKey ?? 'none'}'),
              initialValue: currentTargetKey != null &&
                      candidates
                          .any((e) => '${e.type}/${e.id}' == currentTargetKey)
                  ? currentTargetKey
                  : '__create_new__',
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Target OSM object (point, building, etc.)',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              items: [
                for (final el in candidates)
                  DropdownMenuItem<String>(
                    value: '${el.type}/${el.id}',
                    child: Row(
                      children: [
                        Icon(
                          el.isBuilding && !el.isPoi
                              ? Icons.apartment_rounded
                              : Icons.place_rounded,
                          size: 15,
                          color: el.isBuilding && !el.isPoi
                              ? const Color(0xFF0284C7)
                              : const Color(0xFF059669),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${el.displayName} (${el.type}/${el.id} · ${el.primaryCategory})',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                const DropdownMenuItem<String>(
                  value: '__create_new__',
                  child: Text(
                    'Create new standalone point instead',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
              onChanged: (val) {
                if (val == null || val == '__create_new__') {
                  _selectTargetElementForRecord(status, null);
                  return;
                }
                final chosen = candidates.firstWhere(
                  (e) => '${e.type}/${e.id}' == val,
                );
                _selectTargetElementForRecord(status, chosen);
              },
            ),
          ],

          // Explicitly display all existing tags already registered on OSM (tap X on any chip to mark for upstream removal!)
          if (existingTags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Current tags on OSM (${existingTags.length} — tap × to remove a tag upstream):',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 5,
              runSpacing: 4,
              children: existingTags.entries.map((e) {
                final isMarkedRemoved = removedKeys.contains(e.key);
                final isDep = deprecatedUpstreamKeys.contains(e.key);
                return InputChip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  backgroundColor: isMarkedRemoved
                      ? const Color(0xFFDC2626).withValues(alpha: 0.14)
                      : (isDep
                          ? const Color(0xFFD97706).withValues(alpha: 0.14)
                          : scheme.surfaceContainerHighest),
                  side: BorderSide(
                    color: isMarkedRemoved
                        ? const Color(0xFFDC2626).withValues(alpha: 0.55)
                        : (isDep
                            ? const Color(0xFFD97706).withValues(alpha: 0.5)
                            : Colors.transparent),
                  ),
                  label: Text(
                    '${e.key}=${e.value}${isDep ? ' (deprecated)' : ''}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10.5,
                      decoration: isMarkedRemoved
                          ? TextDecoration.lineThrough
                          : null,
                      color: isMarkedRemoved
                          ? const Color(0xFFB91C1C)
                          : (isDep ? const Color(0xFFB45309) : null),
                    ),
                  ),
                  deleteIcon: Icon(
                    isMarkedRemoved
                        ? Icons.undo_rounded
                        : Icons.close_rounded,
                    size: 13,
                    color: isMarkedRemoved
                        ? const Color(0xFFB91C1C)
                        : scheme.onSurfaceVariant,
                  ),
                  deleteButtonTooltipMessage: isMarkedRemoved
                      ? 'Keep tag on OSM'
                      : 'Remove this tag upstream on OSM',
                  onDeleted: match.isRemoteOsmElement
                      ? () {
                          setState(() {
                            final nextRem = Set<String>.from(removedKeys);
                            if (isMarkedRemoved) {
                              nextRem.remove(e.key);
                            } else {
                              nextRem.add(e.key);
                              _mergeEnabledByRecordId[recId] = true;
                              _selectedRecordIds.remove(recId);
                              // Uncheck from add/modify if removing upstream
                              final nextSel = Set<String>.from(selectedKeys)
                                ..remove(e.key);
                              _selectedMergeTagKeys[recId] = nextSel;
                            }
                            _selectedRemoveTagKeys[recId] = nextRem;
                          });
                        }
                      : null,
                );
              }).toList(),
            ),
          ],

          // Selective tag update / diff / upstream removal panel for matched remote OSM POI
          if (match.isRemoteOsmElement) ...[
            const Divider(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: mergeEnabled,
              onChanged: (v) {
                setState(() {
                  _mergeEnabledByRecordId[recId] = v;
                  if (v) {
                    _selectedRecordIds.remove(recId);
                    if ((_selectedMergeTagKeys[recId] ?? const {}).isEmpty &&
                        (_selectedRemoveTagKeys[recId] ?? const {}).isEmpty) {
                      _selectedMergeTagKeys[recId] = {
                        ...match.newTagsAvailable.keys,
                        ...match.differingTagsAvailable.map((d) => d.key),
                      };
                    }
                  }
                });
              },
              title: Text(
                'Update existing ${match.osmRef} on OSM',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF047857),
                ),
              ),
              subtitle: Text(
                totalSelectedChanges > 0
                    ? '$totalSelectedChanges change${totalSelectedChanges == 1 ? '' : 's'} selected'
                        ' (${selectedKeys.length} add/update, ${removedKeys.length} remove upstream)'
                    : 'Select tags below to add, modify, or remove upstream:',
                style: const TextStyle(fontSize: 11),
              ),
            ),

            // Always show tag differences clearly so modified / removable tags are NEVER hidden!
            if (match.newTagsAvailable.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 2),
                child: Text(
                  'New tags to add (+)',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF047857),
                  ),
                ),
              ),
              for (final entry in match.newTagsAvailable.entries)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: mergeEnabled && selectedKeys.contains(entry.key),
                  onChanged: (checked) {
                    setState(() {
                      final next = Set<String>.from(selectedKeys);
                      if (checked == true) {
                        next.add(entry.key);
                        _mergeEnabledByRecordId[recId] = true;
                        _selectedRecordIds.remove(recId);
                      } else {
                        next.remove(entry.key);
                      }
                      _selectedMergeTagKeys[recId] = next;
                    });
                  },
                  title: Text(
                    '+ ${entry.key}=${entry.value}',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF047857),
                    ),
                  ),
                  secondary: IconButton(
                    tooltip: 'Check OSM Wiki documentation',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.menu_book_outlined,
                      size: 16,
                      color: scheme.primary,
                    ),
                    onPressed: () => openExternalUrl(
                      OsmTagStandards.wikiUrlForTag(entry.key, entry.value),
                    ),
                  ),
                ),
            ],

            if (match.differingTagsAvailable.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.only(top: 6, bottom: 2),
                child: Text(
                  'Modified tags (~ OSM → Yours)',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFB45309),
                  ),
                ),
              ),
              for (final diff in match.differingTagsAvailable)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: mergeEnabled &&
                      selectedKeys.contains(diff.key) &&
                      !removedKeys.contains(diff.key),
                  onChanged: (checked) {
                    setState(() {
                      final next = Set<String>.from(selectedKeys);
                      final nextRem = Set<String>.from(removedKeys);
                      if (checked == true) {
                        next.add(diff.key);
                        nextRem.remove(diff.key);
                        _mergeEnabledByRecordId[recId] = true;
                        _selectedRecordIds.remove(recId);
                      } else {
                        next.remove(diff.key);
                      }
                      _selectedMergeTagKeys[recId] = next;
                      _selectedRemoveTagKeys[recId] = nextRem;
                    });
                  },
                  title: Text(
                    '~ ${diff.key}: "${diff.existingValue}" → "${diff.proposedValue}"',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFB45309),
                    ),
                  ),
                  secondary: IconButton(
                    tooltip: 'Check OSM Wiki documentation',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.menu_book_outlined,
                      size: 16,
                      color: scheme.primary,
                    ),
                    onPressed: () => openExternalUrl(
                      OsmTagStandards.wikiUrlForTag(
                        diff.key,
                        diff.proposedValue,
                      ),
                    ),
                  ),
                ),
            ],

            if (match.upstreamOnlyTags.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.only(top: 6, bottom: 2),
                child: Text(
                  'On OSM but not in your record — check to remove upstream (-)',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFB91C1C),
                  ),
                ),
              ),
              for (final entry in match.upstreamOnlyTags.entries)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: mergeEnabled && removedKeys.contains(entry.key),
                  onChanged: (checked) {
                    setState(() {
                      final nextRem = Set<String>.from(removedKeys);
                      if (checked == true) {
                        nextRem.add(entry.key);
                        _mergeEnabledByRecordId[recId] = true;
                        _selectedRecordIds.remove(recId);
                      } else {
                        nextRem.remove(entry.key);
                      }
                      _selectedRemoveTagKeys[recId] = nextRem;
                    });
                  },
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          '- ${entry.key}=${entry.value}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFB91C1C),
                          ),
                        ),
                      ),
                      if (deprecatedUpstreamKeys.contains(entry.key)) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFDC2626)
                                .withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'DEPRECATED',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFB91C1C),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  secondary: IconButton(
                    tooltip: 'Check OSM Wiki documentation',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.menu_book_outlined,
                      size: 16,
                      color: scheme.primary,
                    ),
                    onPressed: () => openExternalUrl(
                      OsmTagStandards.wikiUrlForTag(entry.key, entry.value),
                    ),
                  ),
                ),
            ],

            // Also show any shared upstream tags marked for removal (via chip × or toggle)
            if (existingTags.isNotEmpty &&
                existingTags.length > match.upstreamOnlyTags.length) ...[
              const SizedBox(height: 2),
              TextButton.icon(
                onPressed: () => setState(
                  () => _showAllUpstreamTagsToRemove[recId] = !showAllToRemove,
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
                icon: Icon(
                  showAllToRemove
                      ? Icons.expand_less_rounded
                      : Icons.delete_sweep_outlined,
                  size: 15,
                ),
                label: Text(
                  showAllToRemove
                      ? 'Hide other upstream tags'
                      : 'Remove any other upstream tag on ${match.osmRef}',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              if (showAllToRemove)
                for (final entry in existingTags.entries.where(
                  (e) => !match.upstreamOnlyTags.containsKey(e.key),
                ))
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: mergeEnabled && removedKeys.contains(entry.key),
                    onChanged: (checked) {
                      setState(() {
                        final nextRem = Set<String>.from(removedKeys);
                        final nextSel = Set<String>.from(selectedKeys);
                        if (checked == true) {
                          nextRem.add(entry.key);
                          nextSel.remove(entry.key);
                          _mergeEnabledByRecordId[recId] = true;
                          _selectedRecordIds.remove(recId);
                        } else {
                          nextRem.remove(entry.key);
                        }
                        _selectedRemoveTagKeys[recId] = nextRem;
                        _selectedMergeTagKeys[recId] = nextSel;
                      });
                    },
                    title: Text(
                      '- ${entry.key}=${entry.value}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0xFFB91C1C),
                      ),
                    ),
                  ),
            ],

            if (!match.hasTagChanges && removedKeys.isEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Your local tags match OSM. Tap × on any upstream tag chip above if you want to remove a tag from OSM.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ],
      ),
        ),
      ),
    );
  }

  Widget _buildSuccessCard(BuildContext context) {
    final res = _publishResult;
    final gpx = _gpxResult;
    final isSandbox = res?.isSandbox ?? gpx?.isSandbox ?? false;
    final url = res?.changesetUrl ?? gpx?.traceUrl ?? '';

    return Card(
      elevation: 0,
      color: const Color(0xFF059669).withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: const Color(0xFF059669).withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  color: Color(0xFF059669),
                  size: 28,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    res != null
                        ? 'Published Changeset #${res.changesetId}!'
                        : 'Uploaded GPX Trace #${gpx!.traceId}!',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: const Color(0xFF047857),
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (res != null) ...[
              Text(
                '${[
                  if (res.createdNodeIds.isNotEmpty)
                    'Created ${res.createdNodeIds.length} node(s)',
                  if (res.createdWayIds.isNotEmpty)
                    'created ${res.createdWayIds.length} way(s)',
                  if (res.updatedNodeIds.isNotEmpty ||
                      res.updatedWayIds.isNotEmpty)
                    'updated ${res.updatedNodeIds.length + res.updatedWayIds.length} existing OSM POI(s) with new tags',
                ].join(', ')} on ${isSandbox ? 'OSM Dev Sandbox' : 'OpenStreetMap Live'}.',
              ),
              if (isSandbox) ...[
                const SizedBox(height: 6),
                const Text(
                  'Sandbox test upload complete — your local record status was left unchanged so you can still publish to Live OSM later.',
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                ),
              ],
            ],
            if (url.isNotEmpty) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => openExternalUrl(url),
                icon: const Icon(Icons.open_in_new_rounded, size: 17),
                label: Text(
                  res != null ? 'View Changeset on OSM' : 'View GPX Trace on OSM',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
