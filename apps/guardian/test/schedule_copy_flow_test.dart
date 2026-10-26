@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/console_pages.dart';
import 'package:guardian/pages/editors.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

const _tenant = '44444444-4444-4444-8444-444444444444';
const _sourceId = '11111111-1111-4111-8111-111111111111';
const _copyId = '22222222-2222-4222-8222-222222222222';
const _sourceName = '原学习计划';
const _copyName = '调整后的学习计划';
const _path = '/api/v1/tenants/$_tenant/schedules';

Json _definition() => {
      'timeZone': 'America/New_York',
      'weekly': [
        {'day': 'MONDAY', 'start': '22:30', 'end': '01:15'},
        {'day': 'FRIDAY', 'start': '19:00', 'end': '20:00'},
      ],
      'exceptions': [
        {
          'date': '2026-12-24',
          'windows': [
            {'start': '09:00', 'end': '11:00'},
            {'start': '14:00', 'end': '16:00'},
          ],
        },
        {'date': '2026-12-25', 'windows': <Json>[]},
      ],
    };

Json _source({Json? definition}) => {
      'id': _sourceId,
      'name': _sourceName,
      'definition': definition ?? _definition(),
    };

Json _presetCatalog() => {
      'schemaVersion': 1,
      'items': [{
        'id': 'weekend-morning', 'name': '周末上午示例',
        'description': '仅供填写参考，请按实际安排调整。',
        'weekly': [
          {'day': 'SATURDAY', 'start': '09:00', 'end': '11:00'},
          {'day': 'SUNDAY', 'start': '09:00', 'end': '11:00'},
        ],
      }],
    };

class _Session extends Session {
  _Session(this.testApi, {String initialRole = 'OWNER'}) {
    profile = {'subject': 'adult-a'};
    tenant = {
      'id': _tenant,
      'kind': 'FAMILY',
      'name': '测试家庭',
      'timeZone': 'Asia/Shanghai',
    };
    role = initialRole;
  }

  final Api testApi;
  @override
  Api get api => testApi;
  @override
  bool get authenticated => profile != null;
  @override
  int get scopeGeneration => 0;

  void actorAwayAndBack() {
    profile = {'subject': 'adult-b'};
    notifyListeners();
    profile = {'subject': 'adult-a'};
    notifyListeners();
  }
}

class _Fixture {
  final requests = <http.Request>[];
  Json? saved;
  late final transport = MockClient((request) async {
    requests.add(request);
    if (request.method == 'GET' &&
        request.url.path == '/api/v1/tenants/$_tenant/schedule-presets') {
      if (presetResponse != null) return await presetResponse!(request);
      return _reply(_presetCatalog());
    }
    if (request.method == 'GET' && request.url.path == _path) {
      return _reply({
        'items': [_source(definition: definition), if (saved != null) saved!],
        'nextCursor': null,
      });
    }
    if (request.method == 'POST' && request.url.path == _path) {
      if (createFailure != null) {
        return _reply({'errorCode': createFailure!.code},
            status: createFailure!.status);
      }
      saved = {'id': _copyId, ...(jsonDecode(request.body) as Json)};
      return _reply(saved!, status: 201);
    }
    throw StateError('Unexpected request: ${request.method} ${request.url}');
  });
  late final api =
      Api(() async => transport, baseUrl: 'https://fixture.invalid/api/v1');
  late final session = _Session(api, initialRole: initialRole);
  final String initialRole;
  final Json? definition;
  final ApiFailure? createFailure;
  final Future<http.Response> Function(http.Request)? presetResponse;
  _Fixture({this.initialRole = 'OWNER', this.definition, this.createFailure,
      this.presetResponse});

  List<http.Request> get reads =>
      requests.where((request) => request.method == 'GET').toList();
  List<http.Request> get writes =>
      requests.where((request) => request.method != 'GET').toList();

  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    transport.close();
    session.dispose();
  }
}

