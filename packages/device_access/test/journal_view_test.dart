import 'package:device_access/device_access.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:test/test.dart';
import 'fixtures.dart';
import 'journal_test.dart' show ack;

void main() {
  test(
      'inspection explains stored, receipt pending, expiry and removal without granting execution',
      () async {
    final db = await databaseFactoryMemory.openDatabase('inspection');
    addTearDown(db.close);
    final key = newKey();
    var clock = now;
    final journal = AccessWindowJournal(
        database: db,
        verifier: AccessWindowVerifier(
            scope: scope, trustedKeys: publicRing(key), nowMillis: () => clock),
        baselineMatches: (_) => true);
    final receipt = await journal.accept(transport(sign(key, envelope())));
    var entry = (await journal.inspect()).single;
    expect(entry.state, AccessEntryState.stored);
    expect(entry.pendingAcknowledgement, isTrue);
    expect(entry.window.systemEnforced, isFalse);
    await journal.acknowledge(ack(receipt));
    expect((await journal.inspect()).single.pendingAcknowledgement, isFalse);
    clock = now + 299000;
    expect((await journal.inspect()).single.state, AccessEntryState.expired);
    expect(await journal.restore(), isEmpty);
    final removal = envelope({
      'documentId': policy,
      'approvalVersion': 2,
      'action': 'REMOVE_ACCESS_WINDOW',
      'approvalState': 'REVOKED',
      'documentIssuedAt': clock
    });
    await journal.accept(transport(sign(key, removal), payload: removal));
    expect((await journal.inspect()).single.state, AccessEntryState.removed);
    expect(await journal.restore(), isEmpty);
  });
  test('inspection distinguishes changed baseline from a durable rejection',
      () async {
    final db = await databaseFactoryMemory.openDatabase('inspection-baseline');
    addTearDown(db.close);
    final key = newKey();
    var base = true;
    final journal = AccessWindowJournal(
        database: db,
        verifier: AccessWindowVerifier(
            scope: scope, trustedKeys: publicRing(key), nowMillis: () => now),
        baselineMatches: (_) => base);
    await journal.accept(transport(sign(key, envelope())));
    base = false;
    expect((await journal.inspect()).single.state,
        AccessEntryState.baselineMissing);
    final body = envelope({'documentId': version, 'requestId': application});
    await journal.accept(transport(sign(key, body), payload: body));
    expect(
        (await journal.inspect())
            .where((v) => v.state == AccessEntryState.rejected)
            .single
            .reasonCode,
        'BASELINE_MISSING');
    expect(await journal.restore(), isEmpty);
  });
}
