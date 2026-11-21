import 'package:flutter/material.dart';

import '../services/bounty_service.dart';
import '../services/connectivity_service.dart';
import '../services/firebase_sync_service.dart';
import '../services/hybrid_ai_service.dart';
import '../services/leaderboard_service.dart';
import '../services/mapper_store.dart';
import '../services/offline_tile_service.dart';
import '../services/osm_publish_service.dart';
import '../services/sensor_service.dart';
import '../services/user_preferences_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ai_status_sheet.dart';
import '../widgets/connectivity_banner.dart';
import '../widgets/explorer_avatar_widget.dart';
import '../widgets/firebase_auth_sheet.dart';
import '../widgets/mapper_quest_bar.dart';
import '../widgets/responsive_layout.dart';
import 'capture_screen.dart';
import 'community_screen.dart';
import 'records_screen.dart';
import 'trail_screen.dart';

class HomeShell extends StatefulWidget {
  final ConnectivityService connectivity;
  final SensorService sensors;
  final HybridAiService ai;
  final MapperStore store;
  final UserPreferencesService prefs;
  final FirebaseSyncService firebaseSync;
  final OfflineTileService tiles;
  final OsmPublishService osmPublish;
  final LeaderboardService leaderboard;
  final BountyService bounties;

  const HomeShell({
    super.key,
    required this.connectivity,
    required this.sensors,
    required this.ai,
    required this.store,
    required this.prefs,
    required this.firebaseSync,
    required this.tiles,
    required this.osmPublish,
    required this.leaderboard,
    required this.bounties,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selectedIndex = 0;

  String _formatSyncSummary(FirebaseSyncResult result) {
    final photoNote = result.photosSynced > 0
        ? ' (${result.photosSynced} photo${result.photosSynced == 1 ? '' : 's'})'
        : '';
    if (result.hasErrors && result.totalSynced == 0) {
      return result.errors.first;
    }
    if (result.totalSynced == 0) {
      return 'Everything is up to date';
    }
    final parts = <String>[
      if (result.totalPulled > 0) '↓${result.totalPulled} pulled',
      if (result.totalPushed > 0) '↑${result.totalPushed} uploaded$photoNote',
      if (result.totalDeleted > 0)
        '${result.totalDeleted} removed from Firestore',
    ];
    return 'Synced · ${parts.join(' · ')}';
  }

  String _syncTooltip() {
    final total = widget.store.totalUnsyncedCount;
    final deletes = widget.store.pendingRemoteDeleteCount;
    if (deletes > 0 && deletes == total) {
      return 'Sync to remove $deletes deleted item${deletes == 1 ? '' : 's'} from Firestore';
    }
    if (total > 0) {
      return 'Sync $total pending change${total == 1 ? '' : 's'} with Firestore';
    }
    return 'Sync to cloud';
  }

  Future<void> _syncNow() async {
    if (!widget.firebaseSync.canSyncNow) {
      await showFirebaseAuthSheet(
        context,
        firebaseSync: widget.firebaseSync,
        store: widget.store,
      );
      return;
    }
    final result = await widget.store.syncAllUnsyncedToFirebase();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_formatSyncSummary(result))),
    );
  }

  void _openSettingsHub() {
    showAdaptiveSheet<void>(
      context: context,
      desktopMaxWidth: 600,
      builder: (_) => AiStatusSheet(
        connectivity: widget.connectivity,
        ai: widget.ai,
        prefs: widget.prefs,
        firebaseSync: widget.firebaseSync,
        tiles: widget.tiles,
        osmPublish: widget.osmPublish,
        store: widget.store,
      ),
    );
  }

  Widget _buildContentStack() {
    return IndexedStack(
      index: _selectedIndex,
      children: [
        CaptureScreen(
          store: widget.store,
          sensors: widget.sensors,
          ai: widget.ai,
          connectivity: widget.connectivity,
          onRecordSaved: () => setState(() => _selectedIndex = 2),
        ),
        TrailScreen(
          store: widget.store,
          sensors: widget.sensors,
          tiles: widget.tiles,
          connectivity: widget.connectivity,
          prefs: widget.prefs,
          ai: widget.ai,
          osmPublish: widget.osmPublish,
          onSnapAlongTrail: () => setState(() => _selectedIndex = 0),
        ),
        RecordsScreen(
          store: widget.store,
          ai: widget.ai,
          tiles: widget.tiles,
          connectivity: widget.connectivity,
          prefs: widget.prefs,
          osmPublish: widget.osmPublish,
          onCaptureFirstPlace: () => setState(() => _selectedIndex = 0),
        ),
        CommunityScreen(
          store: widget.store,
          sensors: widget.sensors,
          prefs: widget.prefs,
          connectivity: widget.connectivity,
          leaderboard: widget.leaderboard,
          bounties: widget.bounties,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sizeClass = AppBreakpoints.of(context);
    final isDesktopSidebar = AppBreakpoints.isDesktop(context);
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semanticColors;
    final textTheme = Theme.of(context).textTheme;

    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.connectivity,
        widget.store,
        widget.prefs,
        widget.ai,
        widget.firebaseSync,
        widget.leaderboard,
        widget.bounties,
      ]),
      builder: (context, _) {
        final recordCount = widget.store.records.length;
        final isRecording = widget.store.isRecordingTrail;
        final isForcedOffline = widget.connectivity.forceOffline;
        final profile = widget.store.explorerProfile;
        final snap = widget.leaderboard.buildSnapshot(
          currentProfile: profile,
          recordsCount: recordCount,
          totalTrailKm: widget.store.totalTrailKm,
        );
        final canSync =
            widget.firebaseSync.isConfigured && widget.connectivity.isOnline;

        // Compact (Smartphone < 600dp): context-aware AppBar + Material 3 NavigationBar
        if (sizeClass == ScreenSizeClass.compact) {
          final currentSectionTitle = switch (_selectedIndex) {
            0 => 'Capture',
            1 => 'Routes',
            2 => 'Records',
            _ => 'Explorer Guild',
          };
          return Scaffold(
            appBar: AppBar(
              titleSpacing: AppSpacing.md,
              title: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                    ),
                    child: Icon(
                      Icons.explore_rounded,
                      color: scheme.onPrimary,
                      size: 17,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      currentSectionTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 142),
                    child: ConnectivityBanner(
                      connectivity: widget.connectivity,
                      ai: widget.ai,
                      onTapDetails: _openSettingsHub,
                      compact: true,
                    ),
                  ),
                ),
                if (canSync)
                  IconButton(
                    tooltip: _syncTooltip(),
                    onPressed: widget.store.isSyncingFirebase ? null : _syncNow,
                    icon: widget.store.isSyncingFirebase
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Badge(
                            isLabelVisible: widget.store.totalUnsyncedCount > 0,
                            backgroundColor:
                                widget.store.hasPendingRemoteDeletes
                                    ? semantic.danger
                                    : semantic.success,
                            textColor: Colors.white,
                            label: Text('${widget.store.totalUnsyncedCount}'),
                            child: Icon(
                              Icons.sync_rounded,
                              size: 22,
                              color: widget.store.totalUnsyncedCount > 0
                                  ? (widget.store.hasPendingRemoteDeletes
                                      ? semantic.danger
                                      : semantic.success)
                                  : null,
                            ),
                          ),
                  ),
                IconButton(
                  tooltip: 'Settings',
                  onPressed: _openSettingsHub,
                  icon: const Icon(Icons.tune_rounded, size: 22),
                ),
              ],
            ),
            body: _buildContentStack(),
            bottomNavigationBar: Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: scheme.outlineVariant)),
              ),
              child: NavigationBar(
                selectedIndex: _selectedIndex,
                onDestinationSelected: (idx) =>
                    setState(() => _selectedIndex = idx),
                destinations: [
                  const NavigationDestination(
                    icon: Icon(Icons.add_a_photo_outlined),
                    selectedIcon: Icon(Icons.add_a_photo_rounded),
                    label: 'Capture',
                  ),
                  NavigationDestination(
                    icon: Badge(
                      isLabelVisible: isRecording,
                      backgroundColor: semantic.danger,
                      label: const Text('REC'),
                      child: const Icon(Icons.route_outlined),
                    ),
                    selectedIcon: Badge(
                      isLabelVisible: isRecording,
                      backgroundColor: semantic.danger,
                      label: const Text('REC'),
                      child: const Icon(Icons.route_rounded),
                    ),
                    label: 'Routes',
                  ),
                  NavigationDestination(
                    icon: Badge(
                      isLabelVisible: recordCount > 0,
                      label: Text('$recordCount'),
                      child: const Icon(Icons.layers_outlined),
                    ),
                    selectedIcon: Badge(
                      isLabelVisible: recordCount > 0,
                      label: Text('$recordCount'),
                      child: const Icon(Icons.layers_rounded),
                    ),
                    label: 'Records',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.emoji_events_outlined),
                    selectedIcon: Icon(Icons.emoji_events_rounded),
                    label: 'Guild',
                  ),
                ],
              ),
            ),
          );
        }

        // Tablet (600..1079dp) labeled NavigationRail & Desktop (>= 1080dp) extended Sidebar
        return Scaffold(
          body: Row(
            children: [
              Container(
                width: isDesktopSidebar ? 248 : 88,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLowest,
                  border: Border(
                    right: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                child: SafeArea(
                  child: Column(
                    crossAxisAlignment: isDesktopSidebar
                        ? CrossAxisAlignment.stretch
                        : CrossAxisAlignment.center,
                    children: [
                      // Brand Header
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          isDesktopSidebar ? 18 : 0,
                          18,
                          isDesktopSidebar ? 16 : 0,
                          16,
                        ),
                        child: Row(
                          mainAxisAlignment: isDesktopSidebar
                              ? MainAxisAlignment.start
                              : MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.explore_rounded,
                                color: scheme.onPrimary,
                                size: 20,
                              ),
                            ),
                            if (isDesktopSidebar) ...[
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Edge Mapper',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),

                      // Primary Navigation Items
                      Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: isDesktopSidebar ? 12 : 8,
                        ),
                        child: Column(
                          children: [
                            _SidebarNavItem(
                              icon: Icons.add_a_photo_outlined,
                              selectedIcon: Icons.add_a_photo_rounded,
                              label: 'Capture',
                              shortLabel: 'Capture',
                              selected: _selectedIndex == 0,
                              expanded: isDesktopSidebar,
                              onTap: () => setState(() => _selectedIndex = 0),
                            ),
                            const SizedBox(height: 6),
                            _SidebarNavItem(
                              icon: Icons.route_outlined,
                              selectedIcon: Icons.route_rounded,
                              label: 'Routes',
                              shortLabel: 'Routes',
                              selected: _selectedIndex == 1,
                              expanded: isDesktopSidebar,
                              badgeText: isRecording ? 'REC' : null,
                              badgeColor: semantic.danger,
                              onTap: () => setState(() => _selectedIndex = 1),
                            ),
                            const SizedBox(height: 6),
                            _SidebarNavItem(
                              icon: Icons.layers_outlined,
                              selectedIcon: Icons.layers_rounded,
                              label: 'Records',
                              shortLabel: 'Records',
                              selected: _selectedIndex == 2,
                              expanded: isDesktopSidebar,
                              badgeText:
                                  recordCount > 0 ? '$recordCount' : null,
                              onTap: () => setState(() => _selectedIndex = 2),
                            ),
                            const SizedBox(height: 6),
                            _SidebarNavItem(
                              icon: Icons.emoji_events_outlined,
                              selectedIcon: Icons.emoji_events_rounded,
                              label: 'Explorer Guild',
                              shortLabel: 'Guild',
                              selected: _selectedIndex == 3,
                              expanded: isDesktopSidebar,
                              onTap: () => setState(() => _selectedIndex = 3),
                            ),
                          ],
                        ),
                      ),

                      const Spacer(),

                      // Footer Controls
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          isDesktopSidebar ? 12 : 8,
                          8,
                          isDesktopSidebar ? 12 : 8,
                          14,
                        ),
                        child: Column(
                          crossAxisAlignment: isDesktopSidebar
                              ? CrossAxisAlignment.stretch
                              : CrossAxisAlignment.center,
                          children: [
                            if (isDesktopSidebar) ...[
                              InkWell(
                                onTap: () => showExplorerBadgesSheet(
                                  context,
                                  profile,
                                  onRerollAvatar: widget.prefs.rerollAvatarSeed,
                                  standingLabel: snap.standingLabel,
                                ),
                                borderRadius:
                                    BorderRadius.circular(AppRadii.md),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 9,
                                  ),
                                  decoration: BoxDecoration(
                                    color: scheme.surfaceContainerLow,
                                    borderRadius:
                                        BorderRadius.circular(AppRadii.md),
                                    border: Border.all(
                                      color: scheme.outlineVariant,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      ExplorerAvatarWidget(
                                        avatar: profile.avatar,
                                        size: 34,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '"${profile.avatar.funnyNickname}"',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: textTheme.labelMedium
                                                  ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            Text(
                                              'Lv.${profile.level} · #${snap.currentUserRank} · ${profile.xp} XP',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: textTheme.labelSmall
                                                  ?.copyWith(
                                                fontFeatures: const [
                                                  FontFeature.tabularFigures(),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              ConnectivityBanner(
                                connectivity: widget.connectivity,
                                ai: widget.ai,
                                onTapDetails: _openSettingsHub,
                              ),
                              const SizedBox(height: 10),
                              const Divider(),
                              const SizedBox(height: AppSpacing.xs),
                              Row(
                                children: [
                                  if (canSync)
                                    Expanded(
                                      child: Tooltip(
                                        message: _syncTooltip(),
                                        child: OutlinedButton.icon(
                                          onPressed:
                                              widget.store.isSyncingFirebase
                                                  ? null
                                                  : _syncNow,
                                          style: OutlinedButton.styleFrom(
                                            visualDensity:
                                                VisualDensity.compact,
                                            minimumSize: const Size(0, 38),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                            ),
                                            foregroundColor: widget
                                                    .store.hasPendingRemoteDeletes
                                                ? semantic.danger
                                                : widget.store
                                                            .totalUnsyncedCount >
                                                        0
                                                    ? semantic.success
                                                    : null,
                                          ),
                                          icon: widget.store.isSyncingFirebase
                                              ? const SizedBox(
                                                  width: 14,
                                                  height: 14,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                  ),
                                                )
                                              : const Icon(
                                                  Icons.sync_rounded,
                                                  size: 16,
                                                ),
                                          label: Text(
                                            widget.store.totalUnsyncedCount > 0
                                                ? 'Sync (${widget.store.totalUnsyncedCount})'
                                                : 'Sync',
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (canSync) const SizedBox(width: 6),
                                  IconButton(
                                    tooltip: isForcedOffline
                                        ? 'Go Online'
                                        : 'Offline Mode',
                                    onPressed:
                                        widget.connectivity.toggleForceOffline,
                                    icon: Icon(
                                      isForcedOffline
                                          ? Icons.airplanemode_active_rounded
                                          : Icons.airplanemode_inactive_rounded,
                                      size: 20,
                                      color: isForcedOffline
                                          ? semantic.warning
                                          : scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Settings',
                                    onPressed: _openSettingsHub,
                                    icon: Icon(
                                      Icons.tune_rounded,
                                      size: 20,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ] else ...[
                              if (canSync)
                                IconButton(
                                  tooltip: _syncTooltip(),
                                  onPressed: widget.store.isSyncingFirebase
                                      ? null
                                      : _syncNow,
                                  icon: widget.store.isSyncingFirebase
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Badge(
                                          isLabelVisible:
                                              widget.store.totalUnsyncedCount >
                                                  0,
                                          backgroundColor: widget
                                                  .store.hasPendingRemoteDeletes
                                              ? semantic.danger
                                              : semantic.success,
                                          textColor: Colors.white,
                                          label: Text(
                                            '${widget.store.totalUnsyncedCount}',
                                          ),
                                          child: Icon(
                                            Icons.sync_rounded,
                                            size: 21,
                                            color: widget.store
                                                        .totalUnsyncedCount >
                                                    0
                                                ? (widget.store
                                                        .hasPendingRemoteDeletes
                                                    ? semantic.danger
                                                    : semantic.success)
                                                : null,
                                          ),
                                        ),
                                ),
                              IconButton(
                                tooltip: isForcedOffline
                                    ? 'Go Online'
                                    : 'Offline Mode',
                                onPressed:
                                    widget.connectivity.toggleForceOffline,
                                icon: Icon(
                                  isForcedOffline
                                      ? Icons.airplanemode_active_rounded
                                      : Icons.airplanemode_inactive_rounded,
                                  size: 21,
                                  color: isForcedOffline
                                      ? semantic.warning
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Settings',
                                onPressed: _openSettingsHub,
                                icon: Icon(
                                  Icons.tune_rounded,
                                  size: 21,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Main Content Canvas
              Expanded(child: _buildContentStack()),
            ],
          ),
        );
      },
    );
  }
}

class _SidebarNavItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String shortLabel;
  final bool selected;
  final bool expanded;
  final String? badgeText;
  final Color? badgeColor;
  final VoidCallback onTap;

  const _SidebarNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.shortLabel,
    required this.selected,
    required this.expanded,
    this.badgeText,
    this.badgeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final fg = selected ? scheme.primary : scheme.onSurfaceVariant;
    final bg =
        selected ? scheme.primary.withValues(alpha: 0.13) : Colors.transparent;

    // Medium Tablet Rail: Material 3 pill indicator + visible short label for touch clarity
    if (!expanded) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 34,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
                child: Center(
                  child: Badge(
                    isLabelVisible: badgeText != null,
                    backgroundColor: badgeColor,
                    label: badgeText != null ? Text(badgeText!) : null,
                    child:
                        Icon(selected ? selectedIcon : icon, color: fg, size: 22),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                shortLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall?.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Row(
          children: [
            Icon(selected ? selectedIcon : icon, color: fg, size: 21),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelLarge?.copyWith(
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            if (badgeText != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: (badgeColor ?? scheme.primary).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
                child: Text(
                  badgeText!,
                  style: textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: badgeColor ?? scheme.primary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
