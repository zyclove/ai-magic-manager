import 'dart:convert';
import 'dart:io';
import 'package:device_access/device_access.dart';
import 'package:sembast/sembast_memory.dart';

void require(bool condition) {
  if (!condition) throw StateError('Backend access interoperability mismatch');
}

Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('Provide a public fixture path');
  final json = jsonDecode(await File(args.single).readAsString())
      as Map<String, dynamic>;
  var now = 1791528000000;
  var hasBase = false;
  final verifier = AccessWindowVerifier(
      scope: const DeviceAccessScope(
          issuer: 'ai-manager',
          tenantId: '11111111-1111-4111-8111-111111111111',
          subjectId: '77777777-7777-4777-8777-777777777777',
          deviceId: '22222222-2222-4222-8222-222222222222',
          registrationId: '33333333-3333-4333-8333-333333333333'),
      trustedKeys: json['publicKeys'],
      nowMillis: () => now);
  final database = await databaseFactoryMemory.openDatabase('access-nimbus');
  final journal = AccessWindowJournal(
      database: database, verifier: verifier, baselineMatches: (_) => hasBase);
  try {
    final first =
        await journal.accept(AccessDocument.fromJson(json['approved']));
    require(
        first.phase == 'REJECTED' && first.reasonCode == 'BASELINE_MISSING');
    require(await journal.acknowledge(
        AccessReceiptAcknowledgement.fromJson(json['rejectionAck'])));
    hasBase = true;
    final second = await journal.accept(AccessDocument.fromJson(json['retry']));
    require(second.phase == 'STORED' && second.deliveryAttempt == 2);
    require(await journal
        .acknowledge(AccessReceiptAcknowledgement.fromJson(json['storedAck'])));
    final active = (await journal.restore()).values.single;
    require(active.absoluteNotAfter == 1791528299000 && !active.systemEnforced);
    now += 86400000;
    require((await journal.restore()).isEmpty);
    final removal =
        await journal.accept(AccessDocument.fromJson(json['removed']));
    require(removal.phase == 'STORED' && removal.approvalVersion == 2);
    require(await journal.acknowledge(
        AccessReceiptAcknowledgement.fromJson(json['removalAck'])));
    require((await journal.restore()).isEmpty &&
        (await journal.pendingReceipts()).isEmpty);
    try {
      await journal.accept(AccessDocument.fromJson(json['approved']));
      throw StateError('Stale approval restored after removal');
    } on AccessFailure catch (failure) {
      require(failure.code == 'STALE_APPROVAL');
    }
    stdout.writeln(
        'PASS actual backend Envelope/Document/Receipt records, Nimbus ES256, '
        'baseline recovery, fixed expiry, revocation watermark and correlated ACKs. '
        'CONFIGURE_ONLY; no HTTP or native execution asserted.');
  } finally {
    await database.close();
  }
}
