@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/pages/classes_page.dart';
import 'package:guardian/ui/class_action_dialog.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:http/http.dart' as http;

import 'device_management_entry_test.dart' show EntrySession, settleReads, tenantId;

const _root = '/api/v1/tenants/$tenantId';
const _classes = '$_root/classes';
const _classId = '15555555-5555-4555-8555-555555555555';
const _firstStudent = '16666666-6666-4666-8666-666666666666';
const _secondStudent = '17777777-7777-4777-8777-777777777777';
const _classPath = '$_classes/$_classId';
const _students = '$_classPath/students';

http.Response _reply(Object? body, {int status = 200}) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});
http.Response _page(List<Json> rows, {String? cursor}) =>
    _reply({'items': rows, 'nextCursor': cursor});

class _ClassSession extends EntrySession {
  _ClassSession(super.handler) {
    tenant = {...tenant!, 'name': '测试机构', 'kind': 'ORGANIZATION'};
  }
  @override
  void login({bool stepUp = false}) {}
}

class _Fixture {
  final bool unknownRemoval;
  final requests = <http.Request>[];
  String name = '七年级一班';
  int version = 7;
  late final session = _ClassSession(handle);
  _Fixture({this.unknownRemoval = false});

  Json get record => {
    'id': _classId, 'name': name, 'state': 'ACTIVE', 'studentCount': 2,
    'version': version, 'updatedAt': '2026-10-26T00:00:00Z',
  };
  Json student(bool second) => {
    'id': second ? _secondStudent : _firstStudent,
    'nickname': second ? '陈同学' : '林同学', 'archived': false,
    'addedAt': '2026-10-26T00:00:00Z',
  };
  List<http.Request> reads(String path) => requests.where(
      (request) => request.method == 'GET' && request.url.path == path).toList();
  List<http.Request> get writes =>
      requests.where((request) => request.method != 'GET').toList();

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET') {
      if (path == _classes) return _page([record]);
      if (path == _classPath) return _reply(record);
      if (path == _students) {
        return request.url.queryParameters['cursor'] == null
            ? _page([student(false)], cursor: _firstStudent)
            : _page([student(true)]);
      }
    }
    if (request.method == 'PATCH' && path == _classPath) {
      name = (jsonDecode(request.body) as Json)['name'] as String;
      version++;
      return _reply(record);
    }
    if (request.method == 'DELETE' && path == '$_students/$_firstStudent') {
      if (unknownRemoval) return _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503);
      return http.Response('', 204);
    }
    throw StateError('Unexpected class workflow request: ${request.method} $path');
  }

  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settleReads(tester);
    session.transport.close();
    session.dispose();
  }
}

Widget _host(_Fixture fixture, {Key? pageKey}) => MaterialApp(
    theme: consoleTheme(), home: Scaffold(body: SingleChildScrollView(
        child: ClassesPage(key: pageKey, session: fixture.session))));

Finder _button(String label) => find.ancestor(of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));
Finder get _topDialog => find.byType(AlertDialog).last;
Finder _dialogButton(String label) =>
    find.descendant(of: _topDialog, matching: _button(label));
Finder get _confirm => find.descendant(of: _topDialog,
    matching: find.byWidgetPredicate((widget) => widget is FilledButton));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var frame = 0; frame < 24 && !ready(); frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue, reason: 'The bounded class workflow must finish.');
}

