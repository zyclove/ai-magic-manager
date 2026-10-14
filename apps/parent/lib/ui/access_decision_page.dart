import 'package:flutter/material.dart';
import '../core/access_decision.dart';
import '../core/parent_session.dart';
import '../core/pending_decisions.dart';

Future<String?> showAccessDecision(
        BuildContext context, ParentSession session, String requestId,
        {bool approve = true}) =>
    Navigator.of(context).push<String>(MaterialPageRoute(
        builder: (_) => AccessDecisionPage(
            session: session, requestId: requestId, approve: approve)));

/// One confirmation surface used by both inbox and notification detail.
class AccessDecisionPage extends StatefulWidget {
  final ParentSession session;
  final String requestId;
  final bool approve;
  final PendingDecisionStore? store;
  const AccessDecisionPage(
      {super.key,
      required this.session,
      required this.requestId,
      this.approve = true,
      this.store});
  @override
  State<AccessDecisionPage> createState() => _AccessDecisionPageState();
}

class _AccessDecisionPageState extends State<AccessDecisionPage>
    with WidgetsBindingObserver {
  late final String tenant, actor, role;
  late final ParentAccessDecision c;
  late bool approve;
  bool foreground = true, acknowledged = false;
  int? seconds;
  String reason = 'NOT_NOW';
  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.canDecide &&
      widget.session.tenant?['id'] == tenant &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;
  @override
  void initState() {
    super.initState();
    tenant = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    approve = widget.approve;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    c = ParentAccessDecision(
        api: widget.session.api,
        store: widget.store ?? PendingDecisionStore(),
        tenant: tenant,
        actor: actor,
        requestId: widget.requestId,
        isCurrent: () => current,
        foreground: () => foreground,
        reauthenticate: widget.session.reauthenticate);
    widget.session.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    c.load();
  }

  void changed() {
    if (!mounted || current) return;
    c.hide();
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
    if (!foreground) {
      acknowledged = false;
      c.hide();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final r = c.request, p = c.pending;
        final requested = r?['requestedWindowSeconds'] as int?;
        final choices = requested == null
            ? <int>[]
            : ({
                ...{300, 600, 900, 1800}.where((v) => v < requested),
                requested
              }.toList()
              ..sort());
        final selected = choices.contains(seconds) ? seconds : requested;
        return PopScope(
            canPop: !c.busy,
            child: Scaffold(
                appBar: AppBar(title: const Text('处理访问申请')),
                body: !current || !foreground
                    ? const Center(child: Text('申请内容已隐藏。'))
                    : ListView(padding: const EdgeInsets.all(20), children: [
                        if (c.busy) const LinearProgressIndicator(),
                        if (c.error != null)
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Semantics(
                                  liveRegion: true, child: Text('${c.error}'))),
                        if (c.receipt != null)
                          Card(
                              child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text('审批决定已保存',
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineSmall),
                                        Text(
                                            accessStates[c.receipt!['state']]!),
                                        const Text(
                                            '此处显示本次提交回执。设备接收和实际系统执行需在申请详情中另行核对。'),
                                        if (p == null)
                                          FilledButton(
                                              onPressed: c.busy
                                                  ? null
                                                  : () => Navigator.pop(
                                                      context,
                                                      c.receipt!['state'] ==
                                                              'DENIED'
                                                          ? 'DENY'
                                                          : 'APPROVE'),
                                              child: const Text('完成，查看当前状态'))
                                      ]))),
                        if (p != null) ...[
                          Text('先核对上次操作',
                              style: Theme.of(context).textTheme.headlineSmall),
                          Text(
                              '原选择：${p.choice == 'APPROVE' ? '批准' : p.choice == 'DENY' ? '拒绝' : '撤销'}${p.grantedWindowSeconds == null ? '' : ' · ${_duration(p.grantedWindowSeconds!)}'}'),
                          const Text('查询只读取原申请，不会重新提交。当前状态变化不能单独证明是上次操作造成的。'),
                          if (r != null)
                            Text(
                                '当前状态：${accessStates[r['state']]} · 修订 ${r['version']}'),
                          OutlinedButton(
                              onPressed: c.busy ? null : c.load,
                              child: const Text('查询原申请')),
                          if (c.queried) ...[
                            CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                value: acknowledged,
                                onChanged: c.busy
                                    ? null
                                    : (v) => setState(
                                        () => acknowledged = v == true),
                                title: const Text('已核对当前状态及设备回执'),
                                subtitle: const Text('清除本机提醒不撤销决定，也不会自动重新提交。')),
                            FilledButton(
                                onPressed: c.busy || !acknowledged
                                    ? null
                                    : () async {
                                        if (await c.acknowledge() &&
                                            current &&
                                            context.mounted) {
                                          Navigator.pop(context);
                                        }
                                      },
                                child: const Text('清除提醒并返回'))
                          ],
                          ExpansionTile(
                              title: const Text('原操作编号'),
                              children: [SelectableText(p.idempotencyKey)]),
                        ] else if (c.receipt == null && !c.loaded) ...[
                          if (!c.busy)
                            OutlinedButton(
                                onPressed: c.load, child: const Text('重新读取申请')),
                        ] else if (c.receipt == null && r != null) ...[
                          Text(
                              '${r['subjectName'] ?? '儿童'} · ${r['applicationName'] ?? '应用'}',
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 12),
                          Text('设备：${r['deviceName'] ?? '未命名设备'}'),
                          Text('用途：${r['reason'] ?? '未填写'}'),
                          Text('申请时长：${_duration(requested!)}'),
                          ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              title: const Text('核对应用与设备编号'),
                              children: [
                                SelectableText(
                                    '包名：${r['applicationPackageName'] ?? '未提供'}\n设备：${r['deviceId']}\n申请：${r['id']}')
                              ]),
                          if (r['state'] != 'PENDING')
                            Text('当前状态：${accessStates[r['state']]}，无需重复处理。')
                          else ...[
                            const SizedBox(height: 12),
                            Wrap(spacing: 8, children: [
                              ChoiceChip(
                                  label: const Text('批准'),
                                  selected: approve,
                                  onSelected: c.busy
                                      ? null
                                      : (_) => setState(() => approve = true)),
                              ChoiceChip(
                                  label: const Text('拒绝'),
                                  selected: !approve,
                                  onSelected: c.busy
                                      ? null
                                      : (_) => setState(() => approve = false))
                            ]),
                            const SizedBox(height: 16),
                            if (approve) ...[
                              DropdownButtonFormField<int>(
                                  value: selected,
                                  isExpanded: true,
                                  isDense: false,
                                  decoration:
                                      const InputDecoration(labelText: '允许时长'),
                                  items: [
                                    for (final v in choices)
                                      DropdownMenuItem(
                                          value: v,
                                          child: Text(
                                              '${_duration(v)}${v == requested ? '（申请上限）' : ''}'))
                                  ],
                                  onChanged: c.busy
                                      ? null
                                      : (v) => setState(() => seconds = v)),
                              const SizedBox(height: 12),
                              const Text('时长不超过孩子的申请。批准后仍需等待设备接收与执行。'),
                            ] else
                              DropdownButtonFormField<String>(
                                  value: reason,
                                  isExpanded: true,
                                  isDense: false,
                                  decoration:
                                      const InputDecoration(labelText: '拒绝原因'),
                                  items: [
                                    for (final e in denialReasons.entries)
                                      DropdownMenuItem(
                                          value: e.key, child: Text(e.value))
                                  ],
                                  onChanged: c.busy
                                      ? null
                                      : (v) => setState(() => reason = v!)),
                            const SizedBox(height: 24),
                            FilledButton.icon(
                                key: const Key('access-decision-submit'),
                                onPressed: c.busy
                                    ? null
                                    : () => c.execute(
                                        choice: approve ? 'APPROVE' : 'DENY',
                                        seconds: approve ? selected : null,
                                        reason: approve ? null : reason),
                                icon: const Icon(Icons.verified_user_outlined),
                                label: Text(approve ? '安全验证并批准' : '安全验证并拒绝')),
                          ],
                        ],
                      ])));
      });
}

String _duration(int seconds) =>
    seconds % 60 == 0 ? '${seconds ~/ 60} 分钟' : '$seconds 秒';
