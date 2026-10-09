import 'package:device_access/device_access.dart';
import 'package:flutter/material.dart';
import '../core/access.dart';
import 'design.dart';

/// Child-only explanatory view. It exposes no local override, grant or reset.
class AccessSection extends StatefulWidget {
  final ChildAccessSnapshot view;
  final bool busy, available;
  final String? errorCode, correlationId;
  final VoidCallback? synchronize;
  const AccessSection(
      {super.key,
      required this.view,
      this.busy = false,
      this.available = true,
      this.errorCode,
      this.correlationId,
      this.synchronize});
  @override
  State<AccessSection> createState() => _AccessSectionState();
}

class _AccessSectionState extends State<AccessSection> {
  int _visible = 8;
  String _state(ChildAccessEntry entry) {
    final record = entry.record;
    if (record.state == AccessEntryState.expired ||
        record.state == AccessEntryState.removed &&
            record.window.fields['approvalState'] == 'EXPIRED') return '已到期';
    if (record.state == AccessEntryState.removed) return '已撤回';
    if (entry.requiresReview) return '需要重新核对';
    return switch (record.state) {
      AccessEntryState.stored =>
        record.pendingAcknowledgement ? '等待服务确认' : '已保存',
      AccessEntryState.baselineMissing => '基础规则已变化',
      AccessEntryState.rejected => record.reasonCode == 'BASELINE_MISSING'
          ? '等待基础规则'
          : record.reasonCode == 'EXPIRED'
              ? '已到期'
              : '未接收',
      _ => '需要重新核对'
    };
  }

  String _time(BuildContext context, int millis) {
    try {
      final date = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
      final local = MaterialLocalizations.of(context);
      return '${local.formatFullDate(date)} ${local.formatTimeOfDay(TimeOfDay.fromDateTime(date), alwaysUse24HourFormat: true)}';
    } catch (_) {
      return '时间暂不可用';
    }
  }

