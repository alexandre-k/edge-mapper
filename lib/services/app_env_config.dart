import 'package:flutter/foundation.dart';

/// Centralized compile-time environment variable configuration (`--dart-define` /
/// `--dart-define-from-file=.env`) for Edge Mapper.
///
/// Every deploy-time or personal configuration value—Firebase project & keys,
/// OpenStreetMap OAuth client defaults, OSMF contact identity & offline tile
/// template, AI engine defaults, sync space, and Bitcoin developer donation
/// rails—is supplied via environment variables rather than hardcoded in source
/// control.
class AppEnvConfig {
  // --- App Identity & OSMF Policy Compliance ---
  /// Canonical semantic version (kept in sync with `pubspec.yaml`).
  static const String appVersion = '0.1.0';

  /// Human-readable generator tag for OSM XML, changeset `created_by`, and GPX.
  static const String osmGenerator = 'Edge Mapper $appVersion';

  /// Fallback project contact URL used in HTTP `User-Agent` headers when
  /// `APP_CONTACT_URL` is not supplied via `.env`. Set `APP_CONTACT_URL` to your
  /// public repository URL or contact email before public distribution so OSMF
  /// Tile & Nominatim operators can reach you.
  static const String defaultContactUrl =
      'https://github.com/edge-mapper/edge-mapper';

  /// Contact URL or email included in HTTP `User-Agent` headers sent to OSMF
  /// services (Tile servers, Nominatim, OSM API v0.6, Overpass, Taginfo).
  static const String appContactUrl =
      String.fromEnvironment('APP_CONTACT_URL');

  /// Optional custom `{z}/{x}/{y}` raster tile URL template used for bulk
  /// offline area pre-downloading (e.g. a self-hosted or commercial provider).
  /// Supports `{z}`, `{x}`, `{y}`, and optional `{s}` (`a`/`b`/`c`).
  static const String offlineTileUrlTemplate =
      String.fromEnvironment('OFFLINE_TILE_URL_TEMPLATE');

  /// Returns a valid contact string for HTTP `User-Agent` headers.
  /// Never returns `openstreetmap.org`, which violates OSMF Tile/Nominatim policy.
  static String get resolvedContactUrl {
    final trimmed = appContactUrl.trim();
    if (trimmed.isEmpty ||
        trimmed.toLowerCase().contains('openstreetmap.org')) {
      return defaultContactUrl;
    }
    return trimmed;
  }

