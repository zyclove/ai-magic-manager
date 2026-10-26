@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/labels.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/console_pages.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/resource_page.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'device_management_entry_test.dart' show EntrySession, settleReads, tenantId;

const _root = '/api/v1/tenants/$tenantId';
const _first = 'a1111111-1111-4111-8111-111111111111';
const _second = 'a2222222-2222-4222-8222-222222222222';
const _created = 'a3333333-3333-4333-8333-333333333333';
const _createLabels = {
  'subjects': '添加儿童', 'applications': '登记应用',
  'schedules': '创建计划', 'policies': '创建策略',
};

String _name(String section, {bool second = false}) =>
    '${second ? '第二条' : '第一条'}$section';

Json _record(String section, {bool second = false}) {
  final id = second ? _second : _first;
  final name = _name(section, second: second);
  return switch (section) {
    'subjects' => {'id': id, 'nickname': name, 'ageBand': 'AGE_7_12',
      'version': 7, 'archived': false},
    'applications' => {'id': id, 'displayName': name,
      'packageName': second ? 'fixture.second.app' : 'fixture.first.app',
      'platform': 'ANDROID', 'profile': 'PRIMARY',
      'signingDigests': <String>[], 'evidenceStatus': 'UNVERIFIED'},
    'schedules' => {'id': id, 'name': name, 'definition': {
      'timeZone': 'Asia/Shanghai', 'weekly': <Json>[], 'exceptions': <Json>[],
    }},
    'policies' => {'id': id, 'name': name, 'kind': 'POLICY',
      'rules': <Json>[], 'revision': 0},
    _ => throw StateError('Unsupported synthetic console section.'),
  };
}

http.Response _reply(Object body, {int status = 200}) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});

class _ConsoleSession extends EntrySession {
  _ConsoleSession(super.handler) {
    tenant = {...tenant!, 'name': '测试家庭', 'timeZone': 'Asia/Shanghai'};
  }
  @override
  void login({bool stepUp = false}) {}
  @override
  void account() {}
  @override
  void logout() {}
}

class _Fixture {
  final requests = <http.Request>[];
  final unknownCreates = <String>{};
  final created = <String, Json>{};
  bool unknownSubjectEdit = false, unknownArchive = false, closed = false;
  late final session = _ConsoleSession(handle);

  List<http.Request> listReads(String section) => requests.where((request) =>
      request.method == 'GET' && request.url.path == '$_root/$section').toList();
  List<http.Request> get writes =>
      requests.where((request) => request.method != 'GET').toList();

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET') {
      if (path == '$_root/subjects/$_first') return _reply(_record('subjects'));
      if (path == '$_root/schedule-presets') {
        return _reply({'schemaVersion': 1, 'items': <Json>[]});
      }
      for (final section in _createLabels.keys) {
        if (path == '$_root/$section') {
          final next = request.url.queryParameters['cursor'];
          if (next != null) {
            expect(next, 'next');
            return _reply({'items': [_record(section, second: true)], 'nextCursor': null});
          }
          return _reply({'items': [_record(section), if (created[section] != null) created[section]!],
            'nextCursor': 'next'});
        }
      }
    }
    for (final section in ['subjects', 'applications']) {
      if (request.method == 'POST' && path == '$_root/$section') {
        if (unknownCreates.contains(section)) {
          return _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503);
        }
        final record = <String, dynamic>{..._record(section),
          ...(jsonDecode(request.body) as Json), 'id': _created};
        created[section] = record;
        return _reply(record, status: 201);
      }
    }
    if (request.method == 'PATCH' && path == '$_root/subjects/$_first') {
      if (unknownSubjectEdit) return _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503);
      return _reply({..._record('subjects'), ...(jsonDecode(request.body) as Json)});
    }
    if (request.method == 'POST' && path == '$_root/subjects/$_first/archive') {
      if (unknownArchive) return _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503);
      return _reply({..._record('subjects'), 'archived': true, 'version': 8});
    }
    throw StateError('Unexpected synthetic console request: ${request.method} $path');
  }

  Future<void> cleanup(WidgetTester tester) async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await settleReads(tester);
    session.transport.close();
    session.dispose();
  }
}

