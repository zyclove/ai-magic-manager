import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/schedules.dart';
import 'package:parent/ui/schedule_editor.dart';
import 'package:parent/ui/schedule_center.dart';
import 'package:parent/ui/policy_editor.dart';

import 'support/parent_operation_journal_fixture.dart';

class _Storage extends ParentDurableStorage with ParentAtomicJournalFixture {
  @override
  bool get fixtureWriteMayCommitBeforeFailure => true;
  final values = <String, String>{};
  bool failWrite = false;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
    if (failWrite) throw StateError('flush failed');
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
}

const scheduleId = '00000000-0000-4000-8000-000000000001';
Json definition() => {
      'timeZone': 'Asia/Shanghai',
      'weekly': [
        {'day': 'MONDAY', 'start': '22:00', 'end': '01:00'}
      ],
      'exceptions': [
        {'date': '2026-10-06', 'windows': []}
      ]
    };
Json entry([Json? source]) =>
    {'id': scheduleId, 'name': '学习计划', 'definition': source ?? definition()};
http.Response response(Json raw, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(raw)), status);

void main() {
  testWidgets('selects a paged schedule and saves its reference in a draft',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Json? submitted;
    var catalogReads = 0;
    final draft = <String, dynamic>{
      'id': 'policy-a',
      'name': '晚间规则',
      'kind': 'POLICY',
      'revision': 1,
      'rules': <Json>[]
    };
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') {
        submitted = jsonDecode(r.body) as Json;
        return response({...draft, ...submitted!, 'revision': 2});
      }
      if (r.url.path.endsWith('/applications')) {
        return response({'items': [], 'nextCursor': null});
      }
      if (r.url.path.endsWith('/schedules')) {
        expect(r.url.queryParameters['limit'], '5');
        catalogReads++;
        return response({
          'items': [entry()],
          'nextCursor': null
        });
      }
      expect(r.url.path, '/tenants/tenant/schedules/$scheduleId');
      return response(entry());
    }));
    await tester.pumpWidget(MaterialApp(
        home: PolicyDraftEditor(session: _Session(api), draft: draft)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用时段'));
    await tester.pumpAndSettle();
    expect(catalogReads, 0);
    await tester.tap(find.text('选择或新建时间计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用于当前规则'));
    await tester.pumpAndSettle();
    expect(find.text('周一 22:00–次日 01:00'), findsOneWidget);
    await tester.tap(find.text('完成规则编辑'));
    await tester.pumpAndSettle();
    expect(submitted, isNull);
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();
    expect(catalogReads, 1);
    expect(submitted!['rules'], hasLength(1));
    expect(submitted!['rules'][0]['scheduleId'], scheduleId);
    expect(submitted!['rules'][0]['kind'], 'TIME_WINDOW');
    expect(tester.takeException(), isNull);
  });
  test('wall-time model preserves cross-midnight and a whole-day closure', () {
    final value = definition();
    validateScheduleDefinition(value);
    expect(scheduleWindowLabel((value['weekly'] as List).single),
        '22:00–次日 01:00');
    expect(value['exceptions'][0]['windows'], isEmpty);
    validateScheduleDefinition(
        {'timeZone': 'Asia/Shanghai', 'weekly': [], 'exceptions': []});
  });
  for (final kind in ['date', 'duplicate', 'equal', 'limit']) {
    test('rejects invalid $kind schedule input locally', () {
      final value = definition();
      switch (kind) {
        case 'date':
          value['exceptions'][0]['date'] = '2026-02-30';
        case 'duplicate':
          value['exceptions'].add({'date': '2026-10-06', 'windows': []});
        case 'equal':
          value['weekly'][0]['end'] = '22:00';
        case 'limit':
          value['weekly'] = List.filled(
              57, {'day': 'MONDAY', 'start': '09:00', 'end': '10:00'});
      }
      expect(() => validateScheduleDefinition(value), throwsFormatException);
    });
  }
  test(
      'decision validation rejects conflicting time zone and expired allowed window',
      () {
    final at = DateTime.utc(2026, 10, 5, 15);
    final decision = <String, dynamic>{
      'allowed': true,
      'timeZone': 'Asia/Shanghai',
      'localDate': '2026-10-05',
      'previewDays': 8,
      'reasonCode': 'WITHIN_ALLOWED_WINDOW',
      'currentUntil': '2026-10-05T17:00:00Z',
      'nextAllowedAt': null
    };
    validateScheduleDecision(decision, 'Asia/Shanghai', at);
    expect(() => validateScheduleDecision(decision, 'UTC', at),
        throwsA(isA<ParentApiException>()));
    decision['currentUntil'] = at.toIso8601String();
    expect(() => validateScheduleDecision(decision, 'Asia/Shanghai', at),
        throwsA(isA<ParentApiException>()));
  });
  test(
      'storage failure stops schedule creation while retaining recovery evidence',
      () async {
    final storage = _Storage()..failWrite = true;
    var requests = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((_) async {
      requests++;
      return response(entry(), 201);
    }));
    final c = ScheduleCreationController(
        api: api,
        store: ScheduleCreationStore(storage: storage),
        tenant: 'tenant',
        actor: 'adult',
        isCurrent: () => true);
    await c.load();
    await c.create('学习计划', definition());
    expect(requests, 0);
    expect(c.loaded, isFalse);
    expect(storage.values, hasLength(1));
    storage.failWrite = false;
    await c.load();
    expect(c.pending, isNotNull);
  });
  test('lost response recovers exact original body after controller restart',
      () async {
    final storage = _Storage();
    final store = ScheduleCreationStore(storage: storage);
    final calls = <http.Request>[];
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((request) async {
      calls.add(request);
      if (!request.url.path.endsWith('/query')) {
        throw http.ClientException('response lost');
      }
      return response(entry());
    }));
    ScheduleCreationController controller() => ScheduleCreationController(
        api: api,
        store: store,
        tenant: 'tenant',
        actor: 'adult',
        isCurrent: () => true);
    final c = controller();
    await c.load();
    await c.create('学习计划', definition());
    final key = c.pending!['requestId'];
    c.dispose();
    final restored = controller();
    await restored.load();
    await restored.query();
    expect(calls, hasLength(2));
    expect(calls.last.url.path.endsWith('/$key/query'), isTrue);
    expect(jsonDecode(calls.last.body), jsonDecode(calls.first.body));
    expect(restored.result!['id'], scheduleId);
    expect(await restored.acknowledge(), isTrue);
    expect(storage.values, isEmpty);
  });
  test('missing creation result remains pending until explicit acknowledgement',
      () async {
    final storage = _Storage();
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => response({
              'errorCode': r.url.path.endsWith('/query')
                  ? 'SCHEDULE_CREATION_RESULT_UNAVAILABLE'
                  : 'UNAVAILABLE'
            }, r.url.path.endsWith('/query') ? 404 : 503)));
    final c = ScheduleCreationController(
        api: api,
        store: ScheduleCreationStore(storage: storage),
        tenant: 'tenant',
        actor: 'adult',
        isCurrent: () => true);
    await c.load();
    await c.create('学习计划', definition());
    expect(await c.acknowledge(), isFalse);
    await c.query();
    expect(c.result, isNull);
    expect(c.pending, isNotNull);
    expect(await c.acknowledge(), isTrue);
  });
  test('a different returned routine is not accepted as the original creation',
      () async {
    final storage = _Storage();
    final other = definition();
    other['weekly'][0]['start'] = '23:00';
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((_) async => response(entry(other), 201)));
    final c = ScheduleCreationController(
        api: api,
        store: ScheduleCreationStore(storage: storage),
        tenant: 'tenant',
        actor: 'adult',
        isCurrent: () => true);
    await c.load();
    await c.create('学习计划', definition());
    expect(c.result, isNull);
    expect(c.pending, isNotNull);
    expect(c.queried, isFalse);
    expect(await c.acknowledge(), isFalse);
  });

  test('scope change during token retrieval stops POST dispatch', () async {
    final storage = _Storage();
    final token = Completer<String>();
    var current = true, calls = 0;
    final api = ParentApi(() => token.future,
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      calls++;
      return response(entry(), 201);
    }));
    final c = ScheduleCreationController(
        api: api,
        store: ScheduleCreationStore(storage: storage),
        tenant: 'tenant',
        actor: 'adult',
        isCurrent: () => current);
    await c.load();
    final pending = c.create('学习计划', definition());
    await Future<void>.delayed(Duration.zero);
    current = false;
    token.complete('new-token');
    await pending;
    expect(calls, 0);
    expect(storage.values, hasLength(1));
  });
  testWidgets(
      'mobile editor stages weekdays and confirms a separate persisted plan',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = _Storage();
    Json? submitted, opened;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      expect(storage.values, hasLength(1));
      submitted = jsonDecode(r.body) as Json;
      return response(entry(submitted!['definition']), 201);
    }));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      opened = await Navigator.of(context).push<Json>(
                          MaterialPageRoute(
                              builder: (_) => ScheduleEditorPage(
                                  session: _Session(api),
                                  store: ScheduleCreationStore(
                                      storage: storage))));
                    },
                    child: const Text('新建时间计划'))))));
    await tester.tap(find.text('新建时间计划'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '学习计划');
    await tester.tap(find.text('添加时段'));
    await tester.pumpAndSettle();
    expect(find.text('每周时段 · 5/56'), findsOneWidget);
    expect(submitted, isNull);
    await tester.ensureVisible(find.text('保存独立时间计划'));
    await tester.tap(find.text('保存独立时间计划'));
    await tester.pumpAndSettle();
    expect(submitted, isNull);
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(submitted!['definition']['weekly'], hasLength(5));
    await tester.ensureVisible(find.text('打开时间计划'));
    await tester.tap(find.text('打开时间计划'));
    await tester.pumpAndSettle();
    expect(opened!['id'], scheduleId);
    expect(storage.values, isEmpty);
  });
  testWidgets('copy edits a date override without mutating the original plan',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = _Storage();
    final original = entry();
    Json? submitted;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      expect(r.method, 'POST');
      expect(r.url.path, '/tenants/tenant/schedules');
      submitted = jsonDecode(r.body) as Json;
      return response(
          {'id': '00000000-0000-4000-8000-000000000002', ...submitted!}, 201);
    }));
    await tester.pumpWidget(MaterialApp(
        home: ScheduleEditorPage(
            session: _Session(api),
            seed: original,
            store: ScheduleCreationStore(storage: storage))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '独立副本');
    await tester.ensureVisible(find.text('2026-10-06'));
    await tester.tap(find.text('2026-10-06'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加时段'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用这些例外时段'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存独立时间计划'));
    await tester.tap(find.text('保存独立时间计划'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(submitted!['name'], '独立副本');
    expect(submitted!['definition']['exceptions'][0]['windows'], [
      {'start': '18:00', 'end': '20:00'}
    ]);
    expect(original['definition']['exceptions'][0]['windows'], isEmpty);
    expect(find.text('时间计划已保存'), findsOneWidget);
  });

  testWidgets(
      'plan detail labels evaluation as plan-only and keeps its original zone',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/schedules')) {
        return response({
          'items': [entry()],
          'nextCursor': null
        });
      }
      if (r.url.path.endsWith('/evaluation')) {
        return response({
          'allowed': false,
          'timeZone': 'Asia/Shanghai',
          'localDate': '2026-10-13',
          'previewDays': 8,
          'reasonCode': 'NO_WINDOW_IN_PREVIEW_HORIZON',
          'currentUntil': null,
          'nextAllowedAt': null
        });
      }
      return response(entry());
    }));
    await tester
        .pumpWidget(MaterialApp(home: ScheduleCenter(session: _Session(api))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习计划'));
    await tester.pumpAndSettle();
    expect(find.text('周一 22:00–次日 01:00'), findsOneWidget);
    await tester.tap(find.text('检查此刻的计划安排'));
    await tester.pumpAndSettle();
    expect(find.text('计划内：此刻不可用'), findsOneWidget);
    expect(find.textContaining('不代表设备正在执行'), findsOneWidget);
  });
}
