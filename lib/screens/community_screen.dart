import 'package:flutter/material.dart';

import '../data/osm_tag_standards.dart';
import '../models/osm_record.dart';
import '../services/bounty_service.dart';
import '../services/connectivity_service.dart';
import '../services/explorer_avatar_service.dart';
import '../services/leaderboard_service.dart';
import '../services/mapper_store.dart';
import '../services/osm_browser_bridge.dart';
import '../services/sensor_service.dart';
import '../services/user_preferences_service.dart';
import '../theme/app_theme.dart';
import '../widgets/bitcoin_donate_sheet.dart';
import '../widgets/explorer_avatar_widget.dart';
import '../widgets/responsive_layout.dart';

/// Community Ranking Hub:
/// Real OpenStreetMap mapper rankings near your captured places / GPS location.
class CommunityScreen extends StatefulWidget {
  final MapperStore store;
  final SensorService sensors;
  final UserPreferencesService prefs;
  final ConnectivityService connectivity;
  final LeaderboardService leaderboard;
  final BountyService bounties;

  const CommunityScreen({
    super.key,
    required this.store,
    required this.sensors,
    required this.prefs,
    required this.connectivity,
    required this.leaderboard,
    required this.bounties,
  });

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  static const String _gpsAnchorId = '__current_gps__';

  String? _selectedPoiAnchorId;
  double _selectedRadiusMeters = 2000;
  bool _autoLoadTriggered = false;

