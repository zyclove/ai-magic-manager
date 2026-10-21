import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';
import 'family_workspace_test.dart' show FamilySession;

class TestAuth extends FlutterAppAuth {
  int calls = 0;
  @override
  Future<AuthorizationTokenResponse> authorizeAndExchangeCode(
      AuthorizationTokenRequest request) async {
    calls++;
    return AuthorizationTokenResponse(
        'fixture-$calls',
        'refresh-$calls',
        DateTime.now().add(const Duration(hours: 1)),
        null,
        'Bearer', [], {}, {});
  }
}

class ConfiguredSession extends ParentSession {
  ConfiguredSession({required super.appAuth, required super.client});
  @override
  bool get configured => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final writes = <String>[];
  setUp(() {
    writes.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
      writes.add(call.method);
      return null;
    });
  });
  FamilySession fixture(List<String> events) {
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      events.add('membership');
      return http.Response(jsonEncode({'role': 'GUARDIAN'}), 200);
    })));
    session.tenants = [
      session.tenant!,
      {'id': 'other', 'kind': 'FAMILY'}
    ];
    addTearDown(session.dispose);
    return session;
  }

  test('scope guard finishes using original identity before changing family',
      () async {
    final events = <String>[];
    final session = fixture(events);
    final gate = Completer<void>();
    session.beforeIdentityChange = () async {
      events.add('guard');
      expect(session.tenant!['id'], 'family');
      expect(session.generation, 0);
      await gate.future;
    };
    final operation = session.selectTenant(session.tenants.last);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['guard']);
    expect(writes, isEmpty);
    gate.complete();
    await operation;
    expect(events, ['guard', 'membership']);
    expect(session.tenant!['id'], 'other');
  });
  test('local notification guard failure preserves identity and credentials',
      () async {
    final events = <String>[];
    final session = fixture(events);
    session.beforeIdentityChange =
        () async => throw StateError('local guard unavailable');
    await expectLater(
        session.selectTenant(session.tenants.last), throwsStateError);
    expect(events, isEmpty);
    expect(session.tenant!['id'], 'family');
    expect(session.generation, 0);
    await expectLater(session.signOut(), throwsStateError);
    expect(session.profile!['subject'], 'adult');
    expect(writes, isEmpty);
  });
  test(
      'logout disables local notification before deleting the current identity',
      () async {
    final events = <String>[];
    final session = fixture(events);
    session.beforeIdentityChange = () async {
      expect(session.profile!['subject'], 'adult');
      expect(writes, isEmpty);
      events.add('guard');
    };
    await session.signOut();
    expect(events, ['guard']);
    expect(session.profile, isNull);
    expect(writes, ['delete', 'delete']);
  });
  test(
      'failed membership lookup republishes the unchanged family after scope invalidation',
      () async {
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient(
            (r) async => http.Response('{"errorCode":"UNAVAILABLE"}', 503))));
    addTearDown(session.dispose);
    session.tenants = [
      session.tenant!,
      {'id': 'other', 'kind': 'FAMILY'}
    ];
    var notifications = 0;
    session.addListener(() => notifications++);
    session.beforeIdentityChange = () async {};
    await expectLater(session.selectTenant(session.tenants.last),
        throwsA(isA<ParentApiException>()));
    expect(session.tenant!['id'], 'family');
    expect(session.generation, 1);
    expect(notifications, 1);
  });
  test(
      'unexpected step-up actor remains quarantined even if native shutdown fails',
      () async {
    var actor = 'adult';
    final auth = TestAuth();
    final session = ConfiguredSession(
        appAuth: auth,
        client: MockClient((r) async => http.Response(
            jsonEncode(r.url.path == '/me'
                ? {'subject': actor}
                : r.url.path == '/tenants'
                    ? {'items': []}
                    : {}),
            200)));
    addTearDown(session.dispose);
    expect(await session.signIn(), isTrue);
    expect(session.authenticated, isTrue);
    actor = 'other-adult';
    session.beforeIdentityChange =
        () async => throw StateError('local guard unavailable');
    await expectLater(session.reauthenticate(), throwsStateError);
    expect(session.authenticated, isFalse);
    expect(session.profile!['subject'], 'adult');
    await expectLater(session.token(), throwsA(isA<ParentApiException>()));
    await expectLater(session.signIn(), throwsStateError);
    expect(auth.calls, 2);
  });
}
