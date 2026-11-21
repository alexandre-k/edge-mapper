import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../data/osm_tag_standards.dart';
import '../models/hike_trail.dart';
import '../models/osm_record.dart';
import 'app_env_config.dart';
import 'osm_browser_bridge.dart';
import 'osm_export_service.dart';
import 'user_preferences_service.dart';

typedef OsmOAuthLauncher = Future<String?> Function({
  required String authorizeUrl,
  required String expectedState,
});

class OsmPkceSession {
  final String clientId;
  final String codeVerifier;
  final String codeChallenge;
  final String state;
  final String redirectUri;
  final String authorizeUrl;

  const OsmPkceSession({
    required this.clientId,
    required this.codeVerifier,
    required this.codeChallenge,
    required this.state,
    required this.redirectUri,
    required this.authorizeUrl,
  });
}

class OsmUserProfile {
  final int id;
  final String displayName;
  final int changesetsCount;

  const OsmUserProfile({
    required this.id,
    required this.displayName,
    this.changesetsCount = 0,
  });
}

class OsmValidationIssue {
  final String title;
  final String detail;
  final bool isBlocking;

  const OsmValidationIssue({
    required this.title,
    required this.detail,
    required this.isBlocking,
  });
}

enum XmlDiffLineKind {
  context,
  added,
  removed,
}

class XmlDiffLine {
  final XmlDiffLineKind kind;
  final String text;

  const XmlDiffLine({
    required this.kind,
    required this.text,
  });
}

/// Represents a selective tag addition, modification, and/or removal on an
/// existing OpenStreetMap element (`node` or `way`).
class OsmElementTagUpdate {
  final String elementType; // 'node' | 'way'
  final int elementId;
  final int? version;
  final double? latitude;
  final double? longitude;
  final List<int> nodeIds;
  final Map<String, String> existingTags;
  final Map<String, String> selectedNewTags;
  final Set<String> removedTagKeys;
  final String? sourceRecordId;

  const OsmElementTagUpdate({
    required this.elementType,
    required this.elementId,
    this.version,
    this.latitude,
    this.longitude,
    this.nodeIds = const [],
    required this.existingTags,
    this.selectedNewTags = const {},
    this.removedTagKeys = const {},
    this.sourceRecordId,
  });

  bool get hasAnyChange =>
      selectedNewTags.isNotEmpty || removedTagKeys.isNotEmpty;

  Map<String, String> get mergedTags {
    final merged = Map<String, String>.from(existingTags);
    for (final key in removedTagKeys) {
      merged.remove(key);
    }
    merged.addAll(selectedNewTags);
    return merged;
  }

  OsmElementTagUpdate copyWith({
    int? version,
    double? latitude,
    double? longitude,
    List<int>? nodeIds,
    Map<String, String>? existingTags,
    Map<String, String>? selectedNewTags,
    Set<String>? removedTagKeys,
  }) {
    return OsmElementTagUpdate(
      elementType: elementType,
      elementId: elementId,
      version: version ?? this.version,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      nodeIds: nodeIds ?? this.nodeIds,
      existingTags: existingTags ?? this.existingTags,
      selectedNewTags: selectedNewTags ?? this.selectedNewTags,
      removedTagKeys: removedTagKeys ?? this.removedTagKeys,
      sourceRecordId: sourceRecordId,
    );
  }
}

class OsmDiffResult {
  final Map<int, int> createdNodeIds;
  final Map<int, int> createdWayIds;
  final List<int> updatedNodeIds;
  final List<int> updatedWayIds;

  const OsmDiffResult({
    this.createdNodeIds = const {},
    this.createdWayIds = const {},
    this.updatedNodeIds = const [],
    this.updatedWayIds = const [],
  });
}

class OsmPublishResult {
  final int changesetId;
  final String changesetUrl;
  final List<int> createdNodeIds;
  final List<int> createdWayIds;
  final List<int> updatedNodeIds;
  final List<int> updatedWayIds;
  final bool isSandbox;

  const OsmPublishResult({
    required this.changesetId,
    required this.changesetUrl,
    required this.createdNodeIds,
    required this.createdWayIds,
    this.updatedNodeIds = const [],
    this.updatedWayIds = const [],
    required this.isSandbox,
  });
}

class OsmGpxUploadResult {
  final int traceId;
  final String traceUrl;
  final bool isSandbox;

  const OsmGpxUploadResult({
    required this.traceId,
    required this.traceUrl,
    required this.isSandbox,
  });
}

/// Handles OpenStreetMap OAuth 2.0 (PKCE) authentication and direct API v0.6
/// publishing (Changesets + OsmChange upload + GPX trace uploads) against either
/// production OpenStreetMap or the OSM Dev Sandbox server.
class OsmPublishService extends ChangeNotifier {
  static const String productionWebBase = 'https://www.openstreetmap.org';
  static const String productionApiBase = 'https://api.openstreetmap.org';
  static const String sandboxBase = 'https://master.apis.dev.openstreetmap.org';
  static const String oauthScopes = 'read_prefs write_api write_gpx';
  static const String androidRedirectUri = 'edgemapper://oauth2/callback';
  static const String oobRedirectUri = 'urn:ietf:wg:oauth:2.0:oob';

  final UserPreferencesService prefs;
  final http.Client _client;
  final OsmOAuthLauncher _oauthLauncher;
  final String? _liveClientIdOverride;
  final String? _sandboxClientIdOverride;
  final String? _redirectUriOverride;

  OsmPkceSession? _pendingPkce;

  OsmPublishService({
    required this.prefs,
    http.Client? client,
    OsmOAuthLauncher? oauthLauncher,
    String? liveClientIdOverride,
    String? sandboxClientIdOverride,
    String? redirectUriOverride,
  })  : _client = client ?? http.Client(),
        _oauthLauncher = oauthLauncher ?? launchOsmOAuthPopup,
        _liveClientIdOverride = liveClientIdOverride,
        _sandboxClientIdOverride = sandboxClientIdOverride,
        _redirectUriOverride = redirectUriOverride {
    prefs.addListener(notifyListeners);
  }

  bool get isSandbox => prefs.osmUseSandbox;
  bool get isAuthenticated => prefs.isOsmAuthenticated;
  String get username => prefs.osmUsername;
  int? get userId => prefs.osmUserId;
  OsmPkceSession? get pendingPkce => _pendingPkce;

