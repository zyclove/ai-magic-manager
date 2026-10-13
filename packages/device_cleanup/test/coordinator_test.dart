import 'dart:async';
import 'package:device_cleanup/device_cleanup.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

Matcher failure(String code) =>
    isA<CleanupFailure>().having((e) => e.code, 'code', code);

void main() {
  late Fixture f;
  late TestServer server;
  late MemoryStore store;
  late TestExecutor executor;
  CleanupCoordinator coordinator({TestExecutor? host}) => CleanupCoordinator(
      client: server.client(),
      journal: f.journal(store),
      executor: host ?? executor);
  setUp(() {
    f = Fixture();
    server = TestServer(f);
    store = MemoryStore();
    executor = TestExecutor();
  });

  test('persist received and cleared acknowledgements before advancing',
      () async {
    server.beforeAck = (body) async {
      expect(store.value, contains(body['receiptId']));
      expect(executor.removals, 0);
      expect(executor.clears, body['stage'] == 'RECEIVED' ? 0 : 1);
    };
    expect(await coordinator().runOnce(), CleanupRunStage.keyRemoved);
    expect(server.receipts.map((r) => r['stage']),
        ['RECEIVED', 'AGENT_DATA_CLEARED']);
    expect(executor.clears, 1);
    expect(executor.removals, 1);
    expect(
        await CleanupReceiptJournal.finalKeyRemovalReady(
            scope: scope,
            commandHash: (await f.verifier.verify(server.signed,
                    operationId: operation,
                    commandId: commandId,
                    notAfter: time + 60000))
                .commandHash,
            store: store),
        isTrue);
  });

  for (final stage in ['RECEIVED', 'AGENT_DATA_CLEARED']) {
    test(
        'unknown $stage replays same durable body after coordinator replacement',
        () async {
      server.loseStage = stage;
      await expectLater(coordinator().runOnce(),
          throwsA(failure('CLEANUP_NETWORK_UNAVAILABLE')));
      expect(executor.removals, 0);
      final original = server.receipts.last;
      final before = server.receipts.length;
      expect(await coordinator().runOnce(), CleanupRunStage.keyRemoved);
      expect(server.receipts[before], original);
      expect(executor.clears, 1);
      expect(executor.removals, 1);
    });
  }

  test('unknown local error reports fixed reason and never removes key',
      () async {
    executor.clearError = StateError('private path and credential');
    expect(await coordinator().runOnce(), CleanupRunStage.localClearFailed);
    expect(server.receipts.last['reasonCode'], 'STORAGE_FAILURE');
    expect(server.receipts.toString(), isNot(contains('credential')));
    expect(executor.removals, 0);
    executor.clearError = null;
    expect(await coordinator().runOnce(), CleanupRunStage.keyRemoved);
    expect(executor.clears, 2);
  });

  test('repeated local failure does not invent another failed receipt',
      () async {
    executor.clearError = AgentCleanupFailure('USER_ACTION_REQUIRED');
    await coordinator().runOnce();
    executor.clearError = AgentCleanupFailure('STORAGE_FAILURE');
    expect(await coordinator().runOnce(), CleanupRunStage.localClearFailed);
    expect(server.receipts.length, 2);
    expect(executor.removals, 0);
  });

  test('failed acknowledgement persistence blocks clear and permits recovery',
      () async {
    server.beforeAck = (body) async {
      if (body['stage'] == 'RECEIVED') {
        store.failWrite = true;
        store.persistThenFail = true;
      }
    };
    await expectLater(coordinator().runOnce(),
        throwsA(failure('CLEANUP_JOURNAL_UNAVAILABLE')));
    expect(executor.clears, 0);
    expect(executor.removals, 0);
    server.beforeAck = null;
    store.failWrite = false;
    expect(await coordinator().runOnce(), CleanupRunStage.keyRemoved);
    expect(executor.clears, 1);
  });

  test('failed final acknowledgement persistence blocks key deletion',
      () async {
    server.beforeAck = (body) async {
      if (body['stage'] == 'AGENT_DATA_CLEARED') {
        store.failWrite = true;
        store.persistThenFail = true;
      }
    };
    await expectLater(coordinator().runOnce(),
        throwsA(failure('CLEANUP_JOURNAL_UNAVAILABLE')));
    expect(executor.clears, 1);
    expect(executor.removals, 0);
    server.beforeAck = null;
    store.failWrite = false;
    expect(await coordinator().runOnce(), CleanupRunStage.keyRemoved);
    expect(executor.clears, 1);
    expect(executor.removals, 1);
  });

  test('same coordinator rejects overlap without new network activity',
      () async {
    executor.clearGate = Completer<void>();
    final c = coordinator();
    final first = c.runOnce();
    await executor.entered.future;
    try {
      await expectLater(
          c.runOnce(), throwsA(failure('CLEANUP_ALREADY_RUNNING')));
    } finally {
      executor.clearGate!.complete();
      await first;
    }
    expect(server.reads, 2);
  });

  test(
      'replacement coordinator rejects same registration while first clear is active',
      () async {
    executor.clearGate = Completer<void>();
    final first = coordinator().runOnce();
    await executor.entered.future;
    final replacement = TestExecutor();
    try {
      await expectLater(coordinator(host: replacement).runOnce(),
          throwsA(failure('CLEANUP_ALREADY_RUNNING')));
      expect(replacement.clears, 0);
      expect(replacement.removals, 0);
      expect(server.reads, 2);
    } finally {
      executor.clearGate!.complete();
      await first;
    }
  });

  test('deadline reached while receiving acknowledgement blocks local clear',
      () async {
    server.beforeAck = (body) async {
      f.now = time + 60000;
    };
    await expectLater(
        coordinator().runOnce(), throwsA(failure('CLEANUP_COMMAND_EXPIRED')));
    expect(executor.clears, 0);
    expect(executor.removals, 0);
  });

  test(
      'failed key removal retains final acknowledgement and releases ownership',
      () async {
    executor.removeError = StateError('native key removal failed');
    await expectLater(coordinator().runOnce(), throwsStateError);
    expect(executor.clears, 1);
    executor.removeError = null;
    expect(await coordinator().runOnce(), CleanupRunStage.keyRemoved);
    expect(executor.clears, 1);
    expect(executor.removals, 2);
    expect(server.receipts.length, 2);
  });

  test('different registration is not blocked by another cleanup', () async {
    executor.clearGate = Completer<void>();
    final first = coordinator().runOnce();
    await executor.entered.future;
    try {
      final other = Fixture(CleanupScope(
          tenant, device, '66666666-6666-4666-8666-666666666666', 'B' * 43));
      final host = TestExecutor();
      expect(
          await CleanupCoordinator(
                  client: TestServer(other).client(),
                  journal: other.journal(MemoryStore()),
                  executor: host)
              .runOnce(),
          CleanupRunStage.keyRemoved);
      expect(host.removals, 1);
    } finally {
      executor.clearGate!.complete();
      await first;
    }
  });
}
