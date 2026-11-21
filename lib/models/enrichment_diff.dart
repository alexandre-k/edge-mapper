import 'osm_record.dart';

enum AiUpdateMode {
  enrichMerge,
  overwriteAll;

  String get label => switch (this) {
        AiUpdateMode.enrichMerge => 'Add Missing Tags (Keep Existing)',
        AiUpdateMode.overwriteAll => 'Reset & Re-analyze (Replace All)',
      };

  String get shortLabel => switch (this) {
        AiUpdateMode.enrichMerge => 'Add Missing Tags',
        AiUpdateMode.overwriteAll => 'Reset & Re-analyze',
      };

  String get description => switch (this) {
        AiUpdateMode.enrichMerge =>
          'Keeps all your existing tags and only fills in missing/empty ones.',
        AiUpdateMode.overwriteAll =>
          'Clears all current tags & summary and rebuilds everything freshly from the photo.',
      };
}

enum TagDiffKind { added, modified, removed, unchanged }

class TagDiffItem {
  final String key;
  final String? beforeValue;
  final String? afterValue;
  final TagDiffKind kind;

  const TagDiffItem({
    required this.key,
    this.beforeValue,
    this.afterValue,
    required this.kind,
  });

  bool get isChange => kind != TagDiffKind.unchanged;
}

/// Structured before/after comparison of an AI enrichment or full overwrite
/// proposal so the user can review and confirm every change before saving.
class EnrichmentDiff {
  final OsmRecord before;
  final OsmRecord proposed;
  final AiUpdateMode mode;
  final List<TagDiffItem> tagDiffs;

  const EnrichmentDiff({
    required this.before,
    required this.proposed,
    required this.mode,
    required this.tagDiffs,
  });

  factory EnrichmentDiff.compute({
    required OsmRecord before,
    required OsmRecord proposed,
    required AiUpdateMode mode,
  }) {
    final allKeys = <String>{
      ...before.tags.keys,
      ...proposed.tags.keys,
    }.toList()
      ..sort();

    final diffs = <TagDiffItem>[];
    for (final key in allKeys) {
      final oldVal = before.tags[key];
      final newVal = proposed.tags[key];
      if (oldVal == null && newVal != null) {
        diffs.add(TagDiffItem(
          key: key,
          afterValue: newVal,
          kind: TagDiffKind.added,
        ));
      } else if (oldVal != null && newVal == null) {
        diffs.add(TagDiffItem(
          key: key,
          beforeValue: oldVal,
          kind: TagDiffKind.removed,
        ));
      } else if (oldVal != newVal) {
        diffs.add(TagDiffItem(
          key: key,
          beforeValue: oldVal,
          afterValue: newVal,
          kind: TagDiffKind.modified,
        ));
      } else {
        diffs.add(TagDiffItem(
          key: key,
          beforeValue: oldVal,
          afterValue: newVal,
          kind: TagDiffKind.unchanged,
        ));
      }
    }

    // Order: added -> modified -> removed -> unchanged
    diffs.sort((a, b) => a.kind.index.compareTo(b.kind.index));

    return EnrichmentDiff(
      before: before,
      proposed: proposed,
      mode: mode,
      tagDiffs: diffs,
    );
  }

  bool get summaryChanged => before.summary.trim() != proposed.summary.trim();
  bool get notesChanged => before.notes.trim() != proposed.notes.trim();
  bool get osmTypeChanged => before.osmType != proposed.osmType;
  bool get languageChanged =>
      before.detectedLanguage != proposed.detectedLanguage;
  bool get distanceChanged =>
      (before.estimatedOffsetMeters - proposed.estimatedOffsetMeters).abs() >=
      0.5;

  List<TagDiffItem> get changedTags =>
      tagDiffs.where((t) => t.isChange).toList();
  int get addedCount =>
      tagDiffs.where((t) => t.kind == TagDiffKind.added).length;
  int get modifiedCount =>
      tagDiffs.where((t) => t.kind == TagDiffKind.modified).length;
  int get removedCount =>
      tagDiffs.where((t) => t.kind == TagDiffKind.removed).length;

  bool get hasAnyChange =>
      summaryChanged ||
      notesChanged ||
      osmTypeChanged ||
      languageChanged ||
      distanceChanged ||
      changedTags.isNotEmpty;

  /// Builds the final [OsmRecord] applying only the fields/tag keys approved by the user.
  OsmRecord buildApprovedRecord({
    required bool acceptSummary,
    required bool acceptNotes,
    required bool acceptDistance,
    required bool acceptMetadata,
    required Set<String> acceptedTagKeys,
  }) {
    final finalTags = Map<String, String>.from(before.tags);
    for (final diff in changedTags) {
      if (!acceptedTagKeys.contains(diff.key)) continue;
      switch (diff.kind) {
        case TagDiffKind.added:
        case TagDiffKind.modified:
          if (diff.afterValue != null) {
            finalTags[diff.key] = diff.afterValue!;
          }
          break;
        case TagDiffKind.removed:
          finalTags.remove(diff.key);
          break;
        case TagDiffKind.unchanged:
          break;
      }
    }

    return before.copyWith(
      summary: acceptSummary ? proposed.summary : before.summary,
      notes: acceptNotes ? proposed.notes : before.notes,
      osmType: acceptMetadata ? proposed.osmType : before.osmType,
      detectedLanguage:
          acceptMetadata ? proposed.detectedLanguage : before.detectedLanguage,
      estimatedOffsetMeters: acceptDistance
          ? proposed.estimatedOffsetMeters
          : before.estimatedOffsetMeters,
      distanceReasoning: acceptDistance
          ? proposed.distanceReasoning
          : before.distanceReasoning,
      extrapolatedLatitude: acceptDistance
          ? proposed.extrapolatedLatitude
          : before.extrapolatedLatitude,
      extrapolatedLongitude: acceptDistance
          ? proposed.extrapolatedLongitude
          : before.extrapolatedLongitude,
      tags: finalTags,
      detectedLabels: proposed.detectedLabels.isNotEmpty
          ? proposed.detectedLabels
          : before.detectedLabels,
      tagCandidates: proposed.tagCandidates.isNotEmpty
          ? proposed.tagCandidates
          : before.tagCandidates,
      aiSource: proposed.aiSource,
      status: RecordStatus.aiEnriched,
      clearFirebaseSyncedAt: true,
    );
  }
}
