import 'dart:async';
import 'package:device_access/device_access.dart';
import 'package:flutter/material.dart';
import '../core/session.dart';
import 'design.dart';
import 'submission_dialogs.dart';
import 'submission_display.dart';

/// Request facts and local intents are distinct from signed device permissions.
class SubmissionSection extends StatefulWidget {
  final ChildSession session;
  final bool available;
  const SubmissionSection(
      {super.key, required this.session, required this.available});
  @override
  State<SubmissionSection> createState() => _SubmissionSectionState();
}

class _SubmissionSectionState extends State<SubmissionSection> {
  final _createFocus = FocusNode(debugLabel: 'request temporary access');
  int _visible = 8;
  ChildSession get session => widget.session;
  @override
  void dispose() {
    _createFocus.dispose();
    super.dispose();
  }

  Future<void> _detail(SubmissionCacheEntry entry) async {
    final generation = session.submissionGeneration;
    await session.submissionDetail(entry.value.id);
    if (!mounted ||
        !session.foreground ||
        !session.credentialReady ||
        generation != session.submissionGeneration ||
        session.submissions.journal == null) return;
    await showSubmissionDetail(context, session, entry.value.id);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final view = session.submissions, pending = view.journal?.pending;
        final entries = view.journal?.entries ?? const <SubmissionCacheEntry>[];
        final usable =
            widget.available && session.foreground && session.credentialReady;
        final ready = usable && !session.busy;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('临时访问申请', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text('需要使用受限应用时，可以向监护人申请。提交申请和获得批准，都不代表应用已经解锁。'),
          const SizedBox(height: 16),
          if (session.submissionErrorCode != null) ...[
            Semantics(
                liveRegion: true,
                child: ChildNotice(submissionError(session.submissionErrorCode),
                    warning: true)),
            if (session.submissionCorrelationId != null)
              SelectableText('问题编号：${session.submissionCorrelationId}',
                  style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16)
          ],
          if (!usable) const ChildNotice('申请暂不可用', detail: '请先确认设备连接与监护人授权。'),
          if (view.contextReady && !view.onlineConfirmed) ...[
            const ChildNotice('显示上次保存的申请', detail: '尚未在线核对。原待审期限和批准截止时间不会延长。'),
            const SizedBox(height: 16)
          ],
          if (pending != null) ...[
            ChildNotice(
                switch (pending.phase) {
                  SubmissionOperationPhase.prepared => '原操作尚未发送',
                  SubmissionOperationPhase.unknown => '结果待确认',
                  SubmissionOperationPhase.rejected => '本次操作未提交'
                },
                detail: pending.phase == SubmissionOperationPhase.unknown
                    ? '${pending.applicationName}：可能已送达监护人。请按原操作确认结果，不能重复申请。'
                    : pending.phase == SubmissionOperationPhase.rejected
                        ? submissionError(pending.rejectionCode)
                        : '${pending.applicationName}：确认后才能发送。',
                warning: true),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 8, children: [
              if (pending.phase != SubmissionOperationPhase.rejected)
                OutlinedButton(
                    onPressed: ready
                        ? () => showSubmissionRecovery(context, session)
                        : null,
                    child: Text(
                        pending.phase == SubmissionOperationPhase.prepared
                            ? '确认并发送原操作'
                            : '按原操作重试')),
              if (pending.phase != SubmissionOperationPhase.unknown)
                TextButton(
                    onPressed: ready
                        ? () => showSubmissionRecovery(context, session,
                            discard: true)
                        : null,
                    child: const Text('放弃本次操作'))
            ]),
            const SizedBox(height: 20)
          ],
          Wrap(spacing: 12, runSpacing: 12, children: [
            FilledButton(
                focusNode: _createFocus,
                key: const Key('submission-create'),
                onPressed: ready &&
                        pending == null &&
                        view.onlineConfirmed &&
                        view.options.isNotEmpty
                    ? () => showSubmissionEditor(context, session)
                    : null,
                child: const Text('申请临时访问')),
            OutlinedButton(
                onPressed: ready
                    ? () => unawaited(session.refreshSubmissions())
                    : null,
                child: const Text('刷新申请'))
          ]),
          const SizedBox(height: 16),
          if (view.onlineConfirmed && view.options.isEmpty)
            Text(view.optionsCursor != null
                ? '当前页暂无可申请应用'
                : '当前暂无可申请应用，请与监护人核对规则。'),
          if (view.optionsCursor != null)
            TextButton(
                onPressed: ready
                    ? () => unawaited(session.moreSubmissionOptions())
                    : null,
                child: const Text('继续查找应用')),
          if (view.contextReady && entries.isEmpty && pending == null)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('还没有保存的申请记录')),
          for (final entry in entries.take(_visible)) ...[
            const Divider(height: 24),
            Text(entry.applicationName,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(submissionState(entry.value)),
            Text(
                '申请时长：${submissionDuration(entry.value.requestedWindowSeconds)}'),
            Text(
                view.confirmedRequestIds.contains(entry.value.id)
                    ? '本轮已在线核对'
                    : '上次保存，待核对',
                style: Theme.of(context).textTheme.bodySmall),
            TextButton(
                onPressed: ready ? () => unawaited(_detail(entry)) : null,
                child: const Text('查看申请'))
          ],
          if (entries.length > _visible)
            TextButton(
                onPressed: () => setState(() => _visible += 8),
                child: const Text('查看更多已保存记录')),
          if (view.requestsCursor != null)
            OutlinedButton(
                onPressed:
                    ready ? () => unawaited(session.moreSubmissions()) : null,
                child: const Text('继续加载申请')),
          if (view.lastCheckedAt != null)
            Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                    '设备上下文最近核对：${submissionTime(context, view.lastCheckedAt!)}',
                    style: Theme.of(context).textTheme.bodySmall))
        ]);
      });
}
