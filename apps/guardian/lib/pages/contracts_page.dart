import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/api.dart';
import '../core/contracts.dart';
import '../core/contracts_repository.dart';
import '../core/contract_action_resume.dart';
import '../core/commercial_catalog.dart' show catalogLabel;
import '../core/commercial_entitlements.dart' show commercialFeatureLabel;
import '../core/session.dart';
import '../ui/design.dart';

/// Platform review and institution acceptance share one read-only layout and distinct APIs.
class ContractsPage extends StatefulWidget {
  final Session session;
  final bool platform;
  const ContractsPage(
      {super.key, required this.session, required this.platform});

  @override
  State<ContractsPage> createState() => _ContractsPageState();
}

class _ContractsPageState extends State<ContractsPage> {
  late final String actorId, tenantId, initialRole;
  late final ContractsRepository repository;
  final reviews = <ContractReview>[];
  final events = <ContractHistory>[];
  ContractReview? selected;
  ContractComparison? comparison;
  ContractCapabilities? capabilities;
  String? selectedId, nextCursor;
  String? resumeAction;
  int? nextBeforeVersion;
  Object? listError,
      detailError,
      historyError,
      comparisonError,
      capabilityError;
  bool loadingList = false,
      loadingMore = false,
      loadingDetail = false,
      loadingHistory = false,
      loadingComparison = false;
  int generation = 0, listGeneration = 0, detailGeneration = 0;

  bool current() {
    final session = widget.session;
    return session.authenticated &&
        session.profile?['subject'] == actorId &&
        (widget.platform
            ? session.canOpen('contracts')
            : session.tenant?['id'] == tenantId &&
                session.role == initialRole &&
                session.canOpen('institution-contracts'));
  }

  @override
  void initState() {
    super.initState();
    actorId = widget.session.profile!['subject'] as String;
    tenantId = widget.session.tenant?['id'] as String? ?? '';
    initialRole = widget.session.role;
    repository = widget.platform
        ? ContractsRepository.platform(
            api: widget.session.api, current: current)
        : ContractsRepository.tenant(
            api: widget.session.api, current: current, tenantId: tenantId);
    final resumed =
        widget.session.takeContractActionResume(platform: widget.platform);
    selectedId = resumed?.reviewId;
    resumeAction = resumed?.action;
    widget.session.addListener(accessChanged);
    if (widget.platform) loadCapabilities();
    loadList();
  }

  void accessChanged() {
    if (!current() && mounted) {
      generation++;
      listGeneration++;
      detailGeneration++;
      setState(() {
        reviews.clear();
        events.clear();
        selected = null;
        comparison = null;
        selectedId = nextCursor = null;
        resumeAction = null;
        nextBeforeVersion = null;
        capabilities = null;
        listError = const ApiFailure(403, 'SCOPE_DENIED');
        detailError = historyError = comparisonError = capabilityError = null;
        loadingList = loadingMore =
            loadingDetail = loadingHistory = loadingComparison = false;
      });
    }
  }

  @override
  void dispose() {
    generation++;
    listGeneration++;
    detailGeneration++;
    widget.session.removeListener(accessChanged);
    super.dispose();
  }

  Future<void> loadCapabilities() async {
    if (!current() || !widget.platform) return;
    final ticket = generation;
    try {
      final value = await repository.capabilities();
      if (!mounted || !current() || ticket != generation) return;
      setState(() {
        capabilities = value;
        capabilityError = null;
      });
    } catch (failure) {
      if (mounted && current() && ticket == generation) {
        setState(() => capabilityError = failure);
      }
    }
  }

  Future<void> loadList({bool more = false}) async {
    if (!current() || (more && (nextCursor == null || loadingMore))) return;
    final ticket = generation;
    if (!more) listGeneration++;
    final listTicket = listGeneration;
    final cursor = more ? nextCursor : null;
    setState(() {
      if (more) {
        loadingMore = true;
      } else {
        loadingList = true;
        listError = null;
      }
    });
    try {
      final page = await repository.list(cursor: cursor);
      if (!mounted ||
          !current() ||
          ticket != generation ||
          listTicket != listGeneration) return;
      if (more &&
          page.items.any((item) => reviews.any((old) => old.id == item.id))) {
        throw const ApiFailure(502, 'INVALID_CONTRACT_RESPONSE');
      }
      setState(() {
        if (!more) reviews.clear();
        reviews.addAll(page.items);
        nextCursor = page.nextCursor;
        loadingList = loadingMore = false;
      });
      if (!more && selectedId != null) await select(selectedId!);
    } catch (failure) {
      if (mounted &&
          current() &&
          ticket == generation &&
          listTicket == listGeneration) {
        setState(() {
          listError = failure;
          loadingList = loadingMore = false;
        });
      }
    }
  }

