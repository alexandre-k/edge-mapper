import 'package:flutter/material.dart';

import '../services/connectivity_service.dart';
import '../services/hybrid_ai_service.dart';
import '../services/user_preferences_service.dart';
import '../theme/app_theme.dart';

/// Restrained Material 3 status pill for AppBar or Sidebar showing live network
/// and active AI engine with a semantic status dot.
class ConnectivityBanner extends StatelessWidget {
  final ConnectivityService connectivity;
  final HybridAiService ai;
  final VoidCallback onTapDetails;
  final bool compact;

  const ConnectivityBanner({
    super.key,
    required this.connectivity,
    required this.ai,
    required this.onTapDetails,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semanticColors;
    final textTheme = Theme.of(context).textTheme;

    return ListenableBuilder(
      listenable: Listenable.merge([connectivity, ai]),
      builder: (context, _) {
        final isOffline = connectivity.isOffline;
        final isLocalNano =
            ai.prefs.aiProviderMode == AiProviderMode.localFirst &&
                ai.nanoStatus.available;

        final Color dotColor;
        final String label;

        if (isOffline) {
          dotColor = semantic.warning;
          label = ai.nanoStatus.available ? 'Offline · Nano 4' : 'Offline';
        } else if (isLocalNano) {
          dotColor = scheme.primary;
          label = ai.activeEngineLabel;
        } else if (ai.canUseAnyCloudAi) {
          dotColor = semantic.success;
          label = ai.activeEngineLabel;
        } else {
          dotColor = scheme.outline;
          label = ai.activeEngineLabel;
        }

        return InkWell(
          onTap: onTapDetails,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 12,
              vertical: compact ? 5 : 7,
            ),
            decoration: BoxDecoration(
              color: isOffline
                  ? semantic.warningContainer
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(AppRadii.pill),
              border: Border.all(
                color: isOffline
                    ? semantic.warning.withValues(alpha: 0.36)
                    : scheme.outlineVariant,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelMedium?.copyWith(
                      color: isOffline
                          ? semantic.onWarningContainer
                          : scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
