import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/api.dart';
import '../core/notifications.dart';
import 'design.dart';

class NotificationsView extends StatefulWidget {
  final NotificationRepository repository;
  final Future<void> Function(String requestId) onOpen;
  const NotificationsView(
      {super.key, required this.repository, required this.onOpen});
  @override
  State<NotificationsView> createState() => _NotificationsViewState();
}

class _NotificationsViewState extends State<NotificationsView> {
  InboxSnapshot? snapshot;
  Object? error;
  bool busy = false, unreadOnly = false;
  Object? activeRead;
  int generation = 0;
  final cursors = <String?>[null];
  Future<void> Function()? retry;
  String? confirmation;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant NotificationsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      activeRead = null;
      cursors
        ..clear()
        ..add(null);
      unreadOnly = false;
      confirmation = null;
      load();
    }
  }

  bool current(NotificationRepository repository) =>
      mounted &&
      identical(widget.repository, repository) &&
      repository.current();

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  Future<void> load({NotificationRepository? owner}) async {
    final repository = owner ?? widget.repository;
    if (!current(repository)) return;
    final request = ++generation;
    setState(() {
      busy = true;
      error = null;
      retry = null;
      snapshot = null;
    });
    try {
      final value = await repository.load(
          cursor: cursors.last, unreadOnly: unreadOnly);
      if (!current(repository) || generation != request) return;
      setState(() => snapshot = value);
    } catch (failure) {
      if (current(repository) && generation == request) {
        setState(() {
          error = failure;
          retry = () => load(owner: repository);
        });
      }
    } finally {
      if (current(repository) && generation == request) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> firstPage({bool? filter, NotificationRepository? owner}) async {
    final repository = owner ?? widget.repository;
    if (!current(repository)) return;
    cursors
      ..clear()
      ..add(null);
    if (filter != null) unreadOnly = filter;
    confirmation = null;
    await load(owner: repository);
  }

  Future<void> read(List<String> selected,
      {String? requestId, NotificationRepository? owner}) async {
    final repository = owner ?? widget.repository;
    if (!current(repository) || activeRead != null || busy) return;
    final onOpen = widget.onOpen;
    final operation = Object();
    activeRead = operation;
    try {
      final ids = List<String>.unmodifiable(selected);
      final request = ++generation;
      setState(() {
        busy = true;
        error = null;
        retry = null;
        confirmation = null;
      });
      try {
        repository.ensureCurrent();
        if (ids.isNotEmpty) await repository.markRead(ids);
        if (!current(repository) || generation != request) return;
        repository.ensureCurrent();
        if (requestId != null) await onOpen(requestId);
        if (!current(repository) || generation != request) return;
        repository.ensureCurrent();
        confirmation =
            requestId == null ? '已将 ${ids.length} 条通知标为已读，仅影响你的账号。' : null;
        cursors
          ..clear()
          ..add(null);
        await load(owner: repository);
      } catch (failure) {
        if (!current(repository) || generation != request) return;
        setState(() {
          error = failure;
          retry = () => read(ids, requestId: requestId, owner: repository);
          if (failure is ApiFailure &&
              (failure.status == 401 ||
                  failure.status == 403 ||
                  failure.code == 'WORKSPACE_CHANGED')) {
            snapshot = null;
            retry = () => load(owner: repository);
          }
        });
      } finally {
        if (current(repository) && generation == request) {
          setState(() => busy = false);
        }
      }
    } finally {
      if (identical(activeRead, operation)) activeRead = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = widget.repository;
    final data = snapshot;
    final unreadIds =
        data?.page.items.where((n) => n.unread).map((n) => n.id).toList() ??
            <String>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageHeading('通知中心', '跟进访问申请，及时查看处理进度。',
          action: OutlinedButton.icon(
              onPressed: busy ? null : () => firstPage(owner: repository),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('刷新通知'))),
      Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Icon(Icons.notifications_none, color: navy, size: 26),
              Semantics(
                  liveRegion: true,
                  child: Text(
                      data == null
                          ? error == null
                              ? '正在同步通知'
                              : '未读数量暂不可用'
                          : '${data.unread.label} 条未读',
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: ink))),
              const Text('当前工作空间 · 个人已读状态', style: TextStyle(color: muted)),
            ]),
        const SizedBox(height: 18),
        Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ChoiceChip(
                  label: const Text('全部'),
                  selected: !unreadOnly,
                  onSelected: busy
                      ? null
                      : (_) => firstPage(filter: false, owner: repository)),
              ChoiceChip(
                  label: const Text('未读'),
                  selected: unreadOnly,
                  onSelected: busy
                      ? null
                      : (_) => firstPage(filter: true, owner: repository)),
              OutlinedButton.icon(
                  onPressed:
                      busy || unreadIds.isEmpty
                          ? null
                          : () => read(unreadIds, owner: repository),
                  icon: const Icon(Icons.done_all, size: 18),
                  label: const Text('将本页标为已读')),
            ]),
        const SizedBox(height: 14),
        const Text('这里显示通知发生时的状态；打开申请可查看最新结果。仅显示保留期内、当前权限可见的通知。',
            style: TextStyle(color: muted, fontSize: 12)),
      ])),
      if (confirmation != null)
        Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Semantics(liveRegion: true, child: Notice(confirmation!))),
      if (error != null)
        Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Panel(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Semantics(
                      liveRegion: true,
                      child: Notice(
                          error is ApiFailure
                              ? (error as ApiFailure).code ==
                                      'INVALID_NOTIFICATION_RESPONSE'
                                  ? '通知响应不完整，请刷新后重试。'
                                  : (error as ApiFailure).message
                              : '通知未能加载，请稍后重试。',
                          warning: true)),
                  const SizedBox(height: 12),
                  OutlinedButton(
                      onPressed: busy ? null : retry, child: const Text('重试')),
                ]))),
      if (busy)
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: LinearProgressIndicator(semanticsLabel: '正在同步通知')),
      if (data != null) ...[
        const SizedBox(height: 20),
        if (data.page.items.isEmpty)
          Panel(
              child: EmptyView(
                  unreadOnly
                      ? '未读通知已处理完'
                      : cursors.length > 1
                          ? '这一页已无通知'
                          : '暂时没有通知',
                  unreadOnly
                      ? '之后有新的申请或处理结果，会显示在这里。'
                      : cursors.length > 1
                          ? '记录可能已读或超出保留期，返回首页查看最新通知。'
                          : '当访问申请状态变化时，这里会及时记录。')),
        for (final notice in data.page.items)
          Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Panel(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(notice.title,
                                  style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600)),
                              Text(notice.unread ? '未读通知' : '已读',
                                  style: TextStyle(
                                      color: notice.unread ? navy : muted,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12)),
                              Text(
                                  DateFormat('yyyy-MM-dd HH:mm').format(
                                      DateTime.fromMillisecondsSinceEpoch(
                                          notice.occurredAt)),
                                  style: const TextStyle(
                                      color: muted, fontSize: 12)),
                            ]),
                        const SizedBox(height: 10),
                        Text(notice.description,
                            style: const TextStyle(color: muted)),
                        const SizedBox(height: 8),
                        Text(
                            '申请 ${notice.requestId.substring(0, 8)} · 变更版本 ${notice.requestVersion}',
                            style: const TextStyle(fontSize: 12, color: muted)),
                        const SizedBox(height: 14),
                        Wrap(spacing: 12, runSpacing: 8, children: [
                          OutlinedButton.icon(
                              onPressed: busy
                                  ? null
                                  : () => read(notice.unread ? [notice.id] : [],
                                      requestId: notice.requestId,
                                      owner: repository),
                              icon: const Icon(Icons.open_in_new, size: 17),
                              label: const Text('查看当前申请')),
                          if (notice.unread)
                            TextButton(
                                onPressed:
                                    busy
                                        ? null
                                        : () => read([notice.id], owner: repository),
                                child: const Text('标为已读')),
                        ]),
                      ]))),
      ],
      if (data != null || cursors.length > 1)
        Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('第 ${cursors.length} 页 · 每页最多 20 条',
                      style: const TextStyle(color: muted, fontSize: 12)),
                  TextButton(
                      onPressed: busy || cursors.length == 1
                          ? null
                          : () => firstPage(owner: repository),
                      child: const Text('返回首页')),
                  OutlinedButton(
                      onPressed: busy || cursors.length == 1
                          ? null
                          : () {
                              if (!current(repository)) return;
                              cursors.removeLast();
                              load(owner: repository);
                            },
                      child: const Text('上一页')),
                  OutlinedButton(
                      onPressed: busy || data?.page.nextCursor == null
                          ? null
                          : () {
                              if (!current(repository)) return;
                              if (cursors.contains(data!.page.nextCursor)) {
                                setState(() {
                                  error = const ApiFailure(
                                      502, 'INVALID_NOTIFICATION_RESPONSE');
                                  retry = () => firstPage(owner: repository);
                                });
                                return;
                              }
                              cursors.add(data.page.nextCursor);
                              load(owner: repository);
                            },
                      child: const Text('下一页')),
                ])),
    ]);
  }
}
