import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/ui/family_membership.dart';
import 'family_workspace_test.dart' show FamilySession;
import 'family_device_access_test.dart'
    show deviceAccessView, SelectionMemoryStorage;

class _PaymentStore extends ParentDurableStorage {
  @override
  Future<String?> read({required String key}) async => null;
}

void _installRecoveryPlatform(
    SelectionMemoryStorage store, List<String> nativeMethods) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const durability = MethodChannel('com.aimanager.parent/storage');
  const payment = MethodChannel('com.aimanager.parent/wechat_pay');
  messenger.setMockMethodCallHandler(secureStorage, (call) async {
    final arguments = Map<String, dynamic>.from(call.arguments as Map);
    final key = arguments['key'] as String;
    switch (call.method) {
      case 'read':
        return store.values[key];
      case 'write':
        store.values[key] = arguments['value'] as String;
        return null;
      case 'delete':
        store.values.remove(key);
        return null;
      default:
        fail('Unexpected secure-storage operation ${call.method}');
    }
  });
  messenger.setMockMethodCallHandler(durability, (call) async {
    expect(call.method, 'flushSecureStorage');
    return true;
  });
  messenger.setMockMethodCallHandler(payment, (call) async {
    nativeMethods.add(call.method);
    if (call.method == 'clear') return true;
    if (call.method == 'launch') return {'status': 'DISPATCHED'};
    fail('Unexpected payment operation ${call.method}');
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(secureStorage, null);
    messenger.setMockMethodCallHandler(durability, null);
    messenger.setMockMethodCallHandler(payment, null);
  });
}

