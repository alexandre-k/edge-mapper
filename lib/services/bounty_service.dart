import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../models/hike_trail.dart';
import '../models/mapping_bounty.dart';
import '../models/osm_record.dart';
import 'bitcoin_service.dart';
import 'connectivity_service.dart';
import 'firebase_sync_service.dart';
import 'local_db_service.dart';
import 'user_preferences_service.dart';

class BountyClaimResult {
  final MappingBounty updatedBounty;
  final BountySubmission submission;

  const BountyClaimResult({
    required this.updatedBounty,
    required this.submission,
  });
}

/// Manages social mapping bounties / announcements backed by Bitcoin rewards:
/// - Post a mapping request for an area/POI with a sats reward
/// - Share the announcement socially (copy/share card)
/// - Claim with a captured OsmRecord inside the bounty's target zone
/// - Pay the mapper in Bitcoin (BIP-21 QR / wallet launch) and mark Paid
class BountyService extends ChangeNotifier {
  static final RegExp _safeDocIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  final LocalDbService db;
  final UserPreferencesService prefs;
  final FirebaseSyncService firebaseSync;
  final ConnectivityService connectivity;
  final http.Client _client;
  final Uuid _uuid = const Uuid();

  List<MappingBounty> _bounties = [];
  bool _isSyncing = false;

  BountyService({
    required this.db,
    required this.prefs,
    required this.firebaseSync,
    required this.connectivity,
    http.Client? client,
  }) : _client = client ?? http.Client();

  List<MappingBounty> get bounties => List.unmodifiable(_bounties);
  List<MappingBounty> get openBounties =>
      _bounties.where((b) => b.status == BountyStatus.open).toList();
  bool get isSyncing => _isSyncing;

  int get completedBountiesByCurrentUser => _bounties
      .where(
        (b) => b.submissions.any(
          (s) => s.mapperExplorerId == prefs.explorerId,
        ),
      )
      .length;

  Future<void> init() async {
    _bounties = await db.getAllBounties();
    if (_bounties.isEmpty) {
      // Seed 2 starter community announcements so users immediately see how BTC bounties work
      await _seedStarterBounties();
    }
    notifyListeners();
  }

  Future<void> _seedStarterBounties() async {
    final now = DateTime.now();
    final starters = [
      MappingBounty(
        id: 'starter-bounty-wheelchair',
        title: 'Survey wheelchair ramps & entrances near station',
        description:
            'Please photograph main station exits & tactile paving so wheelchair accessibility tags (wheelchair=yes/limited, tactile_paving=yes) can be updated on OSM.',
        areaLabel: 'Central Transit Plaza (Community Quest)',
        targetLatitude: 35.6812,
        targetLongitude: 139.7671,
        radiusMeters: 600,
        requestedTags: const [
          'wheelchair=yes',
          'tactile_paving=yes',
          'entrance=main',
        ],
        rewardSats: 15000,
        creatorExplorerId: 'league_01',
        creatorName: 'Kenji_T',
        createdAt: now.subtract(const Duration(hours: 6)),
      ),
      MappingBounty(
        id: 'starter-bounty-water',
        title: 'Map public drinking water fountains in the park',
        description:
            'Summer runners need accurate amenity=drinking_water locations & bottle refill notes before the weekend trail run!',
        areaLabel: 'Riverside Park Loop',
        targetLatitude: 48.8566,
        targetLongitude: 2.3522,
        radiusMeters: 800,
        requestedTags: const [
          'amenity=drinking_water',
          'bottle=yes',
          'fee=no',
        ],
        rewardSats: 8000,
        creatorExplorerId: 'league_02',
        creatorName: 'Camille_M',
        createdAt: now.subtract(const Duration(hours: 14)),
      ),
    ];
    for (final b in starters) {
      await db.upsertBounty(b);
    }
    _bounties = await db.getAllBounties();
  }

