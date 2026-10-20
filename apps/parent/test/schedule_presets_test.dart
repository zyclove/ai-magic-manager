import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/schedule_presets.dart';
import 'package:parent/core/schedules.dart';
import 'package:parent/ui/schedule_editor.dart';

import 'support/parent_operation_journal_fixture.dart';

class _Storage extends ParentDurableStorage with ParentAtomicJournalFixture {
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
  void changeScope({bool sameTenant = false}) {
    generation++;
    if (!sameTenant) tenant = {'id': 'other', 'timeZone': 'Asia/Shanghai'};
    notifyListeners();
  }
}

Json catalog() => {
      'schemaVersion': 1,
      'items': [
        {
          'id': 'weekend',
          'name': '周末示例',
          'description': '可修改的填写示例',
          'weekly': [
            {'day': 'SATURDAY', 'start': '09:00', 'end': '11:00'}
          ]
        }
      ]
    };
Json original() => {
      'id': '00000000-0000-4000-8000-000000000001',
      'name': '原安排',
      'definition': {
        'timeZone': 'Europe/Berlin',
        'weekly': [
          {'day': 'MONDAY', 'start': '22:00', 'end': '01:00'}
        ],
        'exceptions': [
          {'date': '2026-10-25', 'windows': []}
        ]
      }
    };
http.Response response(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status);

