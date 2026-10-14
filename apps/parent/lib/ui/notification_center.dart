import 'dart:async';
import 'package:flutter/material.dart';
import '../core/notifications.dart';
import '../core/parent_session.dart';
import 'access_history.dart';

/// Captures the adult identity; current membership is still checked by the API.
mixin NotificationScope<T extends StatefulWidget> on State<T>
    implements WidgetsBindingObserver {
  ParentSession get session;
  late final String actor, tenant, role;
  bool foreground = true;
  bool get current =>
      mounted &&
      session.authenticated &&
      session.canDecide &&
      session.profile?['subject'] == actor &&
      session.tenant?['id'] == tenant &&
      session.role == role;
  void scopeInvalidated();
  void foregroundChanged();
  @override
  void initState() {
    super.initState();
    actor = session.profile!['subject'];
    tenant = session.tenant!['id'];
    role = session.role;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
  }

  void _changed() {
    if (!current) scopeInvalidated();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    foregroundChanged();
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class ParentNotificationShortcut extends StatefulWidget {
  final ParentSession session;
  const ParentNotificationShortcut({super.key, required this.session});
  @override
  State<ParentNotificationShortcut> createState() =>
      _ParentNotificationShortcutState();
}

class _ParentNotificationShortcutState extends State<ParentNotificationShortcut>
    with WidgetsBindingObserver, NotificationScope {
  @override
  ParentSession get session => widget.session;
  Timer? timer;
  InboxCount? count;
  bool busy = false, failed = false;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    timer?.cancel();
    if (!current || !foreground) return;
    refresh();
    timer = Timer.periodic(const Duration(minutes: 1), (_) => refresh());
  }

  Future<void> refresh() async {
    if (!current || !foreground || busy) return;
    final g = ++generation;
    busy = true;
    try {
      final value = InboxCount.parse(await session.api.object(
          '/tenants/$tenant/notifications/unread-count',
          isCurrent: () => current && foreground && generation == g));
      if (current && foreground && generation == g) {
        setState(() {
          count = value;
          failed = false;
        });
      }
    } catch (_) {
      if (current && foreground && generation == g) {
        setState(() {
          count = null;
          failed = true;
        });
      }
    } finally {
      if (generation == g) busy = false;
    }
  }

  @override
  void scopeInvalidated() {
    generation++;
    timer?.cancel();
    busy = false;
    count = null;
    if (mounted) setState(() {});
  }

  @override
  void foregroundChanged() {
    scopeInvalidated();
    _schedule();
  }

  @override
  void dispose() {
    timer?.cancel();
    generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !current || !foreground
      ? const SizedBox.shrink()
      : IconButton(
          tooltip: failed
              ? '消息中心，未读数量暂不可用'
              : count == null
                  ? '消息中心'
                  : '消息中心，${count!.label} 条未读',
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ParentNotificationCenter(session: session)));
            if (current && foreground) refresh();
          },
          icon: Badge(
              isLabelVisible: failed || (count?.count ?? 0) > 0,
              label: Text(failed
                  ? '!'
                  : (count?.count ?? 0) > 99
                      ? '99+'
                      : '${count?.count ?? 0}'),
              child: const Icon(Icons.notifications_none_outlined)));
}

class ParentNotificationCenter extends StatefulWidget {
  final ParentSession session;
  final Future<void> Function(String)? onOpen;
  const ParentNotificationCenter(
      {super.key, required this.session, this.onOpen});
  @override
  State<ParentNotificationCenter> createState() =>
      _ParentNotificationCenterState();
}

