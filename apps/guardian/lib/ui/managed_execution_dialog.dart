import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/labels.dart';
import '../core/managed_execution.dart';
import 'design.dart';
import 'managed_execution_controller.dart';
import 'managed_execution_review_controller.dart';
import 'owned_dialog_route.dart';

typedef ManagedExecutionReviewFactory
    = ManagedExecutionReviewController Function(ManagedExecution task,
        bool Function() viewCurrent, int Function() latestEventRevision);

/// The list controller supplies reads only. Every mutation belongs to the
/// durable operation coordinator; there is no fallback to the old cancel API.
class ManagedExecutionDialog extends StatefulWidget {
  final ManagedExecutionController controller;
  final ManagedExecutionReviewFactory? reviewFactory;
  final String deviceName;
  final VoidCallback onClose;
  final VoidCallback onReauth;
  final Listenable? accessChanges;

  const ManagedExecutionDialog(
      {super.key,
      required this.controller,
      required this.reviewFactory,
      required this.deviceName,
      required this.onClose,
      required this.onReauth,
      this.accessChanges});

  @override
  State<ManagedExecutionDialog> createState() => _ManagedExecutionDialogState();
}

class _ManagedExecutionDialogState extends State<ManagedExecutionDialog> {
  ManagedExecutionController get c => widget.controller;
  ManagedExecutionReviewController? review;
  OwnedDialogRoute<bool>? confirmation;
  _ConfirmationVisibility? confirmationVisibility;
  final observedEventRevisions = <String, int>{};
  bool confirmationLive = false, closing = false, frameScheduled = false;
  bool _initialLoadStarted = false;
  bool _elementActive = false, _disposing = false;
  ModalRoute<dynamic>? _route;
  int generation = 0;

  bool get canUpdate => mounted && _elementActive && !_disposing;
  bool get routeActive =>
      canUpdate && !closing && (_route?.isActive ?? true);
  bool get routeCurrent => routeActive && (_route?.isCurrent ?? true);
  bool get privateVisible =>
      routeActive &&
      c.hasAccess &&
      !c.needsReauth &&
      (review == null || (review!.hasAccess && !review!.needsReauth));

  VoidCallback guarded(VoidCallback action,
      {ManagedExecutionReviewController? operation,
      bool privateRequired = true}) {
    final epoch = generation, source = c;
    return () {
      if (epoch != generation ||
          !identical(c, source) ||
          !routeCurrent ||
          (privateRequired && !privateVisible) ||
          (operation != null && !identical(review, operation))) return;
      action();
    };
  }

  double availableHeight(BuildContext value) {
    final media = MediaQuery.of(value);
    return (media.size.height - media.viewInsets.vertical - 48)
        .clamp(120.0, double.infinity)
        .toDouble();
  }

