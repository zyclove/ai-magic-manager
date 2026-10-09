import 'package:flutter/material.dart';
import '../core/audit.dart';
import '../core/audit_exports.dart';
import '../core/api.dart';
import '../core/labels.dart';
import 'design.dart';

class ExportCreateDialog extends StatefulWidget {
  final AuditExportRepository repository;
  final AuditQuery query;
  final ValueChanged<AuditExportJob> onCreated;
  final VoidCallback onReauth;
  final Listenable? accessChanges;
  const ExportCreateDialog(
      {super.key,
      required this.repository,
      required this.query,
      required this.onCreated,
      required this.onReauth,
      this.accessChanges});
  @override
  State<ExportCreateDialog> createState() => _ExportCreateDialogState();
}

class _ExportCreateDialogState extends State<ExportCreateDialog> {
  final key = requestId();
  bool busy = false, done = false, attempted = false;
  Object? error;
  @override
  void initState() {
    super.initState();
    widget.accessChanges?.addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.accessChanges?.removeListener(changed);
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || done || !widget.repository.current()) return;
    setState(() {
      busy = true;
      attempted = true;
      error = null;
    });
    try {
      final job = await widget.repository.create(widget.query, key);
      if (!mounted) return;
      setState(() {
        busy = false;
        done = true;
      });
      widget.onCreated(job);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.repository.current(), q = widget.query;
    return PopScope(
        canPop: !busy,
        child: AlertDialog(
            title: const Text('导出审计日志'),
            content: SizedBox(
                width: 460,
                child: SingleChildScrollView(
                    child: current
                        ? Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                                const Text('导出当前已应用的筛选结果，文件将在后台生成。'),
                                const SizedBox(height: 16),
                                Text(
                                    '${dateLabel(q.from)} 至 ${dateLabel(q.to)}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 8),
                                const Text('按本机时区显示；包含开始时间，不包含结束时间。',
                                    style: TextStyle(
                                        color: muted, fontSize: 12)),
                                if (q.action != null) Text('操作：${q.action}'),
                                if (q.resourceId != null)
                                  SelectableText('资源：${q.resourceId}'),
                                if (q.correlationId != null)
                                  SelectableText('关联：${q.correlationId}'),
                                const SizedBox(height: 16),
                                const Notice(
                                    'JSON 格式 · 最多 10,000 条、8 MiB。创建后 24 小时内可下载；创建和下载需要近期安全验证。'),
                                const SizedBox(height: 12),
                                const Text(
                                    '文件包含操作人与资源记录，请妥善保管。取消任务会删除在线文件，已下载的副本需自行管理。',
                                    style:
                                        TextStyle(color: muted, height: 1.6)),
                                if (error != null) ...[
                                  const SizedBox(height: 16),
                                  FailureView(error!,
                                      reauth: busy ? null : widget.onReauth)
                                ],
                                if (done) const Notice('导出任务已创建。'),
                              ])
                        : const Notice('工作空间或权限已变化，请关闭窗口后重新操作。',
                            warning: true))),
            actions: [
              TextButton(
                  onPressed: busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('关闭')),
              if (current && !done)
                FilledButton(
                    onPressed: busy ? null : submit,
                    child: Text(busy
                        ? '正在提交…'
                        : attempted
                            ? '重试生成'
                            : '生成导出')),
            ]));
  }
}
