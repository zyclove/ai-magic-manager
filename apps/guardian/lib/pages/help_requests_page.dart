import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/help_requests.dart';
import '../core/labels.dart';
import '../core/session.dart';
import '../ui/design.dart';

/// Acknowledgement means an authorized adult opened the record, not that help was delivered.
class HelpRequestsPage extends StatefulWidget {
  final Session session;
  const HelpRequestsPage({super.key, required this.session});

  @override
  State<HelpRequestsPage> createState() => _HelpRequestsPageState();
}

class _HelpRequestsPageState extends State<HelpRequestsPage> {
  late final String root, role;
  List<HelpRequest> requests = const [];
  String? cursor;
  String filter = 'OPEN';
  Object? error;
  bool loading = true, loadingMore = false;
  int generation = 0;
  final Set<String> uncertain = {}, sending = {};

  bool get current =>
      widget.session.authenticated &&
      widget.session.tenant != null &&
      widget.session.root == root &&
      widget.session.role == role &&
      widget.session.canWrite;

  @override
  void initState() {
    super.initState();
    root = widget.session.root;
    role = widget.session.role;
    load();
  }

  Future<void> load({bool more = false}) async {
    if (!current) return;
    final epoch = ++generation;
    final sourceFilter = filter;
    final nextCursor = more ? cursor : null;
    setState(() {
      if (more) {
        loadingMore = true;
      } else {
        loading = true;
        requests = const [];
        cursor = null;
      }
      error = null;
    });
    try {
      final path =
          '$root/help-requests${sourceFilter == 'OPEN' ? '?state=OPEN' : ''}';
      final page = await widget.session.api.page(path, cursor: nextCursor);
      final parsed = page.items.map(HelpRequest.parse).toList(growable: false);
      if (current && generation == epoch && filter == sourceFilter) {
        setState(() {
          requests = more ? [...requests, ...parsed] : parsed;
          cursor = page.nextCursor;
          uncertain.clear();
        });
      }
    } catch (failure) {
      if (current && generation == epoch) setState(() => error = failure);
    } finally {
      if (mounted && generation == epoch) {
        setState(() {
          loading = false;
          loadingMore = false;
        });
      }
    }
  }

  void changeFilter(String next) {
    if (filter == next) return;
    setState(() => filter = next);
    load();
  }

  Future<void> acknowledge(HelpRequest item) async {
    if (!current || sending.contains(item.id) || uncertain.contains(item.id)) {
      return;
    }
    final confirmed = await confirmAction(context, '确认已看到求助',
        '此操作只记录你已看到这条求助，不代表已联系孩子、问题已解决或紧急服务已接收。请根据实际情况尽快联系并提供帮助。',
        confirm: '已看到');
    if (!confirmed || !current) return;
    setState(() {
      sending.add(item.id);
      error = null;
    });
    try {
      final response = await widget.session.api.send(
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
          uncertain.add(item.id);
          error = failure;
        });
      }
    } finally {
      if (mounted) setState(() => sending.remove(item.id));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.session,
      builder: (context, _) => !current
          ? const Panel(child: EmptyView('工作空间或权限已变化', '已隐藏旧求助记录，请重新打开当前工作空间。'))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const PageHeading('儿童求助记录', '查看设备提交的求助，并跟进实际联系与处理。'),
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
                    reauth: () => widget.session.login(stepUp: true)),
                const SizedBox(height: 16)
              ],
              Panel(
                  child: loading
                      ? const Center(
                          child: Padding(
                              padding: EdgeInsets.all(40),
                              child: CircularProgressIndicator(strokeWidth: 2)))
                      : requests.isEmpty
                          ? EmptyView(filter == 'OPEN' ? '暂无待查看求助' : '暂无求助记录',
                              '仅展示已由设备成功提交到本服务的记录。')
                          : Column(children: [
                              for (final item in requests) ...[
                                _row(item),
                                const Divider(height: 1)
                              ],
                              if (cursor != null)
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
        Text(
            '提交：${dateLabel(item.createdAt)} · 档案 ${shortId(item.subjectId)} · 设备 ${shortId(item.deviceId)}',
            style: const TextStyle(color: muted)),
        if (item.acknowledgedAt != null)
          Text('管理员已查看：${dateLabel(item.acknowledgedAt)}。实际帮助仍需线下跟进。',
              style: const TextStyle(color: muted)),
        if (item.state == 'OPEN')
          Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton(
                  onPressed:
                      sending.contains(item.id) || uncertain.contains(item.id)
                          ? null
                          : () => acknowledge(item),
                  child: Text(sending.contains(item.id)
                      ? '处理中'
                      : uncertain.contains(item.id)
                          ? '请先刷新核对'
                          : '确认已看到')))
      ]));
}
