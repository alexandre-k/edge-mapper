import 'package:flutter/material.dart';

import '../services/explorer_avatar_service.dart';
import '../services/gamification_service.dart';
import '../theme/app_theme.dart';
import 'bitcoin_donate_sheet.dart';
import 'explorer_avatar_widget.dart';
import 'responsive_layout.dart';

/// Opens the RPG Explorer Avatar, Nicknames, Stats, Characteristics & Badges sheet.
void showExplorerBadgesSheet(
  BuildContext context,
  ExplorerProfile profile, {
  VoidCallback? onRerollAvatar,
  String? standingLabel,
}) {
  showAdaptiveSheet<void>(
    context: context,
    desktopMaxWidth: 560,
    builder: (_) => _ExplorerRpgSheet(
      profile: profile,
      onRerollAvatar: onRerollAvatar,
      standingLabel: standingLabel,
    ),
  );
}

/// Compact explorer RPG strip showing the generated procedural Avatar,
/// funny XP nickname (e.g. "Vasco da Gama"), Level, XP progress, and badges.
class MapperQuestBar extends StatelessWidget {
  final ExplorerProfile profile;
  final VoidCallback? onRerollAvatar;
  final String? standingLabel;

  const MapperQuestBar({
    super.key,
    required this.profile,
    this.onRerollAvatar,
    this.standingLabel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final avatar = profile.avatar;

    return Material(
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showExplorerBadgesSheet(
          context,
          profile,
          onRerollAvatar: onRerollAvatar,
          standingLabel: standingLabel,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              ExplorerAvatarWidget(
                avatar: avatar,
                size: 46,
                showLevelBadge: true,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '"${avatar.funnyNickname}"',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleSmall,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        Text(
                          '${profile.xp} XP',
                          style: textTheme.labelMedium?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Lv.${profile.level} ${avatar.explorerClass} · ${avatar.characteristics.length} traits${standingLabel != null ? ' · $standingLabel' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadii.pill),
                      child: LinearProgressIndicator(
                        value: profile.levelProgress,
                        minHeight: 5,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExplorerRpgSheet extends StatelessWidget {
  final ExplorerProfile profile;
  final VoidCallback? onRerollAvatar;
  final String? standingLabel;

  const _ExplorerRpgSheet({
    required this.profile,
    this.onRerollAvatar,
    this.standingLabel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semanticColors;
    final textTheme = Theme.of(context).textTheme;
    final avatar = profile.avatar;
    final textScale = AppBreakpoints.textScale(context);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ModalSheetHeader(
              title: '"${avatar.funnyNickname}"',
              subtitle:
                  'Lv.${profile.level} ${profile.rankTitle} · ${avatar.explorerClass}',
            ),
            const SizedBox(height: AppSpacing.sm),

            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ExplorerAvatarWidget(
                  avatar: avatar,
                  size: 72,
                  showLevelBadge: true,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Gear: ${avatar.gearName}',
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (standingLabel != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          standingLabel!,
                          style: textTheme.labelLarge?.copyWith(
                            color: scheme.primary,
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        '${profile.xp} XP · ${profile.xpForNextLevel - profile.xpIntoLevel} XP to Lv.${profile.level + 1}',
                        style: textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (onRerollAvatar != null)
                  OutlinedButton.icon(
                    onPressed: () {
                      onRerollAvatar!();
                      Navigator.pop(context);
                    },
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    icon: const Icon(Icons.casino_outlined, size: 16),
                    label: const Text('New Look'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.pill),
              child: LinearProgressIndicator(
                value: profile.levelProgress,
                minHeight: 6,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),

            // RPG Stats Grid
            const SizedBox(height: AppSpacing.md),
            SectionLabel('RPG Attributes (Power ${avatar.stats.totalPower})'),
            const SizedBox(height: AppSpacing.xs),
            _buildStatBar(
              context,
              'PER · Perception',
              avatar.stats.perception,
              semantic.info,
            ),
            _buildStatBar(
              context,
              'STA · Stamina',
              avatar.stats.stamina,
              semantic.accent,
            ),
            _buildStatBar(
              context,
              'LNG · Linguistics',
              avatar.stats.linguistics,
              scheme.tertiary,
            ),
            _buildStatBar(
              context,
              'OFG · Off-Grid',
              avatar.stats.stealth,
              semantic.warning,
            ),
            _buildStatBar(
              context,
              'TRU · Integrity',
              avatar.stats.integrity,
              semantic.success,
            ),

            // Unlocked RPG Characteristics
            const SizedBox(height: AppSpacing.md),
            SectionLabel(
              'RPG Characteristics (${avatar.characteristics.length})',
            ),
            const SizedBox(height: AppSpacing.xs),
            ...avatar.characteristics.map(
              (c) => _CharacteristicTile(trait: c),
            ),

            // Funny Nickname Progression
            if (avatar.unlockedNicknameHistory.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              const SectionLabel('Unlocked Explorer Titles'),
              const SizedBox(height: AppSpacing.xs),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < avatar.unlockedNicknameHistory.length; i++)
                    SubtleTag(
                      label: 'Lv.${i + 1}: ${avatar.unlockedNicknameHistory[i]}',
                    ),
                ],
              ),
            ],

            const SizedBox(height: AppSpacing.md),
            SectionLabel(
              'Badges (${profile.unlockedBadgeCount}/${profile.badges.length})',
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                final cols = constraints.maxWidth >= 460 ? 3 : 2;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: AppSpacing.xs,
                    crossAxisSpacing: AppSpacing.xs,
                    mainAxisExtent: 104 * textScale,
                  ),
                  itemCount: profile.badges.length,
                  itemBuilder: (context, idx) {
                    final b = profile.badges[idx];
                    return Container(
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: b.unlocked
                            ? scheme.primary.withValues(alpha: 0.06)
                            : scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        border: Border.all(
                          color: b.unlocked
                              ? scheme.primary.withValues(alpha: 0.3)
                              : scheme.outlineVariant,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                b.icon,
                                size: 18,
                                color: b.unlocked
                                    ? b.color
                                    : scheme.onSurfaceVariant
                                        .withValues(alpha: 0.45),
                              ),
                              const Spacer(),
                              Icon(
                                b.unlocked
                                    ? Icons.check_circle_rounded
                                    : Icons.lock_outline_rounded,
                                size: 15,
                                color: b.unlocked
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant
                                        .withValues(alpha: 0.4),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            b.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.labelLarge?.copyWith(
                              fontSize: 12.5,
                              color: b.unlocked ? null : scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Expanded(
                            child: Text(
                              b.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),

            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  showBitcoinPaymentSheet(context);
                },
                icon: Icon(
                  Icons.favorite_rounded,
                  color: semantic.accent,
                ),
                label: const Text('Support Edge Mapper'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatBar(
    BuildContext context,
    String label,
    int value,
    Color color,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.labelMedium,
            ),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.pill),
              child: LinearProgressIndicator(
                value: (value / 99.0).clamp(0.05, 1.0),
                minHeight: 7,
                color: color,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          SizedBox(
            width: 28,
            child: Text(
              '$value',
              textAlign: TextAlign.right,
              style: textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CharacteristicTile extends StatelessWidget {
  final RpgCharacteristic trait;

  const _CharacteristicTile({required this.trait});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: trait.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: trait.color.withValues(alpha: 0.24)),
      ),
      child: Row(
        children: [
          Icon(trait.icon, size: 18, color: trait.color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        trait.name,
                        style: textTheme.labelLarge?.copyWith(fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      trait.bonusText,
                      style: textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: trait.color,
                      ),
                    ),
                  ],
                ),
                Text(
                  trait.description,
                  style: textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
