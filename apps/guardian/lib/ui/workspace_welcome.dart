import 'dart:async';
import 'package:flutter/material.dart';
import '../core/workspace_read_recovery.dart';
import 'design.dart';

class WorkspaceWelcome extends StatefulWidget {
  final FutureOr<void> Function()? onCreate;
  final FutureOr<void> Function() onJoin;
  final FutureOr<void> Function()? onRefresh;
  final VoidCallback? onSignOut, onReauthenticate;
  final Object? authenticationIdentity;
  final bool Function()? isCurrent;
  final List<Widget> platformTools;
  const WorkspaceWelcome(
      {super.key,
      this.onCreate,
      required this.onJoin,
      this.onRefresh,
      this.onSignOut,
      this.onReauthenticate,
      this.authenticationIdentity,
      this.isCurrent,
      this.platformTools = const []});

  @override
  State<WorkspaceWelcome> createState() => _WorkspaceWelcomeState();
}

class _WorkspaceWelcomeState extends State<WorkspaceWelcome> {
  bool busy = false, invalidated = false, refreshed = false;
  int generation = 0;
  Object? error;
  WorkspaceReadRecovery? recovery;

  bool get current => !invalidated && (widget.isCurrent?.call() ?? true);
  bool active(int ticket) => mounted && current && ticket == generation;
  VoidCallback? guarded(VoidCallback? action) => action == null
      ? null
      : () {
          if (current) action();
        };

  @override
  void didUpdateWidget(covariant WorkspaceWelcome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
        oldWidget.authenticationIdentity, widget.authenticationIdentity)) {
      generation++;
      busy = invalidated = refreshed = false;
      error = null;
      recovery = null;
    } else if (!current) {
      generation++;
      busy = false;
      invalidated = true;
      error = null;
      recovery = null;
    }
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  Future<void> run(FutureOr<void> Function() operation,
      {bool reading = false}) async {
    if (busy || !current) return;
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = null;
      refreshed = false;
    });
    try {
      await operation();
      if (active(ticket)) {
        setState(() {
          recovery = null;
          refreshed = reading;
        });
      }
    } on WorkspaceReadRecovery catch (failure) {
      if (active(ticket) && failure.isCurrent()) {
        setState(() => recovery = failure);
      }
    } catch (failure) {
      if (active(ticket)) {
        setState(() {
          if (recovery == null) {
            error = failure;
          } else {
            recovery = recovery!.withError(failure);
          }
        });
      }
    } finally {
      if (active(ticket)) setState(() => busy = false);
    }
  }

  void retryRead() {
    final pending = recovery;
    if (pending == null || !current || !pending.isCurrent()) return;
    run(pending.reload, reading: true);
  }

  @override
  Widget build(BuildContext context) {
    if (!current) {
      return const Panel(child: Text('账号会话已变化，请返回当前账号页面。'));
    }
    final locked = busy || recovery != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageHeading(widget.onCreate == null ? '加入你的工作空间' : '从一个工作空间开始',
          '集中管理家庭或机构的档案、设备和使用规则。',
          action: widget.onRefresh == null
              ? null
              : OutlinedButton.icon(
                  onPressed: locked
                      ? null
                      : () => run(widget.onRefresh!, reading: true),
                  icon: const Icon(Icons.refresh),
                  label: const Text('刷新工作空间列表'))),
      if (recovery != null) ...[
        WorkspaceReadRecoveryPanel(
            recovery: recovery!,
            busy: busy,
            onRetry: retryRead,
            onSignOut: guarded(widget.onSignOut),
            onReauthenticate: guarded(widget.onReauthenticate)),
        const SizedBox(height: 16),
      ] else if (error != null) ...[
        const Notice('工作空间资料暂未加载，请刷新列表重试。', warning: true),
        const SizedBox(height: 12),
        FailureView(error!, reauth: guarded(widget.onReauthenticate)),
        if (widget.onSignOut != null)
          TextButton(
              onPressed: guarded(widget.onSignOut),
              child: const Text('退出并重新登录')),
        const SizedBox(height: 16),
      ] else if (refreshed) ...[
        const Notice('工作空间资料已刷新。'),
        const SizedBox(height: 16),
      ],
      if (busy) const LinearProgressIndicator(),
      LayoutBuilder(builder: (context, box) {
        final paired = widget.onCreate != null && box.maxWidth >= 700;
        final width = paired ? (box.maxWidth - 16) / 2 : box.maxWidth;
        return Wrap(spacing: 16, runSpacing: 16, children: [
          if (widget.onCreate != null)
            SizedBox(
                width: width,
                child: _choice(context,
                    icon: Icons.add_home_outlined,
                    title: '管理自己的家庭或机构',
                    description: '先起一个名称，之后再添加档案和连接设备。',
                    action: FilledButton.icon(
                        onPressed: locked ? null : () => run(widget.onCreate!),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('创建工作空间')))),
          SizedBox(
              width: width,
              child: _choice(context,
                  icon: Icons.group_add_outlined,
                  title: '加入已有工作空间',
                  description: '已有邀请？使用管理员发来的邀请加入，无需重复创建。',
                  action: OutlinedButton.icon(
                      onPressed: locked ? null : () => run(widget.onJoin),
                      icon: const Icon(Icons.mail_outline, size: 18),
                      label: const Text('使用邀请加入')))),
        ]);
      }),
      if (widget.platformTools.isNotEmpty) ...[
        const SizedBox(height: 28),
        const Text('平台工具',
            style: TextStyle(
                color: muted, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 10, children: widget.platformTools),
      ],
    ]);
  }

  Widget _choice(BuildContext context,
          {required IconData icon,
          required String title,
          required String description,
          required Widget action}) =>
      Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: canvas, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, size: 26, color: navy)),
        const SizedBox(height: 20),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(description, style: const TextStyle(color: muted, height: 1.7)),
        const SizedBox(height: 24),
        action,
      ]));
}

