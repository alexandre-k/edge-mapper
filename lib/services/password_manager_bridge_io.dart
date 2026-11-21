import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'password_manager_bridge.dart';

const _pmChannel = MethodChannel('com.edgemapper.app/password_manager');

Future<PasswordManagerSaveResult> saveSyncKeyImpl({
  required String accountLabel,
  required String syncKey,
}) async {
  bool prompted = false;
  bool saved = false;
  String? detail;

  // 1. Invoke native Android CredentialManager.createCredential() (Android 14+)
  //    or AutofillManager.commit() (Android 8-13) directly — NEVER copies to clipboard.
  try {
    final res = await _pmChannel.invokeMapMethod<String, dynamic>(
      'saveSyncKey',
      {
        'label': accountLabel,
        'syncKey': syncKey,
      },
    );
    if (res != null) {
      prompted = res['prompted'] == true;
      saved = res['saved'] == true;
      detail = res['message']?.toString();
    }
  } on MissingPluginException {
    // Non-Android / unit-test runtime.
  } catch (e) {
    debugPrint('[EdgeMapper] Native password manager save skipped: $e');
  }

  // 2. Also commit any active Flutter AutofillGroup context.
  try {
    TextInput.finishAutofillContext(shouldSave: true);
  } catch (_) {}

  final message = detail ??
      (saved
          ? 'Saved directly to Bitwarden / Android Credential Manager.'
          : prompted
              ? 'Sent directly to your password manager (Bitwarden / Autofill).'
              : 'Enable Bitwarden (or your password manager) in Android Settings → Passwords, passkeys & accounts to save directly.');

  return PasswordManagerSaveResult(
    promptedPasswordManager: prompted,
    savedDirectly: saved,
    message: message,
  );
}

Future<bool> copySecretToClipboardImpl(String secret) async {
  try {
    final ok = await _pmChannel.invokeMethod<bool>(
      'copySensitive',
      {'text': secret},
    );
    if (ok == true) return true;
  } catch (_) {}

  try {
    await Clipboard.setData(ClipboardData(text: secret));
    return true;
  } catch (_) {
    return false;
  }
}

Future<String?> retrieveSavedSyncKeyImpl() async {
  try {
    final key = await _pmChannel.invokeMethod<String>('retrieveSyncKey');
    final trimmed = key?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
  } on MissingPluginException {
    // Non-Android / unit-test runtime.
  } catch (e) {
    debugPrint('[EdgeMapper] Native password manager retrieve skipped: $e');
  }
  return null;
}
