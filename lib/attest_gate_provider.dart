import 'dart:convert';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Result returned when explicitly requesting a hardware-attested token from the Android channel.
class AttestGateToken {
  const AttestGateToken({
    required this.token,
    required this.expireTimeMillis,
  });

  final String token;
  final int expireTimeMillis;

  DateTime get expiresAt =>
      DateTime.fromMillisecondsSinceEpoch(expireTimeMillis, isUtc: true);
}

/// Result of force-refreshing and inspecting the active App Check token.
class AttestGateDiagnostic {
  const AttestGateDiagnostic({
    required this.refreshed,
    required this.summary,
    this.tokenSub,
    this.expectedAppId,
    this.appIdMismatch = false,
  });

  final bool refreshed;
  final String summary;
  final String? tokenSub;
  final String? expectedAppId;
  final bool appIdMismatch;
}

/// Bridges Flutter to the native Android [AttestGateAppCheckProviderFactory] via a [MethodChannel].
///
/// Important FlutterFire behavior on Android:
/// - `FirebaseAppCheck.instance.activate(...)` only accepts built-in providers
///   (`playIntegrity`, `debug`, `recaptcha`) and will OVERWRITE any custom native
///   `AppCheckProviderFactory`.
/// - Meanwhile, `firebase_ai` discovers `FirebaseAppCheck` automatically via
///   `app.getService<FirebaseAppCheck>()`, which is only registered once
///   `FirebaseAppCheck.instance` has been accessed in Dart.
///
/// Therefore, on Android we:
/// 1. Install `AttestGateAppCheckProviderFactory` natively over the `MethodChannel`.
/// 2. Access `FirebaseAppCheck.instance` and enable token auto-refresh (WITHOUT calling
///    `activate()`), registering the service with `FirebaseApp` so `FirebaseAI.googleAI()`
///    and `FirebaseAI.agentPlatform()` automatically attach `X-Firebase-AppCheck` headers
///    minted by `attest-gate` without Google Play Services.
class AttestGateAppCheck {
  AttestGateAppCheck._();

  static const MethodChannel _channel =
      MethodChannel('dev.attestgate/app_check');

  static bool _isInitialized = false;
  static String? _configuredBaseUrl;
  static String? _lastInitError;
  static AttestGateToken? _cachedHeaderToken;
  static Future<String?>? _inFlightHeaderToken;
  static String? _lastHeaderTokenError;
  static DateTime? _rateLimitedUntil;

  static const Duration _headerTokenExpiryBuffer = Duration(seconds: 30);
  static const Duration _rateLimitBackoff = Duration(seconds: 15);

  static bool get isInitialized => _isInitialized;
  static String? get configuredBaseUrl => _configuredBaseUrl;
  static String? get lastInitError => _lastInitError;
  static String? get lastHeaderTokenError => _lastHeaderTokenError;

  @visibleForTesting
  static void clearHeaderTokenCache() {
    _cachedHeaderToken = null;
    _inFlightHeaderToken = null;
    _lastHeaderTokenError = null;
    _rateLimitedUntil = null;
  }

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get _isApple =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Initializes Firebase App Check using `attest-gate` hardware attestation on Android,
  /// and standard native providers on Apple / Web platforms.
  ///
  /// Call this right after `Firebase.initializeApp(...)` and BEFORE instantiating `FirebaseAI`.
  static Future<void> initialize({
    required String attestGateBaseUrl,
    String? webRecaptchaSiteKey,
  }) async {
    _lastInitError = null;
    if (_isAndroid) {
      final cleanBaseUrl = attestGateBaseUrl.trim();
      if (cleanBaseUrl.isEmpty) {
        _isInitialized = false;
        _configuredBaseUrl = null;
        _lastInitError =
            'ATTEST_GATE_BASE_URL is empty in this build (rebuild with --dart-define-from-file=.env).';
        debugPrint('[EdgeMapper] AttestGate App Check skipped: $_lastInitError');
        return;
      }

      try {
        // 1. Install AttestGateAppCheckProviderFactory natively into FirebaseAppCheck.getInstance().
        await _channel.invokeMethod<void>('installProvider', {
          'baseUrl': cleanBaseUrl,
        });

        // 2. Register FirebaseAppCheck on the default FirebaseApp so FirebaseAI automatically
        //    resolves it via app.getService<FirebaseAppCheck>() and sends X-Firebase-AppCheck.
        //    Do NOT call activate() on Android — that overwrites our custom provider factory.
        //    Keep auto-refresh DISABLED because 5-minute (299s) limited-use tokens sit inside
        //    Firebase Android SDK's 5-minute BUFFER_TIME_MILLIS and would otherwise spin in a
        //    tight background refresh loop, hitting HTTP 429 on attest-gate.
        await FirebaseAppCheck.instance.setTokenAutoRefreshEnabled(false);

        _isInitialized = true;
        _configuredBaseUrl = cleanBaseUrl;
        final serviceRegistered =
            Firebase.apps.isNotEmpty &&
            Firebase.app().getService<FirebaseAppCheck>() != null;
        debugPrint(
          '[EdgeMapper] AttestGate App Check initialized ($cleanBaseUrl, serviceRegistered=$serviceRegistered)',
        );
      } catch (e) {
        _isInitialized = false;
        _configuredBaseUrl = cleanBaseUrl;
        _lastInitError = e.toString();
        rethrow;
      }
      return;
    }

    if (kIsWeb) {
      final siteKey = webRecaptchaSiteKey?.trim() ?? '';
      if (siteKey.isEmpty) {
        // Without a reCAPTCHA site key on Web, leave App Check uninitialized so
        // FirebaseAI doesn't fail trying to call getToken() on an unactivated instance.
        return;
      }
      await FirebaseAppCheck.instance.activate(
        providerWeb: ReCaptchaV3Provider(siteKey),
      );
      _isInitialized = true;
      return;
    }

    if (_isApple) {
      await FirebaseAppCheck.instance.activate(
        providerApple: const AppleAppAttestWithDeviceCheckFallbackProvider(),
      );
      _isInitialized = true;
    }
  }

