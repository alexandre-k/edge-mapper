import 'package:flutter/material.dart';

import '../models/hike_trail.dart';
import '../services/gps_file_picker.dart';
import '../services/ham_radio_gps_import_service.dart';
import '../services/mapper_store.dart';
import 'responsive_layout.dart';
import 'trail_preview_painter.dart';

/// Opens the Ham Radio External GPS Import modal allowing the user to load
/// `.nmea`, `.log`, `.txt`, `.aprs`, `.gpx`, `.kml`, or `.csv` files (or paste
/// raw NMEA-0183 / APRS / GPX / KML / CSV packets) recorded on external Ham
/// radios (Icom, Yaesu, Kenwood, Anytone, BTECH, Direwolf, APRSdroid, aprs.fi).
Future<HikeTrail?> showHamRadioImportSheet(
  BuildContext context, {
  required MapperStore store,
  ActivityType initialActivity = ActivityType.hiking,
}) {
  return showAdaptiveSheet<HikeTrail>(
    context: context,
    desktopMaxWidth: 560,
    builder: (_) => _HamRadioImportSheet(
      store: store,
      initialActivity: initialActivity,
    ),
  );
}

class _HamRadioImportSheet extends StatefulWidget {
  final MapperStore store;
  final ActivityType initialActivity;

  const _HamRadioImportSheet({
    required this.store,
    required this.initialActivity,
  });

  @override
  State<_HamRadioImportSheet> createState() => _HamRadioImportSheetState();
}

