import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/policy_editor.dart';

class _Session extends ParentSession {
  final ParentApi fixture;
  _Session(this.fixture) {
    tenant = {'id': 'tenant-a'};
    profile = {'subject': 'guardian-a'};
    role = 'GUARDIAN';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  void switchWorkspace() {
    tenant = {'id': 'tenant-b'};
    notifyListeners();
  }
}

const _draft = <String, dynamic>{
  'id': 'policy-a',
  'name': '学习规则',
  'kind': 'POLICY',
  'revision': 7,
  'rules': [
    {
      'id': 'rest',
      'kind': 'USAGE_REMINDER',
      'effect': 'REMIND',
      'required': false,
      'seconds': 1800,
      'applicationId': null
    },
  ]
};

Future<void> _open(WidgetTester tester, _Session session, {Json? draft}) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => PolicyDraftEditor(
                          session: session, draft: draft ?? _draft))),
                  child: const Text('打开草稿'))))));
  await tester.tap(find.text('打开草稿'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'rule duration validates locally and stays staged until draft save',
      (tester) async {
    Json? submitted;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((request) async {
      if (request.method == 'GET') {
        return http.Response('{"items":[],"nextCursor":null}', 200);
      }
      submitted = jsonDecode(request.body) as Json;
      return http.Response.bytes(
          utf8.encode(jsonEncode({..._draft, ...submitted!, 'revision': 8})),
          200);
    }));
    await _open(tester, _Session(api));
    await tester.tap(find.text('连续使用提醒'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '0');
    await tester.tap(find.text('完成规则编辑'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 1–86400 的整数'), findsOneWidget);
    expect(submitted, isNull);
    await tester.enterText(find.byType(TextFormField), '600');
    await tester.tap(find.text('完成规则编辑'));
    await tester.pumpAndSettle();
    expect(submitted, isNull);
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();
    expect((submitted!['rules'] as List).single['seconds'], 600);
    expect((submitted!['rules'] as List).single['id'], 'rest');
    expect((_draft['rules'] as List).single['seconds'], 1800);
  });

  testWidgets(
      'workspace change closes the nested rule form and its draft editor',
      (tester) async {
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient(
            (_) async => http.Response('{"items":[],"nextCursor":null}', 200)));
    final session = _Session(api);
    await _open(tester, session);
    await tester.tap(find.text('连续使用提醒'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '600');
    await tester.pump();
    session.switchWorkspace();
    await tester.pumpAndSettle();
    expect(find.text('打开草稿'), findsOneWidget);
    expect(find.text('完成规则编辑'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'save uses the reviewed revision and preserves untouched rule fields',
      (tester) async {
    final writes = <http.Request>[];
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((request) async {
      writes.add(request);
      return http.Response.bytes(
          utf8.encode(jsonEncode({..._draft, 'revision': 8, 'name': '晚间规则'})),
          200);
    }));
    await _open(tester, _Session(api));
    await tester.enterText(find.byType(TextFormField).first, ' 晚间规则 ');
    await tester.pump();
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();
    expect(writes, hasLength(1));
    expect(writes.single.method, 'PUT');
    expect(writes.single.headers['If-Match'], '"7"');
    expect(jsonDecode(writes.single.body),
        {'name': '晚间规则', 'rules': _draft['rules']});
    expect(find.text('打开草稿'), findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join(' | '));
  });

  for (final failure in [412, 503]) {
    testWidgets(
        'HTTP $failure blocks stale or uncertain writes until authoritative reload',
        (tester) async {
      var writes = 0;
      final api = ParentApi(() async => 'fixture',
          baseUrl: 'https://fixture.invalid/api/v1',
          client: MockClient((request) async {
        writes++;
        return http.Response(
            jsonEncode({
              'errorCode':
                  failure == 412 ? 'RESOURCE_VERSION_CONFLICT' : 'UNAVAILABLE'
            }),
            failure);
      }));
      await _open(tester, _Session(api));
      await tester.enterText(find.byType(TextFormField).first, '新的规则');
      await tester.pump();
      await tester.tap(find.text('保存草稿'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(find.text('保存草稿'), findsNothing);
      expect(find.text('返回核对最新草稿'), findsOneWidget);
      expect(
          tester
              .widget<TextFormField>(find.byType(TextFormField).first)
              .enabled,
          isFalse);
      await tester.tap(find.text('返回核对最新草稿'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(find.text('打开草稿'), findsOneWidget);
    });
  }

  testWidgets('unsaved edits require explicit discard and issue no request',
      (tester) async {
    var requests = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((_) async {
      requests++;
      return http.Response('{}', 500);
    }));
    await _open(tester, _Session(api));
    await tester.enterText(find.byType(TextFormField).first, '未保存');
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('未保存'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.text('打开草稿'), findsOneWidget);
    expect(requests, 0);
  });

  testWidgets('scope change during token retrieval prevents the PUT dispatch',
      (tester) async {
    final token = Completer<String>();
    var writes = 0;
    final api = ParentApi(() => token.future,
        baseUrl: 'https://fixture.invalid', client: MockClient((_) async {
      writes++;
      return http.Response('{}', 500);
    }));
    final session = _Session(api);
    await _open(tester, session);
    await tester.enterText(find.byType(TextFormField).first, '未发送');
    await tester.pump();
    await tester.tap(find.text('保存草稿'));
    await tester.pump();
    session.switchWorkspace();
    await tester.pump();
    token.complete('new-account-token');
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.text('编辑策略草稿'), findsNothing);
  });
}
