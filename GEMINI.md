# Edge Mapper — Project Context (`GEMINI.md`)

> Read this file first in any new conversation to restore full architectural context without scanning the whole repo.

## 1. Mission & Core Requirements
**Edge Mapper** is an offline-first, gamified Flutter Android app for fast field mapping and general route recording (walks, park strolls, hikes, cycling, etc.) for **OpenStreetMap (OSM)**, designed to run reliably on a **Google Pixel 6a (Tensor G1, 6GB RAM)** as well as newer Android devices.

Core capabilities:
1. **Street, Park & Trail Snapshot Mapping**: Capture a photo along with live GPS coordinates (lat/lon/altitude/accuracy), GPS quality/anomaly monitoring, and compass heading (azimuth degrees + cardinal direction).
2. **Improved Visual Distance & Spatial Extrapolation**: Estimate the mapped feature's distance using AI visual depth cues (online) or OCR bounding-box height scale + scene labels (offline), with reasoning and an interactive distance slider.
3. **Dual-Language OSM Tags**: User selects confident languages & a preferred fallback language (default English). Generates `name`, `name:<country_lang>`, and `name:<user_lang>` tags.
4. **Smart Probability-Ranked OSM Tag Selector**: Adding tags uses a searchable catalog of 150+ real OSM tags ranked by probability of matching the picture's visual/text cues (no plain free-text box required).
5. **AI Enrichment (Merge) vs Full AI Overwrite + Before/After Diff Review**: Users can either refine/merge tags OR let AI overwrite fields (tags, summary, distance) — ALWAYS reviewing a Before/After diff with per-field/per-tag checkboxes before confirming.
6. **General Activity Route Recorder + Live Offline OSM Map + External Ham Radio GPS Import**: Record city walks, park strolls, mountain hikes, nature walks, cycling, accessible routes, etc., OR import GPS tracks recorded on external Ham radios (NMEA-0183 from Icom/Yaesu/Kenwood, APRS TNC2 / Mic-E / Base-91 compressed packets with callsign filtering, GPX, KML, and CSV from Anytone/aprs.fi/APRSdroid), with full searchable OSM `highway`/`surface`/`smoothness`/`sac_scale`/`wheelchair`/`lit` tags, live OpenStreetMap tile map with persistent offline disk tile cache & area pre-downloader, auto-guessing route name/activity from location online (and deferred when returning online), and a dedicated `TrailDetailScreen` to review & clean up any recorded or imported route.
7. **GPS Anomaly Detection**: Automatically detects & advertises Null Island `(0,0)`, mocked GPS, poor accuracy, stale readings, and sudden teleport jumps.
8. **Selectable Cloud AI Models & Personal API Keys**: Supports Firebase AI Logic (selectable `gemini-3.5-flash-lite`, `gemini-3.8-flash`, `gemini-4-hydrogen`, or custom model), User's Personal Gemini API Key (with dynamic model discovery), and optional OpenAI-compatible Vision APIs.
9. **Direct OpenStreetMap Publishing (OAuth 2.0 PKCE + API v0.6)**: Developer configures the app's OAuth 2.0 Client ID once via `.env` (`OSM_CLIENT_ID` / `OSM_SANDBOX_CLIENT_ID`), hidden from end users. Users simply tap **Sign in with OpenStreetMap** and authorize — authorization codes are captured automatically via popup callback (`<origin>/osm_callback.html`) on Web and custom URI scheme deep link (`edgemapper://oauth2/callback` in `AndroidManifest.xml` + `MainActivity.kt`) on Android against **Live OpenStreetMap** (`api.openstreetmap.org`) or **OSM Dev Sandbox** (`master.apis.dev.openstreetmap.org`), then validate & preview XML and push changesets (`osmChange` nodes/ways) or GPX traces (`/api/0.6/gpx/create`) directly.
10. **Zero-Knowledge E2EE Firebase Cloud Storage & Selective Sharing**: Client-side envelope encryption (`XChaCha20-Poly1305` with 256-bit `Item_DEK`, 192-bit nonce, and document-path AAD `items/{itemId}|v1`), per-user `X25519` keypairs with ephemeral sealed-box `Item_DEK` wrapping (`recipients`), zero-config cross-device root unlock via WebAuthn `prf` (`app-vault-root-v1` → `HKDF-SHA256`), Argon2id (64 MB / 3 iterations) Recovery Key fallback (`users/{uid}/security/keyring`), Android Keystore `AES-256-GCM` (`setRandomizedEncryptionRequired(true)`) local `User_Priv` caching (`com.edgemapper.app/e2ee_keystore`), key rotation on revocation, and `#k=` fragment link sharing (`shares/{shareId}`).
11. **Joyful, Gamified RPG Experience & Explorer Guild**: Procedural unique RPG Explorer Avatar that evolves gear, funny XP nicknames (e.g. "Vasco da Gama", "Sidewalk Magellan"), RPG stats/characteristics, Explorer League Leaderboard with rank incentives, streaks, and unlockable badges.
12. **Pre-Upload OSM Duplicate Detection**: Automatically queries Overpass API + local batch before uploading to OpenStreetMap, advertises duplicate POIs & overlapping tracks, and keeps only non-duplicate items.
13. **Multi-Photo Capture & AI Feature Merging**: Snap sequential angles or pick multiple photos from the gallery; AI analyzes and merges all images into one comprehensive POI tag set.
14. **Bitcoin Developer Donations & Social Mapping Bounties**: Environment-variable-driven (`--dart-define-from-file=.env`) developer donations supporting Taproot P2TR (`bc1p...`), BIP-352 Silent Payments (`sp1...` via BIP-321 `?sp=`), Lightning Address, BOLT 12 / BIP-321 `bitcoin:` URIs, and self-hosted BTCPay Server checkout with offline QR codes (ISO/IEC 18004 V1–V20) & wallet launcher, plus social mapping bounty announcements paid in Bitcoin.
15. **Privacy-Preserving Cryptographic Location Proofs**: Generates salted SHA-256 photo/spatial commitments + coarse Geohash area + anti-spoof GPS telemetry signed via Android Hardware Keystore ECDSA P-256 (`MainActivity.kt`) — independently verifiable without sharing the raw photo.
16. **Centralized Environment Config & OS / Passkey Encrypted Secrets Vault**: All Firebase keys/IDs, OSM OAuth defaults, AI defaults, sync defaults, and Bitcoin donation rails are read strictly from environment variables (`AppEnvConfig`, `.env` / `--dart-define-from-file=.env`) with an in-app `.env` exporter. All sensitive credentials (OSM OAuth tokens, Gemini/Custom AI keys, Firebase API keys, sync passphrases) are encrypted at rest via `SecureVaultService`: hardware-backed `AndroidKeyStore` AES-256-GCM (StrongBox/TEE) + optional Android OS Biometric/Screen Lock on Android, and W3C WebAuthn Passkey PRF (`hmac-secret` for Bitwarden / YubiKey 5 / OS Passkeys) + PBKDF2-SHA-256 (600k iterations) + non-extractable WebCrypto AES-256-GCM on Web.