class WorkspaceReadRecoveryPanel extends StatelessWidget {
  final WorkspaceReadRecovery recovery;
  final bool busy;
  final VoidCallback onRetry;
  final VoidCallback? onSignOut, onReauthenticate;
  const WorkspaceReadRecoveryPanel(
      {super.key,
      required this.recovery,
      required this.busy,
      required this.onRetry,
      this.onSignOut,
      this.onReauthenticate});

  @override
  Widget build(BuildContext context) => Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(liveRegion: true, child: Notice(recovery.completedMessage)),
        const SizedBox(height: 12),
        const Text('无需再次创建或接受邀请。重试只会读取工作空间资料。'),
        const SizedBox(height: 12),
        FailureView(recovery.error,
            reauth: onReauthenticate == null
                ? null
                : () {
                    if (recovery.isCurrent()) onReauthenticate!();
                  }),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 8, children: [
          FilledButton.icon(
              onPressed: busy
                  ? null
                  : () {
                      if (recovery.isCurrent()) onRetry();
                    },
              icon: const Icon(Icons.refresh),
              label: const Text('重试读取')),
          if (onSignOut != null)
            TextButton(
                onPressed: () {
                  if (recovery.isCurrent()) onSignOut!();
                },
                child: const Text('退出并重新登录')),
        ]),
      ]));
}

Future<void> showWorkspaceReadRecoveryDialog(
        BuildContext context, WorkspaceReadRecovery recovery,
        {required Listenable accessChanges,
        required VoidCallback onSignOut,
        required VoidCallback onReauthenticate}) =>
    showDialog<void>(
        context: context,
        builder: (_) => _WorkspaceReadRecoveryDialog(
            recovery: recovery,
            onSignOut: onSignOut,
            onReauthenticate: onReauthenticate,
            accessChanges: accessChanges));

class _WorkspaceReadRecoveryDialog extends StatefulWidget {
  final WorkspaceReadRecovery recovery;
  final Listenable accessChanges;
  final VoidCallback onSignOut, onReauthenticate;
  const _WorkspaceReadRecoveryDialog(
      {required this.recovery,
      required this.onSignOut,
      required this.onReauthenticate,
      required this.accessChanges});
  @override
  State<_WorkspaceReadRecoveryDialog> createState() =>
      _WorkspaceReadRecoveryDialogState();
}

class _WorkspaceReadRecoveryDialogState
    extends State<_WorkspaceReadRecoveryDialog> {
  late WorkspaceReadRecovery recovery = widget.recovery;
  bool busy = false, closing = false;
  bool get ownRoute =>
      mounted && !closing && ModalRoute.of(context)?.isCurrent == true;
  bool get current => ownRoute && recovery.isCurrent();

  @override
  void initState() {
    super.initState();
    widget.accessChanges.addListener(changed);
  }

  void changed() {
    if (mounted && !recovery.isCurrent()) setState(() => busy = false);
  }

  @override
  void dispose() {
    widget.accessChanges.removeListener(changed);
    super.dispose();
  }

  void close() {
    if (!ownRoute) return;
    closing = true;
    Navigator.pop(context);
  }

  Future<void> retry() async {
    if (busy || !current) return;
    setState(() => busy = true);
    try {
      await recovery.reload();
      if (current) close();
    } catch (failure) {
      if (current) {
        setState(() => recovery = recovery.withError(failure));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
      title: const Text('读取工作空间资料'),
      content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
              child: recovery.isCurrent()
                  ? WorkspaceReadRecoveryPanel(
                      recovery: recovery,
                      busy: busy,
                      onRetry: retry,
                      onSignOut: () {
                        if (recovery.isCurrent()) widget.onSignOut();
                      },
                      onReauthenticate: () {
                        if (recovery.isCurrent()) widget.onReauthenticate();
                      })
                  : const Text('账号会话已变化，请关闭此窗口。'))),
      actions: [TextButton(onPressed: close, child: const Text('关闭'))]);
}
