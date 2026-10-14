import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/core/quotas.dart';
import 'package:parent/ui/quota_center.dart';

const subject = '00000000-0000-4000-8000-000000000001';
const poolId = '00000000-0000-4000-8000-000000000002';
Json input() => {
      'name': '每日额度',
      'subjectId': subject,
      'scope': 'TOTAL',
      'timeZone': 'Asia/Shanghai',
      'periodId': '2026-10-14',
      'limitSeconds': 3600
    };
Json pool({int version = 0, int limit = 3600}) => {
      'id': poolId,
      ...input(),
      'periodStart': 1791907200000,
      'periodEnd': 1791993600000,
      'limitSeconds': limit,
      'usedSeconds': 0,
      'reservedSeconds': 0,
      'availableSeconds': limit,
      'status': 'CONFIGURED',
      'evidenceStatus': 'LEDGER_ONLY',
      'version': version
    };
http.Response response(Object data, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), status);

class _Storage extends ParentDurableStorage {
  final values = <String, String>{};
  bool failWrite = false;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    if (failWrite) throw StateError('flush failure');
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

class _Session extends ParentSession {
  final ParentApi fixture;
  _Session(this.fixture) {
    tenant = {'id': 'tenant', 'timeZone': 'Asia/Shanghai'};
    profile = {'subject': 'adult'};
    role = 'GUARDIAN';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  void change() {
    generation++;
    notifyListeners();
  }
}

void main() {
  test(
      'ledger and selection contracts reject malformed values before rendering',
      () {
    expect(
        () => validateQuotaLedger({
              'id': poolId,
              'kind': 'CREATED',
              'occurredAt': 'now',
              'limitDelta': 0,
              'usedDelta': 0,
              'reservedDelta': 0
            }),
        throwsA(isA<ParentApiException>()));
    expect(
        () => validateQuotaEntity({'id': '../bad', 'nickname': '孩子'},
            subject: true),
        throwsA(isA<ParentApiException>()));
    expect(quotaDelta(-90), '−1 分 30 秒');
    expect(quotaDate('2026-02-30'), isFalse);
  });

  testWidgets('auditor reads paged ledger without gaining write controls',
      (tester) async {
    final calls = <String>[];
    final api = ParentApi(() async => 'token',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((request) async {
      calls.add('${request.method} ${request.url}');
      expect(request.method, 'GET');
      if (request.url.path.endsWith('/ledger')) {
        return response({
          'items': [
            {
              'id': request.url.queryParameters.containsKey('cursor')
                  ? subject
                  : poolId,
              'kind': request.url.queryParameters.containsKey('cursor')
                  ? 'ADJUSTED'
                  : 'CREATED',
              'occurredAt': 1791907200000,
              'limitDelta': 900,
              'usedDelta': 0,
              'reservedDelta': 0
            }
          ],
          'nextCursor':
              request.url.queryParameters.containsKey('cursor') ? null : poolId
        });
      }
      if (request.url.path.endsWith(poolId)) return response(pool());
      return response({
        'items': [pool()],
        'nextCursor': null
      });
    }));
    final session = _Session(api)..role = 'AUDITOR';
    await tester.pumpWidget(MaterialApp(home: QuotaCenter(session: session)));
    await tester.pumpAndSettle();
    expect(find.text('设置每日额度'), findsNothing);
    await tester.tap(find.text('每日额度'));
    await tester.pumpAndSettle();
    expect(find.text('增减当日额度'), findsNothing);
    await tester.ensureVisible(find.text('查看额度账本'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看额度账本'));
    await tester.pumpAndSettle();
    expect(find.text('创建额度'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('调整额度'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    expect(calls.where((r) => r.contains('/ledger')), hasLength(2));
  });

  testWidgets(
      'new session generation closes quota confirmation without writing',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var writes = 0;
    final api = ParentApi(() async => 'token',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((request) async {
      if (request.method != 'GET') writes++;
      return request.url.path.endsWith(poolId)
          ? response(pool())
          : response({
              'items': [pool()],
              'nextCursor': null
            });
    }));
    final session = _Session(api);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => QuotaCenter(
                                session: session,
                                store:
                                    QuotaOperationStore(storage: _Storage())))),
                    child: const Text('打开额度'))))));
    await tester.tap(find.text('打开额度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每日额度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('增减当日额度'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '15');
    await tester.tap(find.text('检查并提交'));
    await tester.pumpAndSettle();
    expect(find.text('确认调整额度？'), findsOneWidget);
    session.change();
    await tester.pumpAndSettle();
    expect(find.text('打开额度'), findsOneWidget);
    expect(find.text('确认提交'), findsNothing);
    expect(writes, 0);
  });
  test('ledger model rejects missing, inconsistent and non-ledger facts', () {
    expect(readQuota(pool())['availableSeconds'], 3600);
    for (final change in [
      {'availableSeconds': 1},
      {'reservedSeconds': -1},
      {'usedSeconds': null},
      {'evidenceStatus': 'ENFORCED'},
      {'periodId': '2026-02-30'},
      {'id': '../bad'}
    ]) {
      expect(() => readQuota({...pool(), ...change}),
          throwsA(isA<ParentApiException>()));
    }
    expect(
        () => validateQuotaInput(
            'ADJUST', {'deltaSeconds': -3601, 'reason': 'CORRECTION'}, pool()),
        throwsFormatException);
    expect(
        () => validateQuotaInput(
            'ADJUST', {'deltaSeconds': 0, 'reason': 'EXTRA_TIME'}, pool()),
        throwsFormatException);
  });