  Future<void> select(String id) async {
    if (!current() || !isContractId(id)) return;
    final ticket = ++detailGeneration;
    setState(() {
      if (selectedId != id) resumeAction = null;
      selectedId = id;
      selected = null;
      comparison = null;
      events.clear();
      nextBeforeVersion = null;
      detailError = historyError = comparisonError = null;
      loadingDetail = true;
      loadingHistory = false;
      loadingComparison = false;
    });
    try {
      final detail = await repository.get(id);
      if (!mounted || !current() || ticket != detailGeneration) return;
      setState(() {
        selected = detail;
        loadingDetail = false;
      });
      await Future.wait([
        loadHistory(id, ticket),
        loadComparison(detail, ticket),
      ]);
    } catch (failure) {
      if (mounted && current() && ticket == detailGeneration) {
        setState(() {
          detailError = failure;
          loadingDetail = false;
        });
      }
    }
  }

  Future<void> loadComparison(ContractReview review, int ticket) async {
    if (!current() || ticket != detailGeneration) return;
    setState(() {
      loadingComparison = true;
      comparisonError = null;
    });
    try {
      final result = await repository.comparison(review);
      if (!mounted || !current() || ticket != detailGeneration) return;
      setState(() {
        comparison = result;
        loadingComparison = false;
      });
    } catch (failure) {
      if (mounted && current() && ticket == detailGeneration) {
        setState(() {
          comparison = null;
          comparisonError = failure;
          loadingComparison = false;
        });
      }
    }
  }

  Future<void> loadHistory(String id, int ticket, {bool more = false}) async {
    if (!current() ||
        ticket != detailGeneration ||
        (more && (nextBeforeVersion == null || loadingHistory))) return;
    final before = more ? nextBeforeVersion : null;
    setState(() {
      loadingHistory = true;
      historyError = null;
    });
    try {
      final page = await repository.history(id, beforeVersion: before);
      if (!mounted || !current() || ticket != detailGeneration) return;
      if (more &&
          page.items.any(
              (item) => events.any((old) => old.version == item.version))) {
        throw const ApiFailure(502, 'INVALID_CONTRACT_RESPONSE');
      }
      setState(() {
        if (!more) events.clear();
        events.addAll(page.items);
        nextBeforeVersion = page.nextBeforeVersion;
        loadingHistory = false;
      });
    } catch (failure) {
      if (mounted && current() && ticket == detailGeneration) {
        setState(() {
          historyError = failure;
          loadingHistory = false;
        });
      }
    }
  }

