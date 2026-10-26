import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/help_requests.dart';
import '../core/labels.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/leased_dialog.dart';
import 'device_subflow_scope.dart';

/// Acknowledgement means an authorized adult opened the record, not that help was delivered.
class HelpRequestsPage extends StatefulWidget {
  final Session session;
  const HelpRequestsPage({super.key, required this.session});

  @override
  State<HelpRequestsPage> createState() => _HelpRequestsPageState();
}

class _HelpRequestsPageState extends State<HelpRequestsPage> {
  late final Session sessionOwner;
  late final DeviceSubflowScope scope;
  late final Listenable accessChanges;
  final pageAccess = ValueNotifier<bool>(true);
  late final String root, role;
  List<HelpRequest> requests = const [];
  String? cursor;
  String filter = 'OPEN';
  Object? error, pageError;
  bool loading = true, loadingMore = false;
  bool firstPageLoaded = false;
  int generation = 0, ackSequence = 0;
  final Map<String, int> uncertain = {};
  final Map<String, int> lastDispatchedSequence = {};
  final Set<String> sending = {};

  bool permitted() =>
      mounted &&
      pageAccess.value &&
      identical(widget.session, sessionOwner) &&
      sessionOwner.tenant != null &&
      sessionOwner.canOpen('help-requests');

  bool get current => mounted && scope.current;

  bool get pageCursorInvalid =>
      pageError is ApiFailure &&
      (pageError as ApiFailure).code == 'INVALID_CURSOR';

  bool _accessFailure(Object failure) =>
      failure is ApiFailure &&
      (failure.status == 401 ||
          failure.status == 403 ||
          failure.code == 'WORKSPACE_CHANGED' ||
          failure.code == 'HELP_REQUEST_UNAVAILABLE');

  // A server rejection invalidates this capture, including older in-flight reads.
  // Retain uncertain write markers until disposal; losing access never retries them.
  void _loseAccess() {
    generation++;
    requests = const [];
    cursor = null;
    firstPageLoaded = false;
    loading = false;
    loadingMore = false;
    error = null;
    pageError = null;
    pageAccess.value = false;
  }

  @override
  void initState() {
    super.initState();
    sessionOwner = widget.session;
    root = sessionOwner.root;
    role = sessionOwner.role;
    scope = DeviceSubflowScope(sessionOwner, permitted: permitted);
    accessChanges = Listenable.merge([scope, pageAccess]);
    load();
  }

