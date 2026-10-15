import 'package:flutter/material.dart';

import '../core/commercial_entitlements.dart';
import '../core/parent_session.dart';
import 'contracts_center.dart';

/// Keep the account projection bound to the current identity and workspace.
class CommercialAccount extends StatelessWidget {
  final ParentSession session;
  const CommercialAccount({super.key, required this.session});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        if (!session.authenticated ||
            session.tenant == null ||
            !const {'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'AUDITOR'}
                .contains(session.role)) return const SizedBox.shrink();
        return _ScopedCommercialAccount(
            key: ValueKey(
                '${session.profile?['subject']}:${session.tenant?['id']}:${session.role}:${session.generation}'),
            session: session);
      });
}

class _ScopedCommercialAccount extends StatefulWidget {
  final ParentSession session;
  const _ScopedCommercialAccount({super.key, required this.session});
  @override
  State<_ScopedCommercialAccount> createState() => _CommercialAccountState();
}

class _CommercialAccountState extends State<_ScopedCommercialAccount>
    with WidgetsBindingObserver {
  late final String tenantId, actor, role;
  late final int generation;
  late Future<ParentCommercialEntitlements> result;
  bool foreground = true;
  bool get current =>
      mounted &&
      foreground &&
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenantId &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role &&
      widget.session.generation == generation;
  @override
  void initState() {
    super.initState();
    tenantId = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    generation = widget.session.generation;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    result = _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (mounted) {
      setState(() {
        if (foreground) result = _load();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<ParentCommercialEntitlements> _load() async {
    final raw = await widget.session.api.send(
        'GET', '/tenants/$tenantId/commercial-entitlements',
        isCurrent: () => current);
    return ParentCommercialEntitlements.parse(raw, tenantId);
  }

  void _refresh() {
    if (current) setState(() => result = _load());
  }

  @override
  Widget build(BuildContext context) => !current
      ? const Text('商业账户信息已隐藏。')
      : FutureBuilder<ParentCommercialEntitlements>(
          future: result,
          builder: (context, snapshot) =>
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                      child: Text('商业账户',
                          style: Theme.of(context).textTheme.titleLarge)),
                  IconButton(
                      tooltip: '刷新商业账户',
                      onPressed: _refresh,
                      icon: const Icon(Icons.refresh))
                ]),
                const SizedBox(height: 5),
                if (widget.session.tenant?['kind'] == 'ORGANIZATION' &&
                    const {'OWNER', 'ORG_ADMIN', 'AUDITOR'}.contains(role))
                  OutlinedButton.icon(
                      onPressed: () async {
                        await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) =>
                                    ContractsCenter(session: widget.session)));
                        if (current) _refresh();
                      },
                      icon: const Icon(Icons.description_outlined),
                      label: const Text('机构合同与确认')),
                if (snapshot.connectionState != ConnectionState.done)
                  const LinearProgressIndicator()
                else if (snapshot.hasError) ...[
                  Text('${snapshot.error}',
                      style: const TextStyle(color: Color(0xFF9A3931))),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: _refresh, child: const Text('重试'))
                ] else if (snapshot.hasData)
                  _AccountView(snapshot.data!)
              ]));
}

class _AccountView extends StatelessWidget {
  final ParentCommercialEntitlements rights;
  const _AccountView(this.rights);

  @override
  Widget build(BuildContext context) {
    final checked =
        DateTime.fromMillisecondsSinceEpoch(rights.evaluatedAt).toLocal();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('已核验的合同权益；是否可在设备执行仍需单独核对。'),
      const SizedBox(height: 13),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('当前付费设备名额'),
            const SizedBox(height: 5),
            Semantics(
              label: '当前付费设备名额 ${rights.paidDeviceCapacity}',
              excludeSemantics: true,
              child: Text('${rights.paidDeviceCapacity}',
                  style: const TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF17324B))),
            ),
            Text(
                '基础 ${rights.baseDeviceCapacity} + 加购 ${rights.addOnDeviceCapacity} · 有效来源 ${rights.activeSourceCount}'),
            const SizedBox(height: 7),
            if (rights.activeSourceCount == 0)
              const Text('暂无已核验付费来源。基础安全功能和设备退出不因此关闭。'),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      const Text('当前功能权益', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      if (rights.features.isEmpty)
        const Text('暂无已核验的付费功能权益。')
      else
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final feature in rights.features)
            Chip(
                label:
                    Text(ParentCommercialEntitlements.featureNames[feature]!)),
        ]),
      const SizedBox(height: 11),
      const Text('受管设备、网站过滤和智能建议还需分别满足设备模式、授权与地区发布条件。',
          style: TextStyle(color: Color(0xFF315E86))),
      const SizedBox(height: 8),
      Text(
          '权益版本 ${rights.version} · 核算 ${checked.year}-${checked.month.toString().padLeft(2, '0')}-${checked.day.toString().padLeft(2, '0')} ${checked.hour.toString().padLeft(2, '0')}:${checked.minute.toString().padLeft(2, '0')}',
          style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}