http.Response _reply(Json value, {int status = 200}) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> _flush(WidgetTester tester) async {
  // These browser-only production imports use real streamed HTTP responses.
  for (var frame = 0; frame < 6; frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 24 && !ready(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await _flush(tester);
}

Finder _button(String text) => find.ancestor(
    of: find.text(text),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

Finder _editorText(String text) =>
    find.descendant(of: find.byType(ScheduleEditor), matching: find.text(text));

Future<OwnedDialogRoute<dynamic>> _openDetails(
    WidgetTester tester, _Fixture fixture,
    {Size viewport = const Size(1200, 1000)}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  addTearDown(() => fixture.cleanup(tester));
  await tester.pumpWidget(ChangeNotifierProvider<Session>.value(
      value: fixture.session,
      child: MaterialApp(
          theme: consoleTheme(),
          home: const Scaffold(
              body: SingleChildScrollView(
                  child: ConsolePages(section: 'schedules'))))));
  await _until(tester, () => find.text(_sourceName).evaluate().isNotEmpty);
  expect(fixture.reads, hasLength(1));
  await tester.ensureVisible(find.text(_sourceName));
  await tester.tap(find.text(_sourceName));
  await _flush(tester);
  expect(find.byType(AlertDialog), findsOneWidget);
  return ModalRoute.of(tester.element(find.byType(AlertDialog)))!
      as OwnedDialogRoute<dynamic>;
}

Future<VoidCallback> _openCopy(WidgetTester tester) async {
  expect(_button('复制并调整'), findsOneWidget);
  await tester.ensureVisible(_button('复制并调整'));
  await tester.tap(_button('复制并调整'));
  await _until(tester, () => find.byType(ScheduleEditor).evaluate().isNotEmpty);
  expect(find.text('复制并调整时间计划'), findsOneWidget);
  expect(find.byType(ScheduleEditor), findsOneWidget);
  return tester.widget<ButtonStyleButton>(_button('保存副本')).onPressed!;
}

void main() {
  testWidgets('schedule-copy copy-cancel keeps details without refreshing rows',
      (tester) async {
    final fixture = _Fixture();
    final details =
        await _openDetails(tester, fixture, viewport: const Size(390, 844));
    await _openCopy(tester);
    await tester.tap(_button('取消'));
    await _flush(tester);
    expect(find.byType(ScheduleEditor), findsNothing);
    expect(details.available, isTrue);
    expect(details.isCurrent, isTrue);
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.text(_sourceName)),
        findsOneWidget);
    expect(fixture.requests, hasLength(1));
    expect(fixture.writes, isEmpty);
  });

  testWidgets('schedule-copy saves every time window and refreshes the list',
      (tester) async {
    final fixture = _Fixture();
    final details = await _openDetails(tester, fixture);
    await _openCopy(tester);
    final name = find.widgetWithText(TextFormField, '计划名称');
    final zone = find.widgetWithText(TextFormField, '时区');
    expect(tester.widget<TextFormField>(name).controller!.text,
        '$_sourceName（副本）');
    expect(tester.widget<TextFormField>(zone).controller!.text,
        'America/New_York');
    expect(
        find.descendant(
            of: find.byType(ScheduleEditor),
            matching: find.textContaining('22:30 – 01:15')),
        findsOneWidget);
    expect(_editorText('2026-12-24 · 09:00 – 11:00、14:00 – 16:00'),
        findsOneWidget);
    expect(_editorText('2026-12-25 · 全天关闭'), findsOneWidget);
    await tester.enterText(name, _copyName);
    await tester.ensureVisible(_button('保存副本'));
    await tester.tap(_button('保存副本'));
    await _until(
        tester,
        () =>
            find.byType(AlertDialog).evaluate().isEmpty &&
            fixture.reads.length == 2 &&
            find.text(_copyName).evaluate().isNotEmpty);

    expect(fixture.writes, hasLength(1));
    final request = fixture.writes.single;
    expect(request.method, 'POST');
    expect(request.url.path, _path);
    expect(jsonDecode(request.body), {
      'name': _copyName,
      'definition': _definition(),
    });
    expect(request.headers['idempotency-key'], isNotEmpty);
    expect(request.headers['idempotency-key'], isNot(_sourceId));
    expect(details.available, isFalse);
    expect(find.byType(AlertDialog), findsNothing);
    expect(fixture.reads, hasLength(2));
    expect(find.text(_sourceName), findsOneWidget);
    expect(find.text(_copyName), findsOneWidget);
    expect(fixture.saved!['id'], _copyId);
  });

  testWidgets('schedule-copy special-date changes only the outgoing draft',
      (tester) async {
    final definition = _definition();
    final original = jsonEncode(definition);
    final fixture = _Fixture(definition: definition);
    final details = await _openDetails(tester, fixture);
    await _openCopy(tester);
    final row = find.byKey(const Key('schedule-exception-2026-12-24'));
    final edit = find.descendant(
        of: row,
        matching: find.byWidgetPredicate((widget) =>
            widget is IconButton && widget.tooltip == '调整日期例外'));
    final apply = find.byKey(const Key('schedule-exception-apply'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await _until(tester, () => apply.evaluate().length == 1);
    expect(fixture.writes, isEmpty);
    await tester.tap(find.byKey(const Key('schedule-exception-cancel')));
    await _until(
        tester,
        () =>
            edit.evaluate().length == 1 &&
            tester.widget<IconButton>(edit).onPressed != null);
    expect(_editorText('2026-12-24 · 09:00 – 11:00、14:00 – 16:00'),
        findsOneWidget);
    expect(jsonEncode(definition), original);
    expect(fixture.writes, isEmpty);

    await tester.tap(edit);
    await _until(tester, () => apply.evaluate().length == 1);
    await tester.tap(find.byKey(const Key('schedule-exception-mode-closed')));
    await tester.tap(apply);
    await _until(
        tester,
        () =>
            _editorText('2026-12-24 · 全天关闭').evaluate().length == 1 &&
            tester.widget<IconButton>(edit).onPressed != null);
    expect(fixture.writes, isEmpty,
        reason: 'Applying a date exception only updates the local draft.');
    expect(jsonEncode(definition), original);
    await tester.ensureVisible(_button('保存副本'));
    await tester.tap(_button('保存副本'));
    await _until(
        tester,
        () =>
            fixture.saved != null &&
            find.byType(AlertDialog).evaluate().isEmpty);
    final expected = jsonDecode(original) as Json;
    (expected['exceptions'] as List).first['windows'] = <Json>[];
    expect(fixture.writes, hasLength(1));
    expect((jsonDecode(fixture.writes.single.body) as Json)['definition'],
        expected);
    expect(jsonEncode(definition), original);
    expect(details.available, isFalse);
    expect(fixture.reads, hasLength(2));
  });

  testWidgets('schedule-preset fills an empty draft only on demand', (tester) async {
    final definition = _definition()..['weekly'] = <Json>[];
    final original = jsonEncode(definition);
    final fixture = _Fixture(definition: definition);
    await _openDetails(tester, fixture);
    await _openCopy(tester);
    expect(fixture.requests.where((r) => r.url.path.endsWith('/schedule-presets')), isEmpty);
    final name = find.widgetWithText(TextFormField, '计划名称');
    await tester.enterText(name, '');
    final choose = find.byKey(const Key('schedule-choose-preset'));
    await tester.ensureVisible(choose);
    await tester.tap(choose);
    final use = find.byKey(const Key('schedule-preset-use-weekend-morning'));
    await _until(tester, () => use.evaluate().length == 1);
    expect(fixture.writes, isEmpty);
    await tester.tap(use);
    await _until(tester, () => tester.widget<ButtonStyleButton>(choose).onPressed != null);
    expect(tester.widget<TextFormField>(name).controller!.text, '周末上午示例');
    expect(find.byKey(const Key('schedule-preset-replace-confirm')), findsNothing);
    await tester.ensureVisible(_button('保存副本'));
    await tester.tap(_button('保存副本'));
    await _until(tester, () => fixture.saved != null);
    final expected = jsonDecode(original) as Json;
    expected['weekly'] = (_presetCatalog()['items'] as List).single['weekly'];
    expect(jsonDecode(fixture.writes.single.body), {'name': '周末上午示例', 'definition': expected});
    expect(jsonEncode(definition), original);
    expect(fixture.requests.where((r) => r.url.path.endsWith('/schedule-presets')), hasLength(1));
  });

  testWidgets('schedule-preset replacement requires confirmation and preserves other fields',
      (tester) async {
    final definition = _definition();
    final original = jsonEncode(definition);
    final fixture = _Fixture(definition: definition);
    await _openDetails(tester, fixture);
    await _openCopy(tester);
    final choose = find.byKey(const Key('schedule-choose-preset'));
    final use = find.byKey(const Key('schedule-preset-use-weekend-morning'));
    final cancel = find.byKey(const Key('schedule-preset-replace-cancel'));
    await tester.ensureVisible(choose);
    await tester.tap(choose);
    await _until(tester, () => use.evaluate().length == 1);
    await tester.tap(use);
    await _until(tester, () => cancel.evaluate().length == 1);
    await tester.tap(cancel);
    await _until(tester, () => tester.widget<ButtonStyleButton>(choose).onPressed != null);
    expect(_editorText('2026-12-24 · 09:00 – 11:00、14:00 – 16:00'), findsOneWidget);
    expect(find.textContaining('22:30 – 01:15'), findsWidgets);
    expect(fixture.writes, isEmpty);
    await tester.tap(choose);
    await _until(tester, () => use.evaluate().length == 1);
    await tester.tap(use);
    final confirm = find.byKey(const Key('schedule-preset-replace-confirm'));
    await _until(tester, () => confirm.evaluate().length == 1);
    await tester.tap(confirm);
    await _until(tester, () => tester.widget<ButtonStyleButton>(choose).onPressed != null);
    expect(fixture.writes, isEmpty);
    await tester.ensureVisible(_button('保存副本'));
    await tester.tap(_button('保存副本'));
    await _until(tester, () => fixture.saved != null);
    final expected = jsonDecode(original) as Json;
    expected['weekly'] = (_presetCatalog()['items'] as List).single['weekly'];
    expect(jsonDecode(fixture.writes.single.body), {'name': '$_sourceName（副本）', 'definition': expected});
    expect(jsonEncode(definition), original);
  });

  testWidgets('schedule-preset read failure keeps manual editing and revokes late results',
      (tester) async {
    final pending = Completer<http.Response>();
    var attempts = 0;
    final fixture = _Fixture(presetResponse: (_) async {
      attempts++;
      return attempts == 1 ? _reply({'schemaVersion': 2, 'items': []}) : await pending.future;
    });
    await _openDetails(tester, fixture);
    final heldSave = await _openCopy(tester);
    final choose = find.byKey(const Key('schedule-choose-preset'));
    await tester.ensureVisible(choose);
    await tester.tap(choose);
    await _until(tester, () => tester.widget<ButtonStyleButton>(choose).onPressed != null);
    expect(find.textContaining('时间安排示例无法校验'), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(_button('保存副本')).onPressed, isNotNull);
    expect(find.byKey(const Key('schedule-editor-retry-original')), findsNothing);
    final heldChoose = tester.widget<ButtonStyleButton>(choose).onPressed!;
    await tester.tap(choose);
    for (var turn = 0; turn < 24 && attempts != 2; turn++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(attempts, 2);
    fixture.session.actorAwayAndBack();
    pending.complete(_reply(_presetCatalog()));
    await _flush(tester);
    heldChoose();
    heldSave();
    await _flush(tester);
    expect(attempts, 2);
    expect(fixture.writes, isEmpty);
    expect(find.byKey(const Key('schedule-preset-use-weekend-morning')), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
  });

  testWidgets('schedule-copy saves exception-only and fully closed definitions',
      (tester) async {
    for (final exceptions in <List<Json>>[
      [
        {
          'date': '2026-12-24',
          'windows': [
            {'start': '09:00', 'end': '11:00'}
          ]
        }
      ],
      [],
    ]) {
      final definition = <String, dynamic>{
        'timeZone': 'UTC',
        'weekly': <Json>[],
        'exceptions': exceptions,
      };
      final fixture = _Fixture(definition: definition);
      await _openDetails(tester, fixture);
      await _openCopy(tester);
      expect(find.textContaining('当前没有每周允许时段'), findsOneWidget);
      await tester.tap(_button('保存副本'));
      await _until(
          tester,
          () =>
              fixture.reads.length == 2 &&
              find.byType(AlertDialog).evaluate().isEmpty);
      expect(fixture.writes, hasLength(1));
      expect((jsonDecode(fixture.writes.single.body) as Json)['definition'],
          definition);
      expect(fixture.reads, hasLength(2));
    }
  });

  testWidgets(
      'schedule-copy account ABA cannot revive a captured save callback',
      (tester) async {
    final fixture = _Fixture();
    await _openDetails(tester, fixture);
    final oldSave = await _openCopy(tester);
    fixture.session.actorAwayAndBack();
    await _flush(tester);
    oldSave();
    await _flush(tester);
    expect(fixture.writes, isEmpty);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.textContaining('2026-12-24'), findsNothing);
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('America/New_York')),
        findsNothing);
  });

  testWidgets(
      'schedule-copy ending parent details invalidates the child editor',
      (tester) async {
    final fixture = _Fixture();
    final details = await _openDetails(tester, fixture);
    final oldSave = await _openCopy(tester);
    details.finish();
    await _flush(tester);
    oldSave();
    await _flush(tester);
    expect(details.available, isFalse);
    expect(fixture.writes, isEmpty);
    expect(fixture.reads, hasLength(1));
    expect(find.byType(TextFormField), findsNothing);
    expect(find.textContaining('2026-12-24'), findsNothing);
  });

  testWidgets('schedule-copy auditor can read a schedule but cannot copy it',
      (tester) async {
    final fixture = _Fixture(initialRole: 'AUDITOR');
    final details = await _openDetails(tester, fixture);
    expect(find.text('复制并调整'), findsNothing);
    expect(find.text('检查此刻是否允许'), findsOneWidget);
    await tester.tap(_button('关闭'));
    await _flush(tester);
    expect(details.available, isFalse);
    expect(fixture.requests, hasLength(1));
    expect(fixture.writes, isEmpty);
  });

  testWidgets('schedule-copy unknown close reconciles without claiming saved',
      (tester) async {
    final fixture =
        _Fixture(createFailure: const ApiFailure(503, 'REQUEST_FAILED'));
    final details = await _openDetails(tester, fixture);
    await _openCopy(tester);
    await tester.tap(_button('保存副本'));
    final close = find.byKey(const Key('schedule-editor-close-unknown'));
    await _until(tester, () => close.evaluate().isNotEmpty);
    expect(fixture.writes, hasLength(1));
    expect(details.available, isTrue);
    await tester.tap(close);
    await _flush(tester);
    expect(find.text('暂时关闭未确认的提交？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('schedule-editor-keep-unknown')));
    await _flush(tester);
    expect(fixture.reads, hasLength(1));
    expect(details.available, isTrue);
    await tester.tap(close);
    await _flush(tester);
    await tester
        .tap(find.byKey(const Key('schedule-editor-confirm-close-unknown')));
    await _until(
        tester,
        () =>
            fixture.reads.length == 2 &&
            find.byType(AlertDialog).evaluate().isEmpty);
    expect(details.available, isFalse);
    expect(fixture.reads, hasLength(2));
    expect(fixture.writes, hasLength(1));
    expect(fixture.saved, isNull);
    expect(find.text('保存成功'), findsNothing);
  });

  testWidgets(
      'schedule-copy expired key keeps the draft and requires list review',
      (tester) async {
    final fixture = _Fixture(
        createFailure: const ApiFailure(409, 'IDEMPOTENCY_KEY_EXPIRED'));
    final details = await _openDetails(tester, fixture);
    final oldSave = await _openCopy(tester);
    oldSave();
    final close = find.byKey(const Key('editor-close-stopped'));
    await _until(tester, () => close.evaluate().isNotEmpty);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text('保存副本'), findsNothing);
    expect(fixture.writes, hasLength(1));
    await tester.tap(find.text('保留的草稿'));
    await _flush(tester);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is SelectableText &&
            (widget.data ?? '').contains('$_sourceName（副本）')),
        findsOneWidget);
    oldSave();
    await _flush(tester);
    expect(fixture.writes, hasLength(1));
    await tester.tap(close);
    await _until(
        tester,
        () =>
            fixture.reads.length == 2 &&
            find.byType(AlertDialog).evaluate().isEmpty);
    expect(details.available, isFalse);
    expect(fixture.saved, isNull);
    expect(fixture.writes, hasLength(1));
    expect(find.text('保存成功'), findsNothing);
  });
}
