import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/family_finance.dart';
import 'package:guardian/core/finance_storage_port.dart';

const refundId = '00000000-0000-4000-8000-000000000001';
const orderId = '00000000-0000-4000-8000-000000000002';
const taskId = '00000000-0000-4000-8000-000000000003';
const differenceId = '00000000-0000-4000-8000-000000000004';
const previewHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
Json refundCase({bool canReview = true}) => {
      'id': refundId,
      'orderId': orderId,
      'tenantId': '00000000-0000-4000-8000-000000000005',
      'status': 'AWAITING_REVIEW',
      'reason': '暂时不需要',
      'priceMinor': 1900,
      'currency': 'CNY',
      'createdAt': 1792051200000,
      'canReview': canReview
    };
Json billTask({String status = 'DIFFERENCES'}) => {
      'id': taskId,
      'billDate': '2026-10-15',
      'status': status,
      'attemptCount': 1,
      'rowCount': 3,
      'matchedCount': 1,
      'ignoredCount': 1,
      'differenceCount': 1,
      'createdAt': 1792051200000,
      'updatedAt': 1792051200001
    };
Json difference({String state = 'OPEN'}) => {
      'id': differenceId,
      'kind': 'AMOUNT_MISMATCH',
      'tenantId': '00000000-0000-4000-8000-000000000005',
      'orderId': orderId,
      'refundId': null,
      'expectedMinor': 1900,
      'actualMinor': 1800,
      'state': state,
      'createdAt': 1792051200000
    };
Json reviewPreview() => {
      'id': refundId,
      'status': 'AWAITING_REVIEW',
      'reason': '暂时不需要',
      'createdAt': 1792051200000,
      'order': {
        'id': orderId,
        'status': 'PAID',
        'price_minor': 1900,
        'currency': 'CNY',
        'period_start': 1792051200000,
        'period_end': 1794729600000
      },
      'preservedOrders': [
        {
          'id': '00000000-0000-4000-8000-000000000006',
          'status': 'PAID',
          'period_start': 1794729600000,
          'period_end': 1797321600000
        }
      ],
      'consequence': '仅撤销此订单来源，其他续费单独保留。',
      'previewHash': previewHash
    };

class FinanceMemoryStorage implements FinanceStringStorage {
  final values = <String, String>{};
  bool failWrite = false;
  @override
  String? read(String key) => values[key];
  @override
  void write(String key, String value) {
    values[key] = value;
    if (failWrite) throw StateError('storage unknown');
  }

  @override
  void remove(String key) => values.remove(key);
}

