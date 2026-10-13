import 'package:flutter/material.dart';
import '../core/device_groups.dart';
import '../core/paged_collection.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import 'group_operation_page.dart';

class DeviceGroupCenter extends StatefulWidget {
  final ParentSession session;
  const DeviceGroupCenter({super.key, required this.session});
  @override
  State<DeviceGroupCenter> createState() => _DeviceGroupCenterState();
}

class _DeviceGroupCenterState extends State<DeviceGroupCenter> with GroupScope {
  @override
  ParentSession get session => widget.session;
  late PagedCollection groups;
  bool archived = false, navigating = false;
  @override
  void initState() {
    super.initState();
    groups = _collection();
  }

  PagedCollection _collection() => PagedCollection(
      session.api, '/tenants/$tenant/device-groups?includeArchived=$archived');
  @override
  void dispose() {
    groups.dispose();
    super.dispose();
  }

  Future<void> _open(String id) async {
    if (!current || navigating) return;
    setState(() => navigating = true);
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DeviceGroupDetail(session: session, id: id)));
    if (current) {
      setState(() => navigating = false);
      await groups.reload();
    }
  }

  Future<void> _create() async {
    if (!current || navigating) return;
    setState(() => navigating = true);
    final value = await Navigator.of(context).push<Json>(MaterialPageRoute(
        builder: (_) => GroupOperationPage(
            session: session, input: const {'operation': 'CREATE'})));
    if (!current) return;
    setState(() => navigating = false);
    if (value != null) await _open(value['id']);
    if (current) await groups.reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('机构设备组'), actions: [
        TextButton.icon(
            onPressed: navigating ? null : _create,
            icon: const Icon(Icons.add),
            label: const Text('新建 / 恢复'))
      ]),
      body: AnimatedBuilder(
          animation: groups,
          builder: (context, _) => RefreshIndicator(
              onRefresh: groups.reload,
              child: ListView(padding: const EdgeInsets.all(20), children: [
                Text('按班级与用途整理设备',
                    style: Theme.of(context).textTheme.headlineSmall),
                const Text('维护成员后，在策略中选择当前组快照。组变化不会自动扩展已保存的策略。'),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('包含已归档设备组'),
                    value: archived,
                    onChanged: navigating
                        ? null
                        : (v) {
                            setState(() {
                              archived = v;
                              groups.dispose();
                              groups = _collection();
                            });
                          }),
                ..._pageStatus(groups),
                if (groups.loaded && groups.items.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('还没有设备组，可从右上角新建。')),
                for (final group in groups.items)
                  Card(
                      child: ListTile(
                          title: Text(group['name'] ?? '未命名设备组'),
                          subtitle: Text(
                              '${group['state'] == 'ARCHIVED' ? '已归档' : '可维护'} · ${group['deviceCount']} 条成员记录 · 修订 ${group['version']}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: navigating ? null : () => _open(group['id']))),
                if (groups.hasMore)
                  TextButton(
                      onPressed: groups.loadingMore ? null : groups.loadMore,
                      child: const Text('加载更多设备组')),
              ]))));
}

List<Widget> _pageStatus(PagedCollection page) => [
      if (page.loading || page.loadingMore) const LinearProgressIndicator(),
      if (page.error != null) ...[
        Text('${page.error}'),
        OutlinedButton(onPressed: page.reload, child: const Text('重新读取'))
      ],
    ];

class DeviceGroupDetail extends StatefulWidget {
  final ParentSession session;
  final String id;
  const DeviceGroupDetail({super.key, required this.session, required this.id});
  @override
  State<DeviceGroupDetail> createState() => _DeviceGroupDetailState();
}

class _DeviceGroupDetailState extends State<DeviceGroupDetail> with GroupScope {
  @override
  ParentSession get session => widget.session;
  late Future<Json> group;
  late PagedCollection members;
  String filter = '';
  bool busy = false;
  @override
  void initState() {
    super.initState();
    group = _load();
    members = _members();
  }

