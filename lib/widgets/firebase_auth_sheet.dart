import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/firebase_sync_service.dart';
import '../services/mapper_store.dart';
import '../services/password_manager_bridge.dart';
import '../theme/app_theme.dart';
import 'qr_code_widget.dart';
import 'responsive_layout.dart';

Future<bool?> showFirebaseAuthSheet(
  BuildContext context, {
  required FirebaseSyncService firebaseSync,
  MapperStore? store,
}) {
  return showAdaptiveSheet<bool>(
    context: context,
    desktopMaxWidth: 500,
    builder: (_) => FirebaseAuthSheet(
      firebaseSync: firebaseSync,
      store: store,
    ),
  );
}

/// Simple, user-friendly Zero-Knowledge E2EE Cloud Sync Sheet:
/// - **No key on this device yet**: Invites the user to initialize encrypted
///   sync once (creates the single device key), or link an existing device.
/// - **Key exists on this device (locked)**: 1-tap unlock via Android Keystore
///   (Fingerprint) or WebAuthn Passkey — never creates a duplicate key.
/// - **Unlocked**: One smart **Sync Now** button (automatically checks Firestore
///   and transfers only what is missing or updated), a simple **Sync Another
///   Device** QR/Copy panel, and automatic lock when the app closes.
class FirebaseAuthSheet extends StatefulWidget {
  final FirebaseSyncService firebaseSync;
  final MapperStore? store;

  const FirebaseAuthSheet({
    super.key,
    required this.firebaseSync,
    this.store,
  });

  @override
  State<FirebaseAuthSheet> createState() => _FirebaseAuthSheetState();
}

class _FirebaseAuthSheetState extends State<FirebaseAuthSheet> {
  final _linkKeyCtrl = TextEditingController();

  bool _obscureKeyInput = true;
  bool _busy = false;
  bool _showConnectAnotherDevice = false;
  bool _showQrCode = false;