  Future<MappingBounty> createBounty({
    required String title,
    required String description,
    required String areaLabel,
    required double targetLatitude,
    required double targetLongitude,
    double radiusMeters = 400.0,
    List<String> requestedTags = const [],
    required int rewardSats,
  }) async {
    final bounty = MappingBounty(
      id: _uuid.v4(),
      title: title.trim(),
      description: description.trim(),
      areaLabel: areaLabel.trim().isEmpty
          ? '${targetLatitude.toStringAsFixed(4)}, ${targetLongitude.toStringAsFixed(4)}'
          : areaLabel.trim(),
      targetLatitude: targetLatitude,
      targetLongitude: targetLongitude,
      radiusMeters: radiusMeters.clamp(50.0, 5000.0),
      requestedTags: requestedTags,
      rewardSats: rewardSats.clamp(100, 100000000),
      creatorExplorerId: prefs.explorerId,
      creatorName: prefs.explorerHandle,
      createdAt: DateTime.now(),
      status: BountyStatus.open,
    );

    await db.upsertBounty(bounty);
    _bounties = await db.getAllBounties();
    notifyListeners();

    // Best-effort cloud publish if Firestore is configured
    // ignore: unawaited_futures
    _pushBountyToFirestore(bounty);

    return bounty;
  }

  /// Submits a captured [record] to claim [bounty] after validating the payout
  /// address (excluding arbitrary HTTPS URLs) and target-zone proximity.
  Future<BountyClaimResult> submitClaim({
    required MappingBounty bounty,
    required OsmRecord record,
    required String mapperBtcAddress,
  }) async {
    final cleanAddr = mapperBtcAddress.trim();
    if (!BitcoinService.isValidBitcoinOrLightningAddress(
      cleanAddr,
      allowBtcPayUrl: false,
    )) {
      throw StateError(
        'Enter a valid Bitcoin (bc1p.../bc1q...), Silent Payment (sp1...), Lightning (user@domain), BOLT 12, or bitcoin: URI.',
      );
    }

    final distMeters = haversineMeters(
      record.effectiveLatitude,
      record.effectiveLongitude,
      bounty.targetLatitude,
      bounty.targetLongitude,
    );
    if (distMeters > bounty.radiusMeters) {
      throw StateError(
        'Captured record is ${distMeters.round()}m from the bounty target (outside ${bounty.radiusMeters.round()}m radius).',
      );
    }

    final submission = BountySubmission(
      submissionId: _uuid.v4(),
      mapperExplorerId: prefs.explorerId,
      mapperName: prefs.explorerHandle,
      mapperBtcAddress: cleanAddr,
      recordId: record.id,
      recordSummary: record.displayName,
      submittedAt: DateTime.now(),
      distanceMeters: distMeters,
    );

    final updated = bounty.copyWith(
      status: BountyStatus.claimed,
      submissions: [...bounty.submissions, submission],
    );

    await db.upsertBounty(updated);
    _bounties = await db.getAllBounties();
    notifyListeners();

    // Push claim to the dedicated submissions subcollection (so claimants
    // never need write permission on the bounty creator's parent document).
    // ignore: unawaited_futures
    _pushSubmissionToFirestore(bounty.id, submission);
    if (bounty.creatorExplorerId == prefs.explorerId) {
      // ignore: unawaited_futures
      _pushBountyToFirestore(updated);
    }

    return BountyClaimResult(
      updatedBounty: updated,
      submission: submission,
    );
  }

  Future<MappingBounty> markSubmissionPaid({
    required MappingBounty bounty,
    required String submissionId,
  }) async {
    final now = DateTime.now();
    final updatedSubs = bounty.submissions
        .map((s) => s.submissionId == submissionId ? s.copyWith(paidAt: now) : s)
        .toList();
    final updated = bounty.copyWith(
      status: BountyStatus.paid,
      submissions: updatedSubs,
    );
    await db.upsertBounty(updated);
    _bounties = await db.getAllBounties();
    notifyListeners();
    if (bounty.creatorExplorerId == prefs.explorerId) {
      // ignore: unawaited_futures
      _pushBountyToFirestore(updated);
    }
    return updated;
  }

  Future<void> deleteBounty(String id) async {
    final existing = _bounties.where((b) => b.id == id).firstOrNull;
    await db.deleteBounty(id);
    _bounties = await db.getAllBounties();
    notifyListeners();
    if (existing != null && existing.creatorExplorerId == prefs.explorerId) {
      // ignore: unawaited_futures
      _deleteBountyFromFirestore(id);
    }
  }

