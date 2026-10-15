import 'package:flutter/material.dart';
import '../core/contracts.dart';
import '../core/commercial_entitlements.dart';
import '../core/paged_collection.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';

class ContractsCenter extends StatefulWidget {
  final ParentSession session;
  final ContractAcceptanceStore? store;
  const ContractsCenter({super.key, required this.session, this.store});
  @override
  State<ContractsCenter> createState() => _ContractsCenterState();
}

class _ContractsCenterState extends State<ContractsCenter>
    with WidgetsBindingObserver {
  ParentSession get session => widget.session;
  late final String tenant, actor, role, name;
  late final int generation;
  late final ParentContractsRepository repository;
  late final PagedCollection contracts;
  late final ContractAcceptance acceptance;
  ContractReview? selected;
  ContractComparison? comparison;
  ParentCommercialEntitlements? rights;
  final events = <ContractHistory>[];
  final search = TextEditingController();
  int? before;
  bool foreground = true, loading = false, historyLoading = false;
  int detailEpoch = 0;
  Object? error, historyError, rightsError;
  Route<dynamic>? dialog;
  bool get current =>
      mounted &&
      session.authenticated &&
      session.tenant?['id'] == tenant &&
      session.tenant?['kind'] == 'ORGANIZATION' &&
      session.profile?['subject'] == actor &&
      session.role == role &&
      session.generation == generation &&
      const {'OWNER', 'ORG_ADMIN', 'AUDITOR'}.contains(role);
  bool get available => current && foreground;
  bool get canAccept =>
      available &&
      role != 'AUDITOR' &&
      !loading &&
      !acceptance.busy &&
      acceptance.loaded &&
      acceptance.pending == null &&
      selected?.state == 'AWAITING_CUSTOMER' &&
      selected?.sourceState == 'ACTIVE' &&
      selected!.expiresAt > DateTime.now().millisecondsSinceEpoch &&
      comparison?.factsMatch == true;
  @override
  void initState() {
    super.initState();
    tenant = session.tenant!['id'];
    name = session.tenant!['name'];
    actor = session.profile!['subject'];
    role = session.role;
    generation = session.generation;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    repository = ParentContractsRepository(
        api: session.api, tenant: tenant, current: () => available);
    contracts = PagedCollection(session.api, repository.path,
        isCurrent: () => available,
        validateItem: (r) {
          final review =
              repository.parse(() => ContractReview.parse(r, platform: false));
          if (review.tenantId != tenant) {
            throw const ParentApiException(502, 'INVALID_CONTRACT_RESPONSE');
          }
        });
    acceptance = ContractAcceptance(
        repository: repository,
        store: widget.store ?? ContractAcceptanceStore(),
        actor: actor,
        isCurrent: () => available);
    acceptance.load();
  }

  void _changed() {
    if (!mounted || current) return;
    detailEpoch++;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      if (dialog?.isActive == true) dialog!.navigator?.removeRoute(dialog!);
      final route = ModalRoute.of(context);
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      detailEpoch++;
      loading = false;
      historyLoading = false;
      acceptance.suspend();
      if (dialog?.isActive == true) dialog!.navigator?.removeRoute(dialog!);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    detailEpoch++;
    session.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    contracts.dispose();
    acceptance.dispose();
    search.dispose();
    super.dispose();
  }

  String date(int milliseconds) {
    final d = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
    return MaterialLocalizations.of(context).formatShortDate(d);
  }

  Future<bool> _confirm(String title, String text, String label) async {
    if (!available) return false;
    final route = DialogRoute<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(title),
                content: SingleChildScrollView(child: Text(text)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('返回核对')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(label))
                ]));
    dialog = route;
    try {
      return await Navigator.of(context).push(route) == true && available;
    } finally {
      if (identical(route, dialog)) dialog = null;
    }
  }

  Future<void> _open(String id) async {
    if (!available || acceptance.busy) return;
    final ticket = ++detailEpoch;
    setState(() {
      loading = true;
      selected = null;
      comparison = null;
      rights = null;
      error = null;
      rightsError = null;
      events.clear();
      before = null;
      historyError = null;
      historyLoading = false;
    });
    try {
      final view = await repository.get(id);
      if (!available || ticket != detailEpoch) return;
      setState(() => selected = view);
      final comparisonView = await repository.comparison(view);
      if (!available || ticket != detailEpoch) return;
      setState(() => comparison = comparisonView);
    } catch (e) {
      if (available && ticket == detailEpoch) setState(() => error = e);
    } finally {
      if (mounted && ticket == detailEpoch) setState(() => loading = false);
    }
    if (available && ticket == detailEpoch && selected != null) {
      await _history();
      await _rights(ticket);
    }
  }

  Future<void> _history({bool more = false}) async {
    if (!available ||
        selected == null ||
        historyLoading ||
        (more && before == null)) return;
    final ticket = detailEpoch,
        id = selected!.id,
        cursor = more ? before : null;
    setState(() {
      historyLoading = true;
      historyError = null;
    });
    try {
      final page = await repository.history(id, before: cursor);
      if (!available || ticket != detailEpoch) return;
      if (more &&
          page.items
              .any((e) => events.any((old) => old.version == e.version))) {
        throw const ParentApiException(502, 'INVALID_CONTRACT_RESPONSE');
      }
      setState(() {
        if (!more) events.clear();
        events.addAll(page.items);
        before = page.nextBeforeVersion;
      });
    } catch (e) {
      if (available && ticket == detailEpoch) setState(() => historyError = e);
    } finally {
      if (mounted && ticket == detailEpoch) {
        setState(() => historyLoading = false);
      }
    }
  }

  Future<void> _rights(int ticket) async {
    try {
      final raw = await session.api.send(
          'GET', '/tenants/$tenant/commercial-entitlements',
          isCurrent: () => available && ticket == detailEpoch);
      final value = ParentCommercialEntitlements.parse(raw as Json, tenant);
      if (available && ticket == detailEpoch) setState(() => rights = value);
    } catch (e) {
      if (available && ticket == detailEpoch) setState(() => rightsError = e);
    }
  }

  Future<void> _accept() async {
    if (!canAccept) return;
    final review = selected!, snapshot = comparison!;
    if (!await _confirm(
        '确认这份机构合同？',
        '机构：$name\n合同编号：${review.contractReference}\n服务名额：${catalogLabel(review.capacityKind)} ${review.deviceCapacity} 台\n服务期：${date(review.activeFrom)} 至 ${date(review.expiresAt)}\n\n确认将把这份已独立审核的合同记录应用到机构权益。价格、付款和合同责任以已签署文件为准；不会在此页面扣款。设备系统能力仍需单独验收。',
        '确认合同权益')) return;
    if (!canAccept ||
        selected?.id != review.id ||
        selected?.version != review.version) return;
    await acceptance.submit(review, snapshot);
    if (available) await _rights(detailEpoch);
  }

  Future<void> _finishRecovery() async {
    if (!available || acceptance.busy || !acceptance.queried) return;
    final id = acceptance.pending!['reviewId'] as String;
    if (acceptance.latest?.state == 'AWAITING_CUSTOMER' &&
        !await _confirm(
            '重新核对后再确认？', '当前合同仍待机构确认。清除本机提醒后会重新读取合同和报价，不会自动提交。', '重新核对合同')) {
      return;
    }
    if (!await acceptance.clear() || !available) return;
    await contracts.reload();
    await _open(id);
  }

  Widget failure(Object e) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(contractError(e),
          style: TextStyle(color: Theme.of(context).colorScheme.error)));
  Widget recovery() => Card(
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('核对上一次合同确认', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            const Text('这里显示合同当前状态，不判断是哪一次请求或哪位管理员完成的。不会自动重复确认。'),
            if (acceptance.latest != null)
              Text('最新状态：${contractReviewLabel(acceptance.latest!)}'),
            if (acceptance.error != null) failure(acceptance.error!),
            OutlinedButton(
                onPressed: acceptance.busy
                    ? null
                    : () async {
                        await acceptance.recover();
                        if (available) await _rights(detailEpoch);
                      },
                child: const Text('查询合同当前状态')),
            if (acceptance.queried)
              FilledButton(
                  onPressed: acceptance.busy ? null : _finishRecovery,
                  child: Text(acceptance.latest?.state == 'AWAITING_CUSTOMER'
                      ? '已核对，重新查看合同'
                      : '完成核对并刷新')),
            ExpansionTile(title: const Text('确认记录'), children: [
              SelectableText(
                  '记录编号：${acceptance.pending!['reviewId']}\n提交前版本：${acceptance.pending!['version']}')
            ])
          ])));
  List<Widget> list() => [
        Text('机构合同', style: Theme.of(context).textTheme.headlineSmall),
        Text(name),
        const SizedBox(height: 8),
        const Text('查看签约服务、核对报价并确认权益。合同须先完成独立审核；审计员仅查看。'),
        TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                labelText: '查找已加载的合同编号', prefixIcon: Icon(Icons.search))),
        if (contracts.loading) const LinearProgressIndicator(),
        if (contracts.error != null) ...[
          failure(contracts.error!),
          TextButton(onPressed: contracts.reload, child: const Text('重新加载合同'))
        ],
        if (contracts.loaded && contracts.items.isEmpty)
          const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('暂无合同。请联系机构采购负责人，由服务方提交已签署合同并完成独立审核后，再在这里核对。')),
        for (final raw in contracts.items.where((r) =>
            r['contractReference'].toString().contains(search.text.trim())))
          Builder(builder: (context) {
            final r = ContractReview.parse(raw, platform: false);
            return Card(
                child: ListTile(
                    onTap:
                        loading || acceptance.busy ? null : () => _open(r.id),
                    leading: const Icon(Icons.description_outlined),
                    title: Text(r.contractReference),
                    subtitle: Text(
                        '${contractReviewLabel(r)}\n${r.deviceCapacity} 台 · 截至 ${date(r.expiresAt)}'),
                    trailing: const Icon(Icons.chevron_right)));
          }),
        if (contracts.hasMore)
          TextButton(
              onPressed: contracts.loadingMore ? null : contracts.loadMore,
              child: const Text('加载更多合同'))
      ];
  List<Widget> detail() {
    final r = selected!;
    return [
      Text(r.contractReference,
          style: Theme.of(context).textTheme.headlineSmall),
      Text(contractReviewLabel(r)),
      const SizedBox(height: 12),
      Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${r.deviceCapacity} 台',
                        style: Theme.of(context).textTheme.headlineMedium),
                    Text(
                        '${catalogLabel(r.capacityKind)} · 服务期 ${date(r.activeFrom)} 至 ${date(r.expiresAt)}'),
                    const SizedBox(height: 10),
                    if (r.features.isEmpty)
                      const Text('本记录没有附加功能权益。')
                    else
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final feature in r.features)
                          Chip(label: Text(catalogLabel(feature)))
                      ]),
                    const SizedBox(height: 8),
                    const Text('此处展示核验后的服务事实。价格与付款以已签合同为准。')
                  ]))),
      const SizedBox(height: 12),
      Text('与当前报价核对', style: Theme.of(context).textTheme.titleMedium),
      if (comparison == null)
        const Text('报价尚未核对，不能确认。')
      else ...[
        Text(comparison!.factsMatch ? '合同事实与当前报价一致' : '当前报价存在差异，暂不能确认'),
        for (final issue in comparison!.issues)
          Text('• ${contractComparisonIssueLabel(issue)}'),
        if (comparison!.offer != null)
          Text(
              '${catalogLabel(comparison!.offer!.platform)} · ${catalogLabel(comparison!.offer!.deviceMode)} · ${catalogLabel(comparison!.offer!.billingPeriod)}'),
      ],
      const SizedBox(height: 12),
      const Text('付费权益不会赋予手机或电视原本不具备的系统管控能力，也不会替代设备授权。'),
      if (role == 'AUDITOR') const Text('当前为审计员，可查看合同和历史；确认由机构管理员完成。'),
      OutlinedButton.icon(
          onPressed: loading || acceptance.busy ? null : () => _open(r.id),
          icon: const Icon(Icons.refresh),
          label: const Text('重新核对合同与报价')),
      const Divider(),
      Text('机构当前权益', style: Theme.of(context).textTheme.titleMedium),
      if (rights != null)
        Text(
            '当前有效设备名额 ${rights!.paidDeviceCapacity} 台 · 有效来源 ${rights!.activeSourceCount} 份\n这是当前汇总权益，可能与某一份历史合同不同。')
      else
        const Text('当前权益尚未读取。'),
      if (rightsError != null) ...[
        failure(rightsError!),
        TextButton(
            onPressed: () => _rights(detailEpoch), child: const Text('刷新当前权益'))
      ],
      const Divider(),
      Text('处理记录', style: Theme.of(context).textTheme.titleMedium),
      if (historyLoading) const LinearProgressIndicator(),
      if (historyError != null) ...[
        failure(historyError!),
        TextButton(onPressed: _history, child: const Text('重新加载处理记录'))
      ],
      for (final event in events)
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.history),
            title: Text(contractActionLabel(event.action)),
            subtitle: Text('${date(event.occurredAt)} · 版本 ${event.version}')),
      if (before != null)
        TextButton(
            onPressed: historyLoading ? null : () => _history(more: true),
            child: const Text('查看更早记录')),
      ExpansionTile(title: const Text('合同核验信息'), children: [
        SelectableText(
            '采购方参考：${r.buyerReference}\n合同记录：${r.id}\n来源版本：${r.sourceRevision}\n报价版本：${r.offerRevision}\n证据摘要：${r.evidenceHash}')
      ])
    ];
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: Listenable.merge([contracts, acceptance]),
      builder: (context, _) => Scaffold(
          appBar: AppBar(
              title: const Text('机构合同'),
              leading: selected == null
                  ? null
                  : IconButton(
                      tooltip: '返回合同目录',
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () {
                        detailEpoch++;
                        setState(() {
                          selected = null;
                          comparison = null;
                          loading = false;
                          historyLoading = false;
                          error = null;
                        });
                      })),
          body: !available
              ? const Center(child: Text('合同信息已隐藏。'))
              : RefreshIndicator(
                  onRefresh: contracts.reload,
                  child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(20),
                      children: [
                        if (loading || acceptance.busy)
                          const LinearProgressIndicator(),
                        if (!acceptance.loaded) ...[
                          const Text('先读取本机待核对记录。'),
                          if (acceptance.error != null)
                            failure(acceptance.error!),
                          TextButton(
                              onPressed:
                                  acceptance.busy ? null : acceptance.load,
                              child: const Text('重新读取确认记录'))
                        ],
                        if (acceptance.pending != null)
                          recovery()
                        else if (acceptance.error != null)
                          failure(acceptance.error!),
                        if (error != null) failure(error!),
                        if (acceptance.error is ParentApiException &&
                            (acceptance.error as ParentApiException).code ==
                                'REAUTH_REQUIRED')
                          OutlinedButton(
                              onPressed: acceptance.busy
                                  ? null
                                  : () => session.signIn(stepUp: true),
                              child: const Text('进行安全验证')),
                        if (selected == null) ...list() else ...detail()
                      ])),
          bottomNavigationBar: available &&
                  selected?.state == 'AWAITING_CUSTOMER' &&
                  role != 'AUDITOR' &&
                  acceptance.pending == null
              ? SafeArea(
                  top: false,
                  child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: FilledButton(
                          onPressed: canAccept ? _accept : null,
                          child: const Text('核对并确认合同'))))
              : null));
}
