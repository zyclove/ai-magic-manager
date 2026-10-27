@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/pages/quota_plan_editor.dart';
import 'package:guardian/pages/quota_plans_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/resource_page.dart';
import 'package:http/http.dart' as http;

import 'device_management_entry_test.dart' show EntrySession, tenantId;

const _root = '/api/v1/tenants/$tenantId';
const _path = '$_root/quota-plans';
const _first = 'a1111111-1111-4111-8111-111111111111';
const _second = 'a2222222-2222-4222-8222-222222222222';
const _created = 'a3333333-3333-4333-8333-333333333333';
const _child = 'b1111111-1111-4111-8111-111111111111';
const _firstName = '第一份重复计划';
const _secondName = '第二份重复计划';
const _zone = 'America/Los_Angeles';
const _createdAt = 1760000000000;

Json _plan(String id, String name) => {
  'id': id, 'subjectId': _child, 'scope': 'TOTAL', 'applicationId': null,
  'timeZone': _zone, 'name': name, 'state': 'ACTIVE',
  'effectiveFrom': '2026-10-09', 'version': 7, 'createdAt': _createdAt,
  'weeklyLimits': {for (final day in quotaWeek.keys) day: day == 'MONDAY' ? 3661 : 3600},
  'dateOverrides': {'2026-10-09': 3661},
};

http.Response _reply(Object body, {int status = 200}) => http.Response(jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});
Json _subjects() => {'items': [{'id': _child, 'nickname': '测试儿童',
  'ageBand': 'AGE_7_12', 'version': 0}], 'nextCursor': null};

class _Session extends EntrySession {
  _Session(super.handler) {
    tenant = {...tenant!, 'name': '测试家庭', 'timeZone': _zone};
  }
  int validations = 0;
  @override
  void login({bool stepUp = false}) { if (stepUp) validations++; }
}

class _Fixture {
  final requests = <http.Request>[];
  final visible = ValueNotifier<bool>(true);
  final updateQueryStatuses = <int>[];
  Json first = _plan(_first, _firstName);
  Json? created;
  bool unknownCreate = false, unknownUpdate = false, laterUpdate = false, closed = false;
  bool denyDetail = false, denyHistory = false;
  Completer<http.Response>? detailResponse, subjectResponse;
  late final session = _Session(handle);
  List<http.Request> get lists => requests.where((r) => r.method == 'GET' && r.url.path == _path).toList();
  List<http.Request> get commands => requests.where((r) =>
      r.method == 'PUT' || r.method == 'POST' && r.url.path == _path).toList();
  List<http.Request> get queries => requests.where((r) =>
      r.method == 'POST' && r.url.path.endsWith('/query')).toList();
  Json committed(http.Request request) {
    final body = jsonDecode(request.body) as Json;
    return request.method == 'POST'
        ? {..._plan(_created, body['name'] as String), ...body,
            'id': _created, 'version': 0, 'state': 'ACTIVE'}
        : {...first, ...body, 'version': 8, 'effectiveFrom': '2026-10-09'};
  }

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET') {
      if (path == '$_root/subjects') {
        expect(request.url.queryParameters['cursor'], isNull,
            reason: 'A retired directory must never continue its old cursor.');
        final waiting = subjectResponse;
        if (waiting != null) return waiting.future;
        return _reply(_subjects());
      }
      if (path == '$_root/applications') return _reply({'items': [], 'nextCursor': null});
      if (path == '$_path/calendar') {
        expect(request.url.queryParameters['subjectId'], _child);
        return _reply({'timeZone': _zone, 'currentDate': '2026-10-08'});
      }
      if (path == _path) {
        final cursor = request.url.queryParameters['cursor'];
        if (cursor != null) {
          expect(cursor, 'next');
          return _reply({'items': [_plan(_second, _secondName)], 'nextCursor': null});
        }
        return _reply({'items': [first, if (created != null) created!], 'nextCursor': 'next'});
      }
      if (path == '$_path/$_first') {
        if (denyDetail) return _reply({'errorCode': 'ACCESS_DENIED'}, status: 403);
        final waiting = detailResponse;
        if (waiting != null) return waiting.future;
        return _reply(first);
      }
      if (path == '$_path/$_first/revisions') {
        if (denyHistory) return _reply({'errorCode': 'ACCESS_DENIED'}, status: 403);
        return _reply({'items': [{
          'version': 7, 'effectiveFrom': first['effectiveFrom'], 'createdAt': _createdAt,
          'configuration': {for (final key in ['name', 'state', 'weeklyLimits', 'dateOverrides']) key: first[key]},
        }], 'nextCursor': null});
      }
    }
    if (request.method == 'POST' && path == _path ||
        request.method == 'PUT' && path == '$_path/$_first') {
      expect(request.headers['idempotency-key'], matches(
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(request.headers['if-match'], request.method == 'PUT' ? '"7"' : null);
      if (request.method == 'POST' ? unknownCreate : unknownUpdate) {
        return _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503);
      }
      final record = committed(request);
      if (request.method == 'POST') { created = record; } else { first = record; }
      return _reply(record, status: request.method == 'POST' ? 201 : 200);
    }
    if (request.method == 'POST' && path.endsWith('/query')) {
      final original = commands.firstWhere((r) => path == (r.method == 'POST'
          ? '$_path/creation-results/${r.headers['idempotency-key']}/query'
          : '$_path/$_first/update-results/${r.headers['idempotency-key']}/query'));
      expect(request.body, original.body);
      expect(request.headers['idempotency-key'], isNull);
      expect(request.headers['if-match'], original.headers['if-match']);
      final status = updateQueryStatuses.isEmpty ? 200 : updateQueryStatuses.removeAt(0);
      if (status != 200) return _reply({'errorCode': 'QUOTA_RESULT_UNAVAILABLE'}, status: status);
      final record = committed(original);
      final current = original.method == 'PUT' && laterUpdate
          ? <String, dynamic>{...record, 'version': 10, 'state': 'PAUSED',
              'name': '后来暂停的重复计划', 'effectiveFrom': '2026-10-11'} : record;
      if (original.method == 'POST') { created = current; } else { first = current; }
      return _reply({'requestId': original.headers['idempotency-key'],
        'operation': original.method == 'POST' ? 'PLAN_CREATE' : 'PLAN_UPDATE',
        'committed': record, 'current': current});
    }
    throw StateError('Unexpected quota boundary: ${request.method} $path');
  }

  Future<void> cleanup(WidgetTester tester) async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    if (detailResponse != null && !detailResponse!.isCompleted) detailResponse!.complete(_reply(first));
    if (subjectResponse != null && !subjectResponse!.isCompleted) subjectResponse!.complete(_reply(_subjects()));
    await _flush(tester);
    session.transport.close();
    session.dispose();
    visible.dispose();
  }
}

