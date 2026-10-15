@TestOn('browser')
library;

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/managed_android_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/managed_enrollment_form.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const tenantId = '11111111-1111-4111-8111-111111111111';
const subject = '33333333-3333-4333-8333-333333333333';
const intentId = '22222222-2222-4222-8222-222222222222';

class EnrollmentSession extends Session {
  EnrollmentSession(
      {this.bound = false, String actorRole = 'ORG_ADMIN', this.extra}) {
    profile = {'subject': 'operator-1'};
    tenant = {'id': tenantId, 'kind': 'ORGANIZATION'};
    role = actorRole;
  }
  bool bound, refreshFails = false, emptySubjects = false;
  final Future<http.Response?> Function(http.Request request)? extra;
  int epoch = 0, posts = 0;
  String? bindingState;
  List<Json> rows = [];
  final requests = <http.Request>[];
  late final transport = MockClient((request) async {
    requests.add(request);
    final delegated = await extra?.call(request);
    if (delegated != null) return delegated;
    final path = request.url.path;
    if (request.method == 'POST') {
      posts++;
      if (path.endsWith('/enterprise-binding')) {
        bound = true;
        bindingState = 'PENDING';
        return reply(bindingData(), status: 201);
      }
      if (path.endsWith('/enrollment-intents')) {
        rows = [
          {
            ...row(),
            'expiresAt': DateTime.now().millisecondsSinceEpoch + 300000
          }
        ];
        return reply({
          'intent': rows.first,
          'tokenValue': 'fixture-not-a-credential',
          'qrCode': '{"fixture":true}'
        }, status: 201);
      }
      if (path.endsWith('/verify')) {
        rows = [row(state: 'VERIFIED', version: 2)];
        return reply(rows.first);
      }
      throw StateError('Unexpected mutation $path');
    }
    if (refreshFails) {
      return reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503);
    }
    if (path.endsWith('/enterprise-binding')) {
      return bound ? reply(bindingData()) : reply({}, status: 404);
    }
    if (path.endsWith('/readiness')) {
      return reply({
        'tenantId': tenantId,
        'provider': 'LOCAL_EMM',
        'targetCountryCode': 'CN',
        'reasonCode': bindingState == 'PENDING'
            ? 'BINDING_REVIEW_PENDING'
            : bound
                ? 'PROVISIONING_CONFIGURED'
                : 'BINDING_REQUIRED',
        'canIssueEnrollment': bound && bindingState != 'PENDING',
      });
    }
    if (path.endsWith('/capacity')) {
      return reply({
        'tenantId': tenantId,
        'paidCapacity': 10,
        'verifiedDevices': 0,
        'reservedIntents': 0,
        'expiredUnresolvedIntents': 0,
        'cancelledUnreconciledIntents': 0,
        'availableForNew': 10,
        'overCapacity': false,
        'evaluatedAt': 1000,
      });
    }
    if (path.endsWith('/enrollment-intents')) {
      return reply({'items': rows, 'nextCursor': null});
    }
    if (path.endsWith('/subjects')) {
      return reply({
        'items': emptySubjects
            ? []
            : [
                {'id': subject, 'nickname': '示例学生'}
              ],
        'nextCursor': null
      });
    }
    throw StateError('Unexpected read $path');
  });
  late final Api testApi =
      Api(() async => transport, baseUrl: 'http://mock.invalid/api/v1');
  @override
  Api get api => testApi;
  @override
  bool get authenticated => true;
  @override
  int get scopeGeneration => epoch;
  void invalidate() {
    epoch++;
    notifyListeners();
  }

  Json bindingData() => {
        'tenantId': tenantId,
        'provider': 'LOCAL_EMM',
        'enterpriseId': 'org_1',
        'contractReference': 'CN-001',
        'state': bindingState ?? 'ACTIVE',
        'version': 1,
        'createdAt': 1000,
        'updatedAt': 1000
      };
}

Json row({String state = 'ISSUED', int version = 1}) => {
      'id': intentId,
      'tenantId': tenantId,
      'subjectId': subject,
      'provider': 'LOCAL_EMM',
      'enterpriseId': 'org_1',
      'state': state,
      'version': version,
      'createdAt': 1000,
      'expiresAt': 2000,
      'issuedAt': 1000,
      if (state == 'VERIFIED') ...{
        'providerDeviceId': 'device_1',
        'managementMode': 'DEVICE_OWNER',
        'verifiedAt': 1500
      },
    };
