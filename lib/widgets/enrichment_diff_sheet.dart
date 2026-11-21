import 'package:flutter/material.dart';

import '../data/osm_tag_standards.dart';
import '../models/enrichment_diff.dart';
import '../models/osm_record.dart';
import '../services/mapper_store.dart';
import '../services/osm_browser_bridge.dart';
import '../services/photo_helper.dart';
import 'responsive_layout.dart';

class BatchReviewResult {
  final int appliedCount;
  final int skippedCount;
  final int remainingCount;

  const BatchReviewResult({
    required this.appliedCount,
    required this.skippedCount,
    required this.remainingCount,
  });
}

/// Displays a clear Before/After diff for a single AI Enrichment or Full Overwrite
/// proposal, allowing the mapper to inspect every change, toggle individual
/// fields/tags, and confirm or reject the automated recommendations.
Future<OsmRecord?> showEnrichmentDiffSheet(
  BuildContext context, {
  required EnrichmentDiff diff,
  String? batchProgressLabel,
  VoidCallback? onStopBatch,
}) {
  return showAdaptiveSheet<OsmRecord>(
    context: context,
    desktopMaxWidth: 620,
    builder: (_) => _EnrichmentDiffSheet(
      diff: diff,
      batchProgressLabel: batchProgressLabel,
      onStopBatch: onStopBatch,
    ),
  );
}

/// Displays a unified single-sheet stepper to review ALL pending batch AI diffs
/// in sequence (1/N → 2/N → ... → N/N) without closing/reopening modals between
/// records. Closing early preserves unreviewed diffs in [MapperStore.pendingBatchDiffs]
/// so the user can resume anytime.
Future<BatchReviewResult?> showBatchEnrichmentDiffSheet(
  BuildContext context, {
  required MapperStore store,
}) {
  return showAdaptiveSheet<BatchReviewResult>(
    context: context,
    desktopMaxWidth: 620,
    builder: (_) => _BatchEnrichmentDiffSheet(store: store),
  );
}

class _EnrichmentDiffSheet extends StatefulWidget {
  final EnrichmentDiff diff;
  final String? batchProgressLabel;
  final VoidCallback? onStopBatch;

  const _EnrichmentDiffSheet({
    required this.diff,
    this.batchProgressLabel,
    this.onStopBatch,
  });

  @override
  State<_EnrichmentDiffSheet> createState() => _EnrichmentDiffSheetState();
}

class _EnrichmentDiffSheetState extends State<_EnrichmentDiffSheet> {
  late bool _acceptSummary;
  late bool _acceptDistance;
  late bool _acceptMetadata;
  late Set<String> _acceptedTagKeys;

  @override
  void initState() {
    super.initState();
    _acceptSummary = widget.diff.summaryChanged;
    _acceptDistance = widget.diff.distanceChanged;
    _acceptMetadata =
        widget.diff.osmTypeChanged || widget.diff.languageChanged;
    _acceptedTagKeys =
        widget.diff.changedTags.map((t) => t.key).toSet();
  }

