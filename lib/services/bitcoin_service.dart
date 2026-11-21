import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'app_env_config.dart';
import 'osm_browser_bridge.dart';

class BitcoinPreset {
  final int sats;
  final String label;
  final String shortLabel;
  final String tagline;

  const BitcoinPreset({
    required this.sats,
    required this.label,
    required this.shortLabel,
    required this.tagline,
  });
}

/// High-level payment rail shown in the donation / payout selector.
enum BitcoinPaymentMethod {
  btcPayServer,
  bitcoinUri,
  silentPayment,
  lightning,
  onChain,
}

extension BitcoinPaymentMethodMeta on BitcoinPaymentMethod {
  String get shortLabel => switch (this) {
        BitcoinPaymentMethod.btcPayServer => 'BTCPay Server',
        BitcoinPaymentMethod.bitcoinUri => 'Bitcoin URI',
        BitcoinPaymentMethod.silentPayment => 'Silent Payment',
        BitcoinPaymentMethod.lightning => 'Lightning',
        BitcoinPaymentMethod.onChain => 'Onchain',
      };
}

/// Specific Bitcoin payment destination format detected from an address or URI.
enum BitcoinAddressKind {
  p2tr,
  segwit,
  legacy,
  silentPayment,
  lightningAddress,
  lnurl,
  bolt12Offer,
  bitcoinUri,
  btcPayServer,
  unknown,
}

extension BitcoinAddressKindMeta on BitcoinAddressKind {
  String get displayLabel => switch (this) {
        BitcoinAddressKind.p2tr => 'Taproot (P2TR)',
        BitcoinAddressKind.segwit => 'SegWit (Bech32)',
        BitcoinAddressKind.legacy => 'Bitcoin (Legacy / P2SH)',
        BitcoinAddressKind.silentPayment => 'Silent Payment (BIP-352)',
        BitcoinAddressKind.lightningAddress => 'Lightning Address',
        BitcoinAddressKind.lnurl => 'LNURL (Lightning)',
        BitcoinAddressKind.bolt12Offer => 'BOLT 12 Offer',
        BitcoinAddressKind.bitcoinUri => 'Bitcoin URI (BIP-321)',
        BitcoinAddressKind.btcPayServer => 'BTCPay Server',
        BitcoinAddressKind.unknown => 'Bitcoin',
      };

  BitcoinPaymentMethod get paymentMethod => switch (this) {
        BitcoinAddressKind.btcPayServer => BitcoinPaymentMethod.btcPayServer,
        BitcoinAddressKind.bitcoinUri => BitcoinPaymentMethod.bitcoinUri,
        BitcoinAddressKind.silentPayment => BitcoinPaymentMethod.silentPayment,
        BitcoinAddressKind.lightningAddress ||
        BitcoinAddressKind.lnurl ||
        BitcoinAddressKind.bolt12Offer =>
          BitcoinPaymentMethod.lightning,
        BitcoinAddressKind.p2tr ||
        BitcoinAddressKind.segwit ||
        BitcoinAddressKind.legacy ||
        BitcoinAddressKind.unknown =>
          BitcoinPaymentMethod.onChain,
      };
}

/// A single configured payment rail selectable in the Bitcoin payment sheet.
class BitcoinPaymentOption {
  final BitcoinPaymentMethod method;
  final BitcoinAddressKind kind;

  /// Raw address, BIP-21/BIP-321 URI, BOLT 12 offer, Lightning address, or BTCPay URL.
  final String value;

  /// Short chip label shown in the payment method switcher.
  final String chipLabel;

  /// Descriptive header shown above the raw address / URI box.
  final String fieldLabel;

  /// Human-friendly hint explaining this payment rail.
  final String helperText;

  /// QR caption shown underneath the QR code.
  final String qrCaption;

  const BitcoinPaymentOption({
    required this.method,
    required this.kind,
    required this.value,
    required this.chipLabel,
    required this.fieldLabel,
    required this.helperText,
    required this.qrCaption,
  });

  /// Whether selecting a satoshi amount applies to this payment rail
  /// (either encoded directly in the BIP-21/BIP-321 URI or resolved via
  /// LNURL-pay LUD-16 for Lightning Addresses).
  bool get supportsAmountInUri =>
      method == BitcoinPaymentMethod.onChain ||
      method == BitcoinPaymentMethod.silentPayment ||
      method == BitcoinPaymentMethod.bitcoinUri ||
      kind == BitcoinAddressKind.bolt12Offer ||
      kind == BitcoinAddressKind.lightningAddress;

  /// Whether launching the primary CTA opens a web checkout rather than a wallet URI.
  bool get isWebCheckout => method == BitcoinPaymentMethod.btcPayServer;

  String buildPaymentUri({
    int? amountSats,
    String? label,
    String? message,
  }) {
    return BitcoinService.buildPaymentUri(
      destination: value,
      amountSats: supportsAmountInUri ? amountSats : null,
      label: label,
      message: message,
    );
  }
}

/// Environment-driven developer Bitcoin donation configuration.
///
/// Populated at build/run time via `--dart-define` or `--dart-define-from-file=.env`
/// so no personal donation addresses are hardcoded in source control:
/// - `BTC_DONATION_URI` (BIP-21 / BIP-321 URI, e.g. `bitcoin:?lno=lno1...`)
/// - `BTC_DONATION_P2TR_ADDRESS` (or fallback `BTC_DONATION_ADDRESS`, e.g. `bc1p...`)
/// - `BTC_DONATION_LIGHTNING_ADDRESS` (e.g. `user@domain.tld`)
/// - `BTC_DONATION_SILENT_PAYMENT_ADDRESS` (BIP-352 `sp1q...`)
/// - `BTC_DONATION_BOLT12_OFFER` (optional standalone `lno1...`)
/// - `BTC_DONATION_BTCPAY_URL` (optional self-hosted BTCPay Server checkout / PoS URL)
class BitcoinDonationConfig {
  static const String envDonationUri = AppEnvConfig.btcDonationUri;
  static const String envP2trAddress = AppEnvConfig.btcDonationP2trAddress;
  static const String envFallbackAddress =
      AppEnvConfig.btcDonationFallbackAddress;
  static const String envLightningAddress =
      AppEnvConfig.btcDonationLightningAddress;
  static const String envSilentPaymentAddress =
      AppEnvConfig.btcDonationSilentPaymentAddress;
  static const String envBolt12Offer = AppEnvConfig.btcDonationBolt12Offer;
  static const String envBtcPayUrl = AppEnvConfig.btcDonationBtcPayUrl;

