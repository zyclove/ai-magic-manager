import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family_notifications.dart';
import 'package:parent/core/parent_api.dart';
import 'family_device_access_test.dart' show SelectionMemoryStorage;
import 'family_workspace_test.dart' show FamilySession;

const prefs = {
  'enabled': false,
  'requests': false,
  'deviceAttention': false,
  'ruleExpiry': false
};
const readiness = {
  'provider': 'ALIYUN',
  'platform': 'ANDROID',
  'providerConfigured': true,
  'workerEnabled': true,
  'nativeIntegrationVerified': false,
  'deliveryVerified': false
};

class PushFixture extends FamilyPushPlatform {
  bool permission = true, configured = true;
  String? guard;
  FamilyPushClick? click;
  String deviceToken = 'actual-sdk-fixture-device';
  int registrations = 0, permissionRequests = 0;
  @override
  Future<FamilyPushState> state() async => FamilyPushState(
      configured: configured,
      permissionGranted: permission,
      channelEnabled: permission);
  @override
  Future<FamilyPushState> requestPermission() async {
    permissionRequests++;
    return state();
  }

  @override
  Future<String> register() async {
    registrations++;
    return deviceToken;
  }

  @override
  Future<void> activate(String installationId) async {
    guard = installationId;
  }

  @override
  Future<void> deactivate({bool preserveClick = false}) async {
    guard = null;
    if (!preserveClick) click = null;
  }

