import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/paged_collection.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import '../core/pending_publications.dart';

const _ink = Color(0xFF17324B);
const _muted = Color(0xFF315E86);

/// Returns only the exact committed result for the current creator/key/body.
/// A missing journal entry is inconclusive and must never trigger an auto POST.
Future<Json?> _publicationResult(
    ParentApi api, String tenantId, PendingPublication marker) async {
  final query = Uri(queryParameters: {
    'revision': '${marker.revision}',
    'previewId': marker.previewId,
    'previewHash': marker.previewHash,
  }).query;
  try {
    final result = await api.object(
        '/tenants/$tenantId/policies/${marker.policyId}/publication-results/${marker.idempotencyKey}?$query');
    if (result['id'] is! String ||
        result['versionId'] is! String ||
        result['sequence'] is! int ||
        result['mode'] != 'CONFIGURE_ONLY' ||
        result['state'] != 'CONFIGURED_NOT_ENFORCED') {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return result;
  } on ParentApiException catch (failure) {
    if (failure.status == 404 &&
        failure.code == 'POLICY_PUBLICATION_RESULT_UNAVAILABLE') return null;
    rethrow;
  }
}

/// Mobile policy preview and CONFIGURE_ONLY publication. A preview never
/// changes Android settings, and a saved configuration is not enforcement.
Future<void> showPolicyCenter(BuildContext context, ParentSession session) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => PolicyCenter(session: session),
  ));
}

class PolicyCenter extends StatefulWidget {
  final ParentSession session;
  const PolicyCenter({super.key, required this.session});

  @override
  State<PolicyCenter> createState() => _PolicyCenterState();
}

class _PolicyCenterState extends State<PolicyCenter> {
  late final String tenantId;
  late final String actor;
  late final String role;
  late final PagedCollection policies;
  final publicationStore = PendingPublicationStore();
  List<PendingPublication> recoveries = const [];
  final recoveryStatus = <String, String>{};
  final checkedRecoveries = <String>{};
  bool recoveryBusy = false;
  Object? recoveryError;

  @override
  void initState() {
    super.initState();
    tenantId = widget.session.tenant!['id'] as String;
    actor = widget.session.profile!['subject'] as String;
    role = widget.session.role;
    policies =
        PagedCollection(widget.session.api, '/tenants/$tenantId/policies');
    widget.session.addListener(_closeIfScopeChanged);
    _loadRecoveries();
  }

  bool get _current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenantId &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;

