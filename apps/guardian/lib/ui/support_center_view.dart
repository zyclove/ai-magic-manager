import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/support.dart';
import '../core/support_repository.dart';
import '../core/support_diagnostic.dart';
import 'design.dart';
import 'support_diagnostic_details.dart';
import 'support_view_state.dart';

class SupportCenterView extends StatefulWidget {
  final SupportRepository repository;
  final bool Function() current;
  final Listenable? accessChanges;
  final bool canAdmin;
  final bool canReceive;
  final VoidCallback onReauth, onOpenDevices;
  const SupportCenterView(
      {super.key,
      required this.repository,
      required this.current,
      this.accessChanges,
      required this.canAdmin,
      this.canReceive = true,
      required this.onReauth,
      required this.onOpenDevices});
  @override
  State<SupportCenterView> createState() => _SupportCenterViewState();
}

class _SupportCenterViewState extends State<SupportCenterView>
    with SupportViewState<SupportCenterView> {
  int section = 0, lastTick = 0;
  CreatedSupportPairing? created;
  String? createKey, cursor;
  List<SupportPairing> pairings = [];
  List<SupportGrant> grants = [];
  SupportDiagnostic? diagnostic;
  SupportGrant? confirming;
  ({SupportPairing value, String key})? cancelPending;
  ({SupportGrant value, String key})? revokePending;
  bool loaded = false;
  @override
  bool Function() get scopeCurrent => widget.current;
  @override
  Listenable? get accessChanges => widget.accessChanges;
  @override
  Object get scopeIdentity => (
        widget.repository.actor,
        widget.repository.tenant,
        widget.canAdmin,
        widget.canReceive
      );
  @override
  void initState() {
    super.initState();
    section = widget.canReceive ? 0 : 2;
  }

  @override
  void clearSensitive() {
    created = null;
    createKey = null;
    cursor = null;
    pairings = [];
    grants = [];
    diagnostic = null;
    confirming = null;
    cancelPending = null;
    revokePending = null;
    loaded = false;
  }

  @override
  void timeChanged() {
    final stamp = now;
    if ((created != null && created!.request.expiresAt <= stamp) ||
        (diagnostic != null && diagnostic!.grant.expiresAt <= stamp) ||
        pairings.any((v) => v.expiresAt > lastTick && v.expiresAt <= stamp) ||
        grants.any((v) => v.expiresAt > lastTick && v.expiresAt <= stamp))
      setState(() {
        if (created != null && created!.request.expiresAt <= stamp)
          created = null;
        if (diagnostic != null && diagnostic!.grant.expiresAt <= stamp)
          diagnostic = null;
      });
    lastTick = stamp;
  }

  void changeSection(int value) {
    if (!usable || busy || section == value) return;
    setState(() {
      generation++;
      clearSensitive();
      error = null;
      section = value;
    });
  }

  Future<void> generate() async {
    if (!usable || busy) return;
    createKey ??= requestId();
    final key = createKey!;
    await perform(() => widget.repository.createPairing(key), (value) {
      created = value;
      createKey = null;
      pairings = [];
      cursor = null;
      loaded = false;
    }, failed: (failure) {
      if (!ambiguousSupportFailure(failure)) createKey = null;
    });
  }

  Future<void> load({bool more = false}) async {
    if (!usable || busy) return;
    final after = more ? cursor : null;
    if (more && after == null) return;
    if (!more)
      setState(() {
        pairings = [];
        grants = [];
        cursor = null;
        loaded = false;
        diagnostic = null;
        confirming = null;
      });
    if (section == 0) {
      await perform(() => widget.repository.pairings(cursor: after), (value) {
        final merged = [if (more) ...pairings, ...value.items];
        if (merged.map((v) => v.id).toSet().length != merged.length)
          invalidSupport();
        if (created != null) {
          for (final pair in value.items) {
            if (pair.id == created!.request.id)
              created = created!.refreshed(pair);
          }
        }
        pairings = merged;
        cursor = value.nextCursor;
        loaded = true;
      });
    } else {
      await perform(
          () => widget.repository.grants(received: section == 1, cursor: after),
          (value) {
        final merged = [if (more) ...grants, ...value.items];
        if (merged.map((v) => v.id).toSet().length != merged.length)
          invalidSupport();
        grants = merged;
        cursor = value.nextCursor;
        loaded = true;
      });
    }
  }

  Future<void> cancelPair(SupportPairing pair) async {
    if (!usable || busy) return;
    cancelPending ??= (value: pair, key: requestId());
    final pending = cancelPending!;
    await perform(
        () => widget.repository.cancelPairing(pending.value, pending.key),
        (value) {
      pairings = [
        for (final row in pairings)
          if (row.id == value.id) value else row
      ];
      if (created?.request.id == value.id) created = null;
      cancelPending = null;
    }, failed: (failure) {
      if (!ambiguousSupportFailure(failure)) cancelPending = null;
    });
  }

  Future<void> revoke(SupportGrant grant) async {
    if (!usable || busy) return;
    revokePending ??= (value: grant, key: requestId());
    final pending = revokePending!;
    await perform(() => widget.repository.revoke(pending.value, pending.key),
        (value) {
      grants = [
        for (final row in grants)
          if (row.id == value.id) value else row
      ];
      diagnostic = null;
      confirming = null;
      revokePending = null;
    }, failed: (failure) {
      if (!ambiguousSupportFailure(failure)) revokePending = null;
    });
  }

  Future<void> readDiagnostic(SupportGrant grant) async {
    if (!usable || busy || !grant.withinTerm(now)) return;
    setState(() => diagnostic = null);
    await perform(() => widget.repository.diagnostic(grant), (value) {
      if (value.grant.withinTerm(now))
        diagnostic = value;
      else
        error = const ApiFailure(403, 'SCOPE_DENIED');
    });
  }

  bool get pendingWrite =>
      createKey != null || cancelPending != null || revokePending != null;
  Widget pairCard(SupportPairing pair) => Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(supportPairingState(pair, now),
                style: Theme.of(context).textTheme.titleSmall),
            Text('创建：${supportTime(pair.createdAt)}'),
            Text('截止：${supportTime(pair.expiresAt)}'),
            supportFact(context, '请求标识', pair.id),
            if (pair.pendingAt(now))
              OutlinedButton(
                  onPressed: usable && !busy && !pendingWrite
                      ? () => cancelPair(pair)
                      : null,
                  child: const Text('取消配对请求')),
          ])));
  Widget grantCard(SupportGrant grant) => Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(supportGrantState(grant, now),
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (section == 2) supportFact(context, '接收人', grant.recipientLabel),
            supportFact(
                context,
                '允许范围',
                grant.diagnosticTypes
                    .map((t) => supportTypeLabels[t])
                    .join('、')),
            Text('创建：${supportTime(grant.createdAt)}'),
            Text('截止：${supportTime(grant.expiresAt)}'),
            ExpansionTile(
                tilePadding: EdgeInsets.zero,
                expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                title: const Text('查看授权标识与账号'),
                children: [
                  supportFact(context, '授权标识', grant.id),
                  supportFact(context, '工作空间标识', grant.tenantId),
                  supportFact(context, '设备标识', grant.deviceId),
                  supportFact(context, '注册标识', grant.registrationId),
                  supportFact(context, '接收人账号', grant.recipientActorId),
                  supportFact(context, '已验证邮箱',
                      grant.recipientVerifiedEmail ?? '未提供已验证邮箱')
                ]),
            if (grant.withinTerm(now) && section == 1)
              Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                      onPressed:
                          usable && !busy ? () => readDiagnostic(grant) : null,
                      icon: const Icon(Icons.search),
                      label: const Text('读取授权诊断'))),
            if (grant.state != 'REVOKED' && section == 2) ...[
              if (confirming?.id != grant.id)
                Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                        onPressed: usable && !busy && !pendingWrite
                            ? () => setState(() => confirming = grant)
                            : null,
                        child: const Text('撤销授权')))
              else ...[
                const Text('撤销后将拒绝新的诊断读取。已经保存的副本无法远程收回。'),
                Wrap(spacing: 12, children: [
                  TextButton(
                      onPressed: !busy && !pendingWrite
                          ? () => setState(() => confirming = null)
                          : null,
                      child: const Text('保留授权')),
                  FilledButton(
                      onPressed: usable && !busy && !pendingWrite
                          ? () => revoke(grant)
                          : null,
                      child: const Text('确认撤销'))
                ])
              ],
            ],
          ])));
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const PageHeading('支持协作', '先配对核对身份，再按设备开放限时诊断。所有时间按本机时区显示。'),
        if (!usable)
          Panel(
              child: Text(invalidated || !scopeCurrent()
                  ? '账号或工作空间已变化，请重新打开支持协作。'
                  : '已进入后台，配对码与诊断信息已清除。'))
        else ...[
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final entry in [
              if (widget.canReceive) (0, '我的配对请求'),
              if (widget.canReceive) (1, '收到的授权'),
              if (widget.canAdmin) (2, '本空间授权')
            ])
              ChoiceChip(
                  label: Text(entry.$2),
                  selected: section == entry.$1,
                  onSelected: !busy && !pendingWrite
                      ? (_) => changeSection(entry.$1)
                      : null)
          ]),
          const SizedBox(height: 16),
          Panel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                if (cleared)
                  const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text('敏感内容已清除，请按需重新加载。')),
                if (section == 0) ...[
                  const Text(
                      '作为支持接收人，先生成配对码，再将它提供给需要协助的客户。客户核对身份并授权后，你才能读取选定设备的诊断。'),
                  const SizedBox(height: 12),
                  Wrap(spacing: 12, runSpacing: 8, children: [
                    FilledButton.icon(
                        onPressed:
                            !busy && cancelPending == null && created == null
                                ? generate
                                : null,
                        icon: const Icon(Icons.key_outlined),
                        label: Text(createKey == null ? '生成配对码' : '重试生成结果')),
                    OutlinedButton(
                        onPressed: !busy && !pendingWrite ? () => load() : null,
                        child: const Text('刷新配对请求'))
                  ]),
                  if (created != null) ...[
                    const SizedBox(height: 16),
                    supportFact(context, '请求状态',
                        supportPairingState(created!.request, now)),
                    supportFact(
                        context, '当前接收人', created!.request.recipientLabel),
                    supportFact(context, '已验证邮箱',
                        created!.request.verifiedEmail ?? '未提供已验证邮箱'),
                    if (created!.code != null) ...[
                      supportFact(context, '一次性配对码', created!.code!),
                      const Text('请在有效期内提供给客户。页面离开或进入后台后不再显示，服务器无法再次返回原码。')
                    ] else if (created!.request.pendingAt(now))
                      const Text('请求已创建，但原配对码不会再次显示。请取消此请求后重新生成。'),
                    if (created!.request.state == 'CONSUMED')
                      const Text('客户已使用此请求完成授权。请查看收到的授权。'),
                    if (!created!.request.pendingAt(now) &&
                        created!.request.state != 'CONSUMED')
                      const Text('此配对请求已结束，可关闭这条记录后重新生成。'),
                    Text('截止：${supportTime(created!.request.expiresAt)}'),
                    Wrap(spacing: 12, children: [
                      if (created!.request.pendingAt(now))
                        OutlinedButton(
                            onPressed: !busy && !pendingWrite
                                ? () => cancelPair(created!.request)
                                : null,
                            child: const Text('取消当前配对')),
                      if (created!.request.state == 'CONSUMED')
                        OutlinedButton(
                            onPressed: !busy && !pendingWrite
                                ? () => changeSection(1)
                                : null,
                            child: const Text('查看收到的授权')),
                      TextButton(
                          onPressed: !busy && !pendingWrite
                              ? () => setState(() => created = null)
                              : null,
                          child:
                              Text(created!.code == null ? '关闭这条记录' : '隐藏配对码'))
                    ]),
                  ],
                ] else ...[
                  Text(section == 1
                      ? '这里只列出明确发给当前账号的授权。有效期内仍会在每次读取时检查客户权限和设备状态。'
                      : '这里显示本工作空间的授权历史。创建授权请前往设备详情中的“限时支持授权”。'),
                  const SizedBox(height: 12),
                  Wrap(spacing: 12, runSpacing: 8, children: [
                    FilledButton.icon(
                        onPressed: !busy && !pendingWrite ? () => load() : null,
                        icon: const Icon(Icons.refresh),
                        label: const Text('刷新授权列表')),
                    if (section == 2)
                      OutlinedButton(
                          onPressed: !busy && !pendingWrite
                              ? widget.onOpenDevices
                              : null,
                          child: const Text('前往设备管理'))
                  ]),
                ],
                if (busy)
                  const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: LinearProgressIndicator()),
                if (error != null) supportFailure(error!, widget.onReauth),
                if (createKey != null && !busy)
                  const Text('创建结果尚未确认。重试会查询同一次请求，已生成的原码不会再次返回。'),
                if (cancelPending != null && !busy)
                  OutlinedButton(
                      onPressed: () => cancelPair(cancelPending!.value),
                      child: const Text('按原请求重试取消')),
                if (revokePending != null && !busy)
                  OutlinedButton(
                      onPressed: () => revoke(revokePending!.value),
                      child: const Text('按原请求重试撤销')),
                if (loaded &&
                    (section == 0 ? pairings.isEmpty : grants.isEmpty))
                  Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(section == 0 ? '暂无配对请求。' : '暂无授权记录。')),
                if (section == 0)
                  for (final pair in pairings) pairCard(pair)
                else
                  for (final grant in grants) grantCard(grant),
                if (cursor != null)
                  Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                          onPressed: !busy && !pendingWrite
                              ? () => load(more: true)
                              : null,
                          child: const Text('加载更多'))),
              ])),
          if (diagnostic != null) ...[
            const SizedBox(height: 16),
            Panel(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  Row(children: [
                    Expanded(
                        child: Text('授权诊断',
                            style: Theme.of(context).textTheme.titleLarge)),
                    IconButton(
                        tooltip: '清除诊断',
                        onPressed: () => setState(() => diagnostic = null),
                        icon: const Icon(Icons.close))
                  ]),
                  supportFact(context, '设备标识', diagnostic!.grant.deviceId),
                  SupportDiagnosticDetails(diagnostic!)
                ]))
          ],
        ]
      ]);
}
