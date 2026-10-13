import 'package:flutter/material.dart';

import '../core/paged_collection.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';

const _ink = Color(0xFF17324B);
const _muted = Color(0xFF315E86);

/// Opens a scoped, read-only history. The server remains the authority for
/// member, subject, and tenant access on every request.
Future<void> showAccessHistory(BuildContext context, ParentSession session) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AccessHistory(session: session),
  ));
}

/// Reads the original request and its current delivery evidence independently
/// of the approval form. Device receipts are self reports, not OS enforcement.
Future<void> showAccessRequestDetail(
    BuildContext context, ParentSession session, String requestId) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        _AccessRequestDetail(session: session, requestId: requestId),
  );
}

class AccessHistory extends StatefulWidget {
  final ParentSession session;
  const AccessHistory({super.key, required this.session});

  @override
  State<AccessHistory> createState() => _AccessHistoryState();
}

class _AccessHistoryState extends State<AccessHistory> {
  late final String tenantId;
  late final String actor;
  late final String role;
  late final PagedCollection requests;

  @override
  void initState() {
    super.initState();
    tenantId = widget.session.tenant!['id'] as String;
    actor = widget.session.profile!['subject'] as String;
    role = widget.session.role;
    requests = PagedCollection(
        widget.session.api, '/tenants/$tenantId/access-requests');
    widget.session.addListener(_closeIfScopeChanged);
  }

  bool get _current =>
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenantId &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;

  void _closeIfScopeChanged() {
    if (mounted && !_current) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    widget.session.removeListener(_closeIfScopeChanged);
    requests.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('申请记录')),
        body: AnimatedBuilder(
          animation: requests,
          builder: (context, _) {
            if (!requests.loaded && requests.error != null) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('${requests.error}', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: requests.reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重新加载'),
                    ),
                  ]),
                ),
              );
            }
            if (!requests.loaded) {
              return const Center(child: CircularProgressIndicator());
            }
            return RefreshIndicator(
              onRefresh: requests.reload,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text('审批与设备执行',
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                color: _ink,
                                fontWeight: FontWeight.w700,
                              )),
                  const SizedBox(height: 7),
                  const Text('批准只生成有期限的授权。设备接收、保存和实际执行需要分别核对。',
                      style: TextStyle(color: _muted)),
                  const SizedBox(height: 18),
                  if (requests.items.isEmpty)
                    const Card(
                        child: Padding(
                            padding: EdgeInsets.all(20),
                            child: Text('还没有可查看的申请记录。'))),
                  for (final item in requests.items)
                    Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: Semantics(
                        button: true,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 9),
                          leading: Icon(_icon(item['state']), color: _muted),
                          title: Text(
                            '${_name(item['subjectName'], '儿童')} · ${_name(item['applicationName'], '应用')}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${_state(item['state'])} · ${_time(item['createdAt'])}\n${_name(item['deviceName'], '设备')}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          isThreeLine: true,
                          trailing: const Icon(Icons.chevron_right),
                          onTap: item['id'] is String && _current
                              ? () => showAccessRequestDetail(
                                  context, widget.session, item['id'] as String)
                              : null,
                        ),
                      ),
                    ),
                  if (requests.error != null)
                    Text('${requests.error}',
                        style: const TextStyle(color: Color(0xFF9A3931))),
                  if (requests.loadingMore) const LinearProgressIndicator(),
                  if (requests.hasMore)
                    TextButton.icon(
                      onPressed:
                          requests.loadingMore ? null : requests.loadMore,
                      icon: const Icon(Icons.expand_more),
                      label: const Text('加载更多记录'),
                    ),
                ],
              ),
            );
          },
        ),
      );
}

class _AccessRequestDetail extends StatefulWidget {
  final ParentSession session;
  final String requestId;
  const _AccessRequestDetail({required this.session, required this.requestId});

  @override
  State<_AccessRequestDetail> createState() => _AccessRequestDetailState();
}

class _AccessRequestDetailState extends State<_AccessRequestDetail> {
  late final String tenantId;
  late final String actor;
  late final String role;
  late Future<(Json, Json)> details;

  @override
  void initState() {
    super.initState();
    tenantId = widget.session.tenant!['id'] as String;
    actor = widget.session.profile!['subject'] as String;
    role = widget.session.role;
    widget.session.addListener(_closeIfScopeChanged);
    _reload();
  }

  bool get _current =>
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenantId &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;

  void _closeIfScopeChanged() {
    if (mounted && !_current) Navigator.of(context).pop();
  }

  void _reload() {
    final root = '/tenants/$tenantId/access-requests/${widget.requestId}';
    setState(() => details = _read(root));
  }

  Future<(Json, Json)> _read(String root) async {
    final (request, delivery) = await (
      widget.session.api.object(root),
      widget.session.api.object('$root/delivery'),
    ).wait;
    if (request['id'] != widget.requestId ||
        delivery['requestId'] != widget.requestId ||
        request['version'] is! int ||
        delivery['approvalVersion'] is! int ||
        delivery['deliveryState'] is! String ||
        delivery['executionState'] is! String) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return (request, delivery);
  }

