import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family_account_security.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';

const operation = '91bc0b83-909d-4cca-9a7d-cb775f9a917e';

Map<String, dynamic> accountStatus({
  String subject = 'adult',
  int revision = 1,
  String? receipt,
  String? action,
}) =>
    {
      'subject': subject,
      'phoneMasked': '138****1234',
      'phoneVerified': true,
      'wechatBound': true,
      'identityRevision': revision,
      'sessionCurrent': true,
      'accountSecurityAvailable': true,
      'canChangePhone': true,
      'canBindWechat': false,
      'canUnbindWechat': true,
      'canRecoverByWechat': true,
      'lastOperationId': receipt,
      'lastOperationAction': action,
      'lastOperationAt': receipt == null ? null : 1792108800000,
    };

class AccountMemoryStorage extends ParentDurableStorage {
  String? value;
  bool failWrite = false;
  bool failDelete = false;
  final writes = <String>[];

  @override
  Future<String?> read({required String key}) async => value;
  @override
  Future<void> write({required String key, required String value}) async {
    if (failWrite) throw StateError('fixture storage unavailable');
    writes.add(value);
    this.value = value;
  }

  @override
  Future<void> delete({required String key}) async {
    if (failDelete) throw StateError('fixture delete unavailable');
    value = null;
  }
}

class _DelayedDeleteStorage extends AccountMemoryStorage {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> delete({required String key}) async {
    await super.delete(key: key);
    started.complete();
    await release.future;
  }
}

