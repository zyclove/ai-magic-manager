import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_session.dart';

class AccountAuth extends FlutterAppAuth {
  final requests = <AuthorizationTokenRequest>[];
  Completer<void>? wait;
  @override
  Future<AuthorizationTokenResponse> authorizeAndExchangeCode(
      AuthorizationTokenRequest request) async {
    requests.add(request);
    await wait?.future;
    return AuthorizationTokenResponse(
        'access',
        'refresh',
        DateTime.now().add(const Duration(hours: 1)),
        null,
        'Bearer', [], {}, {});
  }
}

class AccountSession extends ParentSession {
  AccountSession({required super.appAuth, required super.client});
  @override
  bool get configured => true;
  @override
  bool get accountSecurityEnabled => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const operation = '52c27e88-3b77-4874-b78d-912284d9442a';
  final writes = <String, String?>{};
  late AccountAuth auth;
  late AccountSession session;
  var actor = 'original-adult';
  setUp(() {
    writes.clear();
    actor = 'original-adult';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
      if (call.method == 'write') {
        writes[call.arguments['key'] as String] =
            call.arguments['value'] as String?;
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.aimanager.parent/auth'),
            (_) async => 'one-use-wechat-code');
    auth = AccountAuth();
    session = AccountSession(
        appAuth: auth,
        client: MockClient((request) async => http.Response(
            jsonEncode(request.url.path.endsWith('/me')
                ? {'subject': actor}
                : {'items': []}),
            200)));
    addTearDown(session.dispose);
  });
  Future<void> login() async {
    expect(await session.signIn(), isTrue);
    auth.requests.clear();
  }

  test(
      'phone change fixes actor revision operation and forces fresh browser auth',
      () async {
    await login();
    var shutdowns = 0;
    session.beforeIdentityChange = () async => shutdowns++;
    expect(
        await session.runAccountAction(
            action: 'CHANGE_PHONE',
            operationId: operation,
            expectedRevision: 2,
            expectedActor: 'original-adult'),
        isTrue);
    expect(shutdowns, 1);
    expect(session.accountActionMayHaveStarted, isTrue);
    final params = auth.requests.single.additionalParameters!;
    expect(params['family_account_action'], 'CHANGE_PHONE');
    expect(params['family_account_operation'], operation);
    expect(params['family_account_actor'], 'original-adult');
    expect(params['family_account_revision'], '2');
    expect(params['max_age'], '0');
    expect(params, isNot(contains('kc_idp_hint')));
    expect(session.profile?['subject'], 'original-adult');
    expect(writes.values.any((v) => v?.contains('one-use-wechat') ?? false),
        isFalse);
  });

  test('invalid action identifiers and another actor never open secure flow',
      () async {
    await login();
    for (final arguments in [
      ('DELETE_ACCOUNT', operation, 1, 'original-adult'),
      ('CHANGE_PHONE', 'bad-id', 1, 'original-adult'),
      ('UNBIND_WECHAT', operation, 0, 'original-adult'),
      ('CHANGE_PHONE', operation, 1, 'another-adult'),
    ]) {
      expect(
          await session.runAccountAction(
              action: arguments.$1,
              operationId: arguments.$2,
              expectedRevision: arguments.$3,
              expectedActor: arguments.$4),
          isFalse);
    }
    expect(auth.requests, isEmpty);
  });

  test('signed out phone changes cannot be launched', () async {
    expect(
        await session.runAccountAction(
            action: 'CHANGE_PHONE',
            operationId: operation,
            expectedRevision: 1,
            expectedActor: actor),
        isFalse);
    expect(auth.requests, isEmpty);
  });

  test('account recovery carries fresh native WeChat code only in RAM',
      () async {
    expect(
        await session.runAccountAction(
            action: 'RECOVER_PHONE', operationId: operation),
        isTrue);
    final params = auth.requests.single.additionalParameters!;
    expect(params['family_account_action'], 'RECOVER_PHONE');
    expect(params['family_wechat_code'], 'one-use-wechat-code');
    expect(params, isNot(contains('family_account_revision')));
    expect(writes.values, isNot(contains('one-use-wechat-code')));
    auth.requests.clear();
    expect(await session.signIn(), isTrue);
    expect(auth.requests.single.additionalParameters,
        isNot(contains('family_account_action')));
    expect(auth.requests.single.additionalParameters,
        isNot(contains('family_wechat_code')));
  });

  test('unknown native outcome does not dispatch binding or retain code',
      () async {
    await login();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.aimanager.parent/auth'),
            (_) async => throw PlatformException(code: 'cancelled'));
    expect(
        await session.runAccountAction(
            action: 'BIND_WECHAT',
            operationId: operation,
            expectedRevision: 1,
            expectedActor: actor),
        isFalse);
    expect(auth.requests, isEmpty);
    expect(session.authenticated, isTrue);
    expect(session.busy, isFalse);
    expect(session.accountActionMayHaveStarted, isFalse);
  });

  test(
      'account action cannot publish a different actor returned by identity server',
      () async {
    await login();
    actor = 'other-adult';
    expect(
        await session.runAccountAction(
            action: 'UNBIND_WECHAT',
            operationId: operation,
            expectedRevision: 1,
            expectedActor: 'original-adult'),
        isFalse);
    expect(session.authenticated, isFalse);
  });

  test('sign out during native WeChat authorization prevents late operation',
      () async {
    await login();
    final code = Completer<String>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.aimanager.parent/auth'),
            (_) => code.future);
    final attempt = session.runAccountAction(
        action: 'BIND_WECHAT',
        operationId: operation,
        expectedRevision: 1,
        expectedActor: actor);
    await Future<void>.delayed(Duration.zero);
    await session.signOut();
    code.complete('late-code');
    expect(await attempt, isFalse);
    expect(auth.requests, isEmpty);
    expect(session.authenticated, isFalse);
  });

  test(
      'a busy rejection is scoped to its operation and preserves in-flight evidence',
      () async {
    await login();
    auth.wait = Completer<void>();
    final first = session.runAccountAction(
        action: 'CHANGE_PHONE',
        operationId: operation,
        expectedRevision: 1,
        expectedActor: actor);
    await Future<void>.delayed(Duration.zero);
    expect(session.accountActionMayHaveStartedFor(operation), isTrue);
    const another = 'e5882313-28a1-44d5-a6c3-e1818dc9bacc';
    expect(
        await session.runAccountAction(
            action: 'UNBIND_WECHAT',
            operationId: another,
            expectedRevision: 1,
            expectedActor: actor),
        isFalse);
    expect(session.accountActionMayHaveStartedFor(another), isFalse);
    expect(session.accountActionMayHaveStartedFor(operation), isTrue);
    auth.wait!.complete();
    expect(await first, isTrue);
  });

  test('a late account callback cannot clear a newer local workspace scope',
      () async {
    await login();
    auth.wait = Completer<void>();
    final attempt = session.runAccountAction(
        action: 'CHANGE_PHONE',
        operationId: operation,
        expectedRevision: 1,
        expectedActor: actor);
    await Future<void>.delayed(Duration.zero);
    session.generation++;
    session.tenant = {'id': 'new-scope', 'kind': 'FAMILY'};
    auth.wait!.complete();
    expect(await attempt, isFalse);
    expect(session.tenant?['id'], 'new-scope');
    expect(session.profile?['subject'], actor);
    expect(session.accountActionMayHaveStartedFor(operation), isTrue);
  });
}
