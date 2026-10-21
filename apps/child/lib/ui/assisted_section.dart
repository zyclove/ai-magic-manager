import 'dart:async';
import 'package:flutter/material.dart';
import '../core/assisted_runtime.dart';
import 'design.dart';

class ChildAssistedSection extends StatefulWidget {
  final AndroidAssistedRuntime runtime;
  final VoidCallback? onRequest;
  final bool available;
  const ChildAssistedSection(
      {super.key,
      required this.runtime,
      required this.onRequest,
      required this.available});
  @override
  State<ChildAssistedSection> createState() => _ChildAssistedSectionState();
}

class _ChildAssistedSectionState extends State<ChildAssistedSection>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.runtime.addListener(_changed);
    _resume();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant ChildAssistedSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.available != widget.available) _resume();
  }

  void _resume() {
    _timer?.cancel();
    if (!widget.available) return;
    unawaited(widget.runtime.refresh());
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_busy) unawaited(widget.runtime.refresh());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resume();
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.runtime.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy || !widget.available) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enable() async {
    final agreed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('开启家庭应用辅助'),
                content: const SingleChildScrollView(
                    child: Text('仅根据前台应用包名核对已验证的家庭安排。不读取页面、聊天或输入文字。\n\n'
                        '额度用完或不在可用时段时，辅助服务会返回桌面。电话、系统设置、桌面和本应用始终可用。\n\n'
                        '你还需要自行授予使用情况访问和无障碍服务权限。可随时在本应用或系统设置关闭；系统也可能停止服务。')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('暂不开启')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('了解并同意'))
                ]));
    if (agreed == true && mounted) {
      await _action(() => widget.runtime.setConsent(true));
    }
  }

  String _health(AssistedSnapshot snapshot) => switch (snapshot.health) {
        'ACTIVE' => '家庭应用辅助正在运行',
        'CONSENT_REQUIRED' || 'DISABLED' => '家庭应用辅助尚未开启',
        'PERMISSION_MISSING' => '需要恢复使用情况访问或无障碍权限',
        'CLOCK_ANOMALY' => '时间或运行状态异常，辅助已暂停',
        'EXPIRED' => '本机安排已到期，请同步新安排',
        'CONFIGURATION_UNAVAILABLE' ||
        'CONFIGURATION_INVALID' =>
          '尚无可执行的已验证家庭安排',
        'FOREGROUND_UNAVAILABLE' || 'INITIALIZING' => '正在核对当前应用状态',
        _ => '本机辅助状态尚未核对',
      };
  String _reason(AssistedSnapshot snapshot) =>
      snapshot.health == 'CLOCK_ANOMALY'
          ? '请校准设备时间，并请监护人重新发布安排，再同步核对。期间辅助保持暂停。'
          : switch (snapshot.reason) {
              'quota_exhausted' => '今日目标应用的使用额度已用完。',
              'outside_schedule' => '现在不在监护人设置的可用时段内。',
              'exception_active' => '监护人批准的临时放行仍有效。',
              'within_rules' => '当前目标应用符合本机安排。',
              'package_safe' => '电话、系统设置、桌面及恢复入口保持可用。',
              'package_unmanaged' => '当前应用不在本机安排的目标范围内。',
              _ => '请先核对本机授权和已同步的家庭安排。',
            };
  @override
  Widget build(BuildContext context) {
    final snapshot =
        widget.available ? widget.runtime.snapshot : const AssistedSnapshot();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('家庭应用辅助', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      ChildNotice(_health(snapshot), detail: _reason(snapshot)),
      if (snapshot.health == 'ACTIVE' && snapshot.remainingSeconds != null) ...[
        const SizedBox(height: 12),
        Text(
            '今日剩余 ${snapshot.remainingSeconds! ~/ 60} 分 ${snapshot.remainingSeconds! % 60} 秒',
            style: Theme.of(context).textTheme.titleMedium),
      ],
      const SizedBox(height: 12),
      const Text('这是应用层辅助。卸载、强制停止或关闭权限可能使辅助停止；不具备系统级锁定能力。'),
      const SizedBox(height: 12),
      if (snapshot.optedIn)
        OutlinedButton(
            onPressed: _busy || !widget.available
                ? null
                : () => _action(() => widget.runtime.setConsent(false)),
            child: const Text('关闭本机辅助'))
      else
        FilledButton(
            onPressed: _busy || !widget.available ? null : _enable,
            child: const Text('开启家庭应用辅助')),
      Wrap(spacing: 8, children: [
        TextButton(
            onPressed: _busy || !widget.available
                ? null
                : () => _action(widget.runtime.openUsageSettings),
            child: const Text('使用情况授权')),
        TextButton(
            onPressed: _busy || !widget.available
                ? null
                : () => _action(widget.runtime.openAccessibilitySettings),
            child: const Text('无障碍与恢复')),
        TextButton(
            onPressed: _busy || !widget.available
                ? null
                : () => _action(widget.runtime.refresh),
            child: const Text('核对本机状态')),
        TextButton(
            onPressed: !widget.available ? null : widget.onRequest,
            child: const Text('申请临时放行')),
      ]),
    ]);
  }
}
