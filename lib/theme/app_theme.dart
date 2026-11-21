import 'package:flutter/material.dart';

/// Consistent 4dp spacing scale aligned with Material Design 3 guidelines.
abstract final class AppSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
}

/// Consistent corner-radius tokens across cards, controls, banners, and sheets.
abstract final class AppRadii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double pill = 999;
}

/// Contrast-tuned semantic palette that adapts cleanly between Light & Dark mode.
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  final Color success;
  final Color successContainer;
  final Color onSuccessContainer;

  final Color warning;
  final Color warningContainer;
  final Color onWarningContainer;

  final Color danger;
  final Color dangerContainer;
  final Color onDangerContainer;

  final Color info;
  final Color infoContainer;
  final Color onInfoContainer;

  final Color accent;
  final Color accentContainer;
  final Color onAccentContainer;

  const AppSemanticColors({
    required this.success,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.danger,
    required this.dangerContainer,
    required this.onDangerContainer,
    required this.info,
    required this.infoContainer,
    required this.onInfoContainer,
    required this.accent,
    required this.accentContainer,
    required this.onAccentContainer,
  });

  static const light = AppSemanticColors(
    success: Color(0xFF047857),
    successContainer: Color(0xFFECFDF5),
    onSuccessContainer: Color(0xFF065F46),
    warning: Color(0xFFB45309),
    warningContainer: Color(0xFFFFFBEB),
    onWarningContainer: Color(0xFF92400E),
    danger: Color(0xFFDC2626),
    dangerContainer: Color(0xFFFEF2F2),
    onDangerContainer: Color(0xFF991B1B),
    info: Color(0xFF0369A1),
    infoContainer: Color(0xFFF0F9FF),
    onInfoContainer: Color(0xFF075985),
    accent: Color(0xFFD97706),
    accentContainer: Color(0xFFFFF7ED),
    onAccentContainer: Color(0xFF9A3412),
  );

  static const dark = AppSemanticColors(
    success: Color(0xFF34D399),
    successContainer: Color(0xFF0D2B22),
    onSuccessContainer: Color(0xFFA7F3D0),
    warning: Color(0xFFFBBF24),
    warningContainer: Color(0xFF2E220B),
    onWarningContainer: Color(0xFFFDE68A),
    danger: Color(0xFFF87171),
    dangerContainer: Color(0xFF331416),
    onDangerContainer: Color(0xFFFECACA),
    info: Color(0xFF38BDF8),
    infoContainer: Color(0xFF0C2636),
    onInfoContainer: Color(0xFFBAE6FD),
    accent: Color(0xFFF59E0B),
    accentContainer: Color(0xFF30200A),
    onAccentContainer: Color(0xFFFDE68A),
  );

  @override
  AppSemanticColors copyWith({
    Color? success,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? warningContainer,
    Color? onWarningContainer,
    Color? danger,
    Color? dangerContainer,
    Color? onDangerContainer,
    Color? info,
    Color? infoContainer,
    Color? onInfoContainer,
    Color? accent,
    Color? accentContainer,
    Color? onAccentContainer,
  }) {
    return AppSemanticColors(
      success: success ?? this.success,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
      danger: danger ?? this.danger,
      dangerContainer: dangerContainer ?? this.dangerContainer,
      onDangerContainer: onDangerContainer ?? this.onDangerContainer,
      info: info ?? this.info,
      infoContainer: infoContainer ?? this.infoContainer,
      onInfoContainer: onInfoContainer ?? this.onInfoContainer,
      accent: accent ?? this.accent,
      accentContainer: accentContainer ?? this.accentContainer,
      onAccentContainer: onAccentContainer ?? this.onAccentContainer,
    );
  }

  @override
  AppSemanticColors lerp(ThemeExtension<AppSemanticColors>? other, double t) {
    if (other is! AppSemanticColors) return this;
    return AppSemanticColors(
      success: Color.lerp(success, other.success, t)!,
      successContainer:
          Color.lerp(successContainer, other.successContainer, t)!,
      onSuccessContainer:
          Color.lerp(onSuccessContainer, other.onSuccessContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer:
          Color.lerp(warningContainer, other.warningContainer, t)!,
      onWarningContainer:
          Color.lerp(onWarningContainer, other.onWarningContainer, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerContainer: Color.lerp(dangerContainer, other.dangerContainer, t)!,
      onDangerContainer:
          Color.lerp(onDangerContainer, other.onDangerContainer, t)!,
      info: Color.lerp(info, other.info, t)!,
      infoContainer: Color.lerp(infoContainer, other.infoContainer, t)!,
      onInfoContainer: Color.lerp(onInfoContainer, other.onInfoContainer, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentContainer: Color.lerp(accentContainer, other.accentContainer, t)!,
      onAccentContainer:
          Color.lerp(onAccentContainer, other.onAccentContainer, t)!,
    );
  }
}

/// Safe accessor for [AppSemanticColors] with automatic brightness fallback.
extension AppThemeContext on BuildContext {
  AppSemanticColors get semanticColors {
    final theme = Theme.of(this);
    return theme.extension<AppSemanticColors>() ??
        (theme.brightness == Brightness.dark
            ? AppSemanticColors.dark
            : AppSemanticColors.light);
  }
}

/// Centralized Material 3 theme builder for Edge Mapper.
abstract final class AppTheme {
  static const Color brandSeed = Color(0xFF0F766E);

  static ThemeData light() => build(Brightness.light);
  static ThemeData dark() => build(Brightness.dark);

  static ThemeData build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final semantic = isDark ? AppSemanticColors.dark : AppSemanticColors.light;

    final baseScheme = ColorScheme.fromSeed(
      seedColor: brandSeed,
      brightness: brightness,
    );

    final scheme = baseScheme.copyWith(
      surface: isDark ? const Color(0xFF101413) : const Color(0xFFF5F7F7),
      surfaceContainerLowest:
          isDark ? const Color(0xFF171C1B) : const Color(0xFFFFFFFF),
      surfaceContainerLow:
          isDark ? const Color(0xFF1C2220) : const Color(0xFFF9FAFA),
      surfaceContainer:
          isDark ? const Color(0xFF202725) : const Color(0xFFF1F4F4),
      surfaceContainerHigh:
          isDark ? const Color(0xFF262E2C) : const Color(0xFFEAEFEF),
      surfaceContainerHighest:
          isDark ? const Color(0xFF2D3634) : const Color(0xFFE3E8EA),
      outlineVariant:
          isDark ? const Color(0xFF2E3835) : const Color(0xFFDEE4E6),
    );

    final baseTheme = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
    );

    final textTheme = _buildTextTheme(baseTheme.textTheme, scheme);
    final hairline = BorderSide(color: scheme.outlineVariant);

    return baseTheme.copyWith(
      textTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      extensions: [semantic],
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainerLowest,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleSpacing: AppSpacing.md,
        titleTextStyle: textTheme.titleMedium?.copyWith(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.25,
        ),
        iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 22),
        shape: Border(bottom: hairline),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          side: hairline,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.78),
        ),
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: hairline,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: hairline,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: scheme.error),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          elevation: 0,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          side: hairline,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.sm),
          ),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
          ),
          side: WidgetStateProperty.all(hairline),
          textStyle: WidgetStateProperty.all(
            textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
        side: hairline,
        selectedColor: scheme.primary.withValues(alpha: isDark ? 0.24 : 0.14),
        checkmarkColor: scheme.primary,
        backgroundColor: scheme.surfaceContainerLowest,
        labelStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onSurface,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.14),
        trackHeight: 4,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        linearMinHeight: 4,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        iconColor: scheme.onSurfaceVariant,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.xl),
          side: hairline,
        ),
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
        ),
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadii.xl),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          side: hairline,
        ),
        textStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurface),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: isDark ? 0.24 : 0.14),
        height: 70,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 23,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        indicatorColor: scheme.primary.withValues(alpha: isDark ? 0.24 : 0.14),
        selectedIconTheme: IconThemeData(color: scheme.primary, size: 22),
        unselectedIconTheme:
            IconThemeData(color: scheme.onSurfaceVariant, size: 22),
        selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  static TextTheme _buildTextTheme(TextTheme base, ColorScheme scheme) {
    return base.copyWith(
      headlineSmall: base.headlineSmall?.copyWith(
        fontSize: 22,
        height: 1.25,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: scheme.onSurface,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontSize: 19,
        height: 1.28,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        color: scheme.onSurface,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontSize: 16,
        height: 1.32,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        color: scheme.onSurface,
      ),
      titleSmall: base.titleSmall?.copyWith(
        fontSize: 14,
        height: 1.35,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        fontSize: 15,
        height: 1.45,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        fontSize: 14,
        height: 1.42,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
      bodySmall: base.bodySmall?.copyWith(
        fontSize: 12.5,
        height: 1.4,
        fontWeight: FontWeight.w400,
        color: scheme.onSurfaceVariant,
      ),
      labelLarge: base.labelLarge?.copyWith(
        fontSize: 13.5,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.05,
      ),
      labelMedium: base.labelMedium?.copyWith(
        fontSize: 12,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
      labelSmall: base.labelSmall?.copyWith(
        fontSize: 11.5,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
