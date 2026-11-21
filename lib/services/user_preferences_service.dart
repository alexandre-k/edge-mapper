import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'app_env_config.dart';
import 'local_db_service.dart';
import 'secure_vault_service.dart';

enum AiProviderMode {
  localFirst,
  auto,
  firebaseAi,
  personalGeminiApi,
  openAiCompatible,
  onDeviceOnly;

  String get label => switch (this) {
        AiProviderMode.localFirst => 'Local First (Nano 4 → Cloud)',
        AiProviderMode.auto => 'Cloud First (Auto)',
        AiProviderMode.firebaseAi => 'Firebase AI',
        AiProviderMode.personalGeminiApi => 'Gemini API Key',
        AiProviderMode.openAiCompatible => 'Custom API',
        AiProviderMode.onDeviceOnly => 'Offline Only',
      };

  static AiProviderMode get platformDefault =>
      kIsWeb ? AiProviderMode.localFirst : AiProviderMode.auto;

  static AiProviderMode fromString(String? value) {
    if (value == null || value.isEmpty) return platformDefault;
    return AiProviderMode.values.firstWhere(
      (e) => e.name == value,
      orElse: () => platformDefault,
    );
  }
}

class LanguageOption {
  final String code;
  final String name;
  final String nativeName;

  const LanguageOption(this.code, this.name, this.nativeName);

  String get displayLabel =>
      name == nativeName ? '$name ($code)' : '$name / $nativeName ($code)';
}

/// Persists user preferences in SQLite (`app_settings`):
/// - AI provider & selectable Gemini / custom models
/// - User's own Gemini API key / OpenAI-compatible API endpoint
/// - User's confident languages & fallback language for dual-language OSM tags
/// - Firebase cloud sync suggestion opt-in/out & optional project overrides
/// - Offline map prefetch radius
class UserPreferencesService extends ChangeNotifier {
  static const String defaultModelId = 'gemini-3.5-flash-lite';

  static const List<String> defaultGeminiModels = [
    'gemini-3.5-flash-lite',
    'gemini-3.8-flash',
    'gemini-4-hydrogen',
  ];

  static bool isUnsupportedGeminiModel(
    String modelId, {
    bool allowGemini25 = false,
  }) {
    final m = modelId.trim().toLowerCase();
    if (m.startsWith('gemini-1.0-') ||
        m.startsWith('gemini-1.5-') ||
        m.startsWith('gemini-2.0-') ||
        m == 'gemini-3.8-flash-lite' ||
        m == 'gemini-3.8-pro') {
      return true;
    }
    if (!allowGemini25 && m.startsWith('gemini-2.5-')) {
      return true;
    }
    return false;
  }

  static const List<LanguageOption> supportedLanguages = [
    LanguageOption('en', 'English', 'English'),
    LanguageOption('fr', 'French', 'Français'),
    LanguageOption('ja', 'Japanese', '日本語'),
    LanguageOption('de', 'German', 'Deutsch'),
    LanguageOption('es', 'Spanish', 'Español'),
    LanguageOption('it', 'Italian', 'Italiano'),
    LanguageOption('zh', 'Chinese', '中文'),
    LanguageOption('ko', 'Korean', '한국어'),
    LanguageOption('pt', 'Portuguese', 'Português'),
    LanguageOption('nl', 'Dutch', 'Nederlands'),
    LanguageOption('pl', 'Polish', 'Polski'),
    LanguageOption('ru', 'Russian', 'Русский'),
    LanguageOption('ar', 'Arabic', 'العربية'),
    LanguageOption('th', 'Thai', 'ไทย'),
    LanguageOption('vi', 'Vietnamese', 'Tiếng Việt'),
    LanguageOption('id', 'Indonesian', 'Bahasa Indonesia'),
  ];

