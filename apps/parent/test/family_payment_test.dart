import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family.dart';
import 'package:parent/core/family_payment.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';

class _Store extends ParentDurableStorage {
  final values = <String, String>{};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

Map<String, dynamic> parameters() => {
      'appId': 'wx0123456789abcdef',
      'partnerId': '1234567890',
      'prepayId': 'wxprepay123',
      'packageValue': 'Sign=WXPay',
      'nonceStr': 'abcdefghijklmnop',
      'timeStamp': '1792051200',
      'sign': 'c2lnbmF0dXJl'
    };
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final state in ['PAID', 'CLOSED', 'INITIATED']) {
    test(
        '$state attempt without SDK parameters keeps original recovery until an authoritative order GET',
        () async {
      const channel = MethodChannel('fixture/wechat-pay-redacted-attempt');
      final nativeMethods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        nativeMethods.add(call.method);
        if (call.method == 'clear') return true;
        if (call.method == 'launch') return {'status': 'DISPATCHED'};
        fail('Unexpected native method ${call.method}');
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final original = {
        'createdAt': 1792051200000,
        'orderId': 'original-order',
        'attemptKey': 'original-attempt-key',
        'attemptId': 'original-attempt'
      };
      final store = _Store();
      store.values['parent.family.payment.family.adult'] =
          jsonEncode(original);
      final requests = <http.Request>[];
      final api = ParentApi(() async => 'fixture',
          baseUrl: 'https://fixture.invalid',
          client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'POST' &&
            request.url.path.endsWith(
                '/orders/original-order/payment-attempts')) {
          return http.Response(
              jsonEncode({
                'id': 'original-attempt',
                'orderId': 'original-order',
                'status': state,
                'parameters': <String, dynamic>{},
                'createdAt': 1792051200000
              }),
              200);
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/orders/original-order')) {
          return http.Response(
              jsonEncode({
                'id': 'original-order',
                'tenantId': 'family',
                'status': state == 'INITIATED' ? 'PAYMENT_PENDING' : state
              }),
              200);
        }
        fail('Unexpected request ${request.method} ${request.url.path}');
      }));
      addTearDown(api.close);
      final service =
          FamilyService(api: api, tenantId: 'family', available: () => true);
      FamilyPaymentCoordinator coordinator() => FamilyPaymentCoordinator(
          service: service,
          actor: 'adult',
          storage: store,
          native: NativeFamilyPay(channel: channel, available: () => true));

      final first = coordinator();
      await first.restore();
      await expectLater(
          first.launch('original-order'),
          throwsA(isA<ParentApiException>().having((error) => error.code,
              'code', 'INVALID_PAYMENT_PARAMETERS')));
      expect(first.pendingOrderId, 'original-order');
      expect(jsonDecode(store.values.values.single), original);
      expect(nativeMethods, isEmpty);

      final restored = coordinator();
      await restored.restore();
      await expectLater(restored.launch('original-order'),
          throwsA(isA<ParentApiException>()));
      expect(restored.pendingOrderId, 'original-order');
      expect(jsonDecode(store.values.values.single), original);
      expect(nativeMethods, isEmpty);
      final order = await service.object('/orders/original-order');
      await restored.reconcile(order);
      if (state == 'INITIATED') {
        expect(restored.pendingOrderId, 'original-order');
        expect(jsonDecode(store.values.values.single), original);
        expect(nativeMethods, isEmpty);
      } else {
        expect(restored.pendingOrderId, isNull);
        expect(store.values, isEmpty);
        expect(nativeMethods, ['clear']);
      }
      expect(requests.map((request) => request.method), ['POST', 'POST', 'GET']);
      expect(requests.take(2).map((request) => request.headers['Idempotency-Key']),
          ['original-attempt-key', 'original-attempt-key']);
    });
  }
  test(
      'a closed sales gate blocks native payment and preserves the original order for recovery',
      () async {
    final store = _Store();
    final requests = <http.Request>[];
    var launches = 0;
    const channel = MethodChannel('fixture/wechat-pay-closed-gate');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'launch') launches++;
      return {'status': 'DISPATCHED'};
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((request) async {
      requests.add(request);
      if (request.method == 'POST' &&
          request.url.path.endsWith('/orders/original/payment-attempts')) {
        return http.Response(
            '{"errorCode":"FAMILY_PAYMENT_UNAVAILABLE"}', 503);
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/orders/original')) {
        return http.Response(
            '{"id":"original","tenantId":"family","status":"CREATED"}',
            200);
      }
      fail('Unexpected request ${request.method} ${request.url.path}');
    }));
    addTearDown(api.close);
    final service =
        FamilyService(api: api, tenantId: 'family', available: () => true);
    FamilyPaymentCoordinator coordinator() => FamilyPaymentCoordinator(
        service: service,
        actor: 'adult',
        storage: store,
        native: NativeFamilyPay(channel: channel, available: () => true));
    final original = coordinator();
    await original.restore();
    await expectLater(
        original.launch('original'),
        throwsA(isA<ParentApiException>().having(
            (error) => error.code, 'code', 'FAMILY_PAYMENT_UNAVAILABLE')));
    expect(original.pendingOrderId, 'original');
    expect(launches, 0);

    final restored = coordinator();
    await restored.restore();
    expect(restored.pendingOrderId, 'original');
    final order = await service.object('/orders/original');
    await restored.reconcile(order);
    await expectLater(restored.launch('original'),
        throwsA(isA<ParentApiException>()));
    expect(restored.pendingOrderId, 'original');
    expect(launches, 0);
    final posts = requests.where((request) => request.method == 'POST').toList();
    expect(posts, hasLength(2));
    expect(posts.first.headers['Idempotency-Key'], isNotEmpty);
    expect(posts.last.headers['Idempotency-Key'],
        posts.first.headers['Idempotency-Key']);
    expect(requests.where((request) => request.method == 'GET'), hasLength(1));
  });
  test('backgrounding during SDK reservation cannot launch WeChat', () async {
    final store = _Store();
    var foreground = true, launched = false;
    const channel = MethodChannel('fixture/wechat-pay-background');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      launched = true;
      return {'status': 'DISPATCHED'};
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      foreground = false;
      return http.Response(
          jsonEncode({
            'id': 'attempt',
            'orderId': 'order',
            'status': 'READY',
            'parameters': parameters()
          }),
          200);
    }));
    addTearDown(api.close);
    final subject = FamilyPaymentCoordinator(
        service:
            FamilyService(api: api, tenantId: 'family', available: () => true),
        actor: 'adult',
        storage: store,
        native: NativeFamilyPay(channel: channel, available: () => true));
    await subject.restore();
    await expectLater(subject.launch('order', allowLaunch: () => foreground),
        throwsA(isA<ParentApiException>()));
    expect(launched, false);
    expect(store.values, isNotEmpty);
  });
  test(
      'authoritative GET terminal fact clears original payment without a verification POST',
      () async {
    final store = _Store();
    store.values['parent.family.payment.family.adult'] =
        jsonEncode({'createdAt': 1792051200000, 'orderId': 'order'});
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      fail('Reconciliation must not make a new network request');
    }));
    addTearDown(api.close);
    final subject = FamilyPaymentCoordinator(
        service:
            FamilyService(api: api, tenantId: 'family', available: () => true),
        actor: 'adult',
        storage: store);
    await subject.restore();
    await subject
        .reconcile({'id': 'order', 'tenantId': 'family', 'status': 'CLOSED'});
    expect(store.values, isEmpty);
    expect(subject.pendingOrderId, isNull);
  });
  test(
      'a definite changed quote clears the rejected draft so fresh terms can be confirmed',
      () async {
    final store = _Store();
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async =>
            http.Response('{"errorCode":"FAMILY_OFFER_CHANGED"}', 409)));
    addTearDown(api.close);
    final payment = FamilyPaymentCoordinator(
        service:
            FamilyService(api: api, tenantId: 'family', available: () => true),
        actor: 'adult',
        storage: store);
    await payment.restore();
    await expectLater(payment.createOrder('FAMILY_MONTH', offerVersion: 2),
        throwsA(isA<ParentApiException>()));
    expect(store.values, isEmpty);
    expect(payment.pendingPlanKey, isNull);
  });
  test(
      'an unknown order retries the durable original offer version after a quote changes',
      () async {
    final store = _Store();
    final sent = <http.Request>[];
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      sent.add(r);
      if (sent.length == 1) {
        return http.Response('{"errorCode":"UNAVAILABLE"}', 503);
      }
      return http.Response(
          '{"id":"order","tenantId":"family","status":"CREATED"}', 200);
    }));
    addTearDown(api.close);
    final service =
        FamilyService(api: api, tenantId: 'family', available: () => true);
    final first = FamilyPaymentCoordinator(
        service: service, actor: 'adult', storage: store);
    await first.restore();
    await expectLater(first.createOrder('FAMILY_MONTH', offerVersion: 2),
        throwsA(isA<ParentApiException>()));
    final second = FamilyPaymentCoordinator(
        service: service, actor: 'adult', storage: store);
    await second.restore();
    await second.createOrder('FAMILY_MONTH', offerVersion: 3);
    expect(jsonDecode(sent[0].body),
        {'planKey': 'FAMILY_MONTH', 'offerVersion': 2});
    expect(sent[1].body, sent[0].body);
    expect(
        sent[1].headers['Idempotency-Key'], sent[0].headers['Idempotency-Key']);
    expect(second.pendingOrderId, 'order');
  });
  test(
      'native dispatch is not payment and pending order survives to authoritative recovery',
      () async {
    const channel = MethodChannel('fixture/wechat-pay');
    final store = _Store();
    var paid = false;
    final requests = <http.Request>[];
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      requests.add(r);
      final data = r.url.path.endsWith('/payment-attempts')
          ? {
              'id': 'attempt',
              'orderId': 'order',
              'status': 'READY',
              'parameters': parameters(),
              'createdAt': 1792051200000
            }
          : {
              'id': 'order',
              'tenantId': 'family',
              'status': paid ? 'PAID' : 'CREATED',
              'priceMinor': 1900,
              'currency': 'CNY'
            };
      return http.Response(jsonEncode(data), 200);
    }));
    addTearDown(api.close);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'launch') {
        expect(store.values.values.single, contains('"orderId":"order"'));
        expect(store.values.values.single, contains('"attemptId":"attempt"'));
        return {'status': 'DISPATCHED'};
      }
      return true;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final service =
        FamilyService(api: api, tenantId: 'family', available: () => true);
    final native = NativeFamilyPay(channel: channel, available: () => true);
    final payment = FamilyPaymentCoordinator(
        service: service, actor: 'adult', storage: store, native: native);
    await payment.restore();
    await payment.launch('order');
    expect(payment.pendingOrderId, 'order');
    expect(store.values, isNotEmpty);
    expect(requests.where((r) => r.url.path.endsWith('payment-verifications')),
        isEmpty);
    final originalKey = requests.single.headers['Idempotency-Key'];
    expect(originalKey, isNotEmpty);
    paid = true;
    final restored = FamilyPaymentCoordinator(
        service: service, actor: 'adult', storage: store, native: native);
    await restored.restore();
    expect(restored.pendingOrderId, 'order');
    final result = await restored.verify();
    expect(result!['status'], 'PAID');
    expect(requests[1].url.path,
        '/tenants/family/orders/order/payment-verifications');
    expect(requests[2].url.path, '/tenants/family/orders/order');
    expect(store.values, isEmpty);
  });
  test('native rejects malformed provider parameters before dispatch',
      () async {
    const channel = MethodChannel('fixture/wechat-pay-invalid');
    var called = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      called = true;
      return {'status': 'DISPATCHED'};
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final native = NativeFamilyPay(channel: channel, available: () => true);
    await expectLater(
        native.launch(
            attemptId: 'attempt',
            parameters: {...parameters(), 'packageValue': 'evil'}),
        throwsA(isA<ParentApiException>()));
    expect(called, false);
  });
}
