import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family_notifications.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/ui/family_notification_page.dart';
import 'package:parent/ui/family_workspace.dart';
import 'family_device_access_test.dart' show SelectionMemoryStorage;
import 'family_notifications_test.dart' show PushFixture, prefs, readiness;
import 'family_workspace_test.dart' show FamilySession;

void main() {
  Future<
          (
            FamilySession,
            FamilyNotificationCoordinator,
            PushFixture,
            List<http.Request>
          )>
      mount(WidgetTester t, {bool configured = true, double scale = 1}) async {
    final calls = <http.Request>[],
        platform = PushFixture()..configured = configured;
    var currentPrefs = Map<String, dynamic>.from(prefs);
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      calls.add(r);
      final dynamic value;
      if (r.url.path.endsWith('push-readiness')) {
        value = {...readiness, 'providerConfigured': configured};
      } else if (r.url.path.contains('push-installations') &&
          r.method == 'PUT') {
        value = {
          'installationId': r.url.pathSegments.last,
          'provider': 'ALIYUN',
          'platform': 'ANDROID',
          'notificationConsent': true,
          'permissionGranted': true,
          'deliveryVerified': false
        };
      } else if (r.method == 'PUT') {
        currentPrefs = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
        value = currentPrefs;
      } else {
        value = currentPrefs;
      }
      return http.Response(jsonEncode(value), 200);
    })));
    final coordinator = FamilyNotificationCoordinator(
        session: session,
        storage: SelectionMemoryStorage(),
        platform: platform);
    addTearDown(coordinator.dispose);
    addTearDown(session.dispose);
    await t.pumpWidget(MaterialApp(
        theme: familyTheme(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: FamilyNotificationPage(
            session: session, coordinator: coordinator)));
    await t.pumpAndSettle();
    return (session, coordinator, platform, calls);
  }

  testWidgets(
      'opening notification settings neither requests permission nor subscribes',
      (t) async {
    final result = await mount(t);
    expect(find.text('消息提醒'), findsOneWidget);
    expect(find.text('在此手机开启提醒'), findsOneWidget);
    expect(result.$3.permissionRequests, 0);
    expect(result.$4.every((r) => r.method == 'GET'), isTrue);
  });
  testWidgets(
      'one explicit device action registers and then category preferences remain user controlled',
      (t) async {
    final result = await mount(t);
    await t.tap(find.text('在此手机开启提醒'));
    await t.pumpAndSettle();
    expect(result.$3.permissionRequests, 1);
    expect(result.$3.registrations, 1);
    expect(result.$2.deviceRegistered, isTrue);
    expect(result.$2.preferences!.enabled, isFalse);
    await t.ensureVisible(find.text('接收家庭提醒'));
    await t.tap(find.text('接收家庭提醒'));
    await t.pumpAndSettle();
    expect(result.$2.preferences!.enabled, isTrue);
  });
  testWidgets('unavailable service explains status without fake registration',
      (t) async {
    final result = await mount(t, configured: false);
    expect(find.textContaining('提醒服务尚未开放'), findsOneWidget);
    expect(result.$3.registrations, 0);
    expect(result.$4.every((r) => r.method == 'GET'), isTrue);
  });
  testWidgets('settings support narrow screens and double text', (t) async {
    t.view.physicalSize = const Size(320, 720);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await mount(t, scale: 2);
    await t.scrollUntilVisible(find.text('会员与作息到期'), 200);
    expect(t.takeException(), isNull);
  });
}
