import 'package:flutter/material.dart';

import '../services/osm_publish_service.dart';
import '../services/secure_vault_backend.dart';
import '../services/user_preferences_service.dart';
import 'responsive_layout.dart';

Future<bool?> showOsmAuthSheet(
  BuildContext context, {
  required OsmPublishService osm,
  required UserPreferencesService prefs,
}) {
  return showAdaptiveSheet<bool>(
    context: context,
    desktopMaxWidth: 520,
    builder: (_) => OsmAuthSheet(osm: osm, prefs: prefs),
  );
}

class OsmAuthSheet extends StatefulWidget {
  final OsmPublishService osm;
  final UserPreferencesService prefs;

  const OsmAuthSheet({
    super.key,
    required this.osm,
    required this.prefs,
  });

  @override
  State<OsmAuthSheet> createState() => _OsmAuthSheetState();
}

class _OsmAuthSheetState extends State<OsmAuthSheet> {
  bool _busy = false;
  bool _awaitingBrowser = false;
  String? _statusMessage;
  bool _statusIsError = false;

  @override
  void dispose() {
    if (_awaitingBrowser) {
      widget.osm.cancelPendingOAuth();
    }
    super.dispose();
  }

  void _setStatus(String msg, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = msg;
      _statusIsError = isError;
    });
  }

  Future<void> _signInWithOsm() async {
    if (!widget.osm.isOAuthConfigured) {
      final envKey = widget.osm.isSandbox
          ? 'OSM_SANDBOX_CLIENT_ID'
          : 'OSM_CLIENT_ID';
      _setStatus(
        'OpenStreetMap sign-in is not configured in this build ($envKey is missing).',
        isError: true,
      );
      return;
    }

    setState(() {
      _busy = true;
      _awaitingBrowser = true;
      _statusMessage = null;
    });
    try {
      final profile = await widget.osm.beginInteractiveOAuth();
      if (!mounted) return;
      if (profile != null) {
        _setStatus(
          'Signed in as ${profile.displayName} on ${widget.osm.serverLabel}!',
        );
      } else {
        _setStatus('Sign-in cancelled.');
      }
    } catch (e) {
      _setStatus(
        e
            .toString()
            .replaceFirst('Exception: ', '')
            .replaceFirst('Bad state: ', ''),
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _awaitingBrowser = false;
        });
      }
    }
  }

  void _cancelSignIn() {
    widget.osm.cancelPendingOAuth();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _awaitingBrowser = false;
      _statusMessage = 'Sign-in cancelled.';
      _statusIsError = false;
    });
  }

  Future<void> _verifyConnection() async {
    setState(() {
      _busy = true;
      _statusMessage = null;
    });
    try {
      final profile = await widget.osm.fetchUserDetails();
      if (!mounted) return;
      _setStatus(
        'Verified: ${profile.displayName} (ID #${profile.id}, ${profile.changesetsCount} changesets)',
      );
    } catch (e) {
      _setStatus(
        e.toString().replaceFirst('Exception: ', ''),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: Listenable.merge([widget.osm, widget.prefs]),
      builder: (context, _) {
        final isAuthed = widget.osm.isAuthenticated;
        final isSandbox = widget.osm.isSandbox;
        final isConfigured = widget.osm.isOAuthConfigured;
        final isWide = AppBreakpoints.isWide(context);

        return AdaptiveModalScrollContainer(
          initialChildSize: 0.72,
          minChildSize: 0.45,
          maxChildSize: 0.92,
          builder: (context, scrollCtrl) => SingleChildScrollView(
            controller: scrollCtrl,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isWide)
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    Icon(Icons.public_rounded, color: scheme.primary, size: 26),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'OpenStreetMap Account',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(context, isAuthed),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Target Server Selector (Live vs Sandbox)
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment<bool>(
                      value: false,
                      icon: Icon(Icons.public_rounded, size: 17),
                      label: Text('Live OSM'),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      icon: Icon(Icons.science_rounded, size: 17),
                      label: Text('Dev Sandbox'),
                    ),
                  ],
                  selected: {isSandbox},
                  onSelectionChanged: _busy
                      ? null
                      : (selection) async {
                          await widget.prefs.setOsmUseSandbox(selection.first);
                          _setStatus(
                            selection.first
                                ? 'Switched to OSM Dev Sandbox (safe for test uploads).'
                                : 'Switched to Live OpenStreetMap (openstreetmap.org).',
                          );
                        },
                ),
                const SizedBox(height: 6),
                Text(
                  isSandbox
                      ? 'Server: master.apis.dev.openstreetmap.org (separate sandbox account for testing)'
                      : 'Server: openstreetmap.org (live public OpenStreetMap map)',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 14),

                if (widget.prefs.isVaultLocked && widget.prefs.vault != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD97706).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFFD97706).withValues(alpha: 0.45),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.lock_rounded,
                              size: 18,
                              color: Color(0xFFB45309),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Encrypted Vault Locked',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                  color: Color(0xFFB45309),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Unlock your ${widget.prefs.vault!.mode.displayLabel} vault to decrypt your saved OSM login token.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        FilledButton.tonalIcon(
                          onPressed: _busy
                              ? null
                              : () async {
                                  final v = widget.prefs.vault!;
                                  setState(() => _busy = true);
                                  try {
                                    if (v.mode ==
                                        VaultProtectionMode.passkeyPrf) {
                                      await v.unlockWithPasskey();
                                    } else if (v.mode ==
                                        VaultProtectionMode.osBiometric) {
                                      await v.unlockWithOsBiometric();
                                    }
                                    if (!mounted) return;
                                    _setStatus('Encrypted vault unlocked!');
                                  } catch (e) {
                                    _setStatus(
                                      e
                                          .toString()
                                          .replaceFirst('Exception: ', ''),
                                      isError: true,
                                    );
                                  } finally {
                                    if (mounted) setState(() => _busy = false);
                                  }
                                },
                          icon: const Icon(Icons.key_rounded, size: 17),
                          label: Text(
                            widget.prefs.vault!.mode ==
                                    VaultProtectionMode.passkeyPrf
                                ? 'Unlock with Passkey (Bitwarden / YubiKey)'
                                : 'Unlock Encrypted Vault',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // Connected Account Status Card
                Card(
                  elevation: 0,
                  color: (isAuthed
                          ? const Color(0xFF059669)
                          : scheme.surfaceContainerHighest)
                      .withValues(alpha: isAuthed ? 0.12 : 0.6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: isAuthed
                          ? const Color(0xFF059669).withValues(alpha: 0.45)
                          : scheme.outlineVariant,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Icon(
                          isAuthed
                              ? Icons.verified_user_rounded
                              : Icons.person_outline_rounded,
                          color: isAuthed
                              ? const Color(0xFF059669)
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isAuthed
                                    ? (widget.osm.username.isNotEmpty
                                        ? widget.osm.username
                                        : 'Connected')
                                    : 'Not Signed In',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 14.5,
                                ),
                              ),
                              Text(
                                isAuthed
                                    ? 'Authenticated on ${widget.osm.serverLabel}'
                                    : 'Sign in with OpenStreetMap to publish places & GPX routes directly.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        if (isAuthed) ...[
                          IconButton(
                            tooltip: 'Verify session',
                            onPressed: _busy ? null : _verifyConnection,
                            icon: const Icon(Icons.refresh_rounded, size: 20),
                          ),
                          TextButton(
                            onPressed: _busy ? null : widget.osm.signOut,
                            style: TextButton.styleFrom(
                              foregroundColor: scheme.error,
                            ),
                            child: const Text('Sign Out'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                if (_statusMessage != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: (_statusIsError
                              ? const Color(0xFFDC2626)
                              : const Color(0xFF059669))
                          .withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: (_statusIsError
                                ? const Color(0xFFDC2626)
                                : const Color(0xFF059669))
                            .withValues(alpha: 0.45),
                      ),
                    ),
                    child: Text(
                      _statusMessage!,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: _statusIsError
                            ? const Color(0xFFB91C1C)
                            : const Color(0xFF047857),
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 18),

                if (!isConfigured) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD97706).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFFD97706).withValues(alpha: 0.45),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 18,
                              color: Color(0xFFB45309),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Sign-In Unavailable in This Build',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13.5,
                                  color: Color(0xFFB45309),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'OpenStreetMap OAuth sign-in for ${widget.osm.serverLabel} has not been enabled by the app developer in this build '
                          '(missing ${isSandbox ? 'OSM_SANDBOX_CLIENT_ID' : 'OSM_CLIENT_ID'} in .env).',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                height: 1.4,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ] else ...[
                  Text(
                    'Log in on ${widget.osm.serverLabel} and authorize Edge Mapper. '
                    'You will be returned here automatically once authorized.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                  ),
                  const SizedBox(height: 14),
                ],

                FilledButton.icon(
                  onPressed: (_busy || !isConfigured) ? null : _signInWithOsm,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: _busy
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.login_rounded, size: 19),
                  label: Text(
                    _awaitingBrowser
                        ? 'Waiting for OpenStreetMap...'
                        : (isAuthed
                            ? 'Re-authorize ${widget.osm.serverLabel}'
                            : 'Sign in with ${isSandbox ? 'OSM Dev Sandbox' : 'OpenStreetMap'}'),
                  ),
                ),

                if (_awaitingBrowser) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _cancelSignIn,
                    child: const Text('Cancel'),
                  ),
                ],

                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Permissions requested: read profile, edit map & upload GPX. Token encrypted on device.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontSize: 11.5,
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
