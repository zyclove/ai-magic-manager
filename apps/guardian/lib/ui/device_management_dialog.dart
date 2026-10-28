import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/api.dart';
import '../core/device_management.dart';
import '../core/labels.dart';
import 'design.dart';
import 'device_observation_status.dart';
import 'diagnostic_preview_view.dart' show capabilityName;

/// One scoped device window. The host owns the controller and its disposal.
class DeviceManagementDialog extends StatefulWidget {
  final DeviceManagementController controller;
  final VoidCallback onClose;
  final Listenable? accessChanges;
  final VoidCallback? onReauth;
  final Future<void> Function(DeviceManagementRecord)? onDiagnostic;
  final Future<void> Function(DeviceManagementRecord)? onExport;
  final Future<void> Function(DeviceManagementRecord)? onSupport;
  final Future<void> Function(DeviceManagementRecord)? onPrivacy;
  final Future<void> Function(DeviceManagementRecord)? onExit;

  /// Supplied only when the host grants execution-record access for this scope.
  final Future<void> Function(DeviceManagementRecord)? onExecutions;

  const DeviceManagementDialog({
    super.key,
    required this.controller,
    required this.onClose,
    this.accessChanges,
    this.onReauth,
    this.onDiagnostic,
    this.onExport,
    this.onSupport,
    this.onPrivacy,
    this.onExit,
    this.onExecutions,
  });

  @override
  State<DeviceManagementDialog> createState() => _DeviceManagementDialogState();
}

class _DeviceManagementDialogState extends State<DeviceManagementDialog> {
  final search = TextEditingController();
  _ConfirmationLifetime? confirmationLifetime;
  bool confirming = false, showingSubflow = false;
  bool closeRequested = false;
  bool active = true;
  int interactionEpoch = 0;
  Object? subflowToken;
  DeviceManagementController get c => widget.controller;
  bool get checkingRevoke =>
      c.revokeResultUnknown || c.revokeAcceptedAwaitingRead;

  @override
  void initState() {
    super.initState();
    c.addListener(changed);
    widget.accessChanges?.addListener(scopeChanged);
    unawaited(c.initialize());
  }