Finder _button(String text) => find.ancestor(of: find.text(text),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));
Finder _dialogButton(String text) => find.descendant(
    of: find.byType(AlertDialog).last, matching: _button(text));
bool _dialogActionReady(WidgetTester tester, String text) {
  if (find.byType(AlertDialog).evaluate().isEmpty) return false;
  final action = _dialogButton(text);
  return action.evaluate().length == 1 && tester.widget<ButtonStyleButton>(action).onPressed != null;
}
Finder get _search => find.descendant(of: find.byType(ResourcePage).first, matching: find.byType(TextField));
bool _listReady(WidgetTester tester) {
  final create = _button('创建重复计划');
  return find.byType(AlertDialog).evaluate().isEmpty && create.evaluate().length == 1 &&
      tester.widget<ButtonStyleButton>(create).onPressed != null;
}
bool _saveReady(WidgetTester tester) {
  final save = _button('保存计划');
  return find.byType(QuotaPlanEditor).evaluate().length == 1 && save.evaluate().length == 1 &&
      tester.widget<ButtonStyleButton>(save).onPressed != null;
}
bool _queryReady(WidgetTester tester) {
  final query = find.byKey(const Key('quota-plan-query-original'));
  return query.evaluate().length == 1 && tester.widget<ButtonStyleButton>(query).onPressed != null;
}
Future<void> _flush(WidgetTester tester) async {
  for (var turn = 0; turn < 6; turn++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
}
Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var turn = 0; turn < 32 && !ready(); turn++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue, reason: 'The quota plan journey must complete within its bounded wait.');
}
Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
}
Future<void> _mount(WidgetTester tester, _Fixture fixture) async {
  tester.view.physicalSize = const Size(1200, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => fixture.cleanup(tester));
  await tester.pumpWidget(MaterialApp(theme: consoleTheme(), home: Scaffold(
      body: ValueListenableBuilder<bool>(valueListenable: fixture.visible,
          builder: (_, visible, __) => visible
              ? SingleChildScrollView(child: QuotaPlansPage(session: fixture.session,
                  parentCurrent: () => fixture.visible.value, accessChanges: fixture.visible))
              : const Text('已离开计划页面')))));
  await _flush(tester);
  await _until(tester, () => _listReady(tester) && find.text(_firstName).evaluate().length == 1);
}
Future<void> _details(WidgetTester tester) async {
  await _tap(tester, find.text(_firstName));
  await _until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty &&
      _dialogButton('版本历史').evaluate().length == 1);
}