  String get webBaseUrl => isSandbox ? sandboxBase : productionWebBase;
  String get apiBaseUrl => isSandbox ? sandboxBase : productionApiBase;
  String get serverLabel => isSandbox ? 'OSM Dev Sandbox' : 'OpenStreetMap Live';

  String get oauthAppRegisterUrl => '$webBaseUrl/oauth2/applications/new';

  /// Developer-configured OAuth 2.0 Client ID for the selected OSM server
  /// (supplied at build time via `OSM_CLIENT_ID` / `OSM_SANDBOX_CLIENT_ID` in `.env`).
  String get effectiveClientId {
    if (isSandbox) {
      final override = _sandboxClientIdOverride?.trim() ?? '';
      if (override.isNotEmpty) return override;
      return AppEnvConfig.osmClientIdForServer(isSandbox: true);
    }
    final override = _liveClientIdOverride?.trim() ?? '';
    if (override.isNotEmpty) return override;
    final fromEnv = AppEnvConfig.osmClientIdForServer(isSandbox: false);
    if (fromEnv.isNotEmpty) return fromEnv;
    // Backwards-compatible fallback if a developer previously stored a live client ID.
    return prefs.osmClientId.trim();
  }

  /// True when the app build includes an OAuth 2.0 Client ID for the active OSM server.
  bool get isOAuthConfigured => effectiveClientId.isNotEmpty;

  /// Automatic platform callback URI (`edgemapper://oauth2/callback` on Android,
  /// `<origin>/osm_callback.html` on Web), or developer `OSM_REDIRECT_URI` override.
  String get effectiveRedirectUri {
    final override = _redirectUriOverride?.trim() ?? '';
    if (override.isNotEmpty) return override;
    final fromEnv = AppEnvConfig.osmRedirectUri.trim();
    if (fromEnv.isNotEmpty && fromEnv != oobRedirectUri) return fromEnv;
    return defaultOsmRedirectUri();
  }

  /// Generates a cryptographically secure PKCE verifier + S256 challenge + state.
  static ({String verifier, String challenge, String state}) generatePkcePair() {
    final rng = math.Random.secure();
    String randomUrlSafe(int byteLen) {
      final bytes = List<int>.generate(byteLen, (_) => rng.nextInt(256));
      return base64UrlEncode(bytes).replaceAll('=', '');
    }

    final verifier = randomUrlSafe(48);
    final digest = sha256.convert(utf8.encode(verifier));
    final challenge = base64UrlEncode(digest.bytes).replaceAll('=', '');
    final state = randomUrlSafe(24);
    return (verifier: verifier, challenge: challenge, state: state);
  }