  /// Setting keys that hold login tokens, API keys, or sync passphrases and
  /// MUST be stored strictly inside the OS / Passkey encrypted vault (never
  /// plaintext in SQLite `app_settings` or Web `localStorage`).
  static const Set<String> sensitiveSettingKeys = {
    'osm_access_token',
    'personal_gemini_api_key',
    'custom_ai_api_key',
    'custom_firebase_api_key',
    'sync_space_id',
    'firebase_sync_private_key',
    'osm_client_id',
  };

  final LocalDbService? _db;
  final SecureVaultService? _vault;

  AiProviderMode _aiProviderMode = AiProviderMode.platformDefault;
  String _selectedGeminiModel = AppEnvConfig.geminiModel.trim().isNotEmpty
      ? AppEnvConfig.geminiModel.trim()
      : defaultModelId;
  List<String> _discoveredGeminiModels = const [];
  String _personalGeminiApiKey = '';
  String _customAiBaseUrl = AppEnvConfig.customAiBaseUrl.trim().isNotEmpty
      ? AppEnvConfig.customAiBaseUrl.trim()
      : 'https://api.openai.com/v1';
  String _customAiApiKey = '';
  String _customAiModel = AppEnvConfig.customAiModel.trim().isNotEmpty
      ? AppEnvConfig.customAiModel.trim()
      : 'gpt-4o-mini';

  List<String> _confidentLanguages = const ['en'];
  String _primaryLanguage = 'en';
  String _preferredFallbackLanguage = 'en';

  bool _suggestFirebaseSync = true;
  String _customFirebaseProjectId = '';
  String _customFirebaseApiKey = '';
  String _syncSpaceId = '';
  String _firebaseSyncPrivateKey = '';
  String _firebaseSyncKeyFingerprint = '';
  String _e2eePasskeyCredentialId = '';

  double _offlineMapRadiusKm = 1.0;
  bool _autoPrefetchOfflineTiles = false;

  // OpenStreetMap OAuth 2.0 & publishing settings
  bool _osmUseSandbox = AppEnvConfig.osmUseSandbox;
  String _osmClientId = '';
  String _osmRedirectUri = AppEnvConfig.osmRedirectUri.trim();
  String _osmAccessToken = '';
  String _osmUsername = '';
  int? _osmUserId;
  String _osmChangesetComment = AppEnvConfig.osmChangesetComment.trim().isNotEmpty
      ? AppEnvConfig.osmChangesetComment.trim()
      : 'Field survey via Edge Mapper';

  // Explorer RPG identity & Bitcoin bounty payout address
  String _explorerId = '';
  String _explorerHandle = AppEnvConfig.explorerHandle.trim();
  String _avatarSeed = '';
  String _userBtcAddress = '';
  final Set<String> _pendingSecretDeletions = <String>{};

  UserPreferencesService({
    LocalDbService? db,
    SecureVaultService? vault,
  })  : _db = db,
        _vault = vault {
    _vault?.addListener(_handleVaultUpdate);
  }

  SecureVaultService? get vault => _vault;
  bool get isVaultLocked => _vault?.isLocked ?? false;

  void _handleVaultUpdate() {
    final v = _vault;
    if (v != null && v.isUnlocked && _pendingSecretDeletions.isNotEmpty) {
      // Flush queued sign-out / server-switch deletions before reading secrets
      // so stale tokens are never resurrected upon vault unlock.
      final toDelete = Set<String>.from(_pendingSecretDeletions);
      _pendingSecretDeletions.clear();
      // ignore: unawaited_futures
      _flushPendingSecretDeletions(v, toDelete);
      return;
    }
    _applySecretsFromVault();
    notifyListeners();
  }

  Future<void> _flushPendingSecretDeletions(
    SecureVaultService v,
    Set<String> keys,
  ) async {
    try {
      await v.setSecrets({for (final k in keys) k: ''});
      await _db?.deleteSetting('pending_vault_deletions');
    } catch (_) {
      _pendingSecretDeletions.addAll(keys);
    }
    _applySecretsFromVault();
    notifyListeners();
  }