void main() {
  testWidgets('quota plan cancellations and read-only details and history preserve pages and search', (tester) async {
    final fixture = _Fixture();
    await _mount(tester, fixture);
    await _tap(tester, _button('加载更多'));
    await _until(tester, () => fixture.lists.length == 2 && _listReady(tester) &&
        find.text(_secondName).evaluate().length == 1);
    await tester.enterText(_search, '第一份');
    await tester.pump();
    await _tap(tester, _button('创建重复计划'));
    await _until(tester, () => _saveReady(tester));
    await _tap(tester, _dialogButton('取消'));
    await _until(tester, () => _listReady(tester));
    await _details(tester);
    await _tap(tester, _dialogButton('关闭'));
    await _until(tester, () => _listReady(tester));
    await _details(tester);
    await _tap(tester, _dialogButton('版本历史'));
    final historyTitle = find.text('计划版本历史');
    final historyResource = find.ancestor(of: historyTitle, matching: find.byType(ResourcePage));
    await _until(tester, () => historyTitle.evaluate().length == 1 &&
        find.descendant(of: historyResource, matching: find.text('2026-10-09')).evaluate().length == 1);
    final history = find.ancestor(of: find.text('计划版本历史'), matching: find.byType(Dialog)).last;
    await _tap(tester, find.descendant(of: history, matching: _button('关闭')));
    await _until(tester, () => historyTitle.evaluate().isEmpty && _dialogActionReady(tester, '关闭'));
    await _tap(tester, _dialogButton('关闭'));
    await _until(tester, () => _listReady(tester));
    expect(fixture.lists, hasLength(2));
    expect(fixture.commands, isEmpty);
    expect(fixture.queries, isEmpty);
    expect(tester.widget<TextField>(_search).controller!.text, '第一份');
    await tester.enterText(_search, '');
    await tester.pump();
    expect(find.text(_secondName), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('quota plan saves and original update recovery and unknown close each review the list once', (tester) async {
    final fixture = _Fixture();
    await _mount(tester, fixture);
    await _tap(tester, _button('创建重复计划'));
    await _until(tester, () => _saveReady(tester));
    await tester.enterText(find.widgetWithText(TextFormField, '计划名称'), '新建重复计划');
    await _tap(tester, _button('保存计划'));
    await _until(tester, () => fixture.lists.length == 2 && _listReady(tester));
    expect(fixture.commands, hasLength(1));
    expect(fixture.created!['id'], _created);
    fixture.unknownUpdate = true;
    fixture.laterUpdate = true;
    fixture.updateQueryStatuses.addAll([404, 200]);
    await _details(tester);
    await _tap(tester, _dialogButton('修改计划'));
    await _until(tester, () => _saveReady(tester));
    final name = find.widgetWithText(TextFormField, '计划名称');
    await tester.enterText(name, '原本提交的计划修改');
    await _tap(tester, _button('保存计划'));
    await _until(tester, () => fixture.commands.length == 2 && _queryReady(tester));
    final update = fixture.commands.last;
    expect(update.method, 'PUT');
    expect(update.headers['if-match'], '"7"');
    await _tap(tester, find.byKey(const Key('quota-plan-query-original')));
    await _until(tester, () => fixture.queries.length == 1 && _queryReady(tester));
    expect(tester.widget<TextFormField>(name).controller!.text, '原本提交的计划修改');
    expect(tester.widget<TextFormField>(name).enabled, isFalse);
    expect(fixture.commands, hasLength(2));
    expect(fixture.lists, hasLength(2));
    await _tap(tester, find.byKey(const Key('quota-plan-query-original')));
    await _until(tester, () => fixture.queries.length == 2 && fixture.lists.length == 3 && _listReady(tester));
    expect(fixture.commands, hasLength(2));
    expect(fixture.queries.every((r) => r.body == update.body &&
        r.headers['idempotency-key'] == null && r.headers['if-match'] == '"7"'), isTrue);
    expect(find.text('后来暂停的重复计划'), findsOneWidget);
    expect(find.text('原保存已核对，计划已有后续修改，请核对当前列表。'), findsOneWidget);
    fixture.unknownCreate = true;
    await _tap(tester, _button('创建重复计划'));
    await _until(tester, () => _saveReady(tester));
    await _tap(tester, _button('保存计划'));
    await _until(tester, () => fixture.commands.length == 3 && _queryReady(tester));
    await _tap(tester, find.byKey(const Key('quota-plan-close-unknown')));
    await tester.pump();
    await _tap(tester, find.byKey(const Key('quota-plan-confirm-close-unknown')));
    await _until(tester, () => fixture.lists.length == 4 && _listReady(tester));
    expect(fixture.commands, hasLength(3));
    expect(fixture.queries, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('quota plan resource retirement blocks late details and directories and retained editor actions', (tester) async {
    for (final stage in ['detail', 'directory', 'editor', 'denied', 'historyDenied']) {
      final fixture = _Fixture();
      await _mount(tester, fixture);
      if (stage == 'denied' || stage == 'historyDenied') {
        final heldCreate = tester.widget<ButtonStyleButton>(_button('创建重复计划')).onPressed!;
        if (stage == 'denied') {
          fixture.denyDetail = true;
          await _tap(tester, find.text(_firstName));
        } else {
          fixture.denyHistory = true;
          await _details(tester);
          await _tap(tester, _dialogButton('版本历史'));
        }
        await _until(tester, () => find.text('工作空间或权限已变化').evaluate().isNotEmpty &&
            find.text(_firstName).evaluate().isEmpty);
        final beforeStale = fixture.requests.length;
        heldCreate();
        await _flush(tester);
        expect(_button('创建重复计划'), findsNothing);
        expect(find.text(_firstName, skipOffstage: false), findsNothing);
        expect(fixture.requests, hasLength(beforeStale));
        expect(fixture.commands, isEmpty);
        expect(fixture.visible.value, isTrue);
        expect(fixture.session.role, 'OWNER');
        if (stage == 'historyDenied') {
          expect(fixture.requests.where((r) => r.url.path == '$_path/$_first/revisions'), hasLength(1));
        }
        for (var turn = 0; turn < 2 && find.byType(AlertDialog).evaluate().isNotEmpty; turn++) {
          await _tap(tester, _dialogButton('关闭'));
          await _flush(tester);
        }
        expect(tester.takeException(), isNull);
        await fixture.cleanup(tester);
        continue;
      }
      VoidCallback? heldSave, heldValidation;
      if (stage == 'detail') {
        fixture.detailResponse = Completer<http.Response>();
        await _tap(tester, find.text(_firstName));
        await _until(tester, () => fixture.requests.any((r) => r.url.path == '$_path/$_first'));
      } else {
        if (stage == 'directory') fixture.subjectResponse = Completer<http.Response>();
        final subjectReads = fixture.requests.where((r) => r.url.path == '$_root/subjects').length;
        await _tap(tester, _button('创建重复计划'));
        if (stage == 'directory') {
          await _until(tester, () => fixture.requests.where((r) => r.url.path == '$_root/subjects').length > subjectReads);
        } else {
          await _until(tester, () => _saveReady(tester));
          heldSave = tester.widget<ButtonStyleButton>(_button('保存计划')).onPressed!;
          heldValidation = tester.widget<QuotaPlanEditor>(find.byType(QuotaPlanEditor)).reauth!;
        }
      }
      fixture.visible.value = false;
      await _until(tester, () => find.text('已离开计划页面').evaluate().length == 1);
      fixture.detailResponse?.complete(_reply(fixture.first));
      fixture.subjectResponse?.complete(_reply({..._subjects(), 'nextCursor': 'forbidden-next'}));
      await _flush(tester);
      final beforeStale = fixture.requests.length;
      heldSave?.call();
      heldValidation?.call();
      await _flush(tester);
      expect(fixture.requests, hasLength(beforeStale));
      expect(fixture.commands, isEmpty);
      expect(fixture.queries, isEmpty);
      expect(fixture.lists, hasLength(1));
      expect(find.byType(TextFormField), findsNothing);
      if (stage != 'editor') expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(_firstName, skipOffstage: false), findsNothing);
      expect(fixture.requests.where((r) => r.url.queryParameters['cursor'] == 'forbidden-next'), isEmpty);
      expect(fixture.session.validations, 0);
      expect(fixture.session.role, 'OWNER');
      expect(fixture.session.scopeGeneration, 0);
      if (stage == 'editor' && find.byType(AlertDialog).evaluate().isNotEmpty) {
        await _tap(tester, _dialogButton('关闭'));
        await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
      }
      expect(tester.takeException(), isNull);
      await fixture.cleanup(tester);
    }
  });
}
