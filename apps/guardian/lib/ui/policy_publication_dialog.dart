import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/api.dart';
import '../core/labels.dart';
import '../core/policy_publication.dart';
import 'design.dart';
import 'policy_preview_results.dart';
import 'policy_publication_controller.dart';

/// Preview, explicit confirmation and recovery share the host's owned route.
/// The host retains the controller, scope and authentication handoff.
class PolicyPublicationDialog extends StatefulWidget {
  final PolicyPublicationController controller;
  final Json? preview;
  final Map<String, String> names;
  final String? selectionSummary;
  final VoidCallback onClose;
  final VoidCallback reauthenticate;
  final VoidCallback? onRepreview;

  const PolicyPublicationDialog({
    super.key,
    required this.controller,
    this.preview,
    this.names = const {},
    this.selectionSummary,
    required this.onClose,
    required this.reauthenticate,
    this.onRepreview,
  });

  @override
  State<PolicyPublicationDialog> createState() =>
      _PolicyPublicationDialogState();
}

class _PolicyPublicationDialogState extends State<PolicyPublicationDialog> {
  final scroll = ScrollController();
  bool closing = false, localBusy = false, frameRefreshScheduled = false;
  int generation = 0;
  PolicyPublicationController get c => widget.controller;

  bool get ownRouteCurrent =>
      mounted &&
      !closing &&
      ModalRoute.of(context)?.isActive == true &&
      ModalRoute.of(context)?.isCurrent == true;
  bool get canAct => ownRouteCurrent && !localBusy && c.hasAccess;

  VoidCallback guarded(VoidCallback action) {
    final owner = c, ticket = generation, epoch = c.actionEpoch;
    return () {
      if (mounted &&
          !closing &&
          generation == ticket &&
          identical(c, owner) &&
          c.actionEpoch == epoch) action();
    };
  }

  @override
  void initState() {
    super.initState();
    c.addListener(changed);
  }

