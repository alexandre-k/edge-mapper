import 'package:flutter/material.dart';

import '../services/gps_quality_service.dart';
import '../theme/app_theme.dart';
import 'responsive_layout.dart';

/// Restrained inline notice shown when GPS location is missing, weak, stale,
/// mocked, or suspected inaccurate.
class GpsWarningBanner extends StatelessWidget {
  final GpsQualityReport report;
  final VoidCallback onRefreshGps;

  const GpsWarningBanner({
    super.key,
    required this.report,
    required this.onRefreshGps,
  });

  @override
  Widget build(BuildContext context) {
    if (!report.level.shouldAdvertiseWarning) {
      return const SizedBox.shrink();
    }

    final semantic = context.semanticColors;
    final isCritical = report.level == GpsQualityLevel.suspect ||
        report.level == GpsQualityLevel.unavailable;

    return InlineNoticeBanner(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      tone: isCritical ? NoticeTone.danger : NoticeTone.warning,
      icon: isCritical
          ? Icons.location_off_outlined
          : Icons.gps_not_fixed_rounded,
      title: report.headline,
      detail: report.detail,
      action: TextButton(
        onPressed: onRefreshGps,
        style: TextButton.styleFrom(
          foregroundColor: isCritical ? semantic.danger : semantic.warning,
          visualDensity: VisualDensity.compact,
        ),
        child: const Text('Retry'),
      ),
    );
  }
}
