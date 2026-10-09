import 'package:flutter/material.dart';
import 'dart:async';
import 'controller.dart';
import 'models.dart';

const _navy = Color(0xFF19335C);
const _ink = Color(0xFF172238);
const _muted = Color(0xFF67758A);
const _line = Color(0xFFE2E8F0);
const _amber = Color(0xFF795016);
const _cancelWarning =
    '取消只停止服务端继续提供任务或接收新回执。此操作不会恢复云端业务凭证，也不会撤销已执行的清理；离线设备已经缓存的有效命令无法召回。';

/// The host owns controller initialization, scope changes and disposal.
class DeviceExitPanel extends StatefulWidget {
  final ExitController controller;
  final String deviceName;
  final Future<void> Function()? reauthenticate;
  const DeviceExitPanel(
      {super.key,
      required this.controller,
      required this.deviceName,
      this.reauthenticate});
  @override
  State<DeviceExitPanel> createState() => _DeviceExitPanelState();
}

class _DeviceExitPanelState extends State<DeviceExitPanel> {
  Timer? _clockTick;
  bool _authenticating = false;
  @override
  void initState() {
    super.initState();
    // Redraw deadline affordances only; this timer never sends a request.
    _clockTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted &&
          (widget.controller.preview != null ||
              widget.controller.pending != null)) setState(() {});
    });
  }

  @override
  void dispose() {
    _clockTick?.cancel();
    super.dispose();
  }

  Future<void> _reauthenticate() async {
    if (_authenticating || widget.reauthenticate == null) return;
    setState(() => _authenticating = true);
    try {
      await widget.reauthenticate!();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('安全验证未完成，请重新登录或联系管理员。')));
      }
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
    // A successful login is not authorization to automatically retry a write.
  }

  Future<void> _cancel() async {
    final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('取消清理任务？'),
              content: const SizedBox(
                  width: 480,
                  child: SingleChildScrollView(
                      child:
                          Text(_cancelWarning, style: TextStyle(height: 1.7)))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('继续等待')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('确认取消任务'))
              ],
            ));
    if (mounted && accepted == true) {
      await widget.controller.cancel(acceptedWarning: true);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final disabled = c.busy || _authenticating;
        final preview = c.preview;
        final operation = c.operation;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _line)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.logout_outlined, color: _navy, size: 24),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    const Text('退出设备管理',
                        style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                            color: _ink)),
                    const SizedBox(height: 6),
                    Text(widget.deviceName,
                        style: const TextStyle(
                            fontSize: 14, color: _muted, height: 1.5)),
                  ])),
            ]),
            const SizedBox(height: 20),
            if (!c.scope.canRead)
              _notice('当前账号无权查看此设备的退出操作。', warning: true)
            else ...[
              _notice('仅退出当前设备注册的云端业务，并请求清理本代理数据。系统受管解除和整机擦除需单独支持。'),
              if (!c.scope.canManage) ...[
                const SizedBox(height: 12),
                _notice('审计员仅可查看操作状态。')
              ],
              if (c.busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(minHeight: 3),
                const SizedBox(height: 8),
                Semantics(
                    liveRegion: true,
                    child: const Text('正在核对，请稍候…',
                        style: TextStyle(color: _muted)))
              ],
              if (c.error != null) ...[
                const SizedBox(height: 16),
                Semantics(
                    liveRegion: true,
                    child: _notice(c.error!.message, warning: true)),
                if (c.error!.correlationId != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: SelectableText('问题关联编号：${c.error!.correlationId}',
                          style: const TextStyle(fontSize: 12, color: _muted))),
                if ((c.error!.code == 'REAUTH_REQUIRED' ||
                        c.error!.status == 401) &&
                    widget.reauthenticate != null)
                  TextButton.icon(
                      onPressed: disabled ? null : _reauthenticate,
                      icon: const Icon(Icons.verified_user_outlined, size: 18),
                      label: Text(_authenticating ? '正在安全验证…' : '重新安全验证')),
                if (!c.initialized)
                  TextButton.icon(
                      onPressed: disabled ? null : c.initialize,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重新加载')),
              ],
              if (c.pending != null) ...[
                const SizedBox(height: 20),
                const Text('提交结果待确认',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _ink)),
                const SizedBox(height: 8),
                _notice('恢复记录已保留。核对将使用原请求标识，不会创建新的退出请求。', warning: true),
                if (c.initialized &&
                    c.scope.canManage &&
                    !c.canRetry &&
                    !c.busy)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _notice('原请求已超出核对期限，或本地时间异常。请查看操作记录并联系管理员，不要重复退出。',
                          warning: true)),
                const SizedBox(height: 16),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  FilledButton.icon(
                      onPressed:
                          disabled || !c.canRetry ? null : c.retryPending,
                      icon: const Icon(Icons.sync, size: 18),
                      label: const Text('核对上次提交')),
                  OutlinedButton.icon(
                      onPressed: disabled ? null : c.refresh,
                      icon: const Icon(Icons.history, size: 18),
                      label: const Text('查看当前状态')),
                ]),
              ] else if (preview != null) ...[
                const SizedBox(height: 24),
                if (!preview.understood)
                  _notice('设备能力已变化，请更新客户端或联系管理员。', warning: true)
                else ...[
                  const Text('退出后的影响',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _ink)),
                  const SizedBox(height: 12),
                  ...preview.consequences
                      .map((code) => _bullet(consequenceLabels[code]!)),
                  const SizedBox(height: 16),
                  const Divider(color: _line),
                  const SizedBox(height: 16),
                  const Text('适用范围与限制',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: _ink)),
                  const SizedBox(height: 12),
                  ...preview.limitations.map(
                      (code) => _bullet(limitationLabels[code]!, muted: true)),
                  const SizedBox(height: 12),
                  Text('预览有效至 ${_time(preview.expiresAt)}（设备本地时间）',
                      style: const TextStyle(fontSize: 12, color: _muted)),
                  if (c.previewExpired)
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: _notice('预览已过期，请重新获取预览并再次确认。', warning: true)),
                  CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('我已了解退出后的影响',
                          style: TextStyle(fontSize: 14, color: _ink)),
                      value: c.acknowledged,
                      onChanged: disabled || c.previewExpired
                          ? null
                          : (v) => c.acknowledge(v ?? false)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    FilledButton(
                        onPressed: disabled || !c.canConfirm ? null : c.confirm,
                        child: const Text('确认退出')),
                    TextButton(
                        onPressed: disabled || !c.canPrepare ? null : c.prepare,
                        child: const Text('重新获取预览')),
                  ]),
                ],
              ],
              if (operation != null) ...[
                const SizedBox(height: 24),
                const Divider(color: _line),
                const SizedBox(height: 24),
                const Text('操作状态',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _ink)),
                const SizedBox(height: 16),
                LayoutBuilder(builder: (context, constraints) {
                  final cards = [
                    _status('云端业务访问', operation.understood ? '已撤销' : '状态待核对',
                        Icons.cloud_off_outlined),
                    _status('本地清理', operation.stateLabel,
                        Icons.phonelink_erase_outlined)
                  ];
                  if (constraints.maxWidth < 600 ||
                      MediaQuery.textScalerOf(context).scale(14) > 21) {
                    return Column(children: [
                      cards[0],
                      const SizedBox(height: 12),
                      cards[1]
                    ]);
                  }
                  return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: cards[0]),
                        const SizedBox(width: 16),
                        Expanded(child: cards[1])
                      ]);
                }),
                const SizedBox(height: 12),
                Text('清理截止：${_time(operation.notAfter)}（设备本地时间）',
                    style: const TextStyle(fontSize: 12, color: _muted)),
                const SizedBox(height: 8),
                const Text('云端撤销不证明本地数据已删除。取消任务也不会恢复设备业务凭证。',
                    style: TextStyle(fontSize: 13, color: _muted, height: 1.6)),
                if (operation.reasonCode != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _notice(
                          _reasons[operation.reasonCode] ?? '设备报告了其他原因，请联系管理员。',
                          warning: true)),
                const SizedBox(height: 16),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  OutlinedButton.icon(
                      onPressed: disabled ? null : c.refresh,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('刷新状态')),
                  if (c.scope.canManage && operation.canCancel)
                    TextButton(
                        onPressed: disabled || !c.canCancel ? null : _cancel,
                        child: const Text('取消清理任务')),
                ]),
              ],
              if (c.pending == null && preview == null && c.canPrepare) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                    onPressed: disabled ? null : c.prepare,
                    icon: const Icon(Icons.fact_check_outlined, size: 18),
                    label: Text(operation == null ? '查看退出后果' : '重新预览清理任务')),
              ],
              if (c.initialized &&
                  c.scope.canRead &&
                  !c.scope.canManage &&
                  operation == null) ...[
                const SizedBox(height: 16),
                const Text('当前没有退出操作记录。', style: TextStyle(color: _muted)),
                TextButton(
                    onPressed: disabled ? null : c.refresh,
                    child: const Text('刷新状态')),
              ],
            ],
          ]),
        );
      });

  Widget _bullet(String text, {bool muted = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(muted ? Icons.info_outline : Icons.check_circle_outline,
                size: 18, color: muted ? _muted : _navy)),
        const SizedBox(width: 10),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 14, height: 1.6, color: muted ? _muted : _ink))),
      ]));
  Widget _notice(String text, {bool warning = false}) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: warning ? const Color(0xFFFFF7E9) : const Color(0xFFEDF4FC),
          borderRadius: BorderRadius.circular(8)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.info_outline, size: 20, color: warning ? _amber : _navy),
        const SizedBox(width: 10),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 13,
                    height: 1.6,
                    color: warning ? _amber : _navy)))
      ]));
  Widget _status(String label, String value, IconData icon) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: const Color(0xFFF7F9FC),
          border: Border.all(color: _line),
          borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 18, color: _muted),
          const SizedBox(width: 8),
          Expanded(
              child: Text(label,
                  style: const TextStyle(fontSize: 12, color: _muted)))
        ]),
        const SizedBox(height: 10),
        Semantics(
            liveRegion: true,
            child: Text(value,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: _ink,
                    height: 1.5))),
      ]));
}

String _time(DateTime value) {
  final local = value.toLocal();
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${pad(local.month)}-${pad(local.day)} ${pad(local.hour)}:${pad(local.minute)}';
}

const _reasons = {
  'STORAGE_FAILURE': '设备存储清理失败，请检查设备后重试。',
  'KEY_UNAVAILABLE': '设备密钥不可用，请联系管理员。',
  'UNSUPPORTED_AGENT': '设备代理不支持此清理流程。',
  'USER_ACTION_REQUIRED': '需要在设备上完成操作，请联系设备使用者。'
};