  Future<Json> _load() async => readDeviceGroup(
      await session.api.object('/tenants/$tenant/device-groups/${widget.id}',
          isCurrent: () => current),
      id: widget.id);
  PagedCollection _members() => PagedCollection(session.api,
      '/tenants/$tenant/device-groups/${widget.id}/devices${filter.isEmpty ? '' : '?status=$filter'}',
      idField: 'deviceId');
  @override
  void dispose() {
    members.dispose();
    super.dispose();
  }

  void _refresh() {
    if (current) {
      setState(() => group = _load());
      members.reload();
    }
  }

  Future<void> _action(Json value, String op) async {
    if (!current || busy) return;
    setState(() => busy = true);
    try {
      List<Json>? devices;
      if (op == 'ADD' || op == 'REMOVE') {
        devices = await Navigator.of(context).push<List<Json>>(
            MaterialPageRoute(
                builder: (_) => GroupMemberPicker(
                    session: session,
                    groupId: widget.id,
                    removing: op == 'REMOVE')));
        if (!current || devices == null || devices.isEmpty) return;
      }
      if (!mounted || !current) return;
      final result = await Navigator.of(context).push<Json>(MaterialPageRoute(
          builder: (_) => GroupOperationPage(
                  session: session,
                  groupName: value['name'],
                  targetNames: {
                    for (final d in devices ?? <Json>[])
                      d['deviceId']:
                          d['displayName'] as String? ?? d['deviceId']
                  },
                  input: {
                    'operation': op,
                    'groupId': widget.id,
                    'version': value['version'],
                    if (op == 'RENAME') 'name': value['name'],
                    if (devices != null)
                      'devices': [
                        for (final d in devices)
                          {
                            'deviceId': d['deviceId'],
                            'registrationId': d['registrationId']
                          }
                      ],
                  })));
      if (!mounted || !current) return;
      // An earlier pending operation can refer to another group; never render it as this one.
      if (result != null && result['id'] != widget.id) {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                DeviceGroupDetail(session: session, id: result['id'])));
      }
      _refresh();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('设备组详情'), actions: [
        IconButton(
            onPressed: busy ? null : _refresh,
            tooltip: '刷新设备组',
            icon: const Icon(Icons.refresh))
      ]),
      body: FutureBuilder<Json>(
          future: group,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${snap.error}'),
                TextButton(onPressed: _refresh, child: const Text('重新读取'))
              ]));
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final value = snap.data!;
            return AnimatedBuilder(
                animation: members,
                builder: (context, _) =>
                    ListView(padding: const EdgeInsets.all(20), children: [
                      Text(value['name'],
                          style: Theme.of(context).textTheme.headlineSmall),
                      Text(
                          '修订 ${value['version']} · ${value['deviceCount']} 条成员记录${value['state'] == 'ARCHIVED' ? ' · 已归档' : ''}'),
                      const Text('目录成员不代表设备在线或规则已执行。移出与归档不会撤销设备注册或已发布配置。'),
                      if (value['state'] == 'ACTIVE')
                        Wrap(spacing: 8, children: [
                          for (final op in [
                            'ADD',
                            'REMOVE',
                            'RENAME',
                            'ARCHIVE'
                          ])
                            OutlinedButton(
                                onPressed:
                                    busy ? null : () => _action(value, op),
                                child: Text(groupOperations[op]!)),
                        ]),
                      DropdownButtonFormField<String>(
                          isExpanded: true,
                          value: filter,
                          decoration: const InputDecoration(labelText: '成员状态'),
                          items: [
                            const DropdownMenuItem(
                                value: '', child: Text('全部成员')),
                            for (final e in groupMemberStates.entries)
                              DropdownMenuItem(
                                  value: e.key, child: Text(e.value))
                          ],
                          onChanged: busy
                              ? null
                              : (v) {
                                  if (v != null) {
                                    setState(() {
                                      filter = v;
                                      members.dispose();
                                      members = _members();
                                    });
                                  }
                                }),
                      ..._pageStatus(members),
                      if (members.loaded && members.items.isEmpty)
                        const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('没有符合条件的成员。')),
                      for (final d in members.items)
                        ListTile(
                            title: Text(d['displayName'] ?? d['deviceId']),
                            subtitle: Text(
                                '${groupMemberStates[d['membershipStatus']] ?? '状态未知'} · ${d['platform']}\n设备：${d['deviceId']}\n注册周期：${d['registrationId']}')),
                      if (members.hasMore)
                        TextButton(
                            onPressed:
                                members.loadingMore ? null : members.loadMore,
                            child: const Text('加载更多成员')),
                    ]));
          }));
}