  /// Concise platform identifier for `User-Agent` strings.
  static String get platformLabel {
    if (kIsWeb) return 'Web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iOS',
      TargetPlatform.linux => 'Linux',
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.fuchsia => 'Fuchsia',
    };
  }

  /// Builds an OSMF-policy-compliant HTTP `User-Agent` header:
  /// `EdgeMapper/0.1.0 (+<contact>; <platform>[; <component>])`.
  static String httpUserAgent({
    String? component,
    String? contactOverride,
    String? platform,
  }) {
    final rawContact = (contactOverride ?? '').trim();
    final contact = (rawContact.isNotEmpty &&
            !rawContact.toLowerCase().contains('openstreetmap.org'))
        ? rawContact
        : resolvedContactUrl;
    final parts = <String>['+$contact'];
    final cleanPlatform = (platform ?? platformLabel).trim();
    if (cleanPlatform.isNotEmpty) {
      parts.add(cleanPlatform);
    }
    final cleanComponent = (component ?? '').trim();
    if (cleanComponent.isNotEmpty) {
      parts.add(cleanComponent);
    }
    return 'EdgeMapper/$appVersion (${parts.join('; ')})';
  }

  // --- Firebase (Web & Android) ---
  static const String firebaseProjectId =
      String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const String firebaseMessagingSenderId =
      String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static const String firebaseAuthDomain =
      String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
  static const String firebaseStorageBucket =
      String.fromEnvironment('FIREBASE_STORAGE_BUCKET');
  static const String firebaseMeasurementId =
      String.fromEnvironment('FIREBASE_MEASUREMENT_ID');
  static const String firebaseWebApiKey =
      String.fromEnvironment('FIREBASE_WEB_API_KEY');
  static const String firebaseWebAppId =
      String.fromEnvironment('FIREBASE_WEB_APP_ID');
  static const String firebaseAndroidApiKey =
      String.fromEnvironment('FIREBASE_ANDROID_API_KEY');
  static const String firebaseAndroidAppId =
      String.fromEnvironment('FIREBASE_ANDROID_APP_ID');
  // --- Firebase App Check (AttestGate, Android) ---
  static const String attestGateBaseUrl =
      String.fromEnvironment('ATTEST_GATE_BASE_URL');
  static const String firebaseWebRecaptchaSiteKey =
      String.fromEnvironment('FIREBASE_WEB_RECAPTCHA_SITE_KEY');
  static const String firebaseWebAppCheckDebugToken =
      String.fromEnvironment('FIREBASE_WEB_APP_CHECK_DEBUG_TOKEN');

  // --- OpenStreetMap OAuth 2.0 Developer App Config ---
  static const String osmClientId = String.fromEnvironment('OSM_CLIENT_ID');
  static const String osmSandboxClientId =
      String.fromEnvironment('OSM_SANDBOX_CLIENT_ID');
  static const String osmRedirectUri =
      String.fromEnvironment('OSM_REDIRECT_URI');
  static const String osmUseSandboxRaw =
      String.fromEnvironment('OSM_USE_SANDBOX');
  static const String osmChangesetComment =
      String.fromEnvironment('OSM_CHANGESET_COMMENT');

  /// Returns the developer-configured OAuth 2.0 Client ID for the target OSM server.
  static String osmClientIdForServer({required bool isSandbox}) =>
      (isSandbox ? osmSandboxClientId : osmClientId).trim();

  // --- AI Engine Defaults ---
  static const String geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');
  static const String geminiModel = String.fromEnvironment('GEMINI_MODEL');
  static const String customAiBaseUrl =
      String.fromEnvironment('CUSTOM_AI_BASE_URL');
  static const String customAiApiKey =
      String.fromEnvironment('CUSTOM_AI_API_KEY');
  static const String customAiModel =
      String.fromEnvironment('CUSTOM_AI_MODEL');

  // --- Cloud Sync & Explorer Defaults ---
  static const String firebaseSyncSpaceId =
      String.fromEnvironment('FIREBASE_SYNC_SPACE_ID');
  static const String explorerHandle =
      String.fromEnvironment('EXPLORER_HANDLE');

  // --- Bitcoin Developer Donations ---
  static const String btcDonationUri =
      String.fromEnvironment('BTC_DONATION_URI');
  static const String btcDonationP2trAddress =
      String.fromEnvironment('BTC_DONATION_P2TR_ADDRESS');
  static const String btcDonationFallbackAddress =
      String.fromEnvironment('BTC_DONATION_ADDRESS');
  static const String btcDonationLightningAddress =
      String.fromEnvironment('BTC_DONATION_LIGHTNING_ADDRESS');
  static const String btcDonationSilentPaymentAddress =
      String.fromEnvironment('BTC_DONATION_SILENT_PAYMENT_ADDRESS');
  static const String btcDonationBolt12Offer =
      String.fromEnvironment('BTC_DONATION_BOLT12_OFFER');
  static const String btcDonationBtcPayUrl =
      String.fromEnvironment('BTC_DONATION_BTCPAY_URL');

  static bool get osmUseSandbox =>
      osmUseSandboxRaw.trim().toLowerCase() == 'true' ||
      osmUseSandboxRaw.trim() == '1';

  static bool get hasFirebaseWebConfig =>
      firebaseProjectId.trim().isNotEmpty &&
      firebaseWebApiKey.trim().isNotEmpty &&
      firebaseWebAppId.trim().isNotEmpty;

  static bool get hasFirebaseAndroidConfig =>
      firebaseProjectId.trim().isNotEmpty &&
      firebaseAndroidApiKey.trim().isNotEmpty &&
      firebaseAndroidAppId.trim().isNotEmpty;

  static bool get hasAttestGateBaseUrl =>
      attestGateBaseUrl.trim().isNotEmpty;

  /// Complete list of supported environment variable names (useful for docs & diagnostics).
  static const List<String> allEnvVarNames = [
    'APP_CONTACT_URL',
    'OFFLINE_TILE_URL_TEMPLATE',
    'FIREBASE_PROJECT_ID',
    'FIREBASE_MESSAGING_SENDER_ID',
    'FIREBASE_AUTH_DOMAIN',
    'FIREBASE_STORAGE_BUCKET',
    'FIREBASE_MEASUREMENT_ID',
    'FIREBASE_WEB_API_KEY',
    'FIREBASE_WEB_APP_ID',
    'FIREBASE_ANDROID_API_KEY',
    'FIREBASE_ANDROID_APP_ID',
    'ATTEST_GATE_BASE_URL',
    'OSM_CLIENT_ID',
    'OSM_SANDBOX_CLIENT_ID',
    'OSM_REDIRECT_URI',
    'OSM_USE_SANDBOX',
    'OSM_CHANGESET_COMMENT',
    'GEMINI_API_KEY',
    'GEMINI_MODEL',
    'CUSTOM_AI_BASE_URL',
    'CUSTOM_AI_API_KEY',
    'CUSTOM_AI_MODEL',
    'FIREBASE_SYNC_SPACE_ID',
    'EXPLORER_HANDLE',
    'BTC_DONATION_URI',
    'BTC_DONATION_P2TR_ADDRESS',
    'BTC_DONATION_LIGHTNING_ADDRESS',
    'BTC_DONATION_SILENT_PAYMENT_ADDRESS',
    'BTC_DONATION_BOLT12_OFFER',
    'BTC_DONATION_BTCPAY_URL',
  ];

  /// Sanitizes a single `.env` value so newlines cannot break key=value lines.
  static String _cleanEnvValue(String raw) =>
      raw.replaceAll('\r', '').replaceAll('\n', '').trim();

  /// Redacts query parameters (which often carry API keys like `?key=...`)
  /// from URL templates when exporting non-secret `.env` snapshots.
  static String _redactUrlQuery(String raw) {
    final clean = _cleanEnvValue(raw);
    if (clean.isEmpty) return '';
    final qIdx = clean.indexOf('?');
    return qIdx >= 0 ? clean.substring(0, qIdx) : clean;
  }

  /// Optional public share domain for `#k=` zero-knowledge links (e.g. `share.example.org`).
  static const String shareDomain = String.fromEnvironment(
    'APP_SHARE_DOMAIN',
    defaultValue: 'edgemapper.app',
  );

  /// Generates a `.env` file snapshot of the app's exportable configuration.
  ///
  /// When [includeSecrets] is `false` (the default), sensitive API keys and
  /// sync passphrases are left blank so the exported file is safe to share or
  /// store alongside non-secret deployment config.
  static String buildDotEnvExport({
    String? firebaseProject,
    String? firebaseWebKey,
    String? attestGateUrl,
    String? osmClient,
    String? osmRedirect,
    bool? osmSandbox,
    String? osmComment,
    String? selectedGeminiModel,
    String? personalGeminiKey,
    String? customBaseUrl,
    String? customKey,
    String? customModel,
    String? syncSpace,
    String? handle,
    bool includeSecrets = false,
  }) {
    final buf = StringBuffer()
      ..writeln('# Edge Mapper — Exported Environment Configuration (.env)')
      ..writeln('# Use with: flutter run --dart-define-from-file=.env')
      ..writeln('#           flutter build apk --release --dart-define-from-file=.env')
      ..writeln('#           flutter build web --release --dart-define-from-file=.env')
      ..writeln('')
      ..writeln('# App Identity & OSMF Policy Compliance')
      ..writeln('APP_CONTACT_URL=${_cleanEnvValue(appContactUrl)}')
      ..writeln(
        'OFFLINE_TILE_URL_TEMPLATE=${includeSecrets ? _cleanEnvValue(offlineTileUrlTemplate) : _redactUrlQuery(offlineTileUrlTemplate)}',
      )
      ..writeln('')
      ..writeln('# Firebase')
      ..writeln(
        'FIREBASE_PROJECT_ID=${_cleanEnvValue((firebaseProject != null && firebaseProject.trim().isNotEmpty) ? firebaseProject : firebaseProjectId)}',
      )
      ..writeln(
        'FIREBASE_MESSAGING_SENDER_ID=${_cleanEnvValue(firebaseMessagingSenderId)}',
      )
      ..writeln('FIREBASE_AUTH_DOMAIN=${_cleanEnvValue(firebaseAuthDomain)}')
      ..writeln(
        'FIREBASE_STORAGE_BUCKET=${_cleanEnvValue(firebaseStorageBucket)}',
      )
      ..writeln(
        'FIREBASE_MEASUREMENT_ID=${_cleanEnvValue(firebaseMeasurementId)}',
      )
      ..writeln(
        'FIREBASE_WEB_API_KEY=${includeSecrets ? _cleanEnvValue((firebaseWebKey != null && firebaseWebKey.trim().isNotEmpty) ? firebaseWebKey : firebaseWebApiKey) : ''}',
      )
      ..writeln('FIREBASE_WEB_APP_ID=${_cleanEnvValue(firebaseWebAppId)}')
      ..writeln(
        'FIREBASE_ANDROID_API_KEY=${includeSecrets ? _cleanEnvValue(firebaseAndroidApiKey) : ''}',
      )
      ..writeln(
        'FIREBASE_ANDROID_APP_ID=${_cleanEnvValue(firebaseAndroidAppId)}',
      )
      ..writeln(
        'ATTEST_GATE_BASE_URL=${_cleanEnvValue((attestGateUrl != null && attestGateUrl.trim().isNotEmpty) ? attestGateUrl : attestGateBaseUrl)}',
      )
      ..writeln('')
      ..writeln('# OpenStreetMap OAuth 2.0 (Developer App Config)')
      ..writeln(
        'OSM_CLIENT_ID=${_cleanEnvValue((osmClient != null && osmClient.trim().isNotEmpty) ? osmClient : osmClientId)}',
      )
      ..writeln(
        'OSM_SANDBOX_CLIENT_ID=${_cleanEnvValue(osmSandboxClientId)}',
      )
      ..writeln(
        'OSM_REDIRECT_URI=${_cleanEnvValue((osmRedirect != null && osmRedirect.trim().isNotEmpty) ? osmRedirect : osmRedirectUri)}',
      )
      ..writeln('OSM_USE_SANDBOX=${(osmSandbox ?? osmUseSandbox) ? 'true' : 'false'}')
      ..writeln(
        'OSM_CHANGESET_COMMENT=${_cleanEnvValue((osmComment != null && osmComment.trim().isNotEmpty) ? osmComment : osmChangesetComment)}',
      )
      ..writeln('')
      ..writeln('# AI Engine')
      ..writeln(
        'GEMINI_API_KEY=${includeSecrets ? _cleanEnvValue((personalGeminiKey != null && personalGeminiKey.trim().isNotEmpty) ? personalGeminiKey : geminiApiKey) : ''}',
      )
      ..writeln(
        'GEMINI_MODEL=${_cleanEnvValue((selectedGeminiModel != null && selectedGeminiModel.trim().isNotEmpty) ? selectedGeminiModel : geminiModel)}',
      )
      ..writeln(
        'CUSTOM_AI_BASE_URL=${_cleanEnvValue((customBaseUrl != null && customBaseUrl.trim().isNotEmpty) ? customBaseUrl : customAiBaseUrl)}',
      )
      ..writeln(
        'CUSTOM_AI_API_KEY=${includeSecrets ? _cleanEnvValue((customKey != null && customKey.trim().isNotEmpty) ? customKey : customAiApiKey) : ''}',
      )
      ..writeln(
        'CUSTOM_AI_MODEL=${_cleanEnvValue((customModel != null && customModel.trim().isNotEmpty) ? customModel : customAiModel)}',
      )
      ..writeln('')
      ..writeln('# Cloud Sync & Explorer')
      ..writeln(
        'FIREBASE_SYNC_SPACE_ID=${includeSecrets ? _cleanEnvValue((syncSpace != null && syncSpace.trim().isNotEmpty) ? syncSpace : firebaseSyncSpaceId) : ''}',
      )
      ..writeln(
        'EXPLORER_HANDLE=${_cleanEnvValue((handle != null && handle.trim().isNotEmpty) ? handle : explorerHandle)}',
      )
      ..writeln('')
      ..writeln('# Bitcoin Developer Donations')
      ..writeln('BTC_DONATION_URI=${_cleanEnvValue(btcDonationUri)}')
      ..writeln(
        'BTC_DONATION_P2TR_ADDRESS=${_cleanEnvValue(btcDonationP2trAddress)}',
      )
      ..writeln(
        'BTC_DONATION_LIGHTNING_ADDRESS=${_cleanEnvValue(btcDonationLightningAddress)}',
      )
      ..writeln(
        'BTC_DONATION_SILENT_PAYMENT_ADDRESS=${_cleanEnvValue(btcDonationSilentPaymentAddress)}',
      )
      ..writeln(
        'BTC_DONATION_BOLT12_OFFER=${_cleanEnvValue(btcDonationBolt12Offer)}',
      )
      ..writeln(
        'BTC_DONATION_BTCPAY_URL=${_cleanEnvValue(btcDonationBtcPayUrl)}',
      );
    return buf.toString();
  }
}
