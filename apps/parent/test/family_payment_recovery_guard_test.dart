import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family.dart';
import 'package:parent/core/family_payment.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';

class _MemoryStore extends ParentDurableStorage {
  final values = <String, String>{};
  int writes = 0, deletes = 0;

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    deletes++;
    values.remove(key);
  }
}

const _parameters = {
  'appId': 'wx0123456789abcdef',
  'partnerId': '1234567890',
  'prepayId': 'wxprepay123',
  'packageValue': 'Sign=WXPay',
  'nonceStr': 'abcdefghijklmnop',
  'timeStamp': '1792051200',
  'sign': 'c2lnbmF0dXJl',
};

http.Response _response(Object value) => http.Response(jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _readyAttempt() => {
      'id': 'historical-attempt',
      'orderId': 'historical-order',
      'status': 'READY',
      'parameters': _parameters,
      'createdAt': 1792051200000,
    };

NativeFamilyPay _native(List<MethodCall> calls) {
  const channel = MethodChannel('fixture/family-payment-recovery-guard');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    if (call.method == 'launch') return {'status': 'DISPATCHED'};
    fail('Unexpected native payment method ${call.method}');
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return NativeFamilyPay(channel: channel, available: () => true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an unresolved order request blocks another payment before side effects',
      () async {
    const key = 'parent.family.payment.family.adult';
    const original = '''{
  "orderKey": "original-order-key",
  "planKey": "FAMILY_MONTH",
  "offerVersion": 2,
  "createdAt": 1792051200000
}''';
    final store = _MemoryStore()..values[key] = original;
    final requests = <http.Request>[], nativeCalls = <MethodCall>[];
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((request) async {
      requests.add(request);
      if (request.method == 'POST' &&
          request.url.path ==
              '/tenants/family/orders/historical-order/payment-attempts') {
        // An incorrect launch can succeed at both external boundaries, so its
        // rejection cannot be credited to an unavailable provider or SDK.
        return _response(_readyAttempt());
      }
      if (request.method == 'POST' &&
          request.url.path == '/tenants/family/orders') {
        return _response({
          'id': 'recovered-order',
          'tenantId': 'family',
          'planKey': 'FAMILY_MONTH',
          'status': 'CREATED',
          'priceMinor': 1900,
          'currency': 'CNY',
          'periodStart': 1792051200000,
          'periodEnd': 1794729600000,
          'createdAt': 1792051200000,
          'expiresAt': 4102444800000,
        });
      }
      fail('Unexpected request ${request.method} ${request.url.path}');
    }));
    addTearDown(api.close);
    final payment = FamilyPaymentCoordinator(
        service:
            FamilyService(api: api, tenantId: 'family', available: () => true),
        actor: 'adult',
        storage: store,
        native: _native(nativeCalls));
    await payment.restore();
    expect(payment.loaded, isTrue);
    expect(payment.pendingOrderId, isNull);
    expect(payment.pendingPlanKey, 'FAMILY_MONTH');

    await expectLater(payment.launch('historical-order'), throwsStateError);

    expect(store.writes, 0);
    expect(store.deletes, 0);
    expect(store.values, {key: original});
    expect(requests, isEmpty);
    expect(nativeCalls, isEmpty);
    expect(payment.pendingOrderId, isNull);

    final order = await payment.createOrder('FAMILY_MONTH', offerVersion: 3);
    expect(order['id'], 'recovered-order');
    expect(requests, hasLength(1));
    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, '/tenants/family/orders');
    expect(requests.single.headers['Idempotency-Key'], 'original-order-key');
    expect(jsonDecode(requests.single.body),
        {'planKey': 'FAMILY_MONTH', 'offerVersion': 2});
    expect(store.writes, 1);
    expect(store.deletes, 0);
    expect(jsonDecode(store.values[key]!), {
      'orderKey': 'original-order-key',
      'planKey': 'FAMILY_MONTH',
      'offerVersion': 2,
      'createdAt': 1792051200000,
      'orderId': 'recovered-order',
    });
    expect(nativeCalls, isEmpty);
  });

  test('a recovered order can launch its own saved payment attempt', () async {
    const key = 'parent.family.payment.family.adult';
    final store = _MemoryStore();
    store.values[key] = jsonEncode({
      'orderKey': 'original-order-key',
      'planKey': 'FAMILY_MONTH',
      'offerVersion': 2,
      'createdAt': 1792051200000,
      'orderId': 'historical-order',
      'attemptKey': 'original-attempt-key',
    });
    final requests = <http.Request>[], nativeCalls = <MethodCall>[];
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((request) async {
      requests.add(request);
      if (request.method == 'POST' &&
          request.url.path ==
              '/tenants/family/orders/historical-order/payment-attempts') {
        return _response(_readyAttempt());
      }
      fail('Unexpected request ${request.method} ${request.url.path}');
    }));
    addTearDown(api.close);
    final payment = FamilyPaymentCoordinator(
        service:
            FamilyService(api: api, tenantId: 'family', available: () => true),
        actor: 'adult',
        storage: store,
        native: _native(nativeCalls));
    await payment.restore();

    await payment.launch('historical-order');

    expect(requests, hasLength(1));
    expect(requests.single.headers['Idempotency-Key'], 'original-attempt-key');
    expect(jsonDecode(requests.single.body), isEmpty);
    expect(nativeCalls, hasLength(1));
    expect(nativeCalls.single.method, 'launch');
    expect(nativeCalls.single.arguments['attemptId'], 'historical-attempt');
    expect(payment.pendingOrderId, 'historical-order');
    expect(jsonDecode(store.values[key]!), {
      'orderKey': 'original-order-key',
      'planKey': 'FAMILY_MONTH',
      'offerVersion': 2,
      'createdAt': 1792051200000,
      'orderId': 'historical-order',
      'attemptKey': 'original-attempt-key',
      'attemptId': 'historical-attempt',
    });
    expect(store.deletes, 0);
  });
}
