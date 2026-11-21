import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';

/// Safely initializes Firebase from environment variables (`--dart-define-from-file=.env`)
/// or native Android `google-services.json`, while allowing 100% offline boot
/// when Firebase is not configured.
class FirebaseBootstrap {
  static bool _isConfigured = false;
  static String _statusMessage = 'Firebase not configured.';

  static bool get isConfigured => _isConfigured;
  static String get statusMessage => _statusMessage;

  static Future<void> init() async {
    try {
      if (Firebase.apps.isEmpty) {
        final envOptions = DefaultFirebaseOptions.currentPlatformOrNull;
        if (envOptions != null) {
          await Firebase.initializeApp(options: envOptions);
        } else if (!kIsWeb) {
          // On Android, falls back to native google-services.json if present
          await Firebase.initializeApp();
        } else {
          _isConfigured = false;
          _statusMessage =
              'Firebase env vars not set (pass --dart-define-from-file=.env).';
          return;
        }
      }
      _isConfigured = true;
      _statusMessage = 'Firebase AI ready.';
    } catch (e) {
      _isConfigured = false;
      _statusMessage = 'Firebase offline / unconfigured.';
      debugPrint('[EdgeMapper] Firebase bootstrap skipped: $e');
    }
  }
}
