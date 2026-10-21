import 'package:flutter/material.dart';
import '../core/family.dart';
import '../core/family_after_sales.dart';
import '../core/family_payment.dart';
import '../core/parent_api.dart';
import '../core/parent_durable_storage.dart';
import '../core/parent_session.dart';
import 'family_workspace.dart';

String familyOrderStatus(dynamic status) => switch (status) {
      'PAID' => '已支付',
      'CREATED' || 'PAYMENT_PENDING' => '待支付',
      'CLOSED' => '订单已关闭',
      'EXPIRED' => '订单已过期',
      'REFUNDED' => '已退款',
      'CANCELLED' => '订单已取消',
      _ => '付款状态待核对',
    };

class FamilyOrderPage extends StatefulWidget {
  final ParentSession session;
  final String orderId;
  final FamilyPaymentCoordinator? payment;
  final ParentDurableStorage? refundStorage;
  const FamilyOrderPage(
      {super.key,
      required this.session,
      required this.orderId,
      this.payment,
      this.refundStorage});
  @override
  State<FamilyOrderPage> createState() => _FamilyOrderPageState();
}

class _FamilyOrderPageState extends State<FamilyOrderPage>
    with WidgetsBindingObserver, FamilyScope {
  @override
  ParentSession get session => widget.session;
  late final FamilyService commerce;
  late final FamilyPaymentCoordinator payment;
  late final FamilyRefundCoordinator afterSales;
  Json? order, refund;
  Object? error, recoveryError;
  bool busy = false,
      confirming = false,
      foreground = true,
      readVerified = false,
      refundCurrent = false;
  bool paymentAvailable = false;
  int confirmationEpoch = 0;
  BuildContext? confirmationContext;
  String? paymentMessage;
  bool get owner => scopeRole == 'OWNER';
  bool get active => current && foreground;
  bool get awaitingPayment =>
      const {'CREATED', 'PAYMENT_PENDING'}.contains(order?['status']);
  bool get expired =>
      awaitingPayment &&
      order?['expiresAt'] is int &&
      order!['expiresAt'] <= DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    commerce = FamilyService(
        api: session.api, tenantId: scopeTenant, available: () => active);
    payment = widget.payment ??
        FamilyPaymentCoordinator(service: commerce, actor: scopeActor);
    afterSales = FamilyRefundCoordinator(
        service: commerce,
        actor: scopeActor,
        orderId: widget.orderId,
        storage: widget.refundStorage);
    WidgetsBinding.instance.addObserver(this);
    session.addListener(_identityChanged);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session.removeListener(_identityChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final resumed = state == AppLifecycleState.resumed;
    if (!resumed) {
      confirmationEpoch++;
      _dismissConfirmation();
    }
    setState(() => foreground = resumed);
    if (resumed && current && !busy) load();
  }

  void _identityChanged() {
    if (!current) {
      confirmationEpoch++;
      _dismissConfirmation();
    }
  }

  void _dismissConfirmation() {
    final dialogContext = confirmationContext;
    confirmationContext = null;
    if (confirming &&
        dialogContext != null &&
        dialogContext.mounted &&
        ModalRoute.of(dialogContext)?.isCurrent == true) {
      confirming = false;
      Navigator.of(dialogContext).pop();
    }
  }

  Future<void> load() async {
    if (!active || busy) return;
    setState(() {
      busy = true;
      error = null;
      readVerified = false;
      refundCurrent = false;
    });
    try {
      if (owner) {
        try {
          if (!payment.loaded) await payment.restore();
          await afterSales.restore();
          recoveryError = null;
        } catch (e) {
          recoveryError = e;
        }
      }
      final results = await Future.wait([
        commerce.object('/subscription'),
        commerce.object('/orders/${Uri.encodeComponent(widget.orderId)}'),
      ]);
      final sub = results[0], value = results[1];
      if (sub['tenantId'] != scopeTenant ||
          sub['paymentAvailable'] is! bool ||
          value['id'] != widget.orderId ||
          value['tenantId'] != scopeTenant ||
          !const {
            'CREATED',
            'PAYMENT_PENDING',
            'PAID',
            'CLOSED',
            'EXPIRED',
            'CANCELLED',
            'REFUNDED'
          }.contains(value['status']) ||
          value['currency'] != 'CNY' ||
          value['priceMinor'] is! int ||
          value['priceMinor'] <= 0 ||
          value['expiresAt'] is! int) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (active) {
        setState(() {
          order = value;
          paymentAvailable = sub['paymentAvailable'];
        });
      }
      final refundResult = refund == null
          ? await commerce.object(
              '/orders/${Uri.encodeComponent(widget.orderId)}/refund-requests')
          : await commerce
              .object('/refund-requests/${Uri.encodeComponent(refund!['id'])}');
      Json? restored;
      if (refund == null) {
        final items = refundResult['items'];
        if (items is! List || items.length > 1) {
          throw const ParentApiException(502, 'INVALID_RESPONSE');
        }
        if (items.isNotEmpty) {
          restored = validateFamilyRefund(items.single, widget.orderId);
        }
      } else {
        restored = validateFamilyRefund(refundResult, widget.orderId);
        if (restored['id'] != refund!['id']) {
          throw const ParentApiException(502, 'INVALID_RESPONSE');
        }
      }
      if (restored != null && restored['priceMinor'] != value['priceMinor']) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (owner && payment.loaded) await payment.reconcile(value);
      if (active) {
        setState(() {
          order = value;
          refund = restored;
          refundCurrent = true;
          paymentAvailable = sub['paymentAvailable'];
          readVerified = true;
        });
      }
    } catch (e) {
      if (active) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> verifyPayment() async {
    if (!active || busy || !owner || !readVerified) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await commerce.write('POST',
          '/orders/${Uri.encodeComponent(widget.orderId)}/payment-verifications',
          body: {});
    } catch (e) {
      if (active) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (active && error == null) await load();
  }

  Future<void> launchPayment() async {
    if (!active ||
        busy ||
        !owner ||
        !readVerified ||
        !awaitingPayment ||
        expired ||
        !paymentAvailable ||
        !payment.loaded) return;
    setState(() {
      busy = true;
      error = null;
      paymentMessage = null;
    });
    try {
      await payment.launch(widget.orderId, allowLaunch: () => active);
      if (active) {
        setState(() => paymentMessage = '已请求打开微信。返回后请核对付款结果，会员以服务端确认的状态为准。');
      }
    } catch (e) {
      if (active) setState(() => error = e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> requestRefund({bool retry = false}) async {
    if (!active ||
        busy ||
        !owner ||
        !readVerified ||
        !afterSales.loaded ||
        (!retry && (order?['status'] != 'PAID' || refund != null)) ||
        (retry && !afterSales.hasPending)) return;
    final epoch = confirmationEpoch;
    setState(() {
      busy = true;
      confirming = true;
      error = null;
    });
    var typedReason = retry ? afterSales.pendingReason! : '';
    try {
      final reason = await showDialog<String>(
          context: context,
          builder: (dialogContext) {
            confirmationContext = dialogContext;
            return AlertDialog(
              title: Text(retry ? '核对原退款申请' : '申请原路全额退款'),
              scrollable: true,
              content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '退款金额：¥${(order!['priceMinor'] / 100).toStringAsFixed(2)}'),
                    const SizedBox(height: 12),
                    const Text('提交后先由人工审核，审核通过后服务自动办理原路全额退款。无需提供银行卡。'),
                    const SizedBox(height: 12),
                    const Text(
                        '退款完成会撤销本订单对应的会员权益；其他订单单独核算。关联续费与设备名额变化会在审核时核对，必要放行、解除规则和正常退出仍可使用。'),
                    const SizedBox(height: 16),
                    if (retry) ...[
                      const Text('将继续上次申请，不会另建一笔。'),
                      const SizedBox(height: 8),
                      Text('原原因：${afterSales.pendingReason}'),
                    ] else
                      TextField(
                          onChanged: (value) => typedReason = value,
                          maxLength: 200,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                              labelText: '退款原因',
                              hintText: '请简单说明，勿填写孩子或支付隐私资料')),
                  ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () {
                      if (typedReason.trim().isNotEmpty) {
                        Navigator.pop(dialogContext, typedReason.trim());
                      }
                    },
                    child: Text(retry ? '确认并继续原申请' : '确认申请')),
              ],
            );
          });
      confirmationContext = null;
      if (mounted) setState(() => confirming = false);
      if (reason == null || !active || confirmationEpoch != epoch) return;
      final value = retry
          ? await afterSales.retry()
          : await afterSales.request(reason, priceMinor: order!['priceMinor']);
      if (value['priceMinor'] != order!['priceMinor']) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (active) setState(() => refund = value);
    } catch (e) {
      if (active) setState(() => error = e);
    } finally {
      confirmationContext = null;
      if (mounted) {
        setState(() {
          busy = false;
          confirming = false;
        });
      }
    }
  }

  String get statusTitle =>
      expired ? '付款结果待核实' : familyOrderStatus(order?['status']);
  String get statusDetail => switch (order?['status']) {
        'PAID' => '付款已由服务端核验。会员权益与有效期以当前家庭会员页面为准。',
        'REFUNDED' => '此订单已完成退款，对应会员权益已撤销。',
        'CLOSED' => '微信渠道已确认订单关闭。如支付记录有疑问，请保留订单编号联系售后。',
        'EXPIRED' => '未付款订单已过期，不会激活会员。',
        'CANCELLED' => '此订单已取消，不会激活会员。',
        _ => expired
            ? '订单支付时间已到，服务正在核对付款和关单结果。请勿重复付款，稍后刷新查看。'
            : '完成微信付款后，需等待服务端核实。不会自动扣款。',
      };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('订单与售后')),
        body: !current
            ? const Center(child: Text('当前家庭或权限已变化，请返回重新打开。'))
            : !foreground
                ? const Center(child: Text('返回应用后查看订单。'))
                : ListView(
                    key: const ValueKey('family-order-scroll'),
                    padding: const EdgeInsets.all(20),
                    children: [
                        if (busy && !confirming)
                          const LinearProgressIndicator(),
                        if (error != null)
                          FamilyNotice(familyError(error!), error: true),
                        if (recoveryError != null)
                          const FamilyNotice('无法确认原付款或退款申请，暂时停止新操作。请刷新重新读取原进度。',
                              error: true),
                        if (error is ParentApiException &&
                            (error as ParentApiException).code ==
                                'REAUTH_REQUIRED')
                          OutlinedButton(
                              onPressed: busy
                                  ? null
                                  : () async {
                                      await session.reauthenticate();
                                      if (mounted && context.mounted) {
                                        Navigator.of(context).pop();
                                      }
                                    },
                              child: const Text('手机号安全验证后，重新打开原订单确认')),
                        if (order != null)
                          FamilyPanel(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Icon(
                                    order!['status'] == 'PAID'
                                        ? Icons.check_circle_outline
                                        : Icons.receipt_long_outlined,
                                    color: familyInk,
                                    size: 32),
                                const SizedBox(height: 12),
                                Text(statusTitle,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall),
                                const SizedBox(height: 8),
                                Text(
                                    '¥${(order!['priceMinor'] / 100).toStringAsFixed(2)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineMedium),
                                const SizedBox(height: 12),
                                Text(statusDetail),
                                const SizedBox(height: 16),
                                Text(
                                    '本订单会员期间\n${familyDate(order!['periodStart'])} 至\n${familyDate(order!['periodEnd'])}'),
                                if (awaitingPayment && !expired)
                                  Text(
                                      '请在 ${familyDate(order!['expiresAt'])} 前付款'),
                                const SizedBox(height: 16),
                                if (owner &&
                                    awaitingPayment &&
                                    !expired &&
                                    readVerified) ...[
                                  if (!paymentAvailable)
                                    const FamilyNotice(
                                        '微信支付尚未开放。待支付订单不会自动激活会员。'),
                                  if (paymentAvailable)
                                    FilledButton.icon(
                                        onPressed: busy || !payment.loaded
                                            ? null
                                            : launchPayment,
                                        icon: const Icon(Icons.payment),
                                        label: const Text('使用微信支付')),
                                ],
                                if (paymentMessage != null)
                                  FamilyNotice(paymentMessage!),
                                if (owner && awaitingPayment)
                                  TextButton(
                                      onPressed: busy || !readVerified
                                          ? null
                                          : verifyPayment,
                                      child: const Text('核对付款结果')),
                                if (!owner)
                                  const FamilyNotice(
                                      '付款和退款申请由家庭所有者处理。你可以查看当前订单与进度。'),
                                ExpansionTile(
                                    tilePadding: EdgeInsets.zero,
                                    title: const Text('订单信息'),
                                    children: [
                                      Align(
                                          alignment: Alignment.centerLeft,
                                          child: SelectableText(
                                              '订单编号：${widget.orderId}\n创建时间：${familyDate(order!['createdAt'])}')),
                                    ]),
                              ])),
                        if (refund != null && refundCurrent)
                          _RefundProgress(refund: refund!),
                        if (owner && afterSales.hasPending)
                          FamilyPanel(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text('有一份退款申请需要核对',
                                    style:
                                        Theme.of(context).textTheme.titleLarge),
                                const SizedBox(height: 8),
                                const Text(
                                    '上次提交结果尚未确认。继续时将使用原原因和原申请记录，不会另建申请。'),
                                const SizedBox(height: 12),
                                OutlinedButton(
                                    onPressed: busy ||
                                            !readVerified ||
                                            !afterSales.loaded
                                        ? null
                                        : () => requestRefund(retry: true),
                                    child: const Text('核对原退款申请')),
                              ])),
                        if (owner &&
                            order?['status'] == 'PAID' &&
                            refund == null &&
                            !afterSales.hasPending)
                          OutlinedButton(
                              onPressed:
                                  busy || !readVerified || !afterSales.loaded
                                      ? null
                                      : requestRefund,
                              child: const Text('申请原路全额退款')),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                            onPressed: busy ? null : load,
                            icon: const Icon(Icons.refresh),
                            label: const Text('刷新订单与退款进度')),
                        const SizedBox(height: 12),
                        const Text(
                            '仅在支付渠道确认后显示付款或退款完成。若需要售后协助，请提供订单编号，不要发送验证码或支付密码。',
                            style: TextStyle(color: familyMuted)),
                      ]),
      );
}