  @override
  Future<FamilyPushClick?> takeClick() async {
    final value = click;
    click = null;
    return value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'loading preferences never registers SDK, asks permission or enables subscription',
      () async {
    final calls = <http.Request>[], platform = PushFixture();
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      calls.add(r);
      return http.Response(
          jsonEncode(r.url.path.endsWith('push-readiness') ? readiness : prefs),
          200);
    })));
    addTearDown(session.dispose);
    final coordinator = FamilyNotificationCoordinator(
        session: session,
        storage: SelectionMemoryStorage(),
        platform: platform);
    addTearDown(coordinator.dispose);
    await coordinator.load();
    expect(coordinator.loaded, true);
    expect(coordinator.preferences!.enabled, false);
    expect(platform.registrations, 0);
    expect(platform.permissionRequests, 0);
    expect(calls.every((r) => r.method == 'GET'), true);
  });
  test(
      'explicit device enable journals before server PUT and does not enable preference',
      () async {
    final storage = SelectionMemoryStorage(),
        platform = PushFixture(),
        puts = <http.Request>[];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') {
        puts.add(r);
        expect(storage.values, isNotEmpty);
        final id = r.url.pathSegments.last;
        return http.Response(
            jsonEncode({
              'installationId': id,
              'provider': 'ALIYUN',
              'platform': 'ANDROID',
              'notificationConsent': true,
              'permissionGranted': true,
              'deliveryVerified': false
            }),
            200);
      }
      return http.Response(
          jsonEncode(r.url.path.endsWith('push-readiness') ? readiness : prefs),
          200);
    })));
    addTearDown(session.dispose);
    final c = FamilyNotificationCoordinator(
        session: session, storage: storage, platform: platform);
    addTearDown(c.dispose);
    await c.load();
    await c.enableOnDevice();
    expect(c.deviceRegistered, true);
    expect(c.preferences!.enabled, false);
    expect(puts.single.url.path, contains('/push-installations/'));
    expect(jsonDecode(puts.single.body)['providerToken'],
        'actual-sdk-fixture-device');
    expect(platform.guard, null);
    expect(storage.values.values.single,
        isNot(contains('actual-sdk-fixture-device')));
  });
  test(
      'unknown revoke stops local display and survives restart without new registration',
      () async {
    var failDelete = true;
    final storage = SelectionMemoryStorage(), platform = PushFixture();
    final deletes = <String>[];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'DELETE') {
        deletes.add(r.url.path);
        return http.Response(failDelete ? '{}' : '', failDelete ? 503 : 204);
      }
      if (r.method == 'PUT') {
        return http.Response(
            jsonEncode({
              'installationId': r.url.pathSegments.last,
              'provider': 'ALIYUN',
              'platform': 'ANDROID',
              'notificationConsent': true,
              'permissionGranted': true,
              'deliveryVerified': false
            }),
            200);
      }
      return http.Response(
          jsonEncode(r.url.path.endsWith('push-readiness') ? readiness : prefs),
          200);
    })));
    addTearDown(session.dispose);
    final c = FamilyNotificationCoordinator(
        session: session, storage: storage, platform: platform);
    await c.load();
    await c.enableOnDevice();
    expect(await c.beforeScopeChange(), false);
    expect(platform.guard, null);
    expect(c.revocationPending, true);
    c.dispose();
    final restarted = FamilyNotificationCoordinator(
        session: session, storage: storage, platform: platform);
    addTearDown(restarted.dispose);
    await restarted.load();
    expect(restarted.revocationPending, true);
    await expectLater(
        restarted.enableOnDevice(), throwsA(isA<ParentApiException>()));
    expect(platform.registrations, 1);
    failDelete = false;
    await restarted.onResume();
    expect(restarted.revocationPending, false);
    expect(deletes.toSet().length, 1);
    expect(storage.values, isEmpty);
  });
  test('permission revocation reconciles DELETE without requesting permission',
      () async {
    final storage = SelectionMemoryStorage(), platform = PushFixture();
    var deleted = false;
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'DELETE') {
        deleted = true;
        return http.Response('', 204);
      }
      if (r.method == 'PUT') {
        return http.Response(
            jsonEncode({
              'installationId': r.url.pathSegments.last,
              'provider': 'ALIYUN',
              'platform': 'ANDROID',
              'notificationConsent': true,
              'permissionGranted': true,
              'deliveryVerified': false
            }),
            200);
      }
      return http.Response(
          jsonEncode(r.url.path.endsWith('push-readiness') ? readiness : prefs),
          200);
    })));
    addTearDown(session.dispose);
    final c = FamilyNotificationCoordinator(
        session: session, storage: storage, platform: platform);
    addTearDown(c.dispose);
    await c.load();
    await c.enableOnDevice();
    platform.permission = false;
    await c.onResume();
    expect(deleted, true);
    expect(c.deviceRegistered, false);
    expect(platform.guard, null);
    expect(platform.permissionRequests, 1);
  });
  test('stale registration response cannot activate after a workspace change',
      () async {
    final response = Completer<http.Response>(), platform = PushFixture();
    late String id;
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') {
        id = r.url.pathSegments.last;
        return response.future;
      }
      return http.Response(
          jsonEncode(r.url.path.endsWith('push-readiness') ? readiness : prefs),
          200);
    })));
    addTearDown(session.dispose);
    final c = FamilyNotificationCoordinator(
        session: session,
        storage: SelectionMemoryStorage(),
        platform: platform);
    addTearDown(c.dispose);
    await c.load();
    final action = c.enableOnDevice();
    await Future<void>.delayed(Duration.zero);
    session.generation++;
    session.notifyListeners();
    response.complete(http.Response(
        jsonEncode({
          'installationId': id,
          'provider': 'ALIYUN',
          'platform': 'ANDROID',
          'notificationConsent': true,
          'permissionGranted': true,
          'deliveryVerified': false
        }),
        200));
    await expectLater(action, throwsA(isA<ParentApiException>()));
    expect(platform.guard, null);
    expect(c.deviceRegistered, false);
  });
  test('unconfigured builds do not ask system permission or start SDK',
      () async {
    final platform = PushFixture()..configured = false;
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => http.Response(
            jsonEncode(
                r.url.path.endsWith('push-readiness') ? readiness : prefs),
            200))));
    addTearDown(session.dispose);
    final c = FamilyNotificationCoordinator(
        session: session,
        storage: SelectionMemoryStorage(),
        platform: platform);
    addTearDown(c.dispose);
    await c.load();
    await expectLater(c.enableOnDevice(), throwsA(isA<ParentApiException>()));
    expect(platform.permissionRequests, 0);
    expect(platform.registrations, 0);
  });
  test('notification URI accepts only canonical opaque event routes', () {
    const event = '00000000-0000-4000-8000-000000000001';
    expect(FamilyPushClick.parse('aimanager://notifications/$event')!.eventId,
        event);
    for (final bad in [
      'https://notifications/$event',
      'aimanager://notifications/$event?tenant=other',
      'aimanager://notifications/$event#x',
      'aimanager://notifications/%30${event.substring(1)}',
      'aimanager://notifications/$event/',
      'aimanager://user@notifications/$event',
      'aimanager://notifications:80/$event',
      'aimanager://notifications/child'
    ]) {
      expect(FamilyPushClick.parse(bad), null, reason: bad);
    }
  });
  test(
      'warm and cold notification clicks survive read-only resume then consume once',
      () async {
    final storage = SelectionMemoryStorage(), platform = PushFixture();
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') {
        return http.Response(
            jsonEncode({
              'installationId': r.url.pathSegments.last,
              'provider': 'ALIYUN',
              'platform': 'ANDROID',
              'notificationConsent': true,
              'permissionGranted': true,
              'deliveryVerified': false
            }),
            200);
      }
      return http.Response(
          jsonEncode(r.url.path.endsWith('push-readiness')
              ? readiness
              : {...prefs, 'enabled': true}),
          200);
    })));
    addTearDown(session.dispose);
    final c = FamilyNotificationCoordinator(
        session: session, storage: storage, platform: platform);
    await c.load();
    await c.enableOnDevice();
    const event = '00000000-0000-4000-8000-000000000001';
    final id = platform.guard!;
    platform.click = FamilyPushClick(event, installationId: id);
    await c.onResume();
    expect((await c.takeClick())?.eventId, event);
    expect(await c.takeClick(), null);
    c.dispose();
    platform.click = FamilyPushClick(event, installationId: id);
    final cold = FamilyNotificationCoordinator(
        session: session, storage: storage, platform: platform);
    addTearDown(cold.dispose);
    await cold.load();
    expect((await cold.takeClick())?.eventId, event);
    platform.click = const FamilyPushClick(event,
        installationId: '00000000-0000-4000-8000-000000000009');
    expect(await cold.takeClick(), null);
  });
  test('resume reconciles actual SDK token rotation on same installation',
      () async {
    final storage = SelectionMemoryStorage(),
        platform = PushFixture(),
        writes = <http.Request>[];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') {
        writes.add(r);
        return http.Response(
            jsonEncode({
              'installationId': r.url.pathSegments.last,
              'provider': 'ALIYUN',
              'platform': 'ANDROID',
              'notificationConsent': true,
              'permissionGranted': true,
              'deliveryVerified': false
            }),
            200);
      }
      return http.Response(
          jsonEncode(r.url.path.endsWith('push-readiness')
              ? readiness
              : {...prefs, 'enabled': true}),
          200);
    })));
    addTearDown(session.dispose);
    final c = FamilyNotificationCoordinator(
        session: session, storage: storage, platform: platform);
    addTearDown(c.dispose);
    await c.load();
    await c.enableOnDevice();
    platform.deviceToken = 'rotated-sdk-device-token';
    await c.onResume();
    expect(writes.length, 2);
    expect(writes[0].url.path, writes[1].url.path);
    expect(jsonDecode(writes[1].body)['providerToken'],
        'rotated-sdk-device-token');
  });
  test(
      'turning off master stops local display before uncertain preference response',
      () async {
    final storage = SelectionMemoryStorage(), platform = PushFixture();
    var deleted = false;
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'DELETE') {
        deleted = true;
        return http.Response('', 204);
      }
      if (r.method == 'PUT' &&
          r.url.path.endsWith('notification-preferences')) {
        return http.Response('{}', 503);
      }
      if (r.method == 'PUT') {
        return http.Response(
            jsonEncode({
              'installationId': r.url.pathSegments.last,
              'provider': 'ALIYUN',
              'platform': 'ANDROID',
              'notificationConsent': true,
              'permissionGranted': true,
              'deliveryVerified': false
            }),
            200);
      }
      return http.Response(
          jsonEncode(r.url.path.endsWith('push-readiness')
              ? readiness
              : {...prefs, 'enabled': true}),
          200);
    })));
    addTearDown(session.dispose);
    final c = FamilyNotificationCoordinator(
        session: session, storage: storage, platform: platform);
    addTearDown(c.dispose);
    await c.load();
    await c.enableOnDevice();
    expect(platform.guard, isNotNull);
    await expectLater(
        c.savePreferences(c.preferences!.copyWith(enabled: false)),
        throwsA(isA<ParentApiException>()));
    expect(platform.guard, null);
    expect(deleted, true);
    expect(c.deviceRegistered, false);
    await c.onResume();
    expect(platform.guard, null);
  });
  test('accepted but unfinished DELETE keeps encrypted revoke journal',
      () async {
    final storage = SelectionMemoryStorage(), platform = PushFixture();
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'DELETE') return http.Response('', 202);
      if (r.method == 'PUT') {
        return http.Response(
            jsonEncode({
              'installationId': r.url.pathSegments.last,
              'provider': 'ALIYUN',
              'platform': 'ANDROID',
              'notificationConsent': true,
              'permissionGranted': true,
              'deliveryVerified': false
            }),
            200);
      }
      return http.Response(
          jsonEncode(r.url.path.endsWith('push-readiness')
              ? readiness
              : {...prefs, 'enabled': true}),
          200);
    })));
    addTearDown(session.dispose);
    final c = FamilyNotificationCoordinator(
        session: session, storage: storage, platform: platform);
    addTearDown(c.dispose);
    await c.load();
    await c.enableOnDevice();
    expect(await c.beforeScopeChange(), false);
    expect(platform.guard, null);
    expect(c.revocationPending, true);
    expect(storage.values, isNotEmpty);
  });
  test(
      'server membership denial clears cached readiness without deleting original installation journal',
      () async {
    var authorized = true;
    final storage = SelectionMemoryStorage(), platform = PushFixture();
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (!authorized) {
        return http.Response('{"errorCode":"SCOPE_DENIED"}', 403);
      }
      if (r.method == 'PUT') {
        return http.Response(
            jsonEncode({
              'installationId': r.url.pathSegments.last,
              'provider': 'ALIYUN',
              'platform': 'ANDROID',
              'notificationConsent': true,
              'permissionGranted': true,
              'deliveryVerified': false
            }),
            200);
      }
      return http.Response(
          jsonEncode(r.url.path.endsWith('push-readiness')
              ? readiness
              : {...prefs, 'enabled': true}),
          200);
    })));
    addTearDown(session.dispose);
    final c = FamilyNotificationCoordinator(
        session: session, storage: storage, platform: platform);
    addTearDown(c.dispose);
    await c.load();
    await c.enableOnDevice();
    final original = Map.of(storage.values);
    expect(c.deviceRegistered, true);
    authorized = false;
    await expectLater(c.load(), throwsA(isA<ParentApiException>()));
    expect(c.loaded, false);
    expect(c.preferences, null);
    expect(c.readiness, null);
    expect(c.deviceRegistered, false);
    expect(storage.values, original);
    expect(platform.guard, null);
    await expectLater(c.enableOnDevice(), throwsA(isA<ParentApiException>()));
    expect(platform.registrations, 1);
    expect(platform.permissionRequests, 1);
  });
}