http.Response reply(Object data, {int status = 200}) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

Future<void> mount(WidgetTester tester, EnrollmentSession session,
    {double width = 1100}) async {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    session.dispose();
  });
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: SingleChildScrollView(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: ManagedAndroidPage(session: session))))));
  await settle(tester);
}

void main() {
  testWidgets(
      'single first action validates before a scoped POST then shows review progress',
      (tester) async {
    final session = EnrollmentSession();
    await mount(tester, session);
    expect(find.text('申请机构审核'), findsOneWidget);
    await tester.tap(find.text('申请机构审核'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交审核'));
    await tester.pumpAndSettle();
    expect(session.posts, 0);
    await tester.enterText(find.byType(TextFormField).first, 'org_1');
    await tester.enterText(find.byType(TextFormField).last, 'CN-001');
    await tester.tap(find.text('提交审核'));
    await settle(tester);
    expect(session.posts, 1);
    expect(find.text('等待平台审核'), findsWidgets);
    expect(find.text('接入一台设备'), findsNothing);
  });
  testWidgets('scope change closes pending form and old scope cannot revive',
      (tester) async {
    final session = EnrollmentSession();
    await mount(tester, session);
    await tester.tap(find.text('申请机构审核'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'org_1');
    session.invalidate();
    await settle(tester);
    expect(find.byType(ManagedEnrollmentForm), findsNothing);
    expect(session.posts, 0);
    expect(find.text('申请机构审核'), findsNothing);
  });
  testWidgets('refresh failure disables stale primary action', (tester) async {
    final session = EnrollmentSession(bound: true);
    await mount(tester, session);
    session.refreshFails = true;
    await tester.tap(find.text('刷新状态'));
    await settle(tester);
    final button = find.ancestor(
        of: find.text('接入一台设备'),
        matching: find.byWidgetPredicate((w) => w is FilledButton));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(session.posts, 0);
  });
  testWidgets(
      'empty student list explains next operation instead of doing nothing',
      (tester) async {
    final session = EnrollmentSession(bound: true)..emptySubjects = true;
    await mount(tester, session);
    await tester.tap(find.text('接入一台设备'));
    await settle(tester);
    expect(find.textContaining('请先在“儿童 / 学生档案”'), findsOneWidget);
    expect(session.posts, 0);
  });
  testWidgets('auditor can inspect expired records without mutation buttons',
      (tester) async {
    final session = EnrollmentSession(bound: true, actorRole: 'AUDITOR')
      ..rows = [row()];
    await mount(tester, session, width: 390);
    expect(find.text('资料已到期，待核对'), findsOneWidget);
    expect(find.text('核对设备'), findsNothing);
    expect(find.text('取消令牌'), findsNothing);
    expect(find.text('接入一台设备'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('expired intent can still verify using its version',
      (tester) async {
    final session = EnrollmentSession(bound: true)..rows = [row()];
    await mount(tester, session);
    await tester.ensureVisible(find.text('核对设备'));
    await tester.tap(find.text('核对设备'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'device_1');
    await tester.tap(find.widgetWithText(FilledButton, '核对身份'));
    await settle(tester);
    expect(session.posts, 1);
    final request =
        session.requests.singleWhere((r) => r.url.path.endsWith('/verify'));
    expect(request.headers['If-Match'] ?? request.headers['if-match'], '"1"');
    expect(jsonDecode(request.body), {'providerDeviceId': 'device_1'});
    expect(find.text('身份已核对'), findsOneWidget);
  });
  testWidgets(
      'creation selects student and issues once then exposes registered-record followup',
      (tester) async {
    final session = EnrollmentSession(bound: true);
    await mount(tester, session, width: 390);
    await tester.tap(find.text('接入一台设备'));
    await settle(tester);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('示例学生').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成一次性二维码'));
    await settle(tester);
    expect(session.posts, 1);
    expect(find.text('扫描二维码完成注册'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭资料窗口'));
    await settle(tester);
    expect(find.text('核对设备'), findsOneWidget);
    expect(session.posts, 1);
  });
}