## 2. AI Architecture & Cross-Platform Reality
**Android (Pixel 6a)** uses Cloud First (`Auto`) because AICore / Gemini Nano is unavailable on Pixel 6a (Tensor G1, 6GB RAM).
**Linux / Desktop Web (Chrome)** defaults to **Local First (`AiProviderMode.localFirst`)**: runs on-device **Gemini Nano 4** via Chrome's Built-in AI Prompt API (`web/index.html` → `window.edgeMapperNano` → `lib/services/on_device_vision_web.dart`) first, automatically falls back to **Firebase AI** online if unavailable, and lets the user escalate any local result to Firebase AI online with one tap (**Cloud Enrich** / **Cloud Rewrite**).

Platform-specific IO (`sqflite`, `dart:io`, `google_mlkit_*`, `path_provider`, `share_plus`) is isolated behind conditional-import adapters (`local_storage_{io,web}.dart`, `photo_helper_{io,web}.dart`, `on_device_vision_{io,web}.dart`, `tile_disk_cache_{io,web}.dart`, `export_share_{io,web}.dart`) so the same codebase builds for both Android APK and Flutter Web (`flutter run -d chrome` / `flutter build web`).

Edge Mapper uses a **Multi-Provider Hybrid AI Pipeline** (`lib/services/hybrid_ai_service.dart`):
1. **Tier 1 — Online Cloud AI (Configurable)**:
   - **Firebase AI Logic (`firebase_ai`)**: Multimodal image + GPS/compass prompt + strict `Schema.object` JSON output with selectable Gemini model (`gemini-2.5-flash`, `gemini-2.5-pro`, `gemini-2.5-flash-lite`, etc.).
   - **Personal Gemini API Key (REST)**: Direct Google Generative Language API (`generativelanguage.googleapis.com/v1beta`) with model discovery — works even without `google-services.json`.
   - **Custom OpenAI-Compatible Vision API**: Optional custom base URL / API key / vision model.
