import 'package:flutter/material.dart';

import '../data/osm_tag_standards.dart';
import '../models/osm_record.dart';
import '../services/osm_browser_bridge.dart';
import '../services/osm_duplicate_service.dart';
import '../theme/app_theme.dart';
import 'osm_tag_selector_sheet.dart';
import 'responsive_layout.dart';

/// Opens a tag overview & improvement sheet for an existing OpenStreetMap point
/// or building tapped on the Capture surrounding coverage map.
///
/// Returns the updated full tag map if the user adds or improves at least one
/// tag and saves; returns `null` if dismissed.
Future<Map<String, String>?> showOsmMappedFeatureSheet(
  BuildContext context, {
  required NearbyOsmElement element,
}) {
  return showAdaptiveSheet<Map<String, String>>(
    context: context,
    desktopMaxWidth: 560,
    builder: (_) => _OsmMappedFeatureSheet(element: element),
  );
}

class _OsmMappedFeatureSheet extends StatefulWidget {
  final NearbyOsmElement element;

  const _OsmMappedFeatureSheet({required this.element});

  @override
  State<_OsmMappedFeatureSheet> createState() => _OsmMappedFeatureSheetState();
}

class _OsmMappedFeatureSheetState extends State<_OsmMappedFeatureSheet> {
  static const Map<String, List<String>> _quickPresetsByKey = {
    'building': [
      'apartments',
      'house',
      'commercial',
      'retail',
      'office',
      'school',
      'industrial',
      'public',
      'church',
    ],
    'building:levels': ['1', '2', '3', '4', '5', '6', '8', '10'],
    'roof:shape': ['flat', 'gabled', 'hipped', 'pyramidal', 'skillion'],
    'wheelchair': ['yes', 'limited', 'no'],
    'opening_hours': [
      'Mo-Fr 09:00-18:00',
      'Mo-Sa 09:00-19:00',
      'Mo-Su 08:00-20:00',
      '24/7',
    ],
    'outdoor_seating': ['yes', 'no'],
    'payment:credit_cards': ['yes', 'no'],
    'fee': ['yes', 'no'],
    'changing_table': ['yes', 'no'],
    'unisex': ['yes', 'no'],
    'backrest': ['yes', 'no'],
    'armrest': ['yes', 'no'],
    'material': ['wood', 'metal', 'stone', 'concrete', 'plastic'],
    'seats': ['2', '3', '4'],
    'cuisine': ['coffee_shop', 'japanese', 'italian', 'french', 'bakery', 'ramen'],
  };

  late Map<String, String> _workingTags;

  @override
  void initState() {
    super.initState();
    _workingTags = Map<String, String>.from(widget.element.tags);
  }

  Map<String, String> get _addedOrChangedTags {
    final changes = <String, String>{};
    for (final entry in _workingTags.entries) {
      if (widget.element.tags[entry.key] != entry.value) {
        changes[entry.key] = entry.value;
      }
    }
    return changes;
  }