  Future<void> _queueSecretDeletion(String key) async {
    _pendingSecretDeletions.add(key);
    await _db?.setSetting(
      'pending_vault_deletions',
      jsonEncode(_pendingSecretDeletions.toList()),
    );
  }

  void _applySecretsFromVault() {
    final v = _vault;
    if (v == null) return;
    if (v.isLocked) {
      // Wipe decrypted secrets from in-memory preference fields when locked
      _personalGeminiApiKey = '';
      _customAiApiKey = '';
      _customFirebaseApiKey = '';
      _syncSpaceId = '';
      _firebaseSyncPrivateKey = '';
      _osmClientId = '';
      _osmAccessToken = '';
      return;
    }
    String readOrEnv(String key, String envFallback) {
      final stored = v.getSecret(key).trim();
      if (stored.isNotEmpty) return stored;
      return envFallback.trim();
    }

    _personalGeminiApiKey =
        readOrEnv('personal_gemini_api_key', AppEnvConfig.geminiApiKey);
    _customAiApiKey =
        readOrEnv('custom_ai_api_key', AppEnvConfig.customAiApiKey);
    _customFirebaseApiKey = readOrEnv('custom_firebase_api_key', '');
    _syncSpaceId =
        readOrEnv('sync_space_id', AppEnvConfig.firebaseSyncSpaceId);
    _firebaseSyncPrivateKey = v.getSecret('firebase_sync_private_key').trim();
    _osmClientId = readOrEnv('osm_client_id', AppEnvConfig.osmClientId);
    _osmAccessToken = v.getSecret('osm_access_token').trim();
  }

  /// Exports active configuration in `.env` format (secrets omitted by default).
  String exportDotEnv({bool includeSecrets = false}) {
    return AppEnvConfig.buildDotEnvExport(
      firebaseProject: _customFirebaseProjectId,
      firebaseWebKey: _customFirebaseApiKey,
      osmClient: _osmClientId,
      osmRedirect: _osmRedirectUri,
      osmSandbox: _osmUseSandbox,
      osmComment: _osmChangesetComment,
      selectedGeminiModel: _selectedGeminiModel,
      personalGeminiKey: _personalGeminiApiKey,
      customBaseUrl: _customAiBaseUrl,
      customKey: _customAiApiKey,
      customModel: _customAiModel,
      syncSpace: _syncSpaceId,
      handle: _explorerHandle,
      includeSecrets: includeSecrets,
    );
  }

  AiProviderMode get aiProviderMode => _aiProviderMode;
  String get selectedGeminiModel => _selectedGeminiModel;
  List<String> get availableGeminiModels {
    final allow25 = hasPersonalGeminiApiKey;
    final all = <String>{
      ...defaultGeminiModels,
      ..._discoveredGeminiModels.where(
        (m) => !isUnsupportedGeminiModel(m, allowGemini25: allow25),
      ),
      if (_selectedGeminiModel.isNotEmpty) _selectedGeminiModel,
    };
    return all.toList();
  }

  String get personalGeminiApiKey => _personalGeminiApiKey;
  bool get hasPersonalGeminiApiKey => _personalGeminiApiKey.trim().isNotEmpty;

  String get customAiBaseUrl => _customAiBaseUrl;
  String get customAiApiKey => _customAiApiKey;
  String get customAiModel => _customAiModel;
  bool get hasCustomAiConfig =>
      _customAiApiKey.trim().isNotEmpty && _customAiBaseUrl.trim().isNotEmpty;

  List<String> get confidentLanguages => List.unmodifiable(_confidentLanguages);
  /// The user's MAIN specified language (primary language for OSM tags & AI output).
  String get primaryLanguage => _primaryLanguage;
  /// The user's SECONDARY language (formerly fallback) used as the secondary OSM tag language.
  String get secondaryLanguage => _preferredFallbackLanguage;
  String get preferredFallbackLanguage => _preferredFallbackLanguage;

