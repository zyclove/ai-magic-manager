import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family_notifications.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/ui/family_app_host.dart';
import 'package:parent/ui/family_invitation_page.dart';
import 'package:parent/ui/family_inbox_page.dart';
import 'family_workspace_test.dart' show FamilySession, familyDashboard;
import 'family_notifications_test.dart' show PushFixture, prefs, readiness;
import 'family_device_access_test.dart' show SelectionMemoryStorage;
import 'family_collaboration_test.dart' show invitationId, secret;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'an authorized notification opens current family facts rather than the legacy inbox',
      (t) async {
    const installation = '88888888-8888-4888-8888-888888888888';
    final requests = <http.Request>[],
        native = PushFixture()
          ..click = const FamilyPushClick(
              '99999999-9999-4999-8999-999999999999',
              installationId: installation);
    final store = SelectionMemoryStorage();
    store.values['parent.family.push-installation.v1'] = jsonEncode({
      'actor': 'adult',
      'tenant': 'family',
      'installationId': installation,
      'phase': 'ACTIVE'
    });
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      requests.add(r);
      return http.Response(
          jsonEncode(r.url.path.endsWith('family-dashboard')
              ? familyDashboard()
              : r.url.path.endsWith('push-readiness')
                  ? readiness
                  : r.method == 'PUT'
                      ? {
                          'installationId': installation,
                          'provider': 'ALIYUN',
                          'platform': 'ANDROID',
                          'notificationConsent': true,
                          'permissionGranted': true,
                          'deliveryVerified': false
                        }
                      : {...prefs, 'enabled': true}),
          200);
    })));
    final coordinator = FamilyNotificationCoordinator(
        session: session, storage: store, platform: native);
    addTearDown(coordinator.dispose);
    addTearDown(session.dispose);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.aimanager.parent/links'),
            (call) async => null);
    await t.pumpWidget(FamilyAppHost(
        session: session,
        coordinator: coordinator,
        builder: (key, push) => MaterialApp(
            navigatorKey: key, home: const Scaffold(body: Text('home')))));
    await t.pumpAndSettle();
    expect(find.byType(FamilyInboxPage), findsOneWidget);
    expect(
        requests.any((r) => r.url.path.endsWith('/family-dashboard')), isTrue);
    expect(requests.any((r) => r.url.path.contains('/notifications')), isFalse);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'an open invitation does not block app resume and notification recovery',
      (t) async {
    final requests = <http.Request>[], native = PushFixture();
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/preview')) {
        return http.Response('{"errorCode":"UNAVAILABLE"}', 503);
      }
      requests.add(r);
      return http.Response(
          jsonEncode(r.url.path.endsWith('push-readiness') ? readiness : prefs),
          200);
    })));
    final coordinator = FamilyNotificationCoordinator(
        session: session, storage: SelectionMemoryStorage(), platform: native);
    addTearDown(coordinator.dispose);
    addTearDown(session.dispose);
    var take = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.aimanager.parent/storage'),
            (call) async => true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.aimanager.parent/links'), (call) async {
      if (!take) return null;
      take = false;
      return {'id': invitationId, 'token': secret};
    });
    await t.pumpWidget(FamilyAppHost(
        session: session,
        coordinator: coordinator,
        builder: (key, push) => MaterialApp(
            navigatorKey: key, home: const Scaffold(body: Text('home')))));
    await t.pumpAndSettle();
    expect(find.byType(FamilyInvitationAcceptancePage), findsOneWidget);
    expect(requests.length, 2);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(requests.length, 4);
    expect(native.registrations, 0);
    await t.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
      'one app coordinator checks the current scope on resume without opting in',
      (t) async {
    final requests = <http.Request>[];
    final native = PushFixture();
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      requests.add(r);
      return http.Response(
          jsonEncode(r.url.path.endsWith('push-readiness') ? readiness : prefs),
          200);
    })));
    final coordinator = FamilyNotificationCoordinator(
        session: session, storage: SelectionMemoryStorage(), platform: native);
    addTearDown(coordinator.dispose);
    addTearDown(session.dispose);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.aimanager.parent/links'),
            (call) async => null);
    await t.pumpWidget(FamilyAppHost(
        session: session,
        coordinator: coordinator,
        builder: (key, push) => MaterialApp(
            navigatorKey: key, home: const Scaffold(body: Text('home')))));
    await t.pumpAndSettle();
    expect(requests.length, 2);
    expect(native.permissionRequests, 0);
    expect(native.registrations, 0);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(requests.length, 4);
    expect(native.permissionRequests, 0);
    await t.pumpWidget(const SizedBox.shrink());
    expect(session.beforeIdentityChange, isNull);
  });
}
