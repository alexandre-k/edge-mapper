import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'password_manager_bridge.dart';

@JS('window.edgeMapperPasswordManager.saveSyncKey')
external JSPromise<JSString> _webSaveSyncKey(
  JSString accountLabel,
  JSString syncKey,
);

@JS('window.edgeMapperPasswordManager.retrieveSyncKey')
external JSPromise<JSString> _webRetrieveSyncKey();

Future<PasswordManagerSaveResult> saveSyncKeyImpl({
  required String accountLabel,
  required String syncKey,
}) async {
  bool prompted = false;
  bool saved = false;
  String? detail;

  try {
    final raw = (await _webSaveSyncKey(
      accountLabel.toJS,
      syncKey.toJS,
    ).toDart)
        .toDart;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    prompted = decoded['prompted'] == true;
    saved = decoded['credentialApi'] == true;
    detail = decoded['message']?.toString();
  } catch (e) {
    debugPrint('[EdgeMapper] Web password manager save skipped: $e');
  }

  try {
    TextInput.finishAutofillContext(shouldSave: true);
  } catch (_) {}

  final message = detail ??
      (prompted
          ? 'Sent directly to your password manager.'
          : 'No browser password manager detected. Install Bitwarden or KeePassXC-Browser, or use Reveal / QR.');

  return PasswordManagerSaveResult(
    promptedPasswordManager: prompted,
    savedDirectly: saved,
    message: message,
  );
}

Future<bool> copySecretToClipboardImpl(String secret) async {
  try {
    await Clipboard.setData(ClipboardData(text: secret));
    return true;
  } catch (_) {
    return false;
  }
}

Future<String?> retrieveSavedSyncKeyImpl() async {
  try {
    final raw = (await _webRetrieveSyncKey().toDart).toDart;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final key = decoded['syncKey']?.toString().trim();
    if (key != null && key.isNotEmpty) return key;
  } catch (e) {
    debugPrint('[EdgeMapper] Web password manager retrieve skipped: $e');
  }
  return null;
}