  final String bitcoinUri;
  final String p2trAddress;
  final String lightningAddress;
  final String silentPaymentAddress;
  final String bolt12Offer;
  final String btcPayUrl;

  const BitcoinDonationConfig({
    this.bitcoinUri = '',
    this.p2trAddress = '',
    this.lightningAddress = '',
    this.silentPaymentAddress = '',
    this.bolt12Offer = '',
    this.btcPayUrl = '',
  });

  /// Loads developer donation configuration purely from compile-time environment variables.
  factory BitcoinDonationConfig.fromEnvironment() {
    final onChain = envP2trAddress.trim().isNotEmpty
        ? envP2trAddress.trim()
        : envFallbackAddress.trim();
    return BitcoinDonationConfig(
      bitcoinUri: envDonationUri.trim(),
      p2trAddress: onChain,
      lightningAddress: envLightningAddress.trim(),
      silentPaymentAddress: envSilentPaymentAddress.trim(),
      bolt12Offer: envBolt12Offer.trim(),
      btcPayUrl: envBtcPayUrl.trim(),
    );
  }

  /// Extracts an on-chain address from [p2trAddress], or from [bitcoinUri]'s path if present.
  String get effectiveOnChainAddress {
    final direct = p2trAddress.trim();
    if (direct.isNotEmpty) return direct;
    final parsed = _parseBitcoinUri(bitcoinUri);
    if (parsed != null && parsed.path.isNotEmpty) {
      final pathKind = BitcoinService.detectAddressKind(parsed.path);
      if (pathKind == BitcoinAddressKind.p2tr ||
          pathKind == BitcoinAddressKind.segwit ||
          pathKind == BitcoinAddressKind.legacy) {
        return parsed.path;
      }
    }
    return '';
  }

  /// Extracts a Silent Payment address from [silentPaymentAddress], or from [bitcoinUri]'s `sp=` param.
  String get effectiveSilentPaymentAddress {
    final direct = silentPaymentAddress.trim();
    if (direct.isNotEmpty) return direct;
    final parsed = _parseBitcoinUri(bitcoinUri);
    final sp = parsed?.queryParameters['sp']?.trim() ?? '';
    if (sp.isNotEmpty &&
        BitcoinService.detectAddressKind(sp) ==
            BitcoinAddressKind.silentPayment) {
      return sp;
    }
    return '';
  }

  /// Effective unified / BOLT 12 Bitcoin URI.
  String get effectiveBitcoinUri {
    final direct = bitcoinUri.trim();
    if (direct.isNotEmpty) return direct;
    final offer = bolt12Offer.trim();
    if (offer.isNotEmpty) return 'bitcoin:?lno=$offer';
    return '';
  }

  /// All valid, configured donation rails ready for the payment sheet.
  List<BitcoinPaymentOption> get availableOptions {
    final options = <BitcoinPaymentOption>[];

    // 1. Self-hosted BTCPay Server (when configured, prioritized first)
    final btcpay = btcPayUrl.trim();
    if (btcpay.isNotEmpty &&
        BitcoinService.detectAddressKind(btcpay) ==
            BitcoinAddressKind.btcPayServer) {
      options.add(
        BitcoinPaymentOption(
          method: BitcoinPaymentMethod.btcPayServer,
          kind: BitcoinAddressKind.btcPayServer,
          value: btcpay,
          chipLabel: 'BTCPay Server',
          fieldLabel: 'BTCPay Server Checkout URL',
          helperText:
              'Self-hosted BTCPay Server checkout supporting fresh on-chain P2TR & Lightning invoices.',
          qrCaption: 'Scan or open BTCPay Server checkout',
        ),
      );
    }

    // 2. Unified Bitcoin URI / BOLT 12 Offer (BIP-321)
    final uri = effectiveBitcoinUri;
    if (uri.isNotEmpty && BitcoinService.isValidBitcoinDestination(uri)) {
      final parsed = _parseBitcoinUri(uri);
      final hasLno = (parsed?.queryParameters['lno'] ?? '').isNotEmpty;
      final hasSp = (parsed?.queryParameters['sp'] ?? '').isNotEmpty;
      final hasPath = (parsed?.path ?? '').isNotEmpty;
      final chip = hasLno && !hasPath && !hasSp
          ? 'BOLT 12 URI'
          : (hasLno || hasSp ? 'Unified URI' : 'Bitcoin URI');
      final field = hasLno && !hasPath && !hasSp
          ? 'Bitcoin URI (BOLT 12 Offer · BIP-321)'
          : 'Unified Bitcoin URI (BIP-321)';
      final helper = hasLno
          ? 'Reusable BOLT 12 Lightning offer inside a BIP-321 Bitcoin URI — no invoice expiry.'
          : 'Standard BIP-21 / BIP-321 payment URI compatible with modern Bitcoin wallets.';
      final qrCaption = hasLno
          ? 'Scan with a BOLT 12 / BIP-321 wallet (Cake, Phoenix, Zeus)'
          : 'Scan with any Bitcoin wallet (BIP-321)';
      options.add(
        BitcoinPaymentOption(
          method: BitcoinPaymentMethod.bitcoinUri,
          kind: BitcoinAddressKind.bitcoinUri,
          value: uri,
          chipLabel: chip,
          fieldLabel: field,
          helperText: helper,
          qrCaption: qrCaption,
        ),
      );
    }

    // 3. Silent Payments (BIP-352)
    final sp = effectiveSilentPaymentAddress;
    if (sp.isNotEmpty &&
        BitcoinService.detectAddressKind(sp) ==
            BitcoinAddressKind.silentPayment) {
      options.add(
        BitcoinPaymentOption(
          method: BitcoinPaymentMethod.silentPayment,
          kind: BitcoinAddressKind.silentPayment,
          value: sp,
          chipLabel: 'Silent Payment',
          fieldLabel: 'Silent Payment Address (BIP-352)',
          helperText:
              'Static, reusable on-chain address that derives a unique private Taproot output per donation.',
          qrCaption: 'Scan with a Silent Payment wallet (BIP-321 ?sp=)',
        ),
      );
    }

    // 4. Lightning Address / LNURL
    final ln = lightningAddress.trim();
    if (ln.isNotEmpty) {
      final lnKind = BitcoinService.detectAddressKind(ln);
      if (lnKind == BitcoinAddressKind.lightningAddress ||
          lnKind == BitcoinAddressKind.lnurl) {
        options.add(
          BitcoinPaymentOption(
            method: BitcoinPaymentMethod.lightning,
            kind: lnKind,
            value: ln,
            chipLabel: 'Lightning',
            fieldLabel: lnKind.displayLabel,
            helperText:
                'Instant, low-fee satoshi tips via Lightning Address (enter amount in your wallet).',
            qrCaption: 'Scan with any Lightning wallet',
          ),
        );
      }
    }

    // 5. Standard Onchain (Taproot / SegWit / Legacy)
    final onChain = effectiveOnChainAddress;
    if (onChain.isNotEmpty) {
      final chainKind = BitcoinService.detectAddressKind(onChain);
      if (chainKind == BitcoinAddressKind.p2tr ||
          chainKind == BitcoinAddressKind.segwit ||
          chainKind == BitcoinAddressKind.legacy) {
        options.add(
          BitcoinPaymentOption(
            method: BitcoinPaymentMethod.onChain,
            kind: chainKind,
            value: onChain,
            chipLabel: 'Onchain',
            fieldLabel: 'Bitcoin Onchain Address',
            helperText: 'Standard on-chain Bitcoin payment using BIP-21.',
            qrCaption: 'Scan with any Bitcoin wallet (BIP-21)',
          ),
        );
      }
    }

    return List.unmodifiable(options);
  }

