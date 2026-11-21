import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _browserChannel =
    MethodChannel('com.edgemapper.app/browser');

const String _androidOsmCallbackUri = 'edgemapper://oauth2/callback';

bool _channelHandlerRegistered = false;
Completer<String?>? _activeOAuthCompleter;
String? _activeExpectedState;
Timer? _activeOAuthTimeout;

void _ensureCallbackHandler() {
  if (_channelHandlerRegistered) return;
  _channelHandlerRegistered = true;
  _browserChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'onOAuthCallback':
        final url = call.arguments?.toString() ?? '';
        _completeFromCallbackUrl(url);
        return true;
      case 'onOAuthCancelled':
        _finishOAuth(null);
        return true;
    }
    return null;
  });
}

void _finishOAuth(String? code, [Object? error]) {
  final completer = _activeOAuthCompleter;
  _activeOAuthCompleter = null;
  _activeExpectedState = null;
  _activeOAuthTimeout?.cancel();
  _activeOAuthTimeout = null;
  if (completer == null || completer.isCompleted) return;
  if (error != null) {
    completer.completeError(error);
  } else {
    completer.complete(code);
  }
}

void _completeFromCallbackUrl(String callbackUrl) {
  final expectedState = _activeExpectedState;
  if (_activeOAuthCompleter == null || _activeOAuthCompleter!.isCompleted) {
    return;
  }
  final uri = Uri.tryParse(callbackUrl.trim());
  if (uri == null) {
    _finishOAuth(
      null,
      Exception('Invalid OpenStreetMap OAuth callback URL received.'),
    );
    return;
  }
  final err = uri.queryParameters['error']?.trim() ?? '';
  if (err.isNotEmpty) {
    final desc = uri.queryParameters['error_description']?.trim();
    _finishOAuth(
      null,
      Exception(
        'OpenStreetMap authorization cancelled: ${(desc != null && desc.isNotEmpty) ? desc : err}',
      ),
    );
    return;
  }
  final returnedState = uri.queryParameters['state']?.trim() ?? '';
  if (expectedState != null &&
      expectedState.isNotEmpty &&
      returnedState != expectedState) {
    _finishOAuth(
      null,
      StateError(
        'OpenStreetMap sign-in state mismatch. Please try signing in again.',
      ),
    );
    return;
  }
  final code = uri.queryParameters['code']?.trim() ?? '';
  if (code.isEmpty) {
    _finishOAuth(
      null,
      Exception('OpenStreetMap did not return an authorization code.'),
    );
    return;
  }
  _finishOAuth(code);
}

Future<bool> openExternalUrlImpl(String url) async {
  try {
    final launched = await _browserChannel.invokeMethod<bool>(
      'openUrl',
      {'url': url},
    );
    return launched == true;
  } catch (e) {
    debugPrint('[EdgeMapper] openExternalUrl failed: $e');
    return false;
  }
}

String defaultOsmRedirectUriImpl() => _androidOsmCallbackUri;

bool get supportsOAuthPopupImpl => true;

Future<String?> launchOsmOAuthPopupImpl({
  required String authorizeUrl,
  required String expectedState,
}) async {
  _ensureCallbackHandler();

  // Cancel any previous incomplete wait cleanly.
  _finishOAuth(null);

  final completer = Completer<String?>();
  _activeOAuthCompleter = completer;
  _activeExpectedState = expectedState;

  bool launched = false;
  try {
    final ok = await _browserChannel.invokeMethod<bool>(
      'launchOAuth',
      {'url': authorizeUrl},
    );
    launched = ok == true;
  } catch (e) {
    debugPrint('[EdgeMapper] launchOAuth failed: $e');
    launched = false;
  }

  if (!launched) {
    _finishOAuth(
      null,
      Exception('Could not open browser for OpenStreetMap sign-in.'),
    );
    return completer.future;
  }

  _activeOAuthTimeout = Timer(const Duration(minutes: 5), () {
    _finishOAuth(
      null,
      Exception('OpenStreetMap sign-in timed out. Please try again.'),
    );
  });

  return completer.future;
}

void cancelOsmOAuthFlowImpl() {
  _finishOAuth(null);
  try {
    _browserChannel.invokeMethod<bool>('cancelOAuth');
  } catch (_) {}
}