2. **Tier 2 — On-Device Gemini Nano Bridge (`com.edgemapper.app/gemini_nano`)**: Native Kotlin `MethodChannel` in `MainActivity.kt` checks `com.google.android.aicore` availability for Pixel 8/9+.
3. **Tier 3 — Offline Pixel 6a Fallback (ML Kit + OSM Heuristic Mapper)**: Uses `google_mlkit_image_labeling` + `google_mlkit_text_recognition` (Latin + Japanese + Chinese + Korean) + OCR bounding-box height scale distance estimation + `lib/services/osm_heuristic_mapper.dart`. Fast (<1s), low-RAM safe on 6GB devices, 100% offline.

## 3. Repository Map
```text
edge-mapper/
├── GEMINI.md                               # This file (cross-conversation context)
├── README.md                               # Setup, APK build & Firebase instructions
├── firestore.rules                         # Strict per-user Firestore Security Rules (`/users/{uid}/...` + `mapping_bounties`)
├── pubspec.yaml                            # Flutter dependencies (SDK >=3.5.0)
├── android/
│   └── app/
│       ├── build.gradle.kts                # minSdk=24, conditional google-services.json, ML Kit CJK scripts
│       └── src/main/
│           ├── AndroidManifest.xml         # Permissions: Camera, Fine/Coarse/Background GPS, Foreground Service (location), Notifications, Network; adaptive @mipmap/ic_launcher
│           ├── res/                        # Playful adaptive adventure launcher icon
│           └── kotlin/com/edgemapper/app/
│               └── MainActivity.kt         # Native Compass EventChannel + AICore/Gemini Nano, Browser URL, Photo Compression, SAF GPS File Picker, Trail Background Notification (`com.edgemapper.app/trail_background`), AndroidKeyStore AES-256-GCM E2EE/Vault (+ Biometric/PBKDF2) & ECDSA P-256 Proof MethodChannels
├── lib/
│   ├── main.dart                           # App bootstrap, Material 3 AppTheme wiring, service wiring
│   ├── theme/
│   │   └── app_theme.dart                  # Centralized Material 3 theme, typography scale, spacing/radii tokens & light/dark AppSemanticColors
│   ├── data/
│   │   ├── osm_tag_catalog.dart            # 160+ real OSM tags (incl. fitness_station/playground), highway/surface lists, probability ranker
│   │   └── osm_tag_standards.dart          # Real OSM Wiki key allowlist, hallucinated-key auto-repair (e.g. fitness_equipment->fitness_station), deprecated tag guard, day_off->opening_hours merger, publishable vs local-only classifier & OSM Wiki links
│   ├── models/
│   │   ├── osm_record.dart                 # OsmRecord (multi-photo & LocationProof), AiSource, RecordStatus, GPS extrapolation math
│   │   ├── hike_trail.dart                 # HikeTrail, ActivityType, TrailPoint, Haversine & jump detection
│   │   ├── enrichment_diff.dart            # AiUpdateMode (merge/overwrite), EnrichmentDiff, selective apply
│   │   ├── location_proof.dart             # LocationProof, GeohashUtil, ProofVerificationResult
│   │   └── mapping_bounty.dart             # MappingBounty, BountySubmission, BountyStatus
│   ├── services/
│   │   ├── app_env_config.dart             # Centralized compile-time environment variables (.env / --dart-define-from-file) & .env exporter
│   │   ├── secure_vault_service.dart       # Encrypted credentials vault (AndroidKeyStore StrongBox/TEE, OS Biometrics, WebAuthn Passkey PRF for Bitwarden/YubiKey, PBKDF2-SHA-256)
│   │   ├── secure_vault_backend{,_io,_web}.dart # Cross-platform vault bridges (Android MethodChannel / Web window.edgeMapperVault)
│   │   ├── firebase_bootstrap.dart         # Safe Firebase.initializeApp from env vars or google-services.json (zero-config builds!)
│   │   ├── user_preferences_service.dart   # Persisted settings (languages, AI provider/model/keys, explorer handle/avatar/BTC address)
│   │   ├── connectivity_service.dart       # connectivity_plus + manual Force Offline toggle
│   │   ├── gps_quality_service.dart        # Suspect/mocked/poor/stale/teleport GPS anomaly detection
│   │   ├── sensor_service.dart             # geolocator GPS + GpsQualityService + native compass EventChannel
│   │   ├── location_context_service.dart   # Offline country-language map + online Nominatim auto-guessing
│   │   ├── offline_tile_service.dart       # OSM raster tile disk cache, Web Mercator math, area pre-downloader
│   │   ├── firebase_sync_service.dart      # Zero-Knowledge E2EE Cloud Firestore REST sync (`users/{uid}/security/keyring`, `items/{itemId}`, `shares/{shareId}`), selective sharing & revocation
│   │   ├── e2ee_envelope_crypto.dart       # RFC-verified XChaCha20-Poly1305, X25519, HKDF-SHA256, Blake2b & Argon2id (64 MB/3-iter) envelope encryption, keyring & #k= link sharing
│   │   ├── argon2_runner{,_io,_web}.dart   # Off-UI-thread Isolate 64-bit Argon2id runner (native) & 32-bit Web-safe runner
│   │   ├── e2ee_platform_bridge{,_io,_web}.dart # WebAuthn PRF (`getClientExtensionResults().prf`) & Android Keystore `AES-256-GCM` (`com.edgemapper.app/e2ee_keystore`) local `User_Priv` cache bridge
│   │   ├── e2ee_crypto_service.dart        # Legacy NIST FIPS-197 / SP 800-38D AES-256-GCM helper
│   │   ├── e2ee_crypto_bridge{,_io,_web}.dart # Hardware-accelerated AES-256-GCM native bridges (Android JCA / WebCrypto `crypto.subtle`)
│   │   ├── sync_key_service.dart           # 256-bit CSPRNG Private Sync Key (`emk1-...`), 24-bit checksum & HMAC-SHA256 auth + E2EE key derivation
│   │   ├── password_manager_bridge{,_io,_web}.dart # Cross-platform Bitwarden / local password manager bridge (Android 14+ CredentialManager + AutofillManager / Web PasswordCredential + extension form capture — clipboard-free)
│   │   ├── gamification_service.dart       # Explorer XP, levels, ranks, RPG avatars, streaks, badges
│   │   ├── gps_file_picker{,_io,_web}.dart # Cross-platform native SAF / Web file picker for Ham radio GPS logs
│   │   ├── ham_radio_gps_import_service.dart # NMEA-0183, APRS (TNC2/Mic-E/Compressed), GPX, KML & CSV track parser
│   │   ├── explorer_avatar_service.dart    # Procedural RPG avatar, funny XP nicknames & unlockable characteristics
│   │   ├── leaderboard_service.dart        # Real OpenStreetMap Guild ranking near POI (OSM API v0.6 changesets + users, offline cached)
│   │   ├── bitcoin_service.dart            # BIP-21 URI builder, satoshi/BTC formatting, address validator, developer donation config
│   │   ├── bounty_service.dart             # Social Bitcoin mapping bounties, proof-verified claiming & payout flow
│   │   ├── crypto_proof_bridge{,_io,_web}.dart # Cross-platform AndroidKeyStore ECDSA P-256 signing & verification bridge
│   │   ├── exif_gps_reader.dart            # Pure-Dart JPEG EXIF GPS/heading/accuracy extractor for multi-photo gallery captures
│   │   ├── location_proof_service.dart     # Photo-free cryptographic capture proof generator & independent verifier
│   │   ├── osm_duplicate_service.dart      # Overpass API + local batch POI & track duplicate checker
│   │   ├── osm_tag_verifier_service.dart   # Live OpenStreetMap Taginfo API v4 verifier preventing AI-hallucinated keys & values
│   │   ├── local_db_service.dart           # SQLite v4: osm_records, hike_trails, trail_points, mapping_bounties, app_settings
│   │   ├── mapper_store.dart               # Central ChangeNotifier store
│   │   ├── osm_heuristic_mapper.dart       # Dual-language & visual-scale distance + offline OSM inference
│   │   ├── hybrid_ai_service.dart          # Multi-provider AI router, multi-photo merging + diff proposal engine
│   │   ├── osm_export_service.dart         # Export .osm (OSM XML), .gpx (GPX 1.1), .geojson + SharePlus
│   │   ├── osm_publish_service.dart        # OSM OAuth 2.0 PKCE + API v0.6 changeset & GPX trace uploader
│   │   └── osm_browser_bridge{,_io,_web}.dart # Cross-platform OAuth popup & external URL launcher
│   ├── widgets/
│   │   ├── osm_auth_sheet.dart             # OpenStreetMap OAuth 2.0 sign-in & Live/Sandbox switcher
│   │   ├── osm_publish_sheet.dart          # Pre-publish OSM duplicate check, validation, XML preview & uploader
│   │   ├── explorer_avatar_widget.dart     # Procedural RPG Explorer Avatar portrait CustomPainter
│   │   ├── qr_code_widget.dart             # Pure-Dart offline ISO QR code generator & CustomPainter
│   │   ├── bitcoin_donate_sheet.dart       # Bitcoin developer donation & bounty payout QR/wallet sheet
│   │   ├── location_proof_sheet.dart       # Photo-free cryptographic proof inspector & external proof verifier
│   │   ├── connectivity_banner.dart        # High-contrast Online/Offline/Active-AI banner
│   │   ├── compass_badge.dart              # Live heading dial & cardinal direction widget
│   │   ├── gps_warning_banner.dart         # Suspect/poor GPS alert banner + Fix GPS action
│   │   ├── mapper_quest_bar.dart           # Explorer RPG Avatar quest bar & Character/Badges sheet
│   │   ├── osm_map_widget.dart             # Interactive OSM Slippy Tile Map with offline cache, building/POI coverage & tap selection
│   │   ├── osm_mapped_feature_sheet.dart   # Mapped OSM point/building tag overview & improvement sheet
│   │   ├── osm_tag_selector_sheet.dart     # Probability-ranked searchable OSM tag selector
│   │   ├── enrichment_diff_sheet.dart      # Before/After AI diff review & selective confirmation
│   │   ├── ai_update_actions_card.dart     # Clear Add Missing Tags vs Reset & Re-analyze AI action cards with engine toggle
│   │   ├── firebase_auth_sheet.dart        # Private Sync Key (`emk1-...`) generation, QR/copy backup, recovery & Passkey/Fingerprint login sheet
│   │   ├── firebase_backup_banner.dart     # Online Firebase backup suggestion with opt-out
│   │   ├── ham_radio_import_sheet.dart     # External Ham radio GPS track importer modal (file picker, paste, callsign filter & preview)
│   │   ├── trail_preview_painter.dart      # Offline vector track preview painter
│   │   ├── fine_pin_position_pad.dart      # 2D interactive fine pin displacement pad (±5m/±15m/±40m)
│   │   └── ai_status_sheet.dart            # Explorer Settings, AI Hub, Profile & Bitcoin Support
│   └── screens/
│       ├── home_shell.dart                 # 4-tab navigation: Capture, Routes, Records, Explorer Guild
│       ├── capture_screen.dart             # Multi-photo capture/AI merge, distance slider, smart tags, proof badge
│       ├── trail_screen.dart               # General activity recorder, live offline OSM map, full OSM pickers
│       ├── trail_detail_screen.dart        # Review & edit any recorded route, inspect/clean GPS points
│       ├── records_screen.dart             # Collection list, Firebase backup banner, batch AI diff review
│       ├── record_detail_screen.dart       # Multi-photo gallery + AI merge, mini map, proof card, Enrich/Overwrite diff
│       └── community_screen.dart           # Explorer Guild: Ranking leaderboard, Bitcoin bounties, Hero & proof verifier
└── test/
    ├── osm_heuristic_and_export_test.dart  # Core engine unit tests
    ├── community_and_proof_features_test.dart # Unit tests for RPG avatar, duplicate check, BTC/QR, multi-photo merge, leaderboard, bounties & proofs
    └── ui_design_and_responsiveness_test.dart # Widget tests for Material 3 theme tokens, adaptive phone/tablet/desktop nav, font scaling & settings groups
```

