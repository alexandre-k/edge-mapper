import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/osm_tag_standards.dart';
import 'app_env_config.dart';

class TaginfoCheckResult {
  final bool existsOnOsm;
  final bool inWiki;
  final int totalCount;
  final bool verifiedRemotely;

  const TaginfoCheckResult({
    required this.existsOnOsm,
    required this.inWiki,
    required this.totalCount,
    required this.verifiedRemotely,
  });
}

class PublishTagFinding {
  final String itemId;
  final String itemLabel;
  final String key;
  final String value;
  final String reason;
  final bool isConfirmedInvalid;
  final String wikiUrl;

  const PublishTagFinding({
    required this.itemId,
    required this.itemLabel,
    required this.key,
    required this.value,
    required this.reason,
    required this.isConfirmedInvalid,
    required this.wikiUrl,
  });
}

class PublishTagVerificationReport {
  final bool ranOnline;
  final bool taginfoReachable;
  final List<PublishTagFinding> findings;

  const PublishTagVerificationReport({
    required this.ranOnline,
    required this.taginfoReachable,
    required this.findings,
  });

  List<PublishTagFinding> get confirmedInvalid =>
      findings.where((f) => f.isConfirmedInvalid).toList();

  List<PublishTagFinding> get unverifiedWarnings =>
      findings.where((f) => !f.isConfirmedInvalid).toList();

  bool get hasConfirmedInvalid => confirmedInvalid.isNotEmpty;
  bool get hasUnverified => unverifiedWarnings.isNotEmpty;
}

/// Verifies AI-generated OpenStreetMap tags against the official OpenStreetMap
/// Taginfo API v4 (`taginfo.openstreetmap.org/api/4/...`) in addition to the
/// offline curated [OsmTagStandards] registry.
///
/// Prevents LLMs from fabricating non-existent OSM keys (e.g. `fitness_equipment=*`)
/// or invented values on primary feature keys (e.g. `leisure=monkey_gym`).
class OsmTagVerifierService {
  static const String taginfoBaseUrl = 'https://taginfo.openstreetmap.org/api/4';
  static const int minKeyGlobalCount = 500;
  static const int minTagPairGlobalCount = 50;
  static const Duration _requestTimeout = Duration(milliseconds: 3500);

  final http.Client _client;
  final Map<String, TaginfoCheckResult> _keyCache = {};
  final Map<String, TaginfoCheckResult> _tagPairCache = {};

  OsmTagVerifierService({http.Client? client})
      : _client = client ?? http.Client();

  /// Checks whether an OSM [key] exists on OpenStreetMap (offline registry first,
  /// then cached live Taginfo `/api/4/key/overview` when [isOnline] is true).
  Future<TaginfoCheckResult> verifyKey(
    String key, {
    required bool isOnline,
  }) async {
    final cleanKey = key.trim();
    if (cleanKey.isEmpty) {
      return const TaginfoCheckResult(
        existsOnOsm: false,
        inWiki: false,
        totalCount: 0,
        verifiedRemotely: false,
      );
    }

    if (OsmTagStandards.isKnownOsmKey(cleanKey)) {
      return const TaginfoCheckResult(
        existsOnOsm: true,
        inWiki: true,
        totalCount: minKeyGlobalCount,
        verifiedRemotely: false,
      );
    }

    final cached = _keyCache[cleanKey];
    if (cached != null) return cached;

    if (!isOnline) {
      return const TaginfoCheckResult(
        existsOnOsm: false,
        inWiki: false,
        totalCount: 0,
        verifiedRemotely: false,
      );
    }

    try {
      final uri = Uri.parse(
        '$taginfoBaseUrl/key/overview?key=${Uri.encodeQueryComponent(cleanKey)}',
      );
      final resp = await _client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              if (!kIsWeb)
                'User-Agent': AppEnvConfig.httpUserAgent(component: 'Taginfo'),
            },
          )
          .timeout(_requestTimeout);

      if (resp.statusCode != 200) {
        return const TaginfoCheckResult(
          existsOnOsm: false,
          inWiki: false,
          totalCount: 0,
          verifiedRemotely: false,
        );
      }

