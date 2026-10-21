import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/ui/first_use.dart';

class _Session extends ParentSession {
  final ParentApi fixture;
  int refreshes = 0;
  _Session(this.fixture) {
    profile = {'subject': 'adult', 'canCreateTenant': true};
    role = 'OWNER';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  @override
  Future<void> refreshWorkspaces() async {
    refreshes++;
  }
}

class _Store extends ParentDurableStorage {
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

void main() {
  testWidgets(
      'verified family signup requires guardian declaration before onboarding',
      (tester) async {
    http.Request? sent;
    final session = _Session(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      sent = r;
      return http.Response('{"id":"family"}', 201);
    })))
      ..profile = {
        'subject': 'adult',
        'canCreateFamily': true,
        'canCreateTenant': false
      };
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(body: FamilySetup(session: session, storage: _Store()))));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsOneWidget);
    await tester.tap(find.text('创建我的家庭'));
    await tester.pumpAndSettle();
    expect(sent, isNull);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('创建我的家庭'));
    await tester.pumpAndSettle();
    expect(sent!.url.path, '/family-onboarding');
    expect(jsonDecode(sent!.body),
        {'adultGuardian': true, 'declarationVersion': 'family-guardian-v1'});
    expect(sent!.headers['Idempotency-Key'], isNotEmpty);
  });
  testWidgets('new family is created directly in the parent app',
      (tester) async {
    http.Request? sent;
    final session = _Session(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      sent = r;
      return http.Response('{"id":"family"}', 201);
    })));
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        home:
            Scaffold(body: FamilySetup(session: session, storage: _Store()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建我的家庭'));
    await tester.pumpAndSettle();
    expect(sent?.url.path, '/tenants');
    expect(jsonDecode(sent!.body),
        {'name': '我的家庭', 'kind': 'FAMILY', 'timeZone': 'Asia/Shanghai'});
    expect(sent!.headers['Idempotency-Key'], isNotEmpty);
    expect(session.refreshes, 1);
  });
  testWidgets(
      'child form requires an age band and creates without leaving the app',
      (tester) async {
    http.Request? sent;
    final session = _Session(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      sent = r;
      return http.Response(
          '{"id":"child","nickname":"小明","ageBand":"AGE_7_12"}', 201,
          headers: {'content-type': 'application/json; charset=utf-8'});
    })))
      ..tenant = {'id': 'family'};
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ChildProfileForm(session: session, storage: _Store()))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '小明');
    await tester.tap(find.text('保存儿童档案'));
    await tester.pumpAndSettle();
    expect(sent, isNull);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7–12 岁').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存儿童档案'));
    await tester.pumpAndSettle();
    expect(sent?.url.path, '/tenants/family/subjects');
    expect(jsonDecode(sent!.body), {'nickname': '小明', 'ageBand': 'AGE_7_12'});
    expect(find.text('档案已保存'), findsOneWidget);
  });
  testWidgets(
      'an uncertain child save survives closing and reuses its original request',
      (tester) async {
    final store = _Store();
    final sent = <http.Request>[];
    final session = _Session(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      sent.add(r);
      return http.Response(
          sent.length == 1 ? '{"errorCode":"UNAVAILABLE"}' : '{"id":"child"}',
          sent.length == 1 ? 503 : 201);
    })))
      ..tenant = {'id': 'family'};
    addTearDown(session.dispose);
    Widget screen() => MaterialApp(
        home:
            Scaffold(body: ChildProfileForm(session: session, storage: store)));
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '小明');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7–12 岁').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存儿童档案'));
    await tester.pumpAndSettle();
    expect(store.values, isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        '小明');
    await tester.tap(find.text('继续保存'));
    await tester.pumpAndSettle();
    expect(sent.length, 2);
    expect(
        sent[0].headers['Idempotency-Key'], sent[1].headers['Idempotency-Key']);
    expect(sent[0].body, sent[1].body);
    expect(store.values, isEmpty);
    expect(find.text('档案已保存'), findsOneWidget);
  });
}
