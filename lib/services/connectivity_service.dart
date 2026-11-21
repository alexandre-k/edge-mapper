import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Tracks real device network state plus an optional manual "Force Offline" override
/// so field mappers can force on-device AI even when signal is weak or while testing.
class ConnectivityService extends ChangeNotifier {
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  bool _hasNetwork;
  bool _forceOffline = false;
  List<ConnectivityResult> _lastResults;

  ConnectivityService({bool initialHasNetwork = false})
      : _hasNetwork = initialHasNetwork,
        _lastResults = initialHasNetwork
            ? const [ConnectivityResult.wifi]
            : const [ConnectivityResult.none];

  bool get hasNetwork => _hasNetwork;
  bool get forceOffline => _forceOffline;
  bool get isOnline => _hasNetwork && !_forceOffline;
  bool get isOffline => !isOnline;
  List<ConnectivityResult> get lastResults => _lastResults;

  String get connectionTypeLabel {
    if (_forceOffline) return 'Forced Offline';
    if (!_hasNetwork) return 'No Signal';
    if (_lastResults.contains(ConnectivityResult.wifi)) return 'Wi-Fi';
    if (_lastResults.contains(ConnectivityResult.mobile)) return 'Mobile';
    if (_lastResults.contains(ConnectivityResult.ethernet)) return 'Ethernet';
    return 'Online';
  }

  Future<void> init() async {
    try {
      final initial = await _connectivity.checkConnectivity();
      _applyResults(initial);
    } catch (_) {
      _applyResults(const [ConnectivityResult.none]);
    }

    _subscription = _connectivity.onConnectivityChanged.listen(
      _applyResults,
      onError: (_) => _applyResults(const [ConnectivityResult.none]),
    );
  }

  void _applyResults(List<ConnectivityResult> results) {
    _lastResults = results;
    final onlineNow = results.any(
      (r) => r != ConnectivityResult.none,
    );
    if (onlineNow != _hasNetwork) {
      _hasNetwork = onlineNow;
      notifyListeners();
    } else {
      notifyListeners();
    }
  }

  void setForceOffline(bool value) {
    if (_forceOffline != value) {
      _forceOffline = value;
      notifyListeners();
    }
  }

  void toggleForceOffline() => setForceOffline(!_forceOffline);

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