      final parsed = _parseOverviewResponse(resp.body);
      final valid = parsed.inWiki || parsed.totalCount >= minKeyGlobalCount;
      final res = TaginfoCheckResult(
        existsOnOsm: valid,
        inWiki: parsed.inWiki,
        totalCount: parsed.totalCount,
        verifiedRemotely: true,
      );
      _keyCache[cleanKey] = res;
      return res;
    } catch (e) {
      debugPrint('[EdgeMapper] Taginfo key check skipped for "$cleanKey": $e');
      return const TaginfoCheckResult(
        existsOnOsm: false,
        inWiki: false,
        totalCount: 0,
        verifiedRemotely: false,
      );
    }
  }

  /// Checks whether a primary feature `key=value` pair (e.g. `leisure=fitness_station`,
  /// `fitness_station=horizontal_ladder`, `amenity=cafe`) actually exists on
  /// OpenStreetMap via our verified catalog + live Taginfo `/api/4/tag/overview`.
  Future<TaginfoCheckResult> verifyPrimaryTagPair(
    String key,
    String value, {
    required bool isOnline,
  }) async {
    final cleanKey = key.trim();
    final cleanVal = value.trim();
    if (cleanKey.isEmpty || cleanVal.isEmpty) {
      return const TaginfoCheckResult(
        existsOnOsm: false,
        inWiki: false,
        totalCount: 0,
        verifiedRemotely: false,
      );
    }

    if (OsmTagStandards.isKnownVerifiedTagPair(cleanKey, cleanVal)) {
      return const TaginfoCheckResult(
        existsOnOsm: true,
        inWiki: true,
        totalCount: minTagPairGlobalCount,
        verifiedRemotely: false,
      );
    }

    // Semicolon-separated multi-values (e.g. cuisine=ramen;gyoza): EVERY token must be valid
    if (cleanVal.contains(';')) {
      final parts = cleanVal
          .split(';')
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toList();
      if (parts.isEmpty) {
        return const TaginfoCheckResult(
          existsOnOsm: false,
          inWiki: false,
          totalCount: 0,
          verifiedRemotely: false,
        );
      }
      var allValid = true;
      var anyRemote = false;
      for (final part in parts) {
        final sub = await verifyPrimaryTagPair(cleanKey, part, isOnline: isOnline);
        if (!sub.existsOnOsm) allValid = false;
        if (sub.verifiedRemotely) anyRemote = true;
      }
      return TaginfoCheckResult(
        existsOnOsm: allValid,
        inWiki: false,
        totalCount: allValid ? minTagPairGlobalCount : 0,
        verifiedRemotely: anyRemote,
      );
    }

    final cacheKey = '${cleanKey.toLowerCase()}=${cleanVal.toLowerCase()}';
    final cached = _tagPairCache[cacheKey];
    if (cached != null) return cached;

    if (!isOnline) {
      // Offline: key is already known-valid; allow gracefully when Taginfo cannot be reached
      return TaginfoCheckResult(
        existsOnOsm: OsmTagStandards.isKnownOsmKey(cleanKey),
        inWiki: false,
        totalCount: 0,
        verifiedRemotely: false,
      );
    }

    try {
      final uri = Uri.parse(
        '$taginfoBaseUrl/tag/overview'
        '?key=${Uri.encodeQueryComponent(cleanKey)}'
        '&value=${Uri.encodeQueryComponent(cleanVal)}',
      );
      final resp = await _client
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              if (!kIsWeb)
                'User-Agent': AppEnvConfig.httpUserAgent(component: 'Taginfo'),
            },
          )
          .timeout(_requestTimeout);

      if (resp.statusCode != 200) {
        // Network/Taginfo hiccup: fall back to offline key validity
        return TaginfoCheckResult(
          existsOnOsm: OsmTagStandards.isKnownOsmKey(cleanKey),
          inWiki: false,
          totalCount: 0,
          verifiedRemotely: false,
        );
      }

      final parsed = _parseOverviewResponse(resp.body);
      final valid = parsed.inWiki || parsed.totalCount >= minTagPairGlobalCount;
      final res = TaginfoCheckResult(
        existsOnOsm: valid,
        inWiki: parsed.inWiki,
        totalCount: parsed.totalCount,
        verifiedRemotely: true,
      );
      _tagPairCache[cacheKey] = res;
      return res;
    } catch (e) {
      debugPrint(
        '[EdgeMapper] Taginfo tag check skipped for "$cleanKey=$cleanVal": $e',
      );
      return TaginfoCheckResult(
        existsOnOsm: OsmTagStandards.isKnownOsmKey(cleanKey),
        inWiki: false,
        totalCount: 0,
        verifiedRemotely: false,
      );
    }
  }

  /// Filters an AI-generated tag map so ONLY real OpenStreetMap tags survive:
  /// 1. Runs [OsmTagStandards.sanitizeAiTags] (modernizes deprecated tags,
  ///    repairs hallucinated keys like `fitness_equipment=monkey_bars` ->
  ///    `fitness_station=horizontal_ladder`, drops unknown non-OSM keys).
  /// 2. When [isOnline] is true, verifies non-catalog primary feature `key=value`
  ///    pairs against OpenStreetMap Taginfo API v4 in parallel and drops any
  ///    fabricated values that do not exist on OSM.
  Future<({Map<String, String> verifiedTags, List<String> droppedTags})>
      verifyAiTags(
    Map<String, String> rawTags, {
    required bool isOnline,
    bool hasGpsFix = true,
  }) async {
    final sanitized = OsmTagStandards.sanitizeAiTags(
      rawTags,
      hasGpsFix: hasGpsFix,
    );

    final verified = <String, String>{};
    final dropped = <String>[];

    // Identify primary & controlled-vocabulary tags not already verified offline
    final toCheckRemotely = <MapEntry<String, String>>[];
    for (final entry in sanitized.entries) {
      if (isOnline &&
          OsmTagStandards.isControlledVocabularyKey(entry.key) &&
          !OsmTagStandards.isKnownVerifiedTagPair(entry.key, entry.value)) {
        toCheckRemotely.add(entry);
      } else {
        verified[entry.key] = entry.value;
      }
    }

    if (toCheckRemotely.isNotEmpty) {
      final checks = await Future.wait(
        toCheckRemotely.map(
          (e) async => (
            entry: e,
            result: await verifyPrimaryTagPair(
              e.key,
              e.value,
              isOnline: isOnline,
            ),
          ),
        ),
      );

      for (final check in checks) {
        if (check.result.existsOnOsm) {
          verified[check.entry.key] = check.entry.value;
        } else {
          dropped.add('${check.entry.key}=${check.entry.value}');
          debugPrint(
            '[EdgeMapper] Dropped non-existent OSM tag from AI output: '
            '${check.entry.key}=${check.entry.value} '
            '(Taginfo in_wiki=${check.result.inWiki}, count=${check.result.totalCount})',
          );
        }
      }
    }

    return (verifiedTags: verified, droppedTags: dropped);
  }

  /// Filters AI-generated `tagCandidates` (`key=value -> probability`) so fake
  /// keys or invented controlled-vocabulary values never appear in the Tag Selector.
  Future<Map<String, double>> verifyAiTagCandidates(
    Map<String, double> rawCandidates, {
    required bool isOnline,
    bool hasGpsFix = true,
  }) async {
    final cleaned = <String, double>{};
    final pendingChecks = <(String key, String value, double prob)>[];

    for (final entry in rawCandidates.entries) {
      final eq = entry.key.indexOf('=');
      if (eq <= 0) continue;
      final k = entry.key.substring(0, eq).trim();
      final v = entry.key.substring(eq + 1).trim();
      if (k.isEmpty || v.isEmpty) continue;

      final sanitized = OsmTagStandards.sanitizeAiTags(
        {k: v},
        hasGpsFix: hasGpsFix,
      );
      for (final s in sanitized.entries) {
        if (isOnline &&
            OsmTagStandards.isControlledVocabularyKey(s.key) &&
            !OsmTagStandards.isKnownVerifiedTagPair(s.key, s.value)) {
          pendingChecks.add((s.key, s.value, entry.value));
        } else {
          cleaned['${s.key}=${s.value}'] = entry.value;
        }
      }
    }

    if (pendingChecks.isNotEmpty) {
      final checks = await Future.wait(
        pendingChecks.map((item) async {
          final res = await verifyPrimaryTagPair(
            item.$1,
            item.$2,
            isOnline: isOnline,
          );
          return (item: item, exists: res.existsOnOsm);
        }),
      );
      for (final c in checks) {
        if (c.exists) {
          cleaned['${c.item.$1}=${c.item.$2}'] = c.item.$3;
        }
      }
    }

    return cleaned;
  }

  /// Pre-publish verification of all tags about to be pushed to OpenStreetMap.
  /// Runs offline OSM Wiki standards + live Taginfo API v4 checks in parallel so
  /// hallucinated keys or fabricated controlled-vocabulary values are caught
  /// before upload.
  Future<PublishTagVerificationReport> verifyTagsForPublish({
    required List<({String id, String label, Map<String, String> tags})> items,
    required bool isOnline,
  }) async {
    final findings = <PublishTagFinding>[];
    final pendingKeyChecks =
        <({String itemId, String itemLabel, String key, String value})>[];
    final pendingPairChecks =
        <({String itemId, String itemLabel, String key, String value})>[];

    for (final item in items) {
      final publishable = OsmTagStandards.filterPublishableTags(item.tags);
      final localNotices = OsmTagStandards.findDeprecatedTags(publishable);
      final invalidNoticeByKey = <String, DeprecatedTagNotice>{};
      for (final n in localNotices) {
        if (n.isInvalidTag && !n.canAutoFix) {
          invalidNoticeByKey[n.key] = n;
        }
      }

      for (final entry in publishable.entries) {
        final k = entry.key.trim();
        final v = entry.value.trim();
        if (k.isEmpty || v.isEmpty) continue;
        final kl = k.toLowerCase();

        if (!OsmTagStandards.isKnownOsmKey(k)) {
          pendingKeyChecks.add((
            itemId: item.id,
            itemLabel: item.label,
            key: k,
            value: v,
          ));
          continue;
        }

        final localInvalid = invalidNoticeByKey[k];
        if (localInvalid != null) {
          findings.add(
            PublishTagFinding(
              itemId: item.id,
              itemLabel: item.label,
              key: k,
              value: v,
              reason: localInvalid.reason,
              isConfirmedInvalid: true,
              wikiUrl: localInvalid.wikiUrl,
            ),
          );
          continue;
        }

        if (kl == 'opening_hours' &&
            OsmTagStandards.isLikelyProseOpeningHours(v)) {
          findings.add(
            PublishTagFinding(
              itemId: item.id,
              itemLabel: item.label,
              key: k,
              value: v,
              reason:
                  '"opening_hours=$v" looks like free-form text rather than valid OSM opening_hours syntax.',
              isConfirmedInvalid: true,
              wikiUrl: OsmTagStandards.openingHoursWikiUrl,
            ),
          );
          continue;
        }

        if (OsmTagStandards.isControlledVocabularyKey(k) &&
            !OsmTagStandards.isKnownVerifiedTagPair(k, v)) {
          pendingPairChecks.add((
            itemId: item.id,
            itemLabel: item.label,
            key: k,
            value: v,
          ));
        }
      }
    }

    var taginfoReachable = true;

    if (pendingKeyChecks.isNotEmpty) {
      final keyResults = await Future.wait(
        pendingKeyChecks.map((item) async {
          final res = await verifyKey(item.key, isOnline: isOnline);
          return (item: item, res: res);
        }),
      );
      for (final r in keyResults) {
        if (r.res.verifiedRemotely) {
          if (!r.res.existsOnOsm) {
            findings.add(
              PublishTagFinding(
                itemId: r.item.itemId,
                itemLabel: r.item.itemLabel,
                key: r.item.key,
                value: r.item.value,
                reason:
                    '"${r.item.key}" does not exist on OpenStreetMap Taginfo (in_wiki=${r.res.inWiki}, count=${r.res.totalCount}).',
                isConfirmedInvalid: true,
                wikiUrl: OsmTagStandards.wikiUrlForTag(r.item.key),
              ),
            );
          }
        } else {
          if (isOnline) taginfoReachable = false;
          findings.add(
            PublishTagFinding(
              itemId: r.item.itemId,
              itemLabel: r.item.itemLabel,
              key: r.item.key,
              value: r.item.value,
              reason:
                  '"${r.item.key}" is not in the offline OSM Wiki registry and could not be verified on Taginfo.',
              isConfirmedInvalid: false,
              wikiUrl: OsmTagStandards.wikiUrlForTag(r.item.key),
            ),
          );
        }
      }
    }

    if (pendingPairChecks.isNotEmpty) {
      final pairResults = await Future.wait(
        pendingPairChecks.map((item) async {
          final res = await verifyPrimaryTagPair(
            item.key,
            item.value,
            isOnline: isOnline,
          );
          return (item: item, res: res);
        }),
      );
      for (final r in pairResults) {
        if (r.res.verifiedRemotely) {
          if (!r.res.existsOnOsm) {
            findings.add(
              PublishTagFinding(
                itemId: r.item.itemId,
                itemLabel: r.item.itemLabel,
                key: r.item.key,
                value: r.item.value,
                reason:
                    '"${r.item.key}=${r.item.value}" is not a recognized OpenStreetMap tag on Taginfo (in_wiki=${r.res.inWiki}, count=${r.res.totalCount}).',
                isConfirmedInvalid: true,
                wikiUrl: OsmTagStandards.wikiUrlForTag(r.item.key, r.item.value),
              ),
            );
          }
        } else {
          if (isOnline) taginfoReachable = false;
          findings.add(
            PublishTagFinding(
              itemId: r.item.itemId,
              itemLabel: r.item.itemLabel,
              key: r.item.key,
              value: r.item.value,
              reason:
                  '"${r.item.key}=${r.item.value}" could not be verified against live OSM Taginfo.',
              isConfirmedInvalid: false,
              wikiUrl: OsmTagStandards.wikiUrlForTag(r.item.key, r.item.value),
            ),
          );
        }
      }
    }

    return PublishTagVerificationReport(
      ranOnline: isOnline,
      taginfoReachable: isOnline && taginfoReachable,
      findings: findings,
    );
  }

  static ({bool inWiki, int totalCount}) _parseOverviewResponse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      return (inWiki: false, totalCount: 0);
    }
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      return (inWiki: false, totalCount: 0);
    }
    final inWiki = data['in_wiki'] == true;
    int allCount = 0;
    final counts = data['counts'];
    if (counts is List) {
      for (final item in counts) {
        if (item is Map && item['type'] == 'all') {
          allCount = (item['count'] as num?)?.toInt() ?? 0;
          break;
        }
      }
    }
    return (inWiki: inWiki, totalCount: allCount);
  }
}