  test(
      'lost create response recovers original without another mutation after restart',
      () async {
    final storage = _Storage(), requests = <http.Request>[];
    final api = ParentApi(() async => 'token',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((request) async {
      requests.add(request);
      expect(storage.values, hasLength(1));
      if (!request.url.path.endsWith('/query')) {
        throw http.ClientException('response lost');
      }
      final marker = jsonDecode(storage.values.values.single) as Json;
      return response({
        'requestId': marker['requestId'],
        'operation': 'CREATE',
        'committed': pool(),
        'current': pool(version: 1, limit: 4500)
      });
    }));
    QuotaOperationController make() => QuotaOperationController(
        api: api,
        store: QuotaOperationStore(storage: storage),
        tenant: 'tenant',
        actor: 'adult',
        isCurrent: () => true);
    final first = make();
    await first.load();
    await first.submit('CREATE', input());
    expect(first.pending, isNotNull);
    expect(first.committed, isNull);
    first.dispose();
    final second = make();
    await second.load();
    expect(requests, hasLength(1));
    await second.query();
    expect(second.committed!['limitSeconds'], 3600);
    expect(second.latest!['limitSeconds'], 4500);
    expect(requests.where((r) => !r.url.path.endsWith('/query')), hasLength(1));
    expect(await second.acknowledge(), isTrue);
    expect(storage.values, isEmpty);
    second.dispose();
  });

  test('storage failure and workspace change stop dispatch', () async {
    var sent = 0;
    final api = ParentApi(() async => 'token',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((_) async {
      sent++;
      return response(pool());
    }));
    final storage = _Storage()..failWrite = true;
    final c = QuotaOperationController(
        api: api,
        store: QuotaOperationStore(storage: storage),
        tenant: 'tenant',
        actor: 'adult',
        isCurrent: () => true);
    await c.load();
    await c.submit('CREATE', input());
    expect(sent, 0);
    expect(c.loaded, isFalse);
    c.dispose();
    var current = true;
    final token = Completer<String>();
    final delayed =
        ParentApi(() => token.future, baseUrl: 'https://fixture.invalid/api/v1',
            client: MockClient((_) async {
      sent++;
      return response(pool());
    }));
    final d = QuotaOperationController(
        api: delayed,
        store: QuotaOperationStore(storage: _Storage()),
        tenant: 'tenant',
        actor: 'adult',
        isCurrent: () => current);
    await d.load();
    final sending = d.submit('CREATE', input());
    await Future<void>.delayed(Duration.zero);
    current = false;
    token.complete('token');
    await sending;
    expect(sent, 0);
    d.dispose();
  });

