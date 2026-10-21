import 'package:flutter/material.dart';
import '../core/family.dart';
import '../core/family_device_access.dart';
import '../core/parent_api.dart';
import '../core/parent_durable_storage.dart';
import '../core/parent_session.dart';
import 'family_workspace.dart';

String _graceDate(int value) {
  final time = DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)
      .add(const Duration(hours: 8));
  String two(int value) => '$value'.padLeft(2, '0');
  return '${time.month} 月 ${time.day} 日 ${two(time.hour)}:${two(time.minute)}（北京时间）';
}

String _accessTitle(FamilyDeviceAccessSnapshot state) => switch (state.status) {
      'PAID' => '已连接 ${state.activeCount} / ${state.effectiveDeviceLimit} 台设备',
      'GRACE' => '请选择 1 台继续基础管理',
      'EXPIRED' => '会员已到期，保留 1 台基础管理',
      _ => '免费基础版 · 1 台设备',
    };

String _accessDetail(FamilyDeviceAccessSnapshot state) {
  if (state.status == 'PAID') return '有效家庭会员支持 3 台儿童设备，手动续费，不自动扣款。';
  if (state.status == 'GRACE') {
    return '请在 ${_graceDate(state.graceEndsAt!)}前选择。确认后立即结束选择期。';
  }
  final retained = state.retainedDevice;
  if (retained == null) return '连接设备后，可以选择 1 台使用基础作息和当日报告。';
  return '当前保留：${retained.subjectName} · ${retained.displayName}';
}

/// Home receives the same authoritative projection as the rest of its dashboard.
class FamilyDeviceAccessSummary extends StatelessWidget {
  final FamilyDeviceAccessSnapshot snapshot;
  final VoidCallback onOpen;
  const FamilyDeviceAccessSummary(
      {super.key, required this.snapshot, required this.onOpen});
  @override
  Widget build(BuildContext context) => FamilyPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.devices_outlined, color: familyInk, size: 30),
        const SizedBox(height: 12),
        Text(_accessTitle(snapshot),
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(_accessDetail(snapshot),
            style: const TextStyle(color: familyMuted)),
        const SizedBox(height: 8),
        TextButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.chevron_right),
            label: Text(snapshot.status == 'GRACE' ? '选择保留设备' : '查看设备名额')),
      ]));
}

class FamilyDeviceAccessEntry extends StatefulWidget {
  final ParentSession session;
  final ParentDurableStorage? storage;
  const FamilyDeviceAccessEntry(
      {super.key, required this.session, this.storage});
  @override
  State<FamilyDeviceAccessEntry> createState() =>
      _FamilyDeviceAccessEntryState();
}

class _FamilyDeviceAccessEntryState extends State<FamilyDeviceAccessEntry>
    with FamilyScope {
  @override
  ParentSession get session => widget.session;
  FamilyDeviceAccessSnapshot? snapshot;
  Object? error;
  bool loading = true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (!current) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = FamilyDeviceAccessSnapshot.fromJson(
          await service.object('/family-device-access'));
      if (value.tenantId != scopeTenant) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (current) setState(() => snapshot = value);
    } catch (e) {
      if (current) setState(() => error = e);
    } finally {
      if (current) setState(() => loading = false);
    }
  }

  Future<void> open() async {
    if (!current) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            FamilyDeviceAccessPage(session: session, storage: widget.storage)));
    await load();
  }

  @override
  Widget build(BuildContext context) {
    if (!current) return const SizedBox.shrink();
    if (loading) return const FamilyPanel(child: LinearProgressIndicator());
    if (error != null || snapshot == null) {
      return FamilyPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('设备名额暂未读取'),
        if (error != null) Text(familyError(error!)),
        TextButton(onPressed: load, child: const Text('重新读取设备名额')),
      ]));
    }
    return FamilyDeviceAccessSummary(snapshot: snapshot!, onOpen: open);
  }
}

class FamilyDeviceAccessPage extends StatefulWidget {
  final ParentSession session;
  final ParentDurableStorage? storage;
  const FamilyDeviceAccessPage(
      {super.key, required this.session, this.storage});
  @override
  State<FamilyDeviceAccessPage> createState() => _FamilyDeviceAccessPageState();
}