  @override
  void dispose() {
    widget.session.removeListener(_closeIfScopeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: MediaQuery.sizeOf(context).height * .86),
          child: FutureBuilder<(Json, Json)>(
            future: details,
            builder: (context, snapshot) => ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(20),
              children: [
                Row(children: [
                  Expanded(
                      child: Text('申请与交付状态',
                          style: Theme.of(context).textTheme.titleLarge)),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ]),
                const SizedBox(height: 10),
                if (snapshot.hasError) ...[
                  Text('${snapshot.error}',
                      style: const TextStyle(color: Color(0xFF9A3931))),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新查询'),
                  ),
                ] else if (snapshot.connectionState != ConnectionState.done)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else
                  ..._content(snapshot.data!.$1, snapshot.data!.$2),
              ],
            ),
          ),
        ),
      );

  List<Widget> _content(Json request, Json delivery) {
    if (request['version'] != delivery['approvalVersion']) {
      return [
        const Text('读取期间申请发生变化，请重新查询。'),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _reload,
          icon: const Icon(Icons.refresh),
          label: const Text('重新查询'),
        ),
      ];
    }
    final approved = request['state'] == 'APPROVED_PENDING_DELIVERY';
    return [
      Text(
        '${_name(request['subjectName'], '儿童')} · ${_name(request['applicationName'], '应用')}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 6),
      Text(_name(request['deviceName'], '设备'),
          style: const TextStyle(color: _muted)),
      const SizedBox(height: 16),
      if (request['applicationPackageName'] is String)
        _fact('应用包名', request['applicationPackageName'] as String),
      _fact('审批状态', _state(request['state'])),
      _fact('申请时间', _time(request['createdAt'])),
      if (request['requestedWindowSeconds'] is int)
        _fact('申请时长', '${request['requestedWindowSeconds']} 秒'),
      if (request['reason'] is String &&
          (request['reason'] as String).trim().isNotEmpty)
        _fact('申请原因', request['reason'] as String),
      if (request['absoluteNotAfter'] != null)
        _fact('授权截止', _time(request['absoluteNotAfter'])),
      if (delivery['action'] is String)
        _fact('文档动作', _action(delivery['action'])),
      _fact('文档交付', _delivery(delivery['deliveryState'])),
      if (delivery['deliveryAttempt'] is int)
        _fact('交付尝试', '第 ${delivery['deliveryAttempt']} 次'),
      if (delivery['receivedAt'] != null)
        _fact('最近设备报告', _time(delivery['receivedAt'])),
      if (delivery['reasonCode'] is String)
        _fact('拒收原因', _reason(delivery['reasonCode'])),
      if (delivery['retryStatus'] is String &&
          delivery['deliveryState'] == 'REJECTED')
        _fact('设备恢复', _retry(delivery['retryStatus'])),
      if (delivery['retryAfter'] != null)
        _fact('最早可重试', _time(delivery['retryAfter'])),
      _fact('系统执行', _execution(delivery['executionState'])),
      const SizedBox(height: 15),
      DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFFEAF2F8),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(approved
              ? '当前仅能确认成人决定与文档交付阶段。设备“收到”或“保存”是设备自报，不能证明系统已解除应用限制；原批准截止不会因下载或重试延长。'
              : '此申请目前没有可执行的临时开放。交付记录只用于核对当前决定，不代表设备已改变系统限制。'),
        ),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _reload,
        icon: const Icon(Icons.refresh),
        label: const Text('刷新状态'),
      ),
    ];
  }
}

Widget _fact(String title, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 105,
            child: Text(title, style: const TextStyle(color: _muted))),
        Expanded(child: SelectableText(value)),
      ]),
    );

String _name(Object? value, String fallback) =>
    value is String && value.trim().isNotEmpty ? value : fallback;

String _time(Object? millis) {
  if (millis is! int || millis <= 0) return '暂无记录';
  final time = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}';
}

String _state(Object? state) => switch (state) {
      'PENDING' => '等待审批',
      'APPROVED_PENDING_DELIVERY' => '已批准 · 尚未执行',
      'DENIED' => '已拒绝',
      'CANCELLED' => '已取消',
      'EXPIRED' => '已过期',
      'REVOKED' => '已撤销',
      'INVALIDATED' => '已失效',
      _ => '状态待核对',
    };

IconData _icon(Object? state) => switch (state) {
      'PENDING' => Icons.hourglass_empty,
      'APPROVED_PENDING_DELIVERY' => Icons.task_alt_outlined,
      'DENIED' => Icons.block_outlined,
      _ => Icons.info_outline,
    };

String _delivery(Object? state) => switch (state) {
      'NOT_GRANTED' => '没有批准文档',
      'NOT_FETCHED' => '尚未获取',
      'SIGNED' => '已签发，等待设备获取',
      'RECEIVED' => '设备自报已收到',
      'STORED' => '设备自报已保存',
      'REJECTED' => '设备自报拒收',
      _ => '状态待核对',
    };

String _action(Object? value) => switch (value) {
      'UPSERT_ACCESS_WINDOW' => '添加限时授权文档',
      'REMOVE_ACCESS_WINDOW' => '移除限时授权文档',
      _ => '动作待核对',
    };

String _execution(Object? state) => switch (state) {
      'NOT_ENFORCED' => '尚无系统执行证据',
      _ => '状态待核对',
    };

String _reason(Object? value) => switch (value) {
      'SIGNATURE_INVALID' => '签名校验失败',
      'BASELINE_MISSING' => '基础策略缺失',
      'EXPIRED' => '授权已过期',
      'UNSUPPORTED_SCHEMA' => '设备版本不支持',
      'STORAGE_FAILED' => '设备保存失败',
      'WRONG_DEVICE' => '设备绑定不匹配',
      'OTHER' => '其他原因',
      _ => '原因待核对',
    };

String _retry(Object? value) => switch (value) {
      'NOT_NEEDED' => '无需重试',
      'WAITING' => '等待设备重试',
      'AVAILABLE' => '设备可重试',
      'NOT_ALLOWED' => '不允许自动重试',
      'WINDOW_ENDING' => '授权即将到期',
      'EXHAUSTED' => '已达重试上限',
      _ => '状态待核对',
    };