Future<void> _mount(WidgetTester tester, _Fixture fixture, String section) async {
  await tester.pumpWidget(ChangeNotifierProvider<Session>.value(
      value: fixture.session,
      child: MaterialApp(theme: consoleTheme(), home: Scaffold(
          body: SingleChildScrollView(child: ConsolePages(section: section))))));
  await settleReads(tester);
}

Finder _button(String text) => find.ancestor(of: find.text(text),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));
Finder get _dialog => find.byType(AlertDialog).last;
Finder _dialogButton(String text) => find.descendant(of: _dialog, matching: _button(text));
Finder get _search => find.descendant(of: find.byType(ResourcePage).first,
    matching: find.byType(TextField));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var turn = 0; turn < 32 && !ready(); turn++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue, reason: 'The console workflow must reach its bounded next state.');
}

bool _listReady(WidgetTester tester, String section) {
  final create = _button(_createLabels[section]!);
  return find.byType(AlertDialog).evaluate().isEmpty && create.evaluate().length == 1 &&
      tester.widget<ButtonStyleButton>(create).onPressed != null;
}

Future<void> _twoPages(WidgetTester tester, _Fixture fixture, String section) async {
  await _mount(tester, fixture, section);
  await _tap(tester, _button('加载更多'));
  await _until(tester, () => fixture.listReads(section).length == 2 &&
      _listReady(tester, section) &&
      find.text(_name(section, second: true)).evaluate().length == 1);
  expect(fixture.listReads(section).last.url.queryParameters['cursor'], 'next');
  await tester.enterText(_search, '第一条');
  await tester.pump();
}

Future<void> _fillCreation(WidgetTester tester, String section, String name) async {
  if (section == 'subjects') {
    await tester.enterText(find.widgetWithText(TextFormField, '昵称'), name);
    await _tap(tester, find.widgetWithText(DropdownButtonFormField<String>, '年龄段'));
    await tester.pumpAndSettle();
    await _tap(tester, find.text(label('AGE_7_12')).last);
    await tester.pumpAndSettle();
  } else {
    await tester.enterText(find.widgetWithText(TextFormField, '应用名称'), name);
    await tester.enterText(find.widgetWithText(TextFormField, 'Android 包名'), 'fixture.new.app');
  }
}

