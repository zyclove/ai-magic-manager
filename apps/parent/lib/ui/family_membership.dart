import 'package:flutter/material.dart';
import '../core/family.dart';
import '../core/family_payment.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import '../core/parent_durable_storage.dart';
import 'family_order_page.dart';
export 'family_order_page.dart';
import 'family_workspace.dart';
import 'family_device_access_page.dart';

class FamilyMembershipEntry extends StatelessWidget {
  final ParentSession session;
  const FamilyMembershipEntry({super.key, required this.session});
  @override
  Widget build(BuildContext context) => Card(
      child: ListTile(
          contentPadding: const EdgeInsets.all(18),
          leading:
              const Icon(Icons.workspace_premium_outlined, color: familyInk),
          title:
              const Text('家庭会员', style: TextStyle(fontWeight: FontWeight.w700)),
          subtitle: const Text('试用、3 台设备权益、手动续费与订单'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => FamilyMembershipPage(session: session)))));
}

class FamilyMembershipPage extends StatefulWidget {
  final ParentSession session;
  final ParentDurableStorage? paymentStorage;
  const FamilyMembershipPage(
      {super.key, required this.session, this.paymentStorage});
  @override
  State<FamilyMembershipPage> createState() => _FamilyMembershipPageState();
}

class _FamilyMembershipPageState extends State<FamilyMembershipPage>
    with WidgetsBindingObserver, FamilyScope {
  @override
  ParentSession get session => widget.session;
  Json? subscription;
  List<Json> offers = [], orders = [];
  String? orderCursor;
  bool loading = true, busy = false;
  bool foreground = true, confirming = false, loadInFlight = false;
  int confirmationEpoch = 0;
  bool get active => current && foreground;
  bool get owner => scopeRole == 'OWNER';
  Object? error;
  late final FamilyPaymentCoordinator payment;
  late final FamilyService commerce;
  Object? recoveryError;
  String? get pendingPlan => payment.pendingPlanKey;
  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    commerce = FamilyService(
        api: session.api, tenantId: scopeTenant, available: () => active);
    payment = FamilyPaymentCoordinator(
        service: commerce, actor: scopeActor, storage: widget.paymentStorage);
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final resumed = state == AppLifecycleState.resumed;
    if (!resumed) {
      confirmationEpoch++;
      if (confirming) Navigator.of(context).pop();
    }
    setState(() => foreground = resumed);
    if (resumed && current && !busy) load();
  }

  Future<void> load() async {
    if (!active || loadInFlight) return;
    loadInFlight = true;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (owner && !payment.loaded) {
        try {
          await payment.restore();
          recoveryError = null;
        } catch (e) {
          recoveryError = e;
        }
      }
      final values = await Future.wait([
        service.object('/subscription'),
        service.object('/subscription-offers'),
        service.object('/orders?limit=50')
      ]);
      if (!mounted || !current) return;
      final member = values[0], catalog = values[1], directory = values[2];
      if (member['tenantId'] != scopeTenant ||
          !const {'NONE', 'TRIAL', 'ACTIVE', 'SCHEDULED', 'EXPIRED'}
              .contains(member['status']) ||
          member['paymentAvailable'] is! bool ||
          member['trialEligible'] is! bool ||
          member['childDeviceLimit'] is! int ||
          member['renewalMode'] != 'MANUAL' ||
          catalog['items'] is! List ||
          directory['items'] is! List) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      final listed = List<Json>.from(catalog['items']);
      if (listed.any((o) =>
          !const {'FAMILY_MONTH', 'FAMILY_YEAR'}.contains(o['planKey']) ||
          o['currency'] != 'CNY' ||
          o['priceMinor'] is! int ||
          o['priceMinor'] < 0 ||
          o['childDeviceLimit'] != 3 ||
          o['renewalMode'] != 'MANUAL' ||
          o['paymentAvailable'] is! bool)) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      final listedOrders = List<Json>.from(directory['items']);
      if (listedOrders.any((o) =>
          o['tenantId'] != scopeTenant ||
          o['id'] is! String ||
          o['status'] is! String ||
          o['currency'] != 'CNY' ||
          o['priceMinor'] is! int)) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      setState(() {
        subscription = member;
        offers = listed;
        orders = listedOrders;
        orderCursor = directory['nextCursor'];
      });
    } catch (e) {
      if (current) setState(() => error = e);
    } finally {
      loadInFlight = false;
      if (current) setState(() => loading = false);
    }
  }

  Future<void> moreOrders() async {
    if (!active || busy || orderCursor == null) return;
    setState(() => busy = true);
    try {
      final value = await service.object(
          '/orders?limit=50&cursor=${Uri.encodeQueryComponent(orderCursor!)}');
      final items = List<Json>.from(value['items']);
      if (items.any((o) =>
          o['tenantId'] != scopeTenant ||
          o['id'] is! String ||
          o['status'] is! String)) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (current) {
        setState(() {
          orders = [...orders, ...items];
          orderCursor = value['nextCursor'];
        });
      }
    } catch (e) {
      if (current) setState(() => error = e);
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> trial() async {
    if (!active ||
        busy ||
        !owner ||
        subscription?['status'] != 'NONE' ||
        subscription?['trialEligible'] != true) return;
    final epoch = confirmationEpoch;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await service.object('/devices?limit=50');
      if (!mounted || !current) return;
      final devices = List<Json>.from(value['items'])
          .where((d) => d['state'] == 'ACTIVE' && d['lastHeartbeatAt'] != null)
          .toList();
      if (devices.isEmpty) {
        setState(() => error = '请先实际激活并连接儿童设备，再领取试用。');
        return;
      }
      confirming = true;
      final selected = await showDialog<String>(
          context: context,
          builder: (context) =>
              SimpleDialog(title: const Text('选择已激活的设备'), children: [
                for (final d in devices)
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, d['id']),
                      child: Text(d['displayName'] as String? ?? '设备')),
              ]));
      confirming = false;
      if (selected == null || !active || confirmationEpoch != epoch) return;
      await commerce
          .write('POST', '/subscription/trial', body: {'deviceId': selected});
      if (current) await load();
    } catch (e) {
      if (current) setState(() => error = e);
    } finally {
      confirming = false;
      if (current) setState(() => busy = false);
    }
  }

  Future<void> create(Json offer) async {
    if (!active ||
        !owner ||
        busy ||
        !payment.loaded ||
        subscription?['paymentAvailable'] != true ||
        offer['paymentAvailable'] != true) return;
    if (pendingPlan != null && pendingPlan != offer['planKey']) return;
    final epoch = confirmationEpoch;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (pendingPlan == null) {
        confirming = true;
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('确认手动续费订单'),
                    scrollable: true,
                    content: Text(
                        '${_price(offer)} · 3 台儿童设备\n\n不会自动扣款。权益生效和到期时间以服务端订单为准。已支付订单支持申请原路全额退款，退款状态以支付渠道核验为准。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('再想想')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('创建待支付订单'))
                    ]));
        confirming = false;
        if (confirmed != true || !active || confirmationEpoch != epoch) return;
      }
      final order = await payment.createOrder(offer['planKey'],
          offerVersion: offer['offerVersion'] as int? ?? 1);
      if (!mounted || !current) return;
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => FamilyOrderPage(
              session: session, orderId: order['id'], payment: payment)));
      if (current) await load();
    } catch (e) {
      if (current) {
        setState(() {
          error = e;
        });
      }
    } finally {
      confirming = false;
      if (current) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('家庭会员')),
      body: !current
          ? const Center(child: Text('当前家庭或权限已变化，请返回重新打开。'))
          : !foreground
              ? const Center(child: Text('返回应用后查看会员与订单。'))
              : loading
                  ? const Center(child: CircularProgressIndicator())
                  : RefreshIndicator(
                      onRefresh: load,
                      child: ListView(
                          padding: const EdgeInsets.all(20),
                          children: [
                            if (recoveryError != null &&
                                subscription?['paymentAvailable'] == true)
                              const FamilyNotice(
                                  '无法读取上次支付进度。为避免重复下单，付费操作暂时停用。请重试读取。',
                                  error: true),
                            if (owner && payment.pendingOrderId != null)
                              FamilyPanel(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    const Text('有一笔订单需要核对'),
                                    const Text('退出应用或微信返回不会认定支付成功，请查看服务端状态。'),
                                    OutlinedButton(
                                        onPressed: busy
                                            ? null
                                            : () async {
                                                await Navigator.of(context)
                                                    .push(MaterialPageRoute(
                                                        builder: (_) =>
                                                            FamilyOrderPage(
                                                                session:
                                                                    session,
                                                                orderId: payment
                                                                    .pendingOrderId!,
                                                                payment:
                                                                    payment)));
                                                if (current) await load();
                                              },
                                        child: const Text('核对原订单')),
                                  ])),
                            if (error != null)
                              FamilyNotice(familyError(error!), error: true),
                            if (subscription == null)
                              OutlinedButton(
                                  onPressed: load,
                                  child: const Text('重新读取会员状态')),
                            if (subscription != null) ...[
                              FamilyPanel(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                    const Icon(Icons.workspace_premium_outlined,
                                        size: 36, color: familyInk),
                                    const SizedBox(height: 14),
                                    Text(
                                        switch (subscription!['status']) {
                                          'TRIAL' => '正在试用家庭会员',
                                          'ACTIVE' => '家庭会员已生效',
                                          'EXPIRED' => '会员已到期',
                                          _ => '当前没有生效的会员'
                                        },
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge),
                                    const SizedBox(height: 10),
                                    Text(subscription!['status'] == 'NONE' ||
                                            subscription!['status'] == 'EXPIRED'
                                        ? '免费基础版：1 台儿童设备'
                                        : '当前儿童设备权益：${subscription!['childDeviceLimit']} 台'),
                                    if (subscription!['periodEnd'] != null)
                                      Text(
                                          '有效至：${familyDate(subscription!['periodEnd'])}'),
                                    const SizedBox(height: 8),
                                    const Text('手动续费，不自动扣款。到期后仍可查看状态并放宽或停用限制。',
                                        style: TextStyle(color: familyMuted)),
                                    if (!owner)
                                      const FamilyNotice(
                                          '付款、试用和退款申请由家庭所有者处理。你可以查看会员与订单。'),
                                    if (owner &&
                                        subscription!['status'] == 'NONE' &&
                                        subscription!['trialEligible'] ==
                                            true) ...[
                                      const SizedBox(height: 16),
                                      if (owner)
                                        OutlinedButton(
                                            onPressed: busy ? null : trial,
                                            child: const Text('核对激活并领取 7 天试用'))
                                    ],
                                  ])),
                              FamilyDeviceAccessEntry(session: session),
                              if (subscription!['paymentAvailable'] != true)
                                const FamilyNotice('微信支付尚未开放。你可以先连接设备，体验基础管理。'),
                              for (final offer in offers)
                                FamilyPanel(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text(_price(offer),
                                          style: Theme.of(context)
                                              .textTheme
                                              .headlineSmall
                                              ?.copyWith(
                                                  color: familyInk,
                                                  fontWeight: FontWeight.w700)),
                                      const SizedBox(height: 8),
                                      const Text('同一档家庭会员 · 3 台儿童设备 · 手动续费'),
                                      const SizedBox(height: 14),
                                      if (owner)
                                        OutlinedButton(
                                            onPressed: busy ||
                                                    !payment.loaded ||
                                                    payment.pendingOrderId !=
                                                        null ||
                                                    subscription![
                                                            'paymentAvailable'] !=
                                                        true ||
                                                    offer['paymentAvailable'] !=
                                                        true ||
                                                    pendingPlan != null &&
                                                        pendingPlan !=
                                                            offer['planKey']
                                                ? null
                                                : () => create(offer),
                                            child: Text(
                                                pendingPlan == offer['planKey']
                                                    ? '核对原订单请求'
                                                    : '创建待支付订单')),
                                    ])),
                              const SizedBox(height: 20),
                              Text('我的订单',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                              if (orders.isEmpty) const FamilyNotice('还没有订单。'),
                              for (final order in orders)
                                Card(
                                    child: ListTile(
                                        title: Text(
                                            '${order['planKey'] == 'FAMILY_YEAR' ? '家庭年会员' : '家庭月会员'} · ${_orderStatus(order['status'])}'),
                                        subtitle: Text(
                                            '¥${(order['priceMinor'] / 100).toStringAsFixed(2)}\n${familyDate(order['createdAt'])}'),
                                        trailing:
                                            const Icon(Icons.chevron_right),
                                        onTap: busy
                                            ? null
                                            : () async {
                                                await Navigator.of(context)
                                                    .push(MaterialPageRoute(
                                                        builder: (_) =>
                                                            FamilyOrderPage(
                                                                session:
                                                                    session,
                                                                orderId: order[
                                                                    'id'])));
                                                if (current) await load();
                                              })),
                              if (orderCursor != null)
                                TextButton(
                                    onPressed: busy ? null : moreOrders,
                                    child: const Text('加载更多订单')),
                              const SizedBox(height: 20),
                              const Text(
                                  '支付和退款结果以服务端核验为准。家庭辅助限制的效果取决于儿童设备权限与运行状态。',
                                  style: TextStyle(color: familyMuted)),
                            ],
                          ])));
}

String _price(Json offer) =>
    '¥${(offer['priceMinor'] / 100).toStringAsFixed(offer['priceMinor'] % 100 == 0 ? 0 : 2)}/${offer['period'] == 'YEAR' ? '年' : '月'}';
String _orderStatus(dynamic status) => familyOrderStatus(status);