  /// Extracts an OAuth authorization code from either a bare code string or a
  /// callback URL containing `?code=...`.
  static String extractAuthCode(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.queryParameters.containsKey('code')) {
      return uri.queryParameters['code']?.trim() ?? '';
    }
    return trimmed;
  }

  /// Validates an automatic OAuth 2.0 callback URL (`edgemapper://oauth2/callback?...`
  /// or `https://.../osm_callback.html?...`), verifies CSRF `state`, surfaces
  /// provider cancellation/errors, and returns the authorization `code`.
  static String parseOAuthCallbackUri(
    String callbackUrl, {
    required String expectedState,
  }) {
    final uri = Uri.tryParse(callbackUrl.trim());
    if (uri == null) {
      throw const FormatException('Invalid OpenStreetMap OAuth callback URL.');
    }
    final err = uri.queryParameters['error']?.trim() ?? '';
    if (err.isNotEmpty) {
      final desc = uri.queryParameters['error_description']?.trim();
      throw Exception(
        'OpenStreetMap authorization cancelled: ${(desc != null && desc.isNotEmpty) ? desc : err}',
      );
    }
    final returnedState = uri.queryParameters['state']?.trim() ?? '';
    if (expectedState.trim().isNotEmpty && returnedState != expectedState.trim()) {
      throw StateError(
        'OpenStreetMap sign-in state mismatch. Please try signing in again.',
      );
    }
    final code = uri.queryParameters['code']?.trim() ?? '';
    if (code.isEmpty) {
      throw StateError('OpenStreetMap did not return an authorization code.');
    }
    return code;
  }

  /// Builds an OSM OAuth 2.0 PKCE authorize URL and stores the pending PKCE session.
  OsmPkceSession startPkceSession({
    String? clientId,
    String? redirectUri,
  }) {
    final cleanClientId = (clientId?.trim().isNotEmpty == true)
        ? clientId!.trim()
        : effectiveClientId;
    if (cleanClientId.isEmpty) {
      final envName = isSandbox ? 'OSM_SANDBOX_CLIENT_ID' : 'OSM_CLIENT_ID';
      throw StateError(
        'OpenStreetMap sign-in is not configured in this build ($envName is not set).',
      );
    }
    final resolvedRedirect = (redirectUri?.trim().isNotEmpty == true)
        ? redirectUri!.trim()
        : effectiveRedirectUri;

    final pair = generatePkcePair();
    final uri = Uri.parse('$webBaseUrl/oauth2/authorize').replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': cleanClientId,
        'redirect_uri': resolvedRedirect,
        'scope': oauthScopes,
        'code_challenge': pair.challenge,
        'code_challenge_method': 'S256',
        'state': pair.state,
      },
    );

    final session = OsmPkceSession(
      clientId: cleanClientId,
      codeVerifier: pair.verifier,
      codeChallenge: pair.challenge,
      state: pair.state,
      redirectUri: resolvedRedirect,
      authorizeUrl: uri.toString(),
    );
    _pendingPkce = session;
    notifyListeners();
    return session;
  }

  /// Launches one-tap automatic OAuth 2.0 PKCE sign-in using the developer's
  /// registered OSM Client ID. Captures the authorization code automatically via
  /// popup callback on Web or `edgemapper://oauth2/callback` deep link on Android.
  Future<OsmUserProfile?> beginInteractiveOAuth({
    String? clientId,
    String? redirectUri,
  }) async {
    final session = startPkceSession(
      clientId: clientId,
      redirectUri: redirectUri,
    );

    try {
      final code = await _oauthLauncher(
        authorizeUrl: session.authorizeUrl,
        expectedState: session.state,
      );
      if (code == null || code.trim().isEmpty) {
        _pendingPkce = null;
        notifyListeners();
        return null;
      }
      return await completeOAuthWithCode(code);
    } catch (_) {
      _pendingPkce = null;
      notifyListeners();
      rethrow;
    }
  }

  /// Cancels an in-flight OAuth 2.0 browser sign-in flow cleanly.
  void cancelPendingOAuth() {
    cancelOsmOAuthFlow();
    if (_pendingPkce != null) {
      _pendingPkce = null;
      notifyListeners();
    }
  }

  /// Exchanges an authorization code from the pending PKCE session for an
  /// OAuth 2.0 Bearer access token, verifies the OSM user profile, and persists it.
  Future<OsmUserProfile> completeOAuthWithCode(String rawCodeOrUrl) async {
    final session = _pendingPkce;
    if (session == null) {
      throw StateError(
        'No active sign-in session. Tap "Sign in with OpenStreetMap" first.',
      );
    }
    final trimmed = rawCodeOrUrl.trim();
    if (trimmed.contains('://') || trimmed.contains('?')) {
      final parsedUri = Uri.tryParse(trimmed);
      if (parsedUri != null &&
          (parsedUri.queryParameters.containsKey('code') ||
              parsedUri.queryParameters.containsKey('error') ||
              parsedUri.queryParameters.containsKey('state'))) {
        final returnedState = parsedUri.queryParameters['state']?.trim() ?? '';
        if (returnedState != session.state) {
          throw StateError(
            'OAuth CSRF state mismatch. Restart OpenStreetMap sign-in.',
          );
        }
      }
    }
    final code = extractAuthCode(rawCodeOrUrl);
    if (code.isEmpty) {
      throw StateError('No authorization code received from OpenStreetMap.');
    }

    final tokenUri = Uri.parse('$webBaseUrl/oauth2/token');
    final resp = await _client
        .post(
          tokenUri,
          headers: const {
            'Content-Type': 'application/x-www-form-urlencoded',
          },
          body: {
            'grant_type': 'authorization_code',
            'client_id': session.clientId,
            'code': code,
            'redirect_uri': session.redirectUri,
            'code_verifier': session.codeVerifier,
          },
        )
        .timeout(const Duration(seconds: 20));

    if (resp.statusCode != 200) {
      throw Exception(
        'OSM token exchange failed (${resp.statusCode}): ${_compactBody(resp.body)}',
      );
    }

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final accessToken = decoded['access_token']?.toString().trim() ?? '';
    if (accessToken.isEmpty) {
      throw Exception('OSM OAuth response did not include an access_token.');
    }

    final profile = await fetchUserDetails(tokenOverride: accessToken);
    await prefs.setOsmAuthSession(
      accessToken: accessToken,
      username: profile.displayName,
      userId: profile.id,
    );
    _pendingPkce = null;
    notifyListeners();
    return profile;
  }

  /// Saves and verifies a directly pasted OAuth 2.0 Bearer access token.
  Future<OsmUserProfile> connectWithAccessToken(String token) async {
    final clean = token.trim().replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '');
    if (clean.isEmpty) {
      throw StateError('Enter an OpenStreetMap OAuth 2.0 access token.');
    }
    final profile = await fetchUserDetails(tokenOverride: clean);
    await prefs.setOsmAuthSession(
      accessToken: clean,
      username: profile.displayName,
      userId: profile.id,
    );
    notifyListeners();
    return profile;
  }

  Future<void> signOut() async {
    _pendingPkce = null;
    await prefs.clearOsmAuth();
    notifyListeners();
  }

  /// Verifies the active OAuth 2.0 token against `/api/0.6/user/details.json`.
  Future<OsmUserProfile> fetchUserDetails({String? tokenOverride}) async {
    final token = (tokenOverride ?? prefs.osmAccessToken).trim();
    if (token.isEmpty) {
      throw StateError('Not signed in to OpenStreetMap.');
    }

    final uri = Uri.parse('$apiBaseUrl/api/0.6/user/details.json');
    final resp = await _client
        .get(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
            if (!kIsWeb) 'User-Agent': AppEnvConfig.httpUserAgent(component: 'OSM-API'),
          },
        )
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw Exception(
        'OSM token rejected (${resp.statusCode}). Re-authenticate with read_prefs + write_api permissions.',
      );
    }
    final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
    if (resp.statusCode != 200) {
      throw Exception(
        'Could not fetch OSM user details (${resp.statusCode}): ${_compactBody(bodyText)}',
      );
    }

    final decoded = jsonDecode(bodyText) as Map<String, dynamic>;
    final user = decoded['user'] as Map<String, dynamic>? ?? const {};
    final id = (user['id'] as num?)?.toInt() ?? 0;
    final displayName = user['display_name']?.toString().trim() ?? 'OSM Mapper';
    final changesetsCount =
        ((user['changesets'] as Map?)?['count'] as num?)?.toInt() ?? 0;

    final profile = OsmUserProfile(
      id: id,
      displayName: displayName,
      changesetsCount: changesetsCount,
    );

    if (tokenOverride == null && displayName.isNotEmpty) {
      await prefs.setOsmAuthSession(
        accessToken: token,
        username: displayName,
        userId: id,
      );
    }
    return profile;
  }

  /// Validates records, trails & existing-POI tag updates before publishing to
  /// prevent uploading Null Island `(0,0)` or empty untagged elements to OSM.
  static List<OsmValidationIssue> validateForPublish({
    List<OsmRecord> records = const [],
    List<HikeTrail> trails = const [],
    List<OsmElementTagUpdate> tagUpdates = const [],
  }) {
    final issues = <OsmValidationIssue>[];
    if (records.isEmpty && trails.isEmpty && tagUpdates.isEmpty) {
      issues.add(
        const OsmValidationIssue(
          title: 'Nothing selected',
          detail:
              'Select at least one new record, route, or tag update for an existing OSM POI.',
          isBlocking: true,
        ),
      );
      return issues;
    }

    for (final upd in tagUpdates) {
      if (!upd.hasAnyChange) {
        issues.add(
          OsmValidationIssue(
            title: 'No tag changes selected for ${upd.elementType}/${upd.elementId}',
            detail:
                'Select at least one tag to add, update, or remove on the existing OSM POI.',
            isBlocking: true,
          ),
        );
      } else {
        if (upd.mergedTags.isEmpty) {
          issues.add(
            OsmValidationIssue(
              title: 'Cannot remove all tags from ${upd.elementType}/${upd.elementId}',
              detail:
                  'Keep at least one identifying OSM tag on the element instead of leaving an untagged object.',
              isBlocking: true,
            ),
          );
        }
        final deprecated = OsmTagStandards.findDeprecatedTags(
          upd.selectedNewTags,
          hasGpsFix: upd.latitude != null && upd.longitude != null,
        );
        for (final dep in deprecated) {
          final isBlockingInvalid = dep.isInvalidTag && !dep.canAutoFix;
          issues.add(
            OsmValidationIssue(
              title: isBlockingInvalid
                  ? 'Invalid / possibly hallucinated tag "${dep.key}=${dep.value}" on ${upd.elementType}/${upd.elementId}'
                  : 'Tag "${dep.key}=${dep.value}" on ${upd.elementType}/${upd.elementId}',
              detail: dep.canAutoFix
                  ? '${dep.reason} Automatically fixed on upload (${dep.replacementSummary}).'
                  : '${dep.reason} Please edit or remove this tag before publishing.',
              isBlocking: isBlockingInvalid,
            ),
          );
        }
      }
    }

    for (final rec in records) {
      final lat = rec.effectiveLatitude;
      final lon = rec.effectiveLongitude;
      final validGps = OsmTagStandards.hasValidGps(lat, lon);
      if (!validGps) {
        issues.add(
          OsmValidationIssue(
            title: 'Invalid coordinates on "${rec.displayName}"',
            detail:
                'Coordinates (${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}) look like Null Island or out-of-range GPS.',
            isBlocking: true,
          ),
        );
      }

      final deprecated = OsmTagStandards.findDeprecatedTags(
        rec.tags,
        hasGpsFix: validGps,
      );
      for (final dep in deprecated) {
        final isBlockingInvalid = dep.isInvalidTag && !dep.canAutoFix;
        issues.add(
          OsmValidationIssue(
            title: isBlockingInvalid
                ? 'Invalid / possibly hallucinated tag "${dep.key}=${dep.value}" on "${rec.displayName}"'
                : 'Tag "${dep.key}=${dep.value}" on "${rec.displayName}"',
            detail: dep.canAutoFix
                ? '${dep.reason} Automatically fixed on upload (${dep.replacementSummary}).'
                : '${dep.reason} Please edit or remove this tag before publishing.',
            isBlocking: isBlockingInvalid,
          ),
        );
      }

      final sanitized = prepareTagsForPublish(rec.tags, hasGpsFix: validGps);
      final hasFeatureTag = sanitized.keys.any(
        (k) => k != 'source' && k != 'camera:direction' && k != 'note' && k != 'fixme',
      );
      if (!hasFeatureTag) {
        issues.add(
          OsmValidationIssue(
            title: 'No OSM feature tag on "${rec.displayName}"',
            detail:
                'Add at least one OSM classification tag (like amenity, shop, tourism, highway, or name) before publishing.',
            isBlocking: true,
          ),
        );
      }

      if (rec.status == RecordStatus.uploaded) {
        issues.add(
          OsmValidationIssue(
            title: '"${rec.displayName}" was already published',
            detail:
                'Publishing again will create a duplicate node on OpenStreetMap unless intentional.',
            isBlocking: false,
          ),
        );
      }
    }

    for (final trail in trails) {
      if (trail.points.length < 2) {
        issues.add(
          OsmValidationIssue(
            title: 'Route "${trail.name}" has fewer than 2 GPS points',
            detail: 'At least 2 GPS points are required to create a way or GPX trace.',
            isBlocking: true,
          ),
        );
      }
      if (trail.suspectJumpCount > 0) {
        issues.add(
          OsmValidationIssue(
            title: '${trail.suspectJumpCount} suspected GPS jump(s) in "${trail.name}"',
            detail:
                'Consider inspecting and deleting noisy waypoints before publishing.',
            isBlocking: false,
          ),
        );
      }
    }

    return issues;
  }

  /// Cleans tag keys/values to obey OSM API v0.6 constraints (non-empty, <=255 chars).
  static Map<String, String> sanitizeOsmTags(Map<String, String> raw) {
    final cleaned = <String, String>{};
    for (final entry in raw.entries) {
      final k = entry.key.trim();
      final v = entry.value.trim();
      if (k.isEmpty || v.isEmpty) continue;
      final safeK = k.length > 255 ? k.substring(0, 255) : k;
      final safeV = v.length > 255 ? v.substring(0, 255) : v;
      cleaned[safeK] = safeV;
    }
    return cleaned;
  }

  /// Prepares tags for publication to OpenStreetMap:
  /// - Modernizes deprecated OSM tags (e.g. `day_off` -> `opening_hours`)
  /// - Strips local-only metadata (`camera:direction` on non-camera POIs, `created_by`)
  /// - Normalizes software-name and invalid `GPS` `source` values to `survey`
  /// - Enforces OSM API v0.6 255-character limits.
  static Map<String, String> prepareTagsForPublish(
    Map<String, String> raw, {
    bool hasGpsFix = true,
  }) =>
      OsmTagStandards.filterPublishableTags(raw, hasGpsFix: hasGpsFix);

  /// Builds the `<osm><changeset>...</changeset></osm>` creation XML.
  static String buildChangesetXml({
    required String comment,
    String source = 'survey',
  }) {
    final safeComment = comment.trim().isEmpty
        ? 'Field survey'
        : comment.trim();
    final safeSource = source.trim().isEmpty
        ? 'survey'
        : OsmTagStandards.normalizeSourceValue(source);
    return '''<?xml version="1.0" encoding="UTF-8"?>
<osm>
  <changeset>
    <tag k="created_by" v="${_xmlEscape(AppEnvConfig.osmGenerator)}"/>
    <tag k="comment" v="${_xmlEscape(safeComment.length > 255 ? safeComment.substring(0, 255) : safeComment)}"/>
    <tag k="source" v="${_xmlEscape(safeSource)}"/>
  </changeset>
</osm>''';
  }

  /// Builds an OSM API v0.6 `<osmChange>` XML document for creating new nodes/ways
  /// AND/OR modifying existing OSM elements with selectively merged tags.
  static String buildOsmChangeXml({
    required int changesetId,
    List<OsmRecord> records = const [],
    List<HikeTrail> trails = const [],
    List<OsmElementTagUpdate> tagUpdates = const [],
  }) {
    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln('<osmChange version="0.6" generator="${_xmlEscape(AppEnvConfig.osmGenerator)}">');

    if (records.isNotEmpty || trails.isNotEmpty) {
      buf.writeln('  <create>');

      var nextNodeId = -1;
      var nextWayId = -1;

      for (final record in records) {
        final nid = nextNodeId--;
        final hasGps = OsmTagStandards.hasValidGps(
          record.effectiveLatitude,
          record.effectiveLongitude,
        );
        final tags = prepareTagsForPublish(record.tags, hasGpsFix: hasGps);
        tags.putIfAbsent(
          'source',
          () => OsmTagStandards.recommendedSource(hasGpsFix: hasGps),
        );
        buf.writeln(
          '    <node id="$nid" changeset="$changesetId" '
          'lat="${record.effectiveLatitude.toStringAsFixed(7)}" '
          'lon="${record.effectiveLongitude.toStringAsFixed(7)}">',
        );
        for (final entry in tags.entries) {
          buf.writeln(
            '      <tag k="${_xmlEscape(entry.key)}" v="${_xmlEscape(entry.value)}"/>',
          );
        }
        buf.writeln('    </node>');
      }

      for (final trail in trails) {
        if (trail.points.length < 2) continue;
        final wayNodeIds = <int>[];
        for (final pt in trail.points) {
          final nid = nextNodeId--;
          wayNodeIds.add(nid);
          buf.writeln(
            '    <node id="$nid" changeset="$changesetId" '
            'lat="${pt.latitude.toStringAsFixed(7)}" '
            'lon="${pt.longitude.toStringAsFixed(7)}"/>',
          );
        }
        final wid = nextWayId--;
        final wayTags = prepareTagsForPublish(trail.tags, hasGpsFix: true);
        if (trail.name.trim().isNotEmpty && !wayTags.containsKey('name')) {
          wayTags['name'] = trail.name.trim();
        }
        wayTags.putIfAbsent(
          'source',
          () => OsmTagStandards.recommendedSource(hasGpsFix: true),
        );

        buf.writeln('    <way id="$wid" changeset="$changesetId">');
        for (final nid in wayNodeIds) {
          buf.writeln('      <nd ref="$nid"/>');
        }
        for (final entry in wayTags.entries) {
          buf.writeln(
            '      <tag k="${_xmlEscape(entry.key)}" v="${_xmlEscape(entry.value)}"/>',
          );
        }
        buf.writeln('    </way>');
      }

      buf.writeln('  </create>');
    }

    if (tagUpdates.isNotEmpty) {
      buf.writeln('  <modify>');
      for (final upd in tagUpdates) {
        // Start from existing upstream OSM tags, remove any keys explicitly
        // marked for upstream deletion, and apply modernized added/updated tags.
        final hasGps = upd.latitude != null &&
            upd.longitude != null &&
            OsmTagStandards.hasValidGps(upd.latitude!, upd.longitude!);
        final cleanNew = prepareTagsForPublish(
          upd.selectedNewTags,
          hasGpsFix: hasGps,
        );
        final baseExisting = Map<String, String>.from(upd.existingTags);
        for (final removedKey in upd.removedTagKeys) {
          baseExisting.remove(removedKey);
        }
        final merged = sanitizeOsmTags({
          ...baseExisting,
          ...cleanNew,
        });
        final ver = upd.version ?? 1;
        if (upd.elementType == 'node') {
          buf.writeln(
            '    <node id="${upd.elementId}" version="$ver" changeset="$changesetId" '
            'lat="${(upd.latitude ?? 0).toStringAsFixed(7)}" '
            'lon="${(upd.longitude ?? 0).toStringAsFixed(7)}">',
          );
          for (final entry in merged.entries) {
            buf.writeln(
              '      <tag k="${_xmlEscape(entry.key)}" v="${_xmlEscape(entry.value)}"/>',
            );
          }
          buf.writeln('    </node>');
        } else if (upd.elementType == 'way') {
          buf.writeln(
            '    <way id="${upd.elementId}" version="$ver" changeset="$changesetId">',
          );
          for (final nid in upd.nodeIds) {
            buf.writeln('      <nd ref="$nid"/>');
          }
          for (final entry in merged.entries) {
            buf.writeln(
              '      <tag k="${_xmlEscape(entry.key)}" v="${_xmlEscape(entry.value)}"/>',
            );
          }
          buf.writeln('    </way>');
        }
      }
      buf.writeln('  </modify>');
    }

    buf.writeln('</osmChange>');
    return buf.toString();
  }

  /// Produces a Git-style line-by-line XML diff for `<osmChange>` review:
  /// - Newly created nodes/ways and newly added `<tag>` lines are [XmlDiffLineKind.added] (green).
  /// - Replaced old `<tag>` values and explicitly removed upstream `<tag>` lines are [XmlDiffLineKind.removed] (red).
  /// - Unchanged surrounding tags and XML wrapper lines are [XmlDiffLineKind.context].
  static List<XmlDiffLine> buildOsmChangeDiffLines({
    required int changesetId,
    List<OsmRecord> records = const [],
    List<HikeTrail> trails = const [],
    List<OsmElementTagUpdate> tagUpdates = const [],
  }) {
    final lines = <XmlDiffLine>[
      XmlDiffLine(
        kind: XmlDiffLineKind.context,
        text:
            '<osmChange version="0.6" generator="${_xmlEscape(AppEnvConfig.osmGenerator)}">',
      ),
    ];

    if (records.isNotEmpty || trails.isNotEmpty) {
      lines.add(const XmlDiffLine(kind: XmlDiffLineKind.added, text: '  <create>'));
      var nextNodeId = -1;
      var nextWayId = -1;

      for (final record in records) {
        final nid = nextNodeId--;
        final hasGps = OsmTagStandards.hasValidGps(
          record.effectiveLatitude,
          record.effectiveLongitude,
        );
        final tags = prepareTagsForPublish(record.tags, hasGpsFix: hasGps);
        tags.putIfAbsent(
          'source',
          () => OsmTagStandards.recommendedSource(hasGpsFix: hasGps),
        );
        lines.add(
          XmlDiffLine(
            kind: XmlDiffLineKind.added,
            text: '    <node id="$nid" changeset="$changesetId" '
                'lat="${record.effectiveLatitude.toStringAsFixed(7)}" '
                'lon="${record.effectiveLongitude.toStringAsFixed(7)}">',
          ),
        );
        for (final entry in tags.entries) {
          lines.add(
            XmlDiffLine(
              kind: XmlDiffLineKind.added,
              text:
                  '      <tag k="${_xmlEscape(entry.key)}" v="${_xmlEscape(entry.value)}"/>',
            ),
          );
        }
        lines.add(
          const XmlDiffLine(kind: XmlDiffLineKind.added, text: '    </node>'),
        );
      }

      for (final trail in trails) {
        if (trail.points.length < 2) continue;
        final wayNodeIds = <int>[];
        for (final pt in trail.points) {
          final nid = nextNodeId--;
          wayNodeIds.add(nid);
          lines.add(
            XmlDiffLine(
              kind: XmlDiffLineKind.added,
              text: '    <node id="$nid" changeset="$changesetId" '
                  'lat="${pt.latitude.toStringAsFixed(7)}" '
                  'lon="${pt.longitude.toStringAsFixed(7)}"/>',
            ),
          );
        }
        final wid = nextWayId--;
        final wayTags = prepareTagsForPublish(trail.tags, hasGpsFix: true);
        if (trail.name.trim().isNotEmpty && !wayTags.containsKey('name')) {
          wayTags['name'] = trail.name.trim();
        }
        wayTags.putIfAbsent(
          'source',
          () => OsmTagStandards.recommendedSource(hasGpsFix: true),
        );
        lines.add(
          XmlDiffLine(
            kind: XmlDiffLineKind.added,
            text: '    <way id="$wid" changeset="$changesetId">',
          ),
        );
        for (final nid in wayNodeIds) {
          lines.add(
            XmlDiffLine(
              kind: XmlDiffLineKind.added,
              text: '      <nd ref="$nid"/>',
            ),
          );
        }
        for (final entry in wayTags.entries) {
          lines.add(
            XmlDiffLine(
              kind: XmlDiffLineKind.added,
              text:
                  '      <tag k="${_xmlEscape(entry.key)}" v="${_xmlEscape(entry.value)}"/>',
            ),
          );
        }
        lines.add(
          const XmlDiffLine(kind: XmlDiffLineKind.added, text: '    </way>'),
        );
      }

      lines.add(
        const XmlDiffLine(kind: XmlDiffLineKind.added, text: '  </create>'),
      );
    }

    if (tagUpdates.isNotEmpty) {
      lines.add(
        const XmlDiffLine(kind: XmlDiffLineKind.context, text: '  <modify>'),
      );
      for (final upd in tagUpdates) {
        final hasGps = upd.latitude != null &&
            upd.longitude != null &&
            OsmTagStandards.hasValidGps(upd.latitude!, upd.longitude!);
        final cleanNew = prepareTagsForPublish(
          upd.selectedNewTags,
          hasGpsFix: hasGps,
        );
        final beforeTags = sanitizeOsmTags(upd.existingTags);
        final baseExisting = Map<String, String>.from(beforeTags);
        for (final removedKey in upd.removedTagKeys) {
          baseExisting.remove(removedKey);
        }
        final afterTags = sanitizeOsmTags({
          ...baseExisting,
          ...cleanNew,
        });

        final ver = upd.version ?? 1;
        if (upd.elementType == 'node') {
          lines.add(
            XmlDiffLine(
              kind: XmlDiffLineKind.context,
              text:
                  '    <node id="${upd.elementId}" version="$ver" changeset="$changesetId" '
                  'lat="${(upd.latitude ?? 0).toStringAsFixed(7)}" '
                  'lon="${(upd.longitude ?? 0).toStringAsFixed(7)}">',
            ),
          );
        } else {
          lines.add(
            XmlDiffLine(
              kind: XmlDiffLineKind.context,
              text:
                  '    <way id="${upd.elementId}" version="$ver" changeset="$changesetId">',
            ),
          );
          if (upd.nodeIds.isNotEmpty) {
            final shownNodes = upd.nodeIds.take(4).toList();
            for (final nid in shownNodes) {
              lines.add(
                XmlDiffLine(
                  kind: XmlDiffLineKind.context,
                  text: '      <nd ref="$nid"/>',
                ),
              );
            }
            if (upd.nodeIds.length > shownNodes.length) {
              lines.add(
                XmlDiffLine(
                  kind: XmlDiffLineKind.context,
                  text:
                      '      <!-- ... ${upd.nodeIds.length - shownNodes.length} more geometry node(s) unchanged -->',
                ),
              );
            }
          }
        }

        // Preserve stable key ordering: existing keys first (unchanged / modified / removed), then newly added keys
        final seenKeys = <String>{};
        for (final entry in beforeTags.entries) {
          seenKeys.add(entry.key);
          final afterVal = afterTags[entry.key];
          if (afterVal == null) {
            lines.add(
              XmlDiffLine(
                kind: XmlDiffLineKind.removed,
                text:
                    '      <tag k="${_xmlEscape(entry.key)}" v="${_xmlEscape(entry.value)}"/>',
              ),
            );
          } else if (afterVal != entry.value) {
            lines.add(
              XmlDiffLine(
                kind: XmlDiffLineKind.removed,
                text:
                    '      <tag k="${_xmlEscape(entry.key)}" v="${_xmlEscape(entry.value)}"/>',
              ),
            );
            lines.add(
              XmlDiffLine(
                kind: XmlDiffLineKind.added,
                text:
                    '      <tag k="${_xmlEscape(entry.key)}" v="${_xmlEscape(afterVal)}"/>',
              ),
            );
          } else {
            lines.add(
              XmlDiffLine(
                kind: XmlDiffLineKind.context,
                text:
                    '      <tag k="${_xmlEscape(entry.key)}" v="${_xmlEscape(entry.value)}"/>',
              ),
            );
          }
        }
        for (final entry in afterTags.entries) {
          if (seenKeys.contains(entry.key)) continue;
          lines.add(
            XmlDiffLine(
              kind: XmlDiffLineKind.added,
              text:
                  '      <tag k="${_xmlEscape(entry.key)}" v="${_xmlEscape(entry.value)}"/>',
            ),
          );
        }

        lines.add(
          XmlDiffLine(
            kind: XmlDiffLineKind.context,
            text: upd.elementType == 'node' ? '    </node>' : '    </way>',
          ),
        );
      }
      lines.add(
        const XmlDiffLine(kind: XmlDiffLineKind.context, text: '  </modify>'),
      );
    }

    lines.add(
      const XmlDiffLine(kind: XmlDiffLineKind.context, text: '</osmChange>'),
    );
    return lines;
  }

  /// Parses OSM's `<diffResult>` response XML to extract assigned permanent IDs
  /// for both created (negative `old_id`) and modified (positive `old_id`) elements.
  static OsmDiffResult parseDiffResult(String xml) {
    final createdNodes = <int, int>{};
    final createdWays = <int, int>{};
    final updatedNodes = <int>[];
    final updatedWays = <int>[];

    final nodeRegex = RegExp(
      r'<node\b[^>]*old_id="(-?\d+)"[^>]*new_id="(\d+)"',
    );
    for (final match in nodeRegex.allMatches(xml)) {
      final oldId = int.tryParse(match.group(1) ?? '');
      final newId = int.tryParse(match.group(2) ?? '');
      if (oldId != null && newId != null) {
        if (oldId < 0) {
          createdNodes[oldId] = newId;
        } else {
          updatedNodes.add(newId);
        }
      }
    }

    final wayRegex = RegExp(
      r'<way\b[^>]*old_id="(-?\d+)"[^>]*new_id="(\d+)"',
    );
    for (final match in wayRegex.allMatches(xml)) {
      final oldId = int.tryParse(match.group(1) ?? '');
      final newId = int.tryParse(match.group(2) ?? '');
      if (oldId != null && newId != null) {
        if (oldId < 0) {
          createdWays[oldId] = newId;
        } else {
          updatedWays.add(newId);
        }
      }
    }

    return OsmDiffResult(
      createdNodeIds: createdNodes,
      createdWayIds: createdWays,
      updatedNodeIds: updatedNodes,
      updatedWayIds: updatedWays,
    );
  }

  /// Fetches the authoritative live OSM object (`version`, coords/`nodes`, `tags`)
  /// before modifying it so we never hit a version conflict or overwrite other mappers' tags.
  Future<OsmElementTagUpdate> _hydrateTagUpdateFromLiveOsm(
    OsmElementTagUpdate upd,
  ) async {
    final safeType = upd.elementType.trim().toLowerCase();
    if (safeType != 'node' && safeType != 'way' && safeType != 'relation') {
      throw ArgumentError.value(
        upd.elementType,
        'elementType',
        'Unsupported OSM element type.',
      );
    }
    final resp = await _client
        .get(
          Uri.parse('$apiBaseUrl/api/0.6/$safeType/${upd.elementId}.json'),
          headers: {
            'Accept': 'application/json',
            if (!kIsWeb) 'User-Agent': AppEnvConfig.httpUserAgent(component: 'OSM-API'),
          },
        )
        .timeout(const Duration(seconds: 15));

    if (resp.statusCode != 200) {
      throw Exception(
        'Could not fetch latest ${upd.elementType}/${upd.elementId} from OSM (${resp.statusCode}).',
      );
    }

    final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final decoded = jsonDecode(bodyText) as Map<String, dynamic>;
    final elements = decoded['elements'] as List? ?? const [];
    if (elements.isEmpty || elements.first is! Map) {
      throw Exception(
        'OSM returned no data for ${upd.elementType}/${upd.elementId}.',
      );
    }
    final elem = elements.first as Map;
    final liveVersion = (elem['version'] as num?)?.toInt();
    final liveLat = (elem['lat'] as num?)?.toDouble();
    final liveLon = (elem['lon'] as num?)?.toDouble();
    final liveNodes = (elem['nodes'] as List? ?? const [])
        .map((n) => (n as num?)?.toInt())
        .whereType<int>()
        .toList();
    final liveTags = <String, String>{};
    final rawTags = elem['tags'];
    if (rawTags is Map) {
      rawTags.forEach((k, v) {
        final ks = k.toString().trim();
        final vs = v?.toString().trim() ?? '';
        if (ks.isNotEmpty && vs.isNotEmpty) liveTags[ks] = vs;
      });
    }

    return upd.copyWith(
      version: liveVersion ?? upd.version,
      latitude: liveLat ?? upd.latitude,
      longitude: liveLon ?? upd.longitude,
      nodeIds: liveNodes.isNotEmpty ? liveNodes : upd.nodeIds,
      existingTags: liveTags.isNotEmpty ? liveTags : upd.existingTags,
    );
  }

  /// Publishes new [records]/[trails] and/or selective [tagUpdates] to existing
  /// OSM elements in a single atomic changeset: Create -> Upload -> Close.
  Future<OsmPublishResult> publishChangeset({
    List<OsmRecord> records = const [],
    List<HikeTrail> trails = const [],
    List<OsmElementTagUpdate> tagUpdates = const [],
    required String changesetComment,
    void Function(String step)? onProgress,
  }) async {
    final token = prefs.osmAccessToken.trim();
    if (token.isEmpty) {
      throw StateError('Sign in to OpenStreetMap before publishing.');
    }

    final blocking = validateForPublish(
      records: records,
      trails: trails,
      tagUpdates: tagUpdates,
    ).where((i) => i.isBlocking).toList();
    if (blocking.isNotEmpty) {
      throw StateError('${blocking.first.title}: ${blocking.first.detail}');
    }

    // Hydrate existing OSM elements so version, geometry, and live tags are 100% current
    final hydratedUpdates = <OsmElementTagUpdate>[];
    if (tagUpdates.isNotEmpty) {
      onProgress?.call('Fetching latest version of existing OSM POI(s)...');
      for (final upd in tagUpdates) {
        final needsFetch = upd.version == null ||
            (upd.elementType == 'way' && upd.nodeIds.isEmpty) ||
            (upd.elementType == 'node' &&
                (upd.latitude == null || upd.longitude == null));
        if (needsFetch) {
          hydratedUpdates.add(await _hydrateTagUpdateFromLiveOsm(upd));
        } else {
          hydratedUpdates.add(upd);
        }
      }
    }

    final xmlHeaders = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/xml; charset=utf-8',
      if (!kIsWeb) 'User-Agent': AppEnvConfig.httpUserAgent(component: 'OSM-API'),
    };

    final hasAnyGps = records.any(
          (r) => OsmTagStandards.hasValidGps(
            r.effectiveLatitude,
            r.effectiveLongitude,
          ),
        ) ||
        trails.any((t) => t.points.isNotEmpty) ||
        hydratedUpdates.any(
          (u) =>
              u.latitude != null &&
              u.longitude != null &&
              OsmTagStandards.hasValidGps(u.latitude!, u.longitude!),
        );
    final changesetSource =
        OsmTagStandards.recommendedSource(hasGpsFix: hasAnyGps);

    onProgress?.call('Opening OSM changeset on $serverLabel...');
    final createResp = await _client
        .put(
          Uri.parse('$apiBaseUrl/api/0.6/changeset/create'),
          headers: xmlHeaders,
          body: buildChangesetXml(
            comment: changesetComment,
            source: changesetSource,
          ),
        )
        .timeout(const Duration(seconds: 25));

    if (createResp.statusCode != 200) {
      throw Exception(
        'Could not open OSM changeset (${createResp.statusCode}): ${_compactBody(createResp.body)}',
      );
    }

    final changesetId = int.tryParse(createResp.body.trim());
    if (changesetId == null || changesetId <= 0) {
      throw Exception(
        'Unexpected changeset ID from OSM: ${createResp.body.trim()}',
      );
    }

    try {
      onProgress?.call('Uploading changes to changeset #$changesetId...');
      final oscXml = buildOsmChangeXml(
        changesetId: changesetId,
        records: records,
        trails: trails,
        tagUpdates: hydratedUpdates,
      );
      final uploadResp = await _client
          .post(
            Uri.parse('$apiBaseUrl/api/0.6/changeset/$changesetId/upload'),
            headers: xmlHeaders,
            body: oscXml,
          )
          .timeout(const Duration(seconds: 40));

      if (uploadResp.statusCode != 200) {
        throw Exception(
          'OSM upload failed (${uploadResp.statusCode}): ${_compactBody(uploadResp.body)}',
        );
      }

      final diffResult = parseDiffResult(uploadResp.body);
      onProgress?.call('Closing changeset #$changesetId...');

      return OsmPublishResult(
        changesetId: changesetId,
        changesetUrl: '$webBaseUrl/changeset/$changesetId',
        createdNodeIds: diffResult.createdNodeIds.values.toList(),
        createdWayIds: diffResult.createdWayIds.values.toList(),
        updatedNodeIds: diffResult.updatedNodeIds,
        updatedWayIds: diffResult.updatedWayIds,
        isSandbox: isSandbox,
      );
    } finally {
      try {
        await _client
            .put(
              Uri.parse('$apiBaseUrl/api/0.6/changeset/$changesetId/close'),
              headers: {
                'Authorization': 'Bearer $token',
                if (!kIsWeb)
                  'User-Agent': AppEnvConfig.httpUserAgent(component: 'OSM-API'),
              },
            )
            .timeout(const Duration(seconds: 15));
      } catch (e) {
        debugPrint('[EdgeMapper] Changeset close warning: $e');
      }
    }
  }

  /// Uploads a recorded [trail] as an OpenStreetMap GPS Trace (`/api/0.6/gpx/create`).
  /// Recommended by OSM guidelines for raw GPS tracks!
  Future<OsmGpxUploadResult> uploadTrailGpxTrace({
    required HikeTrail trail,
    List<OsmRecord> linkedRecords = const [],
    required String description,
    String visibility = 'identifiable',
    void Function(String step)? onProgress,
  }) async {
    final token = prefs.osmAccessToken.trim();
    if (token.isEmpty) {
      throw StateError('Sign in to OpenStreetMap before uploading a GPX trace.');
    }
    if (trail.points.length < 2) {
      throw StateError('At least 2 GPS points are required to upload a GPX trace.');
    }

    onProgress?.call('Uploading GPX trace to $serverLabel...');
    final gpxXml = OsmExportService.buildGpx(
      records: linkedRecords,
      trails: [trail],
    );
    final safeName = trail.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final fileName = '${safeName.isEmpty ? 'edge_mapper_route' : safeName}.gpx';

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$apiBaseUrl/api/0.6/gpx/create'),
    );
    request.headers['Authorization'] = 'Bearer $token';
    if (!kIsWeb) {
      request.headers['User-Agent'] =
          AppEnvConfig.httpUserAgent(component: 'OSM-API');
    }
    request.fields['description'] =
        description.trim().isEmpty ? trail.name : description.trim();
    request.fields['tags'] =
        'edge-mapper, ${trail.activityType.shortLabel.toLowerCase()}';
    request.fields['visibility'] = visibility;
    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        utf8.encode(gpxXml),
        filename: fileName,
      ),
    );

    final streamed = await _client.send(request).timeout(const Duration(seconds: 40));
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode != 200) {
      throw Exception(
        'GPX trace upload failed (${resp.statusCode}): ${_compactBody(resp.body)}',
      );
    }

    final traceId = int.tryParse(resp.body.trim()) ?? 0;
    final userPath =
        prefs.osmUsername.isNotEmpty ? '/user/${Uri.encodeComponent(prefs.osmUsername)}' : '';
    return OsmGpxUploadResult(
      traceId: traceId,
      traceUrl: '$webBaseUrl$userPath/traces/$traceId',
      isSandbox: isSandbox,
    );
  }

  static String _compactBody(String body) {
    final cleaned = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned.length > 220 ? '${cleaned.substring(0, 217)}...' : cleaned;
  }

  static String _xmlEscape(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
