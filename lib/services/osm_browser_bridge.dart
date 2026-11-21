import 'osm_browser_bridge_io.dart'
    if (dart.library.js_interop) 'osm_browser_bridge_web.dart';

/// Opens [url] in the system browser (Android) or a new browser tab (Web).
Future<bool> openExternalUrl(String url) => openExternalUrlImpl(url);

/// Returns the automatic OAuth 2.0 Redirect URI for the current platform:
/// - Web: `<origin>/osm_callback.html`
/// - Android / IO: `edgemapper://oauth2/callback`
String defaultOsmRedirectUri() => defaultOsmRedirectUriImpl();

/// True when automatic OAuth 2.0 callback capture is supported (Web popup +
/// Android custom URI scheme `edgemapper://oauth2/callback`).
bool get supportsOAuthPopup => supportsOAuthPopupImpl;

/// Opens the OAuth 2.0 authorize URL (popup on Web, browser + deep-link
/// redirect on Android) and automatically returns the authorization code.
/// Returns `null` if cancelled by the user.
Future<String?> launchOsmOAuthPopup({
  required String authorizeUrl,
  required String expectedState,
}) =>
    launchOsmOAuthPopupImpl(
      authorizeUrl: authorizeUrl,
      expectedState: expectedState,
    );

/// Cancels any active pending automatic OAuth callback wait.
void cancelOsmOAuthFlow() => cancelOsmOAuthFlowImpl();