ParentApi accountApi(Future<http.Response> Function(http.Request) handler) =>
    ParentApi(() async => 'fixture',
        baseUrl: 'https://identity.invalid/consumer-account',
        client: MockClient(handler));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('operation reference is durable before secure identity flow starts',
      () async {
    final storage = AccountMemoryStorage();
    final data = accountStatus();
    var actionCalls = 0;
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi((request) async => http.Response(jsonEncode(data), 200)),
      identity: () => const FamilyAccountIdentity('adult', 0, true),
      storage: storage,
      createOperationId: () => operation,
      runAction: (
          {required action,
          required operationId,
          expectedRevision,
          expectedActor}) async {
        actionCalls++;
        final saved = jsonDecode(storage.value!) as Map;
        expect(saved['operationId'], operation);
        expect(saved['actor'], 'adult');
        expect(saved['expectedRevision'], 1);
        expect(saved.keys.toSet(), {
          'schema',
          'action',
          'operationId',
          'actor',
          'expectedRevision',
          'createdAt'
        });
        expect(expectedActor, 'adult');
        expect(expectedRevision, 1);
        data.addAll(accountStatus(
            revision: 2, receipt: operation, action: 'CHANGE_PHONE'));
        return true;
      },
    );
    addTearDown(controller.dispose);
    await controller.restore();
    await controller.perform('CHANGE_PHONE');
    expect(actionCalls, 1);
    expect(controller.completedAction, 'CHANGE_PHONE');
    expect(controller.pending, isNull);
    expect(storage.value, isNull);
  });

  test('storage failure stops the identity flow before authorization',
      () async {
    final storage = AccountMemoryStorage()..failWrite = true;
    var calls = 0;
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi(
          (_) async => http.Response(jsonEncode(accountStatus()), 200)),
      identity: () => const FamilyAccountIdentity('adult', 0, true),
      storage: storage,
      runAction: (
          {required action,
          required operationId,
          expectedRevision,
          expectedActor}) async {
        calls++;
        return true;
      },
    );
    addTearDown(controller.dispose);
    await controller.restore();
    await controller.perform('CHANGE_PHONE');
    expect(calls, 0);
    expect(controller.completedAction, isNull);
    expect(controller.storageFailed, isTrue);
  });

  test('cancellation never proves no change and cannot replay the operation',
      () async {
    final storage = AccountMemoryStorage();
    var calls = 0;
    final requests = <String>[];
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi((request) async {
        requests.add(request.method);
        return http.Response(jsonEncode(accountStatus()), 200);
      }),
      identity: () => const FamilyAccountIdentity('adult', 0, true),
      storage: storage,
      createOperationId: () => operation,
      runAction: (
          {required action,
          required operationId,
          expectedRevision,
          expectedActor}) async {
        calls++;
        return false;
      },
    );
    addTearDown(controller.dispose);
    await controller.restore();
    await controller.perform('CHANGE_PHONE');
    await controller.perform('CHANGE_PHONE');
    await controller.refresh();
    expect(calls, 1);
    expect(controller.pending?.operationId, operation);
    expect(controller.completedAction, isNull);
    expect(requests.every((method) => method == 'GET'), isTrue);
  });

  test('same-actor generation change requires a fresh receipt read', () async {
    final storage = AccountMemoryStorage();
    var identity = const FamilyAccountIdentity('adult', 0, true);
    final data = accountStatus();
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi((_) async => http.Response(jsonEncode(data), 200)),
      identity: () => identity,
      storage: storage,
      createOperationId: () => operation,
      runAction: (
          {required action,
          required operationId,
          expectedRevision,
          expectedActor}) async {
        identity = const FamilyAccountIdentity('adult', 1, true);
        data.addAll(accountStatus(
            revision: 2, receipt: operation, action: 'UNBIND_WECHAT'));
        data.addAll({
          'wechatBound': false,
          'canBindWechat': true,
          'canUnbindWechat': false,
          'canRecoverByWechat': false
        });
        return true;
      },
    );
    addTearDown(controller.dispose);
    await controller.restore();
    await controller.perform('UNBIND_WECHAT');
    expect(controller.completedAction, 'UNBIND_WECHAT');
    expect(controller.pending, isNull);
  });

  test('background reply is discarded and resumed state is read again',
      () async {
    final reply = Completer<http.Response>();
    var reads = 0;
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi((_) async {
        reads++;
        if (reads == 1) return reply.future;
        return http.Response(jsonEncode(accountStatus(revision: 2)), 200);
      }),
      identity: () => const FamilyAccountIdentity('adult', 0, true),
      storage: AccountMemoryStorage(),
      runAction: (
              {required action,
              required operationId,
              expectedRevision,
              expectedActor}) async =>
          false,
    );
    addTearDown(controller.dispose);
    final reading = controller.restore();
    await Future<void>.delayed(Duration.zero);
    controller.setForeground(false);
    reply.complete(http.Response(jsonEncode(accountStatus()), 200));
    await reading;
    expect(controller.status, isNull);
    controller.setForeground(true);
    await controller.refresh();
    expect(controller.status?.identityRevision, 2);
  });

  test('another account cannot receive an old account status', () async {
    var identity = const FamilyAccountIdentity('adult', 0, true);
    final reply = Completer<http.Response>();
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi((_) async => reply.future),
      identity: () => identity,
      storage: AccountMemoryStorage(),
      runAction: (
              {required action,
              required operationId,
              expectedRevision,
              expectedActor}) async =>
          false,
    );
    addTearDown(controller.dispose);
    final reading = controller.restore();
    await Future<void>.delayed(Duration.zero);
    identity = const FamilyAccountIdentity('other-adult', 1, true);
    controller.identityChanged();
    reply.complete(http.Response(jsonEncode(accountStatus()), 200));
    await reading;
    expect(controller.status, isNull);
  });

  test('a receipt with different action cannot confirm the operation',
      () async {
    final storage = AccountMemoryStorage();
    final data = accountStatus();
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi((_) async => http.Response(jsonEncode(data), 200)),
      identity: () => const FamilyAccountIdentity('adult', 0, true),
      storage: storage,
      createOperationId: () => operation,
      runAction: (
          {required action,
          required operationId,
          expectedRevision,
          expectedActor}) async {
        data.addAll(accountStatus(
            revision: 2, receipt: operation, action: 'BIND_WECHAT'));
        return true;
      },
    );
    addTearDown(controller.dispose);
    await controller.restore();
    await controller.perform('CHANGE_PHONE');
    expect(controller.completedAction, isNull);
    expect(controller.pending, isNotNull);
    expect(controller.canAcknowledgeCurrentState, isTrue);
    await controller.acknowledgeCurrentState();
    expect(controller.pending, isNull);
    expect(controller.completedAction, isNull);
  });

  test('logged-out recovery never queries status until login succeeds',
      () async {
    var identity = const FamilyAccountIdentity(null, 0, false);
    var reads = 0;
    final storage = AccountMemoryStorage();
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi((_) async {
        reads++;
        return http.Response(
            jsonEncode(accountStatus(
                revision: 2, receipt: operation, action: 'RECOVER_PHONE')),
            200);
      }),
      identity: () => identity,
      storage: storage,
      createOperationId: () => operation,
      runAction: (
          {required action,
          required operationId,
          expectedRevision,
          expectedActor}) async {
        expect(action, 'RECOVER_PHONE');
        expect(expectedActor, isNull);
        expect(expectedRevision, isNull);
        identity = const FamilyAccountIdentity('adult', 1, true);
        return true;
      },
    );
    addTearDown(controller.dispose);
    await controller.restore();
    expect(reads, 0);
    await controller.perform('RECOVER_PHONE');
    expect(reads, 1);
    expect(controller.completedAction, 'RECOVER_PHONE');
  });

  test('status rejects raw phone, stale session and inconsistent permissions',
      () {
    for (final invalid in [
      {...accountStatus(), 'phoneMasked': '13800131234'},
      {...accountStatus(), 'sessionCurrent': false},
      {...accountStatus(), 'identityRevision': 0},
      {...accountStatus(), 'wechatBound': false},
      {...accountStatus(), 'canBindWechat': true},
      {...accountStatus(), 'lastOperationId': operation},
      {...accountStatus(), 'accountSecurityAvailable': false},
    ]) {
      expect(() => FamilyAccountStatus.fromJson(invalid),
          throwsA(isA<ParentApiException>()));
    }
  });

  test('old journal waits a fresh 30 minutes after restore before ending',
      () async {
    var clock = DateTime.utc(2026, 10, 16, 4);
    var unavailable = false;
    final storage = AccountMemoryStorage()
      ..value = jsonEncode(FamilyAccountPending(
              action: 'CHANGE_PHONE',
              operationId: operation,
              actor: 'adult',
              expectedRevision: 1,
              createdAt: clock
                  .subtract(const Duration(hours: 3))
                  .millisecondsSinceEpoch)
          .toJson());
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi((_) async => unavailable
          ? http.Response('{"errorCode":"UNAVAILABLE"}', 503)
          : http.Response(jsonEncode(accountStatus()), 200)),
      identity: () => const FamilyAccountIdentity('adult', 0, true),
      storage: storage,
      now: () => clock,
      runAction: (
              {required action,
              required operationId,
              expectedRevision,
              expectedActor}) async =>
          false,
    );
    addTearDown(controller.dispose);
    await controller.restore();
    expect(controller.canAcknowledgeCurrentState, isFalse);
    clock = clock.add(const Duration(minutes: 30));
    expect(controller.canAcknowledgeCurrentState, isFalse,
        reason:
            'A prior successful read cannot establish current state later.');
    unavailable = true;
    await controller.refresh();
    expect(controller.canAcknowledgeCurrentState, isFalse);
    unavailable = false;
    await controller.refresh();
    expect(controller.canAcknowledgeCurrentState, isTrue);
    await controller.acknowledgeCurrentState();
    expect(controller.pending, isNull);
    expect(controller.completedAction, isNull);
  });

  test('process restart resets the conservative wait for a pending operation',
      () async {
    var clock = DateTime.utc(2026, 10, 16, 4);
    final storage = AccountMemoryStorage()
      ..value = jsonEncode(FamilyAccountPending(
              action: 'CHANGE_PHONE',
              operationId: operation,
              actor: 'adult',
              expectedRevision: 1,
              createdAt: clock
                  .subtract(const Duration(days: 1))
                  .millisecondsSinceEpoch)
          .toJson());
    FamilyAccountSecurityCoordinator create() =>
        FamilyAccountSecurityCoordinator(
          api: accountApi(
              (_) async => http.Response(jsonEncode(accountStatus()), 200)),
          identity: () => const FamilyAccountIdentity('adult', 0, true),
          storage: storage,
          now: () => clock,
          runAction: (
                  {required action,
                  required operationId,
                  expectedRevision,
                  expectedActor}) async =>
              false,
        );
    final first = create();
    await first.restore();
    clock = clock.add(const Duration(minutes: 29));
    first.dispose();
    final second = create();
    addTearDown(second.dispose);
    await second.restore();
    clock = clock.add(const Duration(minutes: 1));
    await second.refresh();
    expect(second.canAcknowledgeCurrentState, isFalse);
    clock = clock.add(const Duration(minutes: 29));
    await second.refresh();
    expect(second.canAcknowledgeCurrentState, isTrue);
  });

  test(
      'unauthenticated recovery can end after conservative wait and fresh login',
      () async {
    var clock = DateTime.utc(2026, 10, 16, 4);
    var identity = const FamilyAccountIdentity(null, 0, false);
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi(
          (_) async => http.Response(jsonEncode(accountStatus()), 200)),
      identity: () => identity,
      storage: AccountMemoryStorage(),
      now: () => clock,
      runAction: (
              {required action,
              required operationId,
              expectedRevision,
              expectedActor}) async =>
          false,
    );
    addTearDown(controller.dispose);
    await controller.restore();
    await controller.perform('RECOVER_PHONE');
    clock = clock.add(const Duration(minutes: 30));
    expect(controller.canAcknowledgeCurrentState, isFalse);
    identity = const FamilyAccountIdentity('adult', 1, true);
    controller.identityChanged();
    await controller.refresh();
    expect(controller.canAcknowledgeCurrentState, isTrue);
    await controller.acknowledgeCurrentState();
    expect(controller.pending, isNull);
    expect(controller.completedAction, isNull);
  });

  test('trusted native preflight cancellation can clear an unstarted operation',
      () async {
    final storage = AccountMemoryStorage();
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi(
          (_) async => http.Response(jsonEncode(accountStatus()), 200)),
      identity: () => const FamilyAccountIdentity('adult', 0, true),
      storage: storage,
      runAction: (
              {required action,
              required operationId,
              expectedRevision,
              expectedActor}) async =>
          throw const ParentApiException(400, 'ACCOUNT_OPERATION_NOT_STARTED'),
    );
    addTearDown(controller.dispose);
    await controller.restore();
    await controller.perform('BIND_WECHAT');
    // Already-bound fixtures disallow bind; test the allowed phone-change path.
    await controller.perform('CHANGE_PHONE');
    expect(controller.pending, isNull);
    expect(storage.value, isNull);
    expect(controller.completedAction, isNull);
    expect(controller.canPerform('CHANGE_PHONE'), isTrue);
  });

  test('failure deleting a proven receipt keeps the journal and no success',
      () async {
    final storage = AccountMemoryStorage()..failDelete = true;
    final data = accountStatus();
    var launches = 0;
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi((_) async => http.Response(jsonEncode(data), 200)),
      identity: () => const FamilyAccountIdentity('adult', 0, true),
      storage: storage,
      createOperationId: () => operation,
      runAction: (
          {required action,
          required operationId,
          expectedRevision,
          expectedActor}) async {
        launches++;
        data.addAll(accountStatus(
            revision: 2, receipt: operation, action: 'CHANGE_PHONE'));
        return true;
      },
    );
    addTearDown(controller.dispose);
    await controller.restore();
    await controller.perform('CHANGE_PHONE');
    expect(controller.pending, isNotNull);
    expect(controller.completedAction, isNull);
    storage.failDelete = false;
    await controller.refresh();
    expect(controller.pending, isNull);
    expect(controller.completedAction, 'CHANGE_PHONE');
    expect(launches, 1);
  });

  test('two pages cannot authorize different operations over one journal',
      () async {
    final storage = AccountMemoryStorage();
    final authorization = Completer<bool>();
    var launches = 0;
    FamilyAccountSecurityCoordinator create() =>
        FamilyAccountSecurityCoordinator(
          api: accountApi(
              (_) async => http.Response(jsonEncode(accountStatus()), 200)),
          identity: () => const FamilyAccountIdentity('adult', 0, true),
          storage: storage,
          runAction: (
              {required action,
              required operationId,
              expectedRevision,
              expectedActor}) async {
            launches++;
            return authorization.future;
          },
        );
    final first = create(), second = create();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await first.restore();
    await second.restore();
    final a = first.perform('CHANGE_PHONE');
    final b = second.perform('UNBIND_WECHAT');
    await Future<void>.delayed(Duration.zero);
    expect(launches, 1);
    authorization.complete(false);
    await Future.wait([a, b]);
    expect(storage.value, isNotNull);
  });

  test('scope change during successful journal deletion cannot strand the page',
      () async {
    final storage = _DelayedDeleteStorage();
    var identity = const FamilyAccountIdentity('adult', 0, true);
    final data = accountStatus();
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi((_) async => http.Response(jsonEncode(data), 200)),
      identity: () => identity,
      storage: storage,
      createOperationId: () => operation,
      runAction: (
          {required action,
          required operationId,
          expectedRevision,
          expectedActor}) async {
        data.addAll(accountStatus(
            revision: 2, receipt: operation, action: 'CHANGE_PHONE'));
        return true;
      },
    );
    addTearDown(controller.dispose);
    await controller.restore();
    final changing = controller.perform('CHANGE_PHONE');
    await storage.started.future;
    identity = const FamilyAccountIdentity('adult', 1, true);
    controller.identityChanged();
    storage.release.complete();
    await changing;
    expect(controller.completedAction, isNull);
    await controller.refresh();
    expect(controller.pending, isNull);
    expect(controller.completedAction, isNull);
    expect(controller.canPerform('CHANGE_PHONE'), isTrue);
  });

  test(
      'a local release gate keeps mutations disabled despite server capability',
      () async {
    final controller = FamilyAccountSecurityCoordinator(
      api: accountApi(
          (_) async => http.Response(jsonEncode(accountStatus()), 200)),
      identity: () => const FamilyAccountIdentity('adult', 0, true),
      storage: AccountMemoryStorage(),
      actionsAvailable: false,
      runAction: (
              {required action,
              required operationId,
              expectedRevision,
              expectedActor}) async =>
          true,
    );
    addTearDown(controller.dispose);
    await controller.restore();
    expect(controller.status, isNotNull);
    expect(controller.canPerform('CHANGE_PHONE'), isFalse);
    expect(controller.canPerform('UNBIND_WECHAT'), isFalse);
  });

  for (final action in ['BIND_WECHAT', 'UNBIND_WECHAT']) {
    test('$action contradictory WeChat receipt cannot report success',
        () async {
      final storage = AccountMemoryStorage();
      final initiallyBound = action == 'UNBIND_WECHAT';
      final data = {
        ...accountStatus(),
        'wechatBound': initiallyBound,
        'canBindWechat': !initiallyBound,
        'canUnbindWechat': initiallyBound,
        'canRecoverByWechat': initiallyBound,
      };
      final controller = FamilyAccountSecurityCoordinator(
        api: accountApi((_) async => http.Response(jsonEncode(data), 200)),
        identity: () => const FamilyAccountIdentity('adult', 0, true),
        storage: storage,
        createOperationId: () => operation,
        runAction: (
            {required action,
            required operationId,
            expectedRevision,
            expectedActor}) async {
          data.addAll({
            'identityRevision': 2,
            'lastOperationId': operation,
            'lastOperationAction': action,
            'lastOperationAt': 1792108800000
          });
          return true;
        },
      );
      addTearDown(controller.dispose);
      await controller.restore();
      await controller.perform(action);
      expect(controller.completedAction, isNull);
      expect(controller.pending?.operationId, operation);
      expect(storage.value, isNotNull);
      expect(controller.status, isNull);
      expect(
          controller.error,
          isA<ParentApiException>().having((failure) => failure.code, 'code',
              'INVALID_ACCOUNT_SECURITY_RESPONSE'));
    });
  }
}
