import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/subject_archive.dart';
import 'design.dart';
import 'dialog_access.dart';
import 'leased_dialog.dart';
import 'owned_dialog_route.dart';

/// True asks the caller to replace its old details and review the list.
Future<bool> subjectArchiveDialog(BuildContext context,
    {required Api api,
    required String root,
    required Json subject,
    required Listenable accessChanges,
    required bool Function() hasAccess,
    VoidCallback? reauth,
    VoidCallback? onSubmitAttempt}) async {
  if (!context.mounted || !hasAccess()) return false;
  var live = true;
  DialogAccessBinding? lease;
  final operation = SubjectArchiveOperation(
      api: api,
      root: root,
      requestKey: const Uuid().v4(),
      subject: subject,
      isCurrent: () => live && hasAccess() && lease?.permitted() == true,
      onSubmitAttempt: onSubmitAttempt);
  try {
    return await leasedDialog<bool>(context,
        accessChanges: accessChanges,
        hasAccess: hasAccess,
        builder: (_, route, access) {
          lease = access;
          return _SubjectArchiveDialog(
              operation: operation, route: route, reauth: reauth);
        }) ?? false;
  } finally {
    live = false;
    operation.dispose();
  }
}

class _SubjectArchiveDialog extends StatefulWidget {
  final SubjectArchiveOperation operation;
  final OwnedDialogRoute<bool> route;
  final VoidCallback? reauth;
  const _SubjectArchiveDialog(
      {required this.operation, required this.route, this.reauth});

  @override
  State<_SubjectArchiveDialog> createState() => _SubjectArchiveDialogState();
}

class _SubjectArchiveDialogState extends State<_SubjectArchiveDialog> {
  bool confirmingClose = false;
  SubjectArchiveOperation get operation => widget.operation;
  bool get current => mounted && widget.route.available &&
      widget.route.isCurrent && operation.current;

  void close() {
    if (!current || operation.busy) return;
    if (operation.result == null && operation.uncertain && !operation.stopped) {
      setState(() => confirmingClose = true);
    } else {
      widget.route.finish(operation.attempted);
    }
  }

  Future<void> perform({required bool query}) async {
    if (!current || operation.busy || confirmingClose) return;
    if (query) {
      await operation.query();
    } else {
      await operation.submit();
    }
    if (current && operation.result != null) widget.route.finish(true);
  }

  void reauthenticate() {
    if (current && !operation.busy && !operation.stopped && !confirmingClose) {
      widget.reauth?.call();
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: operation,
      builder: (_, __) {
        final subject = operation.subject;
        final confirmed = operation.result != null;
        final unknown = operation.uncertain && !confirmed && !operation.stopped;
        return PopScope(
            // After dispatch, leaving must carry a review signal to the caller.
            canPop: !operation.busy && !operation.attempted,
            child: AlertDialog(
                title: const Text('归档儿童档案'),
                scrollable: true,
                content: SizedBox(
                    width: 480,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${subject['nickname']}',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          SelectableText('档案编号：${subject['id']}'),
                          Text('年龄段：${label(subject['ageBand'])}'),
                          const SizedBox(height: 16),
                          const Text(
                              '归档后将不再显示在活动档案中，相关临时访问窗口会失效。可在“包含已归档”中查看。此操作不会自动解除设备管理。',
                              style: TextStyle(height: 1.8)),
                          if (operation.busy) ...[
                            const SizedBox(height: 16),
                            const LinearProgressIndicator(),
                          ],
                          if (operation.attempted) ...[
                            const SizedBox(height: 16),
                            SelectableText('操作编号：${operation.requestKey}',
                                style: const TextStyle(color: muted, fontSize: 12)),
                            Text('提交时版本：${subject['version']}',
                                style: const TextStyle(color: muted, fontSize: 12)),
                          ],
                          if (confirmed) ...[
                            const SizedBox(height: 16),
                            const Notice('归档结果已确认，请返回列表核对当前档案。'),
                          ] else if (operation.stopped) ...[
                            const SizedBox(height: 16),
                            const Notice('已停止原操作，不会再次提交。请关闭窗口后核对当前档案。',
                                warning: true),
                          ] else if (unknown) ...[
                            const SizedBox(height: 16),
                            const Notice('归档结果尚未确认。可查询原操作，不会重复提交归档。',
                                warning: true),
                          ],
                          if (operation.error != null) ...[
                            const SizedBox(height: 16),
                            FailureView(operation.error!,
                                reauth: widget.reauth == null || operation.stopped ||
                                        confirmingClose || operation.busy
                                    ? null : reauthenticate),
                          ],
                          if (confirmingClose) ...[
                            const SizedBox(height: 16),
                            const Notice(
                                '关闭不会取消已经提交的归档。请先核对当前档案，再决定后续操作。',
                                key: Key('subject-archive-unknown-close-notice'),
                                warning: true),
                          ],
                        ])),
                actions: confirmingClose
                    ? [
                        TextButton(
                            onPressed: () {
                              if (current && !operation.busy && confirmingClose) {
                                setState(() => confirmingClose = false);
                              }
                            },
                            child: const Text('继续核对')),
                        FilledButton(
                            onPressed: () {
                              if (current && !operation.busy && confirmingClose &&
                                  operation.uncertain && !operation.stopped &&
                                  operation.result == null) {
                                widget.route.finish(operation.attempted);
                              }
                            },
                            child: const Text('关闭并核对列表')),
                      ]
                    : [
                        TextButton(
                            onPressed: operation.busy ? null : close,
                            child: Text(confirmed || operation.stopped
                                ? '关闭并核对列表' : unknown ? '暂时关闭' : '取消')),
                        if (!confirmed && !operation.stopped)
                          FilledButton(
                              onPressed: (unknown ? operation.canQuery : operation.canSubmit)
                                  ? () => perform(query: unknown) : null,
                              child: Text(operation.busy
                                  ? '处理中…' : unknown ? '查询归档结果' : '确认归档')),
                      ]));
      });
}
