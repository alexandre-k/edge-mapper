import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

const String _oauthStorageKey = 'edge_mapper_osm_oauth_result';

bool _isAllowedExternalUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return false;
  switch (uri.scheme.toLowerCase()) {
    case 'https':
    case 'bitcoin':
    case 'lightning':
      return true;
    case 'http':
      final host = uri.host.toLowerCase();
      return host == 'localhost' ||
          host == '127.0.0.1' ||
          host == '::1' ||
          host.endsWith('.onion');
    default:
      return false;
  }
}

Future<bool> openExternalUrlImpl(String url) async {
  if (!_isAllowedExternalUrl(url)) return false;
  final opened = web.window.open(url.trim(), '_blank', 'noopener,noreferrer');
  return opened != null;
}

String defaultOsmRedirectUriImpl() {
  final origin = web.window.location.origin;
  if (origin.isEmpty || origin == 'null') {
    return 'urn:ietf:wg:oauth:2.0:oob';
  }
  return '$origin/osm_callback.html';
}

bool get supportsOAuthPopupImpl => true;

void Function()? _activeWebCancel;

Future<String?> launchOsmOAuthPopupImpl({
  required String authorizeUrl,
  required String expectedState,
}) async {
  _activeWebCancel?.call();
  try {
    web.window.localStorage.removeItem(_oauthStorageKey);
  } catch (_) {}

  final popup = web.window.open(
    authorizeUrl,
    'edge_mapper_osm_oauth',
    'width=620,height=740,menubar=no,toolbar=no,status=no',
  );
  if (popup == null) {
    throw Exception(
      'Popup blocked by browser. Please allow popups for this site and tap Sign in again.',
    );
  }

  final completer = Completer<String?>();
  Timer? pollTimer;
  Timer? timeoutTimer;
  late final JSFunction jsMessageListener;

  void finish(String? code, [Object? error]) {
    if (completer.isCompleted) return;
    _activeWebCancel = null;
    pollTimer?.cancel();
    timeoutTimer?.cancel();
    web.window.removeEventListener('message', jsMessageListener);
    try {
      web.window.localStorage.removeItem(_oauthStorageKey);
    } catch (_) {}
    if (error != null) {
      completer.completeError(error);
    } else {
      completer.complete(code);
    }
  }

  _activeWebCancel = () => finish(null);

  void handlePayload(Map<String, dynamic> data) {
    if (data['type'] != 'edge_mapper_osm_oauth') return;
    final state = data['state']?.toString() ?? '';
    if (expectedState.isEmpty || state != expectedState) return;
    final err = data['error']?.toString() ?? '';
    if (err.isNotEmpty) {
      final desc = data['errorDescription']?.toString() ?? err;
      finish(null, Exception('OSM authorization cancelled: $desc'));
      return;
    }
    final code = data['code']?.toString() ?? '';
    if (code.isNotEmpty) {
      finish(code);
    }
  }

  jsMessageListener = ((web.MessageEvent event) {
    if (event.origin != web.window.location.origin) return;
    try {
      final raw = event.data.dartify();
      if (raw is Map) {
        handlePayload(
          raw.map((k, v) => MapEntry(k.toString(), v)),
        );
      }
    } catch (_) {}
  }).toJS;

  web.window.addEventListener('message', jsMessageListener);

  pollTimer = Timer.periodic(const Duration(milliseconds: 450), (_) {
    try {
      final stored = web.window.localStorage.getItem(_oauthStorageKey);
      if (stored != null && stored.isNotEmpty) {
        final decoded = jsonDecode(stored);
        if (decoded is Map<String, dynamic>) {
          handlePayload(decoded);
          return;
        }
      }
    } catch (_) {}

    if (popup.closed) {
      // Give postMessage/localStorage one brief moment before treating as closed
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (!completer.isCompleted) {
          finish(null);
        }
      });
    }
  });

  timeoutTimer = Timer(const Duration(minutes: 4), () {
    finish(null, Exception('OpenStreetMap sign-in timed out.'));
  });

  return completer.future;
}

void cancelOsmOAuthFlowImpl() {
  _activeWebCancel?.call();
}