Future<void> _open(WidgetTester tester, _Session session,
    {Json? seed,
    _Storage? storage,
    Size size = const Size(1000, 1900),
    double textScale = 1}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!),
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => ScheduleEditorPage(
                              session: session,
                              seed: seed,
                              store: ScheduleCreationStore(
                                  storage: storage ?? _Storage())))),
                  child: const Text('打开计划'))))));
  await tester.tap(find.text('打开计划'));
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester) async {
  await tester.ensureVisible(find.text('选择时间安排示例'));
  await tester.tap(find.text('选择时间安排示例'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('使用周末示例'));
  await tester.pumpAndSettle();
}

void main() {
  test('catalog validates all entries and detaches immutable values', () {
    final raw = catalog();
    final parsed = SchedulePreset.readCatalog(raw);
    raw['items'][0]['weekly'][0]['start'] = '13:00';
    expect(parsed.single.weekly.single['start'], '09:00');
    expect(() => parsed.single.weekly.single['start'] = '14:00',
        throwsUnsupportedError);
    expect(() => parsed.clear(), throwsUnsupportedError);
    expect(
        SchedulePreset.readCatalog({'schemaVersion': 1, 'items': []}), isEmpty);
    final cases = <Json>[
      {...catalog(), 'schemaVersion': 2},
      {...catalog(), 'items': List.generate(21, (_) => catalog()['items'][0])},
      {
        ...catalog(),
        'items': [catalog()['items'][0], catalog()['items'][0]]
      },
    ];
    for (final change in <Json>[
      {'name': '\u202ehidden'},
      {'weekly': []},
      {'id': '../bad'},
      {
        'weekly': [
          {'day': 'MONDAY', 'start': '09:00', 'end': '09:00'}
        ]
      },
      {
        'weekly': [
          {'day': 'MONDAY', 'start': '25:00', 'end': '09:00'}
        ]
      },
      {
        'weekly': [
          catalog()['items'][0]['weekly'][0],
          catalog()['items'][0]['weekly'][0]
        ]
      },
    ]) {
      cases.add({
        'schemaVersion': 1,
        'items': [
          {...catalog()['items'][0] as Json, ...change}
        ]
      });
    }
    for (final invalid in cases) {
      expect(() => SchedulePreset.readCatalog(invalid),
          throwsA(isA<ParentApiException>()));
    }
  });

  testWidgets(
      'configured API prefix is used once and reads never create schedules',
      (tester) async {
    final paths = <String>[];
    final session = _Session(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((request) async {
      paths.add('${request.method} ${request.url.path}');
      return request.url.path == '/api/v1/tenants/tenant/schedule-presets'
          ? response(catalog())
          : response({'errorCode': 'NOT_FOUND'}, 404);
    })));
    await _open(tester, session);
    expect(paths, isEmpty);
    await tester.tap(find.text('选择时间安排示例'));
    await tester.pumpAndSettle();
    expect(paths, ['GET /api/v1/tenants/tenant/schedule-presets']);
    expect(find.text('使用周末示例'), findsOneWidget);
    await tester.tap(find.text('使用周末示例'));
    await tester.pumpAndSettle();
    expect(find.text('每周时段 · 1/56'), findsOneWidget);
    expect(paths, hasLength(1));
  });

  testWidgets(
      'replacement cancel preserves draft and confirmed save keeps zone and exceptions',
      (tester) async {
    Json? submitted;
    final seed = original();
    final storage = _Storage();
    final session = _Session(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((request) async {
      if (request.method == 'GET') return response(catalog());
      expect(storage.values, hasLength(1));
      expect(request.headers['Idempotency-Key'], isNotEmpty);
      submitted = jsonDecode(request.body) as Json;
      return response(
          {'id': '00000000-0000-4000-8000-000000000002', ...submitted!}, 201);
    })));
    await _open(tester, session, seed: seed, storage: storage);
    await choose(tester);
    await tester.tap(find.text('保留原安排'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, '22:00–次日 01:00'), findsOneWidget);
    expect(find.widgetWithText(InputChip, '09:00–11:00'), findsNothing);
    expect(submitted, isNull);
    await choose(tester);
    await tester.tap(find.text('替换每周时段'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, '09:00–11:00'), findsOneWidget);
    expect(submitted, isNull);
    await tester.ensureVisible(find.text('保存独立时间计划'));
    await tester.tap(find.text('保存独立时间计划'));
    await tester.pumpAndSettle();
    expect(submitted, isNull);
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(submitted!['name'], '原安排');
    expect(submitted!['definition'], {
      'timeZone': 'Europe/Berlin',
      'weekly': catalog()['items'][0]['weekly'],
      'exceptions': seed['definition']['exceptions']
    });
    expect(seed, original());
    expect(find.text('时间计划已保存'), findsOneWidget);
  });

  testWidgets('failed and empty catalog leave manual editing available',
      (tester) async {
    var reads = 0;
    final session = _Session(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((request) async {
      expect(request.method, 'GET');
      reads++;
      if (reads == 1) throw http.ClientException('offline');
      return response({'schemaVersion': 1, 'items': []});
    })));
    await _open(tester, session);
    await tester.tap(find.text('选择时间安排示例'));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂时无法读取示例'), findsOneWidget);
    await tester.tap(find.text('选择时间安排示例'));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂未提供时间安排示例'), findsOneWidget);
    await tester.ensureVisible(find.text('添加时段'));
    await tester.tap(find.text('添加时段'));
    await tester.pumpAndSettle();
    expect(find.text('每周时段 · 5/56'), findsOneWidget);
    expect(reads, 2);
  });

  for (final sameTenant in [false, true]) {
    testWidgets(
        'scope change discards outstanding catalog, same tenant=$sameTenant',
        (tester) async {
      final pending = Completer<http.Response>();
      final session = _Session(ParentApi(() async => 'fixture',
          baseUrl: 'https://fixture.invalid/api/v1',
          client: MockClient((_) => pending.future)));
      await _open(tester, session);
      await tester.tap(find.text('选择时间安排示例'));
      await tester.pump();
      session.changeScope(sameTenant: sameTenant);
      await tester.pump();
      pending.complete(response(catalog()));
      await tester.pumpAndSettle();
      expect(find.text('打开计划'), findsOneWidget);
      expect(find.text('选择时间安排示例'), findsNothing);
      expect(find.text('使用周末示例'), findsNothing);
    });
  }

  testWidgets('scope change closes the open picker and editor', (tester) async {
    final session = _Session(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((_) async => response(catalog()))));
    await _open(tester, session);
    await tester.tap(find.text('选择时间安排示例'));
    await tester.pumpAndSettle();
    expect(find.text('使用周末示例'), findsOneWidget);
    session.changeScope();
    await tester.pumpAndSettle();
    expect(find.text('打开计划'), findsOneWidget);
    expect(find.text('使用周末示例'), findsNothing);
  });

  testWidgets(
      'narrow screen and large text support selection and removing a window',
      (tester) async {
    final session = _Session(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((_) async => response(catalog()))));
    await _open(tester, session, size: const Size(390, 844), textScale: 2);
    await tester.ensureVisible(find.text('选择时间安排示例'));
    await tester.tap(find.text('选择时间安排示例'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('使用周末示例'));
    await tester.tap(find.text('使用周末示例'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('移除周六 09:00–11:00'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移除周六 09:00–11:00'));
    await tester.pumpAndSettle();
    expect(find.text('每周时段 · 0/56'), findsOneWidget);
    expect(find.byType(InputChip), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
