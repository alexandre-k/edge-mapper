import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:firebase_ai/firebase_ai.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../attest_gate_provider.dart';
import '../data/osm_tag_standards.dart';
import '../models/enrichment_diff.dart';
import '../models/osm_record.dart';
import 'connectivity_service.dart';
import 'firebase_bootstrap.dart';
import 'location_context_service.dart';
import 'on_device_vision.dart';
import 'osm_heuristic_mapper.dart';
import 'osm_tag_verifier_service.dart';
import 'photo_helper.dart';
import 'user_preferences_service.dart';

class GeminiNanoStatus {
  final bool available;
  final bool aicoreInstalled;
  final String deviceModel;
  final int sdkInt;
  final String reason;

  const GeminiNanoStatus({
    required this.available,
    required this.aicoreInstalled,
    required this.deviceModel,
    required this.sdkInt,
    required this.reason,
  });

  static const unknown = GeminiNanoStatus(
    available: false,
    aicoreInstalled: false,
    deviceModel: 'Android Device',
    sdkInt: 0,
    reason: 'Checking on-device AI capabilities...',
  );
}

class AiBatchCancelledException implements Exception {
  const AiBatchCancelledException();

  @override
  String toString() => 'AI enrichment cancelled by user.';
}

/// Multi-provider Hybrid AI service:
/// 1. Online Cloud AI (selectable provider & model):
///    - Firebase AI Logic (`gemini-3.8-flash`, `gemini-3.8-flash-lite`, `gemini-2.5-flash`, etc.)
///    - User's Personal Gemini API Key (Google Generative Language REST API + model discovery)
///    - Custom OpenAI-Compatible Vision API endpoint
/// 2. Offline on AICore-capable phone (Pixel 8/9+) -> Native Gemini Nano channel
/// 3. Offline on Pixel 6a (or fallback) -> On-Device ML Kit Vision + Multilingual OCR + visual distance scale
class HybridAiService extends ChangeNotifier {
  static const Duration _cloudRequestTimeout = Duration(seconds: 30);
  static const Duration _highDemandCooldown = Duration(minutes: 5);
  static const Duration _quotaExceededCooldown = Duration(hours: 6);

  final ConnectivityService connectivity;
  final UserPreferencesService prefs;
  final http.Client _httpClient;
  final OsmTagVerifierService _tagVerifier;

  GeminiNanoStatus _nanoStatus = GeminiNanoStatus.unknown;
  bool _enableJapaneseOcr = true;
  bool _enableChineseOcr = false;
  bool _enableKoreanOcr = false;
  String? _lastCloudError;
  String? _lastNanoError;
  String? _lastUsedModel;
  bool _hasDiscoveredPersonalModels = false;
  final Map<String, DateTime> _modelCooldownUntil = {};

  HybridAiService({
    required this.connectivity,
    required this.prefs,
    GeminiNanoStatus? initialNanoStatus,
    http.Client? httpClient,
    OsmTagVerifierService? tagVerifier,
  })  : _nanoStatus = initialNanoStatus ?? GeminiNanoStatus.unknown,
        _httpClient = httpClient ?? http.Client(),
        _tagVerifier =
            tagVerifier ?? OsmTagVerifierService(client: httpClient) {
    prefs.addListener(notifyListeners);
    connectivity.addListener(notifyListeners);
  }

  GeminiNanoStatus get nanoStatus => _nanoStatus;
  bool get enableJapaneseOcr => _enableJapaneseOcr;
  bool get enableChineseOcr => _enableChineseOcr;
  bool get enableKoreanOcr => _enableKoreanOcr;
  String? get lastCloudError => _lastCloudError;
  String? get lastNanoError => _lastNanoError;
  String? get lastUsedModel => _lastUsedModel;

  void clearLastCloudError() {
    if (_lastCloudError == null) return;
    _lastCloudError = null;
    notifyListeners();
  }

  /// Resets cached cloud errors, model cooldowns, and personal model discovery
  /// state (e.g. after saving a new Personal Gemini API key or changing provider).
  void resetCloudDiagnostics() {
    _lastCloudError = null;
    _modelCooldownUntil.clear();
    _hasDiscoveredPersonalModels = false;
    notifyListeners();
  }

  void clearLastNanoError() {
    if (_lastNanoError == null) return;
    _lastNanoError = null;
    notifyListeners();
  }