class _ParentNotificationCenterState extends State<ParentNotificationCenter>
    with WidgetsBindingObserver, NotificationScope {
  @override
  ParentSession get session => widget.session;
  late final ParentNotificationInbox inbox;
  @override
  void initState() {
    super.initState();
    inbox = ParentNotificationInbox(
        api: session.api, root: '/tenants/$tenant', isCurrent: () => current);
    inbox.setForeground(foreground);
    inbox.load();
  }

  @override
  void scopeInvalidated() {
    inbox.invalidate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void foregroundChanged() {
    inbox.setForeground(foreground);
    if (current && foreground) inbox.load(first: true);
    if (mounted) setState(() {});
  }

  Future<void> open(String id) async {
    if (!current || !foreground) return;
    if (widget.onOpen != null) {
      await widget.onOpen!(id);
    } else {
      await showAccessRequestDetail(context, session, id);
    }
  }

  @override
  void dispose() {
    inbox.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: inbox,
      builder: (context, _) {
        final data = inbox.snapshot, busy = inbox.busy;
        final ids =
            data?.page.items.where((n) => n.unread).map((n) => n.id).toList() ??
                <String>[];
        return Scaffold(
            appBar: AppBar(title: const Text('消息中心'), actions: [
              IconButton(
                  tooltip: '刷新消息',
                  onPressed: busy || !current || !foreground
                      ? null
                      : () => inbox.load(first: true),
                  icon: const Icon(Icons.refresh))
            ]),
            body: !current || !foreground
                ? const Center(child: Text('消息内容已隐藏。'))
                : RefreshIndicator(
                    onRefresh: () => inbox.load(first: true),
                    child: ListView(
                        padding: const EdgeInsets.all(20),
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          Text(
                              data == null
                                  ? inbox.error == null
                                      ? '正在同步消息'
                                      : '未读数量暂不可用'
                                  : '${data.unread.label} 条未读',
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 8),
                          const Text('访问申请的进展都在这里。打开消息可查看申请的当前状态。'),
                          const SizedBox(height: 16),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            ChoiceChip(
                                label: const Text('未读'),
                                selected: inbox.unreadOnly,
                                onSelected: busy
                                    ? null
                                    : (_) => inbox.load(unread: true)),
                            ChoiceChip(
                                label: const Text('全部'),
                                selected: !inbox.unreadOnly,
                                onSelected: busy
                                    ? null
                                    : (_) => inbox.load(unread: false)),
                            TextButton.icon(
                                onPressed: busy || ids.isEmpty
                                    ? null
                                    : () => inbox.read(ids, open: open),
                                icon: const Icon(Icons.done_all),
                                label: const Text('本页已读'))
                          ]),
                          if (busy && !inbox.opening)
                            const LinearProgressIndicator(),
                          if (inbox.confirmation != null)
                            Text(inbox.confirmation!),
                          if (inbox.error != null)
                            Card(
                                child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Semantics(
                                              liveRegion: true,
                                              child: Text('${inbox.error}')),
                                          TextButton(
                                              onPressed: busy
                                                  ? null
                                                  : () => inbox.retryIds != null
                                                      ? inbox.read(
                                                          inbox.retryIds!,
                                                          requestId: inbox
                                                              .retryRequestId,
                                                          open: open)
                                                      : inbox.load(),
                                              child: Text(inbox.retryIds != null
                                                  ? '按原选择重试'
                                                  : '重新读取'))
                                        ]))),
                          if (data != null && data.page.items.isEmpty)
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 32),
                                child: Column(children: [
                                  const Icon(Icons.mark_email_read_outlined,
                                      size: 44),
                                  const SizedBox(height: 12),
                                  Text(inbox.unreadOnly ? '暂无未读消息' : '这一页暂无消息'),
                                  const Text('只显示保留期内、当前权限可见的消息。',
                                      textAlign: TextAlign.center)
                                ])),
                          for (final n in data?.page.items ?? <InboxNotice>[])
                            Card(
                                margin: const EdgeInsets.symmetric(vertical: 6),
                                child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Wrap(
                                              spacing: 8,
                                              runSpacing: 6,
                                              children: [
                                                Text(n.title,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .titleMedium),
                                                Text(n.unread ? '未读' : '已读')
                                              ]),
                                          const SizedBox(height: 8),
                                          Text(n.description),
                                          const SizedBox(height: 8),
                                          Text(_time(n.occurredAt),
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodySmall),
                                          Wrap(spacing: 8, children: [
                                            FilledButton.tonal(
                                                onPressed: busy
                                                    ? null
                                                    : () => inbox.read(
                                                        n.unread ? [n.id] : [],
                                                        requestId: n.requestId,
                                                        open: open),
                                                child: const Text('查看当前申请')),
                                            if (n.unread)
                                              TextButton(
                                                  onPressed: busy
                                                      ? null
                                                      : () => inbox.read([n.id],
                                                          open: open),
                                                  child: const Text('标为已读'))
                                          ]),
                                          ExpansionTile(
                                              tilePadding: EdgeInsets.zero,
                                              title: const Text('消息详情'),
                                              children: [
                                                SelectableText(
                                                    '申请编号：${n.requestId}\n发生时版本：${n.requestVersion}\n消息编号：${n.id}')
                                              ])
                                        ]))),
                          if (data != null || inbox.cursors.length > 1)
                            Wrap(
                                spacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text('第 ${inbox.cursors.length} 页'),
                                  TextButton(
                                      onPressed:
                                          busy || inbox.cursors.length == 1
                                              ? null
                                              : inbox.previous,
                                      child: const Text('上一页')),
                                  TextButton(
                                      onPressed:
                                          busy || data?.page.nextCursor == null
                                              ? null
                                              : inbox.next,
                                      child: const Text('下一页'))
                                ]),
                          const SizedBox(height: 16),
                          const Text('已读只影响你的账号，不会批准申请或改变设备限制。'),
                        ])));
      });
}

String _time(int epoch) {
  final d = DateTime.fromMillisecondsSinceEpoch(epoch);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}（本机时间）';
}
