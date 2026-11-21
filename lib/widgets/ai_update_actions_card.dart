import 'package:flutter/material.dart';

import '../models/enrichment_diff.dart';
import '../theme/app_theme.dart';
import 'responsive_layout.dart';

/// Clear, self-explanatory AI update controls contrasting:
/// - **Add Missing Tags** (`AiUpdateMode.enrichMerge`): keeps existing tags, only fills missing ones
/// - **Reset & Re-analyze** (`AiUpdateMode.overwriteAll`): resets all tags & rebuilds from scratch
///
/// When both on-device Gemini Nano 4 and online Cloud AI are available, provides
/// a single compact engine toggle pill instead of redundant buttons.
class AiUpdateActionsCard extends StatefulWidget {
  final bool canUseLocalNano;
  final bool canUseCloudAi;
  final bool defaultUseNano;
  final bool isRunning;
  final String progressStep;
  final VoidCallback? onCancel;
  final void Function(AiUpdateMode mode, bool forceCloud) onRun;
  final bool compact;

  const AiUpdateActionsCard({
    super.key,
    required this.canUseLocalNano,
    required this.canUseCloudAi,
    required this.defaultUseNano,
    required this.isRunning,
    this.progressStep = '',
    this.onCancel,
    required this.onRun,
    this.compact = false,
  });

  @override
  State<AiUpdateActionsCard> createState() => _AiUpdateActionsCardState();
}

class _AiUpdateActionsCardState extends State<AiUpdateActionsCard> {
  late bool _useCloud;

  @override
  void initState() {
    super.initState();
    _useCloud = !widget.defaultUseNano && widget.canUseCloudAi;
  }

  @override
  void didUpdateWidget(covariant AiUpdateActionsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_useCloud && !widget.canUseCloudAi && widget.canUseLocalNano) {
      _useCloud = false;
    } else if (!_useCloud && !widget.canUseLocalNano && widget.canUseCloudAi) {
      _useCloud = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semanticColors;
    final textTheme = Theme.of(context).textTheme;
    final showEngineToggle = widget.canUseLocalNano && widget.canUseCloudAi;
    final activeEngine = _useCloud ? 'Cloud AI' : 'Nano 4';

    return SurfacePanel(
      padding: EdgeInsets.all(widget.compact ? AppSpacing.sm : AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _useCloud ? Icons.auto_awesome_outlined : Icons.bolt_rounded,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  'AI Update · $activeEngine',
                  style: textTheme.titleSmall,
                ),
              ),
              if (showEngineToggle && !widget.isRunning)
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: WidgetStateProperty.all(
                      const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    textStyle: WidgetStateProperty.all(
                      textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  segments: const [
                    ButtonSegment<bool>(
                      value: false,
                      label: Text('Nano 4'),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      label: Text('Cloud'),
                    ),
                  ],
                  selected: {_useCloud},
                  onSelectionChanged: (s) =>
                      setState(() => _useCloud = s.first),
                ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final sideBySide = constraints.maxWidth >= 340;
              final addMissingTile = _AiModeTile(
                icon: Icons.playlist_add_rounded,
                title: 'Add Missing Tags',
                subtitle: 'Keeps existing tags, fills empty ones',
                accent: semantic.success,
                containerColor: semantic.successContainer,
                foregroundColor: semantic.onSuccessContainer,
                filled: true,
                disabled: widget.isRunning,
                onTap: () => widget.onRun(AiUpdateMode.enrichMerge, _useCloud),
              );
              final resetTile = _AiModeTile(
                icon: Icons.restart_alt_rounded,
                title: 'Reset & Re-analyze',
                subtitle: 'Clears all tags & rebuilds fresh',
                accent: semantic.warning,
                containerColor: semantic.warningContainer,
                foregroundColor: semantic.onWarningContainer,
                filled: false,
                disabled: widget.isRunning,
                onTap: () => widget.onRun(AiUpdateMode.overwriteAll, _useCloud),
              );

              if (sideBySide) {
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: addMissingTile),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(child: resetTile),
                    ],
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  addMissingTile,
                  const SizedBox(height: AppSpacing.xs),
                  resetTile,
                ],
              );
            },
          ),
          if (widget.isRunning) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    widget.progressStep.isNotEmpty
                        ? widget.progressStep
                        : 'Running $activeEngine...',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelMedium,
                  ),
                ),
                if (widget.onCancel != null)
                  TextButton(
                    onPressed: widget.onCancel,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: scheme.error,
                    ),
                    child: const Text('Cancel'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AiModeTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final Color containerColor;
  final Color foregroundColor;
  final bool filled;
  final bool disabled;
  final VoidCallback onTap;

  const _AiModeTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.containerColor,
    required this.foregroundColor,
    required this.filled,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final effectiveAccent = disabled ? accent.withValues(alpha: 0.45) : accent;
    final effectiveFg =
        disabled ? foregroundColor.withValues(alpha: 0.45) : foregroundColor;

    return Material(
      color: filled ? containerColor : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        side: BorderSide(
          color: effectiveAccent.withValues(alpha: filled ? 0.45 : 0.35),
          width: filled ? 1.2 : 1.0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: disabled ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: effectiveAccent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                ),
                child: Icon(icon, size: 17, color: effectiveAccent),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: textTheme.labelLarge?.copyWith(
                        fontSize: 13,
                        color: filled ? effectiveFg : effectiveAccent,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: textTheme.bodySmall?.copyWith(
                        fontSize: 11.5,
                        height: 1.3,
                        color: disabled
                            ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