  bool get suggestFirebaseSync => _suggestFirebaseSync;
  String get customFirebaseProjectId => _customFirebaseProjectId;
  String get customFirebaseApiKey => _customFirebaseApiKey;
  String get syncSpaceId => _syncSpaceId;
  String get firebaseSyncPrivateKey => _firebaseSyncPrivateKey;
  String get firebaseSyncKeyFingerprint => _firebaseSyncKeyFingerprint;
  String get e2eePasskeyCredentialId => _e2eePasskeyCredentialId;
  bool get hasStoredSyncKey =>
      _firebaseSyncPrivateKey.isNotEmpty ||
      _firebaseSyncKeyFingerprint.isNotEmpty;

  double get offlineMapRadiusKm => _offlineMapRadiusKm;
  bool get autoPrefetchOfflineTiles => _autoPrefetchOfflineTiles;

  bool get osmUseSandbox => _osmUseSandbox;
  String get osmClientId => _osmClientId;
  String get osmRedirectUri => _osmRedirectUri;
  String get osmAccessToken => _osmAccessToken;
  String get osmUsername => _osmUsername;
  int? get osmUserId => _osmUserId;
  String get osmChangesetComment => _osmChangesetComment;
  bool get isOsmAuthenticated => _osmAccessToken.trim().isNotEmpty;

  String get explorerId =>
      _explorerId.isNotEmpty ? _explorerId : 'local-explorer';
  String get explorerHandle {
    if (_explorerHandle.trim().isNotEmpty) return _explorerHandle.trim();
    if (_osmUsername.trim().isNotEmpty) return _osmUsername.trim();
    return 'You';
  }

  String get rawExplorerHandle => _explorerHandle;
  String get avatarSeed =>
      _avatarSeed.isNotEmpty ? _avatarSeed : explorerId;
  String get userBtcAddress => _userBtcAddress;

  /// Resolves the user's MAIN language for OSM tags relative to [countryLanguage]:
  /// always prioritizes the user's [primaryLanguage] first (never jumping straight
  /// to the secondary/fallback language when the user specified a main language).
  /// If [primaryLanguage] already equals [countryLanguage], returns [secondaryLanguage]
  /// (or another confident language) as the companion tag language.
  String? resolveUserLanguageForCountry(String countryLanguage) {
    final normalizedCountry = countryLanguage.toLowerCase().trim();
    if (_primaryLanguage != normalizedCountry) {
      return _primaryLanguage;
    }
    if (_preferredFallbackLanguage != normalizedCountry) {
      return _preferredFallbackLanguage;
    }
    for (final lang in _confidentLanguages) {
      if (lang != normalizedCountry) return lang;
    }
    return null;
  }

  /// Resolves the SECONDARY OSM tag language (strictly secondary to [primaryLanguage]).
  /// Returns `null` if no distinct secondary language is configured.
  String? resolveSecondaryLanguageForCountry(String countryLanguage) {
    final normalizedCountry = countryLanguage.toLowerCase().trim();
    final primaryTag = resolveUserLanguageForCountry(normalizedCountry);
    if (_preferredFallbackLanguage != normalizedCountry &&
        _preferredFallbackLanguage != primaryTag &&
        _preferredFallbackLanguage != _primaryLanguage) {
      return _preferredFallbackLanguage;
    }
    for (final lang in _confidentLanguages) {
      if (lang != normalizedCountry &&
          lang != primaryTag &&
          lang != _primaryLanguage) {
        return lang;
      }
    }
    return null;
  }

  static String languageDisplayName(String code) {
    for (final opt in supportedLanguages) {
      if (opt.code == code) return opt.name;
    }
    return code.toUpperCase();
  }