void _wide(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openClass(WidgetTester tester, _Fixture fixture) async {
  await _tap(tester, find.text(fixture.name));
  await _until(tester, () => find.text('修改名称').evaluate().isNotEmpty &&
      find.text('林同学').evaluate().isNotEmpty);
  await settleReads(tester);
}

void main() {
  testWidgets('read-only student details and cancelled rename retain roster pages and search',
      (tester) async {
    _wide(tester);
    final fixture = _Fixture();
    addTearDown(() => fixture.cleanup(tester));
    await tester.pumpWidget(_host(fixture));
    await settleReads(tester);
    await _openClass(tester, fixture);
    await _tap(tester, _button('加载更多'));
    await settleReads(tester);
    expect(fixture.reads(_students), hasLength(2));
    expect(fixture.reads(_students).last.url.queryParameters['cursor'], _firstStudent);
    final search = find.byType(TextField);
    await tester.enterText(search, '同学');
    await tester.pump();
    await _tap(tester, find.text('林同学'));
    await settleReads(tester);
    await _tap(tester, _dialogButton('关闭'));
    await settleReads(tester);
    expect(fixture.reads(_classPath), hasLength(1));
    expect(fixture.reads(_students), hasLength(2));
    expect(tester.widget<TextField>(search).controller!.text, '同学');
    expect(find.text('陈同学'), findsOneWidget);

    final rename = tester.widget<ButtonStyleButton>(_button('修改名称')).onPressed!;
    rename();
    rename();
    await settleReads(tester);
    expect(find.byType(ClassActionDialog), findsOneWidget);
    await _tap(tester, _dialogButton('关闭'));
    await settleReads(tester);
    expect(fixture.writes, isEmpty);
    expect(fixture.reads(_classPath), hasLength(1));
    expect(fixture.reads(_students), hasLength(2));
    expect(tester.widget<TextField>(search).controller!.text, '同学');
    expect(find.text('陈同学'), findsOneWidget);

    await _tap(tester, _button('修改名称'));
    await settleReads(tester);
    await tester.enterText(find.byKey(const Key('class-name')), '七年级甲班');
    await _tap(tester, _dialogButton('保存名称'));
    await _until(tester, () => fixture.reads(_classPath).length == 2 &&
        fixture.reads(_students).length == 3 && find.text('林同学').evaluate().isNotEmpty);
    await settleReads(tester);
    expect(fixture.writes, hasLength(1));
    final patch = fixture.writes.single;
    expect(patch.method, 'PATCH');
    expect(patch.url.path, _classPath);
    expect(patch.headers['if-match'], '"7"');
    expect(patch.headers['idempotency-key'], isNotEmpty);
    expect(jsonDecode(patch.body), {'name': '七年级甲班'});
    expect(fixture.reads(_classPath), hasLength(2));
    expect(fixture.reads(_students), hasLength(3));
    expect(fixture.reads(_classes), hasLength(1));
    expect(find.text('七年级甲班'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retired removal confirmation preserves a cover and unknown DELETE only triggers review reads',
      (tester) async {
    _wide(tester);
    final fixture = _Fixture(unknownRemoval: true);
    addTearDown(() => fixture.cleanup(tester));
    await tester.pumpWidget(_host(fixture));
    await settleReads(tester);
    await _openClass(tester, fixture);
    final rename = tester.widget<ButtonStyleButton>(_button('修改名称')).onPressed!;
    final assign = tester.widget<ButtonStyleButton>(_button('分配教师')).onPressed!;
    await _tap(tester, find.text('林同学'));
    await settleReads(tester);
    await _tap(tester, _dialogButton('移出班级'));
    await settleReads(tester);
    final heldConfirm = tester.widget<FilledButton>(_confirm).onPressed!;
    final confirmation = ModalRoute.of(tester.element(_confirm))!
        as OwnedDialogRoute<bool>;
    unawaited(showDialog<void>(context: tester.element(_topDialog),
        builder: (context) => AlertDialog(title: const Text('独立覆盖通知'), actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭通知')),
        ])));
    await settleReads(tester);
    final originalEpoch = fixture.session.scopeGeneration;
    await tester.pumpWidget(_host(fixture,
        pageKey: const ValueKey('retired-under-cover')));
    await settleReads(tester);
    expect(fixture.session.scopeGeneration, originalEpoch);
    expect(confirmation.available, isFalse);
    heldConfirm();
    rename();
    assign();
    await settleReads(tester);
    expect(fixture.writes, isEmpty);
    expect(find.text('独立覆盖通知'), findsOneWidget);
    await _tap(tester, _dialogButton('关闭通知'));
    await settleReads(tester);
    await _tap(tester, _dialogButton('关闭'));
    await settleReads(tester);

    await tester.pumpWidget(_host(fixture, pageKey: const ValueKey('fresh-classes')));
    await settleReads(tester);
    await _openClass(tester, fixture);
    await _tap(tester, find.text('林同学'));
    await settleReads(tester);
    await _tap(tester, _dialogButton('移出班级'));
    await settleReads(tester);
    final classReads = fixture.reads(_classPath).length;
    final rosterReads = fixture.reads(_students).length;
    await _tap(tester, _confirm);
    await settleReads(tester);
    expect(fixture.writes, hasLength(1));
    final removal = fixture.writes.single;
    expect(removal.method, 'DELETE');
    expect(removal.url.path, '$_students/$_firstStudent');
    expect(removal.headers['if-match'], '"7"');
    expect(removal.headers['idempotency-key'], isNotEmpty);
    expect(fixture.reads(_classPath), hasLength(classReads));
    expect(fixture.reads(_students), hasLength(rosterReads));
    await _tap(tester, _dialogButton('关闭'));
    await _until(tester, () => fixture.reads(_classPath).length == classReads + 1 &&
        fixture.reads(_students).length == rosterReads + 1 &&
        find.text('林同学').evaluate().isNotEmpty);
    await settleReads(tester);
    expect(fixture.reads(_classPath), hasLength(classReads + 1));
    expect(fixture.reads(_students), hasLength(rosterReads + 1));
    expect(fixture.writes, hasLength(1), reason: 'Review must never replay DELETE.');
    expect(fixture.requests.every((request) =>
        request.method == 'GET' || identical(request, removal)), isTrue);
    expect(tester.takeException(), isNull);
  });
}