  void _closeIfScopeChanged() {
    if (!mounted || _current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _current) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  Future<void> _loadRecoveries() async {
    if (!widget.session.canDecide) return;
    try {
      final rows = await publicationStore.load(tenantId, actor);
      if (_current) {
        setState(() {
          recoveries = rows;
          recoveryError = null;
          checkedRecoveries.removeWhere(
              (key) => !rows.any((row) => row.idempotencyKey == key));
        });
      }
    } catch (failure) {
      if (_current) setState(() => recoveryError = failure);
    }
  }

  Future<void> _checkRecovery(PendingPublication marker) async {
    if (!_current || recoveryBusy) return;
    setState(() => recoveryBusy = true);
    try {
      final result =
          await _publicationResult(widget.session.api, tenantId, marker);
      if (!_current) return;
      setState(() {
        checkedRecoveries.add(marker.idempotencyKey);
        recoveryStatus[marker.idempotencyKey] = result == null
            ? '未找到可读取的原提交结果。这不能证明配置没有保存；请到管理台核对版本后决定是否清除提醒。'
            : '原提交已保存为配置版本 ${result['sequence']}，状态：仅配置、未执行。操作编号：${result['id']}。';
      });
    } catch (failure) {
      if (_current) setState(() => recoveryError = failure);
    } finally {
      if (_current) setState(() => recoveryBusy = false);
    }
  }

  Future<void> _clearRecovery(PendingPublication marker) async {
    if (!_current ||
        recoveryBusy ||
        !checkedRecoveries.contains(marker.idempotencyKey)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除本机发布提醒？'),
        content: const Text('这只清除本机的待核对记录，不会创建、撤销或执行策略配置。请先核对原发布结果。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('已核对，清除提醒')),
        ],
      ),
    );
    if (confirmed != true ||
        !_current ||
        recoveryBusy ||
        !checkedRecoveries.contains(marker.idempotencyKey)) return;
    setState(() => recoveryBusy = true);
    try {
      await publicationStore.remove(tenantId, actor, marker.idempotencyKey);
      if (!_current) return;
      setState(() {
        recoveries = recoveries
            .where((row) => row.idempotencyKey != marker.idempotencyKey)
            .toList();
        recoveryStatus.remove(marker.idempotencyKey);
        checkedRecoveries.remove(marker.idempotencyKey);
      });
    } catch (failure) {
      if (_current) setState(() => recoveryError = failure);
    } finally {
      if (_current) setState(() => recoveryBusy = false);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_closeIfScopeChanged);
    policies.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !recoveryBusy,
        child: Scaffold(
          appBar: AppBar(title: const Text('策略中心')),
          body: AnimatedBuilder(
            animation: policies,
            builder: (context, _) {
              if (!policies.loaded && policies.error != null) {
                return _error(policies.error!, policies.reload);
              }
              if (!policies.loaded) {
                return const Center(child: CircularProgressIndicator());
              }
              return RefreshIndicator(
                onRefresh: () async {
                  if (recoveryBusy) return;
                  await _loadRecoveries();
                  await policies.reload();
                },
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text('策略草稿与模板',
                        style:
                            Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  color: _ink,
                                  fontWeight: FontWeight.w700,
                                )),
                    const SizedBox(height: 7),
                    const Text('先选择草稿，再核对目标设备和逐项规则。预览不会改变设备设置。',
                        style: TextStyle(color: _muted)),
                    const SizedBox(height: 18),
                    if (recoveryError != null)
                      Text('$recoveryError',
                          style: const TextStyle(color: Color(0xFF9A3931))),
                    if (recoveries.isNotEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('存在尚未核对的配置发布。客户端不会自动重复提交；先查询原结果。'),
                        ),
                      ),
                    for (final marker in recoveries)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('待核对的配置发布',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w700)),
                              SelectableText('策略编号：${marker.policyId}'),
                              Text('提交时间：${_time(marker.createdAt)}'),
                              if (recoveryStatus[marker.idempotencyKey] != null)
                                Text(recoveryStatus[marker.idempotencyKey]!),
                              Wrap(spacing: 8, children: [
                                OutlinedButton(
                                  onPressed: recoveryBusy
                                      ? null
                                      : () => _checkRecovery(marker),
                                  child: const Text('查询原发布结果'),
                                ),
                                TextButton(
                                  onPressed: recoveryBusy ||
                                          !checkedRecoveries
                                              .contains(marker.idempotencyKey)
                                      ? null
                                      : () => _clearRecovery(marker),
                                  child: const Text('已核对'),
                                ),
                              ]),
                            ],
                          ),
                        ),
                      ),
                    if (policies.items.isEmpty)
                      const Card(
                          child: Padding(
                              padding: EdgeInsets.all(20),
                              child: Text('还没有策略。请先在完整管理台创建草稿或模板。'))),
                    for (final row in policies.items)
                      Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 9),
                          leading:
                              const Icon(Icons.shield_outlined, color: _muted),
                          title: Text(_name(row['name'], '未命名策略')),
                          subtitle: Text(
                              '${row['kind'] == 'TEMPLATE' ? '模板 · 需先复制' : '策略草稿'} · ${(row['rules'] as List?)?.length ?? 0} 条规则 · 修订 ${row['revision'] ?? '—'}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap:
                              row['id'] is String && _current && !recoveryBusy
                                  ? () async {
                                      await Navigator.of(context)
                                          .push(MaterialPageRoute<void>(
                                        builder: (_) => _PolicyDetail(
                                            session: widget.session,
                                            policyId: row['id'] as String),
                                      ));
                                      if (_current) await _loadRecoveries();
                                    }
                                  : null,
                        ),
                      ),
                    if (policies.error != null)
                      Text('${policies.error}',
                          style: const TextStyle(color: Color(0xFF9A3931))),
                    if (policies.loadingMore) const LinearProgressIndicator(),
                    if (policies.hasMore)
                      TextButton.icon(
                        onPressed:
                            policies.loadingMore ? null : policies.loadMore,
                        icon: const Icon(Icons.expand_more),
                        label: const Text('加载更多策略'),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      );
}