  @override
  void dispose() {
    generation++;
    scope.dispose();
    // Dispose may run while the widget tree is locked. Revoke the lease's
    // notification after the frame; scope disposal already blocks callbacks.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      pageAccess.value = false;
      pageAccess.dispose();
    });
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (!current || (more && (loading || loadingMore || cursor == null))) return;
    final epoch = ++generation;
    final sourceFilter = filter;
    final uncertainAtReadStart = more
        ? const <String, int>{}
        : Map<String, int>.of(uncertain);
    final nextCursor = more ? cursor : null;
    setState(() {
      if (more) {
        loadingMore = true;
        pageError = null;
      } else {
        loading = true;
        loadingMore = false;
        firstPageLoaded = false;
        requests = const [];
        cursor = null;
        error = null;
        pageError = null;
      }
    });
    try {
      final path =
          '$root/help-requests${sourceFilter == 'OPEN' ? '?state=OPEN' : ''}';
      final page = await scope.api.page(path, cursor: nextCursor);
      final parsed = page.items.map(HelpRequest.parse).toList(growable: false);
      if (current && generation == epoch && filter == sourceFilter) {
        setState(() {
          requests = more ? [...requests, ...parsed] : parsed;
          cursor = page.nextCursor;
          if (!more) {
            firstPageLoaded = true;
            uncertain.removeWhere((id, operation) =>
                uncertainAtReadStart[id] == operation);
          }
        });
      }
    } catch (failure) {
      if (current && _accessFailure(failure)) {
        setState(_loseAccess);
      } else if (current && generation == epoch) {
        setState(() {
          if (more) {
            pageError = failure;
            if (failure is ApiFailure && failure.code == 'INVALID_CURSOR') {
              cursor = null;
            }
          } else {
            error = failure;
          }
        });
      }
    } finally {
      if (mounted && generation == epoch) {
        setState(() {
          loading = false;
          loadingMore = false;
        });
      }
    }
  }

  void retryMore() {
    if (!current || loading || loadingMore || cursor == null || pageError == null) {
      return;
    }
    load(more: true);
  }

  void refreshAfterPageFailure() {
    if (!current || loading || loadingMore || !pageCursorInvalid) return;
    load();
  }

  void changeFilter(String next) {
    if (!current || filter == next) return;
    setState(() => filter = next);
    load();
  }

  Future<void> acknowledge(HelpRequest item) async {
    if (!current || sending.contains(item.id) || uncertain.containsKey(item.id)) {
      return;
    }
    final openedAtSequence = lastDispatchedSequence[item.id];
    final subject = item.subjectNickname == null
        ? item.subjectId
        : '${item.subjectNickname}（${item.subjectId}）';
    final confirmed = await confirmLeasedAction(context, '确认已看到求助',
        '求助对象：$subject\n'
        '求助类型：${helpReason(item.reasonCode)}\n'
        '设备：${item.deviceId}\n'
        '提交时间：${dateLabel(item.createdAt)}\n\n'
        '此操作只记录你已看到这条求助，不代表已联系孩子、问题已解决或紧急服务已接收。请根据实际情况尽快联系并提供帮助。',
        confirm: '已看到',
        accessChanges: accessChanges,
        hasAccess: () => current);
    if (!confirmed || !current || sending.contains(item.id) ||
        uncertain.containsKey(item.id) ||
        lastDispatchedSequence[item.id] != openedAtSequence) return;
    final operation = ++ackSequence;
    setState(() {
      lastDispatchedSequence[item.id] = operation;
      sending.add(item.id);
      error = null;
    });
    try {
      final response = await scope.api.send(
          'POST', '$root/help-requests/${item.id}/acknowledge',
          version: item.version);
      final updated = HelpRequest.parse(response);
      if (updated.id != item.id || updated.state != 'ACKNOWLEDGED') {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
      if (current) await load();
    } catch (failure) {
      if (current) {
        setState(() {
          if (_accessFailure(failure)) {
            _loseAccess();
          } else {
            uncertain[item.id] = operation;
            error = failure;
          }
        });
      }
    } finally {
      if (mounted) setState(() => sending.remove(item.id));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: scope,
      builder: (context, _) => !current
          ? const Panel(child: EmptyView('工作空间或权限已变化', '已隐藏旧求助记录，请重新打开当前工作空间。'))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              PageHeading(
                  role == 'TEACHER' ? '授权学生求助' : '儿童求助记录',
                  role == 'TEACHER'
                      ? '只显示当前获授权学生的求助；请按机构值班流程联系并跟进。'
                      : '查看设备提交的求助，并跟进实际联系与处理。'),
              const Notice(
                  '此页面只记录服务端收到的求助。它不是紧急呼叫，也没有短信或系统推送保证；若存在即时危险，应通过当地紧急服务或可信任的成人寻求即时帮助。',
                  warning: true),
              const SizedBox(height: 20),
              Wrap(spacing: 10, runSpacing: 10, children: [
                ChoiceChip(
                    label: const Text('待查看'),
                    selected: filter == 'OPEN',
                    onSelected: (_) => changeFilter('OPEN')),
                ChoiceChip(
                    label: const Text('全部'),
                    selected: filter == 'ALL',
                    onSelected: (_) => changeFilter('ALL')),
                OutlinedButton.icon(
                    onPressed: loading ? null : load,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('刷新'))
              ]),
              const SizedBox(height: 16),
              if (error != null) ...[
                const Notice('操作或读取结果暂未确认。刷新后查看当前状态；请勿凭网络错误判断监护人确认已生效。',
                    warning: true),
                const SizedBox(height: 8),
                FailureView(error!,
                    retry: load,
                    reauth: () {
                      if (current) sessionOwner.login(stepUp: true);
                    }),
                const SizedBox(height: 16)
              ],
              Panel(
                  child: loading
                      ? const Center(
                          child: Padding(
                              padding: EdgeInsets.all(40),
                              child: CircularProgressIndicator(strokeWidth: 2)))
                      : !firstPageLoaded
                          ? const EmptyView('读取尚未完成',
                              '当前求助记录未知。请使用上方“重试”或“重新安全验证”后再核对。')
                          : requests.isEmpty
                              ? EmptyView(filter == 'OPEN' ? '暂无待查看求助' : '暂无求助记录',
                                  '仅展示已由设备成功提交到本服务的记录。')
                              : Column(children: [
                              for (final item in requests) ...[
                                _row(item),
                                const Divider(height: 1)
                              ],
                              if (pageError != null) ...[
                                const SizedBox(height: 12),
                                if (pageCursorInvalid) ...[
                                  const Notice(
                                      '分页位置无法继续使用，已保留当前求助记录。请刷新列表后继续查看。',
                                      warning: true),
                                  TextButton.icon(
                                      onPressed: loading || loadingMore
                                          ? null
                                          : refreshAfterPageFailure,
                                      icon: const Icon(Icons.refresh),
                                      label: const Text('刷新求助记录')),
                                ] else
                                  FailureView(pageError!,
                                      retry: loading || loadingMore
                                          ? null
                                          : retryMore,
                                      reauth: () {
                                        if (current) sessionOwner.login(stepUp: true);
                                      }),
                              ],
                              if (cursor != null && pageError == null)
                                TextButton.icon(
                                    onPressed: loadingMore
                                        ? null
                                        : () => load(more: true),
                                    icon: const Icon(Icons.expand_more),
                                    label: Text(loadingMore ? '读取中' : '加载更多'))
                            ]))
            ]));

  Widget _row(HelpRequest item) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(helpReason(item.reasonCode),
                  style: Theme.of(context).textTheme.titleMedium),
              StatusTag(item.state)
            ]),
        const SizedBox(height: 6),
        Text('对象：${item.subjectNickname ?? item.subjectId}'),
        Text('提交：${dateLabel(item.createdAt)}',
            style: const TextStyle(color: muted)),
        Text('设备：${item.deviceId}', style: const TextStyle(color: muted)),
        if (item.acknowledgedAt != null)
          Text('已在管理台确认看到：${dateLabel(item.acknowledgedAt)}。实际帮助仍需线下跟进。',
              style: const TextStyle(color: muted)),
        if (item.state == 'OPEN')
          Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton(
                  onPressed: sending.contains(item.id)
                      ? null
                      : uncertain.containsKey(item.id)
                          ? loadingMore
                              ? null
                              : () {
                                  if (!loading && !loadingMore) load();
                                }
                          : () => acknowledge(item),
                  child: Text(sending.contains(item.id)
                      ? '处理中'
                      : uncertain.containsKey(item.id)
                          ? '刷新核对'
                          : '确认已看到')))
      ]));
}