  bool get isConfigured => availableOptions.isNotEmpty;

  static Uri? _parseBitcoinUri(String raw) {
    final s = raw.trim();
    if (!s.toLowerCase().startsWith('bitcoin:')) return null;
    return Uri.tryParse(s);
  }
}

/// Bitcoin (P2TR / SegWit on-chain BIP-21, BIP-321 unified & BOLT 12 URIs,
/// BIP-352 Silent Payments, Lightning Address, and BTCPay Server) helper powering:
/// - Developer donations configured via environment variables
/// - Peer-to-peer Bitcoin payouts for completed mapping bounties
class BitcoinService {
  /// Compile-time environment variable names used to configure developer donations.
  static const List<String> donationEnvVarNames = [
    'BTC_DONATION_URI',
    'BTC_DONATION_P2TR_ADDRESS',
    'BTC_DONATION_LIGHTNING_ADDRESS',
    'BTC_DONATION_SILENT_PAYMENT_ADDRESS',
    'BTC_DONATION_BTCPAY_URL',
  ];

  /// Developer donation config loaded strictly from environment variables.
  static BitcoinDonationConfig get developerDonationConfig =>
      BitcoinDonationConfig.fromEnvironment();

  static const int satsPerBtc = 100000000;

  static const List<BitcoinPreset> donationPresets = [
    BitcoinPreset(
      sats: 2100,
      label: '2,100 sats',
      shortLabel: 'Coffee',
      tagline: 'Buy a coffee',
    ),
    BitcoinPreset(
      sats: 10000,
      label: '10,000 sats',
      shortLabel: 'Lunch',
      tagline: 'Buy lunch',
    ),
    BitcoinPreset(
      sats: 50000,
      label: '50,000 sats',
      shortLabel: 'Dinner',
      tagline: 'Sponsor a dinner',
    ),
    BitcoinPreset(
      sats: 100000,
      label: '100,000 sats',
      shortLabel: 'Patron',
      tagline: 'Project patron',
    ),
  ];

  /// Returns a compact, human-readable display preview for a Bitcoin address or
  /// BOLT 12 offer/URI:
  /// - Lightning Addresses (`user@domain`) stay intact when reasonably short.
  /// - BOLT 12 URIs (`bitcoin:?lno=lno1...`) and long cryptographic strings
  ///   (`lno1...`, `sp1q...`, `bc1p...`) show only the starting characters
  ///   followed by an ellipsis (and short tail for addresses).
  static String abbreviateDestination(String raw, {BitcoinAddressKind? kind}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final effectiveKind = kind ?? detectAddressKind(trimmed);

    // Email-style Lightning Address stays human-readable in full
    if (effectiveKind == BitcoinAddressKind.lightningAddress &&
        trimmed.length <= 48) {
      return trimmed;
    }

    // Extract inner lno1... prefix when wrapped in `bitcoin:?lno=...`
    if (effectiveKind == BitcoinAddressKind.bitcoinUri) {
      final parsed = Uri.tryParse(trimmed);
      final lno = parsed?.queryParameters['lno']?.trim() ?? '';
      if (lno.isNotEmpty) {
        final head = lno.length > 18 ? lno.substring(0, 18) : lno;
        return '$head…';
      }
    }

    if (effectiveKind == BitcoinAddressKind.bolt12Offer) {
      final head = trimmed.length > 18 ? trimmed.substring(0, 18) : trimmed;
      return '$head…';
    }

    if (trimmed.length <= 26) return trimmed;
    return '${trimmed.substring(0, 14)}…${trimmed.substring(trimmed.length - 6)}';
  }