  Future<void> init() async {
    final db = _db;
    final all = db != null ? await db.getAllSettings() : <String, String>{};

    final rawPendingDel = all['pending_vault_deletions'];
    if (rawPendingDel != null && rawPendingDel.isNotEmpty) {
      try {
        for (final item in (jsonDecode(rawPendingDel) as List)) {
          final k = item.toString().trim();
          if (sensitiveSettingKeys.contains(k)) {
            _pendingSecretDeletions.add(k);
          }
        }
      } catch (_) {}
    }

    // Migrate any legacy plaintext sensitive credentials from SQLite/localStorage
    // into the OS / Passkey encrypted vault and erase the plaintext copies.
    final v = _vault;
    if (v != null && v.isUnlocked) {
      if (_pendingSecretDeletions.isNotEmpty) {
        final toDelete = Set<String>.from(_pendingSecretDeletions);
        _pendingSecretDeletions.clear();
        await v.setSecrets({for (final k in toDelete) k: ''});
        await db?.deleteSetting('pending_vault_deletions');
      }
      final legacySecrets = <String, String>{};
      for (final key in sensitiveSettingKeys) {
        final raw = all[key]?.trim() ?? '';
        if (raw.isNotEmpty) {
          if (v.getSecret(key).trim().isEmpty) {
            legacySecrets[key] = raw;
          }
          await db?.deleteSetting(key);
        }
      }
      if (legacySecrets.isNotEmpty) {
        await v.setSecrets(legacySecrets);
      }
      _applySecretsFromVault();
    } else if (v == null) {
      _personalGeminiApiKey = (all['personal_gemini_api_key'] ?? '').isNotEmpty
          ? all['personal_gemini_api_key']!
          : AppEnvConfig.geminiApiKey.trim();
      _customAiApiKey = (all['custom_ai_api_key'] ?? '').isNotEmpty
          ? all['custom_ai_api_key']!
          : AppEnvConfig.customAiApiKey.trim();
      _customFirebaseApiKey = all['custom_firebase_api_key'] ?? '';
      _syncSpaceId = (all['sync_space_id'] ?? '').isNotEmpty
          ? all['sync_space_id']!
          : AppEnvConfig.firebaseSyncSpaceId.trim();
      _firebaseSyncPrivateKey = all['firebase_sync_private_key'] ?? '';
      _osmClientId = (all['osm_client_id'] ?? '').isNotEmpty
          ? all['osm_client_id']!
          : AppEnvConfig.osmClientId.trim();
      _osmAccessToken = all['osm_access_token'] ?? '';
    } else {
      // Vault is currently locked (Passkey / OS Biometric / Passphrase lock active)
      _applySecretsFromVault();
    }

    _aiProviderMode = AiProviderMode.fromString(all['ai_provider_mode']);
    final allow25 = _personalGeminiApiKey.trim().isNotEmpty;
    if (all['selected_gemini_model']?.isNotEmpty == true) {
      final saved = all['selected_gemini_model']!;
      // Auto-migrate retired or invalid models to a verified active model.
      if (isUnsupportedGeminiModel(saved, allowGemini25: allow25)) {
        _selectedGeminiModel = defaultModelId;
        await db?.setSetting('selected_gemini_model', defaultModelId);
      } else {
        _selectedGeminiModel = saved;
      }
    }
    if (all['discovered_gemini_models']?.isNotEmpty == true) {
      try {
        _discoveredGeminiModels =
            (jsonDecode(all['discovered_gemini_models']!) as List)
                .map((e) => e.toString())
                .where(
                  (m) => !isUnsupportedGeminiModel(m, allowGemini25: allow25),
                )
                .toList();
      } catch (_) {}
    }
    if (all['custom_ai_base_url']?.isNotEmpty == true) {
      _customAiBaseUrl = all['custom_ai_base_url']!;
    }
    if (all['custom_ai_model']?.isNotEmpty == true) {
      _customAiModel = all['custom_ai_model']!;
    }

    if (all['confident_languages']?.isNotEmpty == true) {
      try {
        final list = (jsonDecode(all['confident_languages']!) as List)
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList();
        if (list.isNotEmpty) _confidentLanguages = list;
      } catch (_) {}
    }
    if (all['primary_language']?.isNotEmpty == true) {
      _primaryLanguage = all['primary_language']!.trim().toLowerCase();
      if (!_confidentLanguages.contains(_primaryLanguage)) {
        _confidentLanguages = [_primaryLanguage, ..._confidentLanguages];
      }
    } else if (_confidentLanguages.isNotEmpty) {
      _primaryLanguage = _confidentLanguages.first;
    }
    if (all['preferred_fallback_language']?.isNotEmpty == true) {
      _preferredFallbackLanguage = all['preferred_fallback_language']!;
    }

    if (all['suggest_firebase_sync'] != null) {
      _suggestFirebaseSync = all['suggest_firebase_sync'] == 'true';
    }
    _customFirebaseProjectId = all['custom_firebase_project_id'] ?? '';
    _firebaseSyncKeyFingerprint = all['firebase_sync_key_fingerprint'] ?? '';
    _e2eePasskeyCredentialId = all['e2ee_passkey_credential_id'] ?? '';

    if (all['offline_map_radius_km'] != null) {
      _offlineMapRadiusKm =
          (double.tryParse(all['offline_map_radius_km']!) ?? 1.0)
              .clamp(0.5, 2.0);
    }
    if (all['auto_prefetch_offline_tiles'] != null) {
      _autoPrefetchOfflineTiles = all['auto_prefetch_offline_tiles'] == 'true';
    }

    if (all['osm_use_sandbox'] != null) {
      _osmUseSandbox = all['osm_use_sandbox'] == 'true';
    }
    if (all['osm_redirect_uri']?.isNotEmpty == true) {
      _osmRedirectUri = all['osm_redirect_uri']!;
    }
    _osmUsername = all['osm_username'] ?? '';
    _osmUserId = int.tryParse(all['osm_user_id'] ?? '');
    if (all['osm_changeset_comment']?.isNotEmpty == true) {
      _osmChangesetComment = all['osm_changeset_comment']!;
    }

    _explorerId = all['explorer_id'] ?? '';
    if (_explorerId.isEmpty) {
      _explorerId = const Uuid().v4();
      await db?.setSetting('explorer_id', _explorerId);
    }
    if (all['explorer_handle']?.isNotEmpty == true) {
      _explorerHandle = all['explorer_handle']!;
    }
    _avatarSeed = all['avatar_seed'] ?? _explorerId;
    _userBtcAddress = all['user_btc_address'] ?? '';

    notifyListeners();
  }