http.Response financeResponse(Object value, {int status = 200}) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('definite exhausted bill retry releases only the rejected retry journal',
      () async {
    final storage = FinanceMemoryStorage();
    final api = Api(
        () async => MockClient((r) async => financeResponse(
            {'errorCode': 'FAMILY_BILL_ATTEMPTS_EXHAUSTED'},
            status: 409)),
        baseUrl: 'https://fixture.invalid');
    final subject = FamilyFinanceOperations(
        api: api, actor: 'finance', available: () => true, storage: storage);
    await subject.restore();
    await expectLater(subject.retryBill(taskId), throwsA(isA<ApiFailure>()));
    expect(storage.values, isEmpty);
    expect(subject.pending, isNull);
  });
  test(
      'immutable acknowledgement rejection releases journal without replacing prior note',
      () async {
    final storage = FinanceMemoryStorage(), sent = <http.Request>[];
    final api = Api(
        () async => MockClient((r) async {
              sent.add(r);
              return r.method == 'POST'
                  ? financeResponse(
                      {'errorCode': 'FAMILY_BILL_ACKNOWLEDGEMENT_IMMUTABLE'},
                      status: 409)
                  : financeResponse({
                      'items': [
                        {
                          ...difference(state: 'ACKNOWLEDGED'),
                          'note': '其他审核员已核对原记录'
                        }
                      ],
                      'nextCursor': null
                    });
            }),
        baseUrl: 'https://fixture.invalid');
    final subject = FamilyFinanceOperations(
        api: api, actor: 'finance', available: () => true, storage: storage);
    await subject.restore();
    await expectLater(subject.acknowledge(taskId, differenceId, '本审核员的其他说明'),
        throwsA(isA<ApiFailure>()));
    expect(storage.values, isEmpty);
    expect(subject.pending, isNull);
    final records =
        await FamilyFinanceRepository(api: api, available: () => true)
            .differences(taskId);
    expect(records.items.single['note'], '其他审核员已核对原记录');
    expect(sent.where((r) => r.method == 'POST').length, 1);
  });
  test(
      'invalid bill evidence is shown as invalid instead of a successful reconciliation',
      () async {
    final api = Api(
        () async => MockClient((r) async => financeResponse({
              'items': [
                {
                  ...billTask(status: 'INVALID_BILL'),
                  'errorCode': 'BILL_HASH_MISMATCH'
                }
              ],
              'nextCursor': null
            })),
        baseUrl: 'https://fixture.invalid');
    final repo = FamilyFinanceRepository(api: api, available: () => true);
    final page = await repo.tasks();
    expect(page.items.single['status'], 'INVALID_BILL');
  });
  test(
      'definite unavailable bill date releases rejected request and permits a new date',
      () async {
    final storage = FinanceMemoryStorage();
    var requests = 0;
    final api = Api(
        () async => MockClient((r) async {
              requests++;
              return requests == 1
                  ? financeResponse(
                      {'errorCode': 'FAMILY_BILL_DATE_UNAVAILABLE'},
                      status: 400)
                  : financeResponse(billTask());
            }),
        baseUrl: 'https://fixture.invalid');
    final subject = FamilyFinanceOperations(
        api: api, actor: 'finance', available: () => true, storage: storage);
    await subject.restore();
    await expectLater(
        subject.requestBill('2026-10-16'), throwsA(isA<ApiFailure>()));
    expect(storage.values, isEmpty);
    await subject.requestBill('2026-10-15');
    expect(requests, 2);
  });
  test('review decision mismatch does not consume the original denial journal',
      () async {
    final storage = FinanceMemoryStorage();
    final api = Api(
        () async => MockClient((r) async => financeResponse({
              'id': refundId,
              'status': 'REQUESTED',
              'externalRefundSubmitted': false
            })),
        baseUrl: 'https://fixture.invalid');
    final subject = FamilyFinanceOperations(
        api: api, actor: 'reviewer', available: () => true, storage: storage);
    await subject.restore();
    await expectLater(
        subject.review(refundId,
            decision: 'DENY', previewHash: previewHash, note: '暂不通过退款审核'),
        throwsA(isA<ApiFailure>()));
    expect(storage.values, isNotEmpty);
  });
  test('bill task for another date cannot consume original task request',
      () async {
    final storage = FinanceMemoryStorage();
    final api = Api(
        () async => MockClient((r) async => financeResponse(billTask())),
        baseUrl: 'https://fixture.invalid');
    final subject = FamilyFinanceOperations(
        api: api, actor: 'finance', available: () => true, storage: storage);
    await subject.restore();
    await expectLater(
        subject.requestBill('2026-10-14'), throwsA(isA<ApiFailure>()));
    expect(storage.values, isNotEmpty);
  });
  test(
      'definite changed refund preview releases old operation for fresh confirmation',
      () async {
    final storage = FinanceMemoryStorage();
    final api = Api(
        () async => MockClient((r) async => financeResponse(
            {'errorCode': 'REFUND_PREVIEW_CHANGED'},
            status: 409)),
        baseUrl: 'https://fixture.invalid');
    final subject = FamilyFinanceOperations(
        api: api, actor: 'reviewer', available: () => true, storage: storage);
    await subject.restore();
    await expectLater(
        subject.review(refundId,
            decision: 'APPROVE', previewHash: previewHash, note: '原预览已发生变化'),
        throwsA(isA<ApiFailure>()));
    expect(storage.values, isEmpty);
    expect(subject.pending, isNull);
  });
  test('oversized operator note is rejected before it can be journaled or sent',
      () async {
    final storage = FinanceMemoryStorage();
    var sent = 0;
    final api = Api(
        () async => MockClient((r) async {
              sent++;
              return financeResponse({
                'id': refundId,
                'status': 'REQUESTED',
                'externalRefundSubmitted': false
              });
            }),
        baseUrl: 'https://fixture.invalid');
    final subject = FamilyFinanceOperations(
        api: api, actor: 'reviewer', available: () => true, storage: storage);
    await subject.restore();
    await expectLater(
        subject.review(refundId,
            decision: 'APPROVE',
            previewHash: previewHash,
            note: List.filled(201, '字').join()),
        throwsA(isA<ApiFailure>()));
    expect(sent, 0);
    expect(storage.values, isEmpty);
  });
  test('exhausted bill task stays in manual attention and cannot look matched',
      () async {
    final api = Api(
        () async => MockClient((r) async => financeResponse({
              'items': [
                {
                  ...billTask(status: 'ATTENTION'),
                  'errorCode': 'BILL_ATTEMPTS_EXHAUSTED'
                }
              ],
              'nextCursor': null
            })),
        baseUrl: 'https://fixture.invalid');
    final repo = FamilyFinanceRepository(api: api, available: () => true);
    final page = await repo.tasks();
    expect(page.items.single['status'], 'ATTENTION');
  });
  test(
      'refund review unknown outcome survives tab recovery with exact key path and body',
      () async {
    final storage = FinanceMemoryStorage(), sent = <http.Request>[];
    final api = Api(
        () async => MockClient((r) async {
              sent.add(r);
              expect(storage.values.values.single, contains(previewHash));
              return sent.length == 1
                  ? financeResponse({'errorCode': 'UNAVAILABLE'}, status: 503)
                  : financeResponse({
                      'id': refundId,
                      'status': 'REQUESTED',
                      'externalRefundSubmitted': false
                    });
            }),
        baseUrl: 'https://fixture.invalid');
    final first = FamilyFinanceOperations(
        api: api, actor: 'reviewer', available: () => true, storage: storage);
    await first.restore();
    await expectLater(
        first.review(refundId,
            decision: 'APPROVE', previewHash: previewHash, note: '核对全额原路退款'),
        throwsA(isA<ApiFailure>()));
    final next = FamilyFinanceOperations(
        api: api, actor: 'reviewer', available: () => true, storage: storage);
    await next.restore();
    expect(sent.length, 1);
    expect(next.pending, isNotNull);
    await next.retry();
    expect(sent[1].url, sent[0].url);
    expect(sent[1].body, sent[0].body);
    expect(
        sent[1].headers['Idempotency-Key'], sent[0].headers['Idempotency-Key']);
    expect(storage.values, isEmpty);
  });
  test('journal never contains customer reason or allows an arbitrary endpoint',
      () async {
    final storage = FinanceMemoryStorage();
    final api = Api(
        () async => MockClient((r) async =>
            financeResponse({'errorCode': 'UNAVAILABLE'}, status: 503)),
        baseUrl: 'https://fixture.invalid');
    final subject = FamilyFinanceOperations(
        api: api, actor: 'reviewer', available: () => true, storage: storage);
    await subject.restore();
    await expectLater(
        subject.review(refundId,
            decision: 'DENY', previewHash: previewHash, note: '已联系申请人核对'),
        throwsA(isA<ApiFailure>()));
    final raw = storage.values.values.single;
    expect(raw, isNot(contains('暂时不需要')));
    expect(raw, isNot(contains('token')));
    storage.values[storage.values.keys.single] =
        raw.replaceFirst('/reviews', '/submissions');
    final restored = FamilyFinanceOperations(
        api: api, actor: 'reviewer', available: () => true, storage: storage);
    await expectLater(restored.restore(), throwsA(isA<ApiFailure>()));
  });
  test(
      'uncertain storage write and concurrent page cannot create another operation',
      () async {
    final storage = FinanceMemoryStorage()..failWrite = true;
    var sent = 0;
    final api = Api(
        () async => MockClient((r) async {
              sent++;
              return financeResponse({'id': taskId});
            }),
        baseUrl: 'https://fixture.invalid');
    final first = FamilyFinanceOperations(
        api: api, actor: 'reviewer', available: () => true, storage: storage);
    final next = FamilyFinanceOperations(
        api: api, actor: 'reviewer', available: () => true, storage: storage);
    await first.restore();
    await next.restore();
    await expectLater(
        first.requestBill('2026-10-15'), throwsA(isA<ApiFailure>()));
    storage.failWrite = false;
    await expectLater(
        next.requestBill('2026-10-14'), throwsA(isA<ApiFailure>()));
    expect(sent, 0);
    await next.restore();
    expect(next.pending!['body']['billDate'], '2026-10-15');
  });
  test('scope invalidation during client acquisition prevents queued review',
      () async {
    var active = true, sent = 0;
    final storage = FinanceMemoryStorage();
    final api = Api(() async {
      active = false;
      return MockClient((r) async {
        sent++;
        return financeResponse({});
      });
    }, baseUrl: 'https://fixture.invalid');
    final subject = FamilyFinanceOperations(
        api: api, actor: 'reviewer', available: () => active, storage: storage);
    await subject.restore();
    await expectLater(
        subject.review(refundId,
            decision: 'APPROVE', previewHash: previewHash, note: '核对通过全额退款'),
        throwsA(isA<ApiFailure>()));
    expect(sent, 0);
    expect(storage.values, isNotEmpty);
  });
  test('different actor cannot see or repeat old operator journal', () async {
    final storage = FinanceMemoryStorage();
    final api = Api(
        () async => MockClient((r) async =>
            financeResponse({'errorCode': 'REAUTH_REQUIRED'}, status: 403)),
        baseUrl: 'https://fixture.invalid');
    final first = FamilyFinanceOperations(
        api: api, actor: 'first', available: () => true, storage: storage);
    await first.restore();
    await expectLater(
        first.review(refundId,
            decision: 'DENY', previewHash: previewHash, note: '已核对申请原因'),
        throwsA(isA<ApiFailure>()));
    final next = FamilyFinanceOperations(
        api: api, actor: 'second', available: () => true, storage: storage);
    await next.restore();
    expect(next.pending, isNull);
  });
  test(
      'list and preview validate returned order and preserve independent paid renewals',
      () async {
    final sent = <http.Request>[];
    final api = Api(
        () async => MockClient((r) async {
              sent.add(r);
              return financeResponse(r.url.path.endsWith('/preview')
                  ? reviewPreview()
                  : {
                      'items': [refundCase()],
                      'nextCursor': 'cursor'
                    });
            }),
        baseUrl: 'https://fixture.invalid');
    final repo = FamilyFinanceRepository(api: api, available: () => true);
    final page = await repo.refunds(orderId: orderId, cursor: 'old cursor');
    expect(page.nextCursor, 'cursor');
    expect(sent[0].url.queryParameters['orderId'], orderId);
    expect(sent[0].url.queryParameters['cursor'], 'old cursor');
    final value = await repo.preview(refundId);
    expect(value['preservedOrders'], hasLength(1));
  });
  test('unknown and partial bills never parse as a matched result', () async {
    final api = Api(
        () async => MockClient((r) async => financeResponse({
              'items': [billTask(status: 'PARTIAL')],
              'nextCursor': null
            })),
        baseUrl: 'https://fixture.invalid');
    final repo = FamilyFinanceRepository(api: api, available: () => true);
    final page = await repo.tasks();
    expect(page.items.single['status'], 'PARTIAL');
  });
  test(
      'acknowledging a difference preserves its difference nature and sends a note',
      () async {
    final sent = <http.Request>[];
    final storage = FinanceMemoryStorage();
    final api = Api(
        () async => MockClient((r) async {
              sent.add(r);
              return financeResponse(
                  {...difference(state: 'ACKNOWLEDGED'), 'note': '已建立人工跟进记录'});
            }),
        baseUrl: 'https://fixture.invalid');
    final subject = FamilyFinanceOperations(
        api: api, actor: 'finance', available: () => true, storage: storage);
    await subject.restore();
    final result = await subject.acknowledge(taskId, differenceId, '已建立人工跟进记录');
    expect(result['state'], 'ACKNOWLEDGED');
    expect(jsonDecode(sent.single.body), {'note': '已建立人工跟进记录'});
    expect(sent.single.url.path,
        endsWith('/differences/$differenceId/acknowledgements'));
  });
}
