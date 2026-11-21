import 'package:flutter/material.dart';

import '../data/osm_tag_catalog.dart';
import '../data/osm_tag_standards.dart';
import '../models/osm_record.dart';
import '../services/osm_browser_bridge.dart';
import 'responsive_layout.dart';

/// Opens a probability-ranked OpenStreetMap tag selector tailored to [record].
/// Tags are ordered by probability of matching what is visible in the picture,
/// with instant search across all OSM tags and preset value selection.
Future<MapEntry<String, String>?> showOsmTagSelectorSheet(
  BuildContext context, {
  required OsmRecord record,
}) {
  return showAdaptiveSheet<MapEntry<String, String>>(
    context: context,
    desktopMaxWidth: 560,
    builder: (_) => _OsmTagSelectorSheet(record: record),
  );
}

class _OsmTagSelectorSheet extends StatefulWidget {
  final OsmRecord record;

  const _OsmTagSelectorSheet({required this.record});

  @override
  State<_OsmTagSelectorSheet> createState() => _OsmTagSelectorSheetState();
}

class _OsmTagSelectorSheetState extends State<_OsmTagSelectorSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _selectedCategory = 'All';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _selectEntry(OsmTagEntry entry) async {
    if (!entry.requiresCustomValue && entry.value.isNotEmpty) {
      Navigator.pop(context, MapEntry(entry.key, entry.value));
      return;
    }

    // Tag has configurable values (e.g. cuisine, opening_hours, brand, step_count)
    final ctrl = TextEditingController(
      text: widget.record.tags[entry.key] ?? entry.value,
    );
    final isOpeningHours = entry.key == 'opening_hours';
    final wikiUrl = OsmTagStandards.wikiUrlForTag(entry.key, entry.value);
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Expanded(child: Text('Choose ${entry.key}')),
            IconButton(
              tooltip: 'Check OSM Wiki documentation',
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
              if (entry.description.isNotEmpty) ...[
                Text(
                  entry.description,
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
              ],
              if (entry.suggestedValues.isNotEmpty) ...[
                const Text(
                  'Quick presets:',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: entry.suggestedValues
                      .map(
                        (val) => ActionChip(
                          label: Text(val, style: const TextStyle(fontSize: 12)),
                          onPressed: () => Navigator.pop(ctx, val),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: ctrl,
                decoration: InputDecoration(
                  labelText: 'Value for ${entry.key}',
                  helperText: isOpeningHours
                      ? 'Include 2-letter OSM days before hours, e.g. Tu-Su 09:00-18:00; Mo off'
                      : null,
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
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

    if (chosen != null && chosen.trim().isNotEmpty && mounted) {
      final cleanVal = isOpeningHours
          ? OsmTagStandards.normalizeOpeningHours(chosen.trim())
          : chosen.trim();
      Navigator.pop(context, MapEntry(entry.key, cleanVal));
    }
  }

  Future<void> _addCustomFallbackTag() async {
    final query = _searchController.text.trim();
    String initialKey = '';
    String initialVal = '';
    if (query.contains('=')) {
      final parts = query.split('=');
      initialKey = parts.first.trim();
      initialVal = parts.sublist(1).join('=').trim();
    } else {
      initialKey = query.replaceAll(' ', '_').toLowerCase();
    }

    final keyCtrl = TextEditingController(text: initialKey);
    final valCtrl = TextEditingController(text: initialVal);
    final result = await showDialog<MapEntry<String, String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final curKey = keyCtrl.text.trim();
          final curVal = valCtrl.text.trim();
          final notices = curKey.isNotEmpty
              ? OsmTagStandards.findDeprecatedTags({
                  curKey: curVal.isNotEmpty ? curVal : 'yes',
                })
              : const <DeprecatedTagNotice>[];
          final isLocalOnly = curKey.isNotEmpty &&
              OsmTagStandards.isLocalOnlyTag(curKey, widget.record.tags);

          return AlertDialog(
            title: Row(
              children: [
                const Expanded(child: Text('Add Custom OSM Tag')),
                IconButton(
                  tooltip: 'Check OSM Wiki documentation',
                  icon: const Icon(Icons.menu_book_outlined, size: 20),
                  onPressed: () => openExternalUrl(
                    OsmTagStandards.wikiUrlForTag(curKey, curVal),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: keyCtrl,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'OSM Key (e.g. heritage, operator)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: valCtrl,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'OSM Value',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  if (notices.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD97706).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFFD97706).withValues(alpha: 0.45),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Deprecated OSM tag: ${notices.first.reason}',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFB45309),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Recommended: ${notices.first.replacementSummary}',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (isLocalOnly) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(ctx)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '"$curKey" is local capture metadata and will NOT be published to OpenStreetMap.',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                  ],
                ],
              ),
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
                    // Auto-modernize safely replaceable tags (e.g. day_off -> opening_hours)
                    final modernized = OsmTagStandards.modernizeTags(
                      {...widget.record.tags, k: v},
                      hasGpsFix: OsmTagStandards.hasValidGps(
                        widget.record.effectiveLatitude,
                        widget.record.effectiveLongitude,
                      ),
                    );
                    if (notices.isNotEmpty &&
                        notices.first.canAutoFix &&
                        !modernized.containsKey(k)) {
                      // Return the modernized replacement tag
                      final diffKey = modernized.keys.firstWhere(
                        (mk) => modernized[mk] != widget.record.tags[mk],
                        orElse: () => k,
                      );
                      Navigator.pop(
                        ctx,
                        MapEntry(diffKey, modernized[diffKey] ?? v),
                      );
                      return;
                    }
                    final cleanVal = k == 'opening_hours'
                        ? OsmTagStandards.normalizeOpeningHours(v)
                        : v;
                    Navigator.pop(ctx, MapEntry(k, cleanVal));
                  }
                },
                child: Text(
                  notices.isNotEmpty && notices.first.canAutoFix
                      ? 'Add Modernized'
                      : 'Add',
                ),
              ),
            ],
          );
        },
      ),
    );
    keyCtrl.dispose();
    valCtrl.dispose();

    if (result != null && mounted) {
      Navigator.pop(context, result);
    }
  }

