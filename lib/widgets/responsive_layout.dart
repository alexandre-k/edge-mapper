import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

enum ScreenSizeClass { compact, medium, expanded }

/// Responsive layout breakpoints following Material Design 3 Window Size Classes:
/// - compact (< 600): Smartphone portrait (bottom NavigationBar, single column, bottom sheets)
/// - medium (600..839): Large phone landscape / foldable / portrait tablet (labeled NavigationRail, 2-col grids, centered dialogs)
/// - expanded (>= 840): Landscape tablet / desktop (split workspaces; >= 1080 uses extended sidebar)
class AppBreakpoints {
  static const double medium = 600;
  static const double expanded = 840;
  static const double desktopSidebar = 1080;

  static ScreenSizeClass of(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w >= expanded) return ScreenSizeClass.expanded;
    if (w >= medium) return ScreenSizeClass.medium;
    return ScreenSizeClass.compact;
  }

  static bool isCompact(BuildContext context) =>
      of(context) == ScreenSizeClass.compact;

  static bool isWide(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= medium;

  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= desktopSidebar;

  static double horizontalPadding(BuildContext context) =>
      switch (of(context)) {
        ScreenSizeClass.compact => AppSpacing.md,
        ScreenSizeClass.medium => 20,
        ScreenSizeClass.expanded => AppSpacing.lg,
      };

  /// Clamped text scale factor for sizing grid tiles safely under accessibility font scaling.
  static double textScale(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.6);
}

/// Presents a modal bottom sheet on compact phones and a centered rounded dialog
/// on tablets and desktops so modals never stretch awkwardly across wide screens.
Future<T?> showAdaptiveSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double desktopMaxWidth = 560,
}) {
  if (AppBreakpoints.isWide(context)) {
    return showDialog<T>(
      context: context,
      builder: (ctx) {
        final mq = MediaQuery.of(ctx);
        final availableHeight =
            (mq.size.height - mq.viewInsets.vertical).clamp(240.0, mq.size.height);
        return Dialog(
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.xl),
            side: BorderSide(
              color:
                  Theme.of(ctx).colorScheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: desktopMaxWidth,
              maxHeight: availableHeight * 0.9,
            ),
            child: builder(ctx),
          ),
        );
      },
    );
  }

  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.xl)),
    ),
    builder: (ctx) {
      final bottomInset = MediaQuery.viewInsetsOf(ctx).bottom;
      return AnimatedPadding(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: bottomInset),
        child: MediaQuery.removeViewInsets(
          context: ctx,
          removeBottom: true,
          child: MediaQuery.removePadding(
            context: ctx,
            removeBottom: bottomInset > 0,
            child: builder(ctx),
          ),
        ),
      );
    },
  );
}

/// Wraps scrollable modal content so it uses [DraggableScrollableSheet] on
/// phones and fills the centered [Dialog] cleanly on tablets & desktops.
class AdaptiveModalScrollContainer extends StatelessWidget {
  final Widget Function(BuildContext context, ScrollController? scrollController)
      builder;
  final double initialChildSize;
  final double minChildSize;
  final double maxChildSize;

  const AdaptiveModalScrollContainer({
    super.key,
    required this.builder,
    this.initialChildSize = 0.88,
    this.minChildSize = 0.5,
    this.maxChildSize = 0.96,
  });

  @override
  Widget build(BuildContext context) {
    if (AppBreakpoints.isWide(context)) {
      return builder(context, null);
    }
    return SafeArea(
      top: false,
      child: DraggableScrollableSheet(
        initialChildSize: initialChildSize,
        minChildSize: minChildSize,
        maxChildSize: maxChildSize,
        expand: false,
        builder: (ctx, ctrl) => builder(ctx, ctrl),
      ),
    );
  }
}

/// Clean, restrained Material 3 surface card with subtle hairline border
/// for a calm, uncluttered layout hierarchy.
class SurfacePanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final Color? borderColor;
  final double radius;

  const SurfacePanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.margin,
    this.color,
    this.borderColor,
    this.radius = AppRadii.lg,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final panel = Material(
      color: color ?? scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(
          color: borderColor ?? scheme.outlineVariant.withValues(alpha: 0.75),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
    if (margin != null) {
      return Padding(padding: margin!, child: panel);
    }
    return panel;
  }
}

/// Consistent Material 3 page header with title, optional subtitle, and trailing widget.
class ScreenHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const ScreenHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.headlineSmall),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: AppSpacing.sm),
          trailing!,
        ],
      ],
    );
  }
}

/// Consistent modal header with drag handle on phones, optional leading icon,
/// title, optional subtitle, and accessible close button.
class ModalSheetHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;
  final VoidCallback? onClose;

  const ModalSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isWide = AppBreakpoints.isWide(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isWide)
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: AppSpacing.sm),
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(AppRadii.pill),
              ),
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: (iconColor ?? scheme.primary).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                ),
                child: Icon(
                  icon,
                  color: iconColor ?? scheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: textTheme.titleLarge),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: textTheme.bodySmall),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close_rounded, size: 21),
              onPressed: onClose ?? () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
      ],
    );
  }
}

/// Subtle muted uppercase section label for clean visual hierarchy.
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.75,
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: AppSpacing.xs),
          trailing!,
        ],
      ],
    );
  }
}

/// Semantic tone for [InlineNoticeBanner].
enum NoticeTone { neutral, info, success, warning, danger }

