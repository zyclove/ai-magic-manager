import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/observation.dart' show validObservationReason;
import '../core/permission_observation.dart';
import 'design.dart';

/// Consent, one-app report and evidence state live beside the existing observation page.
class PermissionObservationPanel extends StatefulWidget {
  final PermissionObservationRepository repository;
  final bool canEdit;
  final bool? inventoryEnabled;
  final VoidCallback reauth;
  const PermissionObservationPanel(
      {super.key,
      required this.repository,
      required this.canEdit,
      required this.inventoryEnabled,
      required this.reauth});

  @override
  State<PermissionObservationPanel> createState() =>
      _PermissionObservationPanelState();
}

class _PermissionObservationPanelState
    extends State<PermissionObservationPanel> {
  PermissionObservationSettings? settings;
  PermissionInventory? inventory;
  PermissionObservationResult? result;
  String? selectedPackage;
  Object? error;
  bool busy = false;
  bool changeInFlight = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant PermissionObservationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inventoryEnabled != widget.inventoryEnabled) {
      setState(() {
        inventory = null;
        result = null;
        selectedPackage = null;
      });
      load();
    }
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  Future<void> load() async {
    final request = ++generation;
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final nextSettings = await widget.repository.settings();
      final nextInventory =
          widget.inventoryEnabled == true && nextSettings.enabled
              ? await widget.repository.inventory()
              : null;
      if (!mounted || request != generation) return;
      setState(() {
        settings = nextSettings;
        inventory = nextInventory;
        if (nextInventory == null ||
            !nextInventory.applications
                .any((app) => app.packageName == selectedPackage)) {
          selectedPackage = null;
        }
      });
    } catch (failure) {
      if (mounted && request == generation) {
        setState(() {
          settings = null;
          inventory = null;
          selectedPackage = null;
          error = failure;
        });
      }
    } finally {
      if (mounted && request == generation) setState(() => busy = false);
    }
  }

  Future<void> read() async {
    final selected = selectedPackage;
    if (busy || selected == null) return;
    final request = ++generation;
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final value = await widget.repository.read(selected);
      if (mounted && request == generation) setState(() => result = value);
    } catch (failure) {
      if (mounted && request == generation) setState(() => error = failure);
    } finally {
      if (mounted && request == generation) setState(() => busy = false);
    }
  }

  Future<String?> _reason(bool enabled) async {
    final controller = TextEditingController();
    bool acknowledged = false;
    try {
      return await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                      title: Text(enabled ? '开启应用权限观察' : '撤回应用权限观察'),
                      content: SizedBox(
                          width: 480,
                          child: SingleChildScrollView(
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                Text(enabled
                                    ? '只会在儿童端前台、在线且明确选择一个可见应用后，收集它声明的 Android 权限及系统授予标志。单设备只保留最近一个应用快照，最多 24 小时；这不会更改系统权限。'
                                    : '撤回后服务端删除该注册周期的权限快照；儿童端下次联网核对后清理加密待发结果。已发布的受管策略需另行修改。'),
                                const SizedBox(height: 12),
                                TextField(
                                    controller: controller,
                                    maxLength: 300,
                                    onChanged: (_) => update(() {}),
                                    decoration: const InputDecoration(
                                        labelText: '操作原因')),
                                CheckboxListTile(
                                    contentPadding: EdgeInsets.zero,
                                    value: acknowledged,
                                    onChanged: (value) => update(
                                        () => acknowledged = value == true),
                                    title: const Text('已理解数据范围及撤回后果'))
                              ]))),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: acknowledged &&
                                    validObservationReason(controller.text)
                                ? () => Navigator.pop(
                                    dialogContext, controller.text.trim())
                                : null,
                            child: Text(enabled ? '提交开启' : '提交撤回'))
                      ])));
    } finally {
      controller.dispose();
    }
  }

  Future<void> change() async {
    final before = settings;
    if (changeInFlight || busy || before == null || !widget.canEdit) return;
    changeInFlight = true;
    try {
      final enabled = !before.enabled;
      final reason = await _reason(enabled);
      if (reason == null || !mounted) return;
      final key = requestId();
      setState(() {
        busy = true;
        error = null;
        settings = null;
        result = null;
        inventory = null;
      });
      try {
        await widget.repository.update(before, enabled, reason, key);
        if (mounted) await load();
      } catch (failure) {
        if (mounted) setState(() => error = failure);
      } finally {
        if (mounted) setState(() => busy = false);
      }
    } finally {
      changeInFlight = false;
    }
  }

  String _message(Object failure) {
    if (failure is! ApiFailure) return '操作未完成。请刷新当前设备状态。';
    return switch (failure.code) {
      'PERMISSION_BACKEND_UNAVAILABLE' => '权限观察服务未启用。请联系管理员核对部署开关。',
      'INVALID_PERMISSION_OBSERVATION_RESPONSE' => '权限观察响应未通过校验，已隐藏结果。',
      'PERMISSION_VIEW_CHANGED' ||
      'RESOURCE_VERSION_CONFLICT' =>
        '授权或设备状态在读取期间变化。请刷新后重新操作。',
      'REAUTH_REQUIRED' => '请先完成近期多因素认证。',
      'NETWORK_ERROR' => '网络中断，提交结果可能已生效。请刷新确认，不要立即重复操作。',
      'WORKSPACE_CHANGED' => '工作空间已切换。请关闭窗口并重新打开设备。',
      _ => failure.message
    };
  }

  String _moment(int? millis) {
    if (millis == null) return '尚无记录';
    return DateTime.fromMillisecondsSinceEpoch(millis)
        .toLocal()
        .toString()
        .split('.')
        .first;
  }

  String _state(String code) => switch (code) {
        'RECENT' => '最近已收到代理自报',
        'STALE' => '旧快照，需设备重新采集',
        'NOT_AUTHORIZED' => '未授权',
        _ => '尚无当前快照'
      };

  String _classification(String code) =>
      switch (code) { 'DANGEROUS' => '运行时权限', 'OTHER' => '其他权限', _ => '类别未知' };

  String _grant(String code) =>
      switch (code) { 'GRANTED' => '已授予', 'DENIED' => '未授予', _ => '无法确认' };

  @override
  Widget build(BuildContext context) {
    final candidates = inventory?.applications ?? const <PermissionCandidate>[];
    final unique = <String, PermissionCandidate>{};
    for (final app in candidates) {
      unique.putIfAbsent(app.packageName, () => app);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('应用权限观察', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const Notice('单独授权，只显示当前用户可见应用由设备代理报告的权限声明和授予标志。'
          '普通 Android 应用不能替其他应用修改系统权限；受管策略生效须另看提供方回执。'),
      const SizedBox(height: 14),
      if (busy) const LinearProgressIndicator(),
      if (error != null) ...[
        const SizedBox(height: 8),
        Semantics(
            liveRegion: true, child: Notice(_message(error!), warning: true)),
        if (error is ApiFailure &&
            ((error as ApiFailure).status == 401 ||
                (error as ApiFailure).code == 'REAUTH_REQUIRED'))
          TextButton.icon(
              onPressed: widget.reauth,
              icon: const Icon(Icons.verified_user_outlined),
              label: const Text('进行安全验证')),
      ],
      Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('独立管理员授权', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(settings == null
            ? busy
                ? '正在确认授权状态…'
                : '授权状态未知'
            : settings!.enabled
                ? '已开启'
                : '已关闭'),
        if (settings != null)
          Text('版本 ${settings!.version} · ${_moment(settings!.updatedAt)}'),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: busy ? null : load,
              icon: const Icon(Icons.refresh),
              label: const Text('刷新权限状态')),
          if (widget.canEdit && settings != null)
            FilledButton.icon(
                onPressed: busy ? null : change,
                icon: Icon(settings!.enabled
                    ? Icons.no_accounts_outlined
                    : Icons.verified_user_outlined),
                label: Text(settings!.enabled ? '撤回授权' : '开启授权'))
        ])
      ])),
      const SizedBox(height: 14),
      if (widget.inventoryEnabled == null)
        const EmptyView('应用清单授权状态未知', '尚未确认当前注册周期的应用清单授权，请先刷新上方观察状态。')
      else if (widget.inventoryEnabled == false)
        const EmptyView('先开启应用清单授权', '权限观察需要当前注册周期的可见应用清单；请先在上方“修改观察授权”开启应用清单。')
      else if (settings == null)
        busy
            ? const EmptyView('正在确认权限观察授权', '正在确认当前注册周期的独立授权状态，请稍候。')
            : const EmptyView('权限观察授权状态未知', '尚未确认独立授权状态，请点击“刷新权限状态”后继续。')
      else if (!settings!.enabled)
        const EmptyView('权限观察尚未授权', '开启独立授权后，儿童端仍需在线确认并明确选择一个应用采集。')
      else if (inventory == null)
        busy
            ? const EmptyView('正在读取可见应用', '正在读取当前注册周期的已授权应用清单，请稍候。')
            : const EmptyView('可见应用清单状态未知', '尚未读取到当前注册周期的可见应用清单，请点击“刷新权限状态”重新读取。')
      else ...[
        Text('可见应用 · ${inventory?.status ?? '等待读取'}',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('儿童端需在前台选择并上传；管理端读取不会远程启动摄像头或替设备修改权限。',
            style: TextStyle(color: muted)),
        const SizedBox(height: 12),
        if (unique.isEmpty)
          const EmptyView('暂无可选应用', '请让设备联网并同步已授权应用清单；空列表不表示没有安装应用。')
        else
          Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                LayoutBuilder(
                    builder: (context, constraints) => SizedBox(
                        width: constraints.maxWidth < 360
                            ? constraints.maxWidth
                            : 360,
                        child: DropdownButtonFormField<String>(
                            isExpanded: true,
                            value: unique.containsKey(selectedPackage)
                                ? selectedPackage
                                : null,
                            decoration:
                                const InputDecoration(labelText: '选择可见应用'),
                            items: unique.values
                                .map((app) => DropdownMenuItem(
                                    value: app.packageName,
                                    child: Text(
                                        '${app.displayName} · ${app.packageName}',
                                        overflow: TextOverflow.ellipsis)))
                                .toList(),
                            onChanged: busy
                                ? null
                                : (value) => setState(() {
                                      selectedPackage = value;
                                      result = null;
                                    })))),
                FilledButton.icon(
                    onPressed: busy || selectedPackage == null ? null : read,
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('读取最新上报'))
              ]),
        if (result != null) ...[
          const SizedBox(height: 16),
          Panel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(_state(result!.status),
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                    '应用 ${result!.packageName} · 版本 ${result!.versionCode ?? '未知'}'),
                Text(
                    '设备观察 ${_moment(result!.observedAt)} · 服务端收到 ${_moment(result!.receivedAt)}'),
                const Text('来源：设备代理自报，未经系统策略回读验证。',
                    style: TextStyle(color: muted)),
                if (result!.permissions.isEmpty)
                  const Padding(
                      padding: EdgeInsets.only(top: 10),
                      child: Text('没有当前可展示的 Android 权限条目；不代表设备没有其他权限。')),
                for (final fact in result!.permissions)
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(fact.permissionName
                          .replaceFirst('android.permission.', '')),
                      subtitle: Text(
                          '${_classification(fact.classification)} · 观察结果 ${_grant(fact.observedGrant)} · 系统执行未核对'))
              ]))
        ]
      ]
    ]);
  }
}