  static double satsToBtc(int sats) => sats / satsPerBtc;

  static String formatBtcFromSats(int sats) {
    final btc = satsToBtc(sats);
    // Trim trailing zeros while preserving clean precision up to 8 decimals
    var formatted = btc.toStringAsFixed(8);
    formatted = formatted.replaceFirst(RegExp(r'0+$'), '');
    if (formatted.endsWith('.')) formatted = '${formatted}0';
    return formatted;
  }

  static String formatSats(int sats) {
    final str = sats.toString();
    final buf = StringBuffer();
    for (var i = 0; i < str.length; i++) {
      final posFromRight = str.length - i;
      if (i > 0 && posFromRight % 3 == 0) buf.write(',');
      buf.write(str[i]);
    }
    return '$buf sats';
  }

  static const String _bech32Charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  static const String _base58Alphabet =
      '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  static const int _bech32Const = 1;
  static const int _bech32mConst = 0x2bc830a3;

  static int _bech32Polymod(List<int> values) {
    const gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
    var chk = 1;
    for (final v in values) {
      final top = chk >> 25;
      chk = ((chk & 0x1ffffff) << 5) ^ v;
      for (var i = 0; i < 5; i++) {
        if (((top >> i) & 1) != 0) chk ^= gen[i];
      }
    }
    return chk;
  }

  static List<int> _bech32HrpExpand(String hrp) {
    final out = <int>[];
    for (var i = 0; i < hrp.length; i++) {
      out.add(hrp.codeUnitAt(i) >> 5);
    }
    out.add(0);
    for (var i = 0; i < hrp.length; i++) {
      out.add(hrp.codeUnitAt(i) & 31);
    }
    return out;
  }

  static bool _hasMixedCase(String s) {
    final hasLower = s != s.toUpperCase();
    final hasUpper = s != s.toLowerCase();
    return hasLower && hasUpper;
  }

  /// Verifies Bech32 (BIP-173, [expectedConst] == 1) or Bech32m (BIP-350,
  /// [expectedConst] == 0x2bc830a3) encoding and checksum.
  static bool _verifyBech32Checksum(String raw, {required int expectedConst}) {
    if (raw.length < 8 || _hasMixedCase(raw)) return false;
    final lower = raw.toLowerCase();
    final sep = lower.lastIndexOf('1');
    if (sep < 1 || sep + 7 > lower.length) return false;
    final hrp = lower.substring(0, sep);
    final dataPart = lower.substring(sep + 1);
    for (var i = 0; i < hrp.length; i++) {
      final c = hrp.codeUnitAt(i);
      if (c < 33 || c > 126) return false;
    }
    final data = <int>[];
    for (var i = 0; i < dataPart.length; i++) {
      final idx = _bech32Charset.indexOf(dataPart[i]);
      if (idx < 0) return false;
      data.add(idx);
    }
    return _bech32Polymod([..._bech32HrpExpand(hrp), ...data]) == expectedConst;
  }

  /// Verifies Base58Check (double SHA-256 4-byte checksum) for legacy P2PKH/P2SH.
  static bool _verifyBase58Check(String raw) {
    if (raw.length < 26 || raw.length > 35) return false;
    var numVal = BigInt.zero;
    final base = BigInt.from(58);
    for (var i = 0; i < raw.length; i++) {
      final idx = _base58Alphabet.indexOf(raw[i]);
      if (idx < 0) return false;
      numVal = numVal * base + BigInt.from(idx);
    }
    final bytes = <int>[];
    while (numVal > BigInt.zero) {
      bytes.add((numVal & BigInt.from(0xff)).toInt());
      numVal = numVal >> 8;
    }
    final decoded = bytes.reversed.toList();
    var leadingZeros = 0;
    for (var i = 0; i < raw.length && raw[i] == '1'; i++) {
      leadingZeros++;
    }
    final full = Uint8List.fromList([
      ...List<int>.filled(leadingZeros, 0),
      ...decoded,
    ]);
    if (full.length != 25) return false;
    final payload = full.sublist(0, 21);
    final checksum = full.sublist(21, 25);
    final version = payload[0];
    // Mainnet P2PKH (0x00) or P2SH (0x05)
    if (version != 0x00 && version != 0x05) return false;
    final first = sha256.convert(payload).bytes;
    final second = sha256.convert(first).bytes;
    for (var i = 0; i < 4; i++) {
      if (checksum[i] != second[i]) return false;
    }
    return true;
  }

  /// Parses the BOLT 11 invoice HRP amount in millisatoshis and validates
  /// Bech32 checksum + mainnet `lnbc` prefix. Returns `null` if invalid or
  /// amountless.
  static int? _parseAndVerifyBolt11MainnetAmountMsats(String pr) {
    if (pr.isEmpty || _hasMixedCase(pr)) return null;
    final lower = pr.toLowerCase();
    if (!lower.startsWith('lnbc')) return null;
    if (lower.startsWith('lnbcrt')) return null;
    if (!_verifyBech32Checksum(lower, expectedConst: _bech32Const)) return null;
    final sep = lower.lastIndexOf('1');
    if (sep <= 4) return null;
    final amountPart = lower.substring(4, sep);
    if (amountPart.isEmpty) return null;
    final match = RegExp(r'^([1-9][0-9]*)([munp])?$').firstMatch(amountPart);
    if (match == null) return null;
    final numBig = BigInt.tryParse(match.group(1)!);
    if (numBig == null || numBig <= BigInt.zero) return null;
    final mult = match.group(2);
    // 1 BTC = 100_000_000_000 msats (1e11)
    BigInt msats;
    switch (mult) {
      case null:
        msats = numBig * BigInt.from(100000000000);
      case 'm':
        msats = numBig * BigInt.from(100000000);
      case 'u':
        msats = numBig * BigInt.from(100000);
      case 'n':
        msats = numBig * BigInt.from(100);
      case 'p':
        if (numBig % BigInt.from(10) != BigInt.zero) return null;
        msats = numBig ~/ BigInt.from(10);
      default:
        return null;
    }
    if (!msats.isValidInt) return null;
    return msats.toInt();
  }

