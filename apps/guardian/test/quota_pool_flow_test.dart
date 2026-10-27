@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/pages/quota_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/resource_page.dart';
import 'package:http/http.dart' as http;

import 'device_management_entry_test.dart' show EntrySession, tenantId;

const _root = '/api/v1/tenants/$tenantId';
const _path = '$_root/quota-pools';
const _first = 'a1111111-1111-4111-8111-111111111111';
const _second = 'a2222222-2222-4222-8222-222222222222';
const _created = 'a3333333-3333-4333-8333-333333333333';
const _child = 'b1111111-1111-4111-8111-111111111111';
const _firstName = '第一份每日额度';
const _secondName = '第二份每日额度';
const _period = '2099-10-09';

Json _pool(String id, String name) => {
  'id': id, 'subjectId': _child, 'name': name, 'scope': 'TOTAL', 'applicationId': null,
  'periodId': _period, 'timeZone': 'UTC',
  'periodStart': DateTime.utc(2099, 10, 9).millisecondsSinceEpoch,
  'periodEnd': DateTime.utc(2099, 10, 10).millisecondsSinceEpoch,
  'limitSeconds': 3600, 'usedSeconds': 600, 'reservedSeconds': 300, 'availableSeconds': 2700,
  'status': 'CONFIGURED', 'evidenceStatus': 'LEDGER_ONLY', 'version': 7,
  'planId': null, 'planVersion': null,
};
http.Response _reply(Object body, {int status = 200}) => http.Response(jsonEncode(body), status,
    headers: {'content-type': 'application/json; charset=utf-8'});
Json _subjects() => {'items': [{'id': _child, 'nickname': '测试儿童',
  'ageBand': 'AGE_7_12', 'version': 0}], 'nextCursor': null};

class _Session extends EntrySession {
  _Session(super.handler) { tenant = {...tenant!, 'timeZone': 'UTC'}; }
  int validations = 0;
  @override
  void login({bool stepUp = false}) { if (stepUp) validations++; }
}

