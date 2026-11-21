import 'package:flutter/material.dart';

import '../services/connectivity_service.dart';
import '../services/firebase_sync_service.dart';
import '../services/hybrid_ai_service.dart';
import '../services/mapper_store.dart';
import '../services/offline_tile_service.dart';
import '../services/osm_publish_service.dart';
import '../services/user_preferences_service.dart';
import '../theme/app_theme.dart';
import 'bitcoin_donate_sheet.dart';
import 'firebase_auth_sheet.dart';
import 'osm_auth_sheet.dart';
import 'responsive_layout.dart';

/// Comprehensive Explorer Settings & AI Diagnostics hub:
/// - Offline toggle
/// - AI Provider selection (Auto, Firebase AI, Personal Gemini API Key, Custom OpenAI-compatible, On-Device)
/// - Selectable Gemini models + dynamic model fetching + custom model ID
/// - Personal Gemini API key & OpenAI-compatible API setup
/// - Confident languages & preferred fallback language for dual-language OSM tags
/// - Zero-Knowledge E2EE Cloud Backup, Cross-Device Sync & Selective Sharing
/// - Offline Map cache settings & storage management
/// - Offline OCR scripts
class AiStatusSheet extends StatefulWidget {
  final ConnectivityService connectivity;
  final HybridAiService ai;
  final UserPreferencesService prefs;
  final FirebaseSyncService firebaseSync;
  final OfflineTileService tiles;
  final OsmPublishService osmPublish;
  final MapperStore? store;

  const AiStatusSheet({
    super.key,
    required this.connectivity,
    required this.ai,
    required this.prefs,
    required this.firebaseSync,
    required this.tiles,
    required this.osmPublish,
    this.store,
  });

  @override
  State<AiStatusSheet> createState() => _AiStatusSheetState();
}

class _AiStatusSheetState extends State<AiStatusSheet> {
  late TextEditingController _geminiKeyCtrl;
  late TextEditingController _customModelCtrl;
  late TextEditingController _customBaseUrlCtrl;
  late TextEditingController _customApiKeyCtrl;
  late TextEditingController _customOpenAiModelCtrl;

  bool _obscureKeys = true;
  bool _isFetchingModels = false;
  bool _isTestingAi = false;
  bool _lastTestFailed = false;
  String? _modelStatusMessage;

  @override
  void initState() {
    super.initState();
    _geminiKeyCtrl =
        TextEditingController(text: widget.prefs.personalGeminiApiKey);
    _customModelCtrl =
        TextEditingController(text: widget.prefs.selectedGeminiModel);
    _customBaseUrlCtrl =
        TextEditingController(text: widget.prefs.customAiBaseUrl);
    _customApiKeyCtrl =
        TextEditingController(text: widget.prefs.customAiApiKey);
    _customOpenAiModelCtrl =
        TextEditingController(text: widget.prefs.customAiModel);
  }

  @override
  void dispose() {
    _geminiKeyCtrl.dispose();
    _customModelCtrl.dispose();
    _customBaseUrlCtrl.dispose();
    _customApiKeyCtrl.dispose();
    _customOpenAiModelCtrl.dispose();
    super.dispose();
  }