class _PolicyDetail extends StatefulWidget {
  final ParentSession session;
  final String policyId;
  const _PolicyDetail({required this.session, required this.policyId});

  @override
  State<_PolicyDetail> createState() => _PolicyDetailState();
}

class _PolicyDetailState extends State<_PolicyDetail> {
  late final String tenantId;
  late final String actor;
  late final String role;
  PagedCollection? devices;
  late Future<Json> draft;
  final selected = <String, String>{};
  final selectedNames = <String, String>{};
  final publicationStore = PendingPublicationStore();
  List<PendingPublication> markers = const [];
  bool journalLoaded = false;
  Json? preview;
  Json? publication;
  bool busy = false;
  Object? actionError;

  @override
  void initState() {
    super.initState();
    tenantId = widget.session.tenant!['id'] as String;
    actor = widget.session.profile!['subject'] as String;
    role = widget.session.role;
    if (widget.session.canDecide) {
      devices =
          PagedCollection(widget.session.api, '/tenants/$tenantId/devices');
    }
    widget.session.addListener(_closeIfScopeChanged);
    draft = _readDraft();
    _loadJournal();
  }

  bool get _current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenantId &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;

  void _closeIfScopeChanged() {
    if (!mounted || _current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _current) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  Future<void> _loadJournal() async {
    if (!widget.session.canDecide) return;
    if (_current) setState(() => journalLoaded = false);
    try {
      final rows = await publicationStore.load(tenantId, actor);
      if (_current) {
        setState(() {
          markers = rows;
          journalLoaded = true;
        });
      }
    } catch (failure) {
      if (_current) setState(() => actionError = failure);
    }
  }

  Future<Json> _readDraft() async {
    final result = await widget.session.api
        .object('/tenants/$tenantId/policies/${widget.policyId}');
    if (result['id'] != widget.policyId ||
        result['name'] is! String ||
        result['revision'] is! int ||
        result['rules'] is! List ||
        !const {'POLICY', 'TEMPLATE'}.contains(result['kind'])) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return result;
  }

  void _reload() {
    if (busy) return;
    setState(() {
      preview = null;
      publication = null;
      actionError = null;
      selected.clear();
      selectedNames.clear();
      draft = _readDraft();
    });
    devices?.reload();
  }

  void _toggleDevice(Json row) {
    final id = row['id'];
    final registration = row['registrationId'];
    if (busy || id is! String) return;
    setState(() {
      preview = null;
      actionError = null;
      if (selected.containsKey(id)) {
        selected.remove(id);
        selectedNames.remove(id);
      } else if (registration is String &&
          row['state'] == 'ACTIVE' &&
          selected.length < 50) {
        selected[id] = registration;
        selectedNames[id] = _name(row['displayName'], '未命名设备');
      }
    });
  }

  Future<void> _preview(Json policy) async {
    if (!_current ||
        busy ||
        !widget.session.canDecide ||
        policy['kind'] != 'POLICY' ||
        selected.isEmpty ||
        selected.length > 50) return;
    final revision = policy['revision'];
    if (revision is! int) return;
    final expected = Map<String, String>.from(selected);
    setState(() {
      busy = true;
      actionError = null;
      preview = null;
    });
    try {
      final raw = await widget.session.api.send(
          'POST', '/tenants/$tenantId/policies/${widget.policyId}/previews',
          version: revision,
          body: {'deviceIds': expected.keys.toList()},
          maxResponseBytes: 4 * 1024 * 1024);
      if (!_current) return;
      if (raw is! Json ||
          raw['id'] is! String ||
          !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
              .hasMatch(raw['id'] as String) ||
          raw['policyId'] != widget.policyId ||
          raw['draftRevision'] != revision ||
          raw['phase'] != 'PREVIEW' ||
          raw['hash'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(raw['hash'] as String) ||
          raw['enforceable'] is! bool ||
          raw['targets'] is! List ||
          raw['expiresAt'] is! int ||
          (raw['expiresAt'] as int) <= DateTime.now().millisecondsSinceEpoch ||
          raw['snapshot'] is! Json ||
          (raw['snapshot'] as Json)['groupSelection'] != null) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      final returned = <String, String>{};
      for (final target in raw['targets'] as List) {
        if (target is! Json ||
            target['deviceId'] is! String ||
            target['registrationId'] is! String ||
            target['rules'] is! List ||
            (target['rules'] as List).any((rule) =>
                rule is! Json ||
                rule['kind'] is! String ||
                rule['status'] is! String ||
                (rule['reasonCode'] != null && rule['reasonCode'] is! String) ||
                rule['warnings'] is! List) ||
            returned.containsKey(target['deviceId'])) {
          throw const ParentApiException(502, 'INVALID_RESPONSE');
        }
        returned[target['deviceId'] as String] =
            target['registrationId'] as String;
      }
      if (returned.length != expected.length ||
          expected.entries.any((entry) => returned[entry.key] != entry.value) ||
          selected.length != expected.length ||
          expected.entries.any((entry) => selected[entry.key] != entry.value)) {
        throw const ParentApiException(409, 'RESOURCE_VERSION_CONFLICT');
      }
      setState(() => preview = raw);
    } catch (failure) {
      if (_current) setState(() => actionError = failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _publish(Json policy) async {
    final reviewed = preview;
    if (!_current ||
        busy ||
        !journalLoaded ||
        !widget.session.canDecide ||
        reviewed == null ||
        policy['kind'] != 'POLICY' ||
        reviewed['draftRevision'] != policy['revision'] ||
        reviewed['expiresAt'] is! int ||
        (reviewed['expiresAt'] as int) <=
            DateTime.now().millisecondsSinceEpoch ||
        markers.any((row) => row.policyId == widget.policyId)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('仅保存策略配置？'),
        content:
            Text('将为本次选定的 ${(reviewed['targets'] as List).length} 台设备记录不可变配置版本。'
                '当前服务端尚未开放系统强制执行；保存后应用限制不会因此生效。设备与规则会在提交时重新检查。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续安全验证')),
        ],
      ),
    );
    if (confirmed != true || !_current || busy || preview != reviewed) return;
    final marker = PendingPublication(
      policyId: widget.policyId,
      revision: policy['revision'] as int,
      previewId: reviewed['id'] as String,
      previewHash: reviewed['hash'] as String,
      idempotencyKey: const Uuid().v4(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    var recorded = false;
    var submitted = false;
    setState(() {
      busy = true;
      actionError = null;
    });
    try {
      if (!await widget.session.reauthenticate()) {
        if (_current && widget.session.error != null) {
          setState(() => actionError = widget.session.error);
        }
        return;
      }
      if (!_current) return;
      if ((reviewed['expiresAt'] as int) <=
          DateTime.now().millisecondsSinceEpoch) {
        throw const ParentApiException(409, 'PREVIEW_STALE');
      }
      await publicationStore.add(tenantId, actor, marker);
      recorded = true;
      if (!_current) return;
      setState(() => markers = [...markers, marker]);
      submitted = true;
      final raw = await widget.session.api.send(
          'POST', '/tenants/$tenantId/policies/${widget.policyId}/publications',
          version: marker.revision,
          idempotencyKey: marker.idempotencyKey,
          body: {
            'previewId': marker.previewId,
            'previewHash': marker.previewHash,
            'mode': 'CONFIGURE_ONLY'
          });
      if (raw is! Json ||
          raw['id'] is! String ||
          raw['versionId'] is! String ||
          raw['sequence'] is! int ||
          raw['mode'] != 'CONFIGURE_ONLY' ||
          raw['state'] != 'CONFIGURED_NOT_ENFORCED') {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      await publicationStore.remove(tenantId, actor, marker.idempotencyKey);
      recorded = false;
      if (!_current) return;
      setState(() {
        markers = markers
            .where((row) => row.idempotencyKey != marker.idempotencyKey)
            .toList();
        publication = raw;
        preview = null;
      });
    } catch (failure) {
      if (!_current) return;
      if (submitted &&
          (failure is! ParentApiException ||
              failure.status == 0 ||
              failure.status >= 500 ||
              failure.code == 'REQUEST_IN_PROGRESS' ||
              failure.code == 'IDEMPOTENCY_KEY_CONFLICT')) {
        setState(() {
          actionError = '配置发布结果不明。本机已保留原请求，请返回策略中心查询；客户端不会自动重发。';
          preview = null;
        });
      } else {
        if (recorded) {
          try {
            await publicationStore.remove(
                tenantId, actor, marker.idempotencyKey);
            if (!_current) return;
            setState(() => markers = markers
                .where((row) => row.idempotencyKey != marker.idempotencyKey)
                .toList());
          } catch (_) {
            if (_current) {
              setState(() => actionError = '发布未完成，且本机待核对记录未能清理。请返回策略中心查询原结果。');
            }
            return;
          }
        }
        setState(() {
          actionError = failure;
          preview = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_closeIfScopeChanged);
    devices?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !busy,
        child: Scaffold(
          appBar: AppBar(title: const Text('策略详情与预览')),
          body: FutureBuilder<Json>(
            future: draft,
            builder: (context, snapshot) {
              if (snapshot.hasError) return _error(snapshot.error!, _reload);
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final policy = snapshot.data!;
              return RefreshIndicator(
                onRefresh: () async {
                  _reload();
                  try {
                    await draft;
                  } catch (_) {
                    // The FutureBuilder displays the scoped read failure.
                  }
                },
                child: ListView(padding: const EdgeInsets.all(20), children: [
                  Text(_name(policy['name'], '未命名策略'),
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(color: _ink, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                      '${policy['kind'] == 'TEMPLATE' ? '模板' : '策略草稿'} · 修订 ${policy['revision']} · ${(policy['rules'] as List).length} 条规则',
                      style: const TextStyle(color: _muted)),
                  const SizedBox(height: 16),
                  for (final raw in policy['rules'] as List)
                    if (raw is Json)
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.rule_outlined),
                          title: Text(
                              '${_rule(raw['kind'])} · ${_effect(raw['effect'])}'),
                          subtitle: Text(_ruleDetail(raw)),
                        ),
                      ),
                  if (policy['kind'] == 'TEMPLATE')
                    const Card(
                        child: Padding(
                            padding: EdgeInsets.all(18),
                            child: Text('模板不能直接预览或发布。请先在完整管理台复制为策略草稿。')))
                  else if (!widget.session.canDecide)
                    const Card(
                        child: Padding(
                            padding: EdgeInsets.all(18),
                            child: Text('当前角色可查看策略，不能预览或发布。')))
                  else ...[
                    const SizedBox(height: 18),
                    Text('选择目标设备 · ${selected.length}/50',
                        style: Theme.of(context).textTheme.titleLarge),
                    const Text('本次为明确设备快照。设备组成员后续变化不会自动更新此策略。',
                        style: TextStyle(color: _muted)),
                    const SizedBox(height: 10),
                    _devicePicker(),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: busy || selected.isEmpty
                          ? null
                          : () => _preview(policy),
                      icon: const Icon(Icons.fact_check_outlined),
                      label: Text(busy ? '正在检查设备…' : '预览所选设备'),
                    ),
                  ],
                  if (actionError != null) ...[
                    const SizedBox(height: 12),
                    Text('$actionError',
                        style: const TextStyle(color: Color(0xFF9A3931))),
                  ],
                  if (markers.any((row) => row.policyId == widget.policyId))
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('此策略有待核对的配置发布。请返回策略中心查询原结果，核对前不能再次发布。'),
                      ),
                    ),
                  if (preview != null) ...[
                    const SizedBox(height: 18),
                    _previewContent(preview!),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: busy ||
                              !journalLoaded ||
                              markers.any(
                                  (row) => row.policyId == widget.policyId) ||
                              (preview!['expiresAt'] as int) <=
                                  DateTime.now().millisecondsSinceEpoch
                          ? null
                          : () => _publish(policy),
                      icon: const Icon(Icons.save_outlined),
                      label: Text(busy ? '正在处理…' : '仅保存配置版本'),
                    ),
                    if ((preview!['expiresAt'] as int) <=
                        DateTime.now().millisecondsSinceEpoch)
                      const Text('预览已过期，请重新预览后再保存。',
                          style: TextStyle(color: _muted)),
                    if (!journalLoaded)
                      const Text('正在核对本机待处理发布记录，完成后才可保存。',
                          style: TextStyle(color: _muted)),
                  ],
                  if (publication != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('配置版本已保存',
                                style: TextStyle(fontWeight: FontWeight.w700)),
                            Text('版本序号：${publication!['sequence']}'),
                            SelectableText('操作编号：${publication!['id']}'),
                            const Text('状态：仅保存配置，尚未执行设备系统限制。'),
                          ],
                        ),
                      ),
                    ),
                ]),
              );
            },
          ),
        ),
      );

  Widget _devicePicker() => AnimatedBuilder(
        animation: devices!,
        builder: (context, _) {
          final devices = this.devices!;
          if (!devices.loaded && devices.error != null) {
            return _error(devices.error!, devices.reload);
          }
          if (!devices.loaded) return const LinearProgressIndicator();
          return Column(children: [
            if (devices.items.isEmpty) const Text('当前没有可选择的设备，请先完成设备注册。'),
            for (final row in devices.items)
              Card(
                child: CheckboxListTile(
                  value: selected.containsKey(row['id']),
                  onChanged: !busy &&
                          row['id'] is String &&
                          (selected.containsKey(row['id']) ||
                              (row['state'] == 'ACTIVE' &&
                                  row['registrationId'] is String &&
                                  selected.length < 50))
                      ? (_) => _toggleDevice(row)
                      : null,
                  title: Text(_name(row['displayName'], '未命名设备')),
                  subtitle: Text(
                      '${row['platform'] == 'ANDROID_TV' ? 'Android TV' : 'Android'} · ${row['state'] == 'ACTIVE' ? '已注册' : '不可选择'}'),
                ),
              ),
            if (devices.error != null)
              Text('${devices.error}',
                  style: const TextStyle(color: Color(0xFF9A3931))),
            if (devices.loadingMore) const LinearProgressIndicator(),
            if (devices.hasMore)
              TextButton.icon(
                onPressed: devices.loadingMore ? null : devices.loadMore,
                icon: const Icon(Icons.expand_more),
                label: const Text('加载更多设备'),
              ),
          ]);
        },
      );

  Widget _previewContent(Json result) {
    final targets = result['targets'] as List;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('设备检查结果', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 7),
      Text('预览有效期：${_time(result['expiresAt'])} · ${targets.length} 台设备',
          style: const TextStyle(color: _muted)),
      const SizedBox(height: 9),
      const Card(
          child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                  '这是配置预览，不会更改设备设置。服务端当前尚未开放系统强制执行；“支持”只表示预览检查通过，不代表规则已经生效。'))),
      for (final raw in targets)
        if (raw is Json)
          Card(
            margin: const EdgeInsets.only(top: 10),
            child: ExpansionTile(
              title: Text(selectedNames[raw['deviceId']] ?? '未命名设备'),
              subtitle: Text(
                  '设备观察：${_observation(raw['observationStatus'])} · ${(raw['rules'] as List).length} 项规则'),
              children: [
                for (final rule in raw['rules'] as List)
                  if (rule is Json)
                    ListTile(
                      title: Text(
                          '${_rule(rule['kind'])} · ${_status(rule['status'])}'),
                      subtitle: Text(_evaluationDetail(rule)),
                    ),
              ],
            ),
          ),
    ]);
  }
}