  Future<void> submitEvidence() async {
    if (!current() ||
        capabilities?.canSubmit != true ||
        !widget.session.canManageContracts) return;
    final result = await showDialog<ContractReview>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _EvidenceDialog(
            repository: repository,
            revocationOnly: capabilities?.submissionEnabled != true,
            reauthenticate: () => widget.session.login(stepUp: true)));
    if (!mounted || !current() || result == null) return;
    setState(() => selectedId = result.id);
    await loadList();
  }

  Future<void> act(ContractReview review, String action) async {
    if (!current()) return;
    final result = await showDialog<ContractReview>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ContractActionDialog(
            review: review,
            action: action,
            operation: (reason) => switch (action) {
                  'approve' => repository.approve(review, reason),
                  'reject' => repository.reject(review, reason),
                  _ => repository.accept(review)
                },
            reauthenticate: () => widget.session.reauthenticateContractAction(
                ContractActionResume(review.id, action),
                platform: widget.platform)));
    if (!mounted || !current()) return;
    if (result != null) {
      setState(() => resumeAction = null);
      await loadList();
    } else if (mounted && current()) {
      await select(review.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 950;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageHeading(
          widget.platform ? '平台机构合同' : '机构合同',
          widget.platform
              ? '核验签约事实，独立审核后由机构确认；提交或审核不会自动赋予设备管控能力。'
              : '核对本机构合同、设备名额和服务期限，再由管理员确认生效。',
          action: Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
                onPressed: loadingList || !current() ? null : () => loadList(),
                icon: const Icon(Icons.refresh),
                label: const Text('刷新')),
            if (widget.platform && widget.session.canManageContracts)
              FilledButton.icon(
                  onPressed: capabilities?.canSubmit == true && current()
                      ? submitEvidence
                      : null,
                  icon: const Icon(Icons.add),
                  label: Text(capabilities?.submissionEnabled == true
                      ? '提交签约或撤销事实'
                      : capabilities?.revocationSubmissionEnabled == true
                          ? '提交签名撤销'
                          : '提交签约证据'))
          ])),
      if (widget.platform && capabilities != null && !capabilities!.canSubmit)
        const Notice('合同证据提供方尚未启用，暂不能提交合同事实。审核与查询仅用于已有记录；机构签约、支付和开票未开放。',
            warning: true),
      if (widget.platform &&
          capabilities?.submissionEnabled == false &&
          capabilities?.revocationSubmissionEnabled == true)
        const Notice('新合同受理已暂停。仅可提交可信签发方的签名撤销事实，经独立审批后停止对应来源权益。',
            warning: true),
      if (!widget.platform)
        const Notice(
            '只有本机构所有者或机构管理员可以确认。确认前请核对签约主体、服务期限、名额及设备适用范围；功能权益不保证设备具备受管系统权限。'),
      if (resumeAction != null)
        Notice('安全验证已返回，请重新核对最新合同与报价后再${switch (resumeAction) {
          'approve' => '批准',
          'reject' => '驳回',
          _ => '确认'
        }}。此前操作未自动提交；审核原因需要重新填写。'),
      if (capabilityError != null) ...[
        const SizedBox(height: 12),
        FailureView(capabilityError!, retry: loadCapabilities)
      ],
      const SizedBox(height: 18),
      _summary(),
      const SizedBox(height: 18),
      if (compact)
        Column(children: [_list(), const SizedBox(height: 16), _detail()])
      else
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 4, child: _list()),
          const SizedBox(width: 18),
          Expanded(flex: 6, child: _detail())
        ])
    ]);
  }

  Widget _summary() {
    final counts = {
      for (final state in contractStates)
        state: reviews.where((item) => item.state == state).length
    };
    return Wrap(spacing: 12, runSpacing: 12, children: [
      for (final state in contractStates)
        SizedBox(
            width: 174,
            child: Panel(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(contractStateLabel(state),
                          style: const TextStyle(fontSize: 12, color: muted)),
                      const SizedBox(height: 6),
                      Text('${counts[state]}',
                          style: const TextStyle(
                              fontSize: 25, fontWeight: FontWeight.w700))
                    ])))
    ]);
  }

  Widget _list() => Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('合同记录（已加载）',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (loadingList) const LinearProgressIndicator(),
        if (listError != null) FailureView(listError!, retry: () => loadList()),
        if (!loadingList && reviews.isEmpty && listError == null)
          EmptyView(
              '暂无合同记录',
              widget.platform
                  ? '签约证据接入并完成校验后，记录会出现在这里。'
                  : '本机构目前没有待确认或已生效的合同。'),
        for (final review in reviews)
          Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                  color: review.id == selectedId
                      ? const Color(0xFFEAF2FC)
                      : canvas,
                  borderRadius: BorderRadius.circular(10),
                  child: ListTile(
                      key: ValueKey('contract-review-${review.id}'),
                      selected: review.id == selectedId,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      title: Text(review.contractReference,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          '${review.deviceCapacity} 台 · ${_date(review.updatedAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      trailing: _state(review),
                      onTap: current() ? () => select(review.id) : null))),
        if (loadingMore) const LinearProgressIndicator(),
        if (nextCursor != null)
          TextButton.icon(
              onPressed: loadingMore ? null : () => loadList(more: true),
              icon: const Icon(Icons.expand_more),
              label: const Text('加载更多'))
      ]));

  Widget _detail() => Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (loadingDetail) const LinearProgressIndicator(),
        if (detailError != null)
          FailureView(detailError!,
              retry: selectedId == null ? null : () => select(selectedId!)),
        if (!loadingDetail && selected == null && detailError == null)
          const EmptyView('选择一份合同', '查看签约事实、名额与下一步操作。'),
        if (selected != null) ...[
          Row(children: [
            Expanded(
                child: Text(selected!.contractReference,
                    style: const TextStyle(
                        fontSize: 19, fontWeight: FontWeight.w700))),
            _state(selected!)
          ]),
          const SizedBox(height: 8),
          Text('合同记录 ${selected!.id}',
              style: const TextStyle(fontSize: 12, color: muted)),
          const SizedBox(height: 14),
          if (selected!.state == 'AWAITING_CUSTOMER')
            const Notice('平台已独立审核，权益尚未生效。机构负责人确认后才会写入商业账本。'),
          if (selected!.sourceState == 'REVOKED')
            Notice(
                selected!.state == 'APPLIED'
                    ? '签发方撤销已执行，对应来源权益已经停止。基础安全策略仍继续适用。'
                    : '这是签发方的撤销事实。独立审批通过后将停止对应来源权益。',
                warning: true),
          const SizedBox(height: 18),
          Wrap(spacing: 14, runSpacing: 16, children: [
            _fact('机构标识', selected!.tenantId),
            _fact('采购方引用', selected!.buyerReference),
            _fact('产品报价',
                '${selected!.offerId} · 第 ${selected!.offerRevision} 版'),
            _fact('签发来源版本', '第 ${selected!.sourceRevision} 版'),
            _fact('设备名额',
                '${selected!.capacityKind == 'BASE' ? '基础' : '附加'} ${selected!.deviceCapacity} 台'),
            _fact('来源状态', selected!.sourceState == 'ACTIVE' ? '有效' : '撤销'),
            _fact('签约确认时间', _date(selected!.executedAt)),
            _fact('服务开始', _date(selected!.activeFrom)),
            _fact('服务结束', _date(selected!.expiresAt)),
            _fact('签名断言摘要', selected!.evidenceHash),
            _fact(
                '授权功能',
                selected!.features.isEmpty
                    ? '未配置'
                    : selected!.features.map(commercialFeatureLabel).join('、'))
          ]),
          const SizedBox(height: 18),
          const Text('报价与签约事实对照',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (loadingComparison) const LinearProgressIndicator(),
          if (comparisonError != null)
            FailureView(comparisonError!,
                retry: () => loadComparison(selected!, detailGeneration)),
          if (comparison != null) ...[
            Notice(
                comparison!.factsMatch
                    ? '当前报价版本、设备名额和功能与签名事实一致；正式审批时服务端仍会重新核验。'
                    : '发现报价或签约条件变化。请核对并处理差异；当前无法批准或确认。',
                warning: !comparison!.factsMatch),
            if (comparison!.issues.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(comparison!.issues
                      .map(contractComparisonIssueLabel)
                      .join(' · '))),
            if (comparison!.offer != null) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 14, runSpacing: 16, children: [
                _fact('报价状态', catalogLabel(comparison!.offerState)),
                _fact('当前版本', '${comparison!.currentOfferRevision}'),
                _fact('产品 SKU', comparison!.offer!.sku),
                _fact('适用平台', catalogLabel(comparison!.offer!.platform)),
                _fact('设备模式', catalogLabel(comparison!.offer!.deviceMode)),
                _fact('计费周期', catalogLabel(comparison!.offer!.billingPeriod)),
                _fact('报价名额',
                    '${comparison!.offer!.capacityKind == 'BASE' ? '基础' : '附加'} ${comparison!.offer!.deviceCapacity} 台'),
                _fact(
                    '报价功能',
                    comparison!.offer!.features.isEmpty
                        ? '未配置'
                        : comparison!.offer!.features
                            .map(commercialFeatureLabel)
                            .join('、')),
                _fact('报价有效期',
                    '${_date(comparison!.offer!.availableFrom)} 至 ${_date(comparison!.offer!.availableUntil)}')
              ])
            ],
            const SizedBox(height: 8),
            const Text('此处不包含合同金额、签约主体法定身份或原始合同文件；请在签发方系统核对。',
                style: TextStyle(fontSize: 12, color: muted))
          ],
          const SizedBox(height: 18),
          if (widget.platform) ...[
            Text(
                '提交者 ${selected!.submittedBy ?? '—'} · 审批人 ${selected!.approvedBy ?? '待审核'}',
                style: const TextStyle(color: muted, fontSize: 12)),
            const SizedBox(height: 14),
            if (selected!.state == 'PENDING_REVIEW' &&
                widget.session.canApproveContracts &&
                selected!.submittedBy != actorId)
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                    onPressed: current() && comparison?.factsMatch == true
                        ? () => act(selected!, 'approve')
                        : null,
                    icon: const Icon(Icons.verified_outlined),
                    label: Text(selected!.sourceState == 'REVOKED'
                        ? '核验撤销'
                        : '批准，待机构确认')),
                OutlinedButton.icon(
                    onPressed:
                        current() ? () => act(selected!, 'reject') : null,
                    icon: const Icon(Icons.close),
                    label: const Text('驳回'))
              ])
          ] else if (selected!.state == 'AWAITING_CUSTOMER' &&
              ['OWNER', 'ORG_ADMIN'].contains(widget.session.role))
            FilledButton.icon(
                onPressed: current() && comparison?.factsMatch == true
                    ? () => act(selected!, 'accept')
                    : null,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('核对并确认生效')),
          if (selected!.state == 'APPLIED' &&
              selected!.sourceState == 'ACTIVE') ...[
            const SizedBox(height: 12),
            const Notice('商业权益已记录。设备系统策略是否真正执行，仍以设备能力与回执为准。')
          ],
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 18),
          const Text('审核与确认记录',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('摘要对应签名断言，不是合同文件摘要；正式证据请在签发方系统核对。',
              style: TextStyle(fontSize: 12, color: muted)),
          if (loadingHistory) const LinearProgressIndicator(),
          if (historyError != null)
            FailureView(historyError!,
                retry: () => loadHistory(selected!.id, detailGeneration,
                    more: nextBeforeVersion != null)),
          if (!loadingHistory && historyError == null && events.isEmpty)
            const EmptyView('暂无审核事件', '请刷新合同记录；若持续缺失，请联系平台运维核对。'),
          for (final event in events)
            ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                    '第 ${event.version} 步 · ${contractActionLabel(event.action)}'),
                subtitle: Text(widget.platform && event.actorId != null
                    ? '${_date(event.occurredAt)} · ${event.actorId}'
                    : _date(event.occurredAt)),
                children: [
                  Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.platform)
                              Text('原因：${event.reason ?? '流程提交或机构确认'}')
                            else
                              const Text('操作详情由平台审计记录保管。'),
                            if (widget.platform && event.correlationId != null)
                              SelectableText('关联请求 ${event.correlationId}',
                                  style: const TextStyle(
                                      fontSize: 11, color: muted))
                          ]))
                ]),
          if (nextBeforeVersion != null)
            TextButton.icon(
                onPressed: loadingHistory
                    ? null
                    : () =>
                        loadHistory(selected!.id, detailGeneration, more: true),
                icon: const Icon(Icons.expand_more),
                label: const Text('更多记录'))
        ]
      ]));

  Widget _fact(String name, String value) => SizedBox(
      width: 250,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(fontSize: 12, color: muted)),
        const SizedBox(height: 4),
        SelectableText(value, style: const TextStyle(fontSize: 13, color: ink))
      ]));

  Widget _state(ContractReview review) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
          color: review.state == 'APPLIED' && review.sourceState == 'ACTIVE'
              ? const Color(0xFFE6F4EF)
              : review.state == 'REJECTED' || review.sourceState == 'REVOKED'
                  ? const Color(0xFFFBEDEC)
                  : const Color(0xFFF0F3F8),
          borderRadius: BorderRadius.circular(6)),
      child: Text(contractReviewLabel(review),
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: review.state == 'APPLIED' && review.sourceState == 'ACTIVE'
                  ? const Color(0xFF087A5C)
                  : review.state == 'REJECTED' ||
                          review.sourceState == 'REVOKED'
                      ? const Color(0xFFA7473C)
                      : muted)));

  String _date(int millis) => DateFormat('yyyy-MM-dd HH:mm')
      .format(DateTime.fromMillisecondsSinceEpoch(millis));
}

