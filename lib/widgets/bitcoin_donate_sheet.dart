import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/bitcoin_service.dart';
import 'qr_code_widget.dart';
import 'responsive_layout.dart';

/// Opens the Bitcoin payment / developer donation modal.
///
/// - When [recipientAddress] is omitted, displays all developer donation methods
///   configured via environment variables (`BTC_DONATION_URI`,
///   `BTC_DONATION_P2TR_ADDRESS`, `BTC_DONATION_LIGHTNING_ADDRESS`,
///   `BTC_DONATION_SILENT_PAYMENT_ADDRESS`, `BTC_DONATION_BTCPAY_URL`).
/// - Lightning Address (email format) and BOLT 12 URI/Offer are merged under a
///   single **Lightning** tab with a clean toggle between both formats.
/// - On-chain addresses (Taproot / SegWit / Legacy) appear under **Onchain**.
Future<bool?> showBitcoinPaymentSheet(
  BuildContext context, {
  String? title,
  String? subtitle,
  String? recipientAddress,
  String? lightningAddress,
  BitcoinDonationConfig? donationConfig,
  int? fixedSats,
  String? paymentLabel,
  String? paymentMessage,
  bool showMarkAsPaidButton = false,
}) {
  final List<BitcoinPaymentOption> options;
  if (recipientAddress != null && recipientAddress.trim().isNotEmpty) {
    options = [
      BitcoinService.optionFromDestination(recipientAddress.trim()),
      if (lightningAddress != null &&
          lightningAddress.trim().isNotEmpty &&
          lightningAddress.trim() != recipientAddress.trim())
        BitcoinService.optionFromDestination(lightningAddress.trim()),
    ];
  } else {
    final config = donationConfig ?? BitcoinService.developerDonationConfig;
    options = config.availableOptions;
  }

  return showAdaptiveSheet<bool>(
    context: context,
    desktopMaxWidth: 500,
    builder: (_) => BitcoinPaymentSheet(
      title: title ?? 'Support Edge Mapper',
      subtitle: subtitle ??
          'Help keep Edge Mapper open, private, and ad-free for everyone.',
      options: options,
      fixedSats: fixedSats,
      paymentLabel: paymentLabel ?? 'Edge Mapper Support',
      paymentMessage: paymentMessage ?? 'Thank you for supporting Edge Mapper!',
      showMarkAsPaidButton: showMarkAsPaidButton,
    ),
  );
}

class _MergedPaymentTab {
  final BitcoinPaymentMethod method;
  final String label;
  final BitcoinPaymentOption primary;
  final BitcoinPaymentOption? emailLightning;
  final BitcoinPaymentOption? bolt12Lightning;

  const _MergedPaymentTab({
    required this.method,
    required this.label,
    required this.primary,
    this.emailLightning,
    this.bolt12Lightning,
  });

  bool get hasBothLightningModes =>
      emailLightning != null && bolt12Lightning != null;
}

class BitcoinPaymentSheet extends StatefulWidget {
  final String title;
  final String subtitle;
  final List<BitcoinPaymentOption> options;
  final int? fixedSats;
  final String paymentLabel;
  final String paymentMessage;
  final bool showMarkAsPaidButton;

  const BitcoinPaymentSheet({
    super.key,
    required this.title,
    required this.subtitle,
    required this.options,
    this.fixedSats,
    required this.paymentLabel,
    required this.paymentMessage,
    required this.showMarkAsPaidButton,
  });

  @override
  State<BitcoinPaymentSheet> createState() => _BitcoinPaymentSheetState();
}

