import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/api.dart';
import '../core/support.dart';

/// Keeps secrets and late responses out of a changed session or background tab.
mixin SupportViewState<T extends StatefulWidget> on State<T> {
  bool Function() get scopeCurrent;
  Listenable? get accessChanges;
  Object get scopeIdentity;
  void clearSensitive();
  void timeChanged() {}
  bool busy = false, foreground = true, invalidated = false, cleared = false;
  ApiFailure? error;
  int generation = 0;
  Timer? _timer;
  Listenable? _observed;
  late final _SupportLifecycleObserver _observer;
  late final Object _identity;
  bool get usable => mounted && foreground && !invalidated && scopeCurrent();
  int get now => DateTime.now().millisecondsSinceEpoch;
  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    invalidated = !scopeCurrent();
    _identity = scopeIdentity;
    _observed = accessChanges;
    _observed?.addListener(_accessChanged);
    _observer = _SupportLifecycleObserver(didChangeAppLifecycleState);
    WidgetsBinding.instance.addObserver(_observer);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (usable) timeChanged();
    });
  }

  void _clear() {
    generation++;
    busy = false;
    error = null;
    cleared = true;
    clearSensitive();
  }

  void _accessChanged() {
    if (!mounted || scopeCurrent()) return;
    setState(() {
      invalidated = true;
      _clear();
    });
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_observed != accessChanges) {
      _observed?.removeListener(_accessChanged);
      _observed = accessChanges;
      _observed?.addListener(_accessChanged);
    }
    if (!scopeCurrent() || _identity != scopeIdentity) {
      invalidated = true;
      _clear();
    }
  }

  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    setState(() {
      foreground = state == AppLifecycleState.resumed;
      _clear();
    });
  }

  Future<void> perform<R>(Future<R> Function() operation, void Function(R) done,
      {void Function(ApiFailure)? failed}) async {
    if (!usable || busy) return;
    final expected = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await operation();
      if (usable && generation == expected) setState(() => done(result));
    } catch (failure) {
      if (usable && generation == expected)
        setState(() {
          error = failure is ApiFailure
              ? failure
              : const ApiFailure(0, 'NETWORK_ERROR');
          failed?.call(error!);
        });
    } finally {
      if (usable && generation == expected) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    generation++;
    _timer?.cancel();
    _observed?.removeListener(_accessChanged);
    WidgetsBinding.instance.removeObserver(_observer);
    super.dispose();
  }
}

class _SupportLifecycleObserver extends WidgetsBindingObserver {
  final void Function(AppLifecycleState) changed;
  _SupportLifecycleObserver(this.changed);
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => changed(state);
}

String supportTime(int value) {
  try {
    return DateFormat('yyyy-MM-dd HH:mm:ss')
        .format(DateTime.fromMillisecondsSinceEpoch(value));
  } on ArgumentError {
    return '时间无法显示';
  }
}

String supportGrantState(SupportGrant grant, int now) =>
    grant.state == 'REVOKED'
        ? '已撤销'
        : grant.expiresAt <= now || grant.state == 'EXPIRED'
            ? '已到期'
            : '有效期内';
String supportPairingState(SupportPairing pair, int now) =>
    pair.state == 'CONSUMED'
        ? '已用于授权'
        : pair.state == 'CANCELLED'
            ? '已取消'
            : pair.expiresAt <= now || pair.state == 'EXPIRED'
                ? '已到期'
                : '等待客户授权';
Widget supportFact(BuildContext context, String title, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Theme.of(context).textTheme.labelMedium),
      const SizedBox(height: 4),
      SelectionArea(child: Text(value))
    ]));
Widget supportFailure(ApiFailure failure, VoidCallback reauth) => Semantics(
    liveRegion: true,
    child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(supportErrorMessage(failure)),
          if (failure.correlationId != null)
            SelectionArea(child: Text('请求标识：${failure.correlationId}')),
          if (failure.code == 'REAUTH_REQUIRED' || failure.status == 401)
            TextButton.icon(
                onPressed: reauth,
                icon: const Icon(Icons.verified_user_outlined),
                label: const Text('重新认证'))
        ])));