/// Unified Material 3 tonal inline banner for alerts, status messages, and tips.
class InlineNoticeBanner extends StatelessWidget {
  final NoticeTone tone;
  final IconData icon;
  final String title;
  final String? detail;
  final Widget? action;
  final VoidCallback? onDismiss;
  final EdgeInsetsGeometry? margin;

  const InlineNoticeBanner({
    super.key,
    required this.tone,
    required this.icon,
    required this.title,
    this.detail,
    this.action,
    this.onDismiss,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semanticColors;
    final textTheme = Theme.of(context).textTheme;

    final (Color bg, Color fg, Color border) = switch (tone) {
      NoticeTone.neutral => (
          scheme.surfaceContainerLow,
          scheme.onSurface,
          scheme.outlineVariant,
        ),
      NoticeTone.info => (
          semantic.infoContainer,
          semantic.onInfoContainer,
          semantic.info.withValues(alpha: 0.32),
        ),
      NoticeTone.success => (
          semantic.successContainer,
          semantic.onSuccessContainer,
          semantic.success.withValues(alpha: 0.34),
        ),
      NoticeTone.warning => (
          semantic.warningContainer,
          semantic.onWarningContainer,
          semantic.warning.withValues(alpha: 0.36),
        ),
      NoticeTone.danger => (
          semantic.dangerContainer,
          semantic.onDangerContainer,
          semantic.danger.withValues(alpha: 0.36),
        ),
    };

    final iconTint = switch (tone) {
      NoticeTone.neutral => scheme.onSurfaceVariant,
      NoticeTone.info => semantic.info,
      NoticeTone.success => semantic.success,
      NoticeTone.warning => semantic.warning,
      NoticeTone.danger => semantic.danger,
    };

    return Container(
      margin: margin,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 10,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment:
            detail != null ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          Padding(
            padding: EdgeInsets.only(top: detail != null ? 2 : 0),
            child: Icon(icon, size: 18, color: iconTint),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: textTheme.labelLarge?.copyWith(
                    fontSize: 13,
                    color: fg,
                  ),
                ),
                if (detail != null && detail!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail!,
                    style: textTheme.bodySmall?.copyWith(
                      color: fg.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: AppSpacing.xs),
            action!,
          ],
          if (onDismiss != null)
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
              icon: Icon(
                Icons.close_rounded,
                size: 18,
                color: fg.withValues(alpha: 0.75),
              ),
            ),
        ],
      ),
    );
  }
}

/// Minimalistic empty state card with calm whitespace, icon badge, and optional CTA.
class EmptyStateCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Widget? action;

  const EmptyStateCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 26, color: scheme.primary),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            title,
            textAlign: TextAlign.center,
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.xxs),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              description,
              textAlign: TextAlign.center,
              style: textTheme.bodySmall,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: AppSpacing.md),
            action!,
          ],
        ],
      ),
    );
  }
}

/// Tabular-figure stat metric tile for routes, telemetry, and profiles.
class MetricStatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const MetricStatTile({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: valueColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.labelSmall,
        ),
      ],
    );
  }
}

/// Restrained neutral or semantic pill tag with clear legibility in light & dark mode.
class SubtleTag extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color? tint;

  const SubtleTag({
    super.key,
    required this.label,
    this.icon,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = tint ?? scheme.onSurfaceVariant;
    final bg = tint != null
        ? tint!.withValues(alpha: 0.12)
        : scheme.surfaceContainerHigh;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Thumb-friendly sticky bottom action bar anchored at the lower edge of phones
/// and detail screens so primary one-handed actions never require reaching up.
class BottomActionDock extends StatelessWidget {
  final Widget child;
  final bool safeAreaBottom;

  const BottomActionDock({
    super.key,
    required this.child,
    this.safeAreaBottom = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: SafeArea(
          top: false,
          bottom: safeAreaBottom,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              10,
              AppSpacing.md,
              10,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Compact 3-step workflow indicator so users always see where a record is
/// and what the next step is (e.g. Captured -> Enriched -> Published).
class WorkflowStepStrip extends StatelessWidget {
  final List<String> steps;
  final int activeIndex;

  const WorkflowStepStrip({
    super.key,
    required this.steps,
    required this.activeIndex,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semanticColors;
    final textTheme = Theme.of(context).textTheme;

    return Row(
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0)
            Container(
              width: 16,
              height: 2,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              color: i <= activeIndex
                  ? semantic.success.withValues(alpha: 0.6)
                  : scheme.outlineVariant,
            ),
          Expanded(
            child: Row(
              mainAxisAlignment: i == 0
                  ? MainAxisAlignment.start
                  : (i == steps.length - 1
                      ? MainAxisAlignment.end
                      : MainAxisAlignment.center),
              children: [
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < activeIndex
                        ? semantic.success
                        : (i == activeIndex
                            ? scheme.primary
                            : scheme.surfaceContainerHighest),
                  ),
                  child: Icon(
                    i < activeIndex
                        ? Icons.check_rounded
                        : (i == activeIndex
                            ? Icons.radio_button_checked_rounded
                            : Icons.circle_outlined),
                    size: 11,
                    color: i <= activeIndex
                        ? scheme.onPrimary
                        : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    steps[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall?.copyWith(
                      color: i <= activeIndex
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                      fontWeight:
                          i == activeIndex ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