Future<void> _closeUnknownForm(WidgetTester tester) async {
  await _until(tester, () {
    final close = _dialogButton('暂时关闭');
    return close.evaluate().length == 1 &&
        tester.widget<ButtonStyleButton>(close).onPressed != null;
  });
  await _tap(tester, _dialogButton('暂时关闭'));
  await tester.pump();
  expect(find.byKey(const Key('edit-dialog-unknown-close-notice')), findsOneWidget);
  await _tap(tester, find.byKey(const Key('edit-dialog-confirm-close')));
}

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('all console creation cancellations keep pages and attempted creations request one review',
      (tester) async {
    _wide(tester);
    for (final section in _createLabels.keys) {
      final fixture = _Fixture();
      addTearDown(() => fixture.cleanup(tester));
      await _twoPages(tester, fixture, section);
      await _tap(tester, _button(_createLabels[section]!));
      await _until(tester, () => find.byType(AlertDialog).evaluate().length == 1);
      await _tap(tester, _dialogButton('取消'));
      await _until(tester, () => _listReady(tester, section));
      expect(fixture.listReads(section), hasLength(2), reason: section);
      expect(fixture.writes, isEmpty);
      expect(tester.widget<TextField>(_search).controller!.text, '第一条');
      await tester.enterText(_search, '');
      await tester.pump();
      expect(find.text(_name(section, second: true)), findsOneWidget);

      if (section == 'subjects' || section == 'applications') {
        await _tap(tester, _button(_createLabels[section]!));
        await _until(tester, () => find.byType(EditDialog).evaluate().length == 1);
        await _fillCreation(tester, section, '新增$section');
        await _tap(tester, _dialogButton('保存'));
        await _until(tester, () => fixture.listReads(section).length == 3 && _listReady(tester, section));
        expect(fixture.writes, hasLength(1));
        expect(find.text('新增$section'), findsOneWidget);
        fixture.unknownCreates.add(section);
        await _tap(tester, _button(_createLabels[section]!));
        await _until(tester, () => find.byType(EditDialog).evaluate().length == 1);
        await _fillCreation(tester, section, '待核对$section');
        await _tap(tester, _dialogButton('保存'));
        await _closeUnknownForm(tester);
        await _until(tester, () => fixture.listReads(section).length == 4 && _listReady(tester, section));
        expect(fixture.writes, hasLength(2), reason: 'Closing an unknown creation must not replay POST.');
        expect(fixture.writes.every((request) => request.method == 'POST' &&
            request.url.path == '$_root/$section' &&
            request.headers['idempotency-key']?.isNotEmpty == true), isTrue);
        expect(fixture.writes[0].headers['idempotency-key'],
            isNot(fixture.writes[1].headers['idempotency-key']));
      }
      expect(tester.takeException(), isNull);
      await fixture.cleanup(tester);
    }
  });

  testWidgets('subject detail cancellation preserves pages and unknown edits and archives only read back',
      (tester) async {
    _wide(tester);
    final fixture = _Fixture()..unknownSubjectEdit = true..unknownArchive = true;
    addTearDown(() => fixture.cleanup(tester));
    await _twoPages(tester, fixture, 'subjects');
    Future<void> details() async {
      await _tap(tester, find.text(_name('subjects')));
      await _until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty &&
          _dialogButton('编辑档案').evaluate().length == 1);
    }
    Future<void> closeDetails() async {
      await _tap(tester, _dialogButton('关闭'));
      await _until(tester, () => _listReady(tester, 'subjects'));
    }
    await details();
    await closeDetails();
    await details();
    await _tap(tester, _dialogButton('编辑档案'));
    await _until(tester, () => find.byType(EditDialog).evaluate().length == 1);
    await _tap(tester, _dialogButton('取消'));
    await _until(tester, () => find.byType(EditDialog).evaluate().isEmpty);
    await closeDetails();
    await details();
    await _tap(tester, _dialogButton('归档'));
    await _until(tester, () => find.text('归档儿童档案').evaluate().length == 1);
    await _tap(tester, _dialogButton('取消'));
    await _until(tester, () => _dialogButton('编辑档案').evaluate().length == 1);
    await closeDetails();
    expect(fixture.listReads('subjects'), hasLength(2));
    expect(fixture.writes, isEmpty);
    expect(tester.widget<TextField>(_search).controller!.text, '第一条');
    await tester.enterText(_search, '');
    await tester.pump();
    expect(find.text(_name('subjects', second: true)), findsOneWidget);
    await tester.enterText(_search, '第一条');
    await tester.pump();

    await details();
    await _tap(tester, _dialogButton('编辑档案'));
    await _until(tester, () => find.byType(EditDialog).evaluate().length == 1);
    await tester.enterText(find.widgetWithText(TextFormField, '昵称'), '待核对的编辑昵称');
    await _tap(tester, _dialogButton('保存'));
    await _closeUnknownForm(tester);
    await _until(tester, () => fixture.listReads('subjects').length == 3 && _listReady(tester, 'subjects'));
    expect(fixture.writes, hasLength(1));
    final edit = fixture.writes.single;
    expect(edit.method, 'PATCH');
    expect(edit.url.path, '$_root/subjects/$_first');
    expect(edit.headers['if-match'], '"7"');
    expect(edit.headers['idempotency-key'], isNotEmpty);
    expect(jsonDecode(edit.body), {'nickname': '待核对的编辑昵称', 'ageBand': 'AGE_7_12'});

    await details();
    await _tap(tester, _dialogButton('归档'));
    await _until(tester, () => find.text('归档儿童档案').evaluate().length == 1);
    await _tap(tester, _dialogButton('确认归档'));
    await _until(tester, () => fixture.writes.length == 2 &&
        _dialogButton('关闭').evaluate().length == 1 &&
        tester.widget<ButtonStyleButton>(_dialogButton('关闭')).onPressed != null);
    expect(fixture.listReads('subjects'), hasLength(3));
    final archive = fixture.writes.last;
    expect(archive.method, 'POST');
    expect(archive.url.path, '$_root/subjects/$_first/archive');
    expect(archive.headers['if-match'], '"7"');
    expect(archive.body, isEmpty);
    await closeDetails();
    expect(fixture.listReads('subjects'), hasLength(4));
    expect(fixture.writes, hasLength(2));
    expect(fixture.requests.every((request) => request.method == 'GET' ||
        identical(request, edit) || identical(request, archive)), isTrue);
    expect(tester.takeException(), isNull);
  });
}