class _HamRadioImportSheetState extends State<_HamRadioImportSheet> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _rawTextCtrl = TextEditingController();

  String? _loadedFileName;
  String _rawContent = '';
  String? _selectedCallsign;
  bool _deduplicateClosePoints = true;
  bool _showPasteBox = false;
  bool _isPickingFile = false;
  bool _isImporting = false;
  String? _pickerError;
  late ActivityType _activityType;
  ImportedGpsTrackResult? _parsed;

  @override
  void initState() {
    super.initState();
    _activityType = widget.initialActivity;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _rawTextCtrl.dispose();
    super.dispose();
  }

  void _reparse({bool updateSuggestedName = false}) {
    if (_rawContent.trim().isEmpty) {
      setState(() {
        _parsed = null;
        _selectedCallsign = null;
      });
      return;
    }

    final result = HamRadioGpsImportService.parse(
      _rawContent,
      fileName: _loadedFileName,
      callsignFilter: _selectedCallsign,
      deduplicateClosePoints: _deduplicateClosePoints,
    );

    // Clear stale callsign filter if the newly loaded file doesn't contain it
    if (_selectedCallsign != null &&
        !result.callsigns.contains(_selectedCallsign)) {
      _selectedCallsign = null;
    }

    setState(() {
      _parsed = result;
      if (updateSuggestedName || _nameCtrl.text.trim().isEmpty) {
        _nameCtrl.text = result.suggestedName;
      }
    });
  }

  Future<void> _pickFile() async {
    setState(() {
      _isPickingFile = true;
      _pickerError = null;
    });
    try {
      final picked = await pickGpsLogFile();
      if (!mounted) return;
      if (picked != null) {
        _loadedFileName = picked.fileName;
        _rawContent = picked.content;
        _selectedCallsign = null;
        _showPasteBox = false;
        _reparse(updateSuggestedName: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pickerError = 'Could not read selected file: $e';
      });
    } finally {
      if (mounted) setState(() => _isPickingFile = false);
    }
  }

  Future<void> _confirmImport() async {
    final parsed = _parsed;
    if (parsed == null || parsed.isEmpty || _isImporting) return;
    setState(() => _isImporting = true);
    try {
      final saved = await widget.store.importExternalGpsTrail(
        parsed: parsed,
        customName: _nameCtrl.text.trim(),
        activityType: _activityType,
        selectedCallsign: _selectedCallsign,
      );
      if (!mounted) return;
      Navigator.pop(context, saved);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pickerError = 'Import failed: $e';
        _isImporting = false;
      });
    }
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(2)} km';
    return '${meters.toStringAsFixed(0)} m';
  }

  String _formatDuration(Duration d) {
    if (d == Duration.zero) return '—';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '${h}h ${m}m' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parsed = _parsed;
    final previewPoints = parsed == null
        ? const <TrailPoint>[]
        : parsed.points.map((p) => p.toTrailPoint('preview')).toList();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.settings_input_antenna_rounded,
                    color: scheme.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Import External Ham Radio GPS',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                      ),
                      Text(
                        'NMEA-0183 (Icom / Yaesu / Kenwood), APRS (TNC2 / Mic-E), GPX, KML & CSV',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Source buttons: File Picker OR Paste Raw Log
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _isPickingFile ? null : _pickFile,
                    icon: _isPickingFile
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.folder_open_rounded, size: 18),
                    label: Text(
                      _loadedFileName != null
                          ? 'Change File'
                          : 'Choose GPS File',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () =>
                      setState(() => _showPasteBox = !_showPasteBox),
                  icon: const Icon(Icons.content_paste_rounded, size: 17),
                  label: Text(_showPasteBox ? 'Hide Paste' : 'Paste Log'),
                ),
              ],
            ),

            if (_loadedFileName != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.description_outlined,
                    size: 15,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _loadedFileName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (parsed != null)
                    SubtleTag(
                      label: parsed.format.shortLabel,
                      tint: scheme.primary,
                    ),
                ],
              ),
            ],

            if (_showPasteBox) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _rawTextCtrl,
                maxLines: 5,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                decoration: const InputDecoration(
                  labelText: 'Paste NMEA-0183, APRS packets, GPX, KML, or CSV',
                  hintText:
                      r'$GPRMC,091500,A,3540.87,N,13946.03,E,...  or  N0CALL-7>APRS:!3540.87N/13946.03E[Hiking',
                ),
                onChanged: (text) {
                  _loadedFileName = null;
                  _rawContent = text;
                  _selectedCallsign = null;
                  _reparse(updateSuggestedName: true);
                },
              ),
            ],

            if (_pickerError != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _pickerError!,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],

            if (parsed != null) ...[
              const SizedBox(height: 14),

              // Callsign filter when APRS / CSV log has multiple heard stations
              if (parsed.callsigns.length > 1) ...[
                Text(
                  'Filter by Radio Callsign (${parsed.callsigns.length} stations found)',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('All Stations'),
                      selected: _selectedCallsign == null,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) {
                        _selectedCallsign = null;
                        _reparse(updateSuggestedName: true);
                      },
                    ),
                    for (final call in parsed.callsigns.take(12))
                      ChoiceChip(
                        label: Text(call),
                        selected: _selectedCallsign == call,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) {
                          _selectedCallsign = call;
                          _reparse(updateSuggestedName: true);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],

              if (parsed.isEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: Text(
                    parsed.warnings.isNotEmpty
                        ? parsed.warnings.join('\n')
                        : 'No valid GPS coordinates found in this log. Make sure GPS fix was locked when recorded.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ] else ...[
                // Offline vector preview of the imported track
                TrailPreviewCard(points: previewPoints),
                const SizedBox(height: 10),

                // Stats strip
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    SubtleTag(
                      label: '${parsed.points.length} track points',
                      tint: scheme.primary,
                    ),
                    SubtleTag(
                      label: _formatDistance(parsed.totalDistanceMeters),
                    ),
                    SubtleTag(
                      label: 'Duration ${_formatDuration(parsed.duration)}',
                    ),
                    if (parsed.minAltitudeMeters != null &&
                        parsed.maxAltitudeMeters != null)
                      SubtleTag(
                        label:
                            'Elev ${parsed.minAltitudeMeters!.round()}–${parsed.maxAltitudeMeters!.round()} m',
                      ),
                    if (parsed.removedDuplicates > 0)
                      SubtleTag(
                        label:
                            '${parsed.removedDuplicates} static dups trimmed',
                      ),
                  ],
                ),

                for (final warn in parsed.warnings) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD97706).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: const Color(0xFFD97706).withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.warning_amber_rounded,
                          size: 16,
                          color: Color(0xFFB45309),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            warn,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFFB45309),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 12),
                TextField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Route Name',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<ActivityType>(
                  key: ValueKey(_activityType),
                  initialValue: _activityType,
                  decoration: const InputDecoration(
                    labelText: 'Activity Type (OSM Route Tags)',
                    isDense: true,
                  ),
                  items: ActivityType.values
                      .map(
                        (t) => DropdownMenuItem(
                          value: t,
                          child: Text('${t.label} (highway=${t.defaultHighway})'),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _activityType = v);
                  },
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _deduplicateClosePoints,
                  onChanged: (v) {
                    _deduplicateClosePoints = v;
                    _reparse();
                  },
                  title: const Text(
                    'Trim stationary duplicate points (< 1 m)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _isImporting ? null : _confirmImport,
                  icon: _isImporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.download_done_rounded, size: 18),
                  label: Text(
                    _isImporting
                        ? 'Importing Route...'
                        : 'Import ${parsed.points.length} Points as ${_activityType.shortLabel}',
                  ),
                ),
              ],
            ] else ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Supported External Ham Radio Logs',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '• Icom (ID-51/52, IC-705, ID-5100) — microSD NMEA .log / .nmea\n'
                      '• Yaesu (FT5DR, FT3DR, FTM-300/400/500) — NMEA & APRS Mic-E\n'
                      '• Kenwood (TH-D74/D75, TM-D710) — NMEA .txt / .nmea & APRS\n'
                      '• Anytone / BTECH / OpenGD77 — CSV GPS logs & APRS\n'
                      '• aprs.fi / APRSdroid / Direwolf — GPX, KML, CSV, TNC2 logs',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
