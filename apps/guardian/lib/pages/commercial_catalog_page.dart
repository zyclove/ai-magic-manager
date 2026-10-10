// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/api.dart';
import '../core/commercial_catalog.dart';
import '../core/commercial_catalog_repository.dart';
import '../core/session.dart';
import '../ui/design.dart';
import 'commercial_catalog_editor.dart';

/// Global platform operations; a tenant workspace is never used as authorization.
class CommercialCatalogPage extends StatefulWidget {
  final Session session;
  const CommercialCatalogPage({super.key, required this.session});

  @override
  State<CommercialCatalogPage> createState() => _CommercialCatalogPageState();
}

class _CommercialCatalogPageState extends State<CommercialCatalogPage> {
  late final String actorId, selectionKey;
  late final CommercialCatalogRepository repository;
  final offers = <CatalogOffer>[];
  final events = <CatalogHistory>[];
  CatalogOffer? selected;
  String? selectedId, nextCursor;
  int? nextBeforeRevision;
  Object? listError, detailError, historyError;
  bool loadingList = false,
      loadingMore = false,
      loadingDetail = false,
      loadingHistory = false;
  int generation = 0, listGeneration = 0, detailGeneration = 0;

  bool current() =>
      widget.session.authenticated &&
      widget.session.profile?['subject'] == actorId &&
      widget.session.canOpen('catalog');

  @override
  void initState() {
    super.initState();
    actorId = widget.session.profile!['subject'] as String;
    selectionKey = 'ai-manager.catalog.selected.$actorId';
    repository =
        CommercialCatalogRepository(api: widget.session.api, current: current);
    widget.session.addListener(accessChanged);
    final stored = html.window.sessionStorage[selectionKey];
    if (stored != null && isCatalogId(stored)) selectedId = stored;
    loadList();
  }

