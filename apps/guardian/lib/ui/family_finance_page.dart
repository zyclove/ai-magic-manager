import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/family_finance.dart';
import '../core/finance_storage_port.dart';
import 'design.dart';

String financeMoney(dynamic value) =>
    value is int ? '¥${(value / 100).toStringAsFixed(2)}' : '待核对';
String financeTime(dynamic value) {
  if (value is! int) return '待核对';
  final date = DateTime.fromMillisecondsSinceEpoch(value, isUtc: true)
      .add(const Duration(hours: 8));
  return '${date.year}/${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

String financeRefundLabel(dynamic state) =>
    const {
      'AWAITING_REVIEW': '待人工审核',
      'REQUESTED': '审核通过，等待退款',
      'DECLINED': '审核未通过',
      'PROCESSING': '正在原路退款',
      'REFUNDED': '渠道已确认退款',
      'CLOSED': '退款已关闭',
      'ABNORMAL': '需要人工协助',
    }[state] ??
    '待核对';
String financeBillLabel(dynamic state) =>
    const {
      'PENDING': '等待核对',
      'RUNNING': '正在核对',
      'MATCHED': '已对平',
      'DIFFERENCES': '发现差异，仍需核对',
      'PARTIAL': '部分核对，仍需检查',
      'UNAVAILABLE': '账单暂不可用',
      'FAILED': '核对未完成',
      'ATTENTION': '需要人工处理',
      'INVALID_BILL': '账单校验未通过',
    }[state] ??
    '待核对';
String _errorMessage(Object error) {
  if (error is! ApiFailure) return '暂时无法完成，请刷新后重试。';
  final message = switch (error.code) {
    'FINANCE_RECOVERY_INVALID' ||
    'FINANCE_RECOVERY_UNAVAILABLE' =>
      '无法读取原操作记录，已停止新操作。请重新打开本页或联系管理员核对。',
    'FINANCE_RECOVERY_PENDING' => '有一笔原操作需要核对，请先继续原操作，避免重复处理。',
    'PREVIEW_STALE' ||
    'REFUND_PREVIEW_STALE' ||
    'REFUND_PREVIEW_CHANGED' =>
      '退款权益已变化，请刷新并重新预览后确认。',
    'REFUND_REVIEW_NOT_PENDING' => '此申请已由其他审核处理，请刷新查看当前结果。',
    'FAMILY_BILL_DATE_UNAVAILABLE' =>
      '请选择上海时区过去三个月内的已结束日期。昨天的账单需在今天 10:00 后核对。此请求未提交，可修改日期重新确认。',
    'FAMILY_BILL_ATTEMPTS_EXHAUSTED' => '已达到核对尝试上限，请人工检查原账单和差异记录。此次重试未执行。',
    'FAMILY_BILL_ACKNOWLEDGEMENT_IMMUTABLE' =>
      '其他人已记录此差异的跟进说明，不能覆盖。此次说明未提交，请刷新查看当前记录。',
    _ => error.message,
  };
  return error.correlationId == null
      ? message
      : '$message\n问题编号：${error.correlationId}';
}

/// Platform scope is independent of the currently selected tenant workspace.
class FamilyFinancePage extends StatefulWidget {
  final Api api;
  final String actor;
  final bool canReviewRefunds, canManageFinance;
  final Listenable changes;
  final bool Function() isCurrent;
  final VoidCallback reauthenticate;
  final FinanceStringStorage? storage;
  const FamilyFinancePage(
      {super.key,
      required this.api,
      required this.actor,
      required this.canReviewRefunds,
      required this.canManageFinance,
      required this.changes,
      required this.isCurrent,
      required this.reauthenticate,
      this.storage});
  @override
  State<FamilyFinancePage> createState() => _FamilyFinancePageState();
}

class _FamilyFinancePageState extends State<FamilyFinancePage>
    with WidgetsBindingObserver {
  late final FamilyFinanceRepository repository;
  late final FamilyFinanceOperations operations;
  final orderSearch = TextEditingController();
  late final TextEditingController billDate;
  List<Json> refunds = [], tasks = [], differences = [];
  String? refundsCursor, tasksCursor, differencesCursor;
  Json? refund, preview, task;
  String? selectedRefundId, selectedTaskId;
  String status = 'AWAITING_REVIEW';
  int tab = 0, epoch = 0;
  bool busy = false, confirming = false, foreground = true, invalidated = false;
  Object? error, recoveryError;
  String? message;
  BuildContext? dialogContext;
  bool get active =>
      mounted && !invalidated && foreground && widget.isCurrent();
  bool get working => busy || confirming;
  bool get writesReady => operations.loaded && operations.pending == null;
  bool get pendingAccessible {
    final path = operations.pending?['path'] as String?;
    return path != null &&
        (path.startsWith('$familyRefundRoot/')
            ? widget.canReviewRefunds
            : widget.canManageFinance);
  }

  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    tab = widget.canReviewRefunds ? 0 : 1;
    repository =
        FamilyFinanceRepository(api: widget.api, available: () => active);
    operations = FamilyFinanceOperations(
        api: widget.api,
        actor: widget.actor,
        available: () => active,
        canReviewRefunds: () => widget.canReviewRefunds,
        canManageFinance: () => widget.canManageFinance,
        storage: widget.storage);
    final yesterday = DateTime.now()
        .toUtc()
        .add(const Duration(hours: 8))
        .subtract(const Duration(days: 1));
    billDate = TextEditingController(
        text: yesterday.toIso8601String().substring(0, 10));
    widget.changes.addListener(scopeChanged);
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void didUpdateWidget(covariant FamilyFinancePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes.removeListener(scopeChanged);
      widget.changes.addListener(scopeChanged);
    }
    if (oldWidget.actor != widget.actor ||
        oldWidget.api != widget.api ||
        oldWidget.canReviewRefunds != widget.canReviewRefunds ||
        oldWidget.canManageFinance != widget.canManageFinance) invalidate();
  }

  @override
  void dispose() {
    widget.changes.removeListener(scopeChanged);
    WidgetsBinding.instance.removeObserver(this);
    orderSearch.dispose();
    billDate.dispose();
    super.dispose();
  }

  void clearData() {
    refunds = [];
    tasks = [];
    differences = [];
    refund = null;
    preview = null;
    task = null;
    error = null;
    message = null;
  }

  void dismissDialog() {
    final context = dialogContext;
    dialogContext = null;
    if (confirming &&
        context != null &&
        context.mounted &&
        ModalRoute.of(context)?.isCurrent == true) {
      confirming = false;
      Navigator.of(context).pop();
    }
  }

  void invalidate() {
    if (!mounted) return;
    epoch++;
    dismissDialog();
    setState(() {
      invalidated = true;
      clearData();
    });
  }

  void scopeChanged() {
    if (!widget.isCurrent()) invalidate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final resumed = state == AppLifecycleState.resumed;
    epoch++;
    if (!resumed) dismissDialog();
    setState(() {
      foreground = resumed;
      if (!resumed) clearData();
    });
    if (resumed && !invalidated && !busy) load();
  }

  Future<void> load({bool more = false}) async {
    if (!active || working) return;
    final captured = epoch;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!operations.loaded) {
        try {
          await operations.restore();
          recoveryError = null;
        } catch (e) {
          recoveryError = e;
        }
      }
      if (tab == 0 && widget.canReviewRefunds) {
        if (selectedRefundId != null && !more) {
          await readRefund(selectedRefundId!);
        } else {
          final page = await repository.refunds(
              status: status,
              orderId: orderSearch.text.trim().isEmpty
                  ? null
                  : orderSearch.text.trim(),
              cursor: more ? refundsCursor : null);
          if (active && captured == epoch) {
            setState(() {
              refunds = more ? [...refunds, ...page.items] : page.items;
              refundsCursor = page.nextCursor;
            });
          }
        }
      } else if (tab == 1 && widget.canManageFinance) {
        if (selectedTaskId != null && !more) {
          await readTask(selectedTaskId!);
        } else {
          final page =
              await repository.tasks(cursor: more ? tasksCursor : null);
          if (active && captured == epoch) {
            setState(() {
              tasks = more ? [...tasks, ...page.items] : page.items;
              tasksCursor = page.nextCursor;
            });
          }
        }
      }
    } catch (e) {
      if (active && captured == epoch) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> readRefund(String id) async {
    final captured = epoch, value = await repository.refund(id);
    Json? nextPreview;
    if (value['status'] == 'AWAITING_REVIEW' && value['canReview'] == true) {
      nextPreview = await repository.preview(id);
      if (nextPreview['order']['id'] != value['orderId']) {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
    }
    if (active && captured == epoch) {
      setState(() {
        selectedRefundId = id;
        refund = value;
        preview = nextPreview;
      });
    }
  }

  Future<void> readTask(String id) async {
    final captured = epoch,
        value = await repository.task(id),
        page = await repository.differences(id);
    if (active && captured == epoch) {
      setState(() {
        selectedTaskId = id;
        task = value;
        differences = page.items;
        differencesCursor = page.nextCursor;
      });
    }
  }

  Future<void> openRefund(String id) async {
    if (!active || working) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await readRefund(id);
    } catch (e) {
      if (active) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> openTask(String id) async {
    if (!active || working) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await readTask(id);
    } catch (e) {
      if (active) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> moreDifferences() async {
    if (!active || working || task == null || differencesCursor == null) return;
    final captured = epoch;
    setState(() => busy = true);
    try {
      final page =
          await repository.differences(task!['id'], cursor: differencesCursor);
      if (active && captured == epoch) {
        setState(() {
          differences = [...differences, ...page.items];
          differencesCursor = page.nextCursor;
        });
      }
    } catch (e) {
      if (active) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> confirm(
      {required String title,
      required String detail,
      required String action,
      bool note = false,
      String? initialNote}) async {
    if (!active || working) return null;
    final captured = epoch;
    var text = initialNote ?? '';
    setState(() => confirming = true);
    try {
      final result = await showDialog<String>(
          context: context,
          builder: (context) {
            dialogContext = context;
            return StatefulBuilder(
                builder: (context, refresh) => AlertDialog(
                      title: Text(title),
                      scrollable: true,
                      content: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(detail),
                            if (note) ...[
                              const SizedBox(height: 16),
                              TextField(
                                  maxLength: 200,
                                  minLines: 2,
                                  maxLines: 4,
                                  decoration: const InputDecoration(
                                      labelText: '审核或跟进说明',
                                      helperText: '至少 5 字，请勿填写验证码或其他隐私资料'),
                                  onChanged: (value) =>
                                      refresh(() => text = value)),
                            ],
                          ]),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: note && text.trim().length < 5
                                ? null
                                : () => Navigator.pop(
                                    context, note ? text.trim() : 'CONFIRMED'),
                            child: Text(action))
                      ],
                    ));
          });
      dialogContext = null;
      return active && captured == epoch ? result : null;
    } finally {
      if (mounted) setState(() => confirming = false);
    }
  }

  Future<void> write(Future<Json> Function() operation, String success) async {
    if (!active || working) return;
    final captured = epoch;
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      await operation();
      if (active && captured == epoch) setState(() => message = success);
    } catch (e) {
      if (active && captured == epoch) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (active && captured == epoch && error == null) await load();
  }

  Future<void> review(String decision) async {
    if (!active ||
        working ||
        !writesReady ||
        !widget.canReviewRefunds ||
        refund?['canReview'] != true ||
        preview == null) return;
    final currentRefund = refund!, currentPreview = preview!;
    final note = await confirm(
        title: decision == 'APPROVE' ? '通过全额退款审核' : '不通过退款审核',
        detail:
            '退款金额：${financeMoney(currentRefund['priceMinor'])}\n\n${currentPreview['consequence']}\n\n保留其他续费：${(currentPreview['preservedOrders'] as List).length} 笔。审核通过后服务自动办理原路退款；本操作不会直接认定到账。',
        action: decision == 'APPROVE' ? '确认通过' : '确认不通过',
        note: true);
    if (note != null) {
      await write(
          () => operations.review(currentRefund['id'],
              decision: decision,
              previewHash: currentPreview['previewHash'],
              note: note),
          decision == 'APPROVE'
              ? '审核已记录。退款由服务自动办理，到账以渠道确认结果为准。'
              : '审核已记录：未通过。不会由此发起退款。');
    }
  }

  Future<void> resumeOriginal() async {
    if (!active ||
        working ||
        !operations.loaded ||
        operations.pending == null ||
        !pendingAccessible) return;
    final original = operations.pending!,
        path = original['path'] as String,
        body = original['body'] as Json;
    final confirmValue = await confirm(
        title: '核对原操作',
        detail:
            '将继续上次已保存的操作，使用原编号与原内容。不会另建一笔。\n\n${body['decision'] == null ? '' : body['decision'] == 'APPROVE' ? '原退款决定：通过\n' : '原退款决定：不通过\n'}${body['billDate'] == null ? '' : '账单日期：${body['billDate']}\n'}${body['note'] == null ? '' : '原说明：${body['note']}\n'}\n核对完成后仍以当前服务端记录为准。',
        action: '确认重试原操作');
    if (confirmValue == null) return;
    await write(
        () => operations.retry(),
        path.endsWith('/verifications')
            ? '已安排核对原单，请刷新查看后续结果。'
            : '原操作已核对，请以当前记录为准。');
  }

  Future<void> requestBill() async {
    if (!active || working || !writesReady || !widget.canManageFinance) return;
    final date = billDate.text.trim();
    if (!validFinanceDate(date)) {
      setState(() => error = const ApiFailure(400, 'VALIDATION_FAILED'));
      return;
    }
    final okay = await confirm(
        title: '核对微信日账单',
        detail:
            '账单日期：$date（上海时区）\n\n服务会下载渠道账单并核对本地订单与退款。账单不可用、读取不完整或存在差异时，会如实标记，不会显示已对平。',
        action: '确认核对');
    if (okay != null) {
      await write(() => operations.requestBill(date), '账单核对任务已受理，请查看处理进度。');
    }
  }

  Future<void> retryBill() async {
    if (!active ||
        working ||
        !writesReady ||
        task == null ||
        task!['status'] == 'ATTENTION' ||
        task!['attemptCount'] >= 50) return;
    final selected = task!;
    final okay = await confirm(
        title: '重新核对原账单',
        detail: '将重新核对 ${selected['billDate']} 的原任务。已有人工跟进记录会保留；未解决的差异仍会显示。',
        action: '确认重新核对');
    if (okay != null) {
      await write(
          () => operations.retryBill(selected['id']), '已安排重新核对，请查看原任务进度。');
    }
  }

  Future<void> followDifference(Json difference) async {
    if (!active ||
        working ||
        !writesReady ||
        task == null ||
        difference['state'] != 'OPEN') return;
    final id = task!['id'] as String;
    final note = await confirm(
        title: '记录人工跟进',
        detail: '记录说明会保留此差异，不会把账单标记为已对平。请说明已核对的依据与后续处理。',
        action: '确认记录',
        note: true);
    if (note != null) {
      await write(() => operations.acknowledge(id, difference['id'], note),
          '已记录人工跟进，差异仍需核对。');
    }
  }

  Future<void> verifyOriginal({Json? difference}) async {
    if (!active || working || !writesReady) return;
    final refundId = refund?['id'] as String?, taskId = task?['id'] as String?;
    final okay = await confirm(
        title: '安排原单核对',
        detail: '服务会查询原订单或退款单的微信渠道状态。此操作不提交新退款，不修改金额，也不直接认定已对平。',
        action: '确认安排核对');
    if (okay == null) return;
    if (difference == null && refundId != null) {
      await write(
          () => operations.verifyRefund(refundId), '已安排核对原单，请刷新查看后续结果。');
    }
    if (difference != null && taskId != null) {
      await write(() => operations.verifyDifference(taskId, difference['id']),
          '已安排核对原单，请刷新查看后续结果。');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (invalidated || !widget.isCurrent()) {
      return const Center(child: Text('权限或身份已变化，请重新打开家庭售后。'));
    }
    if (!foreground) return const Center(child: Text('返回页面后重新读取当前记录。'));
    if (!widget.canReviewRefunds && !widget.canManageFinance) {
      return const Center(child: Text('当前账号没有家庭售后或账单权限。'));
    }
    return LayoutBuilder(
        builder: (context, constraints) => ListView(
                shrinkWrap: !constraints.hasBoundedHeight,
                physics: constraints.hasBoundedHeight
                    ? null
                    : const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(24),
                children: [
                  const PageHeading('家庭订阅售后', '退款先审核，到账看渠道；账单差异保留依据并持续核对。'),
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    if (widget.canReviewRefunds)
                      ChoiceChip(
                          label: const Text('退款售后'),
                          selected: tab == 0,
                          onSelected: working
                              ? null
                              : (_) {
                                  setState(() {
                                    tab = 0;
                                    error = null;
                                  });
                                  load();
                                }),
                    if (widget.canManageFinance)
                      ChoiceChip(
                          label: const Text('日账单'),
                          selected: tab == 1,
                          onSelected: working
                              ? null
                              : (_) {
                                  setState(() {
                                    tab = 1;
                                    error = null;
                                  });
                                  load();
                                }),
                    OutlinedButton.icon(
                        onPressed: working ? null : load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('刷新')),
                  ]),
                  const SizedBox(height: 20),
                  if (busy) const LinearProgressIndicator(),
                  if (error != null)
                    _Notice(_errorMessage(error!), error: true),
                  if (error is ApiFailure &&
                      (error as ApiFailure).code == 'REAUTH_REQUIRED')
                    Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton(
                            onPressed: working
                                ? null
                                : () {
                                    invalidate();
                                    widget.reauthenticate();
                                  },
                            child: const Text('完成安全验证'))),
                  if (recoveryError != null)
                    _Notice(_errorMessage(recoveryError!), error: true),
                  if (message != null) _Notice(message!),
                  if (operations.pending != null && !pendingAccessible)
                    const _Notice('原操作需要的权限已变化，请由有权限的账号核对原记录。当前操作未被自动重试。'),
                  if (operations.pending != null && pendingAccessible)
                    Panel(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('上次操作需要核对',
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 8),
                          const Text('原内容已保存在此浏览器标签页。请继续核对，避免重复审核或重复建任务。'),
                          const SizedBox(height: 12),
                          OutlinedButton(
                              onPressed: working ? null : resumeOriginal,
                              child: const Text('继续核对原操作')),
                        ])),
                  const SizedBox(height: 16),
                  if (tab == 0 && widget.canReviewRefunds)
                    ...refundView(context),
                  if (tab == 1 && widget.canManageFinance) ...billView(context),
                ]));
  }

  List<Widget> refundView(BuildContext context) {
    if (refund != null) {
      final item = refund!;
      return [
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
                onPressed: working
                    ? null
                    : () {
                        setState(() {
                          selectedRefundId = null;
                          refund = null;
                          preview = null;
                        });
                        load();
                      },
                child: const Text('返回退款列表'))),
        Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(financeRefundLabel(item['status']),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('${financeMoney(item['priceMinor'])} · 原路全额退款',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text('家长申请原因：${item['reason']}'),
          if (item['reviewNote'] is String && item['reviewNote'].isNotEmpty)
            Text('审核说明：${item['reviewNote']}'),
          const SizedBox(height: 8),
          Text('申请时间：${financeTime(item['createdAt'])}',
              style: const TextStyle(color: muted)),
          const SizedBox(height: 12),
          SelectableText('订单编号：${item['orderId']}'),
          if (preview != null) ...[
            const Divider(height: 32),
            Text('退款权益预览', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(preview!['consequence']),
            const SizedBox(height: 12),
            Text('保留其他续费：${(preview!['preservedOrders'] as List).length} 笔'),
            for (final row in preview!['preservedOrders'])
              Text(
                  '${financeTime(row['period_start'])} 至 ${financeTime(row['period_end'])}',
                  style: const TextStyle(color: muted)),
            const SizedBox(height: 16),
            Wrap(spacing: 12, runSpacing: 12, children: [
              FilledButton(
                  onPressed:
                      working || !writesReady ? null : () => review('APPROVE'),
                  child: const Text('通过退款审核')),
              OutlinedButton(
                  onPressed:
                      working || !writesReady ? null : () => review('DENY'),
                  child: const Text('不通过退款审核')),
            ]),
          ] else if (item['status'] == 'AWAITING_REVIEW')
            const _Notice('当前记录不可审核。本人申请或当前权限不足时，由其他审核员处理。'),
          if (const {'REQUESTED', 'PROCESSING', 'ABNORMAL', 'CLOSED'}
              .contains(item['status'])) ...[
            const SizedBox(height: 16),
            OutlinedButton(
                onPressed: working || !writesReady ? null : verifyOriginal,
                child: const Text('安排原单核对')),
          ],
        ])),
      ];
    }
    return [
      Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(
            spacing: 16,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                  width: 240,
                  child: DropdownButtonFormField<String>(
                      value: status,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '退款状态'),
                      items: familyRefundStatuses
                          .map((value) => DropdownMenuItem(
                              value: value,
                              child: Text(financeRefundLabel(value))))
                          .toList(),
                      onChanged: working
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() => status = value);
                                load();
                              }
                            })),
              SizedBox(
                  width: 360,
                  child: TextField(
                      controller: orderSearch,
                      decoration: const InputDecoration(labelText: '订单编号（可选）'),
                      onSubmitted: (_) => load())),
              OutlinedButton(
                  onPressed: working ? null : load, child: const Text('查询')),
            ]),
      ])),
      const SizedBox(height: 16),
      if (refunds.isEmpty && !busy) const _Notice('当前筛选下没有退款申请。'),
      for (final item in refunds) ...[
        Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              '${financeMoney(item['priceMinor'])} · ${financeRefundLabel(item['status'])}',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(item['reason']),
          const SizedBox(height: 8),
          Text(financeTime(item['createdAt']),
              style: const TextStyle(color: muted)),
          const SizedBox(height: 12),
          if (item['status'] == 'AWAITING_REVIEW' && item['canReview'] != true)
            const Text('当前记录不可审核，由其他审核员处理。'),
          OutlinedButton(
              onPressed: working ? null : () => openRefund(item['id']),
              child: Text(item['status'] == 'AWAITING_REVIEW' &&
                      item['canReview'] == true
                  ? '查看并审核'
                  : '查看进度')),
        ])),
        const SizedBox(height: 12),
      ],
      if (refundsCursor != null)
        TextButton(
            onPressed: working ? null : () => load(more: true),
            child: const Text('加载更多退款')),
    ];
  }

  List<Widget> billView(BuildContext context) {
    if (task != null) {
      final item = task!;
      return [
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
                onPressed: working
                    ? null
                    : () {
                        setState(() {
                          selectedTaskId = null;
                          task = null;
                          differences = [];
                        });
                        load();
                      },
                child: const Text('返回账单列表'))),
        Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${item['billDate']} · ${financeBillLabel(item['status'])}',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(
              '已匹配 ${item['matchedCount']} 条 · 其他业务 ${item['ignoredCount']} 条 · 差异 ${item['differenceCount']} 条'),
          const SizedBox(height: 8),
          Text(item['status'] == 'MATCHED'
              ? '此任务已完整核对且未发现差异。'
              : '当前结果仍需核对。未知、未完成与已记录人工跟进的差异，都不会当作已对平。'),
          const SizedBox(height: 8),
          Text('最近更新：${financeTime(item['updatedAt'])}',
              style: const TextStyle(color: muted)),
          if (item['status'] == 'ATTENTION' || item['attemptCount'] >= 50)
            const _Notice('已达到核对尝试上限，请人工检查原账单和差异记录。不会继续自动重试。'),
          if (!const {'PENDING', 'RUNNING', 'ATTENTION'}
                  .contains(item['status']) &&
              item['attemptCount'] < 50) ...[
            const SizedBox(height: 16),
            OutlinedButton(
                onPressed: working || !writesReady ? null : retryBill,
                child: const Text('重新核对原账单')),
          ],
        ])),
        const SizedBox(height: 16),
        if (differences.isEmpty && !busy)
          const _Notice('当前没有可展示的差异。请结合任务状态判断核对是否完整。'),
        for (final item in differences) ...[
          Panel(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(
                    item['state'] == 'ACKNOWLEDGED'
                        ? '已记录跟进，差异仍需核对'
                        : '账单差异待处理',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                    '本地金额：${financeMoney(item['expectedMinor'])} · 渠道金额：${financeMoney(item['actualMinor'])}'),
                if (item['orderId'] != null)
                  SelectableText('订单编号：${item['orderId']}'),
                if (item['refundId'] != null)
                  SelectableText('退款编号：${item['refundId']}'),
                if (item['note'] is String) Text('跟进说明：${item['note']}'),
                const SizedBox(height: 12),
                Wrap(spacing: 12, runSpacing: 12, children: [
                  if (item['state'] == 'OPEN')
                    OutlinedButton(
                        onPressed: working || !writesReady
                            ? null
                            : () => followDifference(item),
                        child: const Text('记录人工跟进')),
                  if (item['orderId'] != null || item['refundId'] != null)
                    OutlinedButton(
                        onPressed: working || !writesReady
                            ? null
                            : () => verifyOriginal(difference: item),
                        child: const Text('安排原单核对')),
                ]),
                if (item['orderId'] == null && item['refundId'] == null)
                  const Text('未匹配到本项目原单，请人工核对渠道账单。',
                      style: TextStyle(color: muted)),
              ])),
          const SizedBox(height: 12),
        ],
        if (differencesCursor != null)
          TextButton(
              onPressed: working ? null : moreDifferences,
              child: const Text('加载更多差异')),
      ];
    }
    return [
      Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('核对微信日账单', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('按上海时区选择账单日期。其他商户业务会单独标记；部分核对和差异不会显示为成功。'),
        const SizedBox(height: 16),
        Wrap(
            spacing: 16,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                  width: 240,
                  child: TextField(
                      controller: billDate,
                      decoration: const InputDecoration(
                          labelText: '账单日期', hintText: 'YYYY-MM-DD'))),
              FilledButton(
                  onPressed: working || !writesReady ? null : requestBill,
                  child: const Text('核对指定日期')),
            ]),
      ])),
      const SizedBox(height: 16),
      if (tasks.isEmpty && !busy) const _Notice('还没有日账单核对任务。'),
      for (final item in tasks) ...[
        Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(item['billDate'], style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(financeBillLabel(item['status']),
              style: TextStyle(
                  color: item['status'] == 'MATCHED'
                      ? const Color(0xFF00886C)
                      : const Color(0xFF8B621F),
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
              '匹配 ${item['matchedCount']} 条 · 差异 ${item['differenceCount']} 条'),
          const SizedBox(height: 12),
          OutlinedButton(
              onPressed: working ? null : () => openTask(item['id']),
              child: const Text('查看账单')),
        ])),
        const SizedBox(height: 12),
      ],
      if (tasksCursor != null)
        TextButton(
            onPressed: working ? null : () => load(more: true),
            child: const Text('加载更多账单')),
    ];
  }
}

class _Notice extends StatelessWidget {
  final String text;
  final bool error;
  const _Notice(this.text, {this.error = false});
  @override
  Widget build(BuildContext context) => Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: error
              ? Theme.of(context).colorScheme.errorContainer
              : const Color(0xFFEDF2F8),
          borderRadius: BorderRadius.circular(12)),
      child: Semantics(
          liveRegion: error,
          child: Text(text,
              style: TextStyle(
                  color: error
                      ? Theme.of(context).colorScheme.onErrorContainer
                      : navy))));
}
