# Edge Mapper

Offline-first Flutter app (Android + Linux/Desktop Web) for fast **OpenStreetMap (OSM)** field mapping and route recording.

See [`GEMINI.md`](GEMINI.md) for architecture details.

## Run on Linux (Web App + On-Device Gemini Nano 4)

Edge Mapper runs directly in Chrome / Chromium on Linux via Flutter Web. On desktop Web, it defaults to **Local First (`Gemini Nano 4` → `Firebase AI`)** so analysis runs locally first and automatically falls back—or lets you escalate via **Cloud Enrich** / **Cloud Rewrite**—to **Firebase AI** online.

### 1. Launch the Web App on Linux (HTTPS recommended for OSM OAuth)
```bash
# Recommended: HTTPS on fixed port 8443 (auto-generates local TLS cert in .certs/)
# Gives you https://localhost:8443 and OSM OAuth Redirect URI:
#   https://localhost:8443/osm_callback.html
./scripts/run_web_https.sh

# Optional: trust the local dev cert in Chrome on Linux (no TLS warning)
./scripts/run_web_https.sh --trust

# Or launch Flutter's own dev Chrome window over HTTPS:
./scripts/run_web_https.sh --chrome
```

To build a static web bundle and serve it locally over HTTPS (e.g. for PWA install & OSM OAuth):
```bash
./flutter/bin/flutter build web --release
./scripts/run_web_https.sh --serve-build
# Open https://localhost:8443 in Chrome
```

### 2. Enable On-Device Gemini Nano 4 in Chrome (Linux)
1. Open `chrome://flags` in Google Chrome on Linux and enable:
   - `#optimization-guide-on-device-model` → **Enabled BypassPerfRequirement**
   - `#prompt-api-for-gemini-nano-multimodal-input` → **Enabled**
2. Restart Chrome.
3. Open `chrome://components` → click **Check for update** on **Optimization Guide On Device Model** (or inspect `chrome://on-device-internals`) so Gemini Nano downloads locally.
4. Reload Edge Mapper — the top status bar will show **`Nano 4 (+ Cloud)`**.
   - **Not happy with a local result?** Tap **Cloud Enrich** or **Cloud Rewrite** on any draft/record to run Firebase AI online and inspect a Before/After diff.
   - **Always want online Firebase AI?** Open **Settings** (top-right tune icon) → **AI Engine** → switch from **Local First (Nano 4 → Cloud)** to **Firebase AI**.

## Build for Android (Pixel 6a & Newer)

```bash
./flutter/bin/flutter pub get
./flutter/bin/flutter test
./flutter/bin/flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## Environment Variables & Security Vault

### 1. Environment Variables (`.env`)
All deploy-time and personal configuration—Firebase Web/Android keys & IDs, OpenStreetMap OAuth 2.0 defaults, AI Engine defaults, Sync Space, and Bitcoin developer donation methods—are supplied via environment variables (`--dart-define-from-file=.env`) rather than hardcoded in source code.

1. Copy `.env.example` to `.env` (gitignored) and populate whichever sections you use:
   - **App Identity & OSMF Compliance**: `APP_CONTACT_URL` (your public GitHub repo URL or contact email sent in HTTP `User-Agent` headers per OSMF Tile & Nominatim policies), `OFFLINE_TILE_URL_TEMPLATE` (optional `{z}/{x}/{y}` raster tile URL template for bulk offline pre-downloading; `tile.openstreetmap.org` is used for live interactive viewing only and excluded from bulk pre-downloads)
   - **Firebase**: `FIREBASE_PROJECT_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_AUTH_DOMAIN`, `FIREBASE_STORAGE_BUCKET`, `FIREBASE_MEASUREMENT_ID`, `FIREBASE_WEB_API_KEY`, `FIREBASE_WEB_APP_ID`, `FIREBASE_ANDROID_API_KEY`, `FIREBASE_ANDROID_APP_ID`, `ATTEST_GATE_BASE_URL` (optional self-hosted `attest-gate` server URL for Android Hardware Key Attestation App Check)
   - **OpenStreetMap OAuth 2.0 (Developer App Config)**: `OSM_CLIENT_ID`, `OSM_SANDBOX_CLIENT_ID`, `OSM_REDIRECT_URI` (optional override), `OSM_USE_SANDBOX`, `OSM_CHANGESET_COMMENT`
     - Register ONE public (non-confidential) OAuth 2.0 app on `https://www.openstreetmap.org/oauth2/applications/new` (and optionally one on `https://master.apis.dev.openstreetmap.org/oauth2/applications/new` for sandbox testing) with scopes `read_prefs`, `write_api`, `write_gpx` and Redirect URIs (one per line):
       - `edgemapper://oauth2/callback` (Android automatic deep-link return)
       - `https://localhost:8443/osm_callback.html` (Web dev automatic popup return; add your production web `/osm_callback.html` URL too)
     - End users never see or enter a Client ID or copy-paste authorization codes—they simply tap **Sign in with OpenStreetMap**, authorize, and return to the app automatically.
   - **AI Engine**: `GEMINI_API_KEY`, `GEMINI_MODEL`, `CUSTOM_AI_BASE_URL`, `CUSTOM_AI_API_KEY`, `CUSTOM_AI_MODEL`
   - **Sync & Explorer**: `FIREBASE_SYNC_SPACE_ID`, `EXPLORER_HANDLE`
   - **Bitcoin Donations**: `BTC_DONATION_URI`, `BTC_DONATION_P2TR_ADDRESS`, `BTC_DONATION_LIGHTNING_ADDRESS`, `BTC_DONATION_SILENT_PAYMENT_ADDRESS`, `BTC_DONATION_BOLT12_OFFER`, `BTC_DONATION_BTCPAY_URL`
2. Run or build with `--dart-define-from-file=.env` (`./scripts/run_web_https.sh` loads `.env` automatically when present):
```bash
./flutter/bin/flutter build apk --release --dart-define-from-file=.env
./flutter/bin/flutter build web --release --dart-define-from-file=.env
```
3. You can also export your active `.env` configuration from **Settings → Security Vault & Environment Variables** (secrets omitted by default unless you choose **Export Full .env**).

### 2. Encrypted Credentials Vault (OS Keystore & Passkey — Bitwarden / YubiKey)
Sensitive login data and keys entered inside the app (OSM OAuth tokens, Gemini/Custom AI keys, Firebase API keys, and sync codes) are **never stored in plaintext** in SQLite or `localStorage`:
- **Android**: Encrypted with hardware-backed **AndroidKeyStore AES-256-GCM** (StrongBox / Titan M2 on Pixel 6a with TEE fallback), with optional **OS Biometrics / Screen Lock** or **PBKDF2-SHA-256 (600k iterations) Passphrase** gating.
- **Web (HTTPS)**: Protected by default with a non-extractable WebCrypto AES-256-GCM key in IndexedDB, and upgradable in **Settings → Security Vault** to **W3C WebAuthn Passkey PRF (`hmac-secret`)**—manageable directly with **Bitwarden Passkeys**, **YubiKey 5 (USB/NFC)**, or OS Passkeys—or a Bitwarden-autofilled **Vault Passphrase**.

## License

Licensed under the [Apache License, Version 2.0](LICENSE) (`Apache-2.0`).

Map data retrieved from or contributed to OpenStreetMap is subject to the [Open Data Commons Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/).
