import 'package:flutter/material.dart';
import '../core/family.dart';
import '../core/family_requests.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import 'family_workspace.dart';

class FamilyRequestsPage extends StatefulWidget {
  final ParentSession session;
  final FamilyDecisionJournal? journal;
  const FamilyRequestsPage({super.key, required this.session, this.journal});
  @override
  State<FamilyRequestsPage> createState() => _FamilyRequestsPageState();
}

class _FamilyRequestsPageState extends State<FamilyRequestsPage>
    with FamilyScope<FamilyRequestsPage>, WidgetsBindingObserver {
  @override
  ParentSession get session => widget.session;
  late final FamilyDecisionJournal journal;
  late final FamilyRequests requests;
  final List<FamilyAccessRequest> rows = [];
  final Map<String, String> names = {};
  Json? pending;
  String? cursor, error, receipt;
  bool busy = false, foreground = true, needsVerification = false;
  @override
  void initState() {
    super.initState();
    journal = widget.journal ?? FamilyDecisionJournal();
    requests = FamilyRequests(service);
    WidgetsBinding.instance.addObserver(this);
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      setState(() => foreground = state == AppLifecycleState.resumed);
    }
  }

  Future<void> load({bool more = false}) async {
    if (busy || !current) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final marker = await journal.load(scopeTenant, scopeActor);
      if (!current) return;
      final page = await service.object(
          '/family-access-requests?limit=20${more && cursor != null ? '&cursor=${Uri.encodeComponent(cursor!)}' : ''}');
      if (page['items'] is! List ||
          page['nextCursor'] != null && page['nextCursor'] is! String) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      final fetched = (page['items'] as List)
          .map((e) => FamilyAccessRequest.fromJson(e as Json))
          .toList();
      final dashboard = await service.dashboard();
      if (!current) return;
      for (final child in dashboard.children) {
        names[child.id] = child.nickname;
        for (final device in child.devices) {
          names[device.id] = device.displayName;
        }
      }
      setState(() {
        pending = marker;
        if (!more) rows.clear();
        rows.addAll(fetched);
        cursor = page['nextCursor'];
      });
    } catch (failure) {
      if (current) setState(() => error = familyError(failure));
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> decide(FamilyAccessRequest request, bool approve) async {
    if (busy || !current || !foreground || pending != null) return;
    int selected = request.requestedSeconds;
    final options = <int>{
      ...{300, 600, 900, 1800}.where((v) => v < request.requestedSeconds),
      request.requestedSeconds
    }.toList()
      ..sort();
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: Text(approve ? '临时延长使用' : '这次先不延长'),
                  content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '${names[request.subjectId] ?? '孩子'} · ${names[request.deviceId] ?? '儿童设备'}'),
                        if (approve)
                          DropdownButtonFormField<int>(
                              value: selected,
                              isExpanded: true,
                              decoration:
                                  const InputDecoration(labelText: '这次延长多久'),
                              items: options
                                  .map((v) => DropdownMenuItem(
                                      value: v,
                                      child: Text('${(v / 60).ceil()} 分钟')))
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) update(() => selected = v);
                              }),
                        const SizedBox(height: 12),
                        Text(approve
                            ? '从确认时起计时；设备收到规则后生效。离线设备可能延迟收到。'
                            : '孩子可以看到本次结果，原作息保持有效。'),
                      ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('确认'))
                  ],
                )));
    if (confirmed != true || !current || !foreground) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final original = await journal.begin(scopeTenant, scopeActor, request,
          approve: approve, seconds: selected);
      if (!current || !foreground) return;
      setState(() => pending = original);
      await sendOriginal();
    } catch (failure) {
      if (current) setState(() => error = familyError(failure));
    } finally {
      if (current) setState(() => busy = false);
    }
    await load();
  }

  Future<void> sendOriginal() async {
    if (!current || !foreground || pending == null) return;
    try {
      final result = await requests.submit(pending!);
      if (!current) return;
      await journal.clear(scopeTenant, scopeActor);
      if (!current) return;
      setState(() {
        pending = null;
        needsVerification = false;
        receipt = result.state == 'APPROVED'
            ? '延长决定已保存。请在“今日”核对设备收到规则和实际状态。'
            : '决定已保存，孩子可以查看结果。';
      });
    } on ParentApiException catch (failure) {
      if (current && failure.code == 'REAUTH_REQUIRED') {
        setState(() => needsVerification = true);
      }
      rethrow;
    }
  }

  Future<void> recover() async {
    if (busy || !current || !foreground) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await sendOriginal();
    } catch (failure) {
      if (current) setState(() => error = familyError(failure));
    } finally {
      if (current) setState(() => busy = false);
    }
    await load();
  }

  Future<void> checkOriginal() async {
    if (busy || !current || pending == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await requests.read(pending!['id']);
      if (current) {
        setState(
            () => receipt = '原申请当前状态：${stateLabel(result.state)}。查询不会重新提交决定。');
      }
    } catch (failure) {
      if (current) setState(() => error = familyError(failure));
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!current || !foreground) {
      return const Center(child: Text('申请内容已隐藏，请返回家庭首页重新打开。'));
    }
    return RefreshIndicator(
        onRefresh: () => load(),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Text('消息与待办', style: Theme.of(context).textTheme.headlineSmall),
          const Text('给孩子一个明确答复，也让每次延长有清楚的结束时间。'),
          if (busy) const LinearProgressIndicator(),
          if (error != null) FamilyNotice(error!, error: true),
          if (receipt != null) FamilyNotice(receipt!),
          if (pending != null)
            FamilyPanel(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const Text('上次操作需要核对',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  Text(pending!['decision'] == 'APPROVE'
                      ? '原选择：延长 ${(pending!['grantedSeconds'] / 60).ceil()} 分钟'
                      : '原选择：这次不延长'),
                  const Text('掉网或退出后会保留原操作。重试会使用同一个编号，不会额外延长时间。'),
                  OutlinedButton(
                      onPressed: busy ? null : checkOriginal,
                      child: const Text('查询原申请')),
                  FilledButton(
                      onPressed: busy ? null : recover,
                      child: const Text('继续核对原操作')),
                  if (needsVerification)
                    OutlinedButton(
                        onPressed: busy
                            ? null
                            : () async {
                                await session.reauthenticate();
                                if (mounted && context.mounted) {
                                  Navigator.of(context).pop();
                                }
                              },
                        child: const Text('手机号安全验证，然后重新打开此页')),
                ])),
          if (!busy && rows.isEmpty)
            const FamilyNotice('暂时没有申请。孩子发起延长申请后，会显示在这里。'),
          ...rows.map((request) => FamilyPanel(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        '${names[request.subjectId] ?? '孩子'} · ${names[request.deviceId] ?? '儿童设备'}',
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                    Text(
                        '申请延长 ${(request.requestedSeconds / 60).ceil()} 分钟 · ${stateLabel(request.state)}'),
                    if (request.reason.isNotEmpty) Text(request.reason),
                    Text(request.notAfter == null
                        ? '申请有效至 ${familyDate(request.expiresAt)}'
                        : '放行结束：${familyDate(request.notAfter)}'),
                    if (request.state == 'PENDING')
                      Wrap(spacing: 12, children: [
                        FilledButton(
                            onPressed: busy || pending != null
                                ? null
                                : () => decide(request, true),
                            child: const Text('同意延长')),
                        OutlinedButton(
                            onPressed: busy || pending != null
                                ? null
                                : () => decide(request, false),
                            child: const Text('这次先不延长')),
                      ]),
                  ]))),
          if (cursor != null)
            OutlinedButton(
                onPressed: busy ? null : () => load(more: true),
                child: const Text('查看更多')),
        ]));
  }

  String stateLabel(String state) =>
      const {
        'PENDING': '等待答复',
        'APPROVED': '已同意',
        'DENIED': '这次未同意',
        'EXPIRED': '已到期',
        'REVOKED': '已撤销'
      }[state] ??
      '待核对';
}
