import 'package:flutter/material.dart';
import '../core/help_attention.dart';
import '../core/paged_collection.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';

/// Mobile attention inbox with server-side filtering and bounded pagination.
class ParentHelpCenter extends StatefulWidget {
  final ParentSession session;
  final HelpAttentionStore? store;
  const ParentHelpCenter({super.key, required this.session, this.store});
  @override
  State<ParentHelpCenter> createState() => _ParentHelpCenterState();
}

class _ParentHelpCenterState extends State<ParentHelpCenter>
    with WidgetsBindingObserver {
  late final String tenant, actor, role;
  late final HelpAttentionStore store;
  PagedCollection? collection;
  String filter = 'OPEN';
  Json? pending;
  Object? recoveryError;
  bool foreground = true;
  int epoch = 0;
  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.canSeeHelp &&
      widget.session.tenant?['id'] == tenant &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;
  @override
  void initState() {
    super.initState();
    tenant = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    store = widget.store ?? HelpAttentionStore();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    widget.session.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    reload();
  }

  void changed() {
    if (!mounted || current) return;
    epoch++;
    collection?.dispose();
    collection = null;
    pending = null;
    recoveryError = null;
    setState(() {});
  }

  Future<void> reload() async {
    if (!current || !foreground) return;
    final generation = ++epoch;
    collection?.dispose();
    pending = null;
    recoveryError = null;
    collection = PagedCollection(widget.session.api,
        '/tenants/$tenant/help-requests${filter == 'ALL' ? '' : '?state=$filter'}',
        pageSize: 20,
        isCurrent: () => current && foreground && epoch == generation,
        validateItem: (raw) {
          final value = parseHelp(raw);
          if (filter != 'ALL' && value.state != filter) {
            throw const ParentApiException(502, 'INVALID_HELP_RESPONSE');
          }
        });
    setState(() {});
    try {
      final value = await store.load(tenant, actor);
      if (current && foreground && generation == epoch) {
        setState(() => pending = value);
      }
    } catch (e) {
      if (current && foreground && generation == epoch) {
        setState(() => recoveryError = e);
      }
    }
  }

  Future<void> open(String id) async {
    if (!current || !foreground) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ParentHelpDetailPage(
            session: widget.session, id: id, store: store)));
    if (current && foreground) await reload();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    epoch++;
    collection?.dispose();
    collection = null;
    pending = null;
    recoveryError = null;
    if (mounted) setState(() {});
    if (foreground && current) reload();
  }

  @override
  void dispose() {
    epoch++;
    widget.session.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    collection?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!current || !foreground) return const Center(child: Text('求助内容已隐藏。'));
    final list = collection;
    if (list == null) {
      return Center(
          child:
              OutlinedButton(onPressed: reload, child: const Text('重新读取求助')));
    }
    return AnimatedBuilder(
        animation: list,
        builder: (context, _) {
          final items = list.items;
          return RefreshIndicator(
              onRefresh: reload,
              child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(20),
                  itemCount: items.length + 2,
                  itemBuilder: (context, index) {
                    if (index == items.length + 1) {
                      return Column(children: [
                        if (list.loadingMore) const LinearProgressIndicator(),
                        if (list.hasMore)
                          TextButton(
                              onPressed:
                                  list.loadingMore ? null : list.loadMore,
                              child: const Text('加载更多求助')),
                        const SizedBox(height: 16),
                        const Text('这里不是紧急救援服务。遇到即时危险，请通过现实渠道立即寻求帮助。'),
                      ]);
                    }
                    if (index > 0) {
                      final raw = items[index - 1];
                      return _HelpCard(
                          value: parseHelp(raw), onTap: () => open(raw['id']));
                    }
                    return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(
                                child: Text('孩子的求助',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall)),
                            IconButton(
                                tooltip: '刷新求助',
                                onPressed: list.loading ? null : reload,
                                icon: const Icon(Icons.refresh))
                          ]),
                          const Text('先查看，再尽快联系孩子；已看到不代表问题已解决。'),
                          const SizedBox(height: 16),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final option in const {
                              'OPEN': '待查看',
                              'ACKNOWLEDGED': '已查看',
                              'ALL': '全部'
                            }.entries)
                              ChoiceChip(
                                  label: Text(option.value),
                                  selected: filter == option.key,
                                  onSelected: (_) {
                                    filter = option.key;
                                    reload();
                                  })
                          ]),
                          const SizedBox(height: 12),
                          if (pending != null)
                            Card(
                                color: const Color(0xFFFFF4DC),
                                child: ListTile(
                                    leading: const Icon(Icons.pending_actions),
                                    title: const Text('有一条确认结果待核对'),
                                    subtitle: const Text('打开原记录即可核对，不会重复提交。'),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () => open(pending!['id']))),
                          if (recoveryError != null)
                            Text('待核对提醒暂时无法读取：$recoveryError'),
                          if (list.loading) const LinearProgressIndicator(),
                          if (list.error != null)
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                child: Text('${list.error}')),
                          if (list.loaded && list.items.isEmpty)
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 28),
                                child: Text(filter == 'OPEN'
                                    ? '暂无待查看求助。已查看记录可在上方切换查看。'
                                    : '此范围暂无求助记录。')),
                        ]);
                  }));
        });
  }
}