  /// Rejects loopback, private RFC1918, link-local / cloud metadata, and
  /// non-public hosts to prevent SSRF in LNURL-pay resolution.
  static bool _isSafePublicHost(String host) {
    final h = host.trim().toLowerCase();
    if (h.isEmpty || h == 'localhost' || h.endsWith('.localhost')) return false;
    if (h.endsWith('.local') || h.endsWith('.internal')) return false;
    // Reject IPv6 literals (loopback ::1, ULA fc00::/7, link-local fe80::/10)
    if (h.contains(':') || h.startsWith('[')) return false;
    // Reject IPv4 literals in private/loopback/link-local/reserved ranges
    final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
        .firstMatch(h);
    if (ipv4 != null) {
      final a = int.tryParse(ipv4.group(1)!) ?? 256;
      final b = int.tryParse(ipv4.group(2)!) ?? 256;
      final c = int.tryParse(ipv4.group(3)!) ?? 256;
      final d = int.tryParse(ipv4.group(4)!) ?? 256;
      if (a > 255 || b > 255 || c > 255 || d > 255) return false;
      if (a == 0 || a == 10 || a == 127) return false;
      if (a == 169 && b == 254) return false; // Link-local & cloud metadata
      if (a == 172 && b >= 16 && b <= 31) return false;
      if (a == 192 && b == 168) return false;
      if (a == 100 && b >= 64 && b <= 127) return false; // CGNAT
      if (a >= 224) return false; // Multicast / reserved
      return false; // Require public DNS domain for LNURL-pay
    }
    if (!h.contains('.')) return false;
    return RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$')
        .hasMatch(h);
  }

  static bool _isValidBolt11OrLightningParam(String ln) {
    final s = ln.trim();
    if (s.isEmpty || _hasMixedCase(s)) return false;
    final lower = s.toLowerCase();
    if (lower.startsWith('lnbc') && !lower.startsWith('lnbcrt')) {
      return _verifyBech32Checksum(lower, expectedConst: _bech32Const);
    }
    if (lower.startsWith('lno1')) {
      return RegExp(r'^lno1[ac-hj-np-z02-9]{30,}$').hasMatch(lower);
    }
    if (lower.startsWith('lnurl1')) {
      return _verifyBech32Checksum(lower, expectedConst: _bech32Const);
    }
    return false;
  }

  /// Detects the specific Bitcoin payment destination type for [raw].
  ///
  /// Set [allowBtcPayUrl] to `false` when validating untrusted peer-to-peer
  /// payout addresses (such as community bounties) so arbitrary `https://`
  /// phishing links are rejected.
  static BitcoinAddressKind detectAddressKind(
    String raw, {
    bool allowBtcPayUrl = true,
    bool allowTestnet = false,
  }) {
    final s = raw.trim();
    if (s.isEmpty) return BitcoinAddressKind.unknown;
    final lower = s.toLowerCase();

    // BTCPay Server / HTTPS checkout URL (developer donation rail only unless opted in)
    if (lower.startsWith('https://') || lower.startsWith('http://')) {
      if (!allowBtcPayUrl) return BitcoinAddressKind.unknown;
      final uri = Uri.tryParse(s);
      if (uri != null && uri.host.isNotEmpty) {
        final isHttps = uri.scheme == 'https';
        final isLocalOrOnion = uri.host == 'localhost' ||
            uri.host == '127.0.0.1' ||
            uri.host.endsWith('.onion');
        if (isHttps || isLocalOrOnion) {
          return BitcoinAddressKind.btcPayServer;
        }
      }
      return BitcoinAddressKind.unknown;
    }

    // BIP-21 / BIP-321 URI (`bitcoin:<addr>?...` or `bitcoin:?lno=...` / `bitcoin:?sp=...`)
    if (lower.startsWith('bitcoin:')) {
      final uri = Uri.tryParse(s);
      if (uri == null) return BitcoinAddressKind.unknown;
      final path = uri.path.trim();
      if (path.isNotEmpty) {
        final pathKind = detectAddressKind(
          path,
          allowBtcPayUrl: false,
          allowTestnet: allowTestnet,
        );
        if (pathKind == BitcoinAddressKind.p2tr ||
            pathKind == BitcoinAddressKind.segwit ||
            pathKind == BitcoinAddressKind.legacy) {
          return BitcoinAddressKind.bitcoinUri;
        }
        return BitcoinAddressKind.unknown;
      }
      // BIP-321 allows empty address path when query params carry payment instructions
      final lno = uri.queryParameters['lno']?.trim() ?? '';
      final sp = uri.queryParameters['sp']?.trim() ?? '';
      final ln = uri.queryParameters['lightning']?.trim() ?? '';
      final bc = uri.queryParameters['bc']?.trim() ?? '';
      if ((lno.isNotEmpty &&
              detectAddressKind(lno,
                      allowBtcPayUrl: false, allowTestnet: allowTestnet) ==
                  BitcoinAddressKind.bolt12Offer) ||
          (sp.isNotEmpty &&
              detectAddressKind(sp,
                      allowBtcPayUrl: false, allowTestnet: allowTestnet) ==
                  BitcoinAddressKind.silentPayment) ||
          (ln.isNotEmpty && _isValidBolt11OrLightningParam(ln)) ||
          (bc.isNotEmpty &&
              (detectAddressKind(bc,
                          allowBtcPayUrl: false, allowTestnet: allowTestnet) ==
                      BitcoinAddressKind.p2tr ||
                  detectAddressKind(bc,
                          allowBtcPayUrl: false, allowTestnet: allowTestnet) ==
                      BitcoinAddressKind.segwit ||
                  detectAddressKind(bc,
                          allowBtcPayUrl: false, allowTestnet: allowTestnet) ==
                      BitcoinAddressKind.legacy))) {
        return BitcoinAddressKind.bitcoinUri;
      }
      return BitcoinAddressKind.unknown;
    }

    // BIP-352 Silent Payment static address (Bech32m, single-case)
    final spPrefix = allowTestnet ? r'^(sp1|tsp1)' : r'^sp1';
    if (!_hasMixedCase(s) &&
        RegExp('$spPrefix[ac-hj-np-z02-9]{100,140}\$').hasMatch(lower) &&
        _verifyBech32Checksum(s, expectedConst: _bech32mConst)) {
      return BitcoinAddressKind.silentPayment;
    }

    // Taproot (P2TR, Bech32m witness v1, single-case)
    final p2trPrefix = allowTestnet ? r'^(bc1p|tb1p|bcrt1p)' : r'^bc1p';
    if (!_hasMixedCase(s) &&
        RegExp('$p2trPrefix[ac-hj-np-z02-9]{58}\$').hasMatch(lower) &&
        _verifyBech32Checksum(s, expectedConst: _bech32mConst)) {
      return BitcoinAddressKind.p2tr;
    }

    // Native SegWit (P2WPKH / P2WSH, Bech32 witness v0, single-case)
    final segwitPrefix = allowTestnet ? r'^(bc1q|tb1q|bcrt1q)' : r'^bc1q';
    if (!_hasMixedCase(s) &&
        RegExp('$segwitPrefix[ac-hj-np-z02-9]{38,59}\$').hasMatch(lower) &&
        _verifyBech32Checksum(s, expectedConst: _bech32Const)) {
      return BitcoinAddressKind.segwit;
    }

    // Legacy Base58Check P2PKH (`1...`) / P2SH (`3...`)
    if (RegExp(r'^[13][a-km-zA-HJ-NP-Z1-9]{25,34}$').hasMatch(s) &&
        _verifyBase58Check(s)) {
      return BitcoinAddressKind.legacy;
    }

    // BOLT 12 Offer (`lno1...`, single-case; BOLT 12 omits Bech32 checksum by spec)
    if (!_hasMixedCase(s) &&
        RegExp(r'^lno1[ac-hj-np-z02-9]{30,}$').hasMatch(lower)) {
      return BitcoinAddressKind.bolt12Offer;
    }

    // LNURL (`lnurl1...`, Bech32 checksummed, single-case)
    if (!_hasMixedCase(s) &&
        RegExp(r'^lnurl1[ac-hj-np-z02-9]{14,}$').hasMatch(lower) &&
        _verifyBech32Checksum(s, expectedConst: _bech32Const)) {
      return BitcoinAddressKind.lnurl;
    }

    // Lightning Address (`user@domain.tld`) — forbid `..` path traversal & private hosts
    if (RegExp(r'^[a-zA-Z0-9._+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$')
        .hasMatch(s)) {
      final atIdx = s.indexOf('@');
      final user = s.substring(0, atIdx);
      final domain = s.substring(atIdx + 1);
      if (!user.contains('..') &&
          !user.startsWith('.') &&
          !user.endsWith('.') &&
          _isSafePublicHost(domain)) {
        return BitcoinAddressKind.lightningAddress;
      }
    }

    return BitcoinAddressKind.unknown;
  }