  Future<void> _promptValueForKey(String key, {String? initialValue}) async {
    final presets = _quickPresetsByKey[key] ?? const <String>[];
    final ctrl = TextEditingController(
      text: initialValue ?? _workingTags[key] ?? '',
    );
    final wikiUrl = OsmTagStandards.wikiUrlForTag(key, ctrl.text);

    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Expanded(
              child: Text(
                'Set $key',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Open OSM Wiki docs',
              icon: const Icon(Icons.menu_book_outlined, size: 20),
              onPressed: () => openExternalUrl(wikiUrl),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (presets.isNotEmpty) ...[
                Text(
                  'Quick values:',
                  style: Theme.of(ctx).textTheme.labelMedium,
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: presets
                      .map(
                        (v) => ActionChip(
                          label: Text(v),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.pop(ctx, v),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: ctrl,
                autofocus: presets.isEmpty,
                decoration: InputDecoration(
                  labelText: key,
                  hintText: 'Enter value for $key',
                ),
                onSubmitted: (val) => Navigator.pop(ctx, val.trim()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    ctrl.dispose();

    if (chosen != null && chosen.isNotEmpty && mounted) {
      setState(() => _workingTags[key] = chosen);
    }
  }

  Future<void> _openFullTagCatalog() async {
    final tempRecord = OsmRecord(
      id: 'osm-inspect-${widget.element.type}-${widget.element.id}',
      createdAt: DateTime.now(),
      latitude: widget.element.latitude,
      longitude: widget.element.longitude,
      osmType: widget.element.type,
      summary: widget.element.displayName,
      tags: Map<String, String>.from(_workingTags),
      aiSource: AiSource.manual,
      status: RecordStatus.readyToUpload,
    );
    final chosen = await showOsmTagSelectorSheet(context, record: tempRecord);
    if (chosen != null && mounted) {
      setState(() => _workingTags[chosen.key] = chosen.value);
    }
  }

  Future<void> _openCustomTagDialog() async {
    final keyCtrl = TextEditingController();
    final valCtrl = TextEditingController();
    final result = await showDialog<MapEntry<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Custom OSM Tag'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: keyCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Key',
                hintText: 'e.g. building:levels, name:en',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: valCtrl,
              decoration: const InputDecoration(
                labelText: 'Value',
                hintText: 'e.g. 3',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final k = keyCtrl.text.trim();
              final v = valCtrl.text.trim();
              if (k.isNotEmpty && v.isNotEmpty) {
                Navigator.pop(ctx, MapEntry(k, v));
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    keyCtrl.dispose();
    valCtrl.dispose();

    if (result != null && mounted) {
      setState(() => _workingTags[result.key] = result.value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semanticColors;
    final textTheme = Theme.of(context).textTheme;
    final el = widget.element;
    final isBldgOnly = el.isBuilding && !el.isPoi;
    final changes = _addedOrChangedTags;

    final missingKeys = el.missingRecommendedKeys
        .where((k) => (_workingTags[k] ?? '').trim().isEmpty)
        .toList();
    final canRefineBuilding = _workingTags['building'] == 'yes';

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ModalSheetHeader(
                icon: isBldgOnly
                    ? Icons.apartment_rounded
                    : Icons.check_circle_rounded,
                iconColor:
                    isBldgOnly ? const Color(0xFF0284C7) : semantic.success,
                title: el.displayName,
                subtitle:
                    '${el.type}/${el.id} · ${el.primaryCategory} · ${el.tags.length} existing tag${el.tags.length == 1 ? '' : 's'}',
              ),
              const SizedBox(height: AppSpacing.sm),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SectionLabel(
                        'Current OSM Tags (tap to improve)',
                        trailing: TextButton.icon(
                          onPressed: () => openExternalUrl(
                            'https://www.openstreetmap.org/${el.type}/${el.id}',
                          ),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                          icon: const Icon(Icons.open_in_new_rounded, size: 14),
                          label: const Text('OSM'),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: el.tags.entries.map((entry) {
                          final updatedVal = _workingTags[entry.key];
                          final isChanged =
                              updatedVal != null && updatedVal != entry.value;
                          return ActionChip(
                            avatar: Icon(
                              isChanged
                                  ? Icons.edit_rounded
                                  : Icons.tag_rounded,
                              size: 14,
                              color: isChanged
                                  ? semantic.success
                                  : scheme.onSurfaceVariant,
                            ),
                            backgroundColor: isChanged
                                ? semantic.success.withValues(alpha: 0.12)
                                : null,
                            label: Text(
                              isChanged
                                  ? '${entry.key}=$updatedVal'
                                  : '${entry.key}=${entry.value}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isChanged
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                            onPressed: () => _promptValueForKey(
                              entry.key,
                              initialValue: updatedVal ?? entry.value,
                            ),
                          );
                        }).toList(),
                      ),
                      if (canRefineBuilding || missingKeys.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.md),
                        const SectionLabel('Could Do Better — Tap to Add'),
                        const SizedBox(height: AppSpacing.xs),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            if (canRefineBuilding)
                              ActionChip(
                                avatar: Icon(
                                  Icons.apartment_rounded,
                                  size: 15,
                                  color: scheme.primary,
                                ),
                                label: const Text(
                                  'Refine building type',
                                  style: TextStyle(fontSize: 12),
                                ),
                                onPressed: () => _promptValueForKey(
                                  'building',
                                  initialValue: '',
                                ),
                              ),
                            for (final key in missingKeys)
                              ActionChip(
                                avatar: Icon(
                                  Icons.add_rounded,
                                  size: 15,
                                  color: scheme.primary,
                                ),
                                label: Text(
                                  key,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                onPressed: () => _promptValueForKey(key),
                              ),
                          ],
                        ),
                      ],
                      if (changes.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.md),
                        SectionLabel(
                          'Your Tag Improvements (${changes.length})',
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: changes.entries.map((entry) {
                            final oldVal = el.tags[entry.key];
                            return InputChip(
                              backgroundColor:
                                  semantic.success.withValues(alpha: 0.12),
                              side: BorderSide(
                                color: semantic.success.withValues(alpha: 0.4),
                              ),
                              label: Text(
                                oldVal == null
                                    ? '+ ${entry.key}=${entry.value}'
                                    : '${entry.key}: $oldVal → ${entry.value}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: semantic.success,
                                ),
                              ),
                              onDeleted: () {
                                setState(() {
                                  if (oldVal == null) {
                                    _workingTags.remove(entry.key);
                                  } else {
                                    _workingTags[entry.key] = oldVal;
                                  }
                                });
                              },
                            );
                          }).toList(),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.md),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _openFullTagCatalog,
                              icon: const Icon(Icons.search_rounded, size: 17),
                              label: const Text('Browse Tags'),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _openCustomTagDialog,
                              icon: const Icon(Icons.add_rounded, size: 17),
                              label: const Text('Custom Tag'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton.icon(
                onPressed: changes.isEmpty
                    ? null
                    : () => Navigator.pop(context, _workingTags),
                icon: const Icon(Icons.check_rounded, size: 19),
                label: Text(
                  changes.isEmpty
                      ? 'Add or edit a tag above to save'
                      : 'Save Improvement (+${changes.length} tag${changes.length == 1 ? '' : 's'})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (changes.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  'Saves locally at this feature’s coordinates so you can publish the tag update to OpenStreetMap.',
                  textAlign: TextAlign.center,
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