  Color _probColor(int percent, ColorScheme scheme) {
    if (percent >= 70) return const Color(0xFF059669);
    if (percent >= 40) return const Color(0xFFD97706);
    return scheme.onSurfaceVariant;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ranked = OsmTagCatalog.rankForRecord(
      widget.record,
      query: _searchController.text,
      category: _selectedCategory,
    );

    final isWide = AppBreakpoints.isWide(context);
    return AdaptiveModalScrollContainer(
      initialChildSize: 0.84,
      minChildSize: 0.55,
      builder: (context, scrollController) {
        return Column(
          children: [
            if (!isWide) ...[
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.local_offer_rounded, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Smart OSM Tag Picker',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                        ),
                        Text(
                          'Sorted by probability to match your photo',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
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
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _searchController,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search all OSM tags (e.g. bakery, bench, wheelchair)...',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {});
                          },
                        )
                      : null,
                  isDense: true,
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemCount: OsmTagCatalog.categories.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, idx) {
                  final cat = OsmTagCatalog.categories[idx];
                  return ChoiceChip(
                    label: Text(cat, style: const TextStyle(fontSize: 12)),
                    selected: _selectedCategory == cat,
                    onSelected: (_) => setState(() => _selectedCategory = cat),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: ranked.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search_off_rounded,
                              size: 40,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'No standard OSM tag matched your search.',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            FilledButton.tonalIcon(
                              onPressed: _addCustomFallbackTag,
                              icon: const Icon(Icons.add_rounded),
                              label: const Text('Create Custom OSM Tag'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                      itemCount: ranked.length + 1,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (context, index) {
                        if (index == ranked.length) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: OutlinedButton.icon(
                              onPressed: _addCustomFallbackTag,
                              icon: const Icon(Icons.tune_rounded, size: 18),
                              label: const Text(
                                'Didn\'t find your tag? Add custom OSM key=value',
                              ),
                            ),
                          );
                        }

                        final item = ranked[index];
                        final entry = item.entry;
                        final alreadySet =
                            widget.record.tags[entry.key] == entry.value &&
                                entry.value.isNotEmpty;
                        final pct = item.probabilityPercent;
                        final pColor = _probColor(pct, scheme);

                        return Material(
                          color: alreadySet
                              ? scheme.primaryContainer.withValues(alpha: 0.4)
                              : scheme.surfaceContainerHighest
                                  .withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => _selectEntry(entry),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 48,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: pColor.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: pColor.withValues(alpha: 0.35),
                                      ),
                                    ),
                                    child: Text(
                                      '$pct%',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 12,
                                        color: pColor,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                entry.label,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 14,
                                                ),
                                              ),
                                            ),
                                            if (alreadySet)
                                              Icon(
                                                Icons.check_circle_rounded,
                                                size: 16,
                                                color: scheme.primary,
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          entry.requiresCustomValue
                                              ? '${entry.key}=<choose value>'
                                              : entry.tagString,
                                          style: TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 12,
                                            color: scheme.primary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          item.matchReason,
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
                                  IconButton(
                                    tooltip: 'Check OSM Wiki documentation',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => openExternalUrl(
                                      OsmTagStandards.wikiUrlForTag(
                                        entry.key,
                                        entry.value,
                                      ),
                                    ),
                                    icon: Icon(
                                      Icons.menu_book_outlined,
                                      size: 18,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const Icon(
                                    Icons.add_circle_outline_rounded,
                                    size: 20,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