  Future<void> _save(String key, String value) async {
    await _db?.setSetting(key, value);
    notifyListeners();
  }

  /// Stores a sensitive credential strictly inside the encrypted OS/Passkey
  /// vault (and erases any plaintext entry in SQLite/localStorage).
  /// Sensitive keys are NEVER persisted to plaintext SQLite if no vault is
  /// attached (they stay strictly in volatile RAM in unit tests).
  Future<void> _saveSensitive(String key, String value) async {
    final v = _vault;
    if (v != null) {
      await v.setSecret(key, value);
      await _db?.deleteSetting(key);
    } else if (sensitiveSettingKeys.contains(key)) {
      await _db?.deleteSetting(key);
    } else {
      await _db?.setSetting(key, value);
    }
    notifyListeners();
  }

  Future<void> setAiProviderMode(AiProviderMode mode) async {
    _aiProviderMode = mode;
    await _save('ai_provider_mode', mode.name);
  }

  Future<void> setSelectedGeminiModel(String model) async {
    final trimmed = model.trim();
    if (trimmed.isEmpty) return;
    _selectedGeminiModel = trimmed;
    await _save('selected_gemini_model', trimmed);
  }

  Future<void> setDiscoveredGeminiModels(List<String> models) async {
    _discoveredGeminiModels = models;
    await _save('discovered_gemini_models', jsonEncode(models));
  }

  Future<void> setPersonalGeminiApiKey(String key) async {
    _personalGeminiApiKey = key.trim();
    await _saveSensitive('personal_gemini_api_key', _personalGeminiApiKey);
  }