  /// Safely decodes ONLY the non-secret payload claims (e.g. `sub`, `aud`, `iss`, `exp`)
  /// of a JWT so callers can diagnose App ID or expiry mismatches without logging tokens.
  static Map<String, dynamic>? inspectJwtPayload(String token) {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final map = jsonDecode(decoded);
      return map is Map<String, dynamic> ? map : null;
    } catch (_) {
      return null;
    }
  }

  /// Forces a fresh App Check token exchange (bypassing any stale cached token in
  /// SharedPreferences) and validates non-secret JWT claims against the active FirebaseApp.
  ///
  /// When [limitedUse] is `true`, exercises `FirebaseAppCheck.getLimitedUseToken()` —
  /// the exact Replay-Protection path used by `FirebaseAI(..., useLimitedUseAppCheckTokens: true)`.
  static Future<AttestGateDiagnostic> diagnoseAndRefreshToken({
    bool limitedUse = false,
  }) async {
    if (_isAndroid && !_isInitialized) {
      final reason = _lastInitError ??
          'AttestGate App Check was not initialized (check ATTEST_GATE_BASE_URL in .env).';
      return AttestGateDiagnostic(refreshed: false, summary: reason);
    }

    String? expectedAppId;
    if (Firebase.apps.isNotEmpty) {
      expectedAppId = Firebase.app().options.appId;
    }

    try {
      String rawToken;
      int expireTimeMillis;
      if (limitedUse) {
        final svc = Firebase.apps.isNotEmpty
            ? Firebase.app().getService<FirebaseAppCheck>()
            : null;
        if (svc == null) {
          throw StateError(
            'FirebaseAppCheck service is not registered on the default FirebaseApp.',
          );
        }
        rawToken = await svc.getLimitedUseToken();
        if (rawToken.isEmpty) {
          throw StateError('FirebaseAppCheck.getLimitedUseToken() returned empty token');
        }
        final expClaim = inspectJwtPayload(rawToken)?['exp'];
        expireTimeMillis = expClaim is num
            ? expClaim.toInt() * 1000
            : DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch;
      } else {
        final tokenResult = await getToken(forceRefresh: true);
        rawToken = tokenResult.token;
        expireTimeMillis = tokenResult.expireTimeMillis;
      }

      final claims = inspectJwtPayload(rawToken);
      final sub = claims?['sub']?.toString();
      final aud = claims?['aud']?.toString();
      final provider = claims?['provider']?.toString();
      final jti = claims?['jti']?.toString();
      final hasLu = claims?.containsKey('lu') == true;
      final ttlSec = DateTime.fromMillisecondsSinceEpoch(
        expireTimeMillis,
        isUtc: true,
      ).difference(DateTime.now().toUtc()).inSeconds;

      final appIdMismatch = expectedAppId != null &&
          expectedAppId.isNotEmpty &&
          sub != null &&
          sub.isNotEmpty &&
          sub != expectedAppId;

      final modeLabel = limitedUse ? 'limited-use token' : 'token';
      final summary = appIdMismatch
          ? 'AttestGate minted a $modeLabel for appId "$sub", but this app is configured with "$expectedAppId". Update attest-gate FIREBASE_APP_ID to match.'
          : 'AttestGate minted $modeLabel (sub=${sub ?? 'unknown'}, aud=${aud ?? 'unknown'}, provider=${provider ?? 'unknown'}, lu=$hasLu, jti=${jti ?? 'none'}, ttl=${ttlSec}s).';
      debugPrint('[EdgeMapper] $summary');
      return AttestGateDiagnostic(
        refreshed: true,
        summary: summary,
        tokenSub: sub,
        expectedAppId: expectedAppId,
        appIdMismatch: appIdMismatch,
      );
    } catch (e) {
      final summary = 'AttestGate token refresh failed: $e';
      debugPrint('[EdgeMapper] $summary');
      return AttestGateDiagnostic(
        refreshed: false,
        summary: summary,
        expectedAppId: expectedAppId,
      );
    }
  }

  /// Returns an App Check token suitable for attaching as the `X-Firebase-AppCheck`
  /// header on direct Firebase REST calls (e.g. Firestore REST sync, model listing),
  /// or `null` if App Check is not initialized on this platform.
  ///
  /// When [limitedUse] is `true`, fetches a fresh single-use limited-use token via
  /// `FirebaseAppCheck.getLimitedUseToken()` (for Replay-Protected endpoints).
  ///
  /// When [limitedUse] is `false` on Android, caches the minted token in memory
  /// until 30 seconds before expiry — avoiding Android Firebase SDK's 5-minute
  /// `BUFFER_TIME_MILLIS` which otherwise re-attests on every single Firestore
  /// request when `attest-gate` issues 5-minute (299s) limited-use tokens.
  static Future<String?> getHeaderToken({
    bool forceRefresh = false,
    bool limitedUse = false,
  }) async {
    if (Firebase.apps.isEmpty) return null;
    if (_isAndroid && !_isInitialized) return null;

    if (limitedUse) {
      try {
        final svc = Firebase.app().getService<FirebaseAppCheck>();
        if (svc == null) return null;
        final token = await svc.getLimitedUseToken();
        _lastHeaderTokenError = null;
        return token.isNotEmpty ? token : null;
      } catch (e) {
        _lastHeaderTokenError = e.toString();
        debugPrint('[EdgeMapper] App Check limited-use token fetch failed: $e');
        return null;
      }
    }

    if (_isAndroid) {
      final now = DateTime.now().toUtc();
      if (!forceRefresh &&
          _cachedHeaderToken != null &&
          _cachedHeaderToken!.token.isNotEmpty &&
          _cachedHeaderToken!.expiresAt
              .isAfter(now.add(_headerTokenExpiryBuffer))) {
        _lastHeaderTokenError = null;
        return _cachedHeaderToken!.token;
      }
      if (_rateLimitedUntil != null && now.isBefore(_rateLimitedUntil!)) {
        final remainSec = _rateLimitedUntil!.difference(now).inSeconds + 1;
        _lastHeaderTokenError =
            'attest-gate rate-limited (HTTP 429); cooling down for ${remainSec}s.';
        return null;
      }
      if (!forceRefresh && _inFlightHeaderToken != null) {
        return _inFlightHeaderToken;
      }
      final future = () async {
        try {
          final token = await getToken(forceRefresh: true);
          if (token.token.isNotEmpty) {
            _cachedHeaderToken = token;
            _lastHeaderTokenError = null;
            _rateLimitedUntil = null;
            return token.token;
          }
          return null;
        } catch (e) {
          final msg = e.toString();
          _lastHeaderTokenError = msg;
          if (msg.contains('429') ||
              msg.toLowerCase().contains('rate_limited')) {
            _rateLimitedUntil = DateTime.now().toUtc().add(_rateLimitBackoff);
          }
          debugPrint('[EdgeMapper] App Check header token fetch failed: $e');
          return null;
        }
      }();
      _inFlightHeaderToken = future;
      try {
        return await future;
      } finally {
        if (identical(_inFlightHeaderToken, future)) {
          _inFlightHeaderToken = null;
        }
      }
    }
    try {
      final svc = Firebase.app().getService<FirebaseAppCheck>();
      if (svc == null) return null;
      final token = await svc.getToken(forceRefresh);
      _lastHeaderTokenError = null;
      return (token != null && token.isNotEmpty) ? token : null;
    } catch (e) {
      _lastHeaderTokenError = e.toString();
      debugPrint('[EdgeMapper] App Check header token fetch failed: $e');
      return null;
    }
  }

  /// Optionally forces a fresh hardware attestation exchange and returns the resulting App Check JWT.
  static Future<AttestGateToken> getToken({bool forceRefresh = false}) async {
    if (_isAndroid) {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getToken',
        {'forceRefresh': forceRefresh},
      );
      if (result == null) {
        throw StateError('Android attest-gate channel returned null token');
      }
      return AttestGateToken(
        token: result['token'] as String,
        expireTimeMillis: result['expireTimeMillis'] as int,
      );
    }

    final token = await FirebaseAppCheck.instance.getToken(forceRefresh);
    if (token == null) {
      throw StateError('FirebaseAppCheck returned null token');
    }
    return AttestGateToken(
      token: token,
      expireTimeMillis: DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );
  }
}
