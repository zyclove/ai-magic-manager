import 'package:device_policy/device_policy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AssistedSnapshot {
  final String health, limitStatus, reason;
  final int? remainingSeconds, observedAt;
  final bool optedIn, usageGranted, accessibilityConnected;
  const AssistedSnapshot(
      {this.health = 'UNAVAILABLE',
      this.limitStatus = 'UNKNOWN',
      this.reason = 'NATIVE_OBSERVATION_UNAVAILABLE',
      this.remainingSeconds,
      this.observedAt,
      this.optedIn = false,
      this.usageGranted = false,
      this.accessibilityConnected = false});
  bool get systemEnforced => false;

  static AssistedSnapshot fromNative(Object? raw, int nowMillis) {
    if (raw is! Map ||
        raw['observedAt'] is! int ||
        (raw['observedAt'] as int) <= 0 ||
        raw['systemEnforced'] != false ||
        raw['health'] is! String ||
        raw['limitStatus'] is! String ||
        raw['optedIn'] is! bool ||
        raw['usageGranted'] is! bool ||
        raw['accessibilityConnected'] is! bool) {
      return const AssistedSnapshot();
    }
    final time = raw['observedAt'] as int;
    final remaining = raw['remainingSeconds'];
    if (time < nowMillis - 15000 ||
        time > nowMillis + 30000 ||
        (raw['health'] == 'ACTIVE' &&
            (raw['optedIn'] != true ||
                raw['usageGranted'] != true ||
                raw['accessibilityConnected'] != true ||
                remaining is! int ||
                remaining < 0 ||
                remaining > 86400))) {
      return const AssistedSnapshot();
    }
    return AssistedSnapshot(
        health: raw['health'] as String,
        limitStatus: raw['limitStatus'] as String,
        reason: raw['reason'] is String ? raw['reason'] as String : 'UNKNOWN',
        remainingSeconds:
            remaining is int && remaining >= 0 && remaining <= 86400
                ? remaining
                : null,
        observedAt: raw['observedAt'] as int,
        optedIn: raw['optedIn'] == true,
        usageGranted: raw['usageGranted'] == true,
        accessibilityConnected: raw['accessibilityConnected'] == true);
  }
}

class AndroidAssistedRuntime extends ChangeNotifier {
  final MethodChannel channel;
  final Future<void> Function(Map<String, dynamic>)? report;
  final int Function() nowMillis;
  int _generation = 0;
  bool _disposed = false;
  AssistedSnapshot snapshot = const AssistedSnapshot();
  AndroidAssistedRuntime(
      {this.channel = const MethodChannel('com.aimanager.child/assistance'),
      this.report,
      int Function()? nowMillis})
      : nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Reverify compact data, including when callers construct a typed model.
  /// Native repeats signature verification with the installation's public ring.
  /// This channel has no operation accepting unsigned executable rules.
  Future<void> acceptVerified(List<VerifiedConfiguration> configurations,
      ConfigurationVerifier verifier) async {
    final compact = <String>[];
    for (final value in configurations) {
      final verified = await verifier.verify(value.compact, restoration: true);
      compact.add(verified.compact);
    }
    await _invoke('acceptSignedConfigurations', {
      'tenantId': verifier.scope.tenantId,
      'deviceId': verifier.scope.deviceId,
      'registrationId': verifier.scope.registrationId,
      'configurations': compact,
    });
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? arguments]) async {
    if (_disposed) return;
    final generation = ++_generation;
    Object? raw;
    AssistedSnapshot observation;
    try {
      raw = await channel
          .invokeMethod<Object?>(method, arguments)
          .timeout(const Duration(seconds: 5));
      observation = AssistedSnapshot.fromNative(raw, nowMillis());
    } catch (_) {
      observation = const AssistedSnapshot();
    }
    if (_disposed || generation != _generation) return;
    snapshot = observation;
    notifyListeners();
    if (!_disposed &&
        generation == _generation &&
        report != null &&
        raw is Map &&
        snapshot.observedAt != null) {
      // Uploader separately rechecks enrolled identity, freshness and whitelist.
      await report!(Map<String, dynamic>.from(raw));
    }
  }

  Future<void> refresh() => _invoke('inspect');
  Future<void> setConsent(bool enabled) =>
      _invoke('setConsent', {'enabled': enabled});
  Future<void> openUsageSettings() => _invoke('openUsageSettings');
  Future<void> openAccessibilitySettings() =>
      _invoke('openAccessibilitySettings');
  Future<void> clear() => _invoke('clear');

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