class _EvidenceDialog extends StatefulWidget {
  final ContractsRepository repository;
  final bool revocationOnly;
  final VoidCallback reauthenticate;
  const _EvidenceDialog(
      {required this.repository,
      required this.revocationOnly,
      required this.reauthenticate});

  @override
  State<_EvidenceDialog> createState() => _EvidenceDialogState();
}

class _EvidenceDialogState extends State<_EvidenceDialog> {
  final evidence = TextEditingController();
  late final String id = widget.repository.newId();
  Object? error;
  bool saving = false;

  @override
  void dispose() {
    evidence.clear();
    evidence.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final token = evidence.text.trim();
    if (token.isEmpty || token.length > 16384) {
      setState(
          () => error = const ApiFailure(400, 'INVALID_CONTRACT_EVIDENCE'));
      return;
    }
    setState(() {
      error = null;
      saving = true;
    });
    try {
      final result = await widget.repository.create(id, token);
      if (mounted) Navigator.of(context).pop(result);
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = failure;
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.revocationOnly ? '提交签名撤销事实' : '提交已签名合同事实'),
          content: SizedBox(
              width: 520,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Notice(widget.revocationOnly
                        ? '仅粘贴可信签发方按需签发的 REVOKED 短期 JWS。新合同受理已暂停；撤销仍需独立审批。'
                        : '仅粘贴可信签发方按需签发的短期 JWS。提交后进入独立审核，暂不产生权益；不要粘贴合同全文或付款信息。'),
                    const SizedBox(height: 16),
                    TextField(
                        controller: evidence,
                        enabled: !saving,
                        maxLines: 5,
                        maxLength: 16384,
                        decoration: const InputDecoration(
                            labelText: '签名断言', hintText: '以三段点分隔的 JWS')),
                    if (error != null) ...[
                      FailureView(error!),
                      if (error is ApiFailure &&
                          (error as ApiFailure).status == 401)
                        Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('返回后请向签发方重新索取短期断言，再提交待审。'),
                              TextButton.icon(
                                  onPressed: widget.reauthenticate,
                                  icon:
                                      const Icon(Icons.verified_user_outlined),
                                  label: const Text('重新安全验证'))
                            ])
                    ]
                  ])),
          actions: [
            TextButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: saving ? null : submit,
                child: Text(saving ? '提交中…' : '提交待审'))
          ]);
}