## 4. Database Schema (SQLite v5 via `sqflite`)
- `osm_records`: `id TEXT PK`, `created_at TEXT`, `updated_at TEXT`, `photo_path TEXT`, `photo_paths_json TEXT`, `photo_locations_json TEXT`, `primary_location_photo_index INTEGER`, `is_manual_pin_override INTEGER`, `latitude REAL`, `longitude REAL`, `accuracy_meters REAL`, `altitude_meters REAL`, `heading_degrees REAL`, `extrapolated_lat REAL`, `extrapolated_lon REAL`, `estimated_offset_meters REAL`, `distance_reasoning TEXT`, `osm_type TEXT`, `summary TEXT`, `detected_language TEXT`, `tags_json TEXT`, `detected_labels_json TEXT`, `tag_candidates_json TEXT`, `ai_source TEXT`, `status TEXT`, `trail_id TEXT`, `notes TEXT`, `firebase_synced_at TEXT`, `location_proof_json TEXT`, `local_proof_salt TEXT` (ordered by `COALESCE(updated_at, created_at) DESC`)
- `hike_trails`: `id TEXT PK`, `name TEXT`, `started_at TEXT`, `ended_at TEXT`, `is_active INTEGER`, `activity_type TEXT`, `tags_json TEXT`, `needs_location_guess INTEGER`, `location_context TEXT`, `firebase_synced_at TEXT`
- `trail_points`: `id INTEGER PK AUTOINCREMENT`, `trail_id TEXT`, `latitude REAL`, `longitude REAL`, `altitude_meters REAL`, `accuracy_meters REAL`, `recorded_at TEXT`
- `mapping_bounties`: `id TEXT PK`, `title TEXT`, `description TEXT`, `area_label TEXT`, `target_lat REAL`, `target_lon REAL`, `radius_meters REAL`, `requested_tags_json TEXT`, `reward_sats INTEGER`, `creator_explorer_id TEXT`, `creator_name TEXT`, `created_at TEXT`, `status TEXT`, `require_proof INTEGER`, `submissions_json TEXT`
- `app_settings`: `key TEXT PK`, `value TEXT`