class _RefundProgress extends StatelessWidget {
  final Json refund;
  const _RefundProgress({required this.refund});
  @override
  Widget build(BuildContext context) {
    final status = refund['status'];
    final title = switch (status) {
      'AWAITING_REVIEW' => '退款申请审核中',
      'REQUESTED' => '审核通过，等待原路退款',
      'PROCESSING' => '正在原路退款',
      'REFUNDED' => '退款已完成',
      'DECLINED' => '退款申请未通过',
      'CLOSED' => '退款已关闭',
      _ => '需要人工协助',
    };
    final detail = switch (status) {
      'AWAITING_REVIEW' => '申请已收到。请等待人工审核，无需重复提交。',
      'REQUESTED' => '服务会自动向微信渠道提交，请稍后刷新查看进度。',
      'PROCESSING' => '微信渠道正在处理。到账时间以原付款账户记录为准。',
      'REFUNDED' => '微信渠道已确认退款成功，请在原付款账户查看记录。',
      'DECLINED' => '人工审核未通过。如需进一步核对，请提供订单编号联系售后。',
      'CLOSED' => '渠道已关闭此退款。请联系售后核对后续处理。',
      _ => '退款需要进一步核对。请提供订单编号联系售后，不要重复付款或提交新申请。',
    };
    return FamilyPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text('¥${(refund['priceMinor'] / 100).toStringAsFixed(2)} · 原路全额退款'),
      const SizedBox(height: 12),
      for (final stage in ['提交申请', '人工审核', '原路退款'])
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(
                  stage == '提交申请' ||
                          (stage == '人工审核' &&
                              const {'REQUESTED', 'PROCESSING', 'REFUNDED'}
                                  .contains(status)) ||
                          (stage == '原路退款' && status == 'REFUNDED')
                      ? Icons.check_circle_outline
                      : Icons.radio_button_unchecked,
                  size: 20,
                  color: familyInk),
              const SizedBox(width: 10),
              Expanded(child: Text(stage)),
            ])),
      const SizedBox(height: 12),
      Text(detail),
      if (refund['reviewNote'] is String &&
          (refund['reviewNote'] as String).trim().isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('审核说明：${refund['reviewNote']}'),
      ],
      const SizedBox(height: 8),
      Text('申请时间：${familyDate(refund['createdAt'])}',
          style: const TextStyle(color: familyMuted)),
    ]));
  }
}
