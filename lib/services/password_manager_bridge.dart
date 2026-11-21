import 'password_manager_bridge_io.dart'
    if (dart.library.js_interop) 'password_manager_bridge_web.dart';

/// Result of invoking Bitwarden or the system/browser password manager directly
/// (Android Credential Manager / Autofill Service, W3C Credential Management API,
/// and browser extension form-capture) WITHOUT touching the clipboard.
class PasswordManagerSaveResult {
  /// Whether a native password manager / Credential Manager save prompt was dispatched.
  final bool promptedPasswordManager;

  /// Whether the credential provider explicitly confirmed the save completed.
  final bool savedDirectly;

  /// Human-readable status summary for the UI.
  final String message;

  const PasswordManagerSaveResult({
    required this.promptedPasswordManager,
    required this.savedDirectly,
    required this.message,
  });
}

/// Cross-platform bridge that hands a generated Private Sync Key (`emk1-...`)
/// directly to Bitwarden or any local/OS password manager (Android 14+ native
/// `CredentialManager`, Android `AutofillManager`, Web `PasswordCredential`, and
/// browser extension form-capture) without copying to the clipboard, and can
/// retrieve saved keys directly back on recovery.
class PasswordManagerBridge {
  static Future<PasswordManagerSaveResult> saveSyncKey({
    required String accountLabel,
    required String syncKey,
  }) {
    return saveSyncKeyImpl(
      accountLabel: accountLabel,
      syncKey: syncKey,
    );
  }

  /// Explicit manual clipboard copy (only called when the user specifically taps
  /// Copy Key), marked `EXTRA_IS_SENSITIVE` on Android 13+.
  static Future<bool> copySecretToClipboard(String secret) {
    return copySecretToClipboardImpl(secret);
  }

  /// Invokes Bitwarden / Android Credential Manager / browser password manager
  /// directly to retrieve a previously saved Sync Key without using the clipboard.
  static Future<String?> retrieveSavedSyncKey() {
    return retrieveSavedSyncKeyImpl();
  }
}
