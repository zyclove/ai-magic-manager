import 'dart:convert';
import 'package:child/core/environment.dart';
import 'package:child/core/family_access.dart';
import 'package:child/core/help_requests.dart';
import 'package:child/core/session.dart';
import 'package:child/ui/family_access_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support/identity_fixture.dart';

class _Store implements ChildHelpStore {
  final records = <String, String>{};
  @override
  Future<String?> read(String key) async => records[key];
  @override
  Future<void> write(String key, String value) async {
    records[key] = value;
  }
}

void main() {
  late IdentityFixture identity;
  late ChildSession session;
  late _Store store;
  late List<http.Request> requests;
  setUp(() async {
    identity = IdentityFixture();
    await identity.activate();
    session = identity.session();
    await session.initialize();
    store = _Store();
    requests = [];
  });
  tearDown(() {
    session.dispose();
    identity.close();
  });
  FamilyAccessCoordinator create(ChildSession session) =>
      FamilyAccessCoordinator(
          session: session,
          environment: ChildEnvironment(
              apiRoot: Uri.parse('https://service.example/api/v1')),
          store: store,
          nowMillis: () => identity.clock,
          client: MockClient((request) async {
            requests.add(request);
            final body = jsonDecode(request.body) as Map;
            return http.Response(
                jsonEncode({
                  'id': body['requestId'],
                  'subjectId': '99999999-9999-4999-8999-999999999999',
                  'deviceId': IdentityFixture.device,
                  'state': 'PENDING',
                  'requestedSeconds': body['requestedSeconds'],
                  'reason': body['reason'] ?? '',
                  'grantedSeconds': null,
                  'notAfter': null,
                  'expiresAt': identity.clock + 3600000,
                  'version': 0
                }),
                200,
                headers: {'content-type': 'application/json'});
          }));
  testWidgets(
      'family request requires confirmation and labels cloud receipt accurately',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: FamilyAccessPage(session: session, factory: create)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交申请'));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    for (var i = 0;
        i < 20 && find.text('云端已收到，等待家长处理').evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(jsonDecode(store.records.values.single)['phase'], 'CONFIRMED',
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data)
            .join(' | '));
    expect(
        requests.single.url.path, '/api/v1/device-api/family/access-requests');
    expect(find.text('云端已收到，等待家长处理'), findsOneWidget);
    expect(find.text('已解除限制'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
      'a confirmation opened before background cannot submit after resume',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: FamilyAccessPage(session: session, factory: create)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交申请'));
    await tester.pumpAndSettle();
    await session.setForeground(false);
    await session.setForeground(true);
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