class _FamilyDeviceAccessPageState extends State<FamilyDeviceAccessPage>
    with FamilyScope, WidgetsBindingObserver {
  @override
  ParentSession get session => widget.session;
  late FamilyDeviceSelectionCoordinator coordinator;
  bool foreground = true, loading = true, busy = false;
  int epoch = 0;
  Object? error;
  String? selected, receipt;
  BuildContext? confirmationContext;
  Future<void>? mutation;
  bool get active => current && foreground;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_dismissInvalidConfirmation);
    _newCoordinator();
    load();
  }

  void _newCoordinator() {
    final generation = epoch;
    coordinator = FamilyDeviceSelectionCoordinator(
        service: FamilyService(
            api: session.api,
            tenantId: scopeTenant,
            available: () => active && epoch == generation),
        actor: scopeActor,
        storage: widget.storage);
  }

  void _dismissConfirmation() {
    final dialog = confirmationContext;
    confirmationContext = null;
    if (dialog != null && dialog.mounted) Navigator.of(dialog).pop(false);
  }

  void _dismissInvalidConfirmation() {
    if (!current) _dismissConfirmation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final resumed = state == AppLifecycleState.resumed;
    if (!resumed && foreground) {
      _dismissConfirmation();
      setState(() {
        foreground = false;
        epoch++;
        receipt = null;
      });
    } else if (resumed && !foreground) {
      setState(() {
        foreground = true;
        loading = true;
      });
      _resume();
    }
  }

  Future<void> _resume() async {
    final generation = epoch;
    // A previous write may still be persisting its journal or receiving a reply.
    // Finish its durability boundary before reading that same journal again.
    await mutation;
    if (!active || epoch != generation) return;
    busy = false;
    _newCoordinator();
    await load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_dismissInvalidConfirmation);
    super.dispose();
  }

  Future<void> load() async {
    if (!active || busy || coordinator.busy) return;
    final generation = epoch, original = coordinator;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await original.load();
      if (!active || epoch != generation || coordinator != original) return;
      setState(() => selected = original.snapshot!.selectedDeviceId ??
          original.snapshot!.devices.where((d) => d.canSelect).firstOrNull?.id);
    } catch (e) {
      if (active && epoch == generation && coordinator == original) {
        setState(() => error = e);
      }
    } finally {
      if (active && epoch == generation && coordinator == original) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> confirm() async {
    if (!active || busy || coordinator.pending != null) return;
    final generation = epoch;
    final device = coordinator.snapshot?.devices
        .where((d) => d.id == selected && d.canSelect)
        .firstOrNull;
    if (device == null) return;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (dialog) {
          confirmationContext = dialog;
          return AlertDialog(
              title: const Text('保留这台设备？'),
              scrollable: true,
              content: Text('${device.subjectName} · ${device.displayName}\n\n'
                  '${coordinator.snapshot!.status == 'GRACE' ? '确认后立即结束选择期。' : ''}'
                  '此设备继续基础管理。其他设备保留既有规则，仍可放宽、解除限制、必要放行及正常退出。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(dialog, true),
                    child: const Text('确认选择')),
              ]);
        });
    confirmationContext = null;
    if (accepted != true || !active || epoch != generation) return;
    await runChoice(device: device);
  }

  Future<void> runChoice({FamilyAccessDevice? device}) async {
    if (!active || busy) return;
    final generation = epoch, original = coordinator;
    setState(() {
      busy = true;
      error = null;
      receipt = null;
    });
    final operation = () async {
      try {
        if (device == null) {
          await original.retry();
        } else {
          await original.select(device.id, device.registrationId);
        }
        if (!active || epoch != generation || coordinator != original) return;
        setState(() => receipt = '选择已保存，请核对下方当前保留设备。');
        await original.load();
        if (active && epoch == generation && coordinator == original) {
          setState(() => selected = original.snapshot?.selectedDeviceId);
        }
      } catch (e) {
        if (active && epoch == generation && coordinator == original) {
          setState(() => error = e);
        }
      } finally {
        if (active && epoch == generation && coordinator == original) {
          setState(() => busy = false);
        }
      }
    }();
    mutation = operation;
    await operation;
    if (identical(mutation, operation)) mutation = null;
  }

  Future<void> reauthenticate() async {
    if (!active || busy) return;
    final navigator = Navigator.of(context);
    setState(() => busy = true);
    final result = await session.reauthenticate();
    if (!mounted) return;
    if (result) {
      navigator.pop();
    } else if (active) {
      setState(() {
        busy = false;
        error = session.error ?? '安全验证未完成，请重试。';
      });
    }
  }

  Widget _device(FamilyAccessDevice device, bool editable) {
    final detail = '${device.subjectName} · ${switch (device.access) {
      'MEMBER' => '会员设备',
      'GRACE' => '选择期内继续使用',
      'BASIC' => '当前保留 · 基础管理',
      _ => '保留既有规则 · 可恢复与退出'
    }}${device.state == 'AWAITING_CONFIRMATION' ? '\n等待完成连接' : ''}';
    if (!editable) {
      return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.devices),
          title: Text(device.displayName),
          subtitle: Text(detail));
    }
    return RadioListTile<String>(
        key: ValueKey(device.id),
        contentPadding: EdgeInsets.zero,
        value: device.id,
        groupValue: selected,
        onChanged: busy || !device.canSelect
            ? null
            : (value) => setState(() => selected = value),
        title: Text(device.displayName),
        subtitle: Text(detail));
  }

  @override
  Widget build(BuildContext context) {
    final state = coordinator.snapshot, pending = coordinator.pending;
    final originalDevice = pending == null
        ? null
        : state?.devices
            .where((d) =>
                d.id == pending['deviceId'] &&
                d.registrationId == pending['registrationId'])
            .firstOrNull;
    return Scaffold(
        appBar: AppBar(title: const Text('设备名额')),
        body: !current
            ? const Center(child: Text('当前家庭或权限已变化，请返回重新打开。'))
            : !foreground
                ? const Center(child: Text('返回后会重新核对设备状态。'))
                : loading
                    ? const Center(child: CircularProgressIndicator())
                    : RefreshIndicator(
                        onRefresh: load,
                        child: ListView(
                            padding: const EdgeInsets.all(20),
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              if (receipt != null) FamilyNotice(receipt!),
                              if (error != null)
                                FamilyNotice(
                                    error is ParentApiException &&
                                            (error as ParentApiException)
                                                    .code ==
                                                'REAUTH_REQUIRED'
                                        ? '请完成近期手机号安全验证。验证后重新打开设备名额，继续核对原选择。'
                                        : familyError(error!),
                                    error: true),
                              if (error is ParentApiException &&
                                  (error as ParentApiException).code ==
                                      'REAUTH_REQUIRED')
                                FilledButton(
                                    onPressed: busy ? null : reauthenticate,
                                    child: const Text('完成安全验证')),
                              if (state == null || !coordinator.loaded)
                                OutlinedButton(
                                    onPressed: busy ? null : load,
                                    child: const Text('重新读取设备名额')),
                              if (state != null && coordinator.loaded) ...[
                                FamilyPanel(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      const Icon(Icons.devices_outlined,
                                          color: familyInk, size: 36),
                                      const SizedBox(height: 16),
                                      Text(_accessTitle(state),
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleLarge),
                                      const SizedBox(height: 8),
                                      Text(_accessDetail(state)),
                                      if (state.status != 'PAID') ...[
                                        const SizedBox(height: 12),
                                        const Text(
                                            '其他设备保留既有规则，仍可放宽、解除限制、必要放行及正常退出。续费后可恢复会员管理。',
                                            style:
                                                TextStyle(color: familyMuted)),
                                      ],
                                    ])),
                                if (pending != null)
                                  FamilyPanel(
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                        Text('上次选择仍待核对',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        const SizedBox(height: 8),
                                        Text(originalDevice == null
                                            ? '原设备状态已变化，请先查询当前选择。'
                                            : '原选择：${originalDevice.subjectName} · ${originalDevice.displayName}'),
                                        const SizedBox(height: 8),
                                        const Text(
                                            '网络中断或验证未完成时，结果可能仍在处理中。查询只读取当前状态；继续核对会使用同一次选择，不会改选另一台。'),
                                        const SizedBox(height: 12),
                                        Wrap(
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: [
                                              OutlinedButton(
                                                  onPressed: busy ? null : load,
                                                  child: const Text('查询当前选择')),
                                              FilledButton(
                                                  onPressed: busy
                                                      ? null
                                                      : () => runChoice(),
                                                  child: const Text('继续核对原选择')),
                                            ]),
                                      ])),
                                if (state.devices.isEmpty)
                                  const FamilyNotice(
                                      '还没有已连接的儿童设备。返回今日页即可扫码连接。'),
                                if (state.devices.isNotEmpty)
                                  FamilyPanel(
                                      child: Column(children: [
                                    for (final device in state.devices)
                                      _device(
                                          device,
                                          state.status != 'PAID' &&
                                              pending == null),
                                  ])),
                                if (state.status != 'PAID' &&
                                    pending == null &&
                                    state.devices.any((d) => d.canSelect)) ...[
                                  const SizedBox(height: 16),
                                  FilledButton(
                                      onPressed: busy || selected == null
                                          ? null
                                          : confirm,
                                      child: const Text('确认保留此设备')),
                                ],
                                if (busy)
                                  const Padding(
                                      padding: EdgeInsets.all(16),
                                      child: LinearProgressIndicator()),
                              ],
                            ])));
  }
}