  void accessChanged() {
    if (!current() && mounted) {
      generation++;
      listGeneration++;
      detailGeneration++;
      html.window.sessionStorage.remove(selectionKey);
      setState(() {
        offers.clear();
        events.clear();
        selected = null;
        selectedId = null;
        nextCursor = null;
        listError = const ApiFailure(403, 'SCOPE_DENIED');
        detailError = null;
        historyError = null;
        loadingList = loadingMore = loadingDetail = loadingHistory = false;
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
          cursor != null &&
          page.items.any((item) => offers.any((old) => old.id == item.id))) {
        throw const ApiFailure(502, 'INVALID_CATALOG_RESPONSE');
      }
      setState(() {
        if (!more) offers.clear();
        offers.addAll(page.items);
        nextCursor = page.nextCursor;
        loadingList = loadingMore = false;
      });
      if (!more && selectedId != null && selected == null) {
        await select(selectedId!);
      }
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
    if (!current() || !isCatalogId(id)) return;
    final ticket = ++detailGeneration;
    html.window.sessionStorage[selectionKey] = id;
    setState(() {
      selectedId = id;
      selected = null;
      events.clear();
      nextBeforeRevision = null;
      detailError = historyError = null;
      loadingDetail = loadingHistory = true;
    });
    try {
      final detail = await repository.get(id);
      if (!mounted || !current() || ticket != detailGeneration) return;
      setState(() {
        selected = detail;
        loadingDetail = false;
      });
    } catch (failure) {
      if (mounted && current() && ticket == detailGeneration) {
        setState(() {
          detailError = failure;
          loadingDetail = loadingHistory = false;
        });
      }
      return;
    }
    try {
      final page = await repository.history(id);
      if (!mounted || !current() || ticket != detailGeneration) return;
      setState(() {
        events.addAll(page.items);
        nextBeforeRevision = page.nextBeforeRevision;
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

  Future<void> moreHistory() async {
    final id = selectedId, before = nextBeforeRevision;
    if (!current() || id == null || before == null || loadingHistory) return;
    final ticket = detailGeneration;
    setState(() => loadingHistory = true);
    try {
      final page = await repository.history(id, beforeRevision: before);
      if (!mounted || !current() || ticket != detailGeneration) return;
      setState(() {
        events.addAll(page.items);
        nextBeforeRevision = page.nextBeforeRevision;
        historyError = null;
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

  Future<void> edit([CatalogOffer? existing]) async {
    if (!current() || !widget.session.canManageCatalog) return;
    final result = await showDialog<CatalogOffer>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CommercialCatalogEditor(
            repository: repository, existing: existing));
    if (!mounted || !current()) return;
    if (result != null) {
      await loadList();
      if (mounted && current()) await select(result.id);
    } else if (existing != null) {
      await select(existing.id);
    }
  }

  Future<void> action(CatalogOffer offer, String title, String explanation,
      Future<CatalogOffer> Function(String) operation) async {
    if (!current()) return;
    final result = await showDialog<CatalogOffer>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CatalogActionDialog(
            title: title,
            explanation: explanation,
            offer: offer,
            operation: operation,
            reauthenticate: () => widget.session.login(stepUp: true)));
    if (!mounted || !current()) return;
    if (result != null) await loadList();
    if (mounted && current()) await select(offer.id);
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 950;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageHeading('平台产品目录', '管理内部报价草稿、独立审核与版本历史；批准不代表可售。',
          action: Wrap(spacing: 8, children: [
            OutlinedButton.icon(
                onPressed: loadingList || !current() ? null : () => loadList(),
                icon: const Icon(Icons.refresh),
                label: const Text('刷新')),
            if (widget.session.canManageCatalog)
              FilledButton.icon(
                  onPressed: current() ? () => edit() : null,
                  icon: const Icon(Icons.add),
                  label: const Text('新建草稿'))
          ])),
      const Notice('此目录仅供平台人员内部审核。没有已发布、合规且经过渠道核验的报价；家长和儿童没有购买入口。'),
      const SizedBox(height: 18),
      if (compact)
        Column(children: [_offerList(), const SizedBox(height: 16), _detail()])
      else
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(flex: 4, child: _offerList()),
          const SizedBox(width: 18),
          Expanded(flex: 6, child: _detail())
        ])
    ]);
  }

  Widget _offerList() => Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('报价草稿',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (loadingList) const LinearProgressIndicator(),
        if (listError != null) FailureView(listError!, retry: () => loadList()),
        if (!loadingList && offers.isEmpty && listError == null)
          const EmptyView('暂无报价草稿', '平台运营人员可创建第一份草稿；草稿不会对客户售卖。'),
        for (final offer in offers)
          Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                  color:
                      offer.id == selectedId ? const Color(0xFFEAF2FC) : canvas,
                  borderRadius: BorderRadius.circular(10),
                  child: ListTile(
                      key: ValueKey('catalog-offer-${offer.id}'),
                      selected: offer.id == selectedId,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      title: Text(
                          '${offer.offer['sku']} · ${offer.offer['region']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          '${catalogLabel(offer.offer['channel'])} · v${offer.revision} · ${_date(offer.updatedAt)}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      trailing: _state(offer.state),
                      onTap: current() ? () => select(offer.id) : null))),
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
          const EmptyView('选择一份草稿', '查看适用范围、价格、审核动作和历史版本。'),
        if (selected != null) ...[
          Row(children: [
            Expanded(
                child: Text(
                    '${selected!.offer['sku']} · 第 ${selected!.revision} 版',
                    style: const TextStyle(
                        fontSize: 19, fontWeight: FontWeight.w700))),
            _state(selected!.state)
          ]),
          const SizedBox(height: 8),
          Text('编号 ${selected!.id}',
              style: const TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 12),
          const Notice('当前状态不可购买。报价批准不生成权益，设备能否执行限制还需独立验证。'),
          const SizedBox(height: 18),
          _facts(selected!.offer),
          const SizedBox(height: 16),
          Text('创建者 ${selected!.createdBy} · 最近编辑 ${selected!.lastEditor}',
              style: const TextStyle(color: muted, fontSize: 12)),
          if (selected!.approvedBy != null)
            Text('审批人 ${selected!.approvedBy}',
                style: const TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 18),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (selected!.state == 'DRAFT' && widget.session.canManageCatalog)
              OutlinedButton.icon(
                  onPressed: current() ? () => edit(selected!) : null,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('修订')),
            if (selected!.state == 'DRAFT' && widget.session.canManageCatalog)
              FilledButton.icon(
                  onPressed: current()
                      ? () => action(
                          selected!,
                          '提交独立审核',
                          '提交后草稿不可再编辑。请写明本次审核原因。',
                          (reason) => repository.submit(selected!, reason))
                      : null,
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('提交审核')),
            if (selected!.state == 'IN_REVIEW' &&
                widget.session.canApproveCatalog)
              FilledButton.icon(
                  onPressed: current()
                      ? () => action(
                          selected!,
                          '批准内部草稿',
                          '审批人必须与草稿作者及提交者不同。批准后仍不可售。',
                          (reason) => repository.approve(selected!, reason))
                      : null,
                  icon: const Icon(Icons.verified_outlined),
                  label: const Text('批准草稿')),
            if (selected!.state != 'RETIRED' && widget.session.canManageCatalog)
              OutlinedButton.icon(
                  onPressed: current()
                      ? () => action(
                          selected!,
                          '下架内部草稿',
                          '下架保留完整历史。请先确认受影响的地区、渠道和产品版本。',
                          (reason) => repository.retire(selected!, reason))
                      : null,
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('下架'))
          ]),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 18),
          const Text('版本历史',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          if (loadingHistory) const LinearProgressIndicator(),
          if (historyError != null)
            FailureView(historyError!,
                retry: nextBeforeRevision == null
                    ? () => select(selected!.id)
                    : moreHistory),
          for (final entry in events)
            ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                    '第 ${entry.revision} 版 · ${catalogLabel(entry.action)}'),
                subtitle: Text('${_date(entry.occurredAt)} · ${entry.actorId}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                children: [
                  Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('原因：${entry.reason ?? '创建或修订草稿'}'),
                            const SizedBox(height: 6),
                            Text('摘要 ${entry.payloadHash}',
                                style: const TextStyle(
                                    color: muted, fontSize: 11)),
                            const SizedBox(height: 6),
                            _facts(entry.offer.toJson())
                          ]))
                ]),
          if (nextBeforeRevision != null)
            TextButton.icon(
                onPressed: loadingHistory ? null : moreHistory,
                icon: const Icon(Icons.expand_more),
                label: const Text('更多历史'))
        ]
      ]));

  Widget _facts(Map<String, dynamic> offer) {
    final rows = <(String, String)>[
      ('地区与渠道', '${offer['region']} · ${catalogLabel(offer['channel'])}'),
      (
        '客户与平台',
        '${catalogLabel(offer['buyerKind'])} · ${catalogLabel(offer['platform'])}'
      ),
      ('设备模式', catalogLabel(offer['deviceMode'])),
      (
        '价格',
        offer['priceType'] == 'QUOTE'
            ? '人工报价 · ${offer['currency']}'
            : '${offer['currency']} ${offer['priceMinor']}（最小货币单位，${catalogLabel(offer['taxBasis'])}）'
      ),
      (
        '周期与名额',
        '${catalogLabel(offer['billingPeriod'])} · ${catalogLabel(offer['capacityKind'])} ${offer['deviceCapacity']} 台'
      ),
      (
        '生效区间',
        '${_date(offer['availableFrom'])} — ${_date(offer['availableUntil'])}'
      ),
      (
        '功能',
        (offer['features'] as List).isEmpty
            ? '未配置'
            : (offer['features'] as List).map((e) => catalogLabel(e)).join('、')
      )
    ];
    return Wrap(spacing: 12, runSpacing: 12, children: [
      for (final row in rows)
        SizedBox(
            width: 260,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(row.$1, style: const TextStyle(color: muted, fontSize: 12)),
              const SizedBox(height: 4),
              Text(row.$2, style: const TextStyle(color: ink, fontSize: 13))
            ]))
    ]);
  }

  Widget _state(String value) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
          color: value == 'APPROVED'
              ? const Color(0xFFE6F4EF)
              : const Color(0xFFF0F3F8),
          borderRadius: BorderRadius.circular(6)),
      child: Text(catalogLabel(value),
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: value == 'APPROVED' ? const Color(0xFF087A5C) : muted)));

  String _date(int millis) => DateFormat('yyyy-MM-dd HH:mm')
      .format(DateTime.fromMillisecondsSinceEpoch(millis));
}

