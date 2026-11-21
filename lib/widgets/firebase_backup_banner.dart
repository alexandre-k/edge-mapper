import 'package:flutter/material.dart';

import '../services/mapper_store.dart';
import '../theme/app_theme.dart';
import 'firebase_auth_sheet.dart';
import 'responsive_layout.dart';

/// Restrained inline sync notice bar shown when unsynced local changes exist online.
class FirebaseBackupBanner extends StatelessWidget {
  final MapperStore store;

  const FirebaseBackupBanner({super.key, required this.store});

  Future<void> _syncNow(BuildContext context) async {
    if (!store.firebaseSync.canSyncNow) {
      await showFirebaseAuthSheet(
        context,
        firebaseSync: store.firebaseSync,
        store: store,
      );
      return;
    }
    final result = await store.syncAllUnsyncedToFirebase();
    if (!context.mounted) return;
    final photoNote = result.photosSynced > 0
        ? ' (${result.photosSynced} photo${result.photosSynced == 1 ? '' : 's'})'
        : '';
    final msg = result.hasErrors && result.totalSynced == 0
        ? result.errors.first
        : result.hasErrors
            ? 'Synced ↓${result.totalPulled} ↑${result.totalPushed}$photoNote (${result.errors.length} failed)'
            : 'Synced ↓${result.totalPulled} ↑${result.totalPushed}$photoNote';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    if (!store.shouldSuggestFirebaseBackup) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final total = store.totalUnsyncedCount;
    final isSignedIn = store.firebaseSync.canSyncNow;
    final hasLockedVault =
        store.firebaseSync.isSignedIn && !store.firebaseSync.isVaultUnlocked;

    return SurfacePanel(
      margin: const EdgeInsets.fromLTRB(AppSpacing.md, 10, AppSpacing.md, 0),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 8),
      radius: AppRadii.md,
      child: store.isSyncingFirebase
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: LinearProgressIndicator(),
            )
          : Row(
              children: [
                Icon(
                  isSignedIn
                      ? Icons.cloud_upload_outlined
                      : hasLockedVault
                          ? Icons.fingerprint_rounded
                          : Icons.vpn_key_outlined,
                  color: scheme.primary,
                  size: 18,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    isSignedIn
                        ? '$total unsynced change${total == 1 ? '' : 's'}'
                        : hasLockedVault
                            ? '$total unsynced · unlock E2EE vault'
                            : '$total local change${total == 1 ? '' : 's'} · enable E2EE sync',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelLarge?.copyWith(fontSize: 13),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: () => _syncNow(context),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: Text(
                    isSignedIn
                        ? 'Sync'
                        : hasLockedVault
                            ? 'Unlock'
                            : 'E2EE Sync',
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  onPressed: store.dismissFirebasePromptForSession,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                IconButton(
                  tooltip: 'Mute sync reminders',
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    await store.disableFirebaseBackupSuggestionsForever();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Sync reminders muted')),
                    );
                  },
                  icon: Icon(
                    Icons.notifications_off_outlined,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
    );
  }
}