class GroupMemberPicker extends StatefulWidget {
  final ParentSession session;
  final String groupId;
  final bool removing;
  const GroupMemberPicker(
      {super.key,
      required this.session,
      required this.groupId,
      required this.removing});
  @override
  State<GroupMemberPicker> createState() => _GroupMemberPickerState();
}

class _GroupMemberPickerState extends State<GroupMemberPicker> with GroupScope {
  @override
  ParentSession get session => widget.session;
  late final PagedCollection devices;
  final selected = <String, Json>{};
  @override
  void initState() {
    super.initState();
    devices = PagedCollection(
        session.api,
        widget.removing
            ? '/tenants/$tenant/device-groups/${widget.groupId}/devices'
            : '/tenants/$tenant/devices',
        idField: widget.removing ? 'deviceId' : 'id');
  }

  @override
  void dispose() {
    devices.dispose();
    super.dispose();
  }

  String _id(Json d) => d[widget.removing ? 'deviceId' : 'id'];
  bool _valid(Json d) =>
      groupUuid(d[widget.removing ? 'deviceId' : 'id']) &&
      groupUuid(d['registrationId']) &&
      (widget.removing || d['state'] == 'ACTIVE');
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar:
          AppBar(title: Text(widget.removing ? '选择移出成员' : '选择加入设备'), actions: [
        TextButton(
            onPressed: () {
              setState(selected.clear);
              devices.reload();
            },
            child: const Text('刷新并清空'))
      ]),
      bottomNavigationBar: SafeArea(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                  onPressed: selected.isEmpty || !current
                      ? null
                      : () => Navigator.pop(context, selected.values.toList()),
                  child: Text('核对所选 ${selected.length} 台')))),
      body: AnimatedBuilder(
          animation: devices,
          builder: (context, _) =>
              ListView(padding: const EdgeInsets.all(20), children: [
                const Text('每次最多 50 台，保留明确设备和注册周期。服务端在提交时再次校验。'),
                if (widget.removing) const Text('可移出失效注册或归档档案的关联；不会注销设备。'),
                ..._pageStatus(devices),
                if (devices.loaded && devices.items.isEmpty)
                  const Text('当前没有可选记录。'),
                for (final d in devices.items)
                  CheckboxListTile(
                      value: selected.containsKey(_id(d)),
                      title: Text(d['displayName'] ?? _id(d)),
                      subtitle: Text(
                          '${widget.removing ? groupMemberStates[d['membershipStatus']] ?? '未知状态' : d['state']}\n设备：${_id(d)}\n注册周期：${d['registrationId']}'),
                      onChanged: !_valid(d) ||
                              selected.length >= 50 &&
                                  !selected.containsKey(_id(d))
                          ? null
                          : (v) => setState(() {
                                if (v == true) {
                                  selected[_id(d)] = {
                                    'deviceId': _id(d),
                                    'registrationId': d['registrationId'],
                                    'displayName': d['displayName'],
                                  };
                                } else {
                                  selected.remove(_id(d));
                                }
                              })),
                if (devices.hasMore)
                  TextButton(
                      onPressed: devices.loadingMore ? null : devices.loadMore,
                      child: const Text('加载更多设备')),
              ])));
}