class _ContractActionDialog extends StatefulWidget {
  final ContractReview review;
  final String action;
  final Future<ContractReview> Function(String) operation;
  final VoidCallback reauthenticate;
  const _ContractActionDialog(
      {required this.review,
      required this.action,
      required this.operation,
      required this.reauthenticate});

  @override
  State<_ContractActionDialog> createState() => _ContractActionDialogState();
}

class _ContractActionDialogState extends State<_ContractActionDialog> {
  final reason = TextEditingController();
  Object? error;
  bool saving = false;

  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  Future<void> confirm() async {
    final text = reason.text.trim();
    if (widget.action != 'accept' &&
        (text.length < 5 ||
            text.length > 500 ||
            text.runes.any((rune) => rune < 32 || rune == 127))) {
      setState(() => error = const ApiFailure(400, 'INVALID_CONTRACT_REASON'));
      return;
    }
    setState(() {
      error = null;
      saving = true;
    });
    try {
      final result = await widget.operation(text);
      if (mounted) Navigator.of(context).pop(result);
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = failure;
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(switch (widget.action) {
            'approve' =>
              widget.review.sourceState == 'REVOKED' ? '核验撤销事实' : '独立批准合同',
            'reject' => '驳回合同',
            _ => '机构确认合同'
          }),
          content: SizedBox(
              width: 460,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '${widget.review.contractReference} · ${widget.review.deviceCapacity} 台 · ${contractStateLabel(widget.review.state)}'),
                    const SizedBox(height: 12),
                    Notice(
                        widget.action == 'accept'
                            ? '请确认采购主体、服务期限和名额。确认后商业权益将立即记录。'
                            : widget.review.sourceState == 'REVOKED'
                                ? '批准撤销后，对应来源权益将立即停止。请核实签署事实与来源版本。'
                                : '批准后仍需目标机构管理员确认，权益才会生效。',
                        warning: widget.review.sourceState == 'REVOKED'),
                    if (widget.action != 'accept') ...[
                      const SizedBox(height: 16),
                      TextField(
                          controller: reason,
                          enabled: !saving,
                          maxLines: 3,
                          maxLength: 500,
                          decoration: const InputDecoration(
                              labelText: '审核原因', hintText: '至少 5 字，写明核验依据'))
                    ],
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      FailureView(error!),
                      if (error is ApiFailure &&
                          (error as ApiFailure).status == 401)
                        TextButton.icon(
                            onPressed: widget.reauthenticate,
                            icon: const Icon(Icons.verified_user_outlined),
                            label: const Text('重新安全验证')),
                      if (error is ApiFailure &&
                          (error as ApiFailure).status == 412)
                        const Notice('合同版本已变化。关闭窗口后刷新最新记录再操作。', warning: true)
                    ]
                  ])),
          actions: [
            TextButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: saving ? null : confirm,
                child: Text(saving ? '提交中…' : '确认操作'))
          ]);
}