  /// Validates any supported Bitcoin destination.
  static bool isValidBitcoinDestination(
    String raw, {
    bool allowBtcPayUrl = true,
    bool allowTestnet = false,
  }) =>
      detectAddressKind(
        raw,
        allowBtcPayUrl: allowBtcPayUrl,
        allowTestnet: allowTestnet,
      ) !=
      BitcoinAddressKind.unknown;

  /// Backwards-compatible alias for validating Bitcoin / Silent Payment / Lightning
  /// / BOLT 12 / BIP-321 / BTCPay destinations.
  static bool isValidBitcoinOrLightningAddress(
    String raw, {
    bool allowBtcPayUrl = true,
    bool allowTestnet = false,
  }) =>
      isValidBitcoinDestination(
        raw,
        allowBtcPayUrl: allowBtcPayUrl,
        allowTestnet: allowTestnet,
      );

  /// Wraps a single destination (e.g., bounty recipient address) into a
  /// [BitcoinPaymentOption] with accurate labels and URI formatting.
  static BitcoinPaymentOption optionFromDestination(String raw) {
    final clean = raw.trim();
    final kind = detectAddressKind(clean);
    return switch (kind) {
      BitcoinAddressKind.btcPayServer => BitcoinPaymentOption(
          method: BitcoinPaymentMethod.btcPayServer,
          kind: kind,
          value: clean,
          chipLabel: 'BTCPay Server',
          fieldLabel: 'BTCPay Server Checkout URL',
          helperText: 'Pay via BTCPay Server checkout.',
          qrCaption: 'Scan or open BTCPay Server checkout',
        ),
      BitcoinAddressKind.bitcoinUri => BitcoinPaymentOption(
          method: BitcoinPaymentMethod.bitcoinUri,
          kind: kind,
          value: clean,
          chipLabel: clean.toLowerCase().contains('lno=')
              ? 'BOLT 12 URI'
              : 'Bitcoin URI',
          fieldLabel: 'Bitcoin URI (BIP-321)',
          helperText: 'Unified BIP-21 / BIP-321 Bitcoin payment URI.',
          qrCaption: 'Scan with a BIP-321 / BOLT 12 compatible wallet',
        ),
      BitcoinAddressKind.silentPayment => BitcoinPaymentOption(
          method: BitcoinPaymentMethod.silentPayment,
          kind: kind,
          value: clean,
          chipLabel: 'Silent Payment',
          fieldLabel: 'Silent Payment Address (BIP-352)',
          helperText:
              'Private reusable on-chain address encoded via BIP-321 (?sp=).',
          qrCaption: 'Scan with a Silent Payment wallet (BIP-321 ?sp=)',
        ),
      BitcoinAddressKind.bolt12Offer => BitcoinPaymentOption(
          method: BitcoinPaymentMethod.lightning,
          kind: kind,
          value: clean,
          chipLabel: 'BOLT 12',
          fieldLabel: 'BOLT 12 Offer',
          helperText: 'Reusable Lightning BOLT 12 offer encoded via BIP-321 (?lno=).',
          qrCaption: 'Scan with a BOLT 12 wallet (Cake, Phoenix, Zeus)',
        ),
      BitcoinAddressKind.lightningAddress ||
      BitcoinAddressKind.lnurl =>
        BitcoinPaymentOption(
          method: BitcoinPaymentMethod.lightning,
          kind: kind,
          value: clean,
          chipLabel: 'Lightning',
          fieldLabel: kind.displayLabel,
          helperText: 'Instant satoshi payment over Lightning.',
          qrCaption: 'Scan with any Lightning wallet',
        ),
      BitcoinAddressKind.p2tr => BitcoinPaymentOption(
          method: BitcoinPaymentMethod.onChain,
          kind: kind,
          value: clean,
          chipLabel: 'Onchain',
          fieldLabel: 'Bitcoin Onchain Address',
          helperText: 'Standard on-chain Bitcoin payment (BIP-21).',
          qrCaption: 'Scan with any Bitcoin wallet (BIP-21)',
        ),
      _ => BitcoinPaymentOption(
          method: BitcoinPaymentMethod.onChain,
          kind: kind,
          value: clean,
          chipLabel: 'Onchain',
          fieldLabel: 'Bitcoin Onchain Address',
          helperText: 'Standard on-chain Bitcoin payment (BIP-21).',
          qrCaption: 'Scan with any Bitcoin wallet (BIP-21)',
        ),
    };
  }