  @override
  void didUpdateWidget(covariant PolicyPublicationDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, c)) {
      generation++;
      frameRefreshScheduled = false;
      oldWidget.controller.removeListener(changed);
      c.addListener(changed);
      closing = false;
      localBusy = false;
    }
  }

  void changed() {
    if (!mounted || closing) return;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (frameRefreshScheduled) return;
      frameRefreshScheduled = true;
      final owner = c, ticket = generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != ticket || !identical(c, owner)) return;
        frameRefreshScheduled = false;
        changed();
      });
      return;
    }
    setState(() {});
  }

  void close() {
    if (!ownRouteCurrent || c.busy || localBusy) return;
    setState(() {
      closing = true;
      generation++;
    });
    widget.onClose();
  }

  void reauthenticate() {
    if (!canAct || c.busy || !c.needsReauth) return;
    setState(() {
      closing = true;
      generation++;
    });
    widget.reauthenticate();
  }

  void primary() {
    if (!canAct || c.busy) return;
    switch (c.phase) {
      case PublicationViewPhase.fresh:
      case PublicationViewPhase.retryableNotSubmitted:
        c.beginConfirmation();
      case PublicationViewPhase.confirming:
        unawaited(c.submit());
      case PublicationViewPhase.unknown:
      case PublicationViewPhase.cleanupPending:
        unawaited(c.check());
      case PublicationViewPhase.reauthenticationRequired:
      case PublicationViewPhase.queryReauthenticationRequired:
        reauthenticate();
      case PublicationViewPhase.storageBlocked:
        unawaited(c.reloadPending());
      case PublicationViewPhase.previewInvalid:
        unawaited(repreview());
      case PublicationViewPhase.submitting:
      case PublicationViewPhase.querying:
      case PublicationViewPhase.recorded:
      case PublicationViewPhase.loadingLocal:
      case PublicationViewPhase.cancelling:
      case PublicationViewPhase.revoked:
        return;
    }
  }

  Future<void> repreview() async {
    if (!canAct || c.busy || !c.canRepreview || widget.onRepreview == null) {
      return;
    }
    final owner = c, ticket = generation;
    setState(() => localBusy = true);
    try {
      if (owner.pending != null && !await owner.cancelNotSubmitted()) return;
      if (!mounted ||
          closing ||
          generation != ticket ||
          !identical(c, owner) ||
          !owner.hasAccess ||
          !ownRouteCurrent) return;
      setState(() {
        closing = true;
        generation++;
      });
      widget.onRepreview!();
    } finally {
      if (mounted && !closing && generation == ticket && identical(c, owner)) {
        setState(() => localBusy = false);
      }
    }
  }

  String get title {
    if (!c.hasAccess) return '工作空间或权限已变化';
    if (c.receipt != null) return '发布结果';
    return switch (c.phase) {
      PublicationViewPhase.confirming => '发布配置',
      PublicationViewPhase.unknown ||
      PublicationViewPhase.querying ||
      PublicationViewPhase.queryReauthenticationRequired =>
        '核对发布结果',
      PublicationViewPhase.reauthenticationRequired => '需要安全验证',
      PublicationViewPhase.retryableNotSubmitted => '继续保存原配置',
      PublicationViewPhase.storageBlocked ||
      PublicationViewPhase.loadingLocal =>
        '核对本机操作记录',
      PublicationViewPhase.previewInvalid => '预览已失效',
      _ => '发布前预览',
    };
  }

  String? get primaryLabel => switch (c.phase) {
        PublicationViewPhase.fresh => '仅保存配置',
        PublicationViewPhase.confirming => '发布配置',
        PublicationViewPhase.submitting => '保存中…',
        PublicationViewPhase.unknown => '查询发布结果',
        PublicationViewPhase.querying => '查询中…',
        PublicationViewPhase.reauthenticationRequired ||
        PublicationViewPhase.queryReauthenticationRequired =>
          '完成安全验证',
        PublicationViewPhase.retryableNotSubmitted => '继续保存原配置',
        PublicationViewPhase.cleanupPending => '重新核对并清理',
        PublicationViewPhase.storageBlocked => '重新核对本机记录',
        PublicationViewPhase.loadingLocal => '核对中…',
        PublicationViewPhase.cancelling => '核对中…',
        PublicationViewPhase.previewInvalid =>
          widget.onRepreview == null ? null : '重新预览',
        PublicationViewPhase.recorded || PublicationViewPhase.revoked => null,
      };

  bool get primaryEnabled {
    if (!canAct || c.busy) return false;
    return switch (c.phase) {
      PublicationViewPhase.fresh ||
      PublicationViewPhase.retryableNotSubmitted =>
        c.canConfirm,
      PublicationViewPhase.confirming => c.canSubmit,
      PublicationViewPhase.unknown ||
      PublicationViewPhase.cleanupPending =>
        c.canCheck,
      PublicationViewPhase.reauthenticationRequired ||
      PublicationViewPhase.queryReauthenticationRequired =>
        c.needsReauth,
      PublicationViewPhase.storageBlocked => c.canReloadPending,
      PublicationViewPhase.previewInvalid =>
        widget.onRepreview != null && c.canRepreview,
      _ => false,
    };
  }

  String? get instruction => switch (c.phase) {
        PublicationViewPhase.confirming => '确认保存本次预览中的配置版本？当前不会执行设备系统管控。',
        PublicationViewPhase.submitting => '正在核对并保存已确认的原配置。请等待本次结果。',
        PublicationViewPhase.unknown ||
        PublicationViewPhase.querying =>
          c.receipt == null
              ? '本次保存结果尚未确认。请查询原操作；查询不会再次发布，也不会重新生成预览。'
              : '发布已确认，正在核对并清理本机记录；不会再次发布。',
        PublicationViewPhase.reauthenticationRequired =>
          '服务要求近期安全验证，本次配置尚未保存。完成验证后，可继续保存同一份已确认配置。',
        PublicationViewPhase.retryableNotSubmitted =>
          '上次保存因安全验证要求而停止，配置尚未提交。继续将使用原配置、原版本和原操作编号。',
        PublicationViewPhase.queryReauthenticationRequired => c.receipt == null
            ? '需要完成安全验证后继续核对原操作。当前仍不能确认是否保存，不会再次发布。'
            : '发布已确认。完成安全验证后，可继续核对并清理本机记录；不会再次发布。',
        PublicationViewPhase.cleanupPending =>
          '发布已确认，本机核对记录尚未清理。可重新核对并清理记录；不会再次发布。',
        PublicationViewPhase.storageBlocked ||
        PublicationViewPhase.loadingLocal =>
          '本机待确认记录暂时无法核对，保存已暂停。请重新核对本机记录后继续。',
        PublicationViewPhase.previewInvalid =>
          '原预览已过期或目标已发生变化，请重新预览后保存。已发起的未知操作仍只能查询原结果。',
        PublicationViewPhase.cancelling => '正在核对原操作是否可以安全结束。',
        _ => null,
      };

  String? get failureMessage {
    final error = c.error;
    if (error == null) return null;
    if (c.receipt != null) {
      return error is ApiFailure && error.code == 'REAUTH_REQUIRED'
          ? null
          : '配置保存已确认，本机核对记录暂未清理。请稍后重新核对并清理。';
    }
    if (error is! ApiFailure) return '本次核对暂未完成，请按当前提示继续。';
    if (error.code == 'POLICY_PUBLICATION_RESULT_UNAVAILABLE') {
      return '暂时查不到可确认的发布记录；这不代表未保存。请稍后再次查询原操作。';
    }
    if (error.code == 'INVALID_POLICY_PUBLICATION_RESPONSE') {
      return '服务返回的信息不完整，尚不能确认配置是否保存。请查询原操作。';
    }
    if (error.code == 'PREVIEW_EXPIRED') {
      return c.pending?.phase == PublicationPhase.unknown
          ? '原预览已过期；已发起操作的结果仍可按原编号查询。'
          : '原预览已过期，不能继续保存。';
    }
    if (error.code == 'POLICY_GROUP_CHANGED') {
      return '设备组已发生变化，请重新选择目标并预览。';
    }
    if (error.code == 'REAUTH_REQUIRED') return null;
    if (error.status == 0) return '连接暂时中断，原操作结果尚未确认。';
    if (error.status == 429) return '请求较为频繁，请稍后再次核对。';
    if (error.status >= 500) return '服务暂时不能确认结果，请稍后核对原操作。';
    return '本次核对暂未完成，请按当前提示继续。';
  }

  String timeLabel(int instant) {
    try {
      return dateLabel(instant);
    } on RangeError {
      return '时间超出显示范围';
    }
  }

  Widget field(String label, String value) => Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: muted, fontSize: 12)),
        const SizedBox(height: 4),
        SelectableText(value, style: const TextStyle(height: 1.5)),
      ]));

  Widget content() {
    if (!c.hasAccess) {
      return const Text('已隐藏原预览和发布内容。请关闭窗口，在当前工作空间重新打开。');
    }
    final phase = c.phase, receipt = c.receipt;
    final keepPreview = widget.preview != null &&
        const {
          PublicationViewPhase.fresh,
          PublicationViewPhase.confirming,
          PublicationViewPhase.previewInvalid,
        }.contains(phase);
    final message = instruction, failure = failureMessage;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (receipt != null) ...[
        const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.check_circle_outline, color: Color(0xFF00886C)),
          SizedBox(width: 10),
          Expanded(
              child: Text('配置已保存 · 未执行',
                  style: TextStyle(fontWeight: FontWeight.w700, height: 1.4))),
        ]),
        field('配置版本', '第 ${receipt.sequence} 版'),
        field('发布方式', '仅保存配置'),
        field('发布时间', timeLabel(receipt.createdAt)),
        field('发布编号', receipt.id),
      ],
      if (message != null) ...[
        if (receipt != null) const SizedBox(height: 16),
        Notice(message,
            warning: !const {
              PublicationViewPhase.confirming,
              PublicationViewPhase.submitting,
              PublicationViewPhase.retryableNotSubmitted,
            }.contains(phase)),
        const SizedBox(height: 12),
      ],
      if (keepPreview)
        Offstage(
            key: const ValueKey('publication-preview'),
            offstage: phase == PublicationViewPhase.confirming,
            child: PolicyPreviewResults(
                preview: widget.preview!,
                names: widget.names,
                selectionSummary: widget.selectionSummary)),
      if (!keepPreview && receipt == null) ...[
        field('原草稿版本', 'v${c.intent.revision}'),
        field('原操作时间', timeLabel(c.intent.createdAt)),
      ],
      if (!keepPreview || phase == PublicationViewPhase.confirming)
        field('原操作编号', c.intent.idempotencyKey),
      if (failure != null) ...[
        const SizedBox(height: 14),
        Notice(failure, warning: true),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final primaryText = c.hasAccess ? primaryLabel : null;
    return PopScope(
        canPop: !c.busy && !localBusy,
        child: AlertDialog(
            insetPadding: EdgeInsets.symmetric(
                horizontal: screen.width < 600 ? 16 : 40, vertical: 24),
            title: Text(title),
            content: SizedBox(
                width: 760,
                child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight:
                            (screen.height * .64).clamp(120, 720).toDouble()),
                    child: Scrollbar(
                        controller: scroll,
                        child: SingleChildScrollView(
                            controller: scroll, child: content())))),
            actions: [
              if (c.hasAccess && c.phase == PublicationViewPhase.confirming)
                TextButton(
                    onPressed: c.busy || localBusy
                        ? null
                        : guarded(() {
                            if (canAct && !c.busy) c.cancelConfirmation();
                          }),
                    child: const Text('取消')),
              TextButton(
                  key: const Key('publication-close'),
                  onPressed: c.busy || localBusy ? null : guarded(close),
                  child: const Text('关闭')),
              if (primaryText != null)
                FilledButton(
                    key: const Key('publication-primary'),
                    onPressed: primaryEnabled ? guarded(primary) : null,
                    child: Text(primaryText)),
            ]));
  }

  @override
  void dispose() {
    closing = true;
    generation++;
    c.removeListener(changed);
    scroll.dispose();
    super.dispose();
  }
}