  String? _optionalRecoveryKeyBackup;
  String? _statusMessage;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    // Refresh device key state, Android Keystore hardware cache & remote keyring
    // ignore: unawaited_futures
    widget.firebaseSync.refreshSessionAndTryAutoUnlock();
  }

  @override
  void didUpdateWidget(covariant FirebaseAuthSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.firebaseSync != widget.firebaseSync) {
      // ignore: unawaited_futures
      widget.firebaseSync.refreshSessionAndTryAutoUnlock();
    }
  }

  @override
  void dispose() {
    _optionalRecoveryKeyBackup = null;
    _linkKeyCtrl.dispose();
    super.dispose();
  }

  void _setStatus(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = message;
      _statusIsError = isError;
    });
  }

  String _formatSyncResult(FirebaseSyncResult result) {
    final photoNote = result.photosSynced > 0
        ? ' (${result.photosSynced} photo${result.photosSynced == 1 ? '' : 's'})'
        : '';
    if (result.hasErrors && result.totalSynced == 0) {
      return result.errors.first;
    }
    if (result.totalSynced == 0) {
      return 'Everything is up to date.';
    }
    final parts = <String>[
      if (result.totalPulled > 0) '↓${result.totalPulled} pulled',
      if (result.totalPushed > 0) '↑${result.totalPushed} uploaded$photoNote',
      if (result.totalDeleted > 0)
        '${result.totalDeleted} removed from Firestore',
    ];
    final suffix =
        result.hasErrors ? ' (${result.errors.length} failed)' : '';
    return 'Synced · ${parts.join(' · ')}$suffix';
  }

  Future<String> _runPostUnlockSync() async {
    final store = widget.store;
    if (store == null) return 'Ready to sync.';
    final result = await store.syncAllUnsyncedToFirebase();
    return _formatSyncResult(result);
  }

  Future<void> _initializeCloudSync() async {
    final fb = widget.firebaseSync;
    setState(() {
      _busy = true;
      _statusMessage = fb.supportsAndroidHardwareCache
          ? 'Creating your device key...'
          : fb.supportsWebAuthnPrf
              ? 'Creating your Passkey...'
              : 'Initializing encrypted sync...';
      _statusIsError = false;
    });
    try {
      final res = await fb.initializeDeviceVault();
      if (!mounted) return;
      if (res.recoveryKey.isNotEmpty) {
        setState(() => _optionalRecoveryKeyBackup = res.recoveryKey);
      }
      final syncMsg = await _runPostUnlockSync();
      if (!mounted) return;
      _setStatus('Cloud Sync initialized! $syncMsg');
    } on PrfUnsupportedException catch (e) {
      if (!mounted) return;
      setState(() => _showConnectAnotherDevice = true);
      _setStatus(e.message, isError: true);
    } catch (e) {
      _setStatus(
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlockDeviceKey() async {
    final fb = widget.firebaseSync;
    setState(() {
      _busy = true;
      _statusMessage = fb.supportsAndroidHardwareCache
          ? 'Waiting for fingerprint...'
          : 'Waiting for Passkey...';
      _statusIsError = false;
    });
    try {
      if (fb.supportsAndroidHardwareCache && fb.hasAndroidHardwareCache) {
        await fb.unlockWithAndroidKeystore();
      } else {
        await fb.signInAndUnlockWithPasskeyPrf();
      }
      if (!mounted) return;
      final syncMsg = await _runPostUnlockSync();
      if (!mounted) return;
      _setStatus('Unlocked! $syncMsg');
    } on PrfUnsupportedException catch (e) {
      if (!mounted) return;
      setState(() => _showConnectAnotherDevice = true);
      _setStatus(e.message, isError: true);
    } catch (e) {
      _setStatus(
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInWithExistingPasskey() async {
    setState(() {
      _busy = true;
      _statusMessage = 'Waiting for your Passkey...';
      _statusIsError = false;
    });
    try {
      await widget.firebaseSync.signInAndUnlockWithPasskeyPrf();
      if (!mounted) return;
      final syncMsg = await _runPostUnlockSync();
      if (!mounted) return;
      _setStatus('Connected! $syncMsg');
    } catch (e) {
      _setStatus(
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectWithKey() async {
    final key = _linkKeyCtrl.text.trim();
    if (key.isEmpty) {
      _setStatus(
        'Paste the Sync Key from your other device or autofill from Bitwarden.',
        isError: true,
      );
      return;
    }
    setState(() {
      _busy = true;
      _statusMessage = 'Connecting & syncing your encrypted data...';
      _statusIsError = false;
    });
    try {
      TextInput.finishAutofillContext();
      await widget.firebaseSync.signInAndUnlockWithAnyKey(key);
      if (!mounted) return;
      _linkKeyCtrl.clear();
      final syncMsg = await _runPostUnlockSync();
      if (!mounted) return;
      _setStatus('Device connected! $syncMsg');
    } catch (e) {
      _setStatus(
        e
            .toString()
            .replaceFirst('Exception: ', '')
            .replaceFirst('FormatException: ', ''),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _attachPasskeyPrf() async {
    setState(() {
      _busy = true;
      _statusMessage = 'Setting up Passkey...';
      _statusIsError = false;
    });
    try {
      await widget.firebaseSync.attachPasskeyPrfToUnlockedKeyring();
      if (!mounted) return;
      _setStatus('Passkey enabled for this browser.');
    } catch (e) {
      _setStatus(
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fillFromPasswordManager() async {
    final saved = await PasswordManagerBridge.retrieveSavedSyncKey();
    if (!mounted) return;
    if (saved != null && saved.isNotEmpty) {
      setState(() => _linkKeyCtrl.text = saved);
      _setStatus('Filled key from Bitwarden / password manager.');
    } else {
      _setStatus('Tap the key box for Bitwarden autofill, or paste your key.');
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _setStatus('Clipboard is empty.', isError: true);
      return;
    }
    setState(() => _linkKeyCtrl.text = text);
  }

  Future<void> _saveKeyToBitwarden(String key, {required String label}) async {
    final res = await PasswordManagerBridge.saveSyncKey(
      accountLabel: label,
      syncKey: key,
    );
    if (!mounted) return;
    _setStatus(res.message);
  }

  Future<void> _copySyncKey(String secret) async {
    await PasswordManagerBridge.copySecretToClipboard(secret);
    if (!mounted) return;
    _setStatus('Sync Key copied. Paste it on your other device.');
  }

  Future<void> _runSync() async {
    final store = widget.store;
    if (store == null) return;
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      final result = await store.syncAllUnsyncedToFirebase();
      if (!mounted) return;
      _setStatus(
        _formatSyncResult(result),
        isError: result.hasErrors,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAllCloudDataWithConfirm() async {
    final store = widget.store;
    if (store == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete cloud backup?'),
        content: const Text(
          'This removes all encrypted records and routes from Firestore.\n\n'
          'Your local copy on this device will NOT be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete Cloud Data'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      final wipe = await store.deleteAllCloudDataKeepLocal();
      if (!mounted) return;
      if (wipe.hasErrors && wipe.totalDeleted == 0) {
        _setStatus('Cloud delete failed: ${wipe.errors.first}', isError: true);
      } else {
        _setStatus(
          'Deleted ${wipe.recordsDeleted} record${wipe.recordsDeleted == 1 ? '' : 's'} & '
          '${wipe.trailsDeleted} route${wipe.trailsDeleted == 1 ? '' : 's'} from cloud. Local copy kept.',
        );
      }
    } catch (e) {
      _setStatus('Cloud delete failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final semantic = context.semanticColors;

    return ListenableBuilder(
      listenable: widget.store != null
          ? Listenable.merge([widget.firebaseSync, widget.store!])
          : widget.firebaseSync,
      builder: (context, _) {
        final fb = widget.firebaseSync;
        final isUnlocked = fb.canSyncNow;
        final hasDeviceKey = fb.hasDeviceKey;
        final supportsPrf = fb.supportsWebAuthnPrf;
        final supportsAndroidKs = fb.supportsAndroidHardwareCache;
        final syncKey = isUnlocked ? fb.exportX25519SyncKey() : null;
        final fp = fb.activeKeyFingerprint ?? '';

        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      isUnlocked
                          ? Icons.cloud_done_rounded
                          : hasDeviceKey
                              ? (supportsAndroidKs
                                  ? Icons.fingerprint_rounded
                                  : Icons.security_rounded)
                              : Icons.cloud_sync_rounded,
                      color: isUnlocked ? semantic.success : scheme.primary,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        'Cloud Sync',
                        style: textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(isUnlocked),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'End-to-end encrypted backup & sync across your devices.',
                  style: textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.md),

                if (!fb.isAuthAvailable)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(AppRadii.md),
                    ),
                    child: Text(
                      'Firebase is not configured in this build.',
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  )
                // STATE 1 & 2: NOT UNLOCKED YET (Either Initialize OR Unlock existing device key)
                else if (!isUnlocked) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      border: Border.all(
                        color: scheme.primary.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hasDeviceKey
                              ? (supportsAndroidKs
                                  ? 'Unlock with Fingerprint'
                                  : 'Unlock with Passkey')
                              : 'Set Up Cloud Sync',
                          style: textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          hasDeviceKey
                              ? (supportsAndroidKs
                                  ? 'Your encryption key is stored on this device. Unlock to sync your places & routes.'
                                  : 'Use your Passkey to unlock and sync your encrypted places & routes.')
                              : (supportsAndroidKs
                                  ? 'Create your encryption key once. Only your fingerprint is needed to unlock it.'
                                  : supportsPrf
                                      ? 'Create your Passkey once to encrypt and sync your places & routes.'
                                      : 'Create your encryption key once to back up and sync your places & routes.'),
                          style: textTheme.bodySmall,
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _busy
                                ? null
                                : (hasDeviceKey
                                    ? _unlockDeviceKey
                                    : _initializeCloudSync),
                            icon: _busy
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    hasDeviceKey
                                        ? (supportsAndroidKs
                                            ? Icons.fingerprint_rounded
                                            : Icons.security_rounded)
                                        : Icons.rocket_launch_rounded,
                                  ),
                            label: Text(
                              hasDeviceKey
                                  ? (supportsAndroidKs
                                      ? 'Unlock with Fingerprint'
                                      : 'Unlock with Passkey')
                                  : 'Initialize Cloud Sync',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),

                  // Secondary: Connect to an existing device / Bitwarden backup
                  if (!_showConnectAnotherDevice)
                    Center(
                      child: TextButton.icon(
                        onPressed: () =>
                            setState(() => _showConnectAnotherDevice = true),
                        icon: const Icon(Icons.devices_rounded, size: 16),
                        label: Text(
                          hasDeviceKey
                              ? 'Use key from another device'
                              : 'Already using another device?',
                        ),
                      ),
                    )
                  else ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Connect Existing Device',
                            style: textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Paste the Sync Key from your other device (or autofill from Bitwarden).',
                            style: textTheme.bodySmall,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          if (supportsPrf && !hasDeviceKey) ...[
                            OutlinedButton.icon(
                              onPressed:
                                  _busy ? null : _signInWithExistingPasskey,
                              icon: const Icon(
                                Icons.security_rounded,
                                size: 18,
                              ),
                              label: const Text('Use Existing Passkey'),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                          ],
                          AutofillGroup(
                            child: TextFormField(
                              controller: _linkKeyCtrl,
                              enabled: !_busy,
                              obscureText: _obscureKeyInput,
                              autofillHints: const [AutofillHints.password],
                              textInputAction: TextInputAction.done,
                              onFieldSubmitted: (_) {
                                if (!_busy) _connectWithKey();
                              },
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                              ),
                              decoration: InputDecoration(
                                labelText: 'Sync Key',
                                hintText: 'Paste key from other device',
                                prefixIcon: const Icon(
                                  Icons.vpn_key_outlined,
                                  size: 18,
                                ),
                                isDense: true,
                                suffixIcon: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      constraints: const BoxConstraints(
                                        minWidth: 34,
                                        minHeight: 34,
                                      ),
                                      tooltip: 'Autofill from Bitwarden',
                                      onPressed: _busy
                                          ? null
                                          : _fillFromPasswordManager,
                                      icon: const Icon(
                                        Icons.shield_outlined,
                                        size: 18,
                                      ),
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      constraints: const BoxConstraints(
                                        minWidth: 34,
                                        minHeight: 34,
                                      ),
                                      tooltip: 'Paste key',
                                      onPressed:
                                          _busy ? null : _pasteFromClipboard,
                                      icon: const Icon(
                                        Icons.content_paste_rounded,
                                        size: 18,
                                      ),
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      constraints: const BoxConstraints(
                                        minWidth: 34,
                                        minHeight: 34,
                                      ),
                                      tooltip: _obscureKeyInput
                                          ? 'Show Key'
                                          : 'Hide Key',
                                      onPressed: () => setState(
                                        () => _obscureKeyInput =
                                            !_obscureKeyInput,
                                      ),
                                      icon: Icon(
                                        _obscureKeyInput
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined,
                                        size: 18,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          FilledButton.tonalIcon(
                            onPressed: _busy ? null : _connectWithKey,
                            icon: _busy
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.link_rounded),
                            label: const Text('Connect & Sync'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ]
                // STATE 3: UNLOCKED — One Sync Button + Simple Sync Another Device
                else ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: semantic.successContainer.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(AppRadii.md),
                      border: Border.all(
                        color: semantic.success.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.verified_user_rounded,
                          size: 18,
                          color: semantic.success,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Encrypted Sync Active${fp.isNotEmpty ? ' · $fp' : ''}',
                                style: textTheme.titleSmall,
                              ),
                              Text(
                                'Locks automatically when you close the app.',
                                style: textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),

                  // ONE smart Sync button: checks Firestore & syncs only what's missing or updated
                  if (widget.store != null) ...[
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _runSync,
                        icon: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sync_rounded),
                        label: const Text('Sync Now'),
                      ),
                    ),
                    if (widget.store!.hasPendingRemoteDeletes) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${widget.store!.pendingRemoteDeleteCount} removed item${widget.store!.pendingRemoteDeleteCount == 1 ? '' : 's'} waiting to be deleted from Firestore.',
                        style: textTheme.bodySmall?.copyWith(
                          color: semantic.danger,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                  ],

                  // Simple, User-Friendly "Sync Another Device" card
                  if (syncKey != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(AppRadii.md),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.devices_rounded,
                                size: 18,
                                color: scheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Sync Another Device',
                                  style: textTheme.titleSmall,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'On your other phone or computer, open Cloud Sync, tap "Already using another device?", and scan or paste this key.',
                            style: textTheme.bodySmall,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.tonalIcon(
                                  onPressed: () =>
                                      setState(() => _showQrCode = !_showQrCode),
                                  icon: const Icon(
                                    Icons.qr_code_2_rounded,
                                    size: 18,
                                  ),
                                  label: Text(
                                    _showQrCode ? 'Hide QR' : 'Show QR',
                                  ),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => _copySyncKey(syncKey),
                                  icon: const Icon(
                                    Icons.copy_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Copy Key'),
                                ),
                              ),
                            ],
                          ),
                          if (_showQrCode) ...[
                            const SizedBox(height: AppSpacing.sm),
                            Center(
                              child: QrCodeWidget(
                                data: syncKey,
                                size: 200,
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 4,
                            children: [
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () => _saveKeyToBitwarden(
                                  _optionalRecoveryKeyBackup ?? syncKey,
                                  label:
                                      'Edge Mapper Sync (${fp.isNotEmpty ? fp : 'Key'})',
                                ),
                                icon: const Icon(
                                  Icons.shield_outlined,
                                  size: 15,
                                ),
                                label: const Text('Backup to Bitwarden'),
                              ),
                              if (supportsPrf && !fb.hasPrfSlot)
                                TextButton.icon(
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: _busy ? null : _attachPasskeyPrf,
                                  icon: const Icon(
                                    Icons.security_rounded,
                                    size: 15,
                                  ),
                                  label: const Text('Enable Passkey'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                  ],

                  if (widget.store != null)
                    Center(
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.error,
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed:
                            _busy ? null : _deleteAllCloudDataWithConfirm,
                        icon: const Icon(Icons.cloud_off_rounded, size: 16),
                        label: const Text('Delete Cloud Data (Keep Local)'),
                      ),
                    ),
                ],

                if (_statusMessage != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: (_statusIsError
                              ? scheme.errorContainer
                              : semantic.successContainer)
                          .withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                    ),
                    child: Text(
                      _statusMessage!,
                      style: textTheme.bodySmall?.copyWith(
                        color: _statusIsError
                            ? scheme.onErrorContainer
                            : semantic.onSuccessContainer,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