## 5. Build & Verification Commands
```bash
# 1. Fetch dependencies
./flutter/bin/flutter pub get --offline

# 2. Static analysis & unit tests
./flutter/bin/flutter analyze --no-fatal-infos lib test
./flutter/bin/flutter test

# 3. Build APK straight away (works BEFORE adding google-services.json!)
./flutter/bin/flutter build apk --debug
./flutter/bin/flutter build apk --release

# 4. Install on connected Pixel 6a via adb
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## 6. Conventions & Rules for Future Conversations
- **Never break zero-config builds**: Keep `google-services.json` optional in Gradle and keep `FirebaseBootstrap` fail-safe so debug/release APKs always compile and launch offline.
- **Respect Pixel 6a 6GB RAM ceiling**: Avoid bundling >500MB local LLM weights by default; downscale photos before inference.
- **No third-party compass plugin**: Compass heading comes from our native `EventChannel` in `MainActivity.kt`.
- **OSM tag discipline**: Always preserve `name` in the local primary script, add `name:<country_lang>` AND `name:<user_lang>` according to user's confident/fallback languages, strictly avoid deprecated OSM tags (e.g. fold `day_off` into `opening_hours` with days before hours), exclude local-only metadata like `camera:direction` (on non-camera POIs) from OSM publishing, and use `source=survey` (never `GPS` or the app name).
- **Keep `GEMINI.md` updated** whenever adding new screens, SQLite migrations, or native channels.
