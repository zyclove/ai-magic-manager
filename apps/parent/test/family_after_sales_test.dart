import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family.dart';
import 'package:parent/core/family_after_sales.dart';
import 'package:parent/core/parent_api.dart';
import 'family_device_access_test.dart' show SelectionMemoryStorage;

Json refundValue({String status = 'AWAITING_REVIEW'}) => {
      'id': 'refund-1',
      'orderId': 'order-1',
      'status': status,
      'priceMinor': 1900,
      'currency': 'CNY',
      'reason': '暂时不需要',
      'createdAt': 1792051200000,
      'paymentAvailable': false,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('refund amount mismatch cannot clear original request', () async {
    final store = SelectionMemoryStorage();
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => http.Response(
            jsonEncode({...refundValue(), 'priceMinor': 19900}), 200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    addTearDown(api.close);
    final subject = FamilyRefundCoordinator(
        service:
            FamilyService(api: api, tenantId: 'family', available: () => true),
        actor: 'adult',
        orderId: 'order-1',
        storage: store);
    await subject.restore();
    await expectLater(subject.request('暂时不需要', priceMinor: 1900),
        throwsA(isA<ParentApiException>()));
    expect(store.values, isNotEmpty);
  });
  test(
      'unknown refund persists before POST and retries exact request after restart',
      () async {
    final store = SelectionMemoryStorage(), sent = <http.Request>[];
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      sent.add(r);
      expect(store.values.values.single, contains('"reason":"暂时不需要"'));
      return sent.length == 1
          ? http.Response('{"errorCode":"UNAVAILABLE"}', 503)
          : http.Response(jsonEncode(refundValue()), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    addTearDown(api.close);
    final service =
        FamilyService(api: api, tenantId: 'family', available: () => true);
    final first = FamilyRefundCoordinator(
        service: service, actor: 'adult', orderId: 'order-1', storage: store);
    await first.restore();
    await expectLater(
        first.request('暂时不需要'), throwsA(isA<ParentApiException>()));
    final next = FamilyRefundCoordinator(
        service: service, actor: 'adult', orderId: 'order-1', storage: store);
    await next.restore();
    expect(next.pendingReason, '暂时不需要');
    expect(sent.length, 1);
    final result = await next.retry();
    expect(result['id'], 'refund-1');
    expect(sent[1].body, sent[0].body);
    expect(
        sent[1].headers['Idempotency-Key'], sent[0].headers['Idempotency-Key']);
    expect(store.values, isEmpty);
  });
  test(
      'uncertain journal write prevents network and cannot be overwritten by another page',
      () async {
    final store = SelectionMemoryStorage()..failWrite = true;
    var requests = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      requests++;
      return http.Response(jsonEncode(refundValue()), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    addTearDown(api.close);
    final service =
        FamilyService(api: api, tenantId: 'family', available: () => true);
    final first = FamilyRefundCoordinator(
        service: service, actor: 'adult', orderId: 'order-1', storage: store);
    final second = FamilyRefundCoordinator(
        service: service, actor: 'adult', orderId: 'order-1', storage: store);
    await first.restore();
    await second.restore();
    await expectLater(first.request('暂时不需要'), throwsA(isA<StateError>()));
    store.failWrite = false;
    await expectLater(second.request('另一份申请'), throwsA(isA<StateError>()));
    expect(requests, 0);
    await second.restore();
    expect(second.pendingReason, '暂时不需要');
  });
  test('parallel order pages cannot create two independent refund requests',
      () async {
    final store = SelectionMemoryStorage(),
        reached = Completer<void>(),
        release = Completer<void>();
    var requests = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      requests++;
      reached.complete();
      await release.future;
      return http.Response('{"errorCode":"UNAVAILABLE"}', 503);
    }));
    addTearDown(api.close);
    final service =
        FamilyService(api: api, tenantId: 'family', available: () => true);
    final first = FamilyRefundCoordinator(
        service: service, actor: 'adult', orderId: 'order-1', storage: store);
    final second = FamilyRefundCoordinator(
        service: service, actor: 'adult', orderId: 'order-1', storage: store);
    await first.restore();
    await second.restore();
    final attempt =
        expectLater(first.request('暂时不需要'), throwsA(isA<ParentApiException>()));
    await reached.future;
    final other =
        expectLater(second.request('第二份申请'), throwsA(isA<StateError>()));
    release.complete();
    await attempt;
    await other;
    expect(requests, 1);
  });
  for (final error in [
    (401, 'UNAUTHENTICATED'),
    (403, 'FORBIDDEN'),
    (403, 'REAUTH_REQUIRED'),
    (409, 'REQUEST_IN_PROGRESS')
  ]) {
    test('keeps original refund for ${error.$2}', () async {
      final store = SelectionMemoryStorage();
      final api = ParentApi(() async => 'fixture',
          baseUrl: 'https://fixture.invalid',
          client: MockClient((r) async =>
              http.Response(jsonEncode({'errorCode': error.$2}), error.$1)));
      addTearDown(api.close);
      final subject = FamilyRefundCoordinator(
          service: FamilyService(
              api: api, tenantId: 'family', available: () => true),
          actor: 'adult',
          orderId: 'order-1',
          storage: store);
      await subject.restore();
      await expectLater(
          subject.request('暂时不需要'), throwsA(isA<ParentApiException>()));
      expect(store.values, isNotEmpty);
      expect(subject.pendingReason, '暂时不需要');
    });
  }
  test('stale scope cannot POST even after durable write', () async {
    final store = SelectionMemoryStorage();
    var available = true;
    var requests = 0;
    final api = ParentApi(
        () async {
          available = false;
          return 'fixture';
        },
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async {
          requests++;
          return http.Response(jsonEncode(refundValue()), 200,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }));
    addTearDown(api.close);
    final subject = FamilyRefundCoordinator(
        service: FamilyService(
            api: api, tenantId: 'family', available: () => available),
        actor: 'adult',
        orderId: 'order-1',
        storage: store);
    await subject.restore();
    await expectLater(
        subject.request('暂时不需要'), throwsA(isA<ParentApiException>()));
    expect(requests, 0);
    expect(store.values, isNotEmpty);
  });
  test('mismatched refund response never discards original request', () async {
    final store = SelectionMemoryStorage();
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => http.Response(
            jsonEncode({...refundValue(), 'orderId': 'other'}), 200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
    addTearDown(api.close);
    final subject = FamilyRefundCoordinator(
        service:
            FamilyService(api: api, tenantId: 'family', available: () => true),
        actor: 'adult',
        orderId: 'order-1',
        storage: store);
    await subject.restore();
    await expectLater(
        subject.request('暂时不需要'), throwsA(isA<ParentApiException>()));
    expect(store.values, isNotEmpty);
  });
}