class _Fixture {
  final requests = <http.Request>[];
  final visible = ValueNotifier<bool>(true);
  final originals = <String, Json>{};
  final createQueryStatuses = <int>[], adjustQueryStatuses = <int>[];
  Json first = _pool(_first, _firstName);
  Json? created;
  bool unknownCreate = false, unknownAdjust = false, laterBalance = false, denyLedger = false, closed = false;
  Completer<http.Response>? detailResponse, subjectResponse;
  late final session = _Session(handle);
  List<http.Request> get lists => requests.where((r) => r.method == 'GET' && r.url.path == _path).toList();
  List<http.Request> get planLists => requests.where((r) => r.method == 'GET' && r.url.path == '$_root/quota-plans').toList();
  List<http.Request> get commands => requests.where((r) => r.method == 'POST' &&
      (r.url.path == _path || r.url.path.endsWith('/adjustments'))).toList();
  List<http.Request> get queries => requests.where((r) => r.method == 'POST' && r.url.path.endsWith('/query')).toList();
  Json committed(http.Request request) {
    final body = jsonDecode(request.body) as Json;
    if (request.url.path == _path) {
      final start = DateTime.parse('${body['periodId']}T00:00:00Z').millisecondsSinceEpoch;
      return {
        ..._pool(_created, body['name'] as String), ...body, 'id': _created, 'version': 0,
        'periodStart': start, 'periodEnd': start + const Duration(days: 1).inMilliseconds,
        'usedSeconds': 0, 'reservedSeconds': 0, 'availableSeconds': body['limitSeconds'],
      };
    }
    final before = originals[request.headers['idempotency-key']]!;
    final limit = (before['limitSeconds'] as int) + (body['deltaSeconds'] as int);
    return {...before, 'limitSeconds': limit,
      'availableSeconds': limit - (before['usedSeconds'] as int) - (before['reservedSeconds'] as int),
      'version': (before['version'] as int) + 1};
  }
  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET') {
      if (path == '$_root/subjects') {
        expect(request.url.queryParameters['cursor'], isNull,
            reason: 'A retired daily quota directory must not continue pagination.');
        final waiting = subjectResponse;
        if (waiting != null) return waiting.future;
        return _reply(_subjects());
      }
      if (path == '$_root/applications' || path == '$_root/quota-plans') {
        return _reply({'items': [], 'nextCursor': null});
      }
      if (path == _path) {
        final cursor = request.url.queryParameters['cursor'];
        if (cursor != null) {
          expect(cursor, 'next');
          return _reply({'items': [_pool(_second, _secondName)], 'nextCursor': null});
        }
        return _reply({'items': [first, if (created != null) created!], 'nextCursor': 'next'});
      }
      if (path == '$_path/$_first') {
        final waiting = detailResponse;
        if (waiting != null) return waiting.future;
        return _reply(first);
      }
      if (path == '$_path/$_first/ledger') {
        if (denyLedger) return _reply({'errorCode': 'ACCESS_DENIED'}, status: 403);
        return _reply({'items': [{
          'id': 'c1111111-1111-4111-8111-111111111111', 'leaseId': null,
          'kind': 'CREATED', 'limitDelta': 3600, 'usedDelta': 0, 'reservedDelta': 0,
          'sequence': 1, 'reason': 'INITIAL', 'occurredAt': first['periodStart'],
        }], 'nextCursor': null});
      }
    }
    if (request.method == 'POST' && (path == _path || path == '$_path/$_first/adjustments')) {
      final creating = path == _path;
      final key = request.headers['idempotency-key'];
      expect(key, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(request.headers['if-match'], creating ? null : '"${first['version']}"');
      originals[key!] = jsonDecode(jsonEncode(first)) as Json;
      if (creating ? unknownCreate : unknownAdjust) {
        return _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503);
      }
      final record = committed(request);
      if (creating) { created = record; } else { first = record; }
      return _reply(record, status: creating ? 201 : 200);
    }
    if (request.method == 'POST' && path.endsWith('/query')) {
      final original = commands.firstWhere((r) => path == (r.url.path == _path
          ? '$_path/creation-results/${r.headers['idempotency-key']}/query'
          : '$_path/$_first/adjustment-results/${r.headers['idempotency-key']}/query'));
      final creating = original.url.path == _path;
      expect(request.body, original.body);
      expect(request.headers['idempotency-key'], isNull);
      expect(request.headers['if-match'], original.headers['if-match']);
      final statuses = creating ? createQueryStatuses : adjustQueryStatuses;
      final status = statuses.isEmpty ? 200 : statuses.removeAt(0);
      if (status != 200) return _reply({'errorCode': status == 401 ? 'REAUTH_REQUIRED' : 'QUOTA_RESULT_UNAVAILABLE'}, status: status);
      final record = committed(original);
      final limit = (record['limitSeconds'] as int) + 120;
      final used = (record['usedSeconds'] as int) + 60;
      final current = !creating && laterBalance ? <String, dynamic>{...record,
        'version': (record['version'] as int) + 2, 'limitSeconds': limit, 'usedSeconds': used,
        'availableSeconds': limit - used - (record['reservedSeconds'] as int)} : record;
      if (creating) { created = current; } else { first = current; }
      return _reply({'requestId': original.headers['idempotency-key'],
        'operation': creating ? 'CREATE' : 'ADJUST', 'committed': record, 'current': current});
    }
    throw StateError('Unexpected daily quota boundary: ${request.method} $path');
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
Finder _dialogButton(String text) => find.descendant(of: find.byType(AlertDialog).last, matching: _button(text));
Finder get _search => find.descendant(of: find.byType(ResourcePage).first, matching: find.byType(TextField));
bool _actionReady(WidgetTester tester, Finder action) => action.evaluate().length == 1 &&
    tester.widget<ButtonStyleButton>(action).onPressed != null;