  /// Builds a standards-compliant payment URI for any supported destination:
  /// - On-chain P2TR / SegWit / Legacy: `bitcoin:<addr>?amount=<btc>&label=...&message=...`
  /// - Silent Payment (`sp1...`): BIP-321 `bitcoin:?sp=<sp>&amount=<btc>&label=...&message=...`
  /// - BOLT 12 Offer (`lno1...`): BIP-321 `bitcoin:?lno=<offer>&amount=<btc>`
  /// - Existing `bitcoin:` URI: preserves existing query params (`lno`, `sp`, etc.) & merges `amount`
  /// - Lightning Address / LNURL: `lightning:<address>`
  /// - BTCPay Server URL (`https://...`): returned directly
  static String buildPaymentUri({
    required String destination,
    int? amountSats,
    String? label,
    String? message,
    String? silentPaymentAddress,
    String? bolt12Offer,
  }) {
    final clean = destination.trim();
    final kind = detectAddressKind(clean);

    switch (kind) {
      case BitcoinAddressKind.btcPayServer:
        return clean;

      case BitcoinAddressKind.lightningAddress:
      case BitcoinAddressKind.lnurl:
        return 'lightning:$clean';

      case BitcoinAddressKind.silentPayment:
        final pairs = <String>['sp=$clean'];
        if (amountSats != null && amountSats > 0) {
          pairs.add('amount=${formatBtcFromSats(amountSats)}');
        }
        if (label != null && label.trim().isNotEmpty) {
          pairs.add('label=${Uri.encodeQueryComponent(label.trim())}');
        }
        if (message != null && message.trim().isNotEmpty) {
          pairs.add('message=${Uri.encodeQueryComponent(message.trim())}');
        }
        return 'bitcoin:?${pairs.join('&')}';

      case BitcoinAddressKind.bolt12Offer:
        final pairs = <String>['lno=$clean'];
        if (amountSats != null && amountSats > 0) {
          pairs.add('amount=${formatBtcFromSats(amountSats)}');
        }
        return 'bitcoin:?${pairs.join('&')}';

      case BitcoinAddressKind.bitcoinUri:
        return _mergeIntoBitcoinUri(
          baseUri: clean,
          amountSats: amountSats,
          label: label,
          message: message,
        );

      case BitcoinAddressKind.p2tr:
      case BitcoinAddressKind.segwit:
      case BitcoinAddressKind.legacy:
        final pairs = <String>[];
        if (amountSats != null && amountSats > 0) {
          pairs.add('amount=${formatBtcFromSats(amountSats)}');
        }
        if (label != null && label.trim().isNotEmpty) {
          pairs.add('label=${Uri.encodeQueryComponent(label.trim())}');
        }
        if (message != null && message.trim().isNotEmpty) {
          pairs.add('message=${Uri.encodeQueryComponent(message.trim())}');
        }
        if (silentPaymentAddress != null &&
            silentPaymentAddress.trim().isNotEmpty) {
          pairs.add('sp=${silentPaymentAddress.trim()}');
        }
        if (bolt12Offer != null && bolt12Offer.trim().isNotEmpty) {
          pairs.add('lno=${bolt12Offer.trim()}');
        }
        if (pairs.isEmpty) return 'bitcoin:$clean';
        return 'bitcoin:$clean?${pairs.join('&')}';

      case BitcoinAddressKind.unknown:
        throw ArgumentError.value(
          destination,
          'destination',
          'Unsupported or invalid Bitcoin payment destination.',
        );
    }
  }

  /// Builds a BIP-21 / BIP-321 payment URI (supports P2TR, SegWit, Legacy,
  /// Silent Payments `?sp=`, BOLT 12 `?lno=`, and existing `bitcoin:` URIs).
  static String buildBip21Uri({
    required String address,
    int? amountSats,
    String? label,
    String? message,
    String? silentPaymentAddress,
    String? bolt12Offer,
  }) {
    return buildPaymentUri(
      destination: address,
      amountSats: amountSats,
      label: label,
      message: message,
      silentPaymentAddress: silentPaymentAddress,
      bolt12Offer: bolt12Offer,
    );
  }

