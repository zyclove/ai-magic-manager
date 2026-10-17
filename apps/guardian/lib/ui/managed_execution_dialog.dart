import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/labels.dart';
import '../core/managed_execution.dart';
import 'design.dart';
import 'managed_execution_controller.dart';

/// The host owns the scoped controller and its disposal.
class ManagedExecutionDialog extends StatefulWidget {
  final ManagedExecutionController controller;
  final String deviceName;
  final VoidCallback onClose;
  final Listenable? accessChanges;
  final VoidCallback? onReauth;

  const ManagedExecutionDialog({
    super.key,
    required this.controller,
    required this.deviceName,
    required this.onClose,
    this.accessChanges,
    this.onReauth,
  });

  @override
  State<ManagedExecutionDialog> createState() => _ManagedExecutionDialogState();
}

class _ManagedExecutionDialogState extends State<ManagedExecutionDialog> {
  _ExecutionConfirmationLifetime? confirmationLifetime;
  bool confirming = false;

  ManagedExecutionController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(changed);
    widget.accessChanges?.addListener(scopeChanged);
    unawaited(c.load());
  }

  @override
  void didUpdateWidget(covariant ManagedExecutionDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accessChanges != widget.accessChanges) {
      invalidateConfirmation();
      oldWidget.accessChanges?.removeListener(scopeChanged);
      widget.accessChanges?.addListener(scopeChanged);
    }
    if (oldWidget.controller != c) {
      invalidateConfirmation();
      oldWidget.controller.removeListener(changed);
      c.addListener(changed);
      unawaited(c.load());
    }
  }

  void changed() {
    final lifetime = confirmationLifetime;
    if (lifetime != null && !confirmationCurrent(lifetime)) {
      lifetime.value = false;
    }
    if (mounted) setState(() {});
  }

  void scopeChanged() {
    invalidateConfirmation();
    c.checkScope();
  }

  void invalidateConfirmation() => confirmationLifetime?.value = false;

  @override
  void dispose() {
    invalidateConfirmation();
    c.removeListener(changed);
    widget.accessChanges?.removeListener(scopeChanged);
    super.dispose();
  }

  void close() {
    if (!c.writeBusy) {
      invalidateConfirmation();
      widget.onClose();
    }
  }

  void reauthenticate() {
    if (!mounted || c.busy || !c.hasAccess || !c.needsReauth) return;
    invalidateConfirmation();
    widget.onReauth?.call();
  }

  bool confirmationCurrent(_ExecutionConfirmationLifetime lifetime) {
    if (!lifetime.value ||
        !mounted ||
        !identical(c, lifetime.controller) ||
        !c.hasAccess ||
        c.resultUnknown ||
        c.needsReauth ||
        c.eventsAhead) {
      return false;
    }
    final selected = c.selected;
    // writeBusy covers the confirmation itself, so canCancel cannot be used here.
    return selected != null &&
        selected.id == lifetime.task.id &&
        selected.revision == lifetime.task.revision &&
        selected.registrationId == c.registrationId;
  }

  Future<void> cancel() => c.cancel(confirmCancellation);

  bool preparationStage(ManagedExecution task) =>
      const {'READY_TO_WRITE', 'READY_TO_ASSIGN'}.contains(task.state);

  Future<bool> confirmCancellation(ManagedExecution task) async {
    if (!mounted || !c.hasAccess || confirming) return false;
    final controller = c;
    final lifetime = _ExecutionConfirmationLifetime(controller, task);
    final changes = Listenable.merge([controller, lifetime]);
    confirmationLifetime = lifetime;
    setState(() => confirming = true);
    var finished = false;

    void finish(BuildContext routeContext, bool accepted) {
      if (finished || !routeContext.mounted) return;
      // Retained callbacks must never close a route opened above this prompt.
      if (ModalRoute.of(routeContext)?.isCurrent != true) return;
      if (accepted && !confirmationCurrent(lifetime)) return;
      finished = true;
      Navigator.of(routeContext).pop(accepted);
    }

    try {
      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (inner) => AnimatedBuilder(
          animation: changes,
          builder: (_, __) {
            final current = confirmationCurrent(lifetime);
            return confirmationDialog(
              inner,
              current: current,
              preparation: preparationStage(task),
              onDismiss: () => finish(inner, false),
              onConfirm: () => finish(inner, true),
            );
          },
        ),
      );
      return accepted == true && confirmationCurrent(lifetime);
    } finally {
      finished = true;
      if (identical(confirmationLifetime, lifetime)) {
        confirmationLifetime = null;
      }
      lifetime.dispose();
      if (mounted) setState(() => confirming = false);
    }
  }

  double availableHeight(BuildContext context) =>
      (MediaQuery.sizeOf(context).height -
              MediaQuery.viewInsetsOf(context).bottom -
              48)
          .clamp(120.0, double.infinity)
          .toDouble();

  Widget confirmationDialog(
    BuildContext routeContext, {
    required bool current,
    required bool preparation,
    required VoidCallback onDismiss,
    required VoidCallback onConfirm,
  }) =>
      Dialog(
        key: const Key('execution-cancel-dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            maxHeight: availableHeight(routeContext),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        current
                            ? preparation
                                ? '取消后续执行'
                                : '登记取消并复核'
                            : '操作上下文已变化',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(routeContext).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭取消确认',
                      onPressed: onDismiss,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (current) ...[
                          Text(
                            widget.deviceName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(routeContext).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          Notice(
                            preparation
                                ? '将按本次读取的版本请求取消后续执行。已经发起的策略操作可能仍需核对，'
                                    '取消不代表设备已撤回规则。'
                                : '此记录已有执行进展。将登记取消请求，并继续核对已经发起的策略操作；'
                                    '结果可能仍需复核，不能证明设备已恢复原规则。',
                            warning: true,
                          ),
                          const SizedBox(height: 12),
                          const Text('若结果需要复核，请继续查看设备反馈与事件时间线。'),
                        ] else
                          const Notice(
                            '原执行记录已隐藏。请返回并在当前工作空间重新核对；此次确认已失效。',
                            warning: true,
                          ),
                        const SizedBox(height: 20),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            TextButton(
                              key: const Key('execution-dismiss-cancel'),
                              onPressed: onDismiss,
                              child: Text(current ? '继续查看' : '返回执行记录'),
                            ),
                            if (current)
                              FilledButton(
                                key: const Key('execution-confirm-cancel'),
                                onPressed: onConfirm,
                                child: Text(preparation ? '确认取消' : '确认登记取消'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget stateLabel(String state, String label) {
    final color = state == 'APPLIED'
        ? const Color(0xFF00886C)
        : const {
            'POLICY_WRITE_UNKNOWN',
            'ASSIGNMENT_UNKNOWN',
            'NEEDS_REVIEW',
          }.contains(state)
            ? const Color(0xFF916018)
            : state == 'CANCELLED'
                ? muted
                : navy;
    final icon = switch (state) {
      'APPLIED' => Icons.check_circle_outline,
      'CANCELLED' => Icons.cancel_outlined,
      'POLICY_WRITE_UNKNOWN' ||
      'ASSIGNMENT_UNKNOWN' ||
      'NEEDS_REVIEW' =>
        Icons.fact_check_outlined,
      'WAITING_DEVICE' => Icons.tablet_android_outlined,
      _ => Icons.schedule_outlined,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withOpacity(.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget readOnlyNotice() => const Notice('当前为只读访问，可查看执行状态与时间线。');

  Widget notices() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (c.resultUnknown) ...[
            const Notice(
              '尚不能确认取消结果。请读取核对；仍显示等待处理不能证明取消失败。',
              key: Key('execution-result-unknown'),
              warning: true,
            ),
            const SizedBox(height: 12),
          ],
          if (c.needsReauth) ...[
            const Notice('此次操作需要重新安全验证。完成验证后，请重新读取并再次确认取消。', warning: true),
            if (widget.onReauth != null)
              TextButton.icon(
                key: const Key('execution-reauth'),
                onPressed: c.busy ? null : reauthenticate,
                icon: const Icon(Icons.verified_user_outlined, size: 18),
                label: const Text('重新安全验证'),
              ),
            const SizedBox(height: 12),
          ],
          if (c.notice != null && !c.resultUnknown && !c.needsReauth) ...[
            Notice(c.notice!, warning: true),
            const SizedBox(height: 12),
          ],
        ],
      );

  Widget list() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          notices(),
          const Notice('执行状态以服务端读取结果为准。“设备已应用”表示已收到设备应用反馈。'),
          const SizedBox(height: 16),
          if (!c.repository.writable) ...[
            readOnlyNotice(),
            const SizedBox(height: 16),
          ],
          DropdownButtonFormField<String>(
            key: const Key('execution-filter'),
            value: c.filter ?? '',
            isExpanded: true,
            isDense: false,
            itemHeight: null,
            decoration: const InputDecoration(labelText: '执行状态'),
            items: [
              const DropdownMenuItem<String>(
                value: '',
                child: Text('全部状态'),
              ),
              for (final entry in ManagedExecution.stateLabels.entries)
                DropdownMenuItem<String>(
                  value: entry.key,
                  child: Text(entry.value),
                ),
            ],
            onChanged:
                c.busy ? null : (state) => unawaited(c.load(state: state)),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              TextButton.icon(
                key: const Key('execution-refresh-list'),
                onPressed:
                    c.busy ? null : () => unawaited(c.load(state: c.filter)),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(c.listError == null ? '刷新记录' : '重试读取'),
              ),
            ],
          ),
          if (c.listError != null) ...[
            const SizedBox(height: 8),
            Notice(
              c.items.isEmpty
                  ? '执行记录暂未读取成功，请重试读取。'
                  : '部分记录尚未更新，下面保留已读取的记录。请重试读取。',
              warning: true,
            ),
          ],
          const SizedBox(height: 12),
          if (c.items.isEmpty && !c.listBusy && c.listError == null)
            const Notice('暂无执行记录。可刷新记录，或选择其他执行状态查看。'),
          for (final task in c.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: recordCard(task),
            ),
          if (c.cursor != null)
            OutlinedButton.icon(
              key: const Key('execution-more'),
              onPressed: c.busy ? null : () => unawaited(c.loadMore()),
              icon: const Icon(Icons.expand_more, size: 18),
              label: const Text('加载更多记录'),
            ),
        ],
      );

  Widget recordCard(ManagedExecution task) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            stateLabel(task.state, task.stateLabel),
            const SizedBox(height: 12),
            Text(task.reasonLabel),
            const SizedBox(height: 8),
            Text('创建：${dateLabel(task.createdAt)}',
                style: Theme.of(context).textTheme.bodySmall),
            Text('更新：${dateLabel(task.updatedAt)}',
                style: Theme.of(context).textTheme.bodySmall),
            if (task.registrationId != c.registrationId) ...[
              const SizedBox(height: 8),
              const Text('历史注册记录', style: TextStyle(color: muted)),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: Key('execution-open-${task.id}'),
              onPressed: c.busy ? null : () => unawaited(c.open(task)),
              icon: const Icon(Icons.article_outlined, size: 18),
              label: const Text('查看进展'),
            ),
          ],
        ),
      );

  Widget detail(ManagedExecution task) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              TextButton.icon(
                key: const Key('execution-back'),
                onPressed: c.writeBusy ? null : () => c.back(),
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('返回记录'),
              ),
              if (c.resultUnknown)
                OutlinedButton.icon(
                  key: const Key('execution-check-result'),
                  onPressed: c.busy ? null : () => unawaited(c.refreshDetail()),
                  icon: const Icon(Icons.fact_check_outlined, size: 18),
                  label: const Text('核对结果'),
                )
              else
                TextButton.icon(
                  key: const Key('execution-refresh-detail'),
                  onPressed: c.busy ? null : () => unawaited(c.refreshDetail()),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('刷新详情'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          notices(),
          if (c.historical) ...[
            const Notice('历史注册记录：此记录属于设备的旧注册，可查看进展与时间线。'),
            const SizedBox(height: 12),
          ] else if (!c.repository.writable) ...[
            readOnlyNotice(),
            const SizedBox(height: 12),
          ],
          if (c.detailError != null && !c.needsReauth && !c.resultUnknown) ...[
            const Notice('详情尚未更新，下面保留最近读取的资料。请刷新详情后核对。', warning: true),
            const SizedBox(height: 12),
          ],
          stateLabel(task.state, task.stateLabel),
          const SizedBox(height: 12),
          Text(task.reasonLabel),
          if (task.cancellationRequested) ...[
            const SizedBox(height: 10),
            Notice(
              task.state == 'CANCELLED' ? '已在策略分配前取消后续执行。' : '已登记取消，设备结果仍需复核。',
              warning: task.state != 'CANCELLED',
            ),
          ],
          const SizedBox(height: 12),
          Text('创建时间：${dateLabel(task.createdAt)}'),
          const SizedBox(height: 4),
          Text('状态更新时间：${dateLabel(task.updatedAt)}'),
          const SizedBox(height: 4),
          Text('记录版本：${task.revision}',
              style: Theme.of(context).textTheme.bodySmall),
          if (c.eventsAhead) ...[
            const SizedBox(height: 16),
            const Notice('时间线已有较新的进展。请刷新详情后核对当前状态，再决定后续操作。', warning: true),
          ],
          if (c.canCancel) ...[
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  key: const Key('execution-cancel'),
                  onPressed: cancel,
                  icon: const Icon(Icons.cancel_outlined, size: 18),
                  label: Text(preparationStage(task) ? '取消后续执行' : '登记取消并复核'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Text('事件时间线', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text('按事件版本依次展示已读取的进展。', style: TextStyle(color: muted)),
          const SizedBox(height: 12),
          if (c.eventError != null) ...[
            const Notice('部分事件暂未读取成功。可刷新详情，重新核对时间线。', warning: true),
            const SizedBox(height: 12),
          ],
          if (c.events.isEmpty && !c.eventsBusy && c.eventError == null)
            const Notice('尚无可显示的执行事件。'),
          for (final event in c.events)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: eventCard(event),
            ),
          if (c.eventCursor != null)
            OutlinedButton.icon(
              key: const Key('execution-more-events'),
              onPressed: c.busy ? null : () => unawaited(c.loadMoreEvents()),
              icon: const Icon(Icons.expand_more, size: 18),
              label: const Text('加载更多事件'),
            ),
          const SizedBox(height: 16),
          ExpansionTile(
            key: const Key('execution-identifiers'),
            tilePadding: EdgeInsets.zero,
            title: const Text('编号与注册信息'),
            childrenPadding: const EdgeInsets.only(bottom: 12),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText('执行编号：${task.id}'),
                    const SizedBox(height: 8),
                    SelectableText('发布编号：${task.publicationId}'),
                    const SizedBox(height: 8),
                    SelectableText('设备编号：${task.deviceId}'),
                    const SizedBox(height: 8),
                    SelectableText('注册编号：${task.registrationId}'),
                  ],
                ),
              ),
            ],
          ),
        ],
      );

  Widget eventCard(ManagedExecutionEvent event) => Container(
        key: Key('execution-event-${event.revision}'),
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: canvas,
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('版本 ${event.revision} · ${dateLabel(event.occurredAt)}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            stateLabel(event.state, event.stateLabel),
            const SizedBox(height: 10),
            Text(event.reasonLabel),
          ],
        ),
      );

  Widget contents() {
    if (!c.hasAccess) {
      return const Notice('工作空间或访问权限已变化，原执行记录已隐藏。请关闭窗口，在当前工作空间重新打开。',
          key: Key('execution-scope-unavailable'), warning: true);
    }
    final selected = c.selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.deviceName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            semanticsLabel: widget.deviceName,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 16),
        if (selected == null) list() else detail(selected),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !c.writeBusy,
        child: Dialog(
          key: const Key('execution-dialog'),
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 760,
              maxHeight: availableHeight(context),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text('执行记录',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge),
                      ),
                      IconButton(
                        key: const Key('execution-close'),
                        tooltip: '关闭执行记录',
                        onPressed: c.writeBusy ? null : close,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (c.busy && !confirming) ...[
                    const LinearProgressIndicator(minHeight: 2),
                    const SizedBox(height: 12),
                  ],
                  Flexible(
                    child: SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      child: contents(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

/// Changing the value revokes retained callbacks synchronously. If the parent
/// is rebuilding or disposing, notify the confirmation route after that frame.
class _ExecutionConfirmationLifetime extends ValueNotifier<bool> {
  final ManagedExecutionController controller;
  final ManagedExecution task;
  bool notificationScheduled = false, disposed = false;

  _ExecutionConfirmationLifetime(this.controller, this.task) : super(true);

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
