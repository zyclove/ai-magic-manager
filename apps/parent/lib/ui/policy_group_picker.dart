import 'package:flutter/material.dart';

import '../core/paged_collection.dart';
import '../core/parent_session.dart';
import '../core/policy_group_selection.dart';

class PolicyGroupPicker extends StatefulWidget {
  final ParentSession session;
  const PolicyGroupPicker({super.key, required this.session});
  @override
  State<PolicyGroupPicker> createState() => _PolicyGroupPickerState();
}

class _PolicyGroupPickerState extends State<PolicyGroupPicker> {
  late final String tenant, actor, role;
  late final PagedCollection groups;
  bool busy = false, confirming = false;
  Object? error;
  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenant &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role &&
      widget.session.tenant?['kind'] == 'ORGANIZATION' &&
      const {'OWNER', 'ORG_ADMIN'}.contains(role);
  @override
  void initState() {
    super.initState();
    tenant = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    groups =
        PagedCollection(widget.session.api, '/tenants/$tenant/device-groups');
    widget.session.addListener(_scopeChanged);
  }

  void _scopeChanged() {
    if (!mounted || current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    widget.session.removeListener(_scopeChanged);
    groups.dispose();
    super.dispose();
  }

  Future<void> _select(String id) async {
    if (!current || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final selected = await PolicyGroupSelection.load(
          widget.session.api, tenant, id, () => current);
      if (!mounted || !current) return;
      setState(() => confirming = true);
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: Text('选择“${selected.name}”？'),
                  content: Text(
                      '修订 ${selected.version}，共 ${selected.registrations.length} 台当前有效设备。\n'
                      '${selected.excludedCount} 条失效或不可用成员记录不纳入。将替换当前设备选择，后续组变化不会自动扩展这次策略。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('返回')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('使用此组快照'))
                  ]));
      if (confirmed != true || !current) return;
      setState(() => busy = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (current) Navigator.pop(context, selected);
      });
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          confirming = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('选择设备组'), actions: [
          IconButton(
              tooltip: '刷新设备组',
              onPressed: busy ? null : groups.reload,
              icon: const Icon(Icons.refresh)),
        ]),
        body: AnimatedBuilder(
            animation: groups,
            builder: (context, _) =>
                ListView(padding: const EdgeInsets.all(20), children: [
                  const Text('选择一组当前有效设备',
                      style:
                          TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  const Text(
                      '每次完整选择最多 50 台。更大的组请先在管理台拆分；不会只取前 50 台。分组维护在完整管理台进行。'),
                  if (busy && !confirming ||
                      !groups.loaded && groups.error == null)
                    const LinearProgressIndicator(),
                  if (error != null)
                    Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text('$error',
                            style: const TextStyle(color: Color(0xFF9A3931)))),
                  if (groups.error != null) ...[
                    Text('${groups.error}'),
                    OutlinedButton(
                        onPressed: busy ? null : groups.reload,
                        child: const Text('重新读取设备组'))
                  ],
                  if (groups.loaded && groups.items.isEmpty)
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('尚无设备组，请先在机构管理台创建并添加设备。')),
                  for (final group in groups.items)
                    Card(
                        child: ListTile(
                            title: Text(group['name'] is String
                                ? group['name']
                                : '未命名设备组'),
                            subtitle: Text(
                                '成员记录 ${group['deviceCount'] ?? '—'} 条 · 修订 ${group['version'] ?? '—'}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: busy ||
                                    group['state'] != 'ACTIVE' ||
                                    group['id'] is! String
                                ? null
                                : () => _select(group['id']))),
                  if (groups.hasMore)
                    TextButton(
                        onPressed:
                            busy || groups.loadingMore ? null : groups.loadMore,
                        child: const Text('加载更多设备组')),
                ])),
      ));
}