class _BitcoinPaymentSheetState extends State<BitcoinPaymentSheet> {
  int _selectedTabIndex = 0;
  bool _useBolt12ForLightning = false;
  bool _isResolvingInvoice = false;
  int? _selectedSats;
  late TextEditingController _customSatsCtrl;
  late List<_MergedPaymentTab> _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = _buildMergedTabs(widget.options);
    // If Lightning tab only has BOLT 12 (no email-style Lightning address), default to BOLT 12
    for (final tab in _tabs) {
      if (tab.method == BitcoinPaymentMethod.lightning) {
        _useBolt12ForLightning =
            tab.emailLightning == null && tab.bolt12Lightning != null;
        break;
      }
    }
    _selectedSats = widget.fixedSats ?? 10000;
    _customSatsCtrl = TextEditingController(
      text: _selectedSats != null ? '$_selectedSats' : '',
    );
  }

  @override
  void didUpdateWidget(covariant BitcoinPaymentSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.options != widget.options) {
      _tabs = _buildMergedTabs(widget.options);
      if (_selectedTabIndex >= _tabs.length) {
        _selectedTabIndex = 0;
      }
    }
  }

  @override
  void dispose() {
    _customSatsCtrl.dispose();
    super.dispose();
  }

  static bool _isBolt12Option(BitcoinPaymentOption opt) {
    if (opt.kind == BitcoinAddressKind.bolt12Offer) return true;
    if (opt.method == BitcoinPaymentMethod.bitcoinUri) {
      final parsed = Uri.tryParse(opt.value.trim());
      final hasLno = (parsed?.queryParameters['lno'] ?? '').isNotEmpty;
      final hasPath = (parsed?.path ?? '').isNotEmpty;
      final hasSp = (parsed?.queryParameters['sp'] ?? '').isNotEmpty;
      return hasLno && !hasPath && !hasSp;
    }
    return false;
  }

  static bool _isEmailLightningOption(BitcoinPaymentOption opt) =>
      opt.kind == BitcoinAddressKind.lightningAddress ||
      opt.kind == BitcoinAddressKind.lnurl;

  static List<_MergedPaymentTab> _buildMergedTabs(
    List<BitcoinPaymentOption> rawOptions,
  ) {
    BitcoinPaymentOption? emailLn;
    BitcoinPaymentOption? bolt12Ln;
    int? firstLightningPos;
    final nonLightning = <BitcoinPaymentOption>[];

    for (final opt in rawOptions) {
      if (_isEmailLightningOption(opt)) {
        emailLn ??= opt;
        firstLightningPos ??= nonLightning.length;
      } else if (_isBolt12Option(opt)) {
        bolt12Ln ??= opt;
        firstLightningPos ??= nonLightning.length;
      } else {
        nonLightning.add(opt);
      }
    }

    final tabs = <_MergedPaymentTab>[];
    for (final opt in nonLightning) {
      final label =
          opt.method == BitcoinPaymentMethod.onChain ? 'Onchain' : opt.chipLabel;
      tabs.add(
        _MergedPaymentTab(
          method: opt.method,
          label: label,
          primary: opt,
        ),
      );
    }

    if (emailLn != null || bolt12Ln != null) {
      final mergedLnTab = _MergedPaymentTab(
        method: BitcoinPaymentMethod.lightning,
        label: 'Lightning',
        primary: emailLn ?? bolt12Ln!,
        emailLightning: emailLn,
        bolt12Lightning: bolt12Ln,
      );
      final insertAt = (firstLightningPos ?? 0).clamp(0, tabs.length);
      tabs.insert(insertAt, mergedLnTab);
    }

    return tabs;
  }

  _MergedPaymentTab? get _activeTab => _tabs.isEmpty
      ? null
      : _tabs[_selectedTabIndex.clamp(0, _tabs.length - 1)];

  BitcoinPaymentOption? get _activeOption {
    final tab = _activeTab;
    if (tab == null) return null;
    if (tab.method == BitcoinPaymentMethod.lightning) {
      if (_useBolt12ForLightning && tab.bolt12Lightning != null) {
        return tab.bolt12Lightning;
      }
      return tab.emailLightning ?? tab.bolt12Lightning ?? tab.primary;
    }
    return tab.primary;
  }

  String get _paymentUri {
    final option = _activeOption;
    if (option == null) return '';
    return option.buildPaymentUri(
      amountSats: _selectedSats,
      label: widget.paymentLabel,
      message: widget.paymentMessage,
    );
  }

  IconData _iconForMethod(BitcoinPaymentMethod method) => switch (method) {
        BitcoinPaymentMethod.btcPayServer => Icons.storefront_rounded,
        BitcoinPaymentMethod.bitcoinUri => Icons.qr_code_2_rounded,
        BitcoinPaymentMethod.silentPayment => Icons.privacy_tip_rounded,
        BitcoinPaymentMethod.lightning => Icons.bolt_rounded,
        BitcoinPaymentMethod.onChain => Icons.currency_bitcoin_rounded,
      };

  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied $label to clipboard')),
    );
  }

  Future<String> _resolveEffectivePaymentUri(BitcoinPaymentOption option) async {
    if (option.kind == BitcoinAddressKind.lightningAddress &&
        _selectedSats != null &&
        _selectedSats! > 0) {
      final bolt11Uri = await BitcoinService.resolveLightningAddressInvoiceUri(
        lightningAddress: option.value,
        amountSats: _selectedSats!,
        comment: widget.paymentMessage,
      );
      if (bolt11Uri != null) return bolt11Uri;
    }
    return _paymentUri;
  }

  Future<void> _copyActiveUri() async {
    final option = _activeOption;
    if (option == null || _isResolvingInvoice) return;
    setState(() => _isResolvingInvoice = true);
    try {
      final uri = await _resolveEffectivePaymentUri(option);
      if (!mounted) return;
      await _copy(
        uri,
        option.isWebCheckout ? 'BTCPay link' : 'payment URI',
      );
    } finally {
      if (mounted) setState(() => _isResolvingInvoice = false);
    }
  }

  Future<void> _launchActiveOption() async {
    final option = _activeOption;
    if (option == null || _isResolvingInvoice) return;
    setState(() => _isResolvingInvoice = true);
    try {
      final uri = await _resolveEffectivePaymentUri(option);
      final ok = await BitcoinService.launchPaymentUri(uri);
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              option.isWebCheckout
                  ? 'Could not open BTCPay Server URL — copy the link or scan the QR code.'
                  : 'No Bitcoin wallet handler detected on this device — scan the QR or copy the address.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isResolvingInvoice = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const btcOrange = Color(0xFFF7931A);
    final activeTab = _activeTab;
    final activeOption = _activeOption;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          14,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: btcOrange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.favorite_rounded,
                    color: btcOrange,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                      Text(
                        widget.subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context, false),
                ),
              ],
            ),
            const SizedBox(height: 14),

            if (activeOption == null || activeTab == null) ...[
              _buildNotConfiguredCard(context, scheme),
            ] else ...[
              // 1. Amount selection on TOP of payment methods (friendly words + compact inline input)
              if (widget.fixedSats == null &&
                  activeOption.supportsAmountInUri) ...[
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        selected: _selectedSats == null,
                        label: const Text('Any'),
                        onSelected: (_) {
                          setState(() {
                            _selectedSats = null;
                            _customSatsCtrl.clear();
                          });
                        },
                      ),
                      for (final preset in BitcoinService.donationPresets) ...[
                        const SizedBox(width: 6),
                        ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          selected: _selectedSats == preset.sats,
                          label: Text(preset.shortLabel),
                          tooltip: '${preset.label} · ${preset.tagline}',
                          onSelected: (_) {
                            setState(() {
                              _selectedSats = preset.sats;
                              _customSatsCtrl.text = '${preset.sats}';
                            });
                          },
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _customSatsCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: InputDecoration(
                    hintText: 'Custom amount (sats)',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    prefixIcon: const Icon(
                      Icons.currency_bitcoin_rounded,
                      size: 17,
                      color: btcOrange,
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_selectedSats != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Text(
                              '${BitcoinService.formatBtcFromSats(_selectedSats!)} BTC',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        if (_customSatsCtrl.text.isNotEmpty)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 30,
                              minHeight: 30,
                            ),
                            tooltip: 'Clear amount',
                            icon: const Icon(Icons.close_rounded, size: 16),
                            onPressed: () {
                              setState(() {
                                _selectedSats = null;
                                _customSatsCtrl.clear();
                              });
                            },
                          ),
                      ],
                    ),
                  ),
                  onChanged: (raw) {
                    final cleaned = raw.replaceAll(',', '').trim();
                    if (cleaned.isEmpty) {
                      setState(() => _selectedSats = null);
                      return;
                    }
                    final parsed = int.tryParse(cleaned);
                    if (parsed != null && parsed > 0) {
                      setState(() => _selectedSats = parsed);
                    }
                  },
                ),
                const SizedBox(height: 12),
              ] else if (widget.fixedSats != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: btcOrange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: btcOrange.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Amount',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${BitcoinService.formatSats(widget.fixedSats!)} (${BitcoinService.formatBtcFromSats(widget.fixedSats!)} BTC)',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: btcOrange,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // 2. Payment method switcher (Lightning merged, Silent Payment, Onchain, BTCPay)
              if (_tabs.length > 1) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < _tabs.length; i++)
                      ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(
                          _iconForMethod(_tabs[i].method),
                          size: 16,
                          color: _selectedTabIndex == i
                              ? btcOrange
                              : scheme.onSurfaceVariant,
                        ),
                        label: Text(_tabs[i].label),
                        selected: _selectedTabIndex == i,
                        onSelected: (_) =>
                            setState(() => _selectedTabIndex = i),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
              ],

              // 3. Merged Lightning sub-mode selector: Email format vs BOLT 12
              if (activeTab.method == BitcoinPaymentMethod.lightning &&
                  activeTab.hasBothLightningModes) ...[
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: const [
                    ButtonSegment<bool>(
                      value: false,
                      icon: Icon(Icons.alternate_email_rounded, size: 16),
                      label: Text('Email format'),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      icon: Icon(Icons.bolt_rounded, size: 16),
                      label: Text('BOLT 12'),
                    ),
                  ],
                  selected: {_useBolt12ForLightning},
                  onSelectionChanged: (sel) =>
                      setState(() => _useBolt12ForLightning = sel.first),
                ),
                const SizedBox(height: 10),
              ],

              // Live QR Code (larger canvas for dense V10+ BOLT 12 / BIP-321 URIs)
              Builder(
                builder: (context) {
                  final uri = _paymentUri;
                  final qrSize = uri.length > 200 ? 224.0 : 192.0;
                  return Center(
                    child: Column(
                      children: [
                        QrCodeWidget(data: uri, size: qrSize),
                        const SizedBox(height: 6),
                        Text(
                          activeOption.qrCaption,
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),

              // Active method address / abbreviated offer card (no "Payment URI ready" noise)
              Builder(
                builder: (context) {
                  final preview = BitcoinService.abbreviateDestination(
                    activeOption.value,
                    kind: activeOption.kind,
                  );
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _iconForMethod(activeOption.method),
                          size: 16,
                          color: btcOrange,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                activeOption.fieldLabel,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                preview,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (!activeOption.isWebCheckout &&
                            activeOption.method !=
                                BitcoinPaymentMethod.bitcoinUri &&
                            activeOption.kind != BitcoinAddressKind.bolt12Offer)
                          IconButton(
                            tooltip: 'Copy ${activeOption.fieldLabel}',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _copy(
                              activeOption.value,
                              activeOption.fieldLabel,
                            ),
                            icon: const Icon(Icons.copy_rounded, size: 17),
                          ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isResolvingInvoice ? null : _copyActiveUri,
                      icon: const Icon(Icons.copy_rounded, size: 17),
                      label: Text(
                        activeOption.isWebCheckout ? 'Copy Link' : 'Copy URI',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          _isResolvingInvoice ? null : _launchActiveOption,
                      style: FilledButton.styleFrom(
                        backgroundColor: btcOrange,
                        foregroundColor: Colors.white,
                      ),
                      icon: _isResolvingInvoice
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              activeOption.isWebCheckout
                                  ? Icons.open_in_new_rounded
                                  : Icons.account_balance_wallet_rounded,
                              size: 17,
                            ),
                      label: Text(
                        activeOption.isWebCheckout
                            ? 'Open BTCPay'
                            : 'Open Wallet',
                      ),
                    ),
                  ),
                ],
              ),

              if (widget.showMarkAsPaidButton) ...[
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.check_circle_rounded, size: 18),
                  label: const Text('I Sent the Bitcoin — Mark Paid'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNotConfiguredCard(BuildContext context, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 18),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Donation addresses not configured in this build',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Pass a .env file with --dart-define-from-file=.env using any combination of these environment variables:',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            BitcoinService.donationEnvVarNames.join('\n'),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