  @override
  void initState() {
    super.initState();
    c.addListener(changed);
    widget.accessChanges?.addListener(scopeChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Only this active lifecycle hook may establish inherited route access.
    _route = ModalRoute.of(context);
    _elementActive = true;
    if (_initialLoadStarted) return;
    _initialLoadStarted = true;
    // load() notifies synchronously, after route dependencies become available.
    unawaited(c.load());
  }

  @override
  void didUpdateWidget(covariant ManagedExecutionDialog old) {
    super.didUpdateWidget(old);
    if (old.controller != c || old.reviewFactory != widget.reviewFactory) {
      retireReview();
      observedEventRevisions.clear();
      old.controller.removeListener(changed);
      c.addListener(changed);
      unawaited(c.load());
    }
    if (old.accessChanges != widget.accessChanges) {
      old.accessChanges?.removeListener(scopeChanged);
      widget.accessChanges?.addListener(scopeChanged);
    }
  }

  void rebuild() {
    if (!canUpdate) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (frameScheduled) return;
      frameScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        frameScheduled = false;
        if (canUpdate) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void changed() {
    if (!canUpdate) return;
    final task = c.selected;
    if (task != null && c.hasAccess && !c.needsReauth) {
      var highest = observedEventRevisions[task.id] ?? 0;
      for (final event in c.events) {
        if (event.revision > highest) highest = event.revision;
      }
      observedEventRevisions[task.id] = highest;
    }
    if (!c.hasAccess || c.needsReauth) review?.detach();
    if (!privateVisible || review?.confirming != true) revokeConfirmation();
    rebuild();
  }

  void scopeChanged() {
    if (_disposing) return;
    c.checkScope();
    review?.checkScope();
    if (!privateVisible) revokeConfirmation();
    rebuild();
  }

  void revokeConfirmation() {
    confirmationLive = false; // Retained accept callbacks lose authority now.
    confirmationVisibility?.revoke(); // The next safe build must hide the body.
    final owned = confirmation;
    if (owned == null || !owned.available) return;
    void afterHiddenFrame(Duration _) {
      if (owned.available) owned.finish(false);
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      // Visibility notification itself is deferred past the active build.
      // Allow that following frame to paint the redacted body before closing.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback(afterHiddenFrame);
        WidgetsBinding.instance.scheduleFrame();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback(afterHiddenFrame);
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  void retireReview() {
    generation++;
    revokeConfirmation();
    final old = review;
    review = null;
    old?.removeListener(changed);
    old?.detach();
    old?.dispose();
  }

  void retire() {
    if (closing) return;
    closing = true;
    retireReview();
  }

  @override
  void deactivate() {
    // mounted remains true until dispose finishes; callbacks lose authority now.
    _elementActive = false;
    generation++;
    revokeConfirmation();
    review?.detach();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _elementActive = true;
    // The framework refreshes our inherited route dependency before rebuilding.
    // A detached review and a revoked confirmation are never restored here.
  }

  @override
  void dispose() {
    _disposing = true;
    _elementActive = false;
    retire();
    c.removeListener(changed);
    widget.accessChanges?.removeListener(scopeChanged);
    super.dispose();
  }

  void close() {
    if (!routeCurrent) return;
    retire();
    widget.onClose(); // Closing is safe while a durable request is in flight.
  }

  void reauthenticate() {
    if (!routeCurrent || !(review?.needsReauth == true || c.needsReauth)) {
      return;
    }
    // The host verifies the real controller's step-up signal before detach.
    // It owns route completion and is the only caller of Session.login.
    widget.onReauth();
  }

  Future<void> open(ManagedExecution task) async {
    if (!routeCurrent || c.busy || !privateVisible) return;
    retireReview();
    c.back(); // Local selection reset also fences a late old timeline callback.
    final epoch = generation;
    final factory = widget.reviewFactory;
    if (factory != null && task.registrationId == c.registrationId) {
      // The list row is the captured original. Restore the durable slot before
      // any detail, eligibility or event request for this writable task.
      await attachReview(task, factory, epoch);
      return;
    }
    await c.open(task);
  }

  Future<void> attachReview(ManagedExecution selected,
      ManagedExecutionReviewFactory factory, int epoch) async {
    late final ManagedExecutionReviewController owned;
    owned = factory(
        selected,
        () =>
            routeActive &&
            epoch == generation &&
            identical(review, owned) &&
            c.hasAccess,
        () => observedEventRevisions[selected.id] ?? 0);
    review = owned;
    owned.addListener(changed);
    rebuild();
    await owned.initialize();
    if (!routeActive ||
        epoch != generation ||
        !identical(review, owned) ||
        !owned.hasAccess ||
        !owned.initialized ||
        owned.storageBlocked ||
        owned.pending != null) return;
    // Only a clean local slot permits this explicit opening read. UNKNOWN and
    // uncertain storage stop above, with no network request of any kind.
    await owned.refresh();
  }

  Future<void> refreshTimeline() async {
    if (!routeCurrent || !privateVisible || c.busy || review?.busy == true) {
      return;
    }
    if (c.selected != null) {
      await c.refreshDetail();
      return;
    }
    final task = review?.selected;
    if (task == null) return;
    // Keep the read controller's real list-membership check. Its detail GET is
    // user initiated here, followed by events; it never settles our journal.
    for (final row in c.items) {
      if (row.id == task.id &&
          row.publicationId == task.publicationId &&
          row.registrationId == task.registrationId) {
        await c.open(row);
        return;
      }
    }
  }

  void back() {
    if (!routeCurrent || !privateVisible) return;
    retireReview();
    c.back();
    rebuild();
  }

  Future<void> refresh() async {
    if (!routeCurrent || !privateVisible) return;
    final owned = review;
    if (owned == null) {
      await c.refreshDetail();
      return;
    }
    if (!owned.hasAccess || owned.busy) return;
    if (owned.resultUnknown) {
      await owned.query();
      return;
    }
    await owned.refresh();
  }

  Future<bool> confirm(ManagedExecution task, bool recheck,
      ManagedExecutionReviewController owned) async {
    if (!routeCurrent ||
        !identical(review, owned) ||
        !privateVisible ||
        !owned.confirming ||
        confirmation != null) return false;
    final epoch = generation;
    var accepted = false;
    confirmationLive = true;
    final visibility = _ConfirmationVisibility();
    confirmationVisibility = visibility;
    late final OwnedDialogRoute<bool> route;
    bool valid() =>
        mounted &&
        !closing &&
        confirmationLive &&
        epoch == generation &&
        identical(review, owned) &&
        privateVisible &&
        owned.confirming &&
        owned.selected?.id == task.id &&
        owned.selected?.revision == task.revision &&
        route.available &&
        route.isCurrent;
    route = OwnedDialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (inner) => ValueListenableBuilder<bool>(
            valueListenable: visibility,
            builder: (inner, visible, _) => !visible || !privateVisible
                ? const Dialog(
                    key: Key('execution-confirmation-revoked'),
                    child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Notice('原执行记录已隐藏，此次确认已失效。请在当前工作空间重新核对。',
                            warning: true)))
                : Dialog(
                    insetPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          maxWidth: 520, maxHeight: availableHeight(inner)),
                      child: Padding(
                          padding: const EdgeInsets.all(20),
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                      child: Text(
                                          recheck ? '重新核实设备状态？' : '取消后续执行？',
                                          style: Theme.of(inner)
                                              .textTheme
                                              .titleLarge)),
                                  IconButton(
                                      tooltip: recheck ? '关闭复核确认' : '关闭取消确认',
                                      onPressed: () {
                                        if (valid() && !accepted) {
                                          confirmationLive = false;
                                          route.finish(false);
                                        }
                                      },
                                      icon: const Icon(Icons.close)),
                                ]),
                            const SizedBox(height: 12),
                            Flexible(
                                child: SingleChildScrollView(
                                    child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(widget.deviceName),
                                const SizedBox(height: 16),
                                Text(recheck
                                    ? '系统将重新读取设备反馈。申请受理后仍需等待设备，不会重新写入或分配策略。'
                                    : '系统会登记取消后续执行。已送达设备的策略可能仍然生效，取消不能证明设备已恢复。'),
                                const SizedBox(height: 20),
                                Wrap(spacing: 12, runSpacing: 12, children: [
                                  OutlinedButton(
                                      key: Key(recheck
                                          ? 'execution-dismiss-recheck'
                                          : 'execution-dismiss-cancel'),
                                      onPressed: () {
                                        if (valid() && !accepted) {
                                          confirmationLive = false;
                                          route.finish(false);
                                        }
                                      },
                                      child: const Text('暂不操作')),
                                  FilledButton(
                                      key: Key(recheck
                                          ? 'execution-confirm-recheck'
                                          : 'execution-confirm-cancel'),
                                      onPressed: () {
                                        if (!valid() || accepted) return;
                                        accepted =
                                            true; // Synchronous guard, even before rebuild.
                                        confirmationLive = false;
                                        route.finish(true);
                                      },
                                      child: Text(recheck ? '确认重新核实' : '确认取消')),
                                ]),
                              ],
                            ))),
                          ])),
                    ),
                  )));
    confirmation = route;
    try {
      final result = await presentOwnedDialog(context, route);
      return result == true &&
          accepted &&
          mounted &&
          !closing &&
          epoch == generation &&
          identical(review, owned) &&
          owned.hasAccess &&
          owned.confirming &&
          privateVisible;
    } finally {
      if (identical(confirmation, route)) confirmation = null;
      if (identical(confirmationVisibility, visibility)) {
        confirmationVisibility = null;
      }
      visibility.dispose();
      confirmationLive = false;
    }
  }

  void mutate(bool recheck) {
    final owned = review;
    if (!routeCurrent ||
        owned == null ||
        !privateVisible ||
        !(recheck ? owned.canRecheck : owned.canCancel)) return;
    if (recheck) {
      unawaited(owned.requestRecheck((task) => confirm(task, true, owned)));
    } else {
      unawaited(owned.cancel((task) => confirm(task, false, owned)));
    }
  }

  Widget stateLabel(String state, String text) {
    final warning = const {
      'NEEDS_REVIEW',
      'POLICY_WRITE_UNKNOWN',
      'ASSIGNMENT_UNKNOWN'
    }.contains(state);
    final color = state == 'APPLIED'
        ? const Color(0xFF23765A)
        : warning
            ? const Color(0xFF946000)
            : state == 'CANCELLED'
                ? muted
                : navy;
    return Semantics(
        liveRegion: true,
        child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: color.withOpacity(.08),
                borderRadius: BorderRadius.circular(10)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(
                  state == 'APPLIED'
                      ? Icons.check_circle_outline
                      : warning
                          ? Icons.fact_check_outlined
                          : Icons.schedule,
                  color: color,
                  size: 22),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(text,
                      style: TextStyle(
                          color: color, fontWeight: FontWeight.w700))),
            ])));
  }

  Widget list() {
    final epoch = generation;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('查看策略执行进展，需要时再核实设备状态。'),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
          key: const Key('execution-filter'),
          value: c.filter,
          isExpanded: true,
          isDense: false,
          itemHeight: null,
          decoration: const InputDecoration(labelText: '执行状态'),
          items: [
            const DropdownMenuItem<String>(value: null, child: Text('全部状态')),
            for (final entry in ManagedExecution.stateLabels.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value))
          ],
          onChanged: c.busy
              ? null
              : (value) {
                  if (epoch == generation && routeCurrent && privateVisible) {
                    unawaited(c.load(state: value));
                  }
                }),
      const SizedBox(height: 12),
      OutlinedButton.icon(
          key: const Key('execution-refresh-list'),
          onPressed:
              c.busy ? null : guarded(() => unawaited(c.load(state: c.filter))),
          icon: const Icon(Icons.refresh),
          label: Text(c.listError == null ? '刷新记录' : '重新读取记录')),
      if (!c.repository.writable) ...[
        const SizedBox(height: 12),
        const Notice('当前为只读访问，可查看执行进展与时间线。')
      ],
      if (c.listError != null) ...[
        const SizedBox(height: 12),
        const Notice('记录暂未读取成功，请重新读取。', warning: true)
      ],
      if (c.items.isEmpty && !c.listBusy && c.listError == null) ...[
        const SizedBox(height: 12),
        const Notice('暂无执行记录。发布策略后可在这里查看执行进展。')
      ],
      for (final task in c.items)
        Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    border: Border.all(color: line),
                    borderRadius: BorderRadius.circular(10)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      stateLabel(task.state, task.stateLabel),
                      const SizedBox(height: 12),
                      Text(task.reasonLabel),
                      const SizedBox(height: 8),
                      Text('更新：${dateLabel(task.updatedAt)}'),
                      if (task.registrationId != c.registrationId)
                        const Text('历史注册记录', style: TextStyle(color: muted)),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                          key: Key('execution-open-${task.id}'),
                          onPressed: c.busy
                              ? null
                              : guarded(() => unawaited(open(task))),
                          icon: const Icon(Icons.article_outlined),
                          label: const Text('查看进展')),
                    ]))),
      if (c.cursor != null) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(
            key: const Key('execution-more'),
            onPressed: c.busy ? null : guarded(() => unawaited(c.loadMore())),
            icon: const Icon(Icons.expand_more),
            label: const Text('加载更多记录'))
      ],
    ]);
  }

  String nextStep(ManagedExecution task) {
    if (review?.resultUnknown == true) {
      return '请查询任务进展，确认前不要重复提交。也可关闭窗口，稍后继续核对。';
    }
    if (task.registrationId != c.registrationId) {
      return '查看此历史注册的进展。当前设备的操作请从当前注册记录进入。';
    }
    if (widget.reviewFactory == null) return '可查看任务进展与时间线。如需处理，请联系机构管理员。';
    if (review == null) return '先核对最新详情，再决定下一步操作。';
    return switch (task.state) {
      'APPLIED' => '设备已反馈应用成功。可在时间线查看核实过程。',
      'CANCELLED' => '已在策略分配前取消后续执行。',
      'NEEDS_REVIEW' => task.cancellationRequested
          ? '已登记取消。请人工核对设备当前状态。'
          : '先查看原因，再选择重新核实或人工核对设备。',
      'WAITING_DEVICE' => '仍在等待设备反馈。可稍后主动查询进展。',
      _ => '任务正在处理中。可主动刷新，查看最新进展。',
    };
  }

  Widget actions(ManagedExecution task) {
    final owned = review;
    if (task.registrationId != c.registrationId) {
      return const Notice('历史注册记录：可查看进展与时间线。当前注册的操作请从当前记录进入。');
    }
    if (owned == null) {
      if (widget.reviewFactory == null) {
        return const Notice('当前为只读访问，可查看执行进展与时间线。');
      }
      return const Notice('正在准备操作记录，请稍候。');
    }
    if (owned.storageBlocked) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Notice('本地操作记录尚未确认。为避免重复操作，请先重新读取记录。', warning: true),
        const SizedBox(height: 12),
        OutlinedButton(
            key: const Key('execution-restore-operation'),
            onPressed: owned.busy
                ? null
                : guarded(() => unawaited(owned.restore()), operation: owned),
            child: const Text('重新读取本地记录')),
      ]);
    }
    if (owned.resultUnknown) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Notice('暂不能确认是否已受理。操作记录已保留，请查询任务进展；无需再次提交。', warning: true),
        const SizedBox(height: 12),
        OutlinedButton.icon(
            key: const Key('execution-check-result'),
            onPressed: owned.canQuery
                ? guarded(() => unawaited(owned.query()), operation: owned)
                : null,
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('查询进展')),
      ]);
    }
    final eligibility = owned.eligibility;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (owned.notice != null) ...[
        Semantics(liveRegion: true, child: Notice(owned.notice!)),
        const SizedBox(height: 12)
      ],
      if (owned.rejectedNotApplied) ...[
        const Notice('本次操作未被受理。请刷新状态，再决定下一步。', warning: true),
        const SizedBox(height: 12)
      ],
      if (eligibility != null &&
          !eligibility.allowed &&
          task.state == 'NEEDS_REVIEW') ...[
        Notice(eligibility.reasonLabel,
            key: const Key('execution-review-denied')),
        const SizedBox(height: 12)
      ],
      if (owned.error != null) ...[
        const Notice('最新详情尚未核对完成，请重新核对后继续。', warning: true),
        const SizedBox(height: 12)
      ],
      Wrap(spacing: 12, runSpacing: 12, children: [
        if (owned.canRecheck)
          FilledButton.icon(
              key: const Key('execution-recheck'),
              onPressed: guarded(() => mutate(true), operation: owned),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('重新核实设备状态')),
        OutlinedButton.icon(
            key: const Key('execution-refresh-detail'),
            onPressed: owned.busy
                ? null
                : guarded(() => unawaited(refresh()), operation: owned),
            icon: const Icon(Icons.refresh),
            label: Text(owned.error == null ? '刷新状态' : '重新核对详情')),
        if (owned.canCancel)
          TextButton.icon(
              key: const Key('execution-cancel'),
              onPressed: guarded(() => mutate(false), operation: owned),
              icon: const Icon(Icons.cancel_outlined),
              label: const Text('取消后续执行')),
      ]),
      if (owned.busy) ...[
        const SizedBox(height: 12),
        const Text('正在核对，可关闭窗口，操作记录会保留。', style: TextStyle(color: muted))
      ],
    ]);
  }

  Widget detail(ManagedExecution task) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextButton.icon(
            key: const Key('execution-back'),
            onPressed: guarded(back),
            icon: const Icon(Icons.arrow_back),
            label: const Text('返回记录')),
        const SizedBox(height: 12),
        stateLabel(task.state, task.stateLabel),
        const SizedBox(height: 16),
        Text('当前原因', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(task.reasonLabel),
        const SizedBox(height: 20),
        Text('下一步', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(nextStep(task)),
        const SizedBox(height: 12),
        actions(task),
        if (c.eventsAhead ||
            (observedEventRevisions[task.id] ?? 0) > task.revision) ...[
          const SizedBox(height: 12),
          const Notice('时间线已有更新。请刷新状态后核对，再决定后续操作。', warning: true)
        ],
        const SizedBox(height: 24),
        Text('事件时间线', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('展示已读取的进展。新的状态不代表由本次操作引起。', style: TextStyle(color: muted)),
        const SizedBox(height: 8),
        OutlinedButton.icon(
            key: const Key('execution-refresh-timeline'),
            onPressed: c.busy || review?.busy == true
                ? null
                : guarded(() => unawaited(refreshTimeline())),
            icon: const Icon(Icons.refresh),
            label: const Text('刷新时间线')),
        if (c.eventError != null) ...[
          const SizedBox(height: 12),
          const Notice('部分事件暂未读取成功，请刷新时间线。', warning: true)
        ],
        if (c.events.isEmpty && !c.eventsBusy && c.eventError == null) ...[
          const SizedBox(height: 12),
          const Notice('尚无可显示的执行事件。')
        ],
        for (final event in c.events)
          Container(
              key: Key('execution-event-${event.revision}'),
              width: double.infinity,
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: canvas,
                  border: Border.all(color: line),
                  borderRadius: BorderRadius.circular(10)),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '版本 ${event.revision} · ${dateLabel(event.occurredAt)}',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 8),
                    Text(event.stateLabel,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text(event.reasonLabel),
                  ])),
        if (c.eventCursor != null) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
              key: const Key('execution-more-events'),
              onPressed:
                  c.busy ? null : guarded(() => unawaited(c.loadMoreEvents())),
              icon: const Icon(Icons.expand_more),
              label: const Text('加载更多事件'))
        ],
        const SizedBox(height: 16),
        ExpansionTile(
            key: const Key('execution-identifiers'),
            tilePadding: EdgeInsets.zero,
            title: const Text('时间、编号与注册信息'),
            childrenPadding: const EdgeInsets.only(bottom: 12),
            children: [
              Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('创建时间：${dateLabel(task.createdAt)}'),
                        Text('状态更新时间：${dateLabel(task.updatedAt)}'),
                        Text('记录版本：${task.revision}'),
                        const SizedBox(height: 12),
                        SelectableText('执行编号：${task.id}'),
                        SelectableText('发布编号：${task.publicationId}'),
                        SelectableText('设备编号：${task.deviceId}'),
                        SelectableText('注册编号：${task.registrationId}'),
                      ]))
            ]),
      ]);

  Widget contents() {
    if (review?.needsReauth == true || c.needsReauth) {
      return Column(
          key: const Key('execution-auth-required'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Notice('请重新认证后查看任务与继续操作。原记录已隐藏，未确认的操作会保留。', warning: true),
            const SizedBox(height: 12),
            FilledButton.icon(
                key: const Key('execution-reauth'),
                onPressed: routeCurrent
                    ? guarded(reauthenticate,
                        operation: review, privateRequired: false)
                    : null,
                icon: const Icon(Icons.verified_user_outlined),
                label: const Text('重新认证'))
          ]);
    }
    if (!privateVisible) {
      return const Notice('工作空间或访问权限已变化，原执行记录已隐藏。请关闭窗口，在当前工作空间重新打开。',
          key: Key('execution-scope-unavailable'), warning: true);
    }
    final selected = review?.selected ?? c.selected;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.deviceName, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 16),
      if (selected == null) list() else detail(selected),
    ]);
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: true,
      onPopInvoked: (didPop) {
        if (didPop) retire();
      },
      child: Dialog(
        key: const Key('execution-dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: 760, maxHeight: availableHeight(context)),
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
                                  style:
                                      Theme.of(context).textTheme.titleLarge)),
                          IconButton(
                              key: const Key('execution-close'),
                              tooltip: '关闭执行记录',
                              onPressed: guarded(close, privateRequired: false),
                              icon: const Icon(Icons.close)),
                        ]),
                    if ((c.busy || review?.busy == true) &&
                        confirmation == null) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(minHeight: 2)
                    ],
                    const SizedBox(height: 16),
                    Flexible(
                        child: SingleChildScrollView(
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            child: contents())),
                  ])),
        ),
      ));
}

/// The value is revoked synchronously and can never be restored. Notification
/// waits until a safe phase when revocation occurs during build/dispose.
class _ConfirmationVisibility extends ValueNotifier<bool> {
  bool _revoked = false, _scheduled = false, _disposed = false;
  _ConfirmationVisibility() : super(true);
  void revoke() {
    if (_revoked || _disposed) return;
    _revoked = true;
    value = false;
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (!_scheduled) {
        _scheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scheduled = false;
          if (!_disposed) super.notifyListeners();
        });
      }
      return;
    }
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
