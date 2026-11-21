// Environment-driven FirebaseOptions — zero hardcoded API keys in source control.
// Configure via `.env` and `--dart-define-from-file=.env` (see `.env.example`).
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

import 'services/app_env_config.dart';

class DefaultFirebaseOptions {
  /// Returns true when the required Firebase environment variables are present
  /// for the active platform.
  static bool get isConfiguredForCurrentPlatform {
    if (kIsWeb) return AppEnvConfig.hasFirebaseWebConfig;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AppEnvConfig.hasFirebaseAndroidConfig;
    }
    return false;
  }

  static FirebaseOptions? get currentPlatformOrNull {
    if (kIsWeb) {
      return AppEnvConfig.hasFirebaseWebConfig ? web : null;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AppEnvConfig.hasFirebaseAndroidConfig ? android : null;
    }
    return null;
  }

  static FirebaseOptions get currentPlatform {
    final opts = currentPlatformOrNull;
    if (opts != null) return opts;
    throw UnsupportedError(
      'Firebase environment variables are not configured for this platform. '
      'Pass --dart-define-from-file=.env (see .env.example) or place android/app/google-services.json.',
    );
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: AppEnvConfig.firebaseWebApiKey,
    appId: AppEnvConfig.firebaseWebAppId,
    messagingSenderId: AppEnvConfig.firebaseMessagingSenderId,
    projectId: AppEnvConfig.firebaseProjectId,
    authDomain: AppEnvConfig.firebaseAuthDomain,
    storageBucket: AppEnvConfig.firebaseStorageBucket,
    measurementId: AppEnvConfig.firebaseMeasurementId,
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: AppEnvConfig.firebaseAndroidApiKey,
    appId: AppEnvConfig.firebaseAndroidAppId,
    messagingSenderId: AppEnvConfig.firebaseMessagingSenderId,
    projectId: AppEnvConfig.firebaseProjectId,
    storageBucket: AppEnvConfig.firebaseStorageBucket,
  );
}