  @override
  void didUpdateWidget(covariant DeviceManagementDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c ||
        oldWidget.accessChanges != widget.accessChanges) {
      interactionEpoch++;
      invalidateConfirmation();
      confirming = false;
      showingSubflow = false;
      subflowToken = null;
      closeRequested = false;
    }
    if (oldWidget.accessChanges != widget.accessChanges) {
      oldWidget.accessChanges?.removeListener(scopeChanged);
      widget.accessChanges?.addListener(scopeChanged);
    }
    if (oldWidget.controller != c) {
      oldWidget.controller.removeListener(changed);
      search.clear();
      c.addListener(changed);
      unawaited(c.initialize());
    }
  }

  void changed() {
    if (!c.hasAccess) search.clear();
    if (mounted) setState(() {});
  }

  void scopeChanged() => c.checkScope();

  void invalidateConfirmation() {
    confirmationLifetime?.value = false;
  }

  bool ownsInteraction(DeviceManagementController controller, int epoch) =>
      mounted && active && interactionEpoch == epoch && identical(c, controller);

  // Capture while building. Read/action locks apply at entry, never to their
  // continuations after the controller itself becomes busy or opens a child.
  VoidCallback guard(VoidCallback callback,
      {bool allowBusy = false, bool allowDenied = false}) {
    final controller = c, epoch = interactionEpoch;
    final route = ModalRoute.of(context);
    return () {
      if (!ownsInteraction(controller, epoch) || closeRequested ||
          (!allowDenied && !controller.hasAccess) ||
          (!allowBusy && controller.busy) ||
          (route != null && (!route.isActive || !route.isCurrent))) return;
      callback();
    };
  }

  @override
  void deactivate() {
    active = false;
    interactionEpoch++;
    invalidateConfirmation();
    confirming = false;
    showingSubflow = false;
    subflowToken = null;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    active = true;
    closeRequested = false;
  }

  @override
  void dispose() {
    active = false;
    interactionEpoch++;
    invalidateConfirmation();
    subflowToken = null;
    c.removeListener(changed);
    widget.accessChanges?.removeListener(scopeChanged);
    search.dispose();
    super.dispose();
  }

  void close(VoidCallback onClose) {
    if (!mounted || closeRequested || c.writeBusy) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent || !route.isActive) return;
    closeRequested = true;
    interactionEpoch++;
    invalidateConfirmation();
    onClose();
  }

  Future<void> revoke(DeviceManagementController controller, int epoch) async {
    if (!ownsInteraction(controller, epoch) || !controller.canRevoke) return;
    await controller.revoke(
        (device) => confirmCloudRevoke(controller, epoch, device));
  }

  void finishConfirmation(BuildContext routeContext, bool accepted) {
    if (!routeContext.mounted) return;
    // A queued button callback must not pop a different dialog opened above it.
    if (ModalRoute.of(routeContext)?.isCurrent != true) return;
    Navigator.of(routeContext).pop(accepted);
  }

  Future<bool> confirmCloudRevoke(DeviceManagementController controller,
      int epoch, DeviceManagementRecord device) async {
    if (!ownsInteraction(controller, epoch) || !controller.hasAccess) return false;
    // The confirmation keeps the exact controller and interaction it opened in.
    final lifetime = _ConfirmationLifetime();
    confirmationLifetime = lifetime;
    setState(() => confirming = true);
    try {
      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (inner) => AnimatedBuilder(
          animation: Listenable.merge([controller, lifetime]),
          builder: (_, __) {
            if (!lifetime.value ||
                !ownsInteraction(controller, epoch) ||
                !controller.hasAccess) {
              return AlertDialog(
                title: const Text('工作空间已变化'),
                content: const Text('原设备资料已隐藏，请返回当前工作空间重新核对状态。'),
                actions: [
                  TextButton(
                    onPressed: () => finishConfirmation(inner, false),
                    child: const Text('返回设备管理'),
                  ),
                ],
              );
            }
            return AlertDialog(
              title: const Text('紧急撤销云端访问'),
              content: SingleChildScrollView(
                child: SizedBox(
                  width: 460,
                  child: Text(
                    '将撤销“${device.displayName}”当前注册的云端访问凭证，'
                    '并使该设备的临时访问窗口失效。\n\n'
                    '此操作不会向设备发送本地清理命令，不能证明其他应用已被阻止或本地数据已删除。'
                    '\n\n需要退出本代理管理和核对本地清理时，请使用“退出与操作记录”。',
                    style: const TextStyle(height: 1.7),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => finishConfirmation(inner, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => finishConfirmation(
                    inner,
                    lifetime.value &&
                        ownsInteraction(controller, epoch) &&
                        controller.hasAccess,
                  ),
                  child: const Text('确认撤销云端访问'),
                ),
              ],
            );
          },
        ),
      );
      return accepted == true &&
          lifetime.value &&
          ownsInteraction(controller, epoch) &&
          controller.hasAccess;
    } finally {
      final ownsFlag = identical(confirmationLifetime, lifetime) &&
          ownsInteraction(controller, epoch);
      if (identical(confirmationLifetime, lifetime)) confirmationLifetime = null;
      lifetime.dispose();
      if (ownsFlag) setState(() => confirming = false);
    }
  }

  Widget sectionButton(DeviceManagementSection section, String key,
      String title, IconData icon) {
    final controller = c;
    final selected = controller.section == section;
    return Semantics(
      selected: selected,
      child: OutlinedButton.icon(
        key: Key(key),
        onPressed: controller.busy ? null
            : guard(() => controller.selectSection(section)),
        icon: Icon(icon, size: 18),
        label: Text(title),
        style: OutlinedButton.styleFrom(
          foregroundColor: selected ? navy : muted,
          backgroundColor: selected ? const Color(0xFFEDF4FC) : Colors.white,
          side: BorderSide(color: selected ? navy : line),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      ),
    );
  }

  Widget navigation() => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          sectionButton(DeviceManagementSection.overview,
              'device-section-overview', '概况', Icons.devices_outlined),
          sectionButton(DeviceManagementSection.capabilities,
              'device-section-capabilities', '能力与限制', Icons.shield_outlined),
          if (c.canReadApplications)
            sectionButton(DeviceManagementSection.applications,
                'device-section-applications', '应用清单', Icons.apps_outlined),
        ],
      );

  Widget refreshButton() => checkingRevoke
      ? OutlinedButton.icon(
          key: const Key('device-management-check-result'),
          onPressed: c.busy ? null : guard(c.refresh),
          icon: const Icon(Icons.fact_check_outlined, size: 18),
          label: const Text('核对结果'),
        )
      : TextButton.icon(
          key: const Key('device-management-refresh'),
          onPressed: c.busy ? null : guard(c.refresh),
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(c.error == null ? '刷新资料' : '重试读取'),
        );

  Widget readInformation() => Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            c.updatedAt == null ? '尚未完成设备读取' : '最近读取：${dateLabel(c.updatedAt)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          refreshButton(),
        ],
      );

  Widget scopeUnavailable() {
    final failure = c.error;
    final denied = failure is ApiFailure &&
        (failure.status == 401 || failure.status == 403);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_outline, color: muted, size: 32),
          const SizedBox(height: 12),
          Text(denied ? '访问权限已变化' : '工作空间已变化',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            denied
                ? '原设备资料已隐藏。请关闭窗口，在当前账号下重新核对访问权限。'
                : '工作空间或权限已变化，原设备资料已隐藏。请关闭窗口，在当前工作空间重新打开。',
            style: const TextStyle(color: muted, height: 1.7),
          ),
        ],
      ),
    );
  }

  Widget resultNotice() => Notice(
        c.revokeAcceptedAwaitingRead
            ? '云端撤销请求已接受，最新设备状态尚未核对。请读取结果；不会再次提交撤销。'
            : '云端撤销结果尚未确认。请先核对结果；读到仍已注册不能证明原操作失败，'
                '不会自动重复提交。本地退出与清理需单独核对。',
        warning: true,
      );

  Widget readWarning() {
    final error = c.error;
    if (error == null) return const SizedBox.shrink();
    final failure = error is ApiFailure ? error : null;
    final needsAuthentication = failure?.code == 'REAUTH_REQUIRED';
    if (checkingRevoke && !needsAuthentication) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Notice(
          needsAuthentication
              ? checkingRevoke
                  ? '核对当前设备状态需要重新安全验证；验证后请继续核对结果，不会再次提交撤销。'
                  : '此操作需要重新安全验证，已读取的设备资料仍可查看。'
              : c.device == null
                  ? '暂未取得可用的设备资料，请重试读取。'
                  : '部分内容尚未更新，请重试核对。下面保留最近读取到的资料。',
          key: const Key('device-management-read-warning'),
          warning: true,
        ),
        if (widget.onReauth != null && failure?.status == 401)
          TextButton.icon(
            key: const Key('device-management-reauth'),
            onPressed: c.busy || !c.hasAccess ? null : guard(widget.onReauth!),
            icon: const Icon(Icons.verified_user_outlined, size: 18),
            label: const Text('重新安全验证'),
          ),
        if (failure != null)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('问题详情'),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  '${failure.code}${failure.correlationId == null ? '' : ' · ${failure.correlationId}'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget fact(String title, String value) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: canvas,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget overview(DeviceManagementRecord device) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusTag(device.state),
              DeviceObservationStatus(device.observationStatus),
            ],
          ),
          const SizedBox(height: 16),
          Text(DeviceObservationStatus.explanation(device.observationStatus),
              style: const TextStyle(color: muted, height: 1.7)),
          const SizedBox(height: 20),
          LayoutBuilder(builder: (context, bounds) {
            final twoColumns = bounds.maxWidth >= 500 &&
                MediaQuery.textScalerOf(context).scale(14) <= 19;
            final width =
                twoColumns ? (bounds.maxWidth - 12) / 2 : bounds.maxWidth;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                SizedBox(
                  width: width,
                  child: fact('设备平台',
                      '${label(device.platform)} · ${device.osVersion}'),
                ),
                SizedBox(
                  width: width,
                  child: fact('管理模式', label(device.managementMode)),
                ),
                SizedBox(
                  width: width,
                  child: fact(
                      '控制范围',
                      switch (device.controlLevel) {
                        'LIMITED' => '有限管理能力',
                        'NONE' => '无系统控制能力',
                        _ => '待核对',
                      }),
                ),
                SizedBox(
                  width: width,
                  child: fact(
                      '最近心跳',
                      device.lastHeartbeatAt == null
                          ? '尚无可核对的心跳时间'
                          : dateLabel(device.lastHeartbeatAt)),
                ),
              ],
            );
          }),
          if (!checkingRevoke) ...[
            const SizedBox(height: 20),
            Notice(device.state == 'REVOKED'
                ? '当前注册的云端访问已撤销。本地代理是否退出、数据是否清理，仍需到“退出与操作记录”核对。'
                : device.state == 'AWAITING_CONFIRMATION'
                    ? '这台设备仍等待现场确认。请回到设备连接流程核对面前的设备，注册状态不代表规则已经执行。'
                    : '使用情况与隐私可查看观察授权和已上报资料。需要排查连接或管控范围时，先打开设备诊断。'),
          ],
        ],
      );

  Widget capabilities() {
    final value = c.capabilities;
    return Column(
      key: const Key('device-capabilities-content'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('能力与限制', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        if (value == null)
          const Notice('尚未取得能力资料，请完成读取后核对。')
        else ...[
          Notice(
            value.effectiveCount == 0
                ? '当前没有经服务端确认可用于系统执行的能力。设备自报已授权，也不代表应用限制或额度规则已经生效。'
                : '服务端确认 ${value.effectiveCount} 项能力可用。具体规则是否执行，仍须查看对应执行回执。',
            warning: value.effectiveCount == 0,
          ),
          const SizedBox(height: 10),
          Text(
              '共 ${value.items.length} 项 · 实际读取：${dateLabel(c.sectionUpdatedAt)}',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          if (value.items.isEmpty)
            const Text('尚无能力记录。请检查设备注册与最近心跳。')
          else
            for (final item in value.items)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: canvas,
                    border: Border.all(color: line),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(capabilityName(item.key),
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(item.effectiveSupported
                          ? '服务端确认可用'
                          : labels[item.status] ?? '能力状态待核对'),
                      const SizedBox(height: 6),
                      Text('限制：${labels[item.limitationCode] ?? '限制原因待核对'}'),
                      Text('授权：${labels[item.grantStatus] ?? '授权状态待核对'}'),
                      Text(item.reportedSupported ? '设备自报支持' : '设备未报告支持'),
                      Text('证据：${switch (item.evidenceSource) {
                        'AGENT_REPORT' => '设备自报',
                        'REGISTRATION_MODE' => '注册模式',
                        _ => '待核对',
                      }} · 核对时间：${dateLabel(item.checkedAt)}'),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('能力标识'),
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SelectableText(item.key),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ],
    );
  }

  List<DeviceManagementApplication> matchingApplications() {
    final query = search.text.trim().toLowerCase();
    return (c.inventory?.applications ?? const <DeviceManagementApplication>[])
        .where((app) => app.displayName.toLowerCase().contains(query) ||
            app.packageName.toLowerCase().contains(query))
        .toList(growable: false);
  }

  List<Widget> applicationSlivers(List<DeviceManagementApplication> matches) {
    final value = c.inventory;
    if (value == null) {
      return const [SliverToBoxAdapter(child: Notice('尚未取得应用清单，请完成读取后核对。'))];
    }
    final common = commonActions();
    final observation = switch (value.observationStatus) {
      'NOT_AUTHORIZED' => widget.onPrivacy == null
          ? '应用清单采集尚未授权，请联系有权限的管理员核对采集设置。'
          : '应用清单采集尚未授权。请在“使用情况与隐私”核对采集设置，开启后等待设备上报。',
      'UNKNOWN' => '尚未收到当前注册的应用清单。请核对设备连接和采集设置，等待设备上报。',
      'RECENT' => '近期收到设备上报，清单内容以最近上报时间为准。',
      'STALE' => '应用清单已超过观察时限。下面保留上次上报内容，可能与当前安装情况不同。',
      'REVOKED' => '当前注册已撤销，不能继续接收新的应用清单。下方如有历史内容，仅供核对。',
      _ => '应用清单状态暂不可用，请刷新资料后核对。',
    };
    final searchChanged = guard(() => setState(() {}), allowBusy: true);
    return [
      SliverToBoxAdapter(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('设备自报应用清单', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Notice(observation,
              key: const Key('device-app-observation-status'),
              warning: value.observationStatus == 'STALE' ||
                  value.observationStatus == 'REVOKED'),
          const SizedBox(height: 8),
          const Text('仅展示设备可见并已上报的应用，不代表完整安装清单；设备自报资料尚未独立验证。',
              style: TextStyle(color: muted, height: 1.7)),
          const SizedBox(height: 12),
          Text('最近上报：${dateLabel(value.receivedAt)}',
              style: Theme.of(context).textTheme.bodySmall),
          Text('实际读取：${dateLabel(c.sectionUpdatedAt)}',
              style: Theme.of(context).textTheme.bodySmall),
          if (common.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(spacing: 10, runSpacing: 10, children: common),
          ],
          const SizedBox(height: 16),
          if (value.applications.isNotEmpty) ...[
            TextField(
              key: const Key('device-app-search'),
              controller: search,
              onChanged: (_) => searchChanged(),
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '查找已上报应用',
                hintText: '应用名称或包名',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除应用查找',
                        onPressed: guard(() => setState(search.clear), allowBusy: true),
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (value.applications.isEmpty &&
              const {'RECENT', 'STALE'}.contains(value.observationStatus))
            const Notice('尚无可见应用上报，不能据此判断设备未安装应用。')
          else if (value.applications.isNotEmpty && matches.isEmpty)
            const Notice('当前已上报清单没有匹配项。可清除查找条件后重新查看。')
          else if (matches.isNotEmpty) ...[
            Text('匹配 ${matches.length} / ${value.applications.length} 项',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
          ],
        ],
      )),
      if (matches.isNotEmpty)
        SliverList(delegate: SliverChildBuilderDelegate(
            (context, index) => applicationCard(matches[index]),
            childCount: matches.length)),
    ];
  }

  Widget applicationCard(DeviceManagementApplication app) => Padding(
      key: ValueKey('device-app-item-${app.profile}/${app.packageName}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(border: Border.all(color: line),
              borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(app.displayName,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            SelectableText(app.packageName,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 6),
            Text('${label(app.profile)} · 版本 ${app.versionCode} · '
                '${app.systemApplication ? '系统应用' : '普通应用'}'),
          ])));

  Widget actionButton(String key, String title, IconData icon,
      Future<void> Function(DeviceManagementRecord) action,
      {bool primary = false, bool refreshAfter = true}) {
    final controller = c, epoch = interactionEpoch;
    final enabled = !controller.busy && !checkingRevoke && controller.hasAccess;
    return primary
        ? FilledButton.icon(
            key: Key(key),
            onPressed: enabled
                ? guard(() => runAction(controller, epoch, action,
                    refreshAfter: refreshAfter)) : null,
            icon: Icon(icon, size: 18),
            label: Text(title),
          )
        : OutlinedButton.icon(
            key: Key(key),
            onPressed: enabled
                ? guard(() => runAction(controller, epoch, action,
                    refreshAfter: refreshAfter)) : null,
            icon: Icon(icon, size: 18),
            label: Text(title),
          );
  }

  Future<void> runAction(DeviceManagementController controller, int epoch,
      Future<void> Function(DeviceManagementRecord) action,
      {bool refreshAfter = true}) async {
    if (!ownsInteraction(controller, epoch) || closeRequested ||
        !controller.hasAccess) return;
    await controller.runAction((device) async {
      if (!ownsInteraction(controller, epoch) || !controller.hasAccess) return;
      final token = Object();
      setState(() {
        subflowToken = token;
        showingSubflow = true;
      });
      try {
        await action(device);
      } finally {
        if (ownsInteraction(controller, epoch) && identical(subflowToken, token)) {
          setState(() {
            subflowToken = null;
            showingSubflow = false;
          });
        }
      }
    }, refreshAfter: refreshAfter);
  }

  List<Widget> commonActions() {
    if (checkingRevoke) return const [];
    return <Widget>[
      if (widget.onPrivacy != null)
        actionButton('device-management-privacy', '使用情况与隐私',
            Icons.privacy_tip_outlined, widget.onPrivacy!,
            primary: true),
      if (widget.onDiagnostic != null)
        actionButton('device-management-diagnostic', '设备诊断',
            Icons.health_and_safety_outlined, widget.onDiagnostic!,
            refreshAfter: false),
      if (widget.onExecutions != null)
        actionButton('device-management-executions', '执行记录',
            Icons.history_outlined, widget.onExecutions!),
    ];
  }

  Widget actions(DeviceManagementRecord device) {
    final controller = c, epoch = interactionEpoch;
    if (checkingRevoke) return const SizedBox.shrink();
    final activeWrite = c.canWrite && device.state == 'ACTIVE';
    final canExit = c.canWrite &&
        const {'ACTIVE', 'REVOKED'}.contains(device.state) &&
        widget.onExit != null;
    final common = c.section == DeviceManagementSection.applications &&
            c.inventory != null
        ? const <Widget>[]
        : commonActions();
    final additional = <Widget>[
      if (activeWrite && widget.onExport != null)
        actionButton('device-management-export', '导出诊断包',
            Icons.download_outlined, widget.onExport!),
      if (activeWrite && widget.onSupport != null)
        actionButton('device-management-support', '限时支持授权',
            Icons.support_agent_outlined, widget.onSupport!),
      if (canExit)
        actionButton('device-management-exit', '退出与操作记录', Icons.logout_outlined,
            widget.onExit!),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (common.isNotEmpty || additional.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('设备操作', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          if (common.isNotEmpty)
            Wrap(spacing: 10, runSpacing: 10, children: common),
          if (additional.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 10, children: additional),
          ],
        ],
        if (c.canRevoke) ...[
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7F5),
              border: Border.all(color: const Color(0xFFF0D4CE)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('紧急安全操作', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text('紧急撤销仅停止当前注册的云端访问。本地退出与数据清理需分别核对。'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('device-management-revoke'),
                  onPressed: c.busy ? null : guard(() => revoke(controller, epoch)),
                  icon: const Icon(Icons.link_off_outlined, size: 18),
                  label: const Text('紧急撤销云端访问'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFAA3C35),
                    side: const BorderSide(color: Color(0xFFD9A49A)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget identifiers(DeviceManagementRecord device) => ExpansionTile(
        key: const Key('device-management-identifiers'),
        tilePadding: EdgeInsets.zero,
        title: const Text('编号与注册信息'),
        childrenPadding: const EdgeInsets.only(bottom: 12),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText('设备编号：${device.id}'),
                const SizedBox(height: 8),
                SelectableText('档案编号：${device.subjectId}'),
                const SizedBox(height: 8),
                SelectableText('注册编号：${device.registrationId}'),
                const SizedBox(height: 8),
                SelectableText('公钥指纹：${device.keyThumbprint}'),
                const SizedBox(height: 8),
                Text('资料版本：${device.version}'),
              ],
            ),
          ),
        ],
      );

  List<Widget> contents(List<DeviceManagementApplication> matches) {
    if (!c.hasAccess) return [SliverToBoxAdapter(child: scopeUnavailable())];
    final device = c.device;
    return [
      SliverToBoxAdapter(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            navigation(),
            const SizedBox(height: 16),
            readInformation(),
            const SizedBox(height: 12),
            if (checkingRevoke) ...[
              resultNotice(),
              const SizedBox(height: 16),
            ],
            readWarning(),
            if (device == null)
              if (c.busy)
                const Padding(padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: CircularProgressIndicator()))
              else if (c.error == null)
                const Notice('尚未取得设备资料，请读取后继续。'),
          ])),
      if (device != null) ...[
        if (c.section == DeviceManagementSection.applications)
          ...applicationSlivers(matches)
        else
          SliverToBoxAdapter(child: c.section == DeviceManagementSection.overview
              ? overview(device) : capabilities()),
        SliverToBoxAdapter(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              actions(device),
              const SizedBox(height: 16),
              identifiers(device),
            ])),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final availableHeight =
        (size.height - MediaQuery.viewInsetsOf(context).bottom - 48)
            .clamp(120.0, double.infinity)
            .toDouble();
    final compact = availableHeight < 480;
    final onClose = widget.onClose;
    final matches = c.hasAccess && c.section == DeviceManagementSection.applications
        ? matchingApplications() : const <DeviceManagementApplication>[];
    final name = c.hasAccess ? c.device?.displayName ?? '设备管理' : '设备管理';
    return PopScope(
      canPop: !c.writeBusy,
      child: Dialog(
        key: const Key('device-management-dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: 760, maxHeight: availableHeight),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              semanticsLabel: name,
                              style: Theme.of(context).textTheme.titleLarge),
                          if (!compact) ...[
                            const SizedBox(height: 4),
                            const Text('连接与管理状态',
                                style: TextStyle(color: muted)),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      key: const Key('device-management-close'),
                      tooltip: '关闭设备管理',
                      onPressed: c.writeBusy ? null
                          : guard(() => close(onClose),
                              allowBusy: true, allowDenied: true),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (c.busy && !confirming && !showingSubflow) ...[
                  const LinearProgressIndicator(minHeight: 2),
                  const SizedBox(height: 12),
                ],
                Flexible(
                  child: CustomScrollView(
                    key: const Key('device-management-scroll'),
                    shrinkWrap: true,
                    semanticChildCount: c.hasAccess && c.inventory != null &&
                            c.section == DeviceManagementSection.applications
                        ? matches.length : null,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    slivers: contents(matches),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Invalidation is immediate, including during a parent rebuild/disposal.
/// Notify the retained route after that frame so it can safely redact itself.
class _ConfirmationLifetime extends ValueNotifier<bool> {
  _ConfirmationLifetime() : super(true);
  bool notificationScheduled = false, disposed = false;

  @override
  void notifyListeners() {
    if (disposed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (!notificationScheduled) {
        notificationScheduled = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          notificationScheduled = false;
          if (!disposed) super.notifyListeners();
        });
      }
      return;
    }
    super.notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
