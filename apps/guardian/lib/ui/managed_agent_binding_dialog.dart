import 'dart:async';
import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/device_management.dart';
import '../core/labels.dart';
import '../core/managed_agent_binding.dart';
import '../core/managed_agent_binding_repository.dart';
import 'design.dart';

/// Local dialog state belongs to the originating workspace; the parent closes it on scope changes.
class ManagedAgentBindingDialog extends StatefulWidget {
  final ManagedAgentBindingRepository repository;
  final bool writable;
  final VoidCallback reauthenticate;
  final DateTime Function()? now;
  const ManagedAgentBindingDialog(
      {super.key,
      required this.repository,
      required this.writable,
      required this.reauthenticate,
      this.now});
  @override
  State<ManagedAgentBindingDialog> createState() =>
      _ManagedAgentBindingDialogState();
}

class _ManagedAgentBindingDialogState extends State<ManagedAgentBindingDialog> {
  ManagedAgentBindingContext? data;
  ManagedAgentBinding? binding;
  List<DeviceManagementRecord> devices = const [];
  DeviceManagementRecord? selected;
  ({String key, DeviceManagementRecord device})? pendingCreate;
  String? nextCursor;
  Object? error;
  bool loading = true, busy = false, confirmRevoke = false;
  int generation = 0;
  DateTime? verifyAfter;
  Timer? clock;
  DateTime get now => widget.now?.call() ?? DateTime.now();
  bool get current => mounted && widget.repository.current();
  String? get state => binding?.stateAt(now);
  bool get active => state == 'PENDING' || state == 'VERIFIED';
  bool get enabled =>
      current && widget.writable && !loading && !busy && error == null;
  @override
  void initState() {
    super.initState();
    _load();
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (current && binding?.state == 'PENDING') setState(() {});
    });
  }

  @override
  void dispose() {
    generation++;
    clock?.cancel();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (!current || busy || (more && nextCursor == null)) return;
    final ticket = ++generation;
    final cursor = more ? nextCursor : null;
    setState(() {
      loading = true;
      error = null;
      confirmRevoke = false;
    });
    try {
      final result = await widget.repository.context(cursor: cursor);
      if (!current || ticket != generation) return;
      if (more &&
          result.candidates.any((d) => devices.any((old) => old.id == d.id))) {
        throw const ApiFailure(502, 'INVALID_MANAGED_BINDING_RESPONSE');
      }
      setState(() {
        data = result;
        binding = result.currentBinding;
        devices = List.unmodifiable(
            more ? [...devices, ...result.candidates] : result.candidates);
        nextCursor = result.nextCursor;
        final pending = pendingCreate;
        if (pending != null &&
            binding?.deviceId == pending.device.id &&
            binding?.registrationId == pending.device.registrationId) {
          pendingCreate = null;
        }
        final matches = devices
            .where((d) =>
                d.id == selected?.id &&
                d.registrationId == selected?.registrationId)
            .toList();
        selected = pendingCreate?.device ??
            (matches.isNotEmpty
                ? matches.first
                : devices.length == 1
                    ? devices.first
                    : null);
      });
    } catch (failure) {
      if (current && ticket == generation) setState(() => error = failure);
    } finally {
      if (current && ticket == generation) setState(() => loading = false);
    }
  }

  Future<void> _create() async {
    if (!enabled || data?.ready != true || active || selected == null) return;
    final pending = pendingCreate ??
        (key: widget.repository.newRequestId(), device: selected!);
    setState(() {
      pendingCreate = pending;
      busy = true;
      error = null;
    });
    try {
      final result = await widget.repository.create(
          pending.key, pending.device.id, pending.device.registrationId);
      if (!current) return;
      setState(() {
        binding = result;
        pendingCreate = null;
        verifyAfter = now.add(const Duration(seconds: 5));
      });
    } catch (failure) {
      if (current) {
        setState(() {
          error = failure;
          if (failure is ApiFailure &&
              failure.status >= 400 &&
              failure.status < 500 &&
              failure.status != 408) pendingCreate = null;
        });
      }
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> _verify() async {
    final target = binding;
    if (!enabled ||
        data?.ready != true ||
        target == null ||
        state != 'PENDING' ||
        (verifyAfter != null && now.isBefore(verifyAfter!))) return;
    setState(() {
      busy = true;
      confirmRevoke = false;
      verifyAfter = now.add(const Duration(seconds: 5));
    });
    try {
      final result = await widget.repository.verify(target);
      if (current) setState(() => binding = result);
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> _revoke() async {
    final target = binding;
    if (!enabled || !confirmRevoke || target == null || !active) return;
    setState(() => busy = true);
    try {
      final result = await widget.repository.revoke(target);
      if (current) {
        setState(() {
          binding = result;
          confirmRevoke = false;
          pendingCreate = null;
        });
      }
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  String get statusTitle => switch (state) {
        'PENDING' => '等待儿童端反馈',
        'VERIFIED' => '儿童端身份已核验',
        'EXPIRED' => '关联请求已到期',
        'REVOKED' => '本地关联已撤销',
        _ => '选择要关联的儿童端',
      };
  String get statusDetail => switch (state) {
        'PENDING' => '请让所选设备保持联网，并打开机构批准的儿童端。收到身份反馈后，点击下方按钮核验。',
        'VERIFIED' => '这条注册记录与儿童端的身份已完成核验。应用限制是否生效，需要另行查看设备的执行回执。',
        'EXPIRED' => '本次请求不再接受反馈。确认设备联网后，可以重新发起关联。',
        'REVOKED' => '这次本地关联已停止。设备在提供方的受管状态与合同名额没有因此改变。',
        _ => '这里只列出同一学生已经激活的设备，无需填写设备编号。',
      };
  String get deviceName {
    final found = devices.where((d) =>
        d.id == binding?.deviceId &&
        d.registrationId == binding?.registrationId);
    return found.isEmpty ? '所选设备' : found.first.displayName;
  }

  Widget _status(BuildContext context) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: state == 'VERIFIED'
              ? const Color(0xffeff9f3)
              : const Color(0xfff2f6fc),
          borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(
              state == 'VERIFIED'
                  ? Icons.verified_user_outlined
                  : state == 'PENDING'
                      ? Icons.hourglass_top
                      : Icons.devices_outlined,
              color: state == 'VERIFIED' ? const Color(0xff28734d) : navy),
          const SizedBox(width: 10),
          Expanded(
              child: Text(statusTitle,
                  style: Theme.of(context).textTheme.titleMedium)),
        ]),
        const SizedBox(height: 10),
        Text(statusDetail),
        if (binding != null) ...[
          const SizedBox(height: 10),
          Text(deviceName, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (state == 'PENDING')
            Text('有效至 ${dateLabel(binding!.expiresAt)}',
                style: const TextStyle(color: muted)),
          if (state == 'VERIFIED')
            Text('核验时间 ${dateLabel(binding!.verifiedAt)}',
                style: const TextStyle(color: muted)),
        ],
      ]));

  @override
  Widget build(BuildContext context) {
    final waiting = verifyAfter != null && now.isBefore(verifyAfter!);
    return PopScope(
        canPop: !busy,
        child: AlertDialog(
          scrollable: true,
          title: const Text('关联儿童端'),
          content: SizedBox(
              width: 600,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (loading) const LinearProgressIndicator(),
                    if (data != null) ...[
                      _status(context),
                      const SizedBox(height: 16),
                      if (!data!.ready) ...[
                        Notice(managedBindingReason(data!.reasonCode),
                            warning: true),
                        const SizedBox(height: 16)
                      ],
                      if (!widget.writable)
                        const Notice('当前为只读查看。发起、核验与撤销需要机构管理员操作。'),
                      if (!active && widget.writable) ...[
                        if (devices.isEmpty && !loading)
                          const Text('尚无可选择的儿童端。请先完成这位学生的儿童端配对与激活，再刷新。'),
                        for (final device in devices)
                          RadioListTile<String>(
                              key: ValueKey('binding-device-${device.id}'),
                              contentPadding: EdgeInsets.zero,
                              title: Text(device.displayName),
                              subtitle: Text(
                                  '${device.platform == 'ANDROID_TV' ? '电视' : '手机 / 平板'} · Android ${device.osVersion} · ${device.id.substring(0, 8)}'),
                              value: device.id,
                              groupValue: selected?.id,
                              onChanged: enabled &&
                                      pendingCreate == null &&
                                      data!.ready
                                  ? (_) => setState(() => selected = device)
                                  : null),
                        if (nextCursor != null)
                          TextButton(
                              onPressed: enabled && pendingCreate == null
                                  ? () => _load(more: true)
                                  : null,
                              child: const Text('加载更多设备')),
                      ],
                      if (pendingCreate != null) ...[
                        const SizedBox(height: 12),
                        const Notice(
                            '上次提交结果尚未确认。可先查询当前记录；若仍未找到，使用“重试原请求”继续，不会生成重复请求。',
                            warning: true),
                      ],
                      if (active && widget.writable) ...[
                        const SizedBox(height: 8),
                        if (!confirmRevoke)
                          TextButton.icon(
                              onPressed: enabled
                                  ? () => setState(() => confirmRevoke = true)
                                  : null,
                              icon: const Icon(Icons.link_off, size: 18),
                              label: const Text('撤销此关联')),
                        if (confirmRevoke) ...[
                          const Notice('确认停止这次本地关联？设备退管与合同名额需另行处理。',
                              warning: true),
                          Wrap(spacing: 8, children: [
                            TextButton(
                                onPressed: busy
                                    ? null
                                    : () =>
                                        setState(() => confirmRevoke = false),
                                child: const Text('保留关联')),
                            OutlinedButton(
                                onPressed: enabled ? _revoke : null,
                                child: const Text('确认撤销')),
                          ])
                        ],
                      ],
                    ],
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Notice(managedBindingError(error!), warning: true),
                      if (error is ApiFailure &&
                          (error as ApiFailure).status == 401)
                        TextButton(
                            onPressed: busy ? null : widget.reauthenticate,
                            child: const Text('重新安全验证')),
                    ],
                    if (busy)
                      const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: LinearProgressIndicator()),
                  ])),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.of(context).pop(),
                child: const Text('关闭')),
            OutlinedButton.icon(
                onPressed: busy || loading || !current ? null : () => _load(),
                icon: const Icon(Icons.refresh),
                label: Text(pendingCreate == null ? '刷新记录' : '查询当前结果')),
            if (widget.writable && !active)
              FilledButton(
                  onPressed: enabled && data?.ready == true && selected != null
                      ? _create
                      : null,
                  child: Text(pendingCreate != null
                      ? '重试原请求'
                      : state == 'EXPIRED' || state == 'REVOKED'
                          ? '重新发起关联'
                          : '开始关联')),
            if (widget.writable && state == 'PENDING')
              FilledButton.icon(
                  onPressed: enabled && data?.ready == true && !waiting
                      ? _verify
                      : null,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: Text(waiting ? '稍候再核验' : '核验设备反馈')),
          ],
        ));
  }
}
