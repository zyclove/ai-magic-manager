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
  final Future<void> Function(ManagedAgentBinding binding,
      {required bool readOnly,
      required bool Function() parentCurrent,
      required Listenable parentChanges})? onExecutions;
  final Future<void> Function(ManagedAgentBinding binding,
      {required bool Function() parentCurrent,
      required Listenable parentChanges,
      required VoidCallback onParentRefresh})? onApplicationEvidence;
  final DateTime Function()? now;
  const ManagedAgentBindingDialog(
      {super.key,
      required this.repository,
      required this.writable,
      required this.reauthenticate,
      this.onExecutions,
      this.onApplicationEvidence,
      this.now});
  @override
  State<ManagedAgentBindingDialog> createState() =>
      _ManagedAgentBindingDialogState();
}

/// One child journey owns one immutable association snapshot. Once its parent
/// is lost or the child finishes, observing the old scope again cannot revive it.
class _BindingChildLifetime extends ChangeNotifier {
  final bool Function() parentCurrent;
  bool _lost = false;

  _BindingChildLifetime(this.parentCurrent);

  bool get current {
    checkCurrent();
    return !_lost;
  }

  void checkCurrent() {
    if (!_lost && !parentCurrent()) {
      invalidate();
    }
  }

  void invalidate() {
    if (_lost) {
      return;
    }
    _lost = true;
    notifyListeners();
  }
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
  bool feedbackChecked = false;
  bool _scopeLost = false;
  final deviceSearch = TextEditingController();
  int generation = 0, bindingEpoch = 0;
  DateTime? verifyAfter;
  Timer? clock;
  _BindingChildLifetime? bindingChild;
  DateTime get now => widget.now?.call() ?? DateTime.now();
  bool get current {
    if (!mounted || _scopeLost) return false;
    if (!widget.repository.current()) {
      _scopeLost = true;
      return false;
    }
    return true;
  }
  String? get state => binding?.stateAt(now);
  bool get active => state == 'PENDING' || state == 'VERIFIED';
  bool get enabled =>
      current && widget.writable && !loading && !busy && error == null;