  test(
      'explicit retry keeps adjustment key, body and version; wrong result is rejected',
      () async {
    final storage = _Storage(), requests = <http.Request>[];
    final api = ParentApi(() async => 'token',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((request) async {
      requests.add(request);
      if (requests.length == 1) throw http.ClientException('lost');
      return response(pool(version: 1, limit: 999));
    }));
    final c = QuotaOperationController(
        api: api,
        store: QuotaOperationStore(storage: storage),
        tenant: 'tenant',
        actor: 'adult',
        isCurrent: () => true);
    await c.load();
    await c.submit('ADJUST', {'deltaSeconds': 900, 'reason': 'EXTRA_TIME'},
        before: pool());
    await c.retry();
    expect(requests[0].body, requests[1].body);
    expect(requests[0].headers['Idempotency-Key'],
        requests[1].headers['Idempotency-Key']);
    expect(requests[1].headers['If-Match'], '"0"');
    expect(c.committed, isNull);
    expect(c.error, isA<ParentApiException>());
    expect(storage.values, hasLength(1));
    c.dispose();
  });

  testWidgets(
      'creates through child calendar, explicit confirmation and recovery',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = _Storage();
    Json? submitted;
    var writes = 0;
    final api = ParentApi(() async => 'token',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((request) async {
      if (request.url.path.endsWith('/subjects')) {
        return response({
          'items': [
            {'id': subject, 'nickname': '小明'}
          ],
          'nextCursor': null
        });
      }
      if (request.url.path.endsWith('/calendar')) {
        return response({
          'subjectId': subject,
          'timeZone': 'Asia/Shanghai',
          'currentDate': '2026-10-14'
        });
      }
      if (request.url.path.endsWith('/query')) {
        final marker = jsonDecode(storage.values.values.single);
        final saved = {...pool(), ...submitted!};
        return response({
          'requestId': marker['requestId'],
          'operation': 'CREATE',
          'committed': saved,
          'current': saved
        });
      }
      if (request.method == 'POST') {
        writes++;
        submitted = jsonDecode(request.body) as Json;
        return response({...pool(), ...submitted!}, 201);
      }
      return response({'items': [], 'nextCursor': null});
    }));
    await tester.pumpWidget(MaterialApp(
        home: QuotaCenter(
            session: _Session(api),
            store: QuotaOperationStore(storage: storage))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置每日额度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1. 选择儿童或学生'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小明'));
    await tester.pumpAndSettle();
    expect(find.text('额度时区：Asia/Shanghai'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).last, '60');
    await tester.tap(find.text('检查并提交'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(submitted!['subjectId'], subject);
    expect(submitted!['periodId'], '2026-10-14');
    expect(find.text('原操作已提交'), findsOneWidget);
    await tester.tap(find.text('完成核对'));
    await tester.pumpAndSettle();
    expect(storage.values, isEmpty);
  });

  testWidgets(
      'balance and adjustment remain usable on narrow screen and large text',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = _Storage();
    var writes = 0;
    Json? submitted;
    final api = ParentApi(() async => 'token',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((request) async {
      if (request.url.path.endsWith('/query')) {
        final marker = jsonDecode(storage.values.values.single);
        return response({
          'requestId': marker['requestId'],
          'operation': 'ADJUST',
          'committed': pool(version: 1, limit: 4500),
          'current': pool(version: 1, limit: 4500)
        });
      }
      if (request.method == 'POST') {
        writes++;
        submitted = jsonDecode(request.body) as Json;
        return response(pool(version: 1, limit: 4500));
      }
      if (request.url.path.endsWith(poolId)) return response(pool());
      return response({
        'items': [pool()],
        'nextCursor': null
      });
    }));
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!),
        home: QuotaCenter(
            session: _Session(api),
            store: QuotaOperationStore(storage: storage))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('每日额度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每日额度'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('增减当日额度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('增减当日额度'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextFormField));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '15');
    await tester.ensureVisible(find.text('检查并提交'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查并提交'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    await tester.tap(find.text('确认提交'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(submitted!['deltaSeconds'], 900);
    expect(find.text('原操作已提交'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