  /// Generates a ready-to-post social announcement text (for Nostr, X, Telegram,
  /// OSM community chats, etc.) advertising the Bitcoin mapping bounty.
  static String buildSocialAnnouncementText(MappingBounty bounty) {
    final tagsLine = bounty.requestedTags.isNotEmpty
        ? '\nRequested OSM tags: ${bounty.requestedTags.join(', ')}'
        : '';
    return '🗺️ BITCOIN MAPPING BOUNTY: ${BitcoinService.formatSats(bounty.rewardSats)} (${BitcoinService.formatBtcFromSats(bounty.rewardSats)} BTC)\n'
        '📍 Area: ${bounty.areaLabel} (${bounty.targetLatitude.toStringAsFixed(5)}, ${bounty.targetLongitude.toStringAsFixed(5)} · ±${bounty.radiusMeters.round()}m)\n'
        '🎯 Mission: ${bounty.title}\n'
        '${bounty.description}$tagsLine\n'
        'Posted by ${bounty.creatorName} via Edge Mapper · OpenStreetMap';
  }

  Future<void> _pushBountyToFirestore(MappingBounty bounty) async {
    if (!connectivity.isOnline || !firebaseSync.canSyncNow) return;
    if (!_safeDocIdPattern.hasMatch(bounty.id)) return;
    final projectId = firebaseSync.activeProjectId;
    final uid = firebaseSync.currentUid;
    if (projectId == null || projectId.isEmpty || uid == null || uid.isEmpty) {
      return;
    }
    try {
      final uri = Uri.https(
        'firestore.googleapis.com',
        '/v1/projects/$projectId/databases/(default)/documents/mapping_bounties/${bounty.id}',
      );
      final body = {
        'fields': {
          'uid': {'stringValue': uid},
          'payloadJson': {'stringValue': jsonEncode(bounty.toDbMap())},
          'updatedAt': {'stringValue': DateTime.now().toUtc().toIso8601String()},
        },
      };
      final headers = await firebaseSync.buildAuthHeaders();
      final resp = await _client
          .patch(
            uri,
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint(
          '[EdgeMapper] Bounty cloud push returned HTTP ${resp.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('[EdgeMapper] Bounty cloud push skipped: $e');
    }
  }

  Future<void> _pushSubmissionToFirestore(
    String bountyId,
    BountySubmission submission,
  ) async {
    if (!connectivity.isOnline || !firebaseSync.canSyncNow) return;
    if (!_safeDocIdPattern.hasMatch(bountyId) ||
        !_safeDocIdPattern.hasMatch(submission.submissionId)) {
      return;
    }
    final projectId = firebaseSync.activeProjectId;
    final uid = firebaseSync.currentUid;
    if (projectId == null || projectId.isEmpty || uid == null || uid.isEmpty) {
      return;
    }
    try {
      final uri = Uri.https(
        'firestore.googleapis.com',
        '/v1/projects/$projectId/databases/(default)/documents/mapping_bounties/$bountyId/submissions/${submission.submissionId}',
      );
      final body = {
        'fields': {
          'uid': {'stringValue': uid},
          'bountyId': {'stringValue': bountyId},
          'payloadJson': {'stringValue': jsonEncode(submission.toJson())},
          'submittedAt': {
            'stringValue': submission.submittedAt.toUtc().toIso8601String(),
          },
        },
      };
      final headers = await firebaseSync.buildAuthHeaders();
      final resp = await _client
          .patch(
            uri,
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        debugPrint(
          '[EdgeMapper] Bounty claim push returned HTTP ${resp.statusCode}',
        );
      }
    } catch (e) {
      debugPrint('[EdgeMapper] Bounty claim push skipped: $e');
    }
  }

  Future<void> _deleteBountyFromFirestore(String bountyId) async {
    if (!connectivity.isOnline || !firebaseSync.canSyncNow) return;
    if (!_safeDocIdPattern.hasMatch(bountyId)) return;
    final projectId = firebaseSync.activeProjectId;
    if (projectId == null || projectId.isEmpty) return;
    try {
      final uri = Uri.https(
        'firestore.googleapis.com',
        '/v1/projects/$projectId/databases/(default)/documents/mapping_bounties/$bountyId',
      );
      final headers = await firebaseSync.buildAuthHeaders();
      await _client
          .delete(uri, headers: headers)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[EdgeMapper] Bounty remote delete skipped: $e');
    }
  }

  static String? _extractDocId(dynamic rawName) {
    final name = rawName?.toString() ?? '';
    if (name.isEmpty) return null;
    final idx = name.lastIndexOf('/');
    final docId = idx >= 0 ? name.substring(idx + 1) : name;
    if (!_safeDocIdPattern.hasMatch(docId)) return null;
    return docId;
  }

  Future<List<BountySubmission>> _fetchSubmissionsForBounty(
    String projectId,
    String bountyId,
    Map<String, String> headers,
  ) async {
    if (!_safeDocIdPattern.hasMatch(bountyId)) return const [];
    try {
      final uri = Uri.https(
        'firestore.googleapis.com',
        '/v1/projects/$projectId/databases/(default)/documents/mapping_bounties/$bountyId/submissions',
        {'pageSize': '50'},
      );
      final resp = await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return const [];
      final decoded =
          jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true))
              as Map<String, dynamic>;
      final docs = decoded['documents'] as List? ?? const [];
      final result = <BountySubmission>[];
      for (final doc in docs) {
        if (doc is! Map) continue;
        final subDocId = _extractDocId(doc['name']);
        if (subDocId == null) continue;
        final raw = doc['fields']?['payloadJson']?['stringValue']?.toString();
        if (raw == null || raw.isEmpty) continue;
        try {
          final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
          final sub = BountySubmission.fromJson(map);
          // Prevent ID spoofing and untrusted HTTPS phishing payout URLs.
          if (sub.submissionId != subDocId) continue;
          if (!BitcoinService.isValidBitcoinOrLightningAddress(
            sub.mapperBtcAddress,
            allowBtcPayUrl: false,
          )) {
            continue;
          }
          result.add(sub);
        } catch (_) {}
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  Future<void> refreshFromFirestore() async {
    if (!connectivity.isOnline || !firebaseSync.canSyncNow) return;
    final projectId = firebaseSync.activeProjectId;
    if (projectId == null || projectId.isEmpty) return;

    _isSyncing = true;
    notifyListeners();
    try {
      final uri = Uri.https(
        'firestore.googleapis.com',
        '/v1/projects/$projectId/databases/(default)/documents/mapping_bounties',
        {'pageSize': '50'},
      );
      final headers = await firebaseSync.buildAuthHeaders();
      final resp = await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200) {
        final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
        final decoded = jsonDecode(bodyText) as Map<String, dynamic>;
        final docs = decoded['documents'] as List? ?? const [];
        for (final doc in docs) {
          if (doc is! Map) continue;
          final docId = _extractDocId(doc['name']);
          final docUid = doc['fields']?['uid']?['stringValue']?.toString();
          final raw = doc['fields']?['payloadJson']?['stringValue']?.toString();
          if (docId == null ||
              docUid == null ||
              docUid.isEmpty ||
              raw == null ||
              raw.isEmpty) {
            continue;
          }
          try {
            final map = Map<String, Object?>.from(jsonDecode(raw) as Map);
            final bounty = MappingBounty.fromDbMap(map);
            // Enforce strict document-ID equality so an attacker cannot craft
            // a separate Firestore document whose payloadJson overwrites a
            // victim's bounty ID locally.
            if (bounty.id != docId) continue;
            // Filter out invalid / phishing BTC payout URLs from remote submissions
            final validParentSubs = bounty.submissions
                .where(
                  (s) => BitcoinService.isValidBitcoinOrLightningAddress(
                    s.mapperBtcAddress,
                    allowBtcPayUrl: false,
                  ),
                )
                .toList();
            final remoteSubcollection =
                await _fetchSubmissionsForBounty(projectId, docId, headers);
            final mergedById = <String, BountySubmission>{
              for (final s in validParentSubs) s.submissionId: s,
              for (final s in remoteSubcollection)
                if (!validParentSubs.any((p) => p.submissionId == s.submissionId))
                  s.submissionId: s,
            };
            final sanitized = bounty.copyWith(
              submissions: mergedById.values.toList(),
            );
            await db.upsertBounty(sanitized);
          } catch (_) {}
        }
        _bounties = await db.getAllBounties();
      }
    } catch (e) {
      debugPrint('[EdgeMapper] Bounty cloud refresh skipped: $e');
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }
}