Widget _error(Object error, VoidCallback retry) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$error', textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: retry,
            icon: const Icon(Icons.refresh),
            label: const Text('重新加载'),
          ),
        ]),
      ),
    );

String _name(Object? value, String fallback) =>
    value is String && value.trim().isNotEmpty ? value : fallback;

String _time(Object? millis) {
  if (millis is! int || millis <= 0) return '暂无记录';
  final value = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
}

String _rule(Object? kind) => switch (kind) {
      'APP_LAUNCH' => '应用启动',
      'APP_INSTALL' => '应用安装',
      'APP_UNINSTALL' => '应用卸载保护',
      'RUNTIME_PERMISSION' => '系统运行时权限',
      'SPECIAL_ACCESS' => '特殊访问权限',
      'DAILY_QUOTA' => '每日额度',
      'TIME_WINDOW' => '可用时段',
      'DOMAIN_ACCESS' => '网站访问',
      'USAGE_REMINDER' => '使用提醒',
      _ => '其他规则',
    };

String _effect(Object? effect) => switch (effect) {
      'ALLOW' => '允许',
      'DENY' => '拒绝',
      'DEFAULT' => '系统默认',
      'GRANT' => '授予',
      'PROTECT' => '保护',
      'LIMIT' => '限制',
      'REMIND' => '提醒',
      _ => '待核对',
    };