  String _error(String code) => switch (code) {
        'CONNECTION_FAILED' ||
        'NETWORK_TIMEOUT' =>
          '暂时无法连接。下方若有上次记录，仍以原截止时间为准，不会自动延长。',
        'DEVICE_UNAUTHENTICATED' ||
        'SCOPE_DENIED' ||
        'DEVICE_CREDENTIAL_UNAVAILABLE' ||
        'ACCESS_TARGET_CHANGED' =>
          '设备身份或管理员授权需要重新确认，旧记录已停止展示。请联系监护人。',
        'CLOCK_UNTRUSTED' => '设备时间无法确认，已停止展示旧的临时访问安排。请监护人检查时间后重新同步。',
        'ACCESS_STORAGE_FAILED' ||
        'ACCESS_KEY_UNAVAILABLE' ||
        'STORAGE_FAILURE' ||
        'ACCESS_RESTORE_FAILED' =>
          '安全存储暂不可用，原数据会保留。请重试或联系监护人，不要卸载应用或清空记录。',
        'BASELINE_MISSING' ||
        'BASELINE_UNAVAILABLE' =>
          '需要先同步对应基础规则，再重新核对临时安排。',
        'ACCESS_TRUST_UNAVAILABLE' ||
        'ACCESS_CONTEXT_INVALID' ||
        'SIGNATURE_INVALID' ||
        'KEY_NOT_TRUSTED' =>
          '临时安排未通过安全检查。请监护人检查设备连接与服务配置。',
        'STORAGE_CAPACITY' ||
        'ACCESS_STATE_LIMIT' =>
          '设备记录已达到安全容量，需要监护人协助处理。原记录会保留。',
        _ => '本次同步未完成，请重试或联系监护人。'
      };
  void _details(ChildAccessEntry entry) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
              title: Text(entry.applicationName),
              content: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(_state(entry),
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 16),
                    const Text('原截止时间'),
                    Text(_time(context, entry.record.window.absoluteNotAfter)),
                    const SizedBox(height: 16),
                    const Text('批准起始时间'),
                    Text(_time(context, entry.record.window.grantIssuedAt)),
                    const SizedBox(height: 16),
                    const Text('按设备本地时间显示。离线、重启或重试都不会自动延长原截止时间。'),
                    const SizedBox(height: 16),
                    const Text('当前应用只保存监护人批准的配置，尚不能解锁或限制其他应用，也不会增加使用额度。'),
                    if (entry.requiresReview)
                      const Padding(
                          padding: EdgeInsets.only(top: 16),
                          child: Text('存在尚未解决的核对问题。再次成功同步后才会更新此状态。')),
                    if (entry.record.state ==
                            AccessEntryState.baselineMissing ||
                        entry.record.reasonCode == 'BASELINE_MISSING')
                      const Padding(
                          padding: EdgeInsets.only(top: 16),
                          child: Text('对应的基础规则尚未保存或已经变化，请先同步规则。'))
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('知道了'))
              ]));
  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final entries = [...view.entries]..sort((a, b) {
        final aStored = a.record.state == AccessEntryState.stored,
            bStored = b.record.state == AccessEntryState.stored;
        if (aStored != bStored) return aStored ? -1 : 1;
        return b.record.window.absoluteNotAfter
            .compareTo(a.record.window.absoluteNotAfter);
      });
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
          header: true,
          child: Text('临时访问', style: Theme.of(context).textTheme.titleLarge)),
      const SizedBox(height: 12),
      const Text('查看监护人批准的临时安排、原截止时间与同步结果。'),
      const SizedBox(height: 16),
      if (!view.contextReady)
        const ChildNotice('需要在线确认设备身份', detail: '首次连接或安全核对未完成时，不能恢复旧的临时访问记录。')
      else if (!view.onlineConfirmed)
        const ChildNotice('尚未在线核对最新状态',
            detail: '正在查看上次验证的本地记录。离线无法获知新的撤回，原截止时间不会延长。'),
      if (view.lastOnlineAt != null)
        Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text('最近在线核对：${_time(context, view.lastOnlineAt!)}')),
      if (entries.isEmpty)
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('当前没有可显示的临时安排。')),
      for (final entry in entries.take(_visible))
        Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.all(16),
                    side: const BorderSide(color: childLine)),
                onPressed: () => _details(entry),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.schedule_outlined, color: childNavy),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(entry.applicationName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 6),
                            Text(_state(entry),
                                style: TextStyle(
                                    color: entry.requiresReview
                                        ? const Color(0xFF946000)
                                        : childTeal,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            Text(
                                '原截止：${_time(context, entry.record.window.absoluteNotAfter)}',
                                style: Theme.of(context).textTheme.bodyMedium)
                          ])),
                      const SizedBox(width: 8),
                      const Icon(Icons.chevron_right, color: childMuted)
                    ]))),
      if (entries.length > _visible)
        Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextButton(
                onPressed: () => setState(() => _visible += 8),
                child: const Text('显示更多记录'))),
      if (view.pendingReceipts > 0)
        Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text('还有 ${view.pendingReceipts} 条记录等待服务确认，重试不会延长截止时间。')),
      if (view.issues.isNotEmpty)
        const Padding(
            padding: EdgeInsets.only(top: 16),
            child: ChildNotice('部分记录需要核对',
                detail: '已标注相关安排。请重试；若仍未恢复，请监护人检查规则或服务。', warning: true)),
      if (widget.errorCode != null)
        Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Semantics(
                liveRegion: true,
                child: ChildNotice(_error(widget.errorCode!), warning: true))),
      if (widget.correlationId != null)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('问题编号：${widget.correlationId}')),
      const SizedBox(height: 20),
      SizedBox(
          width: double.infinity,
          child: FilledButton(
              onPressed:
                  widget.available && !widget.busy ? widget.synchronize : null,
              child: Text(widget.busy
                  ? '正在同步…'
                  : view.hasMore
                      ? '继续同步临时访问'
                      : '同步临时访问'))),
      const SizedBox(height: 16),
      const Text('已保存不代表系统限制已经改变。儿童端不能修改批准范围、截止时间或管理员规则。')
    ]);
  }
}
