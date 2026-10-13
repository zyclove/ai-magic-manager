import 'dart:convert';
import 'package:device_cleanup/device_cleanup.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

Matcher failure(String code) =>
    isA<CleanupFailure>().having((e) => e.code, 'code', code);
void main() {
  late Fixture f;
  late MemoryStore store;
  late VerifiedCleanupCommand command;
  late CleanupReceiptJournal journal;
  setUp(() async {
    f = Fixture();
    store = MemoryStore();
    command = await f.verified();
    journal = f.journal(store);
    await journal.load(command);
  });
  Future<void> received() async {
    final r = await journal.prepare(CleanupReceiptStage.received);
    await journal.acknowledge(r, f.accepted(r));
  }

  test('same prepared receipt survives recreation and blocks another stage',
      () async {
    final r = await journal.prepare(CleanupReceiptStage.received);
    journal = f.journal(store);
    await journal.load(command);
    expect((await journal.prepare(CleanupReceiptStage.received)).body, r.body);
    await expectLater(
        journal.prepare(CleanupReceiptStage.failed,
            reasonCode: 'STORAGE_FAILURE'),
        throwsA(failure('CLEANUP_RECEIPT_PENDING')));
  });
  test('unknown durable write requires reread and retains original receipt',
      () async {
    store.failWrite = true;
    store.persistThenFail = true;
    await expectLater(journal.prepare(CleanupReceiptStage.received),
        throwsA(failure('CLEANUP_JOURNAL_UNAVAILABLE')));
    expect(() => journal.view, throwsA(failure('CLEANUP_JOURNAL_NOT_LOADED')));
    final saved = jsonDecode(store.value!) as Map<String, dynamic>;
    store.failWrite = false;
    await journal.load(command);
    expect((await journal.prepare(CleanupReceiptStage.received)).receiptId,
        saved['pendingId']);
  });
  test('read error exposes no private exception and invalidates memory',
      () async {
    store.failRead = true;
    await expectLater(
        journal.load(command), throwsA(failure('CLEANUP_JOURNAL_UNAVAILABLE')));
    expect(() => journal.view, throwsA(failure('CLEANUP_JOURNAL_NOT_LOADED')));
  });
  test('new command cannot replace a pending old command', () async {
    await journal.prepare(CleanupReceiptStage.received);
    final original = store.value;
    final changed = await f.verifier.verify(f.sign({'issuedAt': time - 2000}),
        operationId: operation, commandId: commandId, notAfter: time + 60000);
    await expectLater(
        journal.load(changed), throwsA(failure('CLEANUP_JOURNAL_INVALID')));
    expect(store.value, original);
  });
  test('clear or cleared receipt requires received acknowledgement', () async {
    await expectLater(journal.markLocalDataCleared(),
        throwsA(failure('CLEANUP_STAGE_INVALID')));
    await expectLater(journal.prepare(CleanupReceiptStage.agentDataCleared),
        throwsA(failure('CLEANUP_STAGE_INVALID')));
  });
  test('different receipt acknowledgement cannot advance journal', () async {
    final r = await journal.prepare(CleanupReceiptStage.received);
    final different =
        CleanupReceipt(command, tenant, CleanupReceiptStage.received);
    await expectLater(journal.acknowledge(r, f.accepted(different)),
        throwsA(failure('CLEANUP_ACK_INVALID')));
    expect(journal.view.pending!.receiptId, r.receiptId);
  });
  test(
      'completed encrypted record permits only final key recovery after expiry',
      () async {
    await received();
    await journal.markLocalDataCleared();
    final r = await journal.prepare(CleanupReceiptStage.agentDataCleared);
    expect(
        await CleanupReceiptJournal.finalKeyRemovalReady(
            scope: scope, commandHash: command.commandHash, store: store),
        isFalse);
    await journal.acknowledge(r, f.accepted(r));
    f.now = time + 86400000;
    expect(
        await CleanupReceiptJournal.finalKeyRemovalReady(
            scope: scope, commandHash: command.commandHash, store: store),
        isTrue);
    await expectLater(
        CleanupReceiptJournal.finalKeyRemovalReady(
            scope: scope, commandHash: '0' * 64, store: store),
        throwsA(failure('CLEANUP_JOURNAL_INVALID')));
  });
  for (final entry in <String, dynamic>{
    'schemaVersion': 2,
    'registrationId': tenant,
    'localDataCleared': true,
    'accepted': 'AGENT_DATA_CLEARED',
    'pendingStage': 'AGENT_DATA_CLEARED',
    'pendingReason': 'STORAGE_FAILURE',
    'extra': true
  }.entries) {
    test('restore refuses inconsistent ${entry.key}', () async {
      final record = jsonDecode(store.value!) as Map<String, dynamic>;
      record[entry.key] = entry.value;
      store.value = jsonEncode(record);
      await expectLater(
          journal.load(command), throwsA(failure('CLEANUP_JOURNAL_INVALID')));
      expect(
          () => journal.view, throwsA(failure('CLEANUP_JOURNAL_NOT_LOADED')));
    });
  }
  test('expired command cannot prepare a new stage', () async {
    await received();
    f.now = time + 60000;
    await expectLater(
        journal.prepare(CleanupReceiptStage.failed,
            reasonCode: 'STORAGE_FAILURE'),
        throwsA(failure('CLEANUP_COMMAND_EXPIRED')));
  });
}