  Future<void> _savePersonalGeminiKey({bool runTest = false}) async {
    final trimmed = _geminiKeyCtrl.text.trim();
    await widget.prefs.setPersonalGeminiApiKey(trimmed);
    widget.ai.resetCloudDiagnostics();

    if (trimmed.isNotEmpty) {
      if (widget.prefs.aiProviderMode == AiProviderMode.firebaseAi ||
          widget.prefs.aiProviderMode == AiProviderMode.openAiCompatible ||
          widget.prefs.aiProviderMode == AiProviderMode.onDeviceOnly) {
        await widget.prefs.setAiProviderMode(AiProviderMode.personalGeminiApi);
      }
    } else if (widget.prefs.aiProviderMode ==
        AiProviderMode.personalGeminiApi) {
      await widget.prefs.setAiProviderMode(AiProviderMode.platformDefault);
    }

    if (!mounted) return;
    if (!runTest) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            trimmed.isNotEmpty
                ? 'Personal Gemini API key saved & activated for Cloud AI'
                : 'Personal Gemini API key cleared',
          ),
        ),
      );
      return;
    }

    setState(() {
      _isTestingAi = true;
      _lastTestFailed = false;
      _modelStatusMessage = 'Testing Personal Gemini API key...';
    });
    try {
      final msg = await widget.ai.testActiveCloudAi();
      if (!mounted) return;
      _customModelCtrl.text = widget.prefs.selectedGeminiModel;
      final hasErr = msg.toLowerCase().contains('failed') ||
          msg.toLowerCase().contains('error');
      setState(() {
        _lastTestFailed = hasErr;
        _modelStatusMessage = msg;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastTestFailed = true;
        _modelStatusMessage = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (mounted) setState(() => _isTestingAi = false);
    }
  }

  Future<void> _fetchModels() async {
    if (_geminiKeyCtrl.text.trim().isNotEmpty) {
      await widget.prefs.setPersonalGeminiApiKey(_geminiKeyCtrl.text);
      widget.ai.resetCloudDiagnostics();
    }
    setState(() {
      _isFetchingModels = true;
      _modelStatusMessage = null;
    });
    try {
      final models = await widget.ai.fetchAvailableGeminiModels();
      if (!mounted) return;
      setState(() {
        _modelStatusMessage =
            'Loaded ${models.length} Gemini models (${models.take(3).join(', ')})!';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _modelStatusMessage = 'Could not fetch models: $e';
      });
    } finally {
      if (mounted) setState(() => _isFetchingModels = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.connectivity,
        widget.ai,
        widget.prefs,
        widget.tiles,
        widget.osmPublish,
        widget.firebaseSync,
      ]),
      builder: (context, _) {
        final nano = widget.ai.nanoStatus;
        final scheme = Theme.of(context).colorScheme;
        final semantic = context.semanticColors;
        final textTheme = Theme.of(context).textTheme;
        final models = widget.prefs.availableGeminiModels;
        final cacheStats = widget.tiles.cacheStats;

        final langSubtitle =
            '${widget.prefs.primaryLanguage.toUpperCase()} primary · '
            '${widget.prefs.secondaryLanguage.toUpperCase()} fallback · '
            '${widget.prefs.confidentLanguages.length} confident';
        final aiSubtitle =
            '${widget.prefs.aiProviderMode.label} · ${widget.prefs.selectedGeminiModel}';
        final fb = widget.firebaseSync;
        final syncSubtitle = !fb.isConfigured
            ? 'Not configured'
            : fb.canSyncNow
                ? 'Active · ${fb.activeKeyFingerprint ?? 'Encrypted'}'
                : fb.hasDeviceKey
                    ? (fb.supportsAndroidHardwareCache
                        ? 'Unlock with Fingerprint'
                        : 'Unlock with Passkey')
                    : 'Not set up · Tap to initialize';
        final mapSubtitle =
            '${widget.prefs.offlineMapRadiusKm.toStringAsFixed(1)} km · '
            '${cacheStats.tileCount} tiles (${cacheStats.totalMb.toStringAsFixed(1)} MB)';

        return AdaptiveModalScrollContainer(
          builder: (context, scrollController) => SingleChildScrollView(
            controller: scrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ModalSheetHeader(
                  icon: Icons.tune_rounded,
                  title: 'Settings',
                  subtitle: widget.ai.activeEngineLabel,
                  onClose: () => Navigator.pop(context),
                ),
                const SizedBox(height: AppSpacing.md),

                // Quick Essentials Card: Offline Mode + Active AI + OpenStreetMap Account
                SurfacePanel(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  child: Column(
                    children: [
                      SwitchListTile.adaptive(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 4),
                        secondary: Icon(
                          Icons.airplanemode_active_rounded,
                          color: widget.connectivity.forceOffline
                              ? semantic.warning
                              : scheme.onSurfaceVariant,
                        ),
                        title: Text(
                          'Offline Mode',
                          style: textTheme.titleSmall,
                        ),
                        subtitle: Text(
                          'Local AI & cached maps only',
                          style: textTheme.bodySmall,
                        ),
                        value: widget.connectivity.forceOffline,
                        onChanged: widget.connectivity.setForceOffline,
                      ),
                      const Divider(),
                      ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 4),
                        dense: true,
                        leading:
                            Icon(Icons.bolt_rounded, color: scheme.primary),
                        title: Text(
                          widget.ai.activeEngineLabel,
                          style: textTheme.titleSmall,
                        ),
                        subtitle: Text(
                          nano.available ? 'Nano 4 ready' : nano.deviceModel,
                          style: textTheme.bodySmall,
                        ),
                        trailing: TextButton.icon(
                          onPressed: _isTestingAi
                              ? null
                              : () async {
                                  setState(() {
                                    _isTestingAi = true;
                                    _lastTestFailed = false;
                                    _modelStatusMessage = 'Testing AI...';
                                  });
                                  try {
                                    final msg =
                                        await widget.ai.testActiveCloudAi();
                                    if (!mounted) return;
                                    _customModelCtrl.text =
                                        widget.prefs.selectedGeminiModel;
                                    final hasErr =
                                        msg.toLowerCase().contains('failed') ||
                                            msg.toLowerCase().contains('error');
                                    setState(() {
                                      _lastTestFailed = hasErr;
                                      _modelStatusMessage = msg;
                                    });
                                  } catch (e) {
                                    if (!mounted) return;
                                    setState(() {
                                      _lastTestFailed = true;
                                      _modelStatusMessage = e
                                          .toString()
                                          .replaceFirst('Exception: ', '');
                                    });
                                  } finally {
                                    if (mounted) {
                                      setState(() => _isTestingAi = false);
                                    }
                                  }
                                },
                          icon: _isTestingAi
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.play_arrow_rounded, size: 17),
                          label: Text(_isTestingAi ? 'Testing' : 'Test'),
                        ),
                      ),
                      const Divider(),
                      ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 4),
                        dense: true,
                        leading: Icon(
                          Icons.public_rounded,
                          color: widget.osmPublish.isAuthenticated
                              ? semantic.success
                              : scheme.onSurfaceVariant,
                        ),
                        title: Text(
                          widget.osmPublish.isAuthenticated
                              ? (widget.osmPublish.username.isNotEmpty
                                  ? widget.osmPublish.username
                                  : 'OpenStreetMap Connected')
                              : 'OpenStreetMap Account',
                          style: textTheme.titleSmall,
                        ),
                        subtitle: Text(
                          widget.osmPublish.isAuthenticated
                              ? widget.osmPublish.serverLabel
                              : 'Connect via OAuth 2.0 to publish directly',
                          style: textTheme.bodySmall,
                        ),
                        trailing: FilledButton.tonal(
                          onPressed: () => showOsmAuthSheet(
                            context,
                            osm: widget.osmPublish,
                            prefs: widget.prefs,
                          ),
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            minimumSize: const Size(0, 36),
                          ),
                          child: Text(
                            widget.osmPublish.isAuthenticated
                                ? 'Manage'
                                : 'Connect',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Inline Diagnostics (only shown when relevant)
                if (_modelStatusMessage != null)
                  InlineNoticeBanner(
                    margin: const EdgeInsets.only(top: AppSpacing.sm),
                    tone: _lastTestFailed
                        ? NoticeTone.danger
                        : NoticeTone.success,
                    icon: _lastTestFailed
                        ? Icons.error_outline_rounded
                        : Icons.check_circle_outline_rounded,
                    title: _modelStatusMessage!,
                  ),
                if (widget.ai.lastNanoError != null)
                  InlineNoticeBanner(
                    margin: const EdgeInsets.only(top: AppSpacing.xs),
                    tone: NoticeTone.warning,
                    icon: Icons.bolt_rounded,
                    title: 'Nano 4 Notice',
                    detail: widget.ai.lastNanoError,
                    onDismiss: widget.ai.clearLastNanoError,
                  ),
                if (widget.ai.lastCloudError != null)
                  InlineNoticeBanner(
                    margin: const EdgeInsets.only(top: AppSpacing.xs),
                    tone: NoticeTone.danger,
                    icon: Icons.cloud_off_rounded,
                    title: 'Cloud AI Error',
                    detail: widget.ai.lastCloudError,
                    onDismiss: widget.ai.clearLastCloudError,
                  ),

                const SizedBox(height: AppSpacing.sm),

                // 1. Languages Group
                _SettingsGroupCard(
                  icon: Icons.translate_rounded,
                  title: 'Languages',
                  subtitle: langSubtitle,
                  children: [
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: widget.prefs.primaryLanguage,
                      decoration: const InputDecoration(
                        labelText: 'Main Language (Primary)',
                        helperText:
                            'Primary language for OSM tags, summaries & field notes',
                        isDense: true,
                      ),
                      items: UserPreferencesService.supportedLanguages
                          .map(
                            (l) => DropdownMenuItem(
                              value: l.code,
                              child: Text(
                                l.displayLabel,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          widget.prefs.setPrimaryLanguage(v);
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: widget.prefs.secondaryLanguage,
                      decoration: const InputDecoration(
                        labelText: 'Secondary Language (OSM Fallback)',
                        helperText:
                            'Used as secondary name:<lang> on OpenStreetMap',
                        isDense: true,
                      ),
                      items: UserPreferencesService.supportedLanguages
                          .map(
                            (l) => DropdownMenuItem(
                              value: l.code,
                              child: Text(
                                l.displayLabel,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          widget.prefs.setSecondaryLanguage(v);
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    const SectionLabel('Additional Confident Languages'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: UserPreferencesService.supportedLanguages
                          .map((lang) {
                        final isPrimary =
                            widget.prefs.primaryLanguage == lang.code;
                        final selected =
                            widget.prefs.confidentLanguages.contains(lang.code);
                        return FilterChip(
                          label: Text(
                            isPrimary
                                ? '${lang.name} (${lang.code})'
                                : '${lang.name} (${lang.code})',
                          ),
                          avatar: isPrimary
                              ? Icon(
                                  Icons.star_rounded,
                                  size: 15,
                                  color: scheme.primary,
                                )
                              : null,
                          selected: selected,
                          visualDensity: VisualDensity.compact,
                          onSelected: isPrimary
                              ? null
                              : (_) => widget.prefs
                                  .toggleConfidentLanguage(lang.code),
                        );
                      }).toList(),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),

                // 2. AI Engine & Models Group
                _SettingsGroupCard(
                  icon: Icons.auto_awesome_outlined,
                  title: 'AI Engine & Models',
                  subtitle: aiSubtitle,
                  children: [
                    DropdownButtonFormField<AiProviderMode>(
                      isExpanded: true,
                      key: ValueKey(
                        'provider-${widget.prefs.aiProviderMode.name}',
                      ),
                      initialValue: widget.prefs.aiProviderMode,
                      decoration: const InputDecoration(
                        labelText: 'AI Provider Mode',
                        isDense: true,
                      ),
                      items: AiProviderMode.values
                          .map(
                            (m) => DropdownMenuItem(
                              value: m,
                              child: Text(
                                m.label,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          widget.prefs.setAiProviderMode(v);
                          widget.ai.resetCloudDiagnostics();
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      key: ValueKey(
                        'model-${models.contains(widget.prefs.selectedGeminiModel) ? widget.prefs.selectedGeminiModel : models.first}-${models.length}',
                      ),
                      initialValue:
                          models.contains(widget.prefs.selectedGeminiModel)
                              ? widget.prefs.selectedGeminiModel
                              : models.first,
                      decoration: const InputDecoration(
                        labelText: 'Gemini Model',
                        isDense: true,
                      ),
                      items: models
                          .map(
                            (m) => DropdownMenuItem(
                              value: m,
                              child: Text(
                                m,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          widget.prefs.setSelectedGeminiModel(v);
                          widget.ai.resetCloudDiagnostics();
                          _customModelCtrl.text = v;
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _customModelCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Custom Gemini Model ID',
                              hintText: 'e.g. gemini-3.5-flash-lite',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.xs),
                        FilledButton.tonal(
                          onPressed: () {
                            widget.prefs
                                .setSelectedGeminiModel(_customModelCtrl.text);
                            widget.ai.clearLastCloudError();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Model set to ${_customModelCtrl.text.trim()}',
                                ),
                              ),
                            );
                          },
                          child: const Text('Use'),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    OutlinedButton.icon(
                      onPressed: _isFetchingModels ? null : _fetchModels,
                      icon: _isFetchingModels
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded, size: 17),
                      label: const Text('Refresh Available Models'),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      shape: const Border(),
                      collapsedShape: const Border(),
                      title: Text(
                        'Personal Gemini API Key',
                        style: textTheme.titleSmall,
                      ),
                      subtitle: Text(
                        widget.prefs.hasPersonalGeminiApiKey
                            ? (widget.ai.activeCloudProvider ==
                                    AiProviderMode.personalGeminiApi
                                ? 'Active — used for Cloud AI requests'
                                : 'Key saved (switch mode to Gemini API or Auto)')
                            : 'Optional: use your Google AI Studio quota',
                        style: textTheme.bodySmall,
                      ),
                      children: [
                        TextField(
                          controller: _geminiKeyCtrl,
                          obscureText: _obscureKeys,
                          decoration: InputDecoration(
                            labelText: 'Google AI Studio API Key',
                            hintText: 'AIza...',
                            isDense: true,
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureKeys
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () =>
                                  setState(() => _obscureKeys = !_obscureKeys),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _isTestingAi
                                  ? null
                                  : () => _savePersonalGeminiKey(runTest: false),
                              icon: const Icon(Icons.key_rounded, size: 17),
                              label: const Text('Save Key'),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            FilledButton.tonalIcon(
                              onPressed: _isTestingAi
                                  ? null
                                  : () => _savePersonalGeminiKey(runTest: true),
                              icon: _isTestingAi
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.play_arrow_rounded,
                                      size: 17,
                                    ),
                              label: const Text('Save & Test'),
                            ),
                          ],
                        ),
                      ],
                    ),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      shape: const Border(),
                      collapsedShape: const Border(),
                      title: Text(
                        'OpenAI-Compatible Vision API',
                        style: textTheme.titleSmall,
                      ),
                      subtitle: Text(
                        widget.prefs.hasCustomAiConfig
                            ? 'Configured (${widget.prefs.customAiModel})'
                            : 'Optional: OpenAI, OpenRouter, Ollama, etc.',
                        style: textTheme.bodySmall,
                      ),
                      children: [
                        TextField(
                          controller: _customBaseUrlCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Base URL',
                            hintText: 'https://api.openai.com/v1',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        TextField(
                          controller: _customApiKeyCtrl,
                          obscureText: _obscureKeys,
                          decoration: const InputDecoration(
                            labelText: 'API Key',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        TextField(
                          controller: _customOpenAiModelCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Vision Model ID',
                            hintText: 'gpt-4o-mini',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.tonal(
                            onPressed: () async {
                              await widget.prefs.setCustomAiConfig(
                                baseUrl: _customBaseUrlCtrl.text,
                                apiKey: _customApiKeyCtrl.text,
                                model: _customOpenAiModelCtrl.text,
                              );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Custom AI settings saved'),
                                ),
                              );
                            },
                            child: const Text('Save Custom API'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),

                // 3. Cloud Sync Group (Zero-Knowledge E2EE Cloud Sync)
                _SettingsGroupCard(
                  icon: Icons.cloud_upload_outlined,
                  title: 'Cloud Backup & Sync',
                  subtitle: syncSubtitle,
                  children: [
                    _TierCard(
                      title: 'Zero-Knowledge E2EE Cloud Sync',
                      statusText: !fb.isConfigured
                          ? 'Off'
                          : fb.canSyncNow
                              ? 'Ready'
                              : fb.hasDeviceKey
                                  ? 'Locked'
                                  : 'Not Set Up',
                      isReady: fb.canSyncNow,
                      description: !fb.isConfigured
                          ? 'Firebase is not configured in this build.'
                          : fb.canSyncNow
                              ? 'Encrypted backup active${fb.activeKeyFingerprint != null ? ' (Key ${fb.activeKeyFingerprint})' : ''}. Locks automatically when you close the app.'
                              : fb.hasDeviceKey
                                  ? 'Your encryption key is stored on this device. Unlock to sync your places & routes.'
                                  : 'Initialize encrypted sync once to back up and sync your places & routes across devices.',
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed: !fb.isConfigured
                            ? null
                            : () => showFirebaseAuthSheet(
                                  context,
                                  firebaseSync: fb,
                                  store: widget.store,
                                ),
                        icon: Icon(
                          fb.canSyncNow
                              ? Icons.sync_rounded
                              : fb.hasDeviceKey
                                  ? (fb.supportsAndroidHardwareCache
                                      ? Icons.fingerprint_rounded
                                      : Icons.security_rounded)
                                  : Icons.rocket_launch_rounded,
                          size: 18,
                        ),
                        label: Text(
                          fb.canSyncNow
                              ? 'Sync & Link Devices'
                              : fb.hasDeviceKey
                                  ? (fb.supportsAndroidHardwareCache
                                      ? 'Unlock with Fingerprint'
                                      : 'Unlock with Passkey')
                                  : 'Initialize Cloud Sync',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),

                // 4. Offline Maps & On-Device OCR Group
                _SettingsGroupCard(
                  icon: Icons.map_outlined,
                  title: 'Offline Maps & On-Device OCR',
                  subtitle: mapSubtitle,
                  children: [
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        'Auto-cache nearby tiles',
                        style: textTheme.bodyMedium,
                      ),
                      subtitle: Text(
                        'Opt-in. Uses non-OSMF / configured bulk tile server (capped & throttled).',
                        style: textTheme.bodySmall,
                      ),
                      value: widget.prefs.autoPrefetchOfflineTiles,
                      onChanged: widget.prefs.setAutoPrefetchOfflineTiles,
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Download radius: ${widget.prefs.offlineMapRadiusKm.toStringAsFixed(1)} km',
                            style: textTheme.labelLarge,
                          ),
                        ),
                        Text(
                          '${cacheStats.tileCount} tiles (${cacheStats.totalMb.toStringAsFixed(1)} MB)',
                          style: textTheme.bodySmall,
                        ),
                      ],
                    ),
                    Slider(
                      value: widget.prefs.offlineMapRadiusKm.clamp(0.5, 2.0),
                      min: 0.5,
                      max: 2.0,
                      divisions: 3,
                      label:
                          '${widget.prefs.offlineMapRadiusKm.toStringAsFixed(1)} km',
                      onChanged: widget.prefs.setOfflineMapRadiusKm,
                    ),
                    if (cacheStats.tileCount > 0)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () async {
                            await widget.tiles.clearCache();
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Offline map tile cache cleared'),
                              ),
                            );
                          },
                          icon:
                              const Icon(Icons.delete_sweep_rounded, size: 18),
                          label: const Text('Clear Tile Cache'),
                        ),
                      ),
                    const Divider(height: 20),
                    _TierCard(
                      title: 'Gemini Nano 4 (${nano.deviceModel})',
                      statusText: nano.available ? 'Ready' : 'Fallback',
                      isReady: nano.available,
                      description: nano.reason,
                    ),
                    const SizedBox(height: 10),
                    const SectionLabel('Offline OCR Scripts'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: [
                        const FilterChip(
                          label: Text('Latin (Always On)'),
                          selected: true,
                          visualDensity: VisualDensity.compact,
                          onSelected: null,
                        ),
                        FilterChip(
                          label: const Text('Japanese (日本語)'),
                          selected: widget.ai.enableJapaneseOcr,
                          visualDensity: VisualDensity.compact,
                          onSelected: (v) =>
                              widget.ai.setOcrScripts(japanese: v),
                        ),
                        FilterChip(
                          label: const Text('Chinese (中文)'),
                          selected: widget.ai.enableChineseOcr,
                          visualDensity: VisualDensity.compact,
                          onSelected: (v) =>
                              widget.ai.setOcrScripts(chinese: v),
                        ),
                        FilterChip(
                          label: const Text('Korean (한국어)'),
                          selected: widget.ai.enableKoreanOcr,
                          visualDensity: VisualDensity.compact,
                          onSelected: (v) => widget.ai.setOcrScripts(korean: v),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: AppSpacing.md),

                // Direct Support Button
                FilledButton.icon(
                  onPressed: () => showBitcoinPaymentSheet(context),
                  style: FilledButton.styleFrom(
                    backgroundColor: semantic.accent,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.favorite_rounded),
                  label: const Text('Support Edge Mapper'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SettingsGroupCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;

  const _SettingsGroupCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SurfacePanel(
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 2,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            0,
            AppSpacing.md,
            AppSpacing.md,
          ),
          leading: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(AppRadii.sm),
            ),
            child: Icon(icon, size: 19, color: scheme.primary),
          ),
          title: Text(title, style: textTheme.titleSmall),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall,
          ),
          children: [
            const Divider(height: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ],
        ),
      ),
    );
  }
}

class _TierCard extends StatelessWidget {
  final String title;
  final String statusText;
  final bool isReady;
  final String description;

  const _TierCard({
    required this.title,
    required this.statusText,
    required this.isReady,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final semantic = context.semanticColors;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: isReady ? semantic.successContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(
          color: isReady
              ? semantic.success.withValues(alpha: 0.4)
              : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: textTheme.labelLarge?.copyWith(fontSize: 13),
                ),
              ),
              SubtleTag(
                label: statusText,
                tint: isReady ? semantic.success : null,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