String _ruleDetail(Json rule) {
  final parts = <String>[
    rule['required'] == true ? '必须支持' : '可选执行',
    if (rule['applicationId'] is String) '应用 ${rule['applicationId']}',
    if (rule['scheduleId'] is String) '时段 ${rule['scheduleId']}',
    if (rule['seconds'] is int) '${rule['seconds']} 秒',
    if (rule['domain'] is String) '${rule['domain']}',
    if (rule['permission'] is String) '${rule['permission']}',
  ];
  return parts.join(' · ');
}

String _status(Object? value) => switch (value) {
      'SUPPORTED_PENDING' => '能力支持 · 等待执行',
      'UNSUPPORTED' => '预览不支持',
      'UNVERIFIED' => '应用身份未核验',
      'UNAVAILABLE' => '设备当前不可用',
      'STALE' => '能力报告已过期',
      'UNKNOWN' => '能力尚未核验',
      _ => '状态待核对',
    };

String _reason(Object? value) => switch (value) {
      'AWAITING_EXECUTION' => '仅预览支持，仍待设备实际执行',
      'CAPABILITY_NOT_VERIFIED' => '尚无可验证的设备能力证据',
      'AUTO_GRANT_NOT_AVAILABLE' => '不能自动授予该系统权限',
      'SYSTEM_USER_ACTION_REQUIRED' => '需设备用户在系统设置中操作',
      'APPLICATION_IDENTITY_NOT_VERIFIED' => '应用签名或安装身份尚未核验',
      'DEVICE_NOT_ACTIVE' => '设备未处于有效注册状态',
      'APPLICATION_PLATFORM_MISMATCH' => '应用与设备平台不匹配',
      'APPLICATION_PROFILE_NOT_VERIFIED' => '应用安装位置尚未核验',
      _ => value is String && value.isNotEmpty ? value : '无额外说明',
    };

String _evaluationDetail(Json rule) {
  final warnings = rule['warnings'];
  final notes = warnings is List
      ? warnings.map(_warning).where((value) => value.isNotEmpty).toList()
      : <String>[];
  return '原因：${_reason(rule['reasonCode'])}${notes.isEmpty ? '' : '\n提示：${notes.join('、')}'}';
}

String _warning(Object? value) => switch (value) {
      'SAME_LAYER_CONFLICT_RESTRICTIVE_WINS' => '同层冲突取更严格结果',
      'SMALLER_QUOTA_WINS' => '额度取更短时长',
      'INSTALL_DENY_MAY_REMOVE_EXISTING_APP' => '拒绝安装可能影响现有应用',
      'SYSTEM_USER_ACTION_REQUIRED' => '仍需设备用户操作',
      _ => value is String ? value : '',
    };

String _observation(Object? value) => switch (value) {
      'RECENT' => '近期有设备报告',
      'STALE' => '设备报告已过期',
      _ => '尚无有效设备报告',
    };