  void _close() {
    if (!mounted || busy) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent != true || route?.isActive != true) return;
    Navigator.of(context).pop();
  }

  bool _bindingTargetCurrent(ManagedAgentBinding target) =>
      current &&
      !loading &&
      error == null &&
      data?.enrollmentId == widget.repository.enrollmentId &&
      data?.subjectId == widget.repository.subjectId &&
      target.enrollmentId == widget.repository.enrollmentId &&
      binding?.id == target.id &&
      binding?.enrollmentId == target.enrollmentId &&
      binding?.deviceId == target.deviceId &&
      binding?.registrationId == target.registrationId &&
      binding?.version == target.version &&
      binding?.state == target.state &&
      binding?.verifiedAt == target.verifiedAt &&
      binding?.createdAt == target.createdAt &&
      binding?.expiresAt == target.expiresAt;

  bool _applicationEvidenceTargetCurrent(ManagedAgentBinding target) =>
      _bindingTargetCurrent(target) &&
      widget.writable &&
      data?.ready == true &&
      target.state == 'VERIFIED' &&
      target.verifiedAt != null;

  void _invalidateBindingSnapshot() {
    bindingEpoch++;
    bindingChild?.invalidate();
  }

  Future<void> _openApplicationEvidence(
      ManagedAgentBinding target, int expectedEpoch) async {
    if (!current) return;
    final open = widget.onApplicationEvidence;
    final parentRoute = ModalRoute.of(context);
    if (!enabled ||
        open == null ||
        bindingChild != null ||
        bindingEpoch != expectedEpoch ||
        parentRoute?.isActive != true ||
        parentRoute?.isCurrent != true ||
        !_applicationEvidenceTargetCurrent(target)) {
      return;
    }
    final repository = widget.repository;
    final lifetime = _BindingChildLifetime(() =>
        identical(widget.repository, repository) &&
        bindingEpoch == expectedEpoch &&
        parentRoute!.isActive &&
        _applicationEvidenceTargetCurrent(target));
    bool refreshRequested = false;
    bindingChild = lifetime;
    setState(() {
      busy = true;
      confirmRevoke = false;
    });
    try {
      await open(target,
          parentCurrent: () => lifetime.current,
          parentChanges: lifetime,
          onParentRefresh: () {
            if (lifetime.current) {
              refreshRequested = true;
            }
          });
    } catch (failure) {
      if (lifetime.current) {
        setState(() => error = failure);
      }
    } finally {
      final refresh = refreshRequested && lifetime.current;
      lifetime.invalidate();
      if (identical(bindingChild, lifetime)) {
        bindingChild = null;
      }
      lifetime.dispose();
      if (mounted) {
        setState(() => busy = false);
      }
      // A return action requests a new GET only after the child has released
      // its fixed version. Ordinary closing never refreshes implicitly.
      if (refresh &&
          identical(widget.repository, repository) &&
          bindingEpoch == expectedEpoch &&
          _applicationEvidenceTargetCurrent(target)) {
        await _load();
      }
    }
  }

  Future<void> _openExecutions(
      ManagedAgentBinding target, int expectedEpoch) async {
    if (!current) return;
    final open = widget.onExecutions;
    final parentRoute = ModalRoute.of(context);
    if (!_bindingTargetCurrent(target) ||
        busy ||
        open == null ||
        bindingChild != null ||
        bindingEpoch != expectedEpoch ||
        parentRoute?.isActive != true ||
        parentRoute?.isCurrent != true) {
      return;
    }
    final repository = widget.repository;
    final readOnly = !_applicationEvidenceTargetCurrent(target);
    final lifetime = _BindingChildLifetime(() =>
        identical(widget.repository, repository) &&
        bindingEpoch == expectedEpoch &&
        parentRoute!.isActive &&
        _bindingTargetCurrent(target) &&
        (readOnly || _applicationEvidenceTargetCurrent(target)));
    bindingChild = lifetime;
    setState(() {
      busy = true;
      confirmRevoke = false;
    });
    try {
      await open(target,
          readOnly: readOnly,
          parentCurrent: () => lifetime.current,
          parentChanges: lifetime);
    } catch (failure) {
      if (lifetime.current) setState(() => error = failure);
    } finally {
      lifetime.invalidate();
      if (identical(bindingChild, lifetime)) {
        bindingChild = null;
      }
      lifetime.dispose();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      bindingChild?.checkCurrent();
      if (current && binding?.state == 'PENDING') setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant ManagedAgentBindingDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    final repositoryChanged =
        !identical(oldWidget.repository, widget.repository);
    if (repositoryChanged || oldWidget.writable != widget.writable) {
      _invalidateBindingSnapshot();
    }
    if (repositoryChanged) {
      generation++;
      data = null;
      binding = null;
      devices = const [];
      selected = null;
      deviceSearch.clear();
      pendingCreate = null;
      nextCursor = null;
      verifyAfter = null;
      feedbackChecked = false;
      confirmRevoke = false;
      loading = false;
      error = const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
  }

  @override
  void dispose() {
    bindingChild?.invalidate();
    generation++;
    clock?.cancel();
    deviceSearch.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (!current || busy || (more && nextCursor == null)) return;
    final repository = widget.repository;
    final ticket = ++generation;
    final cursor = more ? nextCursor : null;
    setState(() {
      loading = true;
      error = null;
      confirmRevoke = false;
    });
    try {
      final result = await repository.context(cursor: cursor);
      if (!current ||
          ticket != generation ||
          !identical(widget.repository, repository)) return;
      if (more &&
          result.candidates.any((d) => devices.any((old) => old.id == d.id))) {
        throw const ApiFailure(502, 'INVALID_MANAGED_BINDING_RESPONSE');
      }
      _invalidateBindingSnapshot();
      setState(() {
        data = result;
        binding = result.currentBinding;
        feedbackChecked = false;
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
    final repository = widget.repository;
    final ticket = generation;
    final pending = pendingCreate ??
        (key: widget.repository.newRequestId(), device: selected!);
    setState(() {
      pendingCreate = pending;
      busy = true;
      error = null;
    });
    try {
      final result = await repository.create(
          pending.key, pending.device.id, pending.device.registrationId);
      if (!current ||
          ticket != generation ||
          !identical(widget.repository, repository)) return;
      _invalidateBindingSnapshot();
      setState(() {
        binding = result;
        feedbackChecked = false;
        pendingCreate = null;
        verifyAfter = now.add(const Duration(seconds: 5));
      });
    } catch (failure) {
      if (current &&
          ticket == generation &&
          identical(widget.repository, repository)) {
        setState(() {
          error = failure;
          if (failure is ApiFailure &&
              failure.status >= 400 &&
              failure.status < 500 &&
              failure.status != 408) pendingCreate = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _verify() async {
    final target = binding;
    if (!enabled ||
        data?.ready != true ||
        target == null ||
        state != 'PENDING' ||
        (verifyAfter != null && now.isBefore(verifyAfter!))) return;
    final repository = widget.repository;
    final ticket = generation;
    setState(() {
      busy = true;
      confirmRevoke = false;
      verifyAfter = now.add(const Duration(seconds: 5));
    });
    try {
      final result = await repository.verify(target);
      if (current &&
          ticket == generation &&
          identical(widget.repository, repository)) {
        _invalidateBindingSnapshot();
        setState(() {
          binding = result;
          feedbackChecked = result.state == 'PENDING';
        });
      }
    } catch (failure) {
      if (current &&
          ticket == generation &&
          identical(widget.repository, repository)) {
        setState(() => error = failure);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _revoke() async {
    final target = binding;
    if (!enabled || !confirmRevoke || target == null || !active) return;
    final repository = widget.repository;
    final ticket = generation;
    setState(() => busy = true);
    try {
      final result = await repository.revoke(target);
      if (current &&
          ticket == generation &&
          identical(widget.repository, repository)) {
        _invalidateBindingSnapshot();
        setState(() {
          binding = result;
          confirmRevoke = false;
          pendingCreate = null;
        });
      }
    } catch (failure) {
      if (current &&
          ticket == generation &&
          identical(widget.repository, repository)) {
        setState(() => error = failure);
      }
    } finally {
      if (mounted) setState(() => busy = false);
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

  /// Search is local to loaded candidates; it never widens the authorized scope.
  List<DeviceManagementRecord> get visibleDevices {
    final query = deviceSearch.text.trim().toLowerCase();
    if (query.isEmpty) return devices;
    return devices
        .where((device) => device.displayName.toLowerCase().contains(query))
        .toList();
  }

  String get remainingTime {
    final milliseconds = binding!.expiresAt - now.millisecondsSinceEpoch;
    final seconds = milliseconds <= 0 ? 0 : (milliseconds / 1000).ceil();
    return '剩余 ${seconds ~/ 60} 分 ${seconds % 60} 秒';
  }

  Widget _progress(BuildContext context) {
    final complete = state == 'VERIFIED';
    final submitted = state == 'PENDING' || complete;
    return Wrap(spacing: 12, runSpacing: 8, children: [
      for (final step in [
        (number: 1, label: '选择设备', done: submitted, current: !submitted),
        (number: 2, label: '接收反馈', done: complete, current: state == 'PENDING'),
        (number: 3, label: '身份核验', done: complete, current: false),
      ])
        Semantics(
            container: true,
            label:
                '第 ${step.number} 步，${step.label}，${step.done ? '已完成' : step.current ? '当前步骤' : '待完成'}',
            excludeSemantics: true,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                  step.done
                      ? Icons.check_circle_outline
                      : step.current
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                  size: 18,
                  color: step.done
                      ? const Color(0xff28734d)
                      : step.current
                          ? navy
                          : muted),
              const SizedBox(width: 6),
              Text('${step.number} ${step.label}',
                  style: Theme.of(context).textTheme.labelLarge),
            ])),
    ]);
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
          if (state == 'PENDING') ...[
            const SizedBox(height: 6),
            Text(remainingTime,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            Text('到期后可重新发起；等待不会延长有效期。',
                style: Theme.of(context).textTheme.bodySmall),
          ],
          if (state == 'VERIFIED')
            Text('核验时间 ${dateLabel(binding!.verifiedAt)}',
                style: const TextStyle(color: muted)),
        ],
      ]));

  @override
  Widget build(BuildContext context) {
    final waiting = verifyAfter != null && now.isBefore(verifyAfter!);
    final executionTarget = binding;
    final applicationTarget = binding;
    final targetEpoch = bindingEpoch;
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
                      _progress(context),
                      const SizedBox(height: 16),
                      _status(context),
                      const SizedBox(height: 16),
                      if (state == 'PENDING') ...[
                        if (feedbackChecked)
                          Semantics(
                              liveRegion: true,
                              child: const Notice(
                                  '刚刚核验仍未收到有效反馈。请保持儿童端打开，稍后再核验，无需重新关联。')),
                        const ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: Text('一直在等待？查看排查方法'),
                            childrenPadding: EdgeInsets.only(bottom: 12),
                            expandedCrossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text('1. 确认打开的是所选设备上的儿童端，且网络可用。'),
                              SizedBox(height: 8),
                              Text('2. 保持儿童端在前台，使用机构批准的版本。'),
                              SizedBox(height: 8),
                              Text(
                                  '3. 若仍无反馈，请联系机构管理员检查受管接入与反馈配置。普通家庭设备可能不支持此功能。'),
                            ]),
                      ],
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
                        if (devices.length > 5 ||
                            deviceSearch.text.isNotEmpty) ...[
                          TextField(
                              controller: deviceSearch,
                              enabled: !busy && pendingCreate == null,
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                  labelText: '搜索已加载的设备',
                                  helperText: '按设备名称查找；更多设备可在下方加载。',
                                  helperMaxLines: 3,
                                  prefixIcon: const Icon(Icons.search),
                                  suffixIcon: deviceSearch.text.isEmpty
                                      ? null
                                      : IconButton(
                                          tooltip: '清除搜索',
                                          onPressed: () =>
                                              setState(deviceSearch.clear),
                                          icon: const Icon(Icons.close)))),
                          const SizedBox(height: 8),
                          if (visibleDevices.isEmpty)
                            const Text('已加载的设备中没有匹配结果，请更换名称或加载更多。'),
                          if (selected != null)
                            Text('已选：${selected!.displayName}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                        ],
                        for (final device in visibleDevices)
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
            if (applicationTarget != null &&
                widget.onApplicationEvidence != null &&
                _applicationEvidenceTargetCurrent(applicationTarget))
              OutlinedButton.icon(
                key: const Key('managed-binding-application-evidence'),
                onPressed: enabled
                    ? () =>
                        _openApplicationEvidence(applicationTarget, targetEpoch)
                    : null,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('应用核验'),
              ),
            if (executionTarget != null && widget.onExecutions != null)
              OutlinedButton.icon(
                key: const Key('managed-binding-executions'),
                onPressed: busy || loading || !current || error != null
                    ? null
                    : () => _openExecutions(executionTarget, targetEpoch),
                icon: const Icon(Icons.history_outlined),
                label: const Text('执行记录'),
              ),
            if (state != 'VERIFIED')
              TextButton(
                  onPressed: busy ? null : _close, child: const Text('关闭')),
            OutlinedButton.icon(
                onPressed: busy || loading || !current ? null : () => _load(),
                icon: const Icon(Icons.refresh),
                label: Text(pendingCreate == null ? '刷新记录' : '查询当前结果')),
            if (state == 'VERIFIED')
              FilledButton.icon(
                  onPressed: busy ? null : _close,
                  icon: const Icon(Icons.check),
                  label: const Text('完成')),
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