  Future<void> setCustomAiConfig({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    _customAiBaseUrl = baseUrl.trim();
    _customAiApiKey = apiKey.trim();
    _customAiModel = model.trim().isEmpty ? 'gpt-4o-mini' : model.trim();
    await _db?.setSetting('custom_ai_base_url', _customAiBaseUrl);
    await _db?.setSetting('custom_ai_model', _customAiModel);
    await _saveSensitive('custom_ai_api_key', _customAiApiKey);
  }

  Future<void> toggleConfidentLanguage(String langCode) async {
    final code = langCode.trim().toLowerCase();
    final next = List<String>.from(_confidentLanguages);
    if (next.contains(code)) {
      // Never remove the active primary language or the last remaining language
      if (next.length > 1 && code != _primaryLanguage) {
        next.remove(code);
      }
    } else {
      next.add(code);
    }
    _confidentLanguages = next;
    await _save('confident_languages', jsonEncode(next));
  }

  Future<void> setPrimaryLanguage(String langCode) async {
    final code = langCode.trim().toLowerCase();
    if (code.isEmpty) return;
    _primaryLanguage = code;
    final next = <String>[
      code,
      ..._confidentLanguages.where((l) => l != code),
    ];
    _confidentLanguages = next;
    await _db?.setSetting('primary_language', _primaryLanguage);
    await _db?.setSetting('confident_languages', jsonEncode(next));
    notifyListeners();
  }

  Future<void> setConfidentLanguages(List<String> langs) async {
    if (langs.isEmpty) return;
    _confidentLanguages =
        langs.map((l) => l.trim().toLowerCase()).where((l) => l.isNotEmpty).toList();
    if (_confidentLanguages.isEmpty) return;
    _primaryLanguage = _confidentLanguages.first;
    await _db?.setSetting('primary_language', _primaryLanguage);
    await _save('confident_languages', jsonEncode(_confidentLanguages));
  }

  Future<void> setSecondaryLanguage(String langCode) =>
      setPreferredFallbackLanguage(langCode);

  Future<void> setPreferredFallbackLanguage(String langCode) async {
    _preferredFallbackLanguage = langCode.trim().toLowerCase();
    await _save('preferred_fallback_language', _preferredFallbackLanguage);
  }

  Future<void> setSuggestFirebaseSync(bool value) async {
    _suggestFirebaseSync = value;
    await _save('suggest_firebase_sync', value ? 'true' : 'false');
  }

  Future<void> setCustomFirebaseConfig({
    required String projectId,
    required String apiKey,
  }) async {
    _customFirebaseProjectId = projectId.trim();
    _customFirebaseApiKey = apiKey.trim();
    await _db?.setSetting(
      'custom_firebase_project_id',
      _customFirebaseProjectId,
    );
    await _saveSensitive('custom_firebase_api_key', _customFirebaseApiKey);
  }

  Future<void> setSyncSpaceId(String spaceId) async {
    final cleaned = spaceId
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]'), '');
    _syncSpaceId = cleaned;
    await _saveSensitive('sync_space_id', _syncSpaceId);
  }

  /// Persists the private Sync Key strictly inside the encrypted vault and
  /// stores only its non-secret public fingerprint for locked-state UI display.
  Future<void> setFirebaseSyncPrivateKey({
    required String canonicalKey,
    required String fingerprint,
  }) async {
    _firebaseSyncPrivateKey = canonicalKey.trim();
    _firebaseSyncKeyFingerprint = fingerprint.trim();
    await _db?.setSetting(
      'firebase_sync_key_fingerprint',
      _firebaseSyncKeyFingerprint,
    );
    await _saveSensitive('firebase_sync_private_key', _firebaseSyncPrivateKey);
  }

  Future<void> setE2eePasskeyCredentialId(String credentialId) async {
    final trimmed = credentialId.trim();
    if (_e2eePasskeyCredentialId == trimmed) return;
    _e2eePasskeyCredentialId = trimmed;
    await _save('e2ee_passkey_credential_id', trimmed);
  }

