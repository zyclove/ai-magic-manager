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
const _archived = 'a4444444-4444-4444-8444-444444444444';
const _archivedName = '已归档的测试档案';
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
      'version': 7, 'state': 'ACTIVE'},
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

Json _archivedRecord() => {..._record('subjects'), 'id': _archived,
  'nickname': _archivedName, 'state': 'ARCHIVED', 'version': 8};

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
  final archiveQueryStatuses = <int>[];
  final subjectQueryStatuses = <int>[];
  final applicationQueryStatuses = <int>[];
  Completer<http.Response>? subjectDetailsResponse;
  Json Function(Json)? subjectQueryCurrent;
  Json? _changedSubject;
  bool unknownSubjectEdit = false, unknownArchive = false, closed = false;
  bool subjectArchived = false;
  late final session = _ConsoleSession(handle);

  Json get subject => _changedSubject ?? {..._record('subjects'),
    if (subjectArchived) ...{'state': 'ARCHIVED', 'version': 8}};

  Json _subjectReceipt(Json body) => switch (body['operation']) {
    'CREATE' => {'id': _created, 'nickname': body['nickname'],
      'ageBand': body['ageBand'], 'version': 0, 'state': 'ACTIVE'},
    'UPDATE' => {'id': body['subjectId'], 'nickname': body['nickname'],
      'ageBand': body['ageBand'], 'version': (body['version'] as int) + 1, 'state': 'ACTIVE'},
    'ARCHIVE' => {...subject, 'id': body['subjectId'],
      'version': (body['version'] as int) + 1, 'state': 'ARCHIVED'},
    _ => throw StateError('Unexpected synthetic subject operation.'),
  };

  void _applySubjectCurrent(Json value) {
    if (value['id'] == _first) {
      _changedSubject = Map<String, dynamic>.from(value);
      subjectArchived = value['state'] == 'ARCHIVED';
    } else {
      expect(value['id'], _created);
      created['subjects'] = Map<String, dynamic>.from(value);
    }
  }

  List<http.Request> listReads(String section) => requests.where((request) =>
      request.method == 'GET' && (request.url.path == '$_root/$section' ||
          section == 'subjects' && request.url.path == '$_root/subjects/management')).toList();
  List<http.Request> get writes =>
      requests.where((request) => request.method != 'GET').toList();

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET') {
      final subjectSuffix = session.canWrite ? '/management' : '';
      if (path == '$_root/subjects/$_first$subjectSuffix') {
        if (subjectDetailsResponse case final pending?) return pending.future;
        if (subjectArchived && !session.canWrite) {
          return _reply({'errorCode': 'ACCESS_DENIED'}, status: 403);
        }
        final currentSubject = Map<String, dynamic>.from(subject);
        if (!session.canWrite) currentSubject.remove('state');
        return _reply(currentSubject);
      }
      if (session.canWrite && path == '$_root/subjects/$_archived/management') {
        return _reply(_archivedRecord());
      }
      if (path == '$_root/subjects/$_created$subjectSuffix' && created['subjects'] != null) {
        final currentSubject = Map<String, dynamic>.from(created['subjects']!);
        if (!session.canWrite) {
          if (currentSubject['state'] == 'ARCHIVED') {
            return _reply({'errorCode': 'ACCESS_DENIED'}, status: 403);
          }
          currentSubject.remove('state');
        }
        return _reply(currentSubject);
      }
      if (path == '$_root/schedule-presets') {
        return _reply({'schemaVersion': 1, 'items': <Json>[]});
      }
      for (final section in _createLabels.keys) {
        final listPath = section == 'subjects'
            ? '$_root/subjects$subjectSuffix' : '$_root/$section';
        if (path == listPath) {
          final next = request.url.queryParameters['cursor'];
          if (next != null) {
            expect(next, 'next');
            return _reply({'items': [_record(section, second: true)], 'nextCursor': null});
          }
          final includeArchived = section == 'subjects' && session.canWrite &&
              request.url.queryParameters['includeArchived'] == 'true';
          return _reply({'items': [
            if (section != 'subjects') _record(section)
            else if (!subjectArchived || includeArchived) subject,
            if (created[section] != null && (section != 'subjects' ||
                includeArchived || created[section]!['state'] != 'ARCHIVED')) created[section]!,
            if (includeArchived) _archivedRecord()],
            'nextCursor': 'next'});
        }
      }
    }
    if (request.method == 'POST' && path == '$_root/applications') {
      expect(request.headers['idempotency-key'], matches(
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      if (unknownCreates.contains('applications')) {
        return _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503);
      }
      final record = <String, dynamic>{..._record('applications'),
        ...(jsonDecode(request.body) as Json), 'id': _created,
        'evidenceStatus': 'ADMIN_DECLARED'};
      created['applications'] = record;
      return _reply(record, status: 201);
    }
    if (request.method == 'POST' &&
        path.startsWith('$_root/applications/creation-results/') && path.endsWith('/query')) {
      final original = requests.firstWhere((sent) =>
          sent.method == 'POST' && sent.url.path == '$_root/applications');
      expect(path, '$_root/applications/creation-results/${original.headers['idempotency-key']}/query');
      expect(request.body, original.body);
      expect(request.headers['idempotency-key'], isNull);
      final status = applicationQueryStatuses.isEmpty ? 200 : applicationQueryStatuses.removeAt(0);
      if (status != 200) {
        return _reply({'errorCode': 'APPLICATION_CREATION_RESULT_UNAVAILABLE'}, status: status);
      }
      final record = <String, dynamic>{..._record('applications'),
        ...(jsonDecode(original.body) as Json), 'id': _created, 'evidenceStatus': 'ADMIN_DECLARED'};
      created['applications'] = record;
      return _reply(record);
    }
    if (request.method == 'POST' && path == '$_root/subjects/changes') {
      final body = jsonDecode(request.body) as Json;
      final operation = body['operation'];
      expect(operation, isIn(['CREATE', 'UPDATE', 'ARCHIVE']));
      if (operation == 'CREATE') {
        expect(body.keys, unorderedEquals(['operation', 'nickname', 'ageBand']));
      } else if (operation == 'UPDATE') {
        expect(body.keys, unorderedEquals(['operation', 'subjectId', 'version', 'nickname', 'ageBand']));
        expect(body['subjectId'], _first);
        expect(body['version'], 7);
      } else {
        expect(body, {'operation': 'ARCHIVE', 'subjectId': _first, 'version': 7});
      }
      expect(request.headers['if-match'], isNull);
      expect(request.headers['idempotency-key'], matches(
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      if (operation == 'CREATE' && unknownCreates.contains('subjects') ||
          operation == 'UPDATE' && unknownSubjectEdit || operation == 'ARCHIVE' && unknownArchive) {
        return _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503);
      }
      _applySubjectCurrent(_subjectReceipt(body));
      return _reply(operation == 'CREATE' ? created['subjects']! : subject);
    }
    if (request.method == 'POST' &&
        path.startsWith('$_root/subjects/operation-results/') && path.endsWith('/query')) {
      final original = requests.firstWhere((sent) =>
          sent.method == 'POST' && sent.url.path == '$_root/subjects/changes' &&
          path == '$_root/subjects/operation-results/${sent.headers['idempotency-key']}/query');
      expect(path, '$_root/subjects/operation-results/${original.headers['idempotency-key']}/query');
      expect(request.body, original.body);
      expect(request.headers['idempotency-key'], isNull);
      final body = jsonDecode(original.body) as Json;
      final operation = body['operation'];
      final statuses = operation == 'ARCHIVE' ? archiveQueryStatuses : subjectQueryStatuses;
      final status = statuses.isEmpty ? 200 : statuses.removeAt(0);
      if (status != 200) {
        return _reply({'errorCode': status == 404
            ? 'SUBJECT_RESULT_UNAVAILABLE' : 'ACCESS_DENIED'}, status: status);
      }
      final committed = _subjectReceipt(body);
      final current = subjectQueryCurrent?.call(committed) ?? committed;
      _applySubjectCurrent(current);
      return _reply({'operation': operation, 'committed': committed, 'current': current});
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

Future<void> _mount(WidgetTester tester, _Fixture fixture, String section,
    {bool settle = true}) async {
  await tester.pumpWidget(ChangeNotifierProvider<Session>.value(
      value: fixture.session,
      child: MaterialApp(theme: consoleTheme(), home: Scaffold(
          body: SingleChildScrollView(child: ConsolePages(section: section))))));
  if (settle) await settleReads(tester);
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
        final creationPath = section == 'subjects' ? '$_root/subjects/changes' : '$_root/applications';
        expect(fixture.writes.every((request) => request.method == 'POST' &&
            request.url.path == creationPath &&
            request.headers['idempotency-key']?.isNotEmpty == true), isTrue);
        if (section == 'subjects') {
          expect(fixture.writes.every((request) =>
              (jsonDecode(request.body) as Json)['operation'] == 'CREATE' &&
              request.headers['if-match'] == null), isTrue);
        }
        expect(fixture.writes[0].headers['idempotency-key'],
            isNot(fixture.writes[1].headers['idempotency-key']));
      }
      expect(tester.takeException(), isNull);
      await fixture.cleanup(tester);
    }
  });

  testWidgets('application registration validates locally and recovers a normalized original request without replay',
      (tester) async {
    _wide(tester);
    final fixture = _Fixture();
    fixture.unknownCreates.add('applications');
    fixture.applicationQueryStatuses.addAll([404, 200]);
    addTearDown(() => fixture.cleanup(tester));
    const name = '专注学习';
    const packageName = 'com.Example.FocusApp';
    final colonDigest = List<String>.filled(32, 'AB').join(':');
    final plainUpperDigest = List<String>.filled(32, 'AB').join();
    final canonicalDigest = List<String>.filled(32, 'ab').join();
    final packageField = find.widgetWithText(TextFormField, 'Android 包名');
    final digestField = find.widgetWithText(TextFormField, '签名摘要');
    List<http.Request> creations() => fixture.requests.where((request) =>
        request.method == 'POST' && request.url.path == '$_root/applications').toList();
    List<http.Request> queries() => fixture.requests.where((request) =>
        request.method == 'POST' &&
        request.url.path.startsWith('$_root/applications/creation-results/')).toList();
    bool queryReady() {
      if (find.byType(AlertDialog).evaluate().isEmpty) return false;
      final query = _dialogButton('查询登记结果');
      return query.evaluate().length == 1 &&
          tester.widget<ButtonStyleButton>(query).onPressed != null;
    }

    await _mount(tester, fixture, 'applications');
    await _until(tester, () => _listReady(tester, 'applications'));
    await _tap(tester, _button('登记应用'));
    await _until(tester, () => find.byType(EditDialog).evaluate().length == 1);
    await tester.enterText(find.widgetWithText(TextFormField, '应用名称'), name);
    await tester.enterText(packageField, 'invalid package name');
    await _tap(tester, _dialogButton('保存'));
    await tester.pump();
    expect(tester.state<FormFieldState<String>>(packageField).errorText, isNotEmpty);
    expect(tester.widget<TextFormField>(packageField).enabled, isTrue);
    expect(fixture.writes, isEmpty);

    await tester.enterText(packageField, packageName);
    await tester.enterText(digestField, '$colonDigest\n$plainUpperDigest');
    await _tap(tester, _dialogButton('保存'));
    await tester.pump();
    expect(tester.state<FormFieldState<String>>(digestField).errorText, isNotEmpty);
    expect(tester.widget<TextFormField>(digestField).enabled, isTrue);
    expect(fixture.writes, isEmpty, reason: 'Equivalent colon and plain digests must be rejected before HTTP.');

    await tester.enterText(digestField, colonDigest);
    await _tap(tester, _dialogButton('保存'));
    await _until(tester, () => creations().length == 1 && queryReady());
    final original = creations().single;
    expect(jsonDecode(original.body), {
      'displayName': name, 'packageName': packageName, 'platform': 'ANDROID',
      'profile': 'PRIMARY', 'signingDigests': [canonicalDigest],
    });
    expect(tester.widget<TextFormField>(packageField).enabled, isFalse);
    expect(tester.widget<TextFormField>(digestField).enabled, isFalse);
    expect(_dialogButton('保存'), findsNothing);
    expect(fixture.listReads('applications'), hasLength(1));
    await _tap(tester, _dialogButton('查询登记结果'));
    await _until(tester, () => queries().length == 1 && queryReady());
    expect(creations(), hasLength(1));
    expect(tester.widget<TextFormField>(packageField).controller!.text, packageName);
    expect(tester.widget<TextFormField>(digestField).controller!.text, colonDigest);
    expect(tester.widget<TextFormField>(packageField).enabled, isFalse);
    expect(tester.widget<TextFormField>(digestField).enabled, isFalse);
    expect(_dialogButton('保存'), findsNothing);
    expect(fixture.listReads('applications'), hasLength(1));

    await _tap(tester, _dialogButton('查询登记结果'));
    await _until(tester, () => queries().length == 2 &&
        fixture.listReads('applications').length == 2 && _listReady(tester, 'applications'));
    expect(creations(), hasLength(1));
    expect(queries().every((request) => request.body == original.body &&
        request.headers['idempotency-key'] == null &&
        request.url.path == '$_root/applications/creation-results/${original.headers['idempotency-key']}/query'), isTrue);
    expect(fixture.writes, hasLength(3));
    expect(find.text(name), findsOneWidget);
    expect(find.text(packageName), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('subject creation and editing recover their frozen receipts while showing later current facts',
      (tester) async {
    _wide(tester);
    for (final operation in ['CREATE', 'UPDATE']) {
      final creating = operation == 'CREATE';
      final fixture = _Fixture();
      if (creating) {
        fixture.unknownCreates.add('subjects');
      } else {
        fixture.unknownSubjectEdit = true;
      }
      fixture.subjectQueryStatuses.addAll([404, 200]);
      final laterName = creating ? '后续归档的创建档案' : '后来重新编辑的儿童档案';
      fixture.subjectQueryCurrent = (committed) => {...committed,
        'nickname': laterName, 'ageBand': 'UNDER_7',
        'version': (committed['version'] as int) + 2,
        'state': creating ? 'ARCHIVED' : 'ACTIVE'};
      addTearDown(() => fixture.cleanup(tester));
      List<http.Request> changes() => fixture.requests.where((request) =>
          request.method == 'POST' && request.url.path == '$_root/subjects/changes').toList();
      List<http.Request> queries() => fixture.requests.where((request) =>
          request.method == 'POST' &&
          request.url.path.startsWith('$_root/subjects/operation-results/')).toList();
      bool queryReady() {
        if (find.byType(AlertDialog).evaluate().isEmpty) return false;
        final query = _dialogButton('查询档案结果');
        return query.evaluate().length == 1 &&
            tester.widget<ButtonStyleButton>(query).onPressed != null;
      }

      await _mount(tester, fixture, 'subjects');
      await _until(tester, () => _listReady(tester, 'subjects'));
      if (creating) {
        await _tap(tester, _button('添加儿童'));
        await _until(tester, () => find.byType(EditDialog).evaluate().length == 1);
        await _fillCreation(tester, 'subjects', '');
        await _tap(tester, _dialogButton('保存'));
        await tester.pump();
        final nickname = find.widgetWithText(TextFormField, '昵称');
        expect(tester.state<FormFieldState<String>>(nickname).errorText, isNotEmpty);
        await tester.enterText(nickname, List<String>.filled(31, '😀').join());
        await _tap(tester, _dialogButton('保存'));
        await tester.pump();
        expect(tester.state<FormFieldState<String>>(nickname).errorText, isNotEmpty);
        expect(tester.widget<TextFormField>(nickname).enabled, isTrue);
        expect(fixture.writes, isEmpty,
            reason: 'Empty or more than 60 UTF-16 code units must fail before HTTP.');
      } else {
        await _tap(tester, find.text(_name('subjects')));
        await _until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty &&
            _dialogButton('编辑档案').evaluate().length == 1);
        await _tap(tester, _dialogButton('编辑档案'));
        await _until(tester, () => find.byType(EditDialog).evaluate().length == 1);
      }
      final nickname = find.widgetWithText(TextFormField, '昵称');
      final submittedName = creating ? '待核对的新档案' : '待核对的档案编辑';
      await tester.enterText(nickname, submittedName);
      await _tap(tester, find.widgetWithText(DropdownButtonFormField<String>, '年龄段'));
      await tester.pumpAndSettle();
      await _tap(tester, find.text(label('AGE_13_17')).last);
      await tester.pumpAndSettle();
      await _tap(tester, _dialogButton('保存'));
      await _until(tester, () => changes().length == 1 && queryReady());
      final original = changes().single;
      expect(jsonDecode(original.body), {
        'operation': operation,
        if (!creating) ...{'subjectId': _first, 'version': 7},
        'nickname': submittedName, 'ageBand': 'AGE_13_17',
      });
      expect(tester.widget<TextFormField>(nickname).enabled, isFalse);
      expect(fixture.listReads('subjects'), hasLength(1));
      await _tap(tester, _dialogButton('查询档案结果'));
      await _until(tester, () => queries().length == 1 && queryReady());
      expect(tester.widget<TextFormField>(nickname).controller!.text, submittedName);
      expect(tester.widget<TextFormField>(nickname).enabled, isFalse);
      expect(_dialogButton('保存'), findsNothing);
      expect(changes(), hasLength(1));
      expect(fixture.listReads('subjects'), hasLength(1));

      await _tap(tester, _dialogButton('查询档案结果'));
      await _until(tester, () => queries().length == 2 &&
          fixture.listReads('subjects').length == 2 && _listReady(tester, 'subjects'));
      expect(changes(), hasLength(1));
      expect(queries().every((request) => request.body == original.body &&
          request.headers['idempotency-key'] == null &&
          request.url.path == '$_root/subjects/operation-results/${original.headers['idempotency-key']}/query'), isTrue);
      expect(fixture.writes, hasLength(3));
      expect(find.text(submittedName), findsNothing);
      expect(find.textContaining(creating
          ? '原操作已核对，档案现已归档' : '原操作已核对，档案已有后续更新'), findsOneWidget);
      if (creating) {
        expect(find.text(laterName), findsNothing);
        expect(fixture.created['subjects']?['id'], _created);
        expect(fixture.created['subjects']?['state'], 'ARCHIVED');
      } else {
        expect(find.text(laterName), findsOneWidget);
        expect(fixture.subject['id'], _first);
        expect(fixture.subject['version'], 10);
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
    expect(find.descendant(of: _dialog, matching: find.text(_name('subjects'))), findsOneWidget);
    expect(find.descendant(of: _dialog, matching: find.text('档案编号：$_first')), findsOneWidget);
    expect(find.descendant(of: _dialog, matching: find.text('年龄段：${label('AGE_7_12')}')), findsOneWidget);
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
    expect(edit.method, 'POST');
    expect(edit.url.path, '$_root/subjects/changes');
    expect(edit.headers['if-match'], isNull);
    expect(edit.headers['idempotency-key'], isNotEmpty);
    expect(jsonDecode(edit.body), {'operation': 'UPDATE', 'subjectId': _first,
      'version': 7, 'nickname': '待核对的编辑昵称', 'ageBand': 'AGE_7_12'});

    await details();
    await _tap(tester, _dialogButton('归档'));
    await _until(tester, () => find.text('归档儿童档案').evaluate().length == 1);
    await _tap(tester, _dialogButton('确认归档'));
    await _until(tester, () => fixture.writes.length == 2 &&
        _dialogButton('暂时关闭').evaluate().length == 1 &&
        tester.widget<ButtonStyleButton>(_dialogButton('暂时关闭')).onPressed != null);
    expect(fixture.listReads('subjects'), hasLength(3));
    final archive = fixture.writes.last;
    expect(archive.method, 'POST');
    expect(archive.url.path, '$_root/subjects/changes');
    expect(archive.headers['if-match'], isNull);
    expect(archive.headers['idempotency-key'], isNotEmpty);
    expect(jsonDecode(archive.body), {'operation': 'ARCHIVE', 'subjectId': _first, 'version': 7});
    expect(_dialogButton('确认归档'), findsNothing);
    expect(_dialogButton('查询归档结果'), findsOneWidget);
    await _tap(tester, _dialogButton('暂时关闭'));
    await tester.pump();
    expect(_dialogButton('继续核对'), findsOneWidget);
    final oldConfirmClose = tester.widget<ButtonStyleButton>(
        _dialogButton('关闭并核对列表')).onPressed!;
    await _tap(tester, _dialogButton('继续核对'));
    await _until(tester, () {
      if (find.byType(AlertDialog).evaluate().isEmpty) return false;
      final query = _dialogButton('查询归档结果');
      return query.evaluate().length == 1 &&
          tester.widget<ButtonStyleButton>(query).onPressed != null;
    });
    oldConfirmClose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.text('归档儿童档案'), findsOneWidget);
    expect(find.byKey(const Key('subject-archive-unknown-close-notice')), findsNothing);
    expect(_dialogButton('查询归档结果'), findsOneWidget);
    expect(fixture.listReads('subjects'), hasLength(3));
    expect(fixture.requests.where((request) =>
        request.method == 'POST' && request.url.path == '$_root/subjects/changes' &&
        (jsonDecode(request.body) as Json)['operation'] == 'ARCHIVE'), hasLength(1));
    expect(fixture.writes, hasLength(2));
    await _tap(tester, _dialogButton('暂时关闭'));
    await tester.pump();
    await _tap(tester, _dialogButton('关闭并核对列表'));
    await _until(tester, () => fixture.listReads('subjects').length == 4 &&
        _listReady(tester, 'subjects'));
    expect(fixture.listReads('subjects'), hasLength(4));
    expect(fixture.writes, hasLength(2));
    expect(fixture.requests.every((request) => request.method == 'GET' ||
        identical(request, edit) || identical(request, archive)), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unknown archive queries its original result without resubmitting and reviews the current state',
      (tester) async {
    _wide(tester);
    final fixture = _Fixture()..unknownArchive = true;
    fixture.archiveQueryStatuses.addAll([404, 200]);
    addTearDown(() => fixture.cleanup(tester));
    List<http.Request> changes() => fixture.requests.where((request) =>
        request.method == 'POST' && request.url.path == '$_root/subjects/changes').toList();
    List<http.Request> queries() => fixture.requests.where((request) =>
        request.method == 'POST' &&
        request.url.path.startsWith('$_root/subjects/operation-results/')).toList();
    bool queryReady() {
      if (find.byType(AlertDialog).evaluate().isEmpty) return false;
      final query = _dialogButton('查询归档结果');
      return query.evaluate().length == 1 &&
          tester.widget<ButtonStyleButton>(query).onPressed != null;
    }

    await _mount(tester, fixture, 'subjects');
    await _until(tester, () => _listReady(tester, 'subjects'));
    await _tap(tester, find.text(_name('subjects')));
    await _until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty &&
        _dialogButton('归档').evaluate().length == 1);
    await _tap(tester, _dialogButton('归档'));
    await _until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty &&
        _dialogButton('确认归档').evaluate().length == 1);
    await _tap(tester, _dialogButton('确认归档'));
    await _until(tester, () => changes().length == 1 && queryReady());
    final original = changes().single;
    expect(jsonDecode(original.body), {'operation': 'ARCHIVE', 'subjectId': _first, 'version': 7});
    expect(_dialogButton('确认归档'), findsNothing);
    expect(fixture.listReads('subjects'), hasLength(1));
    await _tap(tester, _dialogButton('查询归档结果'));
    await _until(tester, () => queries().length == 1 && queryReady());
    expect(_dialogButton('确认归档'), findsNothing,
        reason: 'A missing result does not prove that the original archive failed.');
    expect(_dialogButton('暂时关闭'), findsOneWidget);
    expect(changes(), hasLength(1));
    expect(fixture.subjectArchived, isFalse);
    expect(fixture.listReads('subjects'), hasLength(1));

    await _tap(tester, _dialogButton('查询归档结果'));
    await _until(tester, () => queries().length == 2 &&
        fixture.listReads('subjects').length == 2 && _listReady(tester, 'subjects'));
    expect(changes(), hasLength(1), reason: 'Recovery must never repeat the archive command.');
    expect(queries().every((request) => request.body == original.body &&
        request.headers['idempotency-key'] == null &&
        request.url.path == '$_root/subjects/operation-results/${original.headers['idempotency-key']}/query'), isTrue);
    expect(fixture.subjectArchived, isTrue);
    expect(find.text(_name('subjects')), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);

    final filter = find.widgetWithText(FilterChip, '包含已归档');
    await _tap(tester, filter);
    await _until(tester, () => fixture.listReads('subjects').length == 3 &&
        _listReady(tester, 'subjects') && find.text(_name('subjects')).evaluate().length == 1);
    await _tap(tester, find.text(_name('subjects')));
    await _until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty &&
        _dialogButton('关闭').evaluate().length == 1);
    expect(find.descendant(of: _dialog, matching: find.text('已归档')), findsOneWidget);
    expect(find.descendant(of: _dialog, matching: find.text('8')), findsOneWidget);
    expect(_dialogButton('编辑档案'), findsNothing);
    expect(_dialogButton('归档'), findsNothing);
    await _tap(tester, _dialogButton('关闭'));
    await _until(tester, () => _listReady(tester, 'subjects'));
    expect(fixture.listReads('subjects'), hasLength(3));
    expect(changes(), hasLength(1));
    expect(queries(), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('archived subject review is read only and retired views cannot reopen management',
      (tester) async {
    _wide(tester);
    final fixture = _Fixture();
    addTearDown(() => fixture.cleanup(tester));
    await _mount(tester, fixture, 'subjects');
    await _until(tester, () => _listReady(tester, 'subjects'));
    expect(fixture.listReads('subjects'), hasLength(1));
    expect(fixture.listReads('subjects').single.url.path, '$_root/subjects/management');
    expect(fixture.listReads('subjects').single.url.queryParameters['includeArchived'], isNot('true'));
    expect(find.text(_archivedName), findsNothing);

    final filter = find.widgetWithText(FilterChip, '包含已归档');
    final oldFilter = tester.widget<FilterChip>(filter).onSelected!;
    final oldOpen = tester.widget<ResourcePage>(find.byType(ResourcePage)).onOpenChanged!;
    Future<bool> openWithIndependentLease(Json row) async {
      final lease = ResourceActionLease(isCurrent: () => true);
      try {
        return await oldOpen(row, lease);
      } finally {
        lease.dispose();
      }
    }
    await _tap(tester, filter);
    await _until(tester, () => fixture.listReads('subjects').length == 2 &&
        _listReady(tester, 'subjects') && find.text(_archivedName).evaluate().length == 1);
    expect(fixture.listReads('subjects').last.url.queryParameters['includeArchived'], 'true');
    expect(tester.widget<FilterChip>(filter).selected, isTrue);
    expect(find.text('已归档'), findsOneWidget);
    await _tap(tester, find.text(_archivedName));
    await _until(tester, () => find.byType(AlertDialog).evaluate().length == 1 &&
        _dialogButton('关闭').evaluate().length == 1);
    expect(find.descendant(of: _dialog, matching: find.text('已归档')), findsOneWidget);
    expect(find.descendant(of: _dialog, matching: find.text(_archived)), findsOneWidget);
    expect(_dialogButton('编辑档案'), findsNothing);
    expect(_dialogButton('归档'), findsNothing);
    expect(fixture.requests.where((request) =>
        request.url.path == '$_root/subjects/$_archived/management'), hasLength(1));
    await _tap(tester, _dialogButton('关闭'));
    await _until(tester, () => _listReady(tester, 'subjects'));
    expect(fixture.listReads('subjects'), hasLength(2));
    expect(tester.widget<FilterChip>(filter).selected, isTrue);
    expect(fixture.writes, isEmpty);

    await _tap(tester, filter);
    await _until(tester, () => fixture.listReads('subjects').length == 3 &&
        _listReady(tester, 'subjects'));
    expect(tester.widget<FilterChip>(filter).selected, isFalse);
    expect(fixture.listReads('subjects').last.url.queryParameters['includeArchived'], isNot('true'));
    expect(find.text(_archivedName), findsNothing);
    final beforeStale = fixture.requests.length;
    oldFilter(true);
    expect(await openWithIndependentLease(_archivedRecord()), isFalse);
    await tester.pump();
    expect(fixture.requests, hasLength(beforeStale),
        reason: 'Returning to the same filter value must not revive an older view.');
    expect(find.byType(AlertDialog), findsNothing);

    fixture.session.role = 'TEACHER';
    fixture.session.changed();
    await _until(tester, () => fixture.listReads('subjects').length == 4 &&
        find.text(_name('subjects')).evaluate().length == 1 &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty);
    expect(fixture.listReads('subjects').last.url.path, '$_root/subjects');
    expect(filter, findsNothing);
    expect(_button('添加儿童'), findsNothing);
    final beforeRoleStale = fixture.requests.length;
    oldFilter(true);
    expect(await openWithIndependentLease(_archivedRecord()), isFalse);
    await tester.pump();
    expect(fixture.requests, hasLength(beforeRoleStale));
    await _tap(tester, find.text(_name('subjects')));
    await _until(tester, () => find.byType(AlertDialog).evaluate().length == 1 &&
        _dialogButton('关闭').evaluate().length == 1);
    expect(fixture.requests.last.url.path, '$_root/subjects/$_first');
    expect(_dialogButton('编辑档案'), findsNothing);
    expect(_dialogButton('归档'), findsNothing);
    await _tap(tester, _dialogButton('关闭'));
    await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty);
    expect(fixture.listReads('subjects'), hasLength(4));
    expect(fixture.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a delayed subject response cannot open details after the console changes section',
      (tester) async {
    _wide(tester);
    final fixture = _Fixture();
    final pending = Completer<http.Response>();
    fixture.subjectDetailsResponse = pending;
    addTearDown(() async {
      if (!pending.isCompleted) pending.complete(_reply(_record('subjects')));
      await fixture.cleanup(tester);
    });
    await _mount(tester, fixture, 'subjects');
    await _until(tester, () => _listReady(tester, 'subjects'));
    final app = tester.element(find.byType(MaterialApp));
    final provider = tester.element(find.byType(ChangeNotifierProvider<Session>));
    final console = tester.element(find.byType(ConsolePages));
    await _tap(tester, find.text(_name('subjects')));
    await _until(tester, () => fixture.requests.where((request) =>
        request.url.path == '$_root/subjects/$_first/management').length == 1);
    expect(pending.isCompleted, isFalse);
    expect(find.byType(AlertDialog), findsNothing);

    await _mount(tester, fixture, 'applications', settle: false);
    expect(tester.element(find.byType(MaterialApp)), same(app));
    expect(tester.element(find.byType(ChangeNotifierProvider<Session>)), same(provider));
    expect(tester.element(find.byType(ConsolePages)), same(console),
        reason: 'The host context stays mounted while its subjects child retires.');
    await _until(tester, () => fixture.listReads('applications').length == 1 &&
        _listReady(tester, 'applications'));
    pending.complete(_reply(_record('subjects')));
    // Drain the streamed response and its UI continuations without settling
    // indefinitely on any pending loading animation.
    for (var frame = 0; frame < 6; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(_name('subjects')), findsNothing);
    expect(find.text(_name('applications')), findsOneWidget);
    expect(fixture.listReads('applications'), hasLength(1));
    expect(fixture.listReads('subjects'), hasLength(1));
    expect(fixture.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing section hides an unknown application form and retires its captured commands',
      (tester) async {
    _wide(tester);
    final fixture = _Fixture();
    fixture.unknownCreates.add('applications');
    addTearDown(() => fixture.cleanup(tester));
    await _mount(tester, fixture, 'applications');
    await _until(tester, () => _listReady(tester, 'applications'));
    final app = tester.element(find.byType(MaterialApp));
    final provider = tester.element(find.byType(ChangeNotifierProvider<Session>));
    final console = tester.element(find.byType(ConsolePages));
    await _tap(tester, _button('登记应用'));
    await _until(tester, () => find.byType(EditDialog).evaluate().length == 1);
    await _fillCreation(tester, 'applications', '旧页面中的待核对应用');
    final oldSave = tester.widget<ButtonStyleButton>(_dialogButton('保存')).onPressed!;
    await _tap(tester, _dialogButton('保存'));
    await _until(tester, () {
      if (find.byType(AlertDialog).evaluate().isEmpty) return false;
      final query = _dialogButton('查询登记结果');
      return fixture.writes.length == 1 && query.evaluate().length == 1 &&
          tester.widget<ButtonStyleButton>(query).onPressed != null;
    });
    final oldQuery = tester.widget<ButtonStyleButton>(
        _dialogButton('查询登记结果')).onPressed!;

    await _mount(tester, fixture, 'subjects', settle: false);
    expect(tester.element(find.byType(MaterialApp)), same(app));
    expect(tester.element(find.byType(ChangeNotifierProvider<Session>)), same(provider));
    expect(tester.element(find.byType(ConsolePages)), same(console),
        reason: 'Changing the resource must retire its operation while the host context stays mounted.');
    await _until(tester, () => fixture.listReads('subjects').length == 1 &&
        find.text(_name('subjects')).evaluate().length == 1 &&
        find.byType(TextFormField).evaluate().isEmpty);
    expect(find.text('旧页面中的待核对应用'), findsNothing);
    final beforeStale = fixture.requests.length;
    oldSave();
    oldQuery();
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 400));
    expect(fixture.requests, hasLength(beforeStale));
    expect(fixture.writes, hasLength(1));
    expect(fixture.writes.single.url.path, '$_root/applications');
    expect(fixture.listReads('subjects'), hasLength(1));
    expect(fixture.listReads('applications'), hasLength(1));
    expect(find.text('旧页面中的待核对应用'), findsNothing);
    await fixture.cleanup(tester);
    expect(tester.takeException(), isNull);
  });
}