class _HelpCard extends StatelessWidget {
  final HelpAttention value;
  final VoidCallback onTap;
  const _HelpCard({required this.value, required this.onTap});
  @override
  Widget build(BuildContext context) => Card(
          child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: Icon(value.state == 'OPEN'
            ? Icons.support_agent
            : Icons.mark_chat_read_outlined),
        title: Text(value.subjectNickname ?? '孩子'),
        subtitle: Text(
            '${value.reason}\n${_time(value.createdAt)} · ${value.state == 'OPEN' ? '待查看' : '已看到'}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ));
}

/// Confirmation is inline, so another account or a background transition cannot
/// leave a detached acknowledgement dialog operating on the wrong workspace.
class ParentHelpDetailPage extends StatefulWidget {
  final ParentSession session;
  final String id;
  final HelpAttentionStore? store;
  const ParentHelpDetailPage(
      {super.key, required this.session, required this.id, this.store});
  @override
  State<ParentHelpDetailPage> createState() => _ParentHelpDetailPageState();
}

class _ParentHelpDetailPageState extends State<ParentHelpDetailPage>
    with WidgetsBindingObserver {
  late final String tenant, actor, role;
  late final ParentHelpDetail detail;
  bool foreground = true, confirmed = false, checked = false;
  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.canSeeHelp &&
      widget.session.tenant?['id'] == tenant &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;
  @override
  void initState() {
    super.initState();
    tenant = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    detail = ParentHelpDetail(
        api: widget.session.api,
        store: widget.store ?? HelpAttentionStore(),
        tenant: tenant,
        actor: actor,
        id: widget.id,
        isCurrent: () => current,
        foreground: () => foreground);
    widget.session.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    detail.load();
  }

  void changed() {
    if (!mounted || current) return;
    detail.hide();
    confirmed = false;
    checked = false;
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    confirmed = false;
    checked = false;
    if (!foreground) detail.hide();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    detail.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    confirmed = false;
    checked = false;
    await detail.load();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: detail,
      builder: (context, _) {
        final value = detail.request;
        final editable = current && foreground && !detail.busy;
        return PopScope(
            canPop: !detail.busy,
            child: Scaffold(
                appBar: AppBar(title: const Text('求助详情')),
                body: !current || !foreground
                    ? const Center(child: Text('求助内容已隐藏，返回后请重新读取。'))
                    : Center(
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 680),
                            child: ListView(
                                padding: const EdgeInsets.all(20),
                                children: [
                                  if (detail.busy)
                                    const LinearProgressIndicator(),
                                  if (detail.error != null)
                                    Semantics(
                                        liveRegion: true,
                                        child: Text('${detail.error}')),
                                  if (value != null) ...[
                                    Text(value.subjectNickname ?? '孩子',
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineMedium),
                                    const SizedBox(height: 12),
                                    Text(value.reason,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge),
                                    const SizedBox(height: 16),
                                    Card(
                                        color: value.state == 'OPEN'
                                            ? const Color(0xFFFFF4DC)
                                            : const Color(0xFFEAF2F8),
                                        child: Padding(
                                            padding: const EdgeInsets.all(18),
                                            child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                      value.state == 'OPEN'
                                                          ? '等待成人查看'
                                                          : '已有成人确认看到',
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleMedium),
                                                  const SizedBox(height: 8),
                                                  Text(
                                                      '提交时间：${_time(value.createdAt)}'),
                                                  if (value.acknowledgedAt !=
                                                      null)
                                                    Text(
                                                        '确认时间：${_time(value.acknowledgedAt!)}'),
                                                ]))),
                                    const SizedBox(height: 12),
                                    const Text(
                                        '请通过现实渠道联系孩子，了解情况并提供帮助。页面上的“已看到”只是一条确认记录。'),
                                    ExpansionTile(
                                        title: const Text('记录详情'),
                                        children: [
                                          ListTile(
                                              title: SelectableText(
                                                  '求助编号：${value.id}'),
                                              subtitle: SelectableText(
                                                  '设备编号：${value.deviceId}\n记录版本：${value.version}'))
                                        ]),
                                  ],
                                  if (detail.pending != null) ...[
                                    const SizedBox(height: 12),
                                    const Text(
                                        '原确认操作已保留，请先核对结果。查询与重新打开都不会重复提交。'),
                                    if (detail.pending!['id'] != widget.id)
                                      const Text('待核对的是另一条求助，请返回求助列表打开顶部提醒。'),
                                    if (detail.queried &&
                                        detail.pending!['id'] == widget.id) ...[
                                      CheckboxListTile(
                                          contentPadding: EdgeInsets.zero,
                                          value: checked,
                                          title: const Text('我已核对原记录和当前状态'),
                                          subtitle: const Text(
                                              '清除本机提醒不会撤销“已看到”。查不到记录也不代表当时未确认。'),
                                          onChanged: editable
                                              ? (v) => setState(
                                                  () => checked = v == true)
                                              : null),
                                      FilledButton(
                                          onPressed: editable && checked
                                              ? () async {
                                                  await detail.clearPending();
                                                  if (current &&
                                                      foreground &&
                                                      detail.pending == null) {
                                                    await refresh();
                                                  }
                                                }
                                              : null,
                                          child: const Text('完成核对')),
                                    ],
                                  ] else if (value?.state == 'OPEN') ...[
                                    CheckboxListTile(
                                        contentPadding: EdgeInsets.zero,
                                        value: confirmed,
                                        title: const Text('我已看到这条求助，会尽快联系孩子'),
                                        onChanged: editable && detail.loaded
                                            ? (v) => setState(
                                                () => confirmed = v == true)
                                            : null),
                                    FilledButton.icon(
                                        onPressed: editable &&
                                                confirmed &&
                                                detail.loaded
                                            ? detail.acknowledge
                                            : null,
                                        icon: const Icon(
                                            Icons.mark_chat_read_outlined),
                                        label: const Text('确认已看到')),
                                  ],
                                  const SizedBox(height: 12),
                                  OutlinedButton.icon(
                                      onPressed: editable ? refresh : null,
                                      icon: const Icon(Icons.refresh),
                                      label: Text(
                                          detail.pending?['id'] == widget.id
                                              ? '只查询原记录'
                                              : '刷新当前记录')),
                                  if (detail.error is ParentApiException &&
                                      (detail.error as ParentApiException)
                                              .status ==
                                          401)
                                    TextButton(
                                        onPressed: editable &&
                                                !widget.session.busy
                                            ? () async {
                                                if (await widget.session
                                                        .reauthenticate() &&
                                                    current &&
                                                    foreground) await refresh();
                                              }
                                            : null,
                                        child: const Text('重新验证并查询')),
                                ])))));
      });
}

String _time(int value) {
  final d = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