class _CatalogActionDialog extends StatefulWidget {
  final String title, explanation;
  final CatalogOffer offer;
  final Future<CatalogOffer> Function(String) operation;
  final VoidCallback reauthenticate;
  const _CatalogActionDialog(
      {required this.title,
      required this.explanation,
      required this.offer,
      required this.operation,
      required this.reauthenticate});

  @override
  State<_CatalogActionDialog> createState() => _CatalogActionDialogState();
}

class _CatalogActionDialogState extends State<_CatalogActionDialog> {
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
    if (text.length < 5 ||
        text.length > 500 ||
        text.runes.any((rune) => rune < 32 || rune == 127)) {
      setState(() => error = const ApiFailure(400, 'INVALID_CATALOG_REASON'));
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
          title: Text(widget.title),
          content: SizedBox(
              width: 420,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.explanation),
                    const SizedBox(height: 12),
                    Text(
                        'SKU ${widget.offer.offer['sku']} · ${widget.offer.offer['region']} · 第 ${widget.offer.revision} 版',
                        style: const TextStyle(color: muted)),
                    const SizedBox(height: 16),
                    TextField(
                        controller: reason,
                        enabled: !saving,
                        maxLines: 3,
                        maxLength: 500,
                        decoration: const InputDecoration(
                            labelText: '操作原因',
                            hintText: '请写明审批依据或下架原因（至少 5 字）')),
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
                        const Notice('版本已变化。关闭窗口后刷新草稿，再重新审核。', warning: true)
                    ]
                  ])),
          actions: [
            TextButton(
                onPressed: saving ? null : () => Navigator.of(context).pop(),
                child: const Text('取消')),
            FilledButton(
                onPressed: saving ? null : confirm,
                child: Text(saving ? '提交中…' : '确认操作'))
          ]);
}