bool _listReady(WidgetTester tester) => find.byType(AlertDialog).evaluate().isEmpty &&
    _actionReady(tester, _button('创建每日额度'));
bool _formReady(WidgetTester tester) => find.byType(EditDialog).evaluate().length == 1 &&
    _actionReady(tester, _dialogButton('保存'));
bool _queryReady(WidgetTester tester) => find.byType(AlertDialog).evaluate().isNotEmpty &&
    _actionReady(tester, _dialogButton('查询原保存结果'));
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
  expect(ready(), isTrue, reason: 'The daily quota flow must reach its bounded next state.');
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
              ? SingleChildScrollView(child: QuotaPage(session: fixture.session))
              : const Text('已离开每日额度页面')))));
  await _flush(tester);
  await _until(tester, () => _listReady(tester) && find.text(_firstName).evaluate().length == 1);
}
Future<void> _details(WidgetTester tester) async {
  await _tap(tester, find.text(_firstName));
  await _until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty &&
      _actionReady(tester, _dialogButton('查看账本')));
}
Future<void> _adjust(WidgetTester tester) async {
  await _details(tester);
  await _tap(tester, _dialogButton('调整额度'));
  await _until(tester, () => _formReady(tester));
}

void main() {
  testWidgets('daily quota create cancellation and read-only details and ledger preserve list pages and search', (tester) async {
    final fixture = _Fixture();
    await _mount(tester, fixture);
    await _tap(tester, _button('加载更多'));
    await _until(tester, () => fixture.lists.length == 2 && _listReady(tester) &&
        find.text(_secondName).evaluate().length == 1);
    await tester.enterText(_search, '第一份');
    await tester.pump();
    await _tap(tester, _button('创建每日额度'));
    await _until(tester, () => _formReady(tester));
    await _tap(tester, _dialogButton('取消'));
    await _until(tester, () => _listReady(tester));
    await _details(tester);
    await _tap(tester, _dialogButton('关闭'));
    await _until(tester, () => _listReady(tester));
    await _details(tester);
    await _tap(tester, _dialogButton('查看账本'));
    final ledgerTitle = find.text('额度账本');
    final ledgerResource = find.ancestor(of: ledgerTitle, matching: find.byType(ResourcePage));
    await _until(tester, () => ledgerResource.evaluate().length == 1 &&
        !tester.state<ResourcePageState>(ledgerResource).loading &&
        tester.state<ResourcePageState>(ledgerResource).rows.length == 1);
    final ledger = find.ancestor(of: ledgerTitle, matching: find.byType(Dialog)).last;
    await _tap(tester, find.descendant(of: ledger, matching: _button('关闭')));
    await _until(tester, () => ledgerTitle.evaluate().isEmpty &&
        find.byType(AlertDialog).evaluate().isNotEmpty && _actionReady(tester, _dialogButton('关闭')));
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

  testWidgets('daily quota original queries preserve precise creation and adjustment bodies and review writes once', (tester) async {
    final fixture = _Fixture()..unknownCreate = true;
    fixture.createQueryStatuses.addAll([404, 200]);
    await _mount(tester, fixture);
    await _tap(tester, _button('创建每日额度'));
    await _until(tester, () => _formReady(tester));
    expect(tester.widget<DropdownButtonFormField<String>>(
        find.widgetWithText(DropdownButtonFormField<String>, '儿童')).initialValue, _child);
    await tester.enterText(find.widgetWithText(TextFormField, '额度名称'), '精确手工额度');
    final nextPeriod = DateTime.now().toUtc().add(const Duration(days: 1))
        .toIso8601String().substring(0, 10);
    await tester.enterText(find.widgetWithText(TextFormField, '当地日期'), nextPeriod);
    final createMinutes = find.widgetWithText(TextFormField, '额度（分钟，0–1440）');
    await tester.enterText(createMinutes, '1441');
    await _tap(tester, _dialogButton('保存'));
    await tester.pump();
    expect(tester.state<FormFieldState<String>>(createMinutes).errorText, isNotEmpty);
    expect(fixture.commands, isEmpty);
    await tester.enterText(createMinutes, '30');
    await tester.enterText(find.widgetWithText(TextFormField, '秒（可选）'), '17');
    await _tap(tester, _dialogButton('保存'));
    await _until(tester, () => fixture.commands.length == 1 && _queryReady(tester));
    expect((jsonDecode(fixture.commands.single.body) as Json)['limitSeconds'], 1817);
    await _tap(tester, _dialogButton('查询原保存结果'));
    await _until(tester, () => fixture.queries.length == 1 && _queryReady(tester));
    expect(tester.widget<TextFormField>(createMinutes).enabled, isFalse);
    expect(fixture.lists, hasLength(1));
    await _tap(tester, _dialogButton('查询原保存结果'));
    await _until(tester, () => fixture.queries.length == 2 && fixture.lists.length == 2 && _listReady(tester));
    expect(fixture.commands, hasLength(1));
    expect(fixture.created!['usedSeconds'], 0);
    expect(fixture.created!['reservedSeconds'], 0);
    await _adjust(tester);
    expect(tester.widget<DropdownButtonFormField<String>>(
        find.widgetWithText(DropdownButtonFormField<String>, '调整方式')).initialValue, 'ADD');
    await _tap(tester, _dialogButton('保存'));
    await _until(tester, () => fixture.commands.length == 2 && fixture.lists.length == 3 && _listReady(tester));
    expect(jsonDecode(fixture.commands.last.body), {'deltaSeconds': 900, 'reason': 'EXTRA_TIME'});
    fixture.unknownAdjust = true;
    fixture.laterBalance = true;
    fixture.adjustQueryStatuses.addAll([401, 200]);
    await _adjust(tester);
    await _tap(tester, find.widgetWithText(DropdownButtonFormField<String>, '调整方式'));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('减少额度').last);
    await tester.pumpAndSettle();
    final minutes = find.widgetWithText(TextFormField, '调整分钟数（0–1440）');
    final seconds = find.widgetWithText(TextFormField, '秒（可选）');
    await tester.enterText(minutes, '1440');
    await _tap(tester, _dialogButton('保存'));
    await _until(tester, () => find.byType(FailureView).evaluate().isNotEmpty && _formReady(tester));
    expect(fixture.commands, hasLength(2), reason: 'A reduction below settled and reserved seconds must fail locally.');
    expect(tester.widget<TextFormField>(minutes).enabled, isTrue);
    await tester.enterText(minutes, '0');
    await tester.enterText(seconds, '1');
    await _tap(tester, _dialogButton('保存'));
    await _until(tester, () => fixture.commands.length == 3 && _queryReady(tester));
    final adjustment = fixture.commands.last;
    expect(jsonDecode(adjustment.body), {'deltaSeconds': -1, 'reason': 'CORRECTION'});
    expect(adjustment.headers['if-match'], '"8"');
    await _tap(tester, _dialogButton('查询原保存结果'));
    await _until(tester, () => fixture.queries.length == 3 && _queryReady(tester));
    expect(tester.widget<TextFormField>(minutes).enabled, isFalse);
    expect(fixture.commands, hasLength(3));
    await _tap(tester, _dialogButton('查询原保存结果'));
    await _until(tester, () => fixture.queries.length == 4 && fixture.lists.length == 4 && _listReady(tester));
    expect(fixture.commands, hasLength(3));
    expect(fixture.queries.skip(2).every((r) => r.body == adjustment.body &&
        r.headers['idempotency-key'] == null && r.headers['if-match'] == '"8"'), isTrue);
    expect(find.textContaining('账本已有后续变化'), findsOneWidget);
    await _tap(tester, _button('创建每日额度'));
    await _until(tester, () => _formReady(tester));
    await _tap(tester, _dialogButton('保存'));
    await _until(tester, () => fixture.commands.length == 4 && _queryReady(tester));
    await _tap(tester, _dialogButton('暂时关闭'));
    await tester.pump();
    await _tap(tester, find.byKey(const Key('edit-dialog-confirm-close')));
    await _until(tester, () => fixture.lists.length == 5 && _listReady(tester));
    expect(fixture.commands, hasLength(4));
    expect(fixture.queries, hasLength(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('daily quota tab and page retirement block late reads and old actions while ledger denial hides private data', (tester) async {
    for (final stage in ['detailTab', 'directoryPage', 'editorPage', 'ledgerDenied']) {
      final fixture = _Fixture();
      await _mount(tester, fixture);
      final selectTab = tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>)).onSelectionChanged!;
      if (stage == 'ledgerDenied') {
        final oldCreate = tester.widget<ButtonStyleButton>(_button('创建每日额度')).onPressed!;
        fixture.denyLedger = true;
        await _details(tester);
        await _tap(tester, _dialogButton('查看账本'));
        await _until(tester, () => find.text('工作空间或权限已变化').evaluate().isNotEmpty &&
            find.text(_firstName, skipOffstage: false).evaluate().isEmpty);
        final beforeStale = fixture.requests.length;
        oldCreate();
        selectTab({true});
        await _flush(tester);
        expect(fixture.requests, hasLength(beforeStale));
        expect(_button('创建每日额度'), findsNothing);
        expect(fixture.commands, isEmpty);
        expect(fixture.session.role, 'OWNER');
        for (var turn = 0; turn < 2 && find.byType(AlertDialog).evaluate().isNotEmpty; turn++) {
          await _tap(tester, _dialogButton('关闭'));
          await _flush(tester);
        }
      } else {
        VoidCallback? heldSave, heldValidation;
        if (stage == 'detailTab') {
          fixture.detailResponse = Completer<http.Response>();
          await _tap(tester, find.text(_firstName));
          await _until(tester, () => fixture.requests.any((r) => r.url.path == '$_path/$_first'));
          selectTab({true});
          fixture.detailResponse!.complete(_reply(fixture.first));
          await tester.runAsync(() async {
            for (var turn = 0; turn < 6; turn++) {
              await Future<void>.delayed(Duration.zero);
            }
          });
          await tester.pump();
          await _until(tester, () => fixture.planLists.length == 1);
        } else {
          if (stage == 'directoryPage') fixture.subjectResponse = Completer<http.Response>();
          await _tap(tester, _button('创建每日额度'));
          if (stage == 'directoryPage') {
            await _until(tester, () => fixture.requests.any((r) => r.url.path == '$_root/subjects'));
          } else {
            await _until(tester, () => _formReady(tester));
            heldSave = tester.widget<ButtonStyleButton>(_dialogButton('保存')).onPressed!;
            heldValidation = tester.widget<EditDialog>(find.byType(EditDialog)).reauth!;
          }
          fixture.visible.value = false;
          await _until(tester, () => find.text('已离开每日额度页面').evaluate().length == 1);
        }
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
        expect(find.text(_firstName, skipOffstage: false), findsNothing);
        if (stage != 'editorPage') expect(find.byType(AlertDialog), findsNothing);
        expect(fixture.requests.where((r) => r.url.queryParameters['cursor'] == 'forbidden-next'), isEmpty);
        expect(fixture.session.validations, 0);
        expect(fixture.session.scopeGeneration, 0);
        if (stage == 'editorPage' && find.byType(AlertDialog).evaluate().isNotEmpty) {
          await _tap(tester, _dialogButton('关闭'));
          await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
        }
      }
      expect(tester.takeException(), isNull);
      await fixture.cleanup(tester);
    }
  });
}