  void _applyAndClose() {
    final approved = widget.diff.buildApprovedRecord(
      acceptSummary: _acceptSummary,
      acceptNotes: false,
      acceptDistance: _acceptDistance,
      acceptMetadata: _acceptMetadata,
      acceptedTagKeys: _acceptedTagKeys,
    );
    Navigator.pop(context, approved);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diff = widget.diff;
    final isOverwrite = diff.mode == AiUpdateMode.overwriteAll;

    final isWide = AppBreakpoints.isWide(context);
    return AdaptiveModalScrollContainer(
      initialChildSize: 0.85,
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
                  if (photoExists(diff.before.photoPath))
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: buildPhotoWidget(
                        diff.before.photoPath!,
                        width: 44,
                        height: 44,
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: (isOverwrite ? Colors.deepOrange : scheme.primary)
                            .withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        isOverwrite
                            ? Icons.auto_fix_high_rounded
                            : Icons.compare_arrows_rounded,
                        color: isOverwrite ? Colors.deepOrange : scheme.primary,
                      ),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                widget.batchProgressLabel != null
                                    ? 'Review AI (${widget.batchProgressLabel})'
                                    : 'Review AI Recommendations',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                            if (widget.onStopBatch != null)
                              TextButton(
                                onPressed: () {
                                  widget.onStopBatch!();
                                  Navigator.pop(context, null);
                                },
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                ),
                                child: const Text('Stop Batch'),
                              ),
                          ],
                        ),
                        Text(
                          '${diff.before.displayName} • ${diff.mode.shortLabel} • ${diff.proposed.aiSource.shortLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Mode explanation + diff stats summary strip
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    diff.mode.description,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: 11.5,
                          color: isOverwrite
                              ? const Color(0xFFC2410C)
                              : const Color(0xFF047857),
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _CountPill(
                        label: '+${diff.addedCount} added',
                        color: const Color(0xFF059669),
                      ),
                      _CountPill(
                        label: '~${diff.modifiedCount} modified',
                        color: const Color(0xFFD97706),
                      ),
                      if (diff.removedCount > 0)
                        _CountPill(
                          label: '-${diff.removedCount} removed',
                          color: const Color(0xFFDC2626),
                        ),
                    ],
                  ),
                ],
              ),
            ),

            const Divider(height: 16),

            Expanded(
              child: !diff.hasAnyChange
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'AI confirmed your current record looks great — no changes suggested!',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      children: [
                        if (diff.summaryChanged)
                          _FieldDiffCard(
                            title: 'Summary',
                            beforeText: diff.before.summary,
                            afterText: diff.proposed.summary,
                            accepted: _acceptSummary,
                            onChanged: (v) =>
                                setState(() => _acceptSummary = v),
                          ),
                        if (diff.distanceChanged)
                          _FieldDiffCard(
                            title: 'Estimated Distance & Extrapolated GPS',
                            beforeText:
                                '${diff.before.estimatedOffsetMeters.toStringAsFixed(1)} m',
                            afterText:
                                '${diff.proposed.estimatedOffsetMeters.toStringAsFixed(1)} m'
                                '${diff.proposed.distanceReasoning.isNotEmpty ? ' — ${diff.proposed.distanceReasoning}' : ''}',
                            accepted: _acceptDistance,
                            onChanged: (v) =>
                                setState(() => _acceptDistance = v),
                          ),
                        if (diff.languageChanged || diff.osmTypeChanged)
                          _FieldDiffCard(
                            title: 'Language & OSM Type',
                            beforeText:
                                'lang=${diff.before.detectedLanguage}, type=${diff.before.osmType}',
                            afterText:
                                'lang=${diff.proposed.detectedLanguage}, type=${diff.proposed.osmType}',
                            accepted: _acceptMetadata,
                            onChanged: (v) =>
                                setState(() => _acceptMetadata = v),
                          ),

                        if (diff.changedTags.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            'OSM Tag Changes (${diff.changedTags.length})',
                            style: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 6),
                          ...diff.changedTags.map((tagDiff) {
                            final checked =
                                _acceptedTagKeys.contains(tagDiff.key);
                            final (badgeText, badgeColor) = switch (tagDiff.kind) {
                              TagDiffKind.added => ('ADD', const Color(0xFF059669)),
                              TagDiffKind.modified => ('EDIT', const Color(0xFFD97706)),
                              TagDiffKind.removed => ('DEL', const Color(0xFFDC2626)),
                              TagDiffKind.unchanged => ('SAME', Colors.grey),
                            };

                            return Card(
                              elevation: 0,
                              margin: const EdgeInsets.only(bottom: 6),
                              color: badgeColor.withValues(alpha: 0.08),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: badgeColor.withValues(alpha: 0.35),
                                ),
                              ),
                              child: CheckboxListTile(
                                value: checked,
                                onChanged: (v) {
                                  setState(() {
                                    if (v == true) {
                                      _acceptedTagKeys.add(tagDiff.key);
                                    } else {
                                      _acceptedTagKeys.remove(tagDiff.key);
                                    }
                                  });
                                },
                                dense: true,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: badgeColor,
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      child: Text(
                                        badgeText,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        tagDiff.key,
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (tagDiff.beforeValue != null)
                                        Text(
                                          'Before: ${tagDiff.beforeValue}',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFFB91C1C),
                                            decoration:
                                                TextDecoration.lineThrough,
                                          ),
                                        ),
                                      if (tagDiff.afterValue != null)
                                        Text(
                                          'After:  ${tagDiff.afterValue}',
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF047857),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                secondary: IconButton(
                                  tooltip: 'Check OSM Wiki documentation',
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    Icons.menu_book_outlined,
                                    size: 17,
                                    color: scheme.primary,
                                  ),
                                  onPressed: () => openExternalUrl(
                                    OsmTagStandards.wikiUrlForTag(
                                      tagDiff.key,
                                      tagDiff.afterValue ?? tagDiff.beforeValue,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                      ],
                    ),
            ),

            // Action bar
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(
                  top: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context, null),
                      icon: const Icon(Icons.close_rounded, size: 18),
                      label: const Text('Reject'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _applyAndClose,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Confirm & Apply'),
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
}

class _BatchEnrichmentDiffSheet extends StatefulWidget {
  final MapperStore store;

  const _BatchEnrichmentDiffSheet({required this.store});

  @override
  State<_BatchEnrichmentDiffSheet> createState() =>
      _BatchEnrichmentDiffSheetState();
}

class _BatchEnrichmentDiffSheetState extends State<_BatchEnrichmentDiffSheet> {
  late int _initialTotal;
  int _stepNumber = 1;
  int _appliedCount = 0;
  int _skippedCount = 0;
  bool _isBusy = false;

  String? _loadedRecordId;
  bool _acceptSummary = false;
  bool _acceptDistance = false;
  bool _acceptMetadata = false;
  Set<String> _acceptedTagKeys = {};

  @override
  void initState() {
    super.initState();
    _initialTotal = widget.store.pendingBatchDiffs.length;
    if (widget.store.pendingBatchDiffs.isNotEmpty) {
      _loadDiffState(widget.store.pendingBatchDiffs.first);
    }
  }

  void _loadDiffState(EnrichmentDiff diff) {
    _loadedRecordId = diff.before.id;
    _acceptSummary = diff.summaryChanged;
    _acceptDistance = diff.distanceChanged;
    _acceptMetadata = diff.osmTypeChanged || diff.languageChanged;
    _acceptedTagKeys = diff.changedTags.map((t) => t.key).toSet();
  }

  void _closeWithSummary() {
    Navigator.pop(
      context,
      BatchReviewResult(
        appliedCount: _appliedCount,
        skippedCount: _skippedCount,
        remainingCount: widget.store.pendingBatchDiffs.length,
      ),
    );
  }

  Future<void> _confirmCurrent(
    EnrichmentDiff diff,
    ScrollController? scrollController,
  ) async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final approved = diff.buildApprovedRecord(
        acceptSummary: _acceptSummary,
        acceptNotes: false,
        acceptDistance: _acceptDistance,
        acceptMetadata: _acceptMetadata,
        acceptedTagKeys: _acceptedTagKeys,
      );
      await widget.store.saveRecord(approved);
      widget.store.removePendingBatchDiff(diff.before.id);
      _appliedCount++;

      if (!mounted) return;
      final remaining = widget.store.pendingBatchDiffs;
      if (remaining.isEmpty) {
        _closeWithSummary();
        return;
      }

      setState(() {
        _stepNumber++;
        _loadDiffState(remaining.first);
        _isBusy = false;
      });
      if (scrollController != null && scrollController.hasClients) {
        scrollController.jumpTo(0);
      }
    } finally {
      if (mounted && _isBusy) {
        setState(() => _isBusy = false);
      }
    }
  }

  void _skipCurrent(
    EnrichmentDiff diff,
    ScrollController? scrollController,
  ) {
    if (_isBusy) return;
    widget.store.removePendingBatchDiff(diff.before.id);
    _skippedCount++;

    final remaining = widget.store.pendingBatchDiffs;
    if (remaining.isEmpty) {
      _closeWithSummary();
      return;
    }

    setState(() {
      _stepNumber++;
      _loadDiffState(remaining.first);
    });
    if (scrollController != null && scrollController.hasClients) {
      scrollController.jumpTo(0);
    }
  }

  Future<void> _applyAllRemaining() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final count = await widget.store.applyAllPendingBatchDiffs();
      _appliedCount += count;
      if (!mounted) return;
      _closeWithSummary();
    } finally {
      if (mounted && _isBusy) {
        setState(() => _isBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final remaining = widget.store.pendingBatchDiffs;
    if (remaining.isEmpty) {
      return const SizedBox.shrink();
    }

    final diff = remaining.first;
    if (_loadedRecordId != diff.before.id) {
      _loadDiffState(diff);
    }

    final isOverwrite = diff.mode == AiUpdateMode.overwriteAll;
    final hasNext = remaining.length > 1;
    final displayStep = _stepNumber.clamp(1, _initialTotal);

    final isWide = AppBreakpoints.isWide(context);
    return AdaptiveModalScrollContainer(
      initialChildSize: 0.88,
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
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 6),
              child: Row(
                children: [
                  if (photoExists(diff.before.photoPath))
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: buildPhotoWidget(
                        diff.before.photoPath!,
                        width: 46,
                        height: 46,
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: (isOverwrite ? Colors.deepOrange : scheme.primary)
                            .withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        isOverwrite
                            ? Icons.auto_fix_high_rounded
                            : Icons.compare_arrows_rounded,
                        color: isOverwrite ? Colors.deepOrange : scheme.primary,
                      ),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Review AI ($displayStep of $_initialTotal)',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w800,
                                  ),
                        ),
                        Text(
                          '${diff.before.displayName} • ${diff.mode.shortLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Pause & review remaining later',
                    onPressed: _isBusy ? null : _closeWithSummary,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),

            // Progress bar across the batch
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: LinearProgressIndicator(
                value: _initialTotal > 0 ? displayStep / _initialTotal : 1.0,
                borderRadius: BorderRadius.circular(99),
              ),
            ),

            // Diff stats + quick Apply All Remaining option
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _CountPill(
                          label: '+${diff.addedCount} added',
                          color: const Color(0xFF059669),
                        ),
                        _CountPill(
                          label: '~${diff.modifiedCount} modified',
                          color: const Color(0xFFD97706),
                        ),
                        if (diff.removedCount > 0)
                          _CountPill(
                            label: '-${diff.removedCount} removed',
                            color: const Color(0xFFDC2626),
                          ),
                      ],
                    ),
                  ),
                  if (hasNext)
                    TextButton.icon(
                      onPressed: _isBusy ? null : _applyAllRemaining,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.done_all_rounded, size: 16),
                      label: Text('Apply All (${remaining.length})'),
                    ),
                ],
              ),
            ),

            const Divider(height: 14),

            Expanded(
              child: !diff.hasAnyChange
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'AI confirmed your current record looks great — no changes suggested!',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      children: [
                        if (diff.summaryChanged)
                          _FieldDiffCard(
                            title: 'Summary',
                            beforeText: diff.before.summary,
                            afterText: diff.proposed.summary,
                            accepted: _acceptSummary,
                            onChanged: (v) =>
                                setState(() => _acceptSummary = v),
                          ),
                        if (diff.distanceChanged)
                          _FieldDiffCard(
                            title: 'Estimated Distance & Extrapolated GPS',
                            beforeText:
                                '${diff.before.estimatedOffsetMeters.toStringAsFixed(1)} m',
                            afterText:
                                '${diff.proposed.estimatedOffsetMeters.toStringAsFixed(1)} m'
                                '${diff.proposed.distanceReasoning.isNotEmpty ? ' — ${diff.proposed.distanceReasoning}' : ''}',
                            accepted: _acceptDistance,
                            onChanged: (v) =>
                                setState(() => _acceptDistance = v),
                          ),
                        if (diff.languageChanged || diff.osmTypeChanged)
                          _FieldDiffCard(
                            title: 'Language & OSM Type',
                            beforeText:
                                'lang=${diff.before.detectedLanguage}, type=${diff.before.osmType}',
                            afterText:
                                'lang=${diff.proposed.detectedLanguage}, type=${diff.proposed.osmType}',
                            accepted: _acceptMetadata,
                            onChanged: (v) =>
                                setState(() => _acceptMetadata = v),
                          ),
                        if (diff.changedTags.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            'OSM Tag Changes (${diff.changedTags.length})',
                            style: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 6),
                          ...diff.changedTags.map((tagDiff) {
                            final checked =
                                _acceptedTagKeys.contains(tagDiff.key);
                            final (badgeText, badgeColor) =
                                switch (tagDiff.kind) {
                              TagDiffKind.added =>
                                ('ADD', const Color(0xFF059669)),
                              TagDiffKind.modified =>
                                ('EDIT', const Color(0xFFD97706)),
                              TagDiffKind.removed =>
                                ('DEL', const Color(0xFFDC2626)),
                              TagDiffKind.unchanged => ('SAME', Colors.grey),
                            };

                            return Card(
                              elevation: 0,
                              margin: const EdgeInsets.only(bottom: 6),
                              color: badgeColor.withValues(alpha: 0.08),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: badgeColor.withValues(alpha: 0.35),
                                ),
                              ),
                              child: CheckboxListTile(
                                value: checked,
                                onChanged: (v) {
                                  setState(() {
                                    if (v == true) {
                                      _acceptedTagKeys.add(tagDiff.key);
                                    } else {
                                      _acceptedTagKeys.remove(tagDiff.key);
                                    }
                                  });
                                },
                                dense: true,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: badgeColor,
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      child: Text(
                                        badgeText,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        tagDiff.key,
                                        style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (tagDiff.beforeValue != null)
                                        Text(
                                          'Before: ${tagDiff.beforeValue}',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFFB91C1C),
                                            decoration:
                                                TextDecoration.lineThrough,
                                          ),
                                        ),
                                      if (tagDiff.afterValue != null)
                                        Text(
                                          'After:  ${tagDiff.afterValue}',
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFF047857),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                secondary: IconButton(
                                  tooltip: 'Check OSM Wiki documentation',
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    Icons.menu_book_outlined,
                                    size: 17,
                                    color: scheme.primary,
                                  ),
                                  onPressed: () => openExternalUrl(
                                    OsmTagStandards.wikiUrlForTag(
                                      tagDiff.key,
                                      tagDiff.afterValue ?? tagDiff.beforeValue,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                      ],
                    ),
            ),

            // Bottom action bar
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(
                  top: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isBusy
                          ? null
                          : () => _skipCurrent(diff, scrollController),
                      icon: const Icon(Icons.skip_next_rounded, size: 18),
                      label: Text(hasNext ? 'Skip' : 'Reject'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: _isBusy
                          ? null
                          : () => _confirmCurrent(diff, scrollController),
                      icon: _isBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              hasNext
                                  ? Icons.arrow_forward_rounded
                                  : Icons.check_rounded,
                              size: 18,
                            ),
                      label: Text(
                        hasNext
                            ? 'Confirm & Next (${remaining.length - 1} left)'
                            : 'Confirm & Finish',
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
}

class _FieldDiffCard extends StatelessWidget {
  final String title;
  final String beforeText;
  final String afterText;
  final bool accepted;
  final ValueChanged<bool> onChanged;

  const _FieldDiffCard({
    required this.title,
    required this.beforeText,
    required this.afterText,
    required this.accepted,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: CheckboxListTile(
        value: accepted,
        onChanged: (v) => onChanged(v ?? false),
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Before: $beforeText',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFB91C1C),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'After:  $afterText',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF047857),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  final String label;
  final Color color;

  const _CountPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