ParentApi _membershipRecoveryApi(
    {required List<http.Request> sent,
    required bool paymentAvailable,
    required String orderStatus,
    bool listOrder = false,
    bool refundUnavailable = false}) {
  final order = {
    'id': 'original-order',
    'tenantId': 'family',
    'planKey': 'FAMILY_MONTH',
    'status': orderStatus,
    'priceMinor': 1900,
    'currency': 'CNY',
    'periodStart': 1792051200000,
    'periodEnd': 1794729600000,
    'createdAt': 1792051200000,
    'expiresAt': 4102444800000,
  };
  http.Response response(Object value) => http.Response(jsonEncode(value), 200,
      headers: {'content-type': 'application/json; charset=utf-8'});
  return ParentApi(() async => 'fixture', baseUrl: 'https://fixture.invalid',
      client: MockClient((request) async {
    sent.add(request);
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/subscription')) {
      return response({
        'tenantId': 'family',
        'status': orderStatus == 'PAID' ? 'ACTIVE' : 'NONE',
        'periodStart': orderStatus == 'PAID' ? 1792051200000 : null,
        'periodEnd': orderStatus == 'PAID' ? 1794729600000 : null,
        'childDeviceLimit': orderStatus == 'PAID' ? 3 : 1,
        'renewalMode': 'MANUAL',
        'paymentAvailable': paymentAvailable,
        'trialEligible': false,
        'billingTimeZone': 'Asia/Shanghai',
      });
    }
    if (request.method == 'GET' && path.endsWith('/subscription-offers')) {
      return response({
        'items': [
          for (final offer in [
            {'planKey': 'FAMILY_MONTH', 'period': 'MONTH', 'priceMinor': 1900},
            {'planKey': 'FAMILY_YEAR', 'period': 'YEAR', 'priceMinor': 19900},
          ])
            {
              ...offer,
              'offerVersion': 3,
              'currency': 'CNY',
              'childDeviceLimit': 3,
              'renewalMode': 'MANUAL',
              'paymentAvailable': paymentAvailable,
            }
        ]
      });
    }
    if (request.method == 'GET' && path.endsWith('/family-device-access')) {
      return response(deviceAccessView(status: 'FREE'));
    }
    if (path == '/tenants/family/orders') {
      if (request.method == 'GET') {
        return response({
          'items': listOrder ? [order] : [],
          'nextCursor': null
        });
      }
      if (request.method == 'POST') return response(order);
    }
    if (request.method == 'GET' &&
        path == '/tenants/family/orders/original-order') {
      return response(order);
    }
    if (request.method == 'GET' &&
        path == '/tenants/family/orders/original-order/refund-requests') {
      if (refundUnavailable) {
        return http.Response(
            jsonEncode({
              'errorCode': 'REFUND_READ_UNAVAILABLE',
              'correlationId': 'refund-read-failure',
            }),
            503,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      return response({'items': []});
    }
    fail('Unexpected recovery request ${request.method} $path');
  }));
}

void main() {
  testWidgets('guardian membership is read only even when payment is available',
      (tester) async {
    final writes = <String>[];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method != 'GET') writes.add(r.url.path);
      final data = r.url.path.endsWith('/family-device-access')
          ? deviceAccessView(status: 'FREE')
          : r.url.path.endsWith('/subscription')
              ? {
                  'tenantId': 'family',
                  'status': 'NONE',
                  'childDeviceLimit': 1,
                  'renewalMode': 'MANUAL',
                  'paymentAvailable': true,
                  'trialEligible': true
                }
              : r.url.path.endsWith('/subscription-offers')
                  ? {
                      'items': [
                        {
                          'planKey': 'FAMILY_MONTH',
                          'period': 'MONTH',
                          'priceMinor': 1900,
                          'currency': 'CNY',
                          'childDeviceLimit': 3,
                          'renewalMode': 'MANUAL',
                          'paymentAvailable': true
                        }
                      ]
                    }
                  : {'items': [], 'nextCursor': null};
      return http.Response(jsonEncode(data), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    })))
      ..role = 'GUARDIAN';
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        home: FamilyMembershipPage(
            session: session, paymentStorage: _PaymentStore())));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('19/月'), 150);
    expect(find.text('创建待支付订单'), findsNothing);
    expect(find.text('核对激活并领取 7 天试用'), findsNothing);
    expect(find.textContaining('家庭所有者'), findsOneWidget);
    expect(writes, isEmpty);
  });
  testWidgets(
      'unavailable payment shows real offers but cannot create a paid order',
      (tester) async {
    final writes = <String>[];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method != 'GET') writes.add(r.url.path);
      final data = r.url.path.endsWith('/family-device-access')
          ? deviceAccessView(status: 'FREE')
          : r.url.path.endsWith('/subscription')
              ? {
                  'tenantId': 'family',
                  'status': 'NONE',
                  'periodStart': null,
                  'periodEnd': null,
                  'childDeviceLimit': 0,
                  'renewalMode': 'MANUAL',
                  'paymentAvailable': false,
                  'trialEligible': false
                }
              : r.url.path.endsWith('/subscription-offers')
                  ? {
                      'items': [
                        {
                          'planKey': 'FAMILY_MONTH',
                          'period': 'MONTH',
                          'priceMinor': 1900,
                          'currency': 'CNY',
                          'childDeviceLimit': 3,
                          'renewalMode': 'MANUAL',
                          'paymentAvailable': false
                        },
                        {
                          'planKey': 'FAMILY_YEAR',
                          'period': 'YEAR',
                          'priceMinor': 19900,
                          'currency': 'CNY',
                          'childDeviceLimit': 3,
                          'renewalMode': 'MANUAL',
                          'paymentAvailable': false
                        }
                      ]
                    }
                  : {'items': [], 'nextCursor': null};
      return http.Response(jsonEncode(data), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    })));
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        home: FamilyMembershipPage(
            session: session, paymentStorage: _PaymentStore())));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('19/月'), 160);
    expect(find.textContaining('19/月'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('199/年'), 160);
    expect(find.textContaining('199/年'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('微信支付尚未开放'), -160);
    expect(find.textContaining('微信支付尚未开放'), findsWidgets);
    await tester.scrollUntilVisible(find.text('当前没有生效的会员'), -240);
    expect(find.text('当前没有生效的会员'), findsOneWidget);
    expect(writes, isEmpty);
  });
  testWidgets('closed sales can recover the original order request and quote',
      (tester) async {
    final store = SelectionMemoryStorage();
    store.values['parent.family.payment.family.adult'] = jsonEncode({
      'orderKey': 'original-order-key',
      'planKey': 'FAMILY_MONTH',
      'offerVersion': 2,
      'createdAt': 1792051200000,
    });
    final sent = <http.Request>[], nativeMethods = <String>[];
    _installRecoveryPlatform(store, nativeMethods);
    final api = _membershipRecoveryApi(
        sent: sent, paymentAvailable: false, orderStatus: 'CREATED');
    final session = FamilySession(api);
    addTearDown(session.dispose);
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(
        home: FamilyMembershipPage(session: session, paymentStorage: store)));
    await tester.pumpAndSettle();

    final original = find.widgetWithText(OutlinedButton, '核对原订单请求');
    final otherPlan = find.widgetWithText(OutlinedButton, '创建待支付订单');
    await tester.scrollUntilVisible(original, 160);
    expect(tester.widget<OutlinedButton>(original).onPressed, isNotNull);
    await tester.scrollUntilVisible(otherPlan, 160);
    expect(tester.widget<OutlinedButton>(otherPlan).onPressed, isNull);
    await tester.scrollUntilVisible(original, -160);
    await tester.tap(original);
    await tester.pumpAndSettle();

    final writes = sent.where((request) => request.method != 'GET').toList();
    expect(writes, hasLength(1));
    expect(writes.single.method, 'POST');
    expect(writes.single.url.path, '/tenants/family/orders');
    expect(writes.single.headers['Idempotency-Key'], 'original-order-key');
    expect(jsonDecode(writes.single.body),
        {'planKey': 'FAMILY_MONTH', 'offerVersion': 2});
    expect(find.text('订单与售后'), findsOneWidget);
    expect(find.text('使用微信支付'), findsNothing);
    expect(find.textContaining('无法确认原付款或退款申请'), findsNothing);
    expect(nativeMethods, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  testWidgets('returning from a paid order clears membership recovery',
      (tester) async {
    final store = SelectionMemoryStorage();
    const paymentKey = 'parent.family.payment.family.adult';
    store.values[paymentKey] = jsonEncode({
      'orderKey': 'original-order-key',
      'planKey': 'FAMILY_MONTH',
      'offerVersion': 2,
      'createdAt': 1792051200000,
      'orderId': 'original-order',
      'attemptKey': 'original-attempt-key',
      'attemptId': 'original-attempt',
    });
    final sent = <http.Request>[], nativeMethods = <String>[];
    _installRecoveryPlatform(store, nativeMethods);
    final api = _membershipRecoveryApi(
        sent: sent,
        paymentAvailable: true,
        orderStatus: 'PAID',
        listOrder: true);
    final session = FamilySession(api);
    addTearDown(session.dispose);
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(
        home: FamilyMembershipPage(session: session, paymentStorage: store)));
    await tester.pumpAndSettle();
    expect(find.text('有一笔订单需要核对'), findsOneWidget);
    expect(store.values, contains(paymentKey));

    final listedOrder = find.text('家庭月会员 · 已支付');
    await tester.scrollUntilVisible(listedOrder, 160);
    await tester.tap(listedOrder);
    await tester.pumpAndSettle();
    expect(find.text('订单与售后'), findsOneWidget);
    expect(find.text('已支付'), findsOneWidget);
    expect(find.textContaining('无法确认原付款或退款申请'), findsNothing);
    expect(
        sent
            .where((request) => request.method == 'GET')
            .map((request) => request.url.path),
        containsAll([
          '/tenants/family/orders/original-order',
          '/tenants/family/orders/original-order/refund-requests',
        ]));
    // Both the injected store and default platform storage use the same map.
    // The old second coordinator must really clear this before the UI assertion.
    expect(store.values, isNot(contains(paymentKey)));
    expect(nativeMethods, ['clear']);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 10000));
    await tester.pumpAndSettle();
    expect(find.text('有一笔订单需要核对'), findsNothing);
    final create = find.widgetWithText(OutlinedButton, '创建待支付订单').first;
    await tester.scrollUntilVisible(create, 160);
    expect(tester.widget<OutlinedButton>(create).onPressed, isNotNull);
    expect(sent.where((request) => request.method != 'GET'), isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  testWidgets('paid order clears recovery when refund progress is unavailable',
      (tester) async {
    final store = SelectionMemoryStorage();
    const paymentKey = 'parent.family.payment.family.adult';
    store.values[paymentKey] = jsonEncode({
      'orderKey': 'original-order-key',
      'planKey': 'FAMILY_MONTH',
      'offerVersion': 2,
      'createdAt': 1792051200000,
      'orderId': 'original-order',
      'attemptKey': 'original-attempt-key',
      'attemptId': 'original-attempt',
    });
    final sent = <http.Request>[], nativeMethods = <String>[];
    _installRecoveryPlatform(store, nativeMethods);
    final api = _membershipRecoveryApi(
        sent: sent,
        paymentAvailable: true,
        orderStatus: 'PAID',
        listOrder: true,
        refundUnavailable: true);
    final session = FamilySession(api);
    addTearDown(session.dispose);
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(
        home: FamilyMembershipPage(session: session, paymentStorage: store)));
    await tester.pumpAndSettle();
    expect(find.text('有一笔订单需要核对'), findsOneWidget);
    expect(store.values, contains(paymentKey));

    final listedOrder = find.text('家庭月会员 · 已支付');
    await tester.scrollUntilVisible(listedOrder, 160);
    await tester.tap(listedOrder);
    await tester.pumpAndSettle();
    expect(find.text('订单与售后'), findsOneWidget);
    expect(find.text('已支付'), findsOneWidget);
    expect(find.textContaining('问题编号：refund-read-failure'), findsOneWidget);
    final refundAction = find.widgetWithText(OutlinedButton, '申请原路全额退款');
    await tester.scrollUntilVisible(refundAction, 160);
    expect(tester.widget<OutlinedButton>(refundAction).onPressed, isNull);
    expect(
        sent
            .where((request) => request.method == 'GET')
            .map((request) => request.url.path),
        containsAll([
          '/tenants/family/orders/original-order',
          '/tenants/family/orders/original-order/refund-requests',
        ]));
    expect(store.values, isNot(contains(paymentKey)));
    expect(nativeMethods, ['clear']);
    expect(sent.where((request) => request.method != 'GET'), isEmpty);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 10000));
    await tester.pumpAndSettle();
    expect(find.text('有一笔订单需要核对'), findsNothing);
    final create = find.widgetWithText(OutlinedButton, '创建待支付订单').first;
    await tester.scrollUntilVisible(create, 160);
    expect(tester.widget<OutlinedButton>(create).onPressed, isNotNull);
    expect(sent.where((request) => request.method != 'GET'), isEmpty);
    expect(nativeMethods, ['clear']);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  testWidgets('unresolved order request blocks paying a listed order',
      (tester) async {
    final store = SelectionMemoryStorage();
    const paymentKey = 'parent.family.payment.family.adult';
    final originalRequest = jsonEncode({
      'orderKey': 'original-order-key',
      'planKey': 'FAMILY_MONTH',
      'offerVersion': 2,
      'createdAt': 1792051200000,
    });
    store.values[paymentKey] = originalRequest;
    final sent = <http.Request>[], nativeMethods = <String>[];
    _installRecoveryPlatform(store, nativeMethods);
    final api = _membershipRecoveryApi(
        sent: sent,
        paymentAvailable: true,
        orderStatus: 'CREATED',
        listOrder: true);
    final session = FamilySession(api);
    addTearDown(session.dispose);
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(
        home: FamilyMembershipPage(session: session, paymentStorage: store)));
    await tester.pumpAndSettle();

    final listedOrder = find.text('家庭月会员 · 待支付');
    await tester.scrollUntilVisible(listedOrder, 160);
    await tester.tap(listedOrder);
    await tester.pumpAndSettle();
    expect(find.text('订单与售后'), findsOneWidget);
    expect(find.text('请先返回会员页核对原订单请求，确认结果后再支付其他订单。'), findsOneWidget);
    final pay = find.ancestor(
        of: find.text('使用微信支付'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton));
    await tester.scrollUntilVisible(pay, 160);
    expect(tester.widget<FilledButton>(pay).onPressed, isNull);
    expect(store.values[paymentKey], originalRequest);
    expect(sent.where((request) => request.method != 'GET'), isEmpty);
    expect(nativeMethods, isEmpty);

    await tester.pageBack();
    await tester.pumpAndSettle();
    final original = find.widgetWithText(OutlinedButton, '核对原订单请求');
    await tester.scrollUntilVisible(original, -160);
    expect(tester.widget<OutlinedButton>(original).onPressed, isNotNull);
    expect(store.values[paymentKey], originalRequest);
    expect(sent.where((request) => request.method != 'GET'), isEmpty);
    expect(nativeMethods, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