  static String _mergeIntoBitcoinUri({
    required String baseUri,
    int? amountSats,
    String? label,
    String? message,
  }) {
    final parsed = Uri.tryParse(baseUri);
    if (parsed == null) return baseUri;

    final path = parsed.path;
    final existingKeys = <String>{};
    final pairs = <String>[];

    // Preserve original query parameters verbatim (avoids double-encoding Bech32 params)
    if (parsed.query.isNotEmpty) {
      for (final rawPair in parsed.query.split('&')) {
        if (rawPair.isEmpty) continue;
        final eq = rawPair.indexOf('=');
        final key = (eq >= 0 ? rawPair.substring(0, eq) : rawPair).toLowerCase();
        existingKeys.add(key);
        pairs.add(rawPair);
      }
    }

    final hasLongBolt12 = existingKeys.contains('lno');

    if (amountSats != null &&
        amountSats > 0 &&
        !existingKeys.contains('amount')) {
      pairs.add('amount=${formatBtcFromSats(amountSats)}');
    }
    // Keep BOLT 12 QR codes compact (the offer already carries its own description)
    if (!hasLongBolt12) {
      if (label != null &&
          label.trim().isNotEmpty &&
          !existingKeys.contains('label')) {
        pairs.add('label=${Uri.encodeQueryComponent(label.trim())}');
      }
      if (message != null &&
          message.trim().isNotEmpty &&
          !existingKeys.contains('message')) {
        pairs.add('message=${Uri.encodeQueryComponent(message.trim())}');
      }
    }

    if (pairs.isEmpty) return 'bitcoin:$path';
    return 'bitcoin:$path?${pairs.join('&')}';
  }

  /// Resolves an exact-amount BOLT 11 Lightning invoice URI (`lightning:lnbc...`)
  /// for a Lightning Address (`user@domain.tld`) via LNURL-pay (LUD-16) so
  /// wallets open with the chosen amount pre-filled.
  ///
  /// Returns `null` if offline, invalid, out of server min/max bounds, or if
  /// the recipient's LNURL-pay server is unreachable (caller falls back to
  /// `lightning:user@domain.tld`).
  static Future<String?> resolveLightningAddressInvoiceUri({
    required String lightningAddress,
    required int amountSats,
    String? comment,
    http.Client? client,
  }) async {
    final clean = lightningAddress.trim();
    if (amountSats <= 0 ||
        detectAddressKind(clean) != BitcoinAddressKind.lightningAddress) {
      return null;
    }
    final atIdx = clean.indexOf('@');
    if (atIdx <= 0 || atIdx >= clean.length - 1) return null;
    final user = clean.substring(0, atIdx);
    final domain = clean.substring(atIdx + 1);
    if (user.contains('..') || !_isSafePublicHost(domain)) return null;
    final ownClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      final metaUri = Uri.https(domain, '/.well-known/lnurlp/$user');
      final metaReq = http.Request('GET', metaUri)
        ..followRedirects = false
        ..headers['Accept'] = 'application/json';
      final metaStreamed =
          await httpClient.send(metaReq).timeout(const Duration(seconds: 5));
      final metaResp = await http.Response.fromStream(metaStreamed);
      if (metaResp.statusCode < 200 || metaResp.statusCode >= 300) return null;
      final metaJson = jsonDecode(metaResp.body);
      if (metaJson is! Map<String, dynamic>) return null;
      final callbackRaw = metaJson['callback']?.toString().trim() ?? '';
      final callbackUri = Uri.tryParse(callbackRaw);
      if (callbackUri == null ||
          callbackUri.scheme != 'https' ||
          !_isSafePublicHost(callbackUri.host)) {
        return null;
      }

      final amountMsats = amountSats * 1000;
      final minSendable = (metaJson['minSendable'] as num?)?.toInt();
      final maxSendable = (metaJson['maxSendable'] as num?)?.toInt();
      if (minSendable != null && amountMsats < minSendable) return null;
      if (maxSendable != null && amountMsats > maxSendable) return null;

      final commentAllowed = (metaJson['commentAllowed'] as num?)?.toInt() ?? 0;
      final params = Map<String, String>.from(callbackUri.queryParameters);
      params['amount'] = '$amountMsats';
      final trimmedComment = comment?.trim() ?? '';
      if (commentAllowed > 0 && trimmedComment.isNotEmpty) {
        params['comment'] = trimmedComment.length > commentAllowed
            ? trimmedComment.substring(0, commentAllowed)
            : trimmedComment;
      }

      final invUri = callbackUri.replace(queryParameters: params);
      final invReq = http.Request('GET', invUri)
        ..followRedirects = false
        ..headers['Accept'] = 'application/json';
      final invStreamed =
          await httpClient.send(invReq).timeout(const Duration(seconds: 5));
      final invResp = await http.Response.fromStream(invStreamed);
      if (invResp.statusCode < 200 || invResp.statusCode >= 300) return null;
      final invJson = jsonDecode(invResp.body);
      if (invJson is! Map<String, dynamic>) return null;
      final pr = invJson['pr']?.toString().trim() ?? '';
      // LUD-06 security check: verify BOLT 11 Bech32 checksum, mainnet prefix,
      // and exact amount match against requested amountMsats.
      final decodedMsats = _parseAndVerifyBolt11MainnetAmountMsats(pr);
      if (decodedMsats == null || decodedMsats != amountMsats) {
        return null;
      }
      return 'lightning:$pr';
    } catch (_) {
      return null;
    } finally {
      if (ownClient) httpClient.close();
    }
  }

  /// Launches a pre-built payment URI (`bitcoin:...`, `lightning:...`, or BTCPay `https://...`).
  static Future<bool> launchPaymentUri(String uri) => openExternalUrl(uri);

  /// Launches the user's installed Bitcoin wallet (or BTCPay Server checkout) for [address].
  static Future<bool> launchWalletPayment({
    required String address,
    int? amountSats,
    String? label,
    String? message,
  }) {
    final uri = buildPaymentUri(
      destination: address,
      amountSats: amountSats,
      label: label,
      message: message,
    );
    return openExternalUrl(uri);
  }
}