  @override
  void initState() {
    super.initState();
    _selectedRadiusMeters = widget.leaderboard.radiusMeters;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoLoadOsmRanking();
    });
  }

  List<OsmRecord> get _poiAnchors => widget.store.records
      .where(
        (r) => OsmTagStandards.hasValidGps(
          r.effectiveLatitude,
          r.effectiveLongitude,
        ),
      )
      .take(20)
      .toList();

  ({double lat, double lon, String label, String id})? _resolveAnchor() {
    final pois = _poiAnchors;
    if (_selectedPoiAnchorId != null && _selectedPoiAnchorId != _gpsAnchorId) {
      for (final p in pois) {
        if (p.id == _selectedPoiAnchorId) {
          return (
            lat: p.effectiveLatitude,
            lon: p.effectiveLongitude,
            label: p.displayName,
            id: p.id,
          );
        }
      }
    }
    if (_selectedPoiAnchorId == null && pois.isNotEmpty) {
      final first = pois.first;
      return (
        lat: first.effectiveLatitude,
        lon: first.effectiveLongitude,
        label: first.displayName,
        id: first.id,
      );
    }
    final pos = widget.sensors.currentPosition;
    if (pos != null &&
        OsmTagStandards.hasValidGps(pos.latitude, pos.longitude)) {
      return (
        lat: pos.latitude,
        lon: pos.longitude,
        label: 'Current GPS',
        id: _gpsAnchorId,
      );
    }
    if (pois.isNotEmpty) {
      final first = pois.first;
      return (
        lat: first.effectiveLatitude,
        lon: first.effectiveLongitude,
        label: first.displayName,
        id: first.id,
      );
    }
    return null;
  }

  Future<void> _maybeAutoLoadOsmRanking() async {
    if (_autoLoadTriggered || !mounted) return;
    if (!widget.connectivity.isOnline || widget.leaderboard.isRefreshing) return;
    final anchor = _resolveAnchor();
    if (anchor == null) return;
    _autoLoadTriggered = true;
    await widget.leaderboard.fetchNearbyOsmMappers(
      latitude: anchor.lat,
      longitude: anchor.lon,
      poiLabel: anchor.label,
      radiusMeters: _selectedRadiusMeters,
    );
  }

  Future<void> _refreshCloud() async {
    final anchor = _resolveAnchor();
    if (anchor != null) {
      await widget.leaderboard.fetchNearbyOsmMappers(
        latitude: anchor.lat,
        longitude: anchor.lon,
        poiLabel: anchor.label,
        radiusMeters: _selectedRadiusMeters,
      );
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Wait for a GPS fix or capture a POI first to load real OpenStreetMap mappers nearby.',
          ),
        ),
      );
    }
  }

  Future<void> _showOsmMapperProfileSheet(LeaderboardEntry entry) async {
    final scheme = Theme.of(context).colorScheme;
    final avatar = ExplorerAvatarService.buildAvatar(
      seed: entry.avatarSeed,
      level: entry.level,
      xp: entry.xp,
      recordsCount: entry.recordsCount,
      multiPhotoRecordsCount: entry.osmAreaChangesetsCount,
      multilingualRecordsCount: entry.osmAreaChangesetsCount,
      offlineRecordsCount: 0,
      totalTrailKm: entry.trailsKm,
      activeDayStreak: 1,
    );
    final profileUrl = entry.effectiveOsmProfileUrl;

    await showAdaptiveSheet<void>(
      context: context,
      desktopMaxWidth: 460,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ExplorerAvatarWidget(
                    avatar: avatar,
                    size: 54,
                    showLevelBadge: true,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.isCurrentUser
                              ? '${entry.displayName} (You)'
                              : entry.displayName,
                          style: Theme.of(ctx)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          'Rank #${entry.rank} · Lv.${entry.level} · ${entry.xp} XP',
                          style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        if (entry.osmAccountCreatedAt != null)
                          Text(
                            'OpenStreetMap mapper since ${entry.osmAccountCreatedAt!.year}',
                            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (entry.osmAreaChangesCount > 0)
                    SubtleTag(
                      label: '${entry.osmAreaChangesCount} edits near POI',
                      tint: scheme.primary,
                    ),
                  if (entry.osmAreaChangesetsCount > 0)
                    SubtleTag(
                      label: '${entry.osmAreaChangesetsCount} local changesets',
                    ),
                  if (entry.distanceToPoiMeters != null)
                    SubtleTag(
                      label:
                          '${LeaderboardService.formatDistanceFromPoi(entry.distanceToPoiMeters!)} from POI',
                    ),
                  if (entry.osmLifetimeChangesets > 0)
                    SubtleTag(
                      label:
                          '${entry.osmLifetimeChangesets} lifetime OSM changesets',
                    ),
                  if (entry.osmTracesCount > 0)
                    SubtleTag(
                      label: '${entry.osmTracesCount} GPS traces',
                    ),
                ],
              ),
              if (profileUrl.isNotEmpty) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => openExternalUrl(profileUrl),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('View Real OpenStreetMap Profile'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.semanticColors;
    final isCompact = AppBreakpoints.isCompact(context);
    final hPad = AppBreakpoints.horizontalPadding(context);

    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.store,
        widget.prefs,
        widget.leaderboard,
      ]),
      builder: (context, _) {
        final profile = widget.store.explorerProfile;
        final snap = widget.leaderboard.buildSnapshot(
          currentProfile: profile,
          recordsCount: widget.store.records.length,
          totalTrailKm: widget.store.totalTrailKm,
        );

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            hPad,
            AppSpacing.sm,
            hPad,
            AppSpacing.xl,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!isCompact) ...[
                    ScreenHeader(
                      title: 'Explorer Guild',
                      subtitle:
                          'Local OpenStreetMap mapper rankings near your places.',
                      trailing: OutlinedButton.icon(
                        onPressed: () => showBitcoinPaymentSheet(context),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(0, 38),
                        ),
                        icon: Icon(
                          Icons.favorite_rounded,
                          size: 17,
                          color: semantic.accent,
                        ),
                        label: const Text('Support'),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  _buildRankingTab(context, snap),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRankingTab(BuildContext context, LeaderboardSnapshot snap) {
    final scheme = Theme.of(context).colorScheme;
    final pois = _poiAnchors;
    final activeAnchor = _resolveAnchor();
    final hasGps = widget.sensors.currentPosition != null &&
        OsmTagStandards.hasValidGps(
          widget.sensors.currentPosition!.latitude,
          widget.sensors.currentPosition!.longitude,
        );

    final anchorItems = <DropdownMenuItem<String>>[
      if (hasGps)
        const DropdownMenuItem(
          value: _gpsAnchorId,
          child: Text('Current GPS Location'),
        ),
      for (final p in pois)
        DropdownMenuItem(
          value: p.id,
          child: Text(
            'POI: ${p.displayName}',
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
    final currentDropdownValue = activeAnchor != null &&
            anchorItems.any((i) => i.value == activeAnchor.id)
        ? activeAnchor.id
        : (anchorItems.isNotEmpty ? anchorItems.first.value : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Standing & Incentive Banner
        SurfacePanel(
          padding: const EdgeInsets.all(16),
          borderColor: scheme.primary.withValues(alpha: 0.4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ExplorerAvatarWidget(
                    avatar: widget.store.explorerProfile.avatar,
                    size: 56,
                    showLevelBadge: true,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          snap.standingLabel,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: scheme.primary,
                              ),
                        ),
                        Text(
                          snap.currentUser.isRealOsmProfile
                              ? '${snap.currentUser.displayName} (OpenStreetMap)'
                              : '${snap.currentUser.displayName} · Local Profile',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          snap.currentUser.osmAreaChangesCount > 0 ||
                                  snap.currentUser.osmLifetimeChangesets > 0
                              ? '${snap.currentUser.xp} XP · ${snap.currentUser.osmAreaChangesCount} OSM edits nearby · ${snap.currentUser.osmLifetimeChangesets} total changesets'
                              : '${snap.currentUser.xp} XP · ${snap.currentUser.recordsCount} local POIs · ${snap.currentUser.trailsKm.toStringAsFixed(1)} km routes',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh Real OpenStreetMap Mappers',
                    onPressed: widget.leaderboard.isRefreshing ||
                            !widget.connectivity.isOnline
                        ? null
                        : _refreshCloud,
                    icon: widget.leaderboard.isRefreshing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.local_fire_department_rounded,
                      color: scheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        snap.incentiveMessage,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // POI Anchor & Radius Controls (Real OpenStreetMap Area Filter)
        SurfacePanel(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.public_rounded, size: 17, color: scheme.primary),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'Real OpenStreetMap Mappers Near POI',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (snap.anchorLabel != null)
                    SubtleTag(
                      label:
                          '±${LeaderboardService.formatDistanceFromPoi(snap.radiusMeters)}',
                      tint: scheme.primary,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (anchorItems.isNotEmpty) ...[
                DropdownButtonFormField<String>(
                  key: ValueKey(
                    'poi-anchor-$currentDropdownValue-${anchorItems.length}',
                  ),
                  initialValue: currentDropdownValue,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Point of Interest Anchor',
                    isDense: true,
                  ),
                  items: anchorItems,
                  onChanged: (val) async {
                    if (val == null) return;
                    setState(() => _selectedPoiAnchorId = val);
                    final next = _resolveAnchor();
                    if (next != null && widget.connectivity.isOnline) {
                      await widget.leaderboard.fetchNearbyOsmMappers(
                        latitude: next.lat,
                        longitude: next.lon,
                        poiLabel: next.label,
                        radiusMeters: _selectedRadiusMeters,
                      );
                    }
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'Radius:',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    for (final r in const [1000.0, 2000.0, 5000.0])
                      ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(LeaderboardService.formatDistanceFromPoi(r)),
                        selected: _selectedRadiusMeters == r,
                        onSelected: (_) async {
                          setState(() => _selectedRadiusMeters = r);
                          final next = _resolveAnchor();
                          if (next != null && widget.connectivity.isOnline) {
                            await widget.leaderboard.fetchNearbyOsmMappers(
                              latitude: next.lat,
                              longitude: next.lon,
                              poiLabel: next.label,
                              radiusMeters: r,
                            );
                          }
                        },
                      ),
                  ],
                ),
              ] else ...[
                Text(
                  'Capture a POI or wait for GPS to query real OpenStreetMap contributors around your location.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
              if (snap.lastError != null) ...[
                const SizedBox(height: 8),
                Text(
                  snap.lastError!,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Full Real OpenStreetMap Leaderboard Table
        SurfacePanel(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        snap.anchorLabel != null
                            ? 'OSM Guild near ${snap.anchorLabel} (${snap.totalMappers})'
                            : 'OpenStreetMap Guild (${snap.totalMappers})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      snap.syncedWithCloud
                          ? (widget.connectivity.isOnline
                              ? 'Live OSM'
                              : 'Cached OSM')
                          : 'Not loaded',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              const Divider(),
              for (final entry in snap.entries)
                _LeaderboardRow(
                  entry: entry,
                  onTap: () => _showOsmMapperProfileSheet(entry),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                child: Text(
                  'Real OpenStreetMap contributors & mapped counts via OSM API v0.6 · XP = 5/edit + 20/local changeset + 2/lifetime changeset + 10/GPS trace. Tap a mapper to view their OSM profile.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LeaderboardRow extends StatelessWidget {
  final LeaderboardEntry entry;
  final VoidCallback? onTap;

  const _LeaderboardRow({
    required this.entry,
    this.onTap,
  });

  String _subtitleText() {
    final parts = <String>[];
    if (entry.osmAreaChangesCount > 0) {
      parts.add('${entry.osmAreaChangesCount} edits');
    } else if (entry.recordsCount > 0) {
      parts.add('${entry.recordsCount} POIs');
    }
    if (entry.osmAreaChangesetsCount > 0) {
      parts.add(
        '${entry.osmAreaChangesetsCount} changeset${entry.osmAreaChangesetsCount == 1 ? '' : 's'}',
      );
    }
    if (entry.distanceToPoiMeters != null && !entry.isCurrentUser) {
      parts.add(
        '${LeaderboardService.formatDistanceFromPoi(entry.distanceToPoiMeters!)} away',
      );
    }
    if (entry.osmLifetimeChangesets > 0) {
      parts.add('${entry.osmLifetimeChangesets} OSM total');
    }
    if (parts.isEmpty) {
      return '${entry.recordsCount} POIs · ${entry.trailsKm.toStringAsFixed(1)} km';
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final avatar = ExplorerAvatarService.buildAvatar(
      seed: entry.avatarSeed,
      level: entry.level,
      xp: entry.xp,
      recordsCount: entry.recordsCount,
      multiPhotoRecordsCount: entry.osmAreaChangesetsCount,
      multilingualRecordsCount: entry.osmAreaChangesetsCount,
      offlineRecordsCount: 0,
      totalTrailKm: entry.trailsKm,
      activeDayStreak: 1,
    );

    final Color rankColor = switch (entry.rank) {
      1 => const Color(0xFFF59E0B),
      2 => const Color(0xFF64748B),
      3 => const Color(0xFFB45309),
      _ => scheme.onSurfaceVariant,
    };

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: entry.isCurrentUser
              ? scheme.primary.withValues(alpha: 0.08)
              : null,
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Text(
                '#${entry.rank}',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13.5,
                  color: rankColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            ExplorerAvatarWidget(avatar: avatar, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          entry.isCurrentUser
                              ? '${entry.displayName} (You)'
                              : entry.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: entry.isCurrentUser
                                ? FontWeight.w800
                                : FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Lv.${entry.level}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                      if (entry.isRealOsmProfile) ...[
                        const SizedBox(width: 5),
                        Icon(
                          Icons.verified_rounded,
                          size: 13,
                          color: scheme.primary.withValues(alpha: 0.8),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    _subtitleText(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${entry.xp} XP',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color:
                        entry.isCurrentUser ? scheme.primary : scheme.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (entry.isRealOsmProfile)
                  Text(
                    'OSM profile',
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