  /// Returns true when the model hit its free-tier / daily / per-minute quota.
  /// On quota errors we should NEVER retry the same model or JSON-only mode —
  /// instead immediately switch settings to a less-demanding model.
  static bool isQuotaExceededError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('quota exceeded') ||
        msg.contains('exceeded your current quota') ||
        msg.contains('free_tier_requests') ||
        msg.contains('requests per day') ||
        msg.contains('rate-limit') ||
        msg.contains('rate_limit') ||
        msg.contains('rate limit') ||
        msg.contains('resource_exhausted') ||
        msg.contains('too many requests') ||
        msg.contains('server error [429]') ||
        msg.contains('[429]') ||
        msg.contains('error (429)') ||
        msg.contains('"code": 429');
  }

  /// Returns true when an error represents a temporary server spike, overload,
  /// quota/rate limit, or network hiccup that should NOT trigger a duplicate
  /// JSON-only retry on the same model.
  static bool isTransientCloudError(Object error) {
    if (error is TimeoutException || error is http.ClientException) {
      return true;
    }
    if (isQuotaExceededError(error)) {
      return true;
    }
    final msg = error.toString().toLowerCase();
    return msg.contains('high demand') ||
        msg.contains('socketexception') ||
        msg.contains('overloaded') ||
        msg.contains('try again later') ||
        msg.contains('temporarily') ||
        msg.contains('service unavailable') ||
        msg.contains('status": "internal"') ||
        msg.contains('status": "unavailable"') ||
        msg.contains('server error [500]') ||
        msg.contains('server error [502]') ||
        msg.contains('server error [503]') ||
        msg.contains('server error [504]') ||
        msg.contains('error (500)') ||
        msg.contains('error (502)') ||
        msg.contains('error (503)') ||
        msg.contains('error (504)') ||
        msg.contains('"code": 500') ||
        msg.contains('"code": 502') ||
        msg.contains('"code": 503') ||
        msg.contains('"code": 504') ||
        msg.contains('timed out') ||
        msg.contains('connection closed') ||
        msg.contains('connection reset');
  }

  /// Returns true when Firebase App Check token minting or verification failed
  /// (e.g. HTTP 401 "Firebase App Check token is invalid.", missing provider, or
  /// an attest-gate hardware attestation error). Switching models will not fix
  /// this; callers should force-refresh the App Check token once and surface
  /// the underlying diagnostic if it still fails.
  static bool isAppCheckTokenError(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('app check token') ||
        msg.contains('firebase_app_check') ||
        msg.contains('no appcheckprovider installed') ||
        msg.contains('attest-gate') ||
        msg.contains('attestgate') ||
        msg.contains('attestation_failed') ||
        msg.contains('provider_not_installed') ||
        msg.contains('hardware attestation failed');
  }

  /// Returns true when a model ID is retired, invalid, requires App Check
  /// enforcement not enabled on this project, or is unsupported on this endpoint.
  static bool isModelUnavailableError(Object error) {
    if (isAppCheckTokenError(error)) {
      return false;
    }
    final msg = error.toString().toLowerCase();
    return msg.contains('enforce firebase app check') ||
        msg.contains('ai-logic/app-check') ||
        msg.contains('no longer available') ||
        msg.contains('is not found') ||
        msg.contains('model not found') ||
        msg.contains('not supported for generatecontent') ||
        msg.contains('deprecated') ||
        msg.contains('error (404)') ||
        msg.contains('[404]') ||
        msg.contains('"code": 404');
  }

  /// Returns true for auth/project-setup errors where retrying other models on the
  /// same backend will not help.
  static bool isAuthOrConfigError(Object error) {
    if (isAppCheckTokenError(error)) {
      return true;
    }
    final msg = error.toString().toLowerCase();
    return msg.contains('genai config not found') ||
        msg.contains('api has not been used') ||
        msg.contains('permission_denied') ||
        msg.contains('unauthenticated') ||
        msg.contains('api key not valid') ||
        msg.contains('api_key_invalid') ||
        msg.contains('invalid api key') ||
        msg.contains('[401]') ||
        msg.contains('[403]') ||
        msg.contains('error (401)') ||
        msg.contains('error (403)');
  }

  /// Formats verbose Firebase/Gemini JSON error payloads into a concise user-facing message.
  static String formatCloudError(Object error) {
    if (error is AiBatchCancelledException) {
      return error.toString();
    }
    final raw = error.toString();
    final lower = raw.toLowerCase();
    final providerPrefix = lower.contains('personal gemini api')
        ? 'Personal Gemini API: '
        : (lower.contains('firebase ai') ? 'Firebase AI: ' : '');
    if (lower.contains('api_key_invalid') ||
        lower.contains('api key not valid') ||
        lower.contains('invalid api key')) {
      return '${providerPrefix}API key is invalid or restricted. Check your Google AI Studio key in Settings.';
    }
    if (isAppCheckTokenError(error)) {
      final clean = raw
          .replaceFirst(RegExp(r'^Exception:\s*'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final clipped =
          clean.length > 260 ? '${clean.substring(0, 257)}...' : clean;
      if (lower.contains('attestgate') || lower.contains('attest-gate')) {
        return clipped;
      }
      return 'Firebase App Check token rejected ($clipped). Verify ATTEST_GATE_BASE_URL is compiled in (--dart-define-from-file=.env) and attest-gate is minting tokens for this app ID.';
    }
    if (lower.contains('enforce firebase app check') ||
        lower.contains('ai-logic/app-check')) {
      return 'That model requires Firebase App Check enforcement. Switch to a Flash/Lite model in Settings or enable App Check in Firebase Console.';
    }
    if (isQuotaExceededError(error)) {
      return '${providerPrefix}Free-tier quota reached on this model. Switched to a lighter model — retry remaining drafts.';
    }
    if (lower.contains('high demand') || lower.contains('overloaded')) {
      return '${providerPrefix}Gemini servers busy (high demand, HTTP 500/503). Retry shortly.';
    }
    if (error is TimeoutException || lower.contains('timed out')) {
      return '${providerPrefix}Cloud AI request timed out. Check your connection and retry.';
    }
    if (lower.contains('genai config not found')) {
      return 'Firebase AI Logic provider is not enabled yet. Enable Gemini Developer API in Firebase Console or add a Personal Gemini API Key in Settings.';
    }
    final redacted = raw.replaceAll(
      RegExp(r'([?&](?:key|api_key|token|access_token)=)[^&\s\)\]]+',
          caseSensitive: false),
      r'$1REDACTED',
    );
    final singleLine = redacted.replaceAll(RegExp(r'\s+'), ' ').trim();
    return singleLine.length > 220
        ? '${singleLine.substring(0, 217)}...'
        : singleLine;
  }

  /// Computes an ordered list of Gemini models to try for a request:
  /// prefers [selectedModel] first, followed by lighter/sibling fallback models
  /// so a high-demand spike on one model tier does not stall a large batch.
  /// Models in [cooledDownModels] are deferred behind healthy models.
  static List<String> buildFallbackModelOrder(
    String selectedModel,
    List<String> availableModels, {
    Set<String> cooledDownModels = const {},
    int maxCandidates = 3,
    bool allowGemini25 = false,
    bool preferDiscoveredModels = false,
  }) {
    final trimmedSelected = selectedModel.trim();
    final orderedPool = <String>[];
    void addUnique(String m) {
      final clean = m.trim();
      if (clean.isEmpty || !clean.startsWith('gemini-')) return;
      if (!orderedPool.contains(clean)) orderedPool.add(clean);
    }

    if (!UserPreferencesService.isUnsupportedGeminiModel(
      trimmedSelected,
      allowGemini25: allowGemini25,
    )) {
      addUnique(trimmedSelected);
    }

    // Prefer verified active Gemini models
    final siblingHints = <String>[
      'gemini-3.5-flash-lite',
      'gemini-3.8-flash',
      'gemini-4-hydrogen',
      if (allowGemini25) 'gemini-2.5-flash-lite',
      if (allowGemini25) 'gemini-2.5-flash',
    ];

    if (preferDiscoveredModels) {
      for (final m in availableModels) {
        if (UserPreferencesService.isUnsupportedGeminiModel(
          m,
          allowGemini25: allowGemini25,
        )) {
          continue;
        }
        addUnique(m);
      }
      for (final m in siblingHints) {
        addUnique(m);
      }
    } else {
      for (final m in siblingHints) {
        addUnique(m);
      }
      for (final m in availableModels) {
        if (UserPreferencesService.isUnsupportedGeminiModel(
          m,
          allowGemini25: allowGemini25,
        )) {
          continue;
        }
        addUnique(m);
      }
    }

    final healthy = orderedPool
        .where((m) => !cooledDownModels.contains(m))
        .toList();
    final cooled = orderedPool
        .where((m) => cooledDownModels.contains(m))
        .toList();

    final combined = [...healthy, ...cooled];
    if (combined.length <= maxCandidates) return combined;
    return combined.sublist(0, maxCandidates);
  }

  /// Runs [action] with bounded exponential backoff + jitter on transient cloud
  /// errors (HTTP 500/503/429, high demand, timeouts, socket errors).
  static Future<T> runWithTransientRetry<T>({
    required Future<T> Function(int attempt) action,
    int maxAttempts = 3,
    Duration initialDelay = const Duration(milliseconds: 1500),
    Duration maxDelay = const Duration(seconds: 12),
    void Function(int attempt, Duration delay, Object error)? onRetry,
    bool Function()? shouldCancel,
    Future<void> Function(Duration)? sleeper,
  }) async {
    final wait = sleeper ?? Future<void>.delayed;
    final rng = math.Random();
    Object? lastError;

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      if (shouldCancel?.call() == true) {
        throw const AiBatchCancelledException();
      }
      try {
        return await action(attempt);
      } catch (e) {
        if (e is AiBatchCancelledException) rethrow;
        lastError = e;
        if (!isTransientCloudError(e) ||
            isQuotaExceededError(e) ||
            attempt >= maxAttempts) {
          rethrow;
        }
        final baseMs = initialDelay.inMilliseconds * (1 << (attempt - 1));
        final jitterMs = rng.nextInt(500);
        final cappedMs = math.min(baseMs + jitterMs, maxDelay.inMilliseconds);
        final delay = Duration(milliseconds: cappedMs);
        onRetry?.call(attempt, delay, e);
        await wait(delay);
        if (shouldCancel?.call() == true) {
          throw const AiBatchCancelledException();
        }
      }
    }

    throw lastError ?? StateError('Cloud AI retry loop ended unexpectedly.');
  }

  Set<String> _activeCooledDownModels() {
    final now = DateTime.now();
    _modelCooldownUntil.removeWhere((_, until) => !until.isAfter(now));
    return _modelCooldownUntil.keys.toSet();
  }

  void _markModelCooldown(String modelId, Duration duration) {
    _modelCooldownUntil[modelId] = DateTime.now().add(duration);
  }

  bool get canUseFirebaseCloud =>
      connectivity.isOnline && FirebaseBootstrap.isConfigured;

  bool get canUsePersonalGeminiApi =>
      connectivity.isOnline && prefs.hasPersonalGeminiApiKey;

  bool get canUseCustomAi =>
      connectivity.isOnline && prefs.hasCustomAiConfig;

  /// True when on-device Gemini Nano 4 (e.g. Chrome Built-in AI) is ready.
  bool get canUseLocalNano => _nanoStatus.available;

  /// True if ANY AI engine (on-device Gemini Nano 4 OR online Cloud AI) can
  /// enrich/rewrite existing records.
  bool get canEnrichRecords => canUseLocalNano || canUseAnyCloudAi;

  /// True when record enrichment will run on-device Gemini Nano 4 first
  /// (either offline / on-device-only, or in Local First mode when Nano 4 is ready).
  bool get willEnrichUseNanoFirst =>
      canUseLocalNano &&
      (!canUseAnyCloudAi ||
          prefs.aiProviderMode == AiProviderMode.localFirst ||
          prefs.aiProviderMode == AiProviderMode.onDeviceOnly);

  /// True if ANY online cloud AI engine is ready (Firebase AI, Personal Gemini API, or Custom AI).
  bool get canUseAnyCloudAi {
    if (!connectivity.isOnline) return false;
    return switch (prefs.aiProviderMode) {
      AiProviderMode.onDeviceOnly => false,
      AiProviderMode.firebaseAi => canUseFirebaseCloud,
      AiProviderMode.personalGeminiApi => canUsePersonalGeminiApi,
      AiProviderMode.openAiCompatible => canUseCustomAi,
      AiProviderMode.localFirst || AiProviderMode.auto =>
        canUseFirebaseCloud || canUsePersonalGeminiApi || canUseCustomAi,
    };
  }

  /// Active cloud provider resolved from connectivity, saved API keys, and mode.
  /// Exposed publicly so Settings UI and diagnostics can show which cloud backend
  /// will actually handle requests.
  AiProviderMode? get activeCloudProvider => _resolveActiveCloudProvider();

  static String providerDisplayName(AiProviderMode mode) => switch (mode) {
        AiProviderMode.firebaseAi => 'Firebase AI',
        AiProviderMode.personalGeminiApi => 'Personal Gemini API',
        AiProviderMode.openAiCompatible => 'Custom Vision API',
        AiProviderMode.localFirst => 'Local First',
        AiProviderMode.auto => 'Cloud First',
        AiProviderMode.onDeviceOnly => 'On-Device Only',
      };

  String get activeEngineLabel {
    final activeCloud = _resolveActiveCloudProvider();
    if (prefs.aiProviderMode == AiProviderMode.localFirst &&
        _nanoStatus.available) {
      if (activeCloud == null) return 'Nano 4';
      return switch (activeCloud) {
        AiProviderMode.personalGeminiApi => 'Nano 4 (+ Gemini API)',
        AiProviderMode.firebaseAi => 'Nano 4 (+ Firebase AI)',
        AiProviderMode.openAiCompatible => 'Nano 4 (+ Custom AI)',
        _ => 'Nano 4 (+ Cloud)',
      };
    }
    if (activeCloud != null) {
      return switch (activeCloud) {
        AiProviderMode.firebaseAi => 'Firebase • ${prefs.selectedGeminiModel}',
        AiProviderMode.personalGeminiApi =>
          'Gemini API • ${prefs.selectedGeminiModel}',
        AiProviderMode.openAiCompatible => prefs.customAiModel,
        _ => _nanoStatus.available ? 'Nano 4' : 'Local AI',
      };
    }
    if (_nanoStatus.available) return 'Nano 4';
    return 'Local AI';
  }

  AiProviderMode? _resolveActiveCloudProvider() {
    if (!connectivity.isOnline) return null;
    switch (prefs.aiProviderMode) {
      case AiProviderMode.onDeviceOnly:
        return null;
      case AiProviderMode.firebaseAi:
        return canUseFirebaseCloud ? AiProviderMode.firebaseAi : null;
      case AiProviderMode.personalGeminiApi:
        return canUsePersonalGeminiApi
            ? AiProviderMode.personalGeminiApi
            : null;
      case AiProviderMode.openAiCompatible:
        return canUseCustomAi ? AiProviderMode.openAiCompatible : null;
      case AiProviderMode.localFirst:
      case AiProviderMode.auto:
        // When the user explicitly supplied a Personal Gemini API Key, prefer it
        // first (falling back to Firebase AI automatically if needed).
        if (canUsePersonalGeminiApi) return AiProviderMode.personalGeminiApi;
        if (canUseFirebaseCloud) return AiProviderMode.firebaseAi;
        if (canUseCustomAi) return AiProviderMode.openAiCompatible;
        return null;
    }
  }

  Future<void> init() async {
    final result = await checkLocalNanoAvailability();
    _nanoStatus = GeminiNanoStatus(
      available: result.available,
      aicoreInstalled: result.aicoreInstalled,
      deviceModel: result.deviceModel,
      sdkInt: result.sdkInt,
      reason: result.reason,
    );
    notifyListeners();
  }

  void setOcrScripts({
    bool? japanese,
    bool? chinese,
    bool? korean,
  }) {
    if (japanese != null) _enableJapaneseOcr = japanese;
    if (chinese != null) _enableChineseOcr = chinese;
    if (korean != null) _enableKoreanOcr = korean;
    notifyListeners();
  }

  /// Dynamically fetches available Gemini models using either the user's Personal
  /// Gemini API Key OR Firebase AI Logic (no personal API key required!).
  Future<List<String>> fetchAvailableGeminiModels() async {
    final personalKey = prefs.personalGeminiApiKey.trim();

    // 1. Personal Gemini API Key path (sent via HTTP header, never URL query)
    if (personalKey.isNotEmpty) {
      final uri = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models',
      );
      final resp = await _httpClient
          .get(uri, headers: {'x-goog-api-key': personalKey})
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        throw Exception(
          'Personal Gemini API error (${resp.statusCode}): ${utf8.decode(resp.bodyBytes, allowMalformed: true)}',
        );
      }
      final names = _extractGeminiModelNames(
        utf8.decode(resp.bodyBytes, allowMalformed: true),
        forPersonalApi: true,
      );
      _hasDiscoveredPersonalModels = true;
      if (names.isNotEmpty) {
        await prefs.setDiscoveredGeminiModels(names);
      }
      return names;
    }

    // 2. Firebase AI Logic path (no personal API key needed!)
    if (FirebaseBootstrap.isConfigured && Firebase.apps.isNotEmpty) {
      final opts = Firebase.app().options;
      try {
        final uri = Uri.parse(
          'https://firebasevertexai.googleapis.com/v1beta/projects/${opts.projectId}/models',
        );
        final appCheckToken = await AttestGateAppCheck.getHeaderToken(
          limitedUse: true,
        );
        final resp = await _httpClient.get(
          uri,
          headers: {
            'x-goog-api-key': opts.apiKey,
            if (appCheckToken != null) 'X-Firebase-AppCheck': appCheckToken,
          },
        ).timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200) {
          final names = _extractGeminiModelNames(
            utf8.decode(resp.bodyBytes, allowMalformed: true),
          );
          if (names.isNotEmpty) {
            await prefs.setDiscoveredGeminiModels(names);
            return names;
          }
        }
      } catch (e) {
        debugPrint('[EdgeMapper] Firebase model list fallback: $e');
      }

      // Firebase AI Logic client keys often restrict list-models; verify default catalog cleanly
      final curated = UserPreferencesService.defaultGeminiModels;
      await prefs.setDiscoveredGeminiModels(curated);
      return curated;
    }

    throw StateError(
      'Neither Firebase AI nor a Personal Gemini API Key is configured yet.',
    );
  }

  List<String> _extractGeminiModelNames(
    String responseBody, {
    bool forPersonalApi = false,
  }) {
    final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
    final rawModels = decoded['models'] as List? ?? const [];
    final names = <String>[];
    const excludedTokens = [
      'embedding',
      'aqa',
      'imagen',
      'veo',
      'tts',
      'audio',
      'live',
      'learnlm',
      'robotics',
      'computer-use',
      'deep-research',
      'image-generation',
      'nano-banana',
    ];
    for (final m in rawModels) {
      if (m is Map) {
        final methods = (m['supportedGenerationMethods'] as List? ?? const [])
            .map((e) => e.toString())
            .toList();
        if (methods.isNotEmpty && !methods.contains('generateContent')) continue;
        final fullName = m['name']?.toString() ?? '';
        final shortName = fullName.split('/').last.trim();
        final lower = shortName.toLowerCase();
        if (!lower.startsWith('gemini-')) continue;
        if (excludedTokens.any(lower.contains)) continue;
        if (UserPreferencesService.isUnsupportedGeminiModel(
          shortName,
          allowGemini25: forPersonalApi,
        )) {
          continue;
        }
        if (!names.contains(shortName)) {
          names.add(shortName);
        }
      }
    }

    // Rank fast, reliable Flash / Flash-Lite models first for field mapping
    int priorityScore(String modelId) {
      final m = modelId.toLowerCase();
      var score = 50;
      if (m.contains('flash-lite')) {
        score -= 30;
      } else if (m.contains('flash')) {
        score -= 20;
      } else if (m.contains('hydrogen')) {
        score -= 10;
      }
      if (m.contains('preview') || m.contains('exp')) score += 8;
      if (m.contains('-latest')) score += 4;
      return score;
    }

    names.sort((a, b) => priorityScore(a).compareTo(priorityScore(b)));
    return names;
  }

  void cancelActiveLocalNano() => cancelLocalNanoDraft();

  Future<OsmInferenceResult?> _tryLocalNano({
    required String? photoPath,
    required double latitude,
    required double longitude,
    double? headingDegrees,
    double? altitudeMeters,
    String? userHint,
    OsmPreset? preset,
    required bool isOnTrail,
    required String countryLang,
    bool isFullOverwrite = false,
    void Function(String step)? onStatusUpdate,
  }) async {
    if (!_nanoStatus.available) return null;
    if (photoPath == null && (userHint == null || userHint.trim().isEmpty)) {
      return null;
    }
    try {
      onStatusUpdate?.call('Starting Gemini Nano 4...');
      final prompt = _buildNanoOsmPrompt(
        latitude: latitude,
        longitude: longitude,
        headingDegrees: headingDegrees,
        userHint: userHint,
        preset: preset,
        isOnTrail: isOnTrail,
        countryLang: countryLang,
        isFullOverwrite: isFullOverwrite,
      );
      final rawJson = await runLocalNanoDraft(
        prompt: prompt,
        photoPath: photoPath,
        latitude: latitude,
        longitude: longitude,
        headingDegrees: headingDegrees,
        userHint: userHint,
        onProgress: onStatusUpdate,
      );
      if (rawJson != null && rawJson.trim().isNotEmpty) {
        final hasGpsFix = OsmTagStandards.hasValidGps(latitude, longitude);
        final parsed = _parseStructuredOsmJson(
          rawJson,
          aiSource: AiSource.geminiNano,
          headingDegrees: headingDegrees,
          hasGpsFix: hasGpsFix,
        );
        final verified = await _verifyInferenceResultTags(
          parsed,
          hasGpsFix: hasGpsFix,
        );
        _lastNanoError = null;
        notifyListeners();
        return verified;
      }
      _lastNanoError = 'Gemini Nano 4 returned empty output.';
      notifyListeners();
    } catch (e) {
      _lastNanoError = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      debugPrint('[EdgeMapper] Gemini Nano 4 fallback: $e');
    }
    return null;
  }

  /// Merges multiple per-photo [OsmInferenceResult]s for the SAME POI into a single
  /// comprehensive result combining all discovered tags, notes, labels, and candidates.
  static OsmInferenceResult mergeInferenceResults(
    List<OsmInferenceResult> results,
  ) {
    if (results.isEmpty) {
      throw ArgumentError('Cannot merge an empty list of inference results.');
    }
    if (results.length == 1) return results.first;

    final mergedTags = <String, String>{};
    final mergedLabels = <String>{};
    final mergedCandidates = <String, double>{};
    final summaryParts = <String>[];
    final notesParts = <String>[];

    double offsetSum = 0;
    int offsetCount = 0;

    for (final r in results) {
      for (final e in r.tags.entries) {
        if (e.value.trim().isEmpty) continue;
        // Prefer richer/longer values if same key appears across angles (e.g. full opening_hours)
        final existing = mergedTags[e.key];
        if (existing == null ||
            (e.key != 'source' &&
                e.key != 'camera:direction' &&
                e.value.length > existing.length)) {
          mergedTags[e.key] = e.value;
        }
      }
      mergedLabels.addAll(r.detectedLabels);
      for (final c in r.tagCandidates.entries) {
        final prev = mergedCandidates[c.key] ?? 0.0;
        if (c.value > prev) mergedCandidates[c.key] = c.value;
      }
      if (r.summary.trim().isNotEmpty &&
          !summaryParts.contains(r.summary.trim())) {
        summaryParts.add(r.summary.trim());
      }
      if (r.fieldNotes.trim().isNotEmpty &&
          !notesParts.contains(r.fieldNotes.trim())) {
        notesParts.add(r.fieldNotes.trim());
      }
      if (r.estimatedOffsetMeters > 0) {
        offsetSum += r.estimatedOffsetMeters;
        offsetCount++;
      }
    }

    final primary = results.first;
    final avgOffset = offsetCount > 0
        ? (offsetSum / offsetCount).clamp(1.0, 120.0)
        : primary.estimatedOffsetMeters;

    return OsmInferenceResult(
      summary: summaryParts.isNotEmpty ? summaryParts.first : primary.summary,
      fieldNotes: notesParts.join(' | '),
      detectedLanguage: primary.detectedLanguage,
      osmType: primary.osmType,
      estimatedOffsetMeters: avgOffset,
      distanceReasoning:
          'Merged from ${results.length} photos · ${primary.distanceReasoning}',
      tags: mergedTags,
      detectedLabels: mergedLabels.toList(),
      tagCandidates: mergedCandidates,
      aiSource: primary.aiSource,
      diagnosticNote:
          'Combined features from ${results.length} photos into unified OSM tags.',
    );
  }

  static List<String> _resolvePhotoList(
    String? photoPath,
    List<String>? photoPaths,
  ) {
    final list = <String>[];
    if (photoPaths != null) {
      for (final p in photoPaths) {
        if (p.trim().isNotEmpty && !list.contains(p)) list.add(p);
      }
    }
    if (list.isEmpty && photoPath != null && photoPath.trim().isNotEmpty) {
      list.add(photoPath);
    }
    // Cap at 6 photos to stay RAM-safe on 6GB Pixel 6a & cloud payload limits
    return list.take(6).toList();
  }

  /// Main entry point for analyzing a single- or multi-photo street/park/hiking snapshot
  /// with GPS + compass heading. When multiple photos are supplied, AI fuses all angles
  /// into one rich, merged OSM feature!
  Future<OsmInferenceResult> analyzeSnapshot({
    required String? photoPath,
    List<String>? photoPaths,
    required double latitude,
    required double longitude,
    double? headingDegrees,
    double? altitudeMeters,
    String? userHint,
    OsmPreset? preset,
    bool isOnTrail = false,
    bool preferCloud = true,
    bool forceCloud = false,
    void Function(String step)? onStatusUpdate,
    bool Function()? shouldCancel,
  }) async {
    final resolvedPhotos = _resolvePhotoList(photoPath, photoPaths);
    final primaryPhoto = resolvedPhotos.isNotEmpty ? resolvedPhotos.first : null;
    final countryLang =
        LocationContextService.guessCountryLanguageOffline(latitude, longitude);
    final preferLocalNanoFirst =
        !forceCloud && prefs.aiProviderMode == AiProviderMode.localFirst;

    // Local-First mode (default on Linux/Web): try on-device Gemini Nano 4 FIRST.
    // If unavailable/timed out — or when user clicks "Use Cloud AI" — escalate to Firebase AI!
    if (preferLocalNanoFirst) {
      final nanoRes = await _tryLocalNanoMulti(
        photoPaths: resolvedPhotos,
        latitude: latitude,
        longitude: longitude,
        headingDegrees: headingDegrees,
        altitudeMeters: altitudeMeters,
        userHint: userHint,
        preset: preset,
        isOnTrail: isOnTrail,
        countryLang: countryLang,
        onStatusUpdate: onStatusUpdate,
        shouldCancel: shouldCancel,
      );
      if (shouldCancel?.call() == true) {
        throw const AiBatchCancelledException();
      }
      if (nanoRes != null) return nanoRes;
      if (preferCloud && canUseAnyCloudAi) {
        onStatusUpdate?.call('Nano 4 unavailable → Switching to Firebase AI...');
      }
    }

    // Cloud AI (Personal Gemini API / Firebase AI / Custom OpenAI-compatible)
    final cloudProvider = preferCloud ? _resolveActiveCloudProvider() : null;
    if (cloudProvider != null &&
        (resolvedPhotos.isNotEmpty || (userHint?.isNotEmpty == true))) {
      try {
        final providerName = providerDisplayName(cloudProvider);
        onStatusUpdate?.call(
          resolvedPhotos.length > 1
              ? 'Merging ${resolvedPhotos.length} photos with $providerName ($effectiveGeminiModelNow)...'
              : 'Analyzing with $providerName ($effectiveGeminiModelNow)...',
        );
        final cloudRes = await _runCloudProvider(
          provider: cloudProvider,
          photoPaths: resolvedPhotos,
          latitude: latitude,
          longitude: longitude,
          headingDegrees: headingDegrees,
          altitudeMeters: altitudeMeters,
          userHint: userHint,
          preset: preset,
          isOnTrail: isOnTrail,
          countryLang: countryLang,
          isFullOverwrite: false,
          onStatusUpdate: onStatusUpdate,
          shouldCancel: shouldCancel,
        );
        _lastCloudError = null;
        notifyListeners();
        return cloudRes;
      } catch (e) {
        if (e is AiBatchCancelledException) rethrow;
        _lastCloudError = formatCloudError(e);
        notifyListeners();
        debugPrint('[EdgeMapper] Cloud AI ($cloudProvider) failed, falling back on-device: $e');
      }
    }

    // Fallback to on-device Gemini Nano 4 if we haven't tried it yet
    if (!preferLocalNanoFirst && !forceCloud) {
      final nanoRes = await _tryLocalNanoMulti(
        photoPaths: resolvedPhotos,
        latitude: latitude,
        longitude: longitude,
        headingDegrees: headingDegrees,
        altitudeMeters: altitudeMeters,
        userHint: userHint,
        preset: preset,
        isOnTrail: isOnTrail,
        countryLang: countryLang,
        onStatusUpdate: onStatusUpdate,
        shouldCancel: shouldCancel,
      );
      if (nanoRes != null) return nanoRes;
    }

    onStatusUpdate?.call(
      resolvedPhotos.length > 1
          ? 'Merging ${resolvedPhotos.length} photos offline...'
          : 'Running offline tagger...',
    );
    return _analyzeOfflineWithMlKit(
      photoPath: primaryPhoto,
      photoPaths: resolvedPhotos,
      latitude: latitude,
      longitude: longitude,
      headingDegrees: headingDegrees,
      userHint: userHint,
      preset: preset,
      isOnTrail: isOnTrail,
      countryLang: countryLang,
    );
  }

  Future<OsmInferenceResult?> _tryLocalNanoMulti({
    required List<String> photoPaths,
    required double latitude,
    required double longitude,
    double? headingDegrees,
    double? altitudeMeters,
    String? userHint,
    OsmPreset? preset,
    required bool isOnTrail,
    required String countryLang,
    bool isFullOverwrite = false,
    void Function(String step)? onStatusUpdate,
    bool Function()? shouldCancel,
  }) async {
    if (photoPaths.length <= 1) {
      return _tryLocalNano(
        photoPath: photoPaths.isNotEmpty ? photoPaths.first : null,
        latitude: latitude,
        longitude: longitude,
        headingDegrees: headingDegrees,
        altitudeMeters: altitudeMeters,
        userHint: userHint,
        preset: preset,
        isOnTrail: isOnTrail,
        countryLang: countryLang,
        isFullOverwrite: isFullOverwrite,
        onStatusUpdate: onStatusUpdate,
      );
    }
    final perPhotoResults = <OsmInferenceResult>[];
    for (var i = 0; i < photoPaths.length; i++) {
      if (shouldCancel?.call() == true) {
        throw const AiBatchCancelledException();
      }
      onStatusUpdate?.call(
        'Gemini Nano 4 analyzing photo ${i + 1}/${photoPaths.length}...',
      );
      final r = await _tryLocalNano(
        photoPath: photoPaths[i],
        latitude: latitude,
        longitude: longitude,
        headingDegrees: headingDegrees,
        altitudeMeters: altitudeMeters,
        userHint: userHint,
        preset: preset,
        isOnTrail: isOnTrail,
        countryLang: countryLang,
        isFullOverwrite: isFullOverwrite,
        onStatusUpdate: onStatusUpdate,
      );
      if (r != null) perPhotoResults.add(r);
    }
    if (perPhotoResults.isEmpty) return null;
    return mergeInferenceResults(perPhotoResults);
  }

  /// Generates a proposed [EnrichmentDiff] (Before vs After) using the active AI
  /// (on-device Gemini Nano 4 and/or online Cloud AI) without mutating the stored
  /// record, so the user can inspect the diff and accept or reject changes.
  /// Supports BOTH [AiUpdateMode.enrichMerge] and [AiUpdateMode.overwriteAll].
  Future<EnrichmentDiff> proposeAiUpdate(
    OsmRecord record, {
    required AiUpdateMode mode,
    bool forceCloud = false,
    void Function(String status)? onStatusUpdate,
    bool Function()? shouldCancel,
  }) async {
    final provider = _resolveActiveCloudProvider();
    final preferNanoFirst = !forceCloud && willEnrichUseNanoFirst;
    final canFallbackToNano = !forceCloud && canUseLocalNano;

    if (!preferNanoFirst && provider == null && !canFallbackToNano) {
      throw StateError(
        connectivity.isOffline
            ? 'Device is currently offline and on-device Gemini Nano 4 is not available.'
            : 'No AI provider configured. Enable Gemini Nano 4, Firebase AI, or add a Gemini API key in Settings.',
      );
    }

    final countryLang = LocationContextService.guessCountryLanguageOffline(
      record.latitude,
      record.longitude,
    );
    final isFullOverwrite = mode == AiUpdateMode.overwriteAll;
    final recordPhotos = record.allPhotoPaths;
    final hasPhoto = recordPhotos.any(photoExists);
    final existingHint = record.notes.isNotEmpty
        ? record.notes
        : (record.summary.isNotEmpty
            ? record.summary
            : record.tags.entries.map((e) => '${e.key}=${e.value}').join(', '));
    // In full overwrite mode with a photo, ignore possibly stale notes/summary;
    // if there is no photo, pass existing context so the model still has input.
    final effectiveHint = (isFullOverwrite && hasPhoto) ? null : existingHint;

    OsmInferenceResult? result;

    if (preferNanoFirst) {
      result = await _tryLocalNanoMulti(
        photoPaths: recordPhotos,
        latitude: record.latitude,
        longitude: record.longitude,
        headingDegrees: record.headingDegrees,
        altitudeMeters: record.altitudeMeters,
        userHint: effectiveHint,
        isOnTrail: record.trailId != null,
        countryLang: countryLang,
        isFullOverwrite: isFullOverwrite,
        onStatusUpdate: onStatusUpdate,
        shouldCancel: shouldCancel,
      );
      if (shouldCancel?.call() == true) {
        throw const AiBatchCancelledException();
      }
      if (result == null && provider != null) {
        onStatusUpdate?.call('Nano 4 unavailable → Switching to Cloud AI...');
      }
    }

    if (result == null && provider != null) {
      try {
        result = await _runCloudProvider(
          provider: provider,
          photoPaths: recordPhotos,
          latitude: record.latitude,
          longitude: record.longitude,
          headingDegrees: record.headingDegrees,
          altitudeMeters: record.altitudeMeters,
          userHint: effectiveHint,
          isOnTrail: record.trailId != null,
          countryLang: countryLang,
          isFullOverwrite: isFullOverwrite,
          onStatusUpdate: onStatusUpdate,
          shouldCancel: shouldCancel,
        );
        _lastCloudError = null;
        notifyListeners();
      } catch (e) {
        if (e is AiBatchCancelledException) rethrow;
        _lastCloudError = formatCloudError(e);
        notifyListeners();
        if (!preferNanoFirst && canFallbackToNano) {
          onStatusUpdate?.call('Cloud AI failed → Trying Gemini Nano 4...');
          result = await _tryLocalNanoMulti(
            photoPaths: recordPhotos,
            latitude: record.latitude,
            longitude: record.longitude,
            headingDegrees: record.headingDegrees,
            altitudeMeters: record.altitudeMeters,
            userHint: effectiveHint,
            isOnTrail: record.trailId != null,
            countryLang: countryLang,
            isFullOverwrite: isFullOverwrite,
            onStatusUpdate: onStatusUpdate,
            shouldCancel: shouldCancel,
          );
          if (shouldCancel?.call() == true) {
            throw const AiBatchCancelledException();
          }
        }
        if (result == null) rethrow;
      }
    }

    if (result == null && !preferNanoFirst && canFallbackToNano) {
      result = await _tryLocalNanoMulti(
        photoPaths: recordPhotos,
        latitude: record.latitude,
        longitude: record.longitude,
        headingDegrees: record.headingDegrees,
        altitudeMeters: record.altitudeMeters,
        userHint: effectiveHint,
        isOnTrail: record.trailId != null,
        countryLang: countryLang,
        isFullOverwrite: isFullOverwrite,
        onStatusUpdate: onStatusUpdate,
        shouldCancel: shouldCancel,
      );
    }

    if (result == null) {
      throw Exception(
        _lastNanoError ??
            'Gemini Nano 4 could not generate an update for this record.',
      );
    }

    final hasGpsFix = OsmTagStandards.hasValidGps(record.latitude, record.longitude);
    final Map<String, String> nextTags;
    final String nextSummary;
    if (mode == AiUpdateMode.overwriteAll) {
      // Reset & Re-analyze: replace all tags and summary freshly from the photo!
      nextTags = Map<String, String>.from(result.tags);
      nextSummary = result.summary;
    } else {
      // Add Missing Tags: keep all existing non-empty user tags intact, remove
      // draft `fixme`, modernize any deprecated tags, and ONLY fill missing tags!
      final baseModern = OsmTagStandards.modernizeTags(
        Map<String, String>.from(record.tags)..remove('fixme'),
        hasGpsFix: hasGpsFix,
        stripLocalOnly: true,
      );
      for (final entry in result.tags.entries) {
        final existing = baseModern[entry.key]?.trim() ?? '';
        if (existing.isEmpty) {
          baseModern[entry.key] = entry.value;
        }
      }
      nextTags = baseModern;
      final existingSum = record.summary.trim();
      final isGenericSummary = existingSum.isEmpty ||
          existingSum == 'Field OSM draft' ||
          existingSum == 'Street feature' ||
          existingSum == 'Trail feature' ||
          existingSum == 'Unnamed OSM Feature';
      nextSummary = isGenericSummary ? result.summary : record.summary;
    }

    final extrapolated = record.headingDegrees != null
        ? extrapolateCoordinate(
            latitude: record.latitude,
            longitude: record.longitude,
            bearingDegrees: record.headingDegrees!,
            distanceMeters: result.estimatedOffsetMeters,
          )
        : GeoPoint(record.latitude, record.longitude);

    final proposed = record.copyWith(
      summary: nextSummary,
      detectedLanguage: result.detectedLanguage,
      osmType: result.osmType,
      estimatedOffsetMeters: result.estimatedOffsetMeters,
      distanceReasoning: result.distanceReasoning,
      extrapolatedLatitude: extrapolated.latitude,
      extrapolatedLongitude: extrapolated.longitude,
      tags: nextTags,
      detectedLabels: result.detectedLabels.isNotEmpty
          ? result.detectedLabels
          : record.detectedLabels,
      tagCandidates: {
        ...record.tagCandidates,
        ...result.tagCandidates,
      },
      aiSource: result.aiSource,
      status: RecordStatus.aiEnriched,
      clearFirebaseSyncedAt: true,
    );

    return EnrichmentDiff.compute(
      before: record,
      proposed: proposed,
      mode: mode,
    );
  }

  /// Convenience wrapper returning the directly enriched record (used in batch flows
  /// or tests where diff review happens at the caller level).
  Future<OsmRecord> enrichRecordWithCloudAi(
    OsmRecord record, {
    AiUpdateMode mode = AiUpdateMode.enrichMerge,
  }) async {
    final diff = await proposeAiUpdate(record, mode: mode);
    return diff.proposed;
  }

  Future<OsmInferenceResult> _verifyInferenceResultTags(
    OsmInferenceResult result, {
    required bool hasGpsFix,
  }) async {
    final checkedTags = await _tagVerifier.verifyAiTags(
      result.tags,
      isOnline: connectivity.isOnline,
      hasGpsFix: hasGpsFix,
    );
    final verifiedCandidates = await _tagVerifier.verifyAiTagCandidates(
      result.tagCandidates,
      isOnline: connectivity.isOnline,
      hasGpsFix: hasGpsFix,
    );
    final finalTags = Map<String, String>.from(checkedTags.verifiedTags);
    finalTags['source'] = OsmTagStandards.recommendedSource(hasGpsFix: hasGpsFix);

    return OsmInferenceResult(
      summary: result.summary,
      fieldNotes: result.fieldNotes,
      detectedLanguage: result.detectedLanguage,
      osmType: result.osmType,
      estimatedOffsetMeters: result.estimatedOffsetMeters,
      distanceReasoning: result.distanceReasoning,
      tags: finalTags,
      detectedLabels: result.detectedLabels,
      tagCandidates: verifiedCandidates,
      aiSource: result.aiSource,
    );
  }

  Future<OsmInferenceResult> _runCloudProvider({
    required AiProviderMode provider,
    required List<String> photoPaths,
    required double latitude,
    required double longitude,
    double? headingDegrees,
    double? altitudeMeters,
    String? userHint,
    OsmPreset? preset,
    required bool isOnTrail,
    required String countryLang,
    required bool isFullOverwrite,
    void Function(String status)? onStatusUpdate,
    bool Function()? shouldCancel,
  }) async {
    final prompt = _buildOsmPrompt(
      latitude: latitude,
      longitude: longitude,
      headingDegrees: headingDegrees,
      altitudeMeters: altitudeMeters,
      userHint: userHint,
      preset: preset,
      isOnTrail: isOnTrail,
      countryLang: countryLang,
      isFullOverwrite: isFullOverwrite,
      photoCount: photoPaths.length,
    );

    final hasGpsFix = OsmTagStandards.hasValidGps(latitude, longitude);
    final allowCrossCloudFallback =
        prefs.aiProviderMode == AiProviderMode.auto ||
            prefs.aiProviderMode == AiProviderMode.localFirst;

    late final OsmInferenceResult rawResult;
    switch (provider) {
      case AiProviderMode.firebaseAi:
        rawResult = await _callFirebaseAi(
          photoPaths: photoPaths,
          prompt: prompt,
          headingDegrees: headingDegrees,
          hasGpsFix: hasGpsFix,
          onStatusUpdate: onStatusUpdate,
          shouldCancel: shouldCancel,
        ).catchError((Object err) {
          if (err is AiBatchCancelledException) throw err;
          // In Auto / Local First mode, if Firebase AI fails (e.g. API not enabled
          // or sustained high demand) and the user has a Personal Gemini API Key,
          // fall back automatically!
          if (allowCrossCloudFallback && canUsePersonalGeminiApi) {
            debugPrint(
              '[EdgeMapper] Firebase AI failed ($err); falling back to Personal Gemini API Key.',
            );
            onStatusUpdate?.call(
              'Firebase AI busy — switching to Personal Gemini API Key...',
            );
            return _callPersonalGeminiRestApi(
              photoPaths: photoPaths,
              prompt: prompt,
              headingDegrees: headingDegrees,
              hasGpsFix: hasGpsFix,
              onStatusUpdate: onStatusUpdate,
              shouldCancel: shouldCancel,
            );
          }
          throw err;
        });
      case AiProviderMode.personalGeminiApi:
        rawResult = await _callPersonalGeminiRestApi(
          photoPaths: photoPaths,
          prompt: prompt,
          headingDegrees: headingDegrees,
          hasGpsFix: hasGpsFix,
          onStatusUpdate: onStatusUpdate,
          shouldCancel: shouldCancel,
        ).catchError((Object err) {
          if (err is AiBatchCancelledException) throw err;
          // In Auto / Local First mode, if the Personal Gemini API Key fails
          // (busy/quota) and Firebase AI is configured, fall back automatically!
          if (allowCrossCloudFallback && canUseFirebaseCloud) {
            debugPrint(
              '[EdgeMapper] Personal Gemini API failed ($err); falling back to Firebase AI.',
            );
            onStatusUpdate?.call(
              'Personal Gemini API busy — switching to Firebase AI...',
            );
            return _callFirebaseAi(
              photoPaths: photoPaths,
              prompt: prompt,
              headingDegrees: headingDegrees,
              hasGpsFix: hasGpsFix,
              onStatusUpdate: onStatusUpdate,
              shouldCancel: shouldCancel,
            );
          }
          throw err;
        });
      case AiProviderMode.openAiCompatible:
        rawResult = await _callOpenAiCompatibleApi(
          photoPaths: photoPaths,
          prompt: prompt,
          headingDegrees: headingDegrees,
          hasGpsFix: hasGpsFix,
          onStatusUpdate: onStatusUpdate,
          shouldCancel: shouldCancel,
        );
      default:
        throw StateError('Unsupported cloud provider: $provider');
    }

    return _verifyInferenceResultTags(rawResult, hasGpsFix: hasGpsFix);
  }

  /// Compact prompt tuned for on-device Gemini Nano 4's smaller context window
  /// and fast local latency while keeping full OSM & dual-language fidelity.
  String _buildNanoOsmPrompt({
    required double latitude,
    required double longitude,
    double? headingDegrees,
    String? userHint,
    OsmPreset? preset,
    required bool isOnTrail,
    required String countryLang,
    bool isFullOverwrite = false,
  }) {
    final headingText = headingDegrees != null
        ? '${headingDegrees.round()}° (${cardinalDirection(headingDegrees)})'
        : 'unknown';
    final mainLang = prefs.primaryLanguage;
    final secondaryLang = prefs.secondaryLanguage;
    return '''
Identify the main OpenStreetMap feature in this photo.
GPS: ${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)} | Heading: $headingText | Context: ${isOnTrail ? 'trail/park' : 'street'} | Local lang: $countryLang | Main lang: $mainLang | Secondary lang: $secondaryLang
${preset != null ? 'Preset hint: ${preset.label} (${preset.tags})\n' : ''}${userHint != null && userHint.trim().isNotEmpty ? 'Note: ${userHint.trim()}\n' : ''}${isFullOverwrite ? 'Mode: FULL FRESH REWRITE — infer everything freshly from the photo.\n' : ''}Rules:
- Return valid JSON only with: summary, detectedLanguage, osmType ("node"|"way"|"area"), estimatedOffsetMeters (1-120), distanceReasoning, tags ([{key,value}]), tagCandidates ([{key,value,probability}]).
- Write summary in the user's MAIN language ($mainLang).
- OSM name tags: put on-the-ground local name in `name` and `name:$countryLang`, prioritize the user's MAIN language in `name:$mainLang`, and use the SECONDARY language ($secondaryLang) strictly as a secondary tag `name:$secondaryLang` (if different). If an English name is the only available name, use English (`name` / `name:en`).
- Include ONLY real, documented, non-deprecated OpenStreetMap Wiki tags (wiki.openstreetmap.org/wiki/Map_features) and up to 5 probable tagCandidates.
- NEVER invent, guess, or fabricate OSM keys or values! If unsure whether a key exists on OpenStreetMap Wiki, OMIT it.
- Examples of real OSM keys vs fake keys to NEVER output:
  • Outdoor fitness equipment: use `leisure=fitness_station` + `fitness_station=horizontal_ladder` (monkey bars) / `horizontal_bar` / `parallel_bars` / `sit-up` / `balance_beam` / `rings` — NEVER invent `fitness_equipment=*` or `equipment=*`!
  • Children's playground equipment: use `playground=monkey_bars` / `horizontal_bar` / `climbingframe` / `slide` / `swing` / `seesaw` — NEVER invent `playground_equipment=*`!
  • Use British `colour` (not `color`), and NEVER use deprecated OSM tags (`day_off`, `closed_days`, `wifi`, `phone_number`, `amenity=gym`, `shop=fish`, `surface=cobblestone`, `created_by`).
- For `opening_hours`, ALWAYS put 2-letter OSM weekday codes (`Mo`, `Tu`, `We`, `Th`, `Fr`, `Sa`, `Su`, `PH`) before hours and fold closed days into `opening_hours` (e.g. `Tu-Su 09:00-18:00` or `Mo-Fr 09:00-18:00; We off`).
- Do NOT output `camera:direction` (unless the object itself is a surveillance/speed camera), NEVER output `source=GPS`, and do NOT put any software name in `source` (the app sets `source=survey` automatically).
- NEVER output placeholder values like `unknown`, `N/A`, `none`, or `not_visible`. If a detail is unreadable or uncertain, OMIT the tag completely.
''';
  }

  String _buildOsmPrompt({
    required double latitude,
    required double longitude,
    double? headingDegrees,
    double? altitudeMeters,
    String? userHint,
    OsmPreset? preset,
    required bool isOnTrail,
    required String countryLang,
    required bool isFullOverwrite,
    int photoCount = 1,
  }) {
    final headingText = headingDegrees != null
        ? '${headingDegrees.toStringAsFixed(0)}° (${cardinalDirection(headingDegrees)})'
        : 'unknown';

    final mainLang = prefs.primaryLanguage;
    final secondaryLang = prefs.secondaryLanguage;
    final confidentList = prefs.confidentLanguages.join(', ');
    final multiPhotoNote = photoCount > 1
        ? '\n- MULTI-PHOTO MERGE ($photoCount photos provided): All $photoCount images depict different angles or detail signs of the SAME POI (e.g. storefront sign, opening hours sticker, wheelchair ramp, payment/menu info, entrance). Inspect EVERY image and MERGE all observed features into ONE comprehensive, unified set of OSM tags and summary!'
        : '';

    return '''
You are an expert OpenStreetMap (OSM) cartographer helping a field mapper tag a real-world place, shop, street object, park feature, or hiking landmark.

Field telemetry:
- Camera GPS: ${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}
- Altitude: ${altitudeMeters != null ? '${altitudeMeters.toStringAsFixed(1)} m' : 'unknown'}
- Camera compass heading (looking toward): $headingText
- Context: ${isOnTrail ? 'Walking / Park / Hiking route' : 'Street / urban / neighborhood'}
- Country local language (estimated from GPS): $countryLang
- User's MAIN language (primary): $mainLang
- User's SECONDARY language (secondary OSM tag): $secondaryLang
- All user confident languages: $confidentList$multiPhotoNote
${preset != null ? '- User quick preset hint: ${preset.label} (${preset.tags})' : ''}
${userHint != null && userHint.trim().isNotEmpty ? '- Mapper note: ${userHint.trim()}' : ''}
${isFullOverwrite ? '- Mode: FULL FRESH REWRITE — ignore any previous assumptions and infer everything freshly and accurately from the photo.' : ''}

Instructions:
1. Identify the primary mappable OSM feature in the photo.
2. Estimate the distance in meters (`estimatedOffsetMeters`, between 1.0 and 120.0) from the camera to the object/shop using visual depth cues: standard doorway (~2.0m tall), storefront width (~4-6m), sidewalk (~2m), road lanes (~3.2m each), bench (~1.5m), street sign (~2.5m), perspective foreshortening. Explain briefly in `distanceReasoning` (e.g. "Storefront across a 2-lane street, ~14m").
3. Generate ONLY real, documented, non-deprecated OpenStreetMap Wiki tags (`wiki.openstreetmap.org/wiki/Map_features`: `amenity`, `shop`, `tourism`, `highway`, `leisure`, `fitness_station`, `playground`, `natural`, `surface`, `cuisine`, `opening_hours`, `wheelchair`, `outdoor_seating`, `material`, `colour`, etc.):
   - STRICT ANTI-HALLUCINATION RULE: NEVER invent, guess, or fabricate OSM tag keys or values that do not exist on OpenStreetMap Wiki / Taginfo! If you are not 100% certain a key/value is a real OpenStreetMap tag, OMIT it instead of inventing one.
   - Common traps to get right:
     • Outdoor fitness equipment: use `leisure=fitness_station` + `fitness_station=horizontal_ladder` (monkey bars), `fitness_station=horizontal_bar` (pull-up bar), `fitness_station=parallel_bars`, `fitness_station=sit-up`, `fitness_station=push-up`, `fitness_station=balance_beam`, `fitness_station=rings` — NEVER invent `fitness_equipment=*`, `workout_equipment=*`, or `equipment=*`!
     • Children's playground equipment: use `playground=monkey_bars`, `playground=horizontal_bar`, `playground=climbingframe`, `playground=slide`, `playground=swing`, `playground=seesaw`, `playground=sandpit` — NEVER invent `playground_equipment=*`!
     • Use British spelling `colour` (NEVER `color`), `material=*` (NEVER `frame_material` or `bench_material`).
   - STRICTLY AVOID all deprecated OSM tags (for example NEVER use `day_off`, `closed_days`, `wifi`, `phone_number`, `url`, `amenity=gym`, `amenity=sauna`, `shop=fish`, `surface=cobblestone`, `landuse=wood`, `created_by`). Use current replacements (`leisure=fitness_centre`, `shop=seafood`, `internet_access=wlan`, `phone`, `website`, `surface=sett`, etc.).
   - For `opening_hours`, ALWAYS follow official OpenStreetMap `Key:opening_hours` syntax with 2-letter weekday codes (`Mo`, `Tu`, `We`, `Th`, `Fr`, `Sa`, `Su`, `PH`) BEFORE hours and encode closed days inside `opening_hours` (e.g. `Tu-Su 09:30-18:00`, `Mo,Tu,Th-Su 09:00-18:00`, or `Mo-Fr 09:00-18:00; Sa 10:00-16:00; Su,PH off`) — NEVER use a separate `day_off` tag!
4. MAIN & SECONDARY LANGUAGE RULE (very important!):
   - Put the on-the-ground primary local name in `name` (and duplicate in `name:$countryLang` when applicable).
   - Prioritize the user's MAIN language (`$mainLang`) as the primary user language: include `name:$mainLang` (if `$mainLang` has a valid name/translation) and write `summary` in `$mainLang`.
   - Use the user's SECONDARY language (`$secondaryLang`) strictly as a SECONDARY tag on OSM (`name:$secondaryLang`, when `$secondaryLang` differs from `$mainLang` and `$countryLang`) — NEVER let the secondary language override the main language `$mainLang`!
   - ENGLISH-ONLY EXCEPTION: If an English name is the only applicable/recognized name (e.g. English-only sign or untranslatable English proper name), use the English name for `name` and `name:en` cleanly instead of forcing an awkward translation.
5. Provide `tagCandidates`: 5 to 10 probable, current (non-deprecated) OSM `key`/`value` tags matching what is visible in the photo with `probability` between 0.1 and 0.99 (ordered highest first), so the user can pick additional tags from a ranked selector.
6. Do NOT output `camera:direction` (unless the mapped feature itself is a surveillance or speed camera; use `direction` only for viewpoints/guideposts/benches). NEVER output `source=GPS` or put the app/software name in `source` (the app sets `source=survey` automatically).
7. NEVER guess or output placeholder values like `unknown`, `N/A`, `none`, or `not_visible`. Only include tags directly supported by visual/text evidence in the photo.
''';
  }

  /// Returns the Gemini Developer API [FirebaseAI] client configured to request
  /// single-use limited-use App Check tokens so Replay Protection ("Replay Enforced")
  /// is satisfied on every request.
  FirebaseAI _firebaseGoogleAi() =>
      FirebaseAI.googleAI(useLimitedUseAppCheckTokens: true);

  /// Returns the Vertex / Agent Platform [FirebaseAI] client configured for
  /// limited-use App Check tokens (Replay Protection).
  FirebaseAI _firebaseAgentPlatform() =>
      FirebaseAI.agentPlatform(useLimitedUseAppCheckTokens: true);

  /// Quick diagnostic ping verifying the active AI engine:
  /// - Offline / On-Device Only: tests local Gemini Nano 4 (or ML Kit) directly!
  /// - Local First (online): tests BOTH Gemini Nano 4 AND Firebase AI!
  /// - Cloud mode: tests Firebase AI / Personal Gemini API / Custom AI!
  Future<String> testActiveCloudAi() async {
    final isOfflineOrLocalOnly = connectivity.isOffline ||
        prefs.aiProviderMode == AiProviderMode.onDeviceOnly;

    if (isOfflineOrLocalOnly) {
      try {
        final nanoMsg = await testLocalNano();
        _lastNanoError = null;
        notifyListeners();
        return nanoMsg;
      } catch (e) {
        _lastNanoError = e.toString().replaceFirst('Exception: ', '');
        notifyListeners();
        rethrow;
      }
    }

    final reportLines = <String>[];

    // When in Local First mode (default on Linux/Web), test Nano 4 first!
    if (prefs.aiProviderMode == AiProviderMode.localFirst) {
      try {
        final nanoMsg = await testLocalNano();
        _lastNanoError = null;
        reportLines.add('Local: $nanoMsg');
      } catch (e) {
        final clean = e.toString().replaceFirst('Exception: ', '');
        _lastNanoError = clean;
        reportLines.add('Local: $clean');
      }
    }

    final provider = _resolveActiveCloudProvider();
    if (provider == null) {
      notifyListeners();
      if (reportLines.isNotEmpty) return reportLines.join('\n');
      throw StateError('No Cloud AI provider active.');
    }

    if (provider == AiProviderMode.firebaseAi) {
      final candidates = buildFallbackModelOrder(
        prefs.selectedGeminiModel,
        prefs.availableGeminiModels,
        cooledDownModels: _activeCooledDownModels(),
        maxCandidates: 4,
      );
      Object? lastErr;
      String lastModelTried = effectiveGeminiModelNow;
      bool retriedAppCheck = false;
      for (int idx = 0; idx < candidates.length; idx++) {
        final modelId = candidates[idx];
        lastModelTried = modelId;
        try {
          final model = _firebaseGoogleAi().generativeModel(model: modelId);
          final resp = await model
              .generateContent([Content.text('Reply with OK')])
              .timeout(const Duration(seconds: 15));
          _lastCloudError = null;
          _modelCooldownUntil.remove(modelId);
          if (modelId != prefs.selectedGeminiModel) {
            await prefs.setSelectedGeminiModel(modelId);
          }
          notifyListeners();
          final cloudMsg =
              'Firebase AI ($modelId): ${(resp.text ?? 'OK').trim()}';
          return reportLines.isEmpty
              ? cloudMsg
              : [...reportLines, 'Cloud: $cloudMsg'].join('\n');
        } catch (googleAiErr) {
          debugPrint(
            '[EdgeMapper] Firebase AI test ($modelId) failed: $googleAiErr',
          );
          if (isAppCheckTokenError(googleAiErr)) {
            if (!retriedAppCheck) {
              retriedAppCheck = true;
              // With useLimitedUseAppCheckTokens: true, retrying immediately mints
              // a fresh single-use token via FirebaseAppCheck.getLimitedUseToken().
              idx--;
              continue;
            }
            final diag = await AttestGateAppCheck.diagnoseAndRefreshToken(
              limitedUse: true,
            );
            lastErr = Exception('$googleAiErr — ${diag.summary}');
            break;
          }
          if (googleAiErr.toString().contains('genai config not found')) {
            try {
              final vertexModel =
                  _firebaseAgentPlatform().generativeModel(model: modelId);
              final resp = await vertexModel
                  .generateContent([Content.text('Reply with OK')])
                  .timeout(const Duration(seconds: 15));
              _lastCloudError = null;
              _modelCooldownUntil.remove(modelId);
              if (modelId != prefs.selectedGeminiModel) {
                await prefs.setSelectedGeminiModel(modelId);
              }
              notifyListeners();
              final cloudMsg =
                  'Firebase Vertex AI ($modelId): ${(resp.text ?? 'OK').trim()}';
              return reportLines.isEmpty
                  ? cloudMsg
                  : [...reportLines, 'Cloud: $cloudMsg'].join('\n');
            } catch (vertexErr) {
              lastErr = vertexErr;
              if (isAuthOrConfigError(vertexErr)) {
                break;
              }
              if (isModelUnavailableError(vertexErr) ||
                  isQuotaExceededError(vertexErr)) {
                _markModelCooldown(modelId, _quotaExceededCooldown);
                continue;
              }
              if (isTransientCloudError(vertexErr)) {
                _markModelCooldown(modelId, _highDemandCooldown);
                continue;
              }
              break;
            }
          }
          lastErr = googleAiErr;
          if (isAuthOrConfigError(googleAiErr)) {
            break;
          }
          if (isModelUnavailableError(googleAiErr) ||
              isQuotaExceededError(googleAiErr)) {
            _markModelCooldown(modelId, _quotaExceededCooldown);
            continue;
          }
          if (isTransientCloudError(googleAiErr)) {
            _markModelCooldown(modelId, _highDemandCooldown);
            continue;
          }
          break;
        }
      }
      final formatted = formatCloudError(
        Exception('Firebase AI ($lastModelTried): ${lastErr ?? 'test failed'}'),
      );
      _lastCloudError = formatted;
      notifyListeners();
      if (reportLines.isNotEmpty) {
        return [...reportLines, 'Cloud error ($lastModelTried): $formatted']
            .join('\n');
      }
      throw Exception('$lastModelTried failed: $formatted');
    }
    if (provider == AiProviderMode.personalGeminiApi) {
      final apiKey = prefs.personalGeminiApiKey.trim();
      List<String> discovered = const [];
      try {
        discovered = await fetchAvailableGeminiModels();
      } catch (e) {
        if (isAuthOrConfigError(e)) {
          final formatted = formatCloudError(e);
          _lastCloudError = formatted;
          notifyListeners();
          throw Exception(formatted);
        }
      }

      final candidates = buildFallbackModelOrder(
        prefs.selectedGeminiModel,
        discovered.isNotEmpty ? discovered : prefs.availableGeminiModels,
        cooledDownModels: _activeCooledDownModels(),
        maxCandidates: 6,
        allowGemini25: true,
        preferDiscoveredModels: discovered.isNotEmpty,
      );

      Object? lastErr;
      String lastModelTried =
          candidates.isNotEmpty ? candidates.first : prefs.selectedGeminiModel;
      final pingBody = jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': 'Reply with OK'},
            ],
          },
        ],
      });

      for (final modelId in candidates) {
        lastModelTried = modelId;
        final uri = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/${Uri.encodeComponent(modelId)}:generateContent',
        );
        try {
          final resp = await _httpClient
              .post(
                uri,
                headers: {
                  'Content-Type': 'application/json',
                  'x-goog-api-key': apiKey,
                },
                body: pingBody,
              )
              .timeout(const Duration(seconds: 15));
          final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
          if (resp.statusCode != 200) {
            throw Exception(
              'Personal Gemini API error (${resp.statusCode}): $bodyText',
            );
          }
          final decoded = jsonDecode(bodyText) as Map<String, dynamic>;
          final apiCandidates = decoded['candidates'] as List? ?? const [];
          final replyParts = apiCandidates.isNotEmpty
              ? ((apiCandidates.first['content']?['parts'] as List?) ??
                  const [])
              : const [];
          final reply = replyParts
              .map((p) => (p as Map)['text']?.toString() ?? '')
              .join('')
              .trim();
          _lastCloudError = null;
          _modelCooldownUntil.remove(modelId);
          _lastUsedModel = modelId;
          if (modelId != prefs.selectedGeminiModel) {
            await prefs.setSelectedGeminiModel(modelId);
          }
          notifyListeners();
          final msg =
              'Personal Gemini API ($modelId): ${reply.isNotEmpty ? reply : 'OK'}${discovered.isNotEmpty ? ' · ${discovered.length} models' : ''}';
          return reportLines.isEmpty
              ? msg
              : [...reportLines, 'Cloud: $msg'].join('\n');
        } catch (err) {
          lastErr = err;
          if (isAuthOrConfigError(err)) break;
          if (isModelUnavailableError(err) || isQuotaExceededError(err)) {
            _markModelCooldown(modelId, _quotaExceededCooldown);
            continue;
          }
          if (isTransientCloudError(err)) {
            _markModelCooldown(modelId, _highDemandCooldown);
            continue;
          }
          break;
        }
      }

      final formatted = formatCloudError(
        Exception(
          'Personal Gemini API ($lastModelTried): ${lastErr ?? 'test failed'}',
        ),
      );
      _lastCloudError = formatted;
      notifyListeners();
      if (reportLines.isNotEmpty) {
        return [...reportLines, 'Cloud error ($lastModelTried): $formatted']
            .join('\n');
      }
      throw Exception('$lastModelTried failed: $formatted');
    }
    final msg = 'Custom AI configured (${prefs.customAiModel}).';
    return reportLines.isEmpty
        ? msg
        : [...reportLines, 'Cloud: $msg'].join('\n');
  }

  Future<OsmInferenceResult> _callFirebaseAiSingleAttempt({
    required FirebaseAI backend,
    required String modelId,
    required List<Part> parts,
    required Schema schema,
    required String prompt,
    double? headingDegrees,
    bool hasGpsFix = true,
  }) async {
    // Attempt 1: Structured JSON Schema mode
    try {
      final model = backend.generativeModel(
        model: modelId,
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          responseSchema: schema,
        ),
      );
      final response = await model
          .generateContent([Content.multi(parts)])
          .timeout(_cloudRequestTimeout);
      final text = response.text;
      if (text != null && text.trim().isNotEmpty) {
        return _parseStructuredOsmJson(
          text,
          aiSource: AiSource.firebaseCloud,
          headingDegrees: headingDegrees,
          hasGpsFix: hasGpsFix,
        );
      }
    } catch (schemaError) {
      // Do NOT immediately fire a second JSON-only request on transient overload
      // (500 high demand / 503 / 429 / timeout), auth/config, or retired-model errors!
      // Let our exponential backoff + fallback-model router handle those cleanly.
      if (isTransientCloudError(schemaError) ||
          isAuthOrConfigError(schemaError) ||
          isModelUnavailableError(schemaError)) {
        rethrow;
      }
      debugPrint(
        '[EdgeMapper] Firebase AI schema call ($modelId) failed ($schemaError), retrying JSON-only mode...',
      );
      final fallbackParts = <Part>[
        ...parts.whereType<InlineDataPart>(),
        TextPart(
          '$prompt\n\nReturn strictly valid JSON with keys: summary (string), '
          'detectedLanguage (ISO 639-1 string), osmType ("node"|"way"|"area"), '
          'estimatedOffsetMeters (number), distanceReasoning (string), '
          'tags (array of {"key": "...", "value": "..."}), '
          'tagCandidates (array of {"key": "...", "value": "...", "probability": 0.8}).',
        ),
      ];
      final fallbackModel = backend.generativeModel(
        model: modelId,
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
        ),
      );
      final response = await fallbackModel
          .generateContent([Content.multi(fallbackParts)])
          .timeout(_cloudRequestTimeout);
      final text = response.text;
      if (text == null || text.trim().isEmpty) {
        throw Exception(
          'Firebase AI returned empty response (initial error: $schemaError)',
        );
      }
      return _parseStructuredOsmJson(
        text,
        aiSource: AiSource.firebaseCloud,
        headingDegrees: headingDegrees,
        hasGpsFix: hasGpsFix,
      );
    }

    throw Exception('Firebase AI returned an empty response.');
  }

  String get effectiveGeminiModelNow {
    final isPersonal =
        _resolveActiveCloudProvider() == AiProviderMode.personalGeminiApi;
    final candidates = buildFallbackModelOrder(
      prefs.selectedGeminiModel,
      prefs.availableGeminiModels,
      cooledDownModels: _activeCooledDownModels(),
      maxCandidates: 1,
      allowGemini25: isPersonal,
      preferDiscoveredModels: isPersonal && _hasDiscoveredPersonalModels,
    );
    return candidates.isNotEmpty ? candidates.first : prefs.selectedGeminiModel;
  }

  Future<OsmInferenceResult> _callFirebaseAiWithModels({
    required FirebaseAI backend,
    required List<Part> parts,
    required Schema schema,
    required String prompt,
    double? headingDegrees,
    bool hasGpsFix = true,
    void Function(String status)? onStatusUpdate,
    bool Function()? shouldCancel,
  }) async {
    final candidates = buildFallbackModelOrder(
      prefs.selectedGeminiModel,
      prefs.availableGeminiModels,
      cooledDownModels: _activeCooledDownModels(),
      maxCandidates: 4,
    );

    Object? lastError;
    bool retriedAppCheck = false;
    for (int idx = 0; idx < candidates.length; idx++) {
      if (shouldCancel?.call() == true) {
        throw const AiBatchCancelledException();
      }
      final modelId = candidates[idx];
      final hasFallback = idx + 1 < candidates.length;
      try {
        // Fail over IMMEDIATELY to the next fallback model when a model hits
        // 500 high demand / 503 / 429 — only do 1 quick retry on the last candidate.
        final result = await runWithTransientRetry(
          maxAttempts: hasFallback ? 1 : 2,
          initialDelay: const Duration(milliseconds: 1200),
          maxDelay: const Duration(seconds: 4),
          shouldCancel: shouldCancel,
          onRetry: (attempt, delay, err) {
            final sec = (delay.inMilliseconds / 1000).ceil();
            debugPrint(
              '[EdgeMapper] Firebase AI ($modelId) transient error on last candidate; retrying in ${sec}s: $err',
            );
            onStatusUpdate?.call(
              '$modelId busy — quick retry in ${sec}s...',
            );
          },
          action: (_) => _callFirebaseAiSingleAttempt(
            backend: backend,
            modelId: modelId,
            parts: parts,
            schema: schema,
            prompt: prompt,
            headingDegrees: headingDegrees,
            hasGpsFix: hasGpsFix,
          ),
        );
        _modelCooldownUntil.remove(modelId);
        _lastUsedModel = modelId;
        return result;
      } catch (err) {
        if (err is AiBatchCancelledException) rethrow;
        lastError = err;
        debugPrint('[EdgeMapper] Firebase AI ($modelId) error: $err');
        if (isAppCheckTokenError(err)) {
          if (!retriedAppCheck) {
            retriedAppCheck = true;
            onStatusUpdate?.call('Retrying with fresh limited-use App Check token...');
            // With useLimitedUseAppCheckTokens: true, retrying immediately fetches
            // a brand-new single-use token via FirebaseAppCheck.getLimitedUseToken().
            idx--;
            continue;
          }
          final diag = await AttestGateAppCheck.diagnoseAndRefreshToken(
            limitedUse: true,
          );
          throw Exception('$err — ${diag.summary}');
        }
        if (isAuthOrConfigError(err)) {
          rethrow;
        }
        if (isModelUnavailableError(err)) {
          _markModelCooldown(modelId, _quotaExceededCooldown);
          if (hasFallback) {
            final nextModel = candidates[idx + 1];
            if (modelId == prefs.selectedGeminiModel) {
              debugPrint(
                '[EdgeMapper] Model $modelId unavailable/restricted ($err); switching saved setting to $nextModel',
              );
              await prefs.setSelectedGeminiModel(nextModel);
            }
            onStatusUpdate?.call(
              '$modelId restricted → $nextModel',
            );
            continue;
          }
        }
        if (isQuotaExceededError(err)) {
          _markModelCooldown(modelId, _quotaExceededCooldown);
          if (hasFallback) {
            final nextModel = candidates[idx + 1];
            debugPrint(
              '[EdgeMapper] Quota exceeded on $modelId; switching saved model setting to $nextModel',
            );
            await prefs.setSelectedGeminiModel(nextModel);
            onStatusUpdate?.call(
              'Quota hit on $modelId → switched to $nextModel',
            );
            continue;
          }
        }
        if (isTransientCloudError(err)) {
          _markModelCooldown(modelId, _highDemandCooldown);
          if (hasFallback) {
            final nextModel = candidates[idx + 1];
            debugPrint(
              '[EdgeMapper] $modelId busy (high demand); immediately switching to $nextModel',
            );
            onStatusUpdate?.call(
              '$modelId busy → $nextModel',
            );
            continue;
          }
        }
        rethrow;
      }
    }

    throw lastError ?? Exception('Firebase AI request failed on all models.');
  }

  Future<OsmInferenceResult> _callFirebaseAi({
    required List<String> photoPaths,
    required String prompt,
    double? headingDegrees,
    bool hasGpsFix = true,
    void Function(String status)? onStatusUpdate,
    bool Function()? shouldCancel,
  }) async {
    final schema = Schema.object(
      description:
          'Structured OpenStreetMap feature suggestion extrapolated from photo, GPS, and compass direction.',
      optionalProperties: const [
        'distanceReasoning',
        'tagCandidates',
      ],
      properties: {
        'summary': Schema.string(
          description: 'Concise human-readable description of the mapped place/object.',
        ),
        'detectedLanguage': Schema.string(
          description: 'ISO 639-1 language code of primary local signage (e.g. en, ja, fr, zh, ko).',
        ),
        'osmType': Schema.string(
          description: 'OSM element type: node, way, or area.',
        ),
        'estimatedOffsetMeters': Schema.number(
          description:
              'Estimated distance in meters from camera location along compass bearing to the object/shop (1.0 to 120.0).',
        ),
        'distanceReasoning': Schema.string(
          description: 'Brief visual explanation of how distance was estimated.',
        ),
        'tags': Schema.array(
          description:
              'Valid OpenStreetMap key/value tags including dual-language name, name:<country_lang>, and name:<user_lang>.',
          items: Schema.object(
            properties: {
              'key': Schema.string(description: 'Standard OSM tag key.'),
              'value': Schema.string(description: 'OSM tag value.'),
            },
          ),
        ),
        'tagCandidates': Schema.array(
          description:
              'Additional probable OSM tags matching visual cues in the photo, sorted by probability.',
          items: Schema.object(
            properties: {
              'key': Schema.string(description: 'OSM tag key.'),
              'value': Schema.string(description: 'OSM tag value.'),
              'probability': Schema.number(description: 'Match probability 0.1 to 0.99.'),
            },
          ),
        ),
      },
    );

    final parts = <Part>[];
    for (final p in photoPaths) {
      final photoBytes = await readPhotoBytes(p);
      if (photoBytes != null && photoBytes.isNotEmpty) {
        parts.add(InlineDataPart(mimeTypeForPhoto(p), photoBytes));
      }
    }
    parts.add(TextPart(prompt));

    // Try Gemini Developer API backend first; if the project was set up with
    // Vertex AI / Agent Platform instead, automatically fall back to it!
    try {
      return await _callFirebaseAiWithModels(
        backend: _firebaseGoogleAi(),
        parts: parts,
        schema: schema,
        prompt: prompt,
        headingDegrees: headingDegrees,
        hasGpsFix: hasGpsFix,
        onStatusUpdate: onStatusUpdate,
        shouldCancel: shouldCancel,
      );
    } catch (googleAiErr) {
      if (googleAiErr is AiBatchCancelledException) rethrow;
      final errLower = googleAiErr.toString().toLowerCase();
      if (errLower.contains('genai config not found')) {
        debugPrint(
          '[EdgeMapper] Gemini Developer API config not found; trying Firebase Vertex AI backend...',
        );
        try {
          return await _callFirebaseAiWithModels(
            backend: _firebaseAgentPlatform(),
            parts: parts,
            schema: schema,
            prompt: prompt,
            headingDegrees: headingDegrees,
            hasGpsFix: hasGpsFix,
            onStatusUpdate: onStatusUpdate,
            shouldCancel: shouldCancel,
          );
        } catch (vertexErr) {
          if (vertexErr is AiBatchCancelledException) rethrow;
          throw Exception(
            'Firebase AI Logic provider not linked yet. In Firebase Console → Build → AI Logic → Get started → click "Enable" on Gemini Developer API (or paste a personal Gemini API key in Settings).',
          );
        }
      }
      rethrow;
    }
  }

  Future<OsmInferenceResult> _callPersonalGeminiRestApi({
    required List<String> photoPaths,
    required String prompt,
    double? headingDegrees,
    bool hasGpsFix = true,
    void Function(String status)? onStatusUpdate,
    bool Function()? shouldCancel,
  }) async {
    final apiKey = prefs.personalGeminiApiKey.trim();
    if (apiKey.isEmpty) {
      throw StateError('Personal Gemini API key is empty.');
    }

    final parts = <Map<String, dynamic>>[];
    for (final p in photoPaths) {
      final photoBytes = await readPhotoBytes(p);
      if (photoBytes != null && photoBytes.isNotEmpty) {
        parts.add({
          'inline_data': {
            'mime_type': mimeTypeForPhoto(p),
            'data': base64Encode(photoBytes),
          },
        });
      }
    }
    parts.add({
      'text':
          '$prompt\n\nReturn strictly valid JSON with keys: summary, detectedLanguage, osmType, estimatedOffsetMeters, distanceReasoning, tags (array of {key, value}), tagCandidates (array of {key, value, probability}).',
    });

    final payloadJson = jsonEncode({
      'contents': [
        {'parts': parts},
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
      },
    });

    final candidates = buildFallbackModelOrder(
      prefs.selectedGeminiModel,
      prefs.availableGeminiModels,
      cooledDownModels: _activeCooledDownModels(),
      maxCandidates: 5,
      allowGemini25: true,
      preferDiscoveredModels: _hasDiscoveredPersonalModels,
    );

    final triedModels = <String>{};
    Object? lastError;

    Future<OsmInferenceResult?> tryCandidateList(List<String> list) async {
      for (int idx = 0; idx < list.length; idx++) {
        if (shouldCancel?.call() == true) {
          throw const AiBatchCancelledException();
        }
        final modelId = list[idx];
        if (!triedModels.add(modelId)) continue;
        final hasFallback = idx + 1 < list.length;
        final uri = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/${Uri.encodeComponent(modelId)}:generateContent',
        );

        try {
          final result = await runWithTransientRetry(
            maxAttempts: hasFallback ? 1 : 2,
            initialDelay: const Duration(milliseconds: 1200),
            maxDelay: const Duration(seconds: 4),
            shouldCancel: shouldCancel,
            onRetry: (attempt, delay, err) {
              final sec = (delay.inMilliseconds / 1000).ceil();
              debugPrint(
                '[EdgeMapper] Personal Gemini API ($modelId) transient error on last candidate; retrying in ${sec}s: ${formatCloudError(err)}',
              );
              onStatusUpdate?.call(
                '$modelId busy — quick retry in ${sec}s...',
              );
            },
            action: (_) async {
              final resp = await _httpClient
                  .post(
                    uri,
                    headers: {
                      'Content-Type': 'application/json',
                      'x-goog-api-key': apiKey,
                    },
                    body: payloadJson,
                  )
                  .timeout(_cloudRequestTimeout);

              final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
              if (resp.statusCode != 200) {
                throw Exception(
                  'Personal Gemini API error (${resp.statusCode}): $bodyText',
                );
              }

              final decoded = jsonDecode(bodyText) as Map<String, dynamic>;
              final apiCandidates = decoded['candidates'] as List? ?? const [];
              if (apiCandidates.isEmpty) {
                throw Exception('Personal Gemini API returned no candidates.');
              }
              final contentParts =
                  (apiCandidates.first['content']?['parts'] as List?) ??
                      const [];
              final text = contentParts
                  .map((p) => (p as Map)['text']?.toString() ?? '')
                  .join('')
                  .trim();
              if (text.isEmpty) {
                throw Exception('Personal Gemini API returned empty text.');
              }

              return _parseStructuredOsmJson(
                text,
                aiSource: AiSource.personalGeminiApi,
                headingDegrees: headingDegrees,
                hasGpsFix: hasGpsFix,
              );
            },
          );
          _modelCooldownUntil.remove(modelId);
          _lastUsedModel = modelId;
          return result;
        } catch (err) {
          if (err is AiBatchCancelledException) rethrow;
          lastError = err;
          if (isAuthOrConfigError(err)) rethrow;
          if (isModelUnavailableError(err)) {
            _markModelCooldown(modelId, _quotaExceededCooldown);
            if (hasFallback) {
              final nextModel = list[idx + 1];
              if (modelId == prefs.selectedGeminiModel) {
                await prefs.setSelectedGeminiModel(nextModel);
              }
              onStatusUpdate?.call(
                '$modelId unavailable → $nextModel',
              );
              continue;
            }
          }
          if (isQuotaExceededError(err)) {
            _markModelCooldown(modelId, _quotaExceededCooldown);
            if (hasFallback) {
              final nextModel = list[idx + 1];
              debugPrint(
                '[EdgeMapper] Quota exceeded on $modelId (Personal Gemini API); switching saved model setting to $nextModel',
              );
              await prefs.setSelectedGeminiModel(nextModel);
              onStatusUpdate?.call(
                'Quota hit on $modelId → switched to $nextModel',
              );
              continue;
            }
          }
          if (isTransientCloudError(err)) {
            _markModelCooldown(modelId, _highDemandCooldown);
            if (hasFallback) {
              onStatusUpdate?.call(
                '$modelId busy → ${list[idx + 1]}',
              );
              continue;
            }
          }
          if (!hasFallback) return null;
          rethrow;
        }
      }
      return null;
    }

    final primaryRes = await tryCandidateList(candidates);
    if (primaryRes != null) return primaryRes;

    // Auto-discover live models available on this Personal Gemini API key if initial
    // defaults were unavailable or overloaded (500/503/404/429).
    if (!_hasDiscoveredPersonalModels &&
        lastError != null &&
        !isAuthOrConfigError(lastError!)) {
      try {
        onStatusUpdate?.call(
          'Discovering available models for your Gemini API key...',
        );
        final discovered = await fetchAvailableGeminiModels();
        final extraCandidates = discovered
            .where((m) => !triedModels.contains(m))
            .take(3)
            .toList();
        if (extraCandidates.isNotEmpty) {
          final extraRes = await tryCandidateList(extraCandidates);
          if (extraRes != null) {
            if (_lastUsedModel != null &&
                _lastUsedModel != prefs.selectedGeminiModel) {
              await prefs.setSelectedGeminiModel(_lastUsedModel!);
            }
            return extraRes;
          }
        }
      } catch (discoverErr) {
        if (discoverErr is AiBatchCancelledException) rethrow;
        if (isAuthOrConfigError(discoverErr)) rethrow;
      }
    }

    throw lastError ??
        Exception('Personal Gemini API failed on all candidate models.');
  }

  Future<OsmInferenceResult> _callOpenAiCompatibleApi({
    required List<String> photoPaths,
    required String prompt,
    double? headingDegrees,
    bool hasGpsFix = true,
    void Function(String status)? onStatusUpdate,
    bool Function()? shouldCancel,
  }) async {
    final baseUrl = prefs.customAiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final apiKey = prefs.customAiApiKey.trim();
    final modelId = prefs.customAiModel.trim();
    if (baseUrl.isEmpty || apiKey.isEmpty) {
      throw StateError('Custom AI base URL and API key are required.');
    }

    final uri = Uri.tryParse('$baseUrl/chat/completions');
    if (uri == null || uri.host.isEmpty) {
      throw StateError('Invalid Custom AI base URL.');
    }
    final isLoopback = uri.host == 'localhost' ||
        uri.host == '127.0.0.1' ||
        uri.host == '::1';
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && isLoopback)) {
      throw StateError(
        'Custom AI base URL must use https:// (http:// is only allowed for localhost/127.0.0.1).',
      );
    }
    final content = <Map<String, dynamic>>[
      {
        'type': 'text',
        'text':
            '$prompt\n\nReturn strictly a JSON object with keys: summary, detectedLanguage, osmType, estimatedOffsetMeters, distanceReasoning, tags ([{key,value}]), tagCandidates ([{key,value,probability}]).',
      },
    ];
    for (final p in photoPaths) {
      final photoBytes = await readPhotoBytes(p);
      if (photoBytes != null && photoBytes.isNotEmpty) {
        content.add({
          'type': 'image_url',
          'image_url': {
            'url': 'data:${mimeTypeForPhoto(p)};base64,${base64Encode(photoBytes)}',
          },
        });
      }
    }

    final bodyJson = jsonEncode({
      'model': modelId,
      'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'user', 'content': content},
      ],
    });

    final result = await runWithTransientRetry(
      maxAttempts: 3,
      initialDelay: const Duration(milliseconds: 1600),
      maxDelay: const Duration(seconds: 10),
      shouldCancel: shouldCancel,
      onRetry: (attempt, delay, err) {
        final sec = (delay.inMilliseconds / 1000).ceil();
        debugPrint(
          '[EdgeMapper] Custom AI ($modelId) transient error on attempt $attempt; retrying in ${sec}s: $err',
        );
        onStatusUpdate?.call(
          '$modelId busy — retrying in ${sec}s (attempt ${attempt + 1})...',
        );
      },
      action: (_) async {
        final resp = await _httpClient
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $apiKey',
              },
              body: bodyJson,
            )
            .timeout(_cloudRequestTimeout);

        final bodyText = utf8.decode(resp.bodyBytes, allowMalformed: true);
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw Exception('Custom AI error (${resp.statusCode}): $bodyText');
        }

        final decoded = jsonDecode(bodyText) as Map<String, dynamic>;
        final choices = decoded['choices'] as List? ?? const [];
        final text = choices.isNotEmpty
            ? (choices.first['message']?['content']?.toString() ?? '')
            : '';
        if (text.trim().isEmpty) {
          throw Exception('Custom AI returned empty response.');
        }

        return _parseStructuredOsmJson(
          text,
          aiSource: AiSource.customAi,
          headingDegrees: headingDegrees,
          hasGpsFix: hasGpsFix,
        );
      },
    );
    _lastUsedModel = modelId;
    return result;
  }

  static double? _toDouble(dynamic raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    return double.tryParse(raw.toString().trim());
  }

  /// Parses structured JSON output from Cloud AI or Gemini Nano 4, automatically
  /// modernizing deprecated OSM tags (e.g. folding `day_off` into `opening_hours`),
  /// stripping non-OSM local-only tags (`camera:direction` on non-camera POIs),
  /// and setting standard `source=survey`.
  static OsmInferenceResult parseStructuredOsmJson(
    String rawJson, {
    required AiSource aiSource,
    double? headingDegrees,
    bool hasGpsFix = true,
  }) {
    // Strip markdown code fences or prose around the JSON object
    var cleaned = rawJson
        .trim()
        .replaceFirst(RegExp(r'^```json\s*'), '')
        .replaceFirst(RegExp(r'^```\s*'), '')
        .replaceFirst(RegExp(r'\s*```$'), '')
        .trim();

    final firstBrace = cleaned.indexOf('{');
    final lastBrace = cleaned.lastIndexOf('}');
    if (firstBrace >= 0 && lastBrace > firstBrace) {
      cleaned = cleaned.substring(firstBrace, lastBrace + 1);
    }

    final rawDecoded = jsonDecode(cleaned);
    final Map<String, dynamic> decoded;
    if (rawDecoded is Map<String, dynamic>) {
      decoded = rawDecoded;
    } else if (rawDecoded is List &&
        rawDecoded.isNotEmpty &&
        rawDecoded.first is Map) {
      decoded = Map<String, dynamic>.from(rawDecoded.first as Map);
    } else {
      throw FormatException('Unexpected JSON shape from AI: $cleaned');
    }

    final rawParsedTags = <String, String>{};
    final rawTags = decoded['tags'];
    if (rawTags is List) {
      for (final item in rawTags) {
        if (item is Map) {
          final k = item['key']?.toString().trim() ?? '';
          final v = item['value']?.toString().trim() ?? '';
          if (k.isNotEmpty && v.isNotEmpty) {
            rawParsedTags[k] = v;
          }
        }
      }
    } else if (rawTags is Map) {
      for (final entry in rawTags.entries) {
        final k = entry.key.toString().trim();
        final v = entry.value?.toString().trim() ?? '';
        if (k.isNotEmpty && v.isNotEmpty) {
          rawParsedTags[k] = v;
        }
      }
    }

    // Strictly sanitize AI tags: modernize deprecated tags, auto-repair known
    // LLM hallucinations (e.g. fitness_equipment=monkey_bars -> fitness_station=horizontal_ladder),
    // strip local-only tags, and DROP any non-existent / undocumented OSM keys!
    final tags = OsmTagStandards.sanitizeAiTags(
      rawParsedTags,
      hasGpsFix: hasGpsFix,
    );

    // If the mapped feature itself is a surveillance/speed camera, preserve camera:direction
    if (headingDegrees != null &&
        OsmTagStandards.isCameraFeature(tags) &&
        !tags.containsKey('camera:direction')) {
      tags['camera:direction'] = '${headingDegrees.round() % 360}';
    }

    // Always use standard OSM survey source (never `GPS` or app name)
    tags['source'] = OsmTagStandards.recommendedSource(hasGpsFix: hasGpsFix);

    final candidates = <String, double>{};
    final rawCandidates = decoded['tagCandidates'];
    if (rawCandidates is List) {
      for (final item in rawCandidates) {
        if (item is Map) {
          final k = item['key']?.toString().trim() ?? '';
          final v = item['value']?.toString().trim() ?? '';
          final prob = _toDouble(item['probability']) ?? 0.65;
          if (k.isNotEmpty && v.isNotEmpty) {
            // Skip local-only, deprecated, or non-existent OSM keys in candidate suggestions
            if (OsmTagStandards.isLocalOnlyTag(k, tags)) continue;
            final sanitizedCand = OsmTagStandards.sanitizeAiTags(
              {k: v},
              hasGpsFix: hasGpsFix,
            );
            for (final mc in sanitizedCand.entries) {
              candidates['${mc.key}=${mc.value}'] = prob.clamp(0.05, 0.99);
            }
          }
        }
      }
    }
    // Also register primary tags as high-confidence candidates
    for (final e in tags.entries) {
      candidates.putIfAbsent('${e.key}=${e.value}', () => 0.92);
    }

    final offset =
        (_toDouble(decoded['estimatedOffsetMeters']) ?? 8.0).clamp(1.0, 120.0);

    return OsmInferenceResult(
      summary: decoded['summary']?.toString().trim().isNotEmpty == true
          ? decoded['summary'].toString().trim()
          : 'AI Mapped OSM Feature',
      fieldNotes: decoded['fieldNotes']?.toString().trim() ?? '',
      detectedLanguage: decoded['detectedLanguage']?.toString().trim() ?? 'en',
      osmType: decoded['osmType']?.toString().trim() ?? 'node',
      estimatedOffsetMeters: offset,
      distanceReasoning: decoded['distanceReasoning']?.toString().trim() ??
          'AI visual depth estimate (~${offset.toStringAsFixed(1)}m)',
      tags: tags,
      tagCandidates: candidates,
      aiSource: aiSource,
    );
  }

  OsmInferenceResult _parseStructuredOsmJson(
    String rawJson, {
    required AiSource aiSource,
    double? headingDegrees,
    bool hasGpsFix = true,
  }) =>
      parseStructuredOsmJson(
        rawJson,
        aiSource: aiSource,
        headingDegrees: headingDegrees,
        hasGpsFix: hasGpsFix,
      );

  Future<OsmInferenceResult> _analyzeOfflineWithMlKit({
    required String? photoPath,
    List<String>? photoPaths,
    required double latitude,
    required double longitude,
    double? headingDegrees,
    String? userHint,
    OsmPreset? preset,
    required bool isOnTrail,
    required String countryLang,
  }) async {
    final resolved = _resolvePhotoList(photoPath, photoPaths);
    final combinedLabels = <String>{};
    final combinedOcrLines = <String>[];
    double? maxHeightRatio;

    if (resolved.isEmpty) {
      final signals = await extractLocalVisionSignals(
        photoPath: null,
        enableJapaneseOcr: _enableJapaneseOcr,
        enableChineseOcr: _enableChineseOcr,
        enableKoreanOcr: _enableKoreanOcr,
      );
      combinedLabels.addAll(signals.imageLabels);
      combinedOcrLines.addAll(signals.ocrLines);
      maxHeightRatio = signals.maxOcrHeightRatio;
    } else {
      for (final p in resolved) {
        final signals = await extractLocalVisionSignals(
          photoPath: p,
          enableJapaneseOcr: _enableJapaneseOcr,
          enableChineseOcr: _enableChineseOcr,
          enableKoreanOcr: _enableKoreanOcr,
        );
        combinedLabels.addAll(signals.imageLabels);
        for (final line in signals.ocrLines) {
          if (!combinedOcrLines.contains(line)) combinedOcrLines.add(line);
        }
        final ratio = signals.maxOcrHeightRatio;
        if (ratio != null &&
            (maxHeightRatio == null || ratio > maxHeightRatio)) {
          maxHeightRatio = ratio;
        }
      }
    }

    return OsmHeuristicMapper.inferFromOnDeviceSignals(
      imageLabels: combinedLabels.toList(),
      ocrLines: combinedOcrLines,
      headingDegrees: headingDegrees,
      maxOcrHeightRatio: maxHeightRatio,
      userHint: userHint,
      preset: preset,
      isOnTrail: isOnTrail,
      countryLanguage: countryLang,
      primaryLanguage: prefs.primaryLanguage,
      confidentLanguages: prefs.confidentLanguages,
      preferredFallbackLanguage: prefs.secondaryLanguage,
      hasGpsFix: OsmTagStandards.hasValidGps(latitude, longitude),
    );
  }

  @override
  void dispose() {
    prefs.removeListener(notifyListeners);
    connectivity.removeListener(notifyListeners);
    super.dispose();
  }
}