  /// Removes the Sync Key and its fingerprint from this device.
  Future<void> clearFirebaseSyncPrivateKey() async {
    _firebaseSyncPrivateKey = '';
    _firebaseSyncKeyFingerprint = '';
    await _db?.setSetting('firebase_sync_key_fingerprint', '');
    if (_vault == null || _vault.isUnlocked) {
      await _saveSensitive('firebase_sync_private_key', '');
    } else {
      await _queueSecretDeletion('firebase_sync_private_key');
      notifyListeners();
    }
  }

  Future<void> setOfflineMapRadiusKm(double km) async {
    _offlineMapRadiusKm = km.clamp(0.5, 2.0);
    await _save('offline_map_radius_km', _offlineMapRadiusKm.toString());
  }

  Future<void> setAutoPrefetchOfflineTiles(bool enabled) async {
    _autoPrefetchOfflineTiles = enabled;
    await _save('auto_prefetch_offline_tiles', enabled ? 'true' : 'false');
  }

  Future<void> setOsmUseSandbox(bool sandbox) async {
    if (_osmUseSandbox == sandbox) return;
    _osmUseSandbox = sandbox;
    // Tokens are server-specific (dev vs production), so clear cached session on switch.
    _osmAccessToken = '';
    _osmUsername = '';
    _osmUserId = null;
    await _db?.setSetting('osm_use_sandbox', sandbox ? 'true' : 'false');
    await _db?.setSetting('osm_username', '');
    await _db?.setSetting('osm_user_id', '');
    if (_vault == null || _vault.isUnlocked) {
      await _saveSensitive('osm_access_token', '');
    } else {
      await _queueSecretDeletion('osm_access_token');
      notifyListeners();
    }
  }

  Future<void> setOsmOAuthApp({
    required String clientId,
    String? redirectUri,
  }) async {
    _osmClientId = clientId.trim();
    if (redirectUri != null) {
      _osmRedirectUri = redirectUri.trim();
      await _db?.setSetting('osm_redirect_uri', _osmRedirectUri);
    }
    await _saveSensitive('osm_client_id', _osmClientId);
  }

  Future<void> setOsmAuthSession({
    required String accessToken,
    String? username,
    int? userId,
  }) async {
    _osmAccessToken = accessToken.trim();
    if (username != null) _osmUsername = username.trim();
    if (userId != null) _osmUserId = userId;
    await _db?.setSetting('osm_username', _osmUsername);
    await _db?.setSetting('osm_user_id', _osmUserId?.toString() ?? '');
    await _saveSensitive('osm_access_token', _osmAccessToken);
  }

  Future<void> clearOsmAuth() async {
    _osmAccessToken = '';
    _osmUsername = '';
    _osmUserId = null;
    await _db?.setSetting('osm_username', '');
    await _db?.setSetting('osm_user_id', '');
    if (_vault == null || _vault.isUnlocked) {
      await _saveSensitive('osm_access_token', '');
    } else {
      await _queueSecretDeletion('osm_access_token');
      notifyListeners();
    }
  }

  Future<void> setOsmChangesetComment(String comment) async {
    final trimmed = comment.trim();
    _osmChangesetComment =
        trimmed.isEmpty ? 'Field survey via Edge Mapper' : trimmed;
    await _save('osm_changeset_comment', _osmChangesetComment);
  }

  Future<void> setExplorerHandle(String handle) async {
    _explorerHandle = handle.trim();
    await _save('explorer_handle', _explorerHandle);
  }

  Future<void> rerollAvatarSeed() async {
    _avatarSeed = const Uuid().v4();
    await _save('avatar_seed', _avatarSeed);
  }

  Future<void> setUserBtcAddress(String address) async {
    _userBtcAddress = address.trim();
    await _save('user_btc_address', _userBtcAddress);
  }

  @override
  void dispose() {
    _vault?.removeListener(_handleVaultUpdate);
    super.dispose();
  }
}
