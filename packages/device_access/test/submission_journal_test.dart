import 'package:device_access/device_access.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:test/test.dart';
import 'fixtures.dart' as f;
import 'support/submission_fixture.dart' as sample;

void main() {
  const scope = DeviceAccessScope(
      issuer: 'test-issuer',
      tenantId: f.tenant,
      subjectId: f.subject,
      deviceId: f.device,
      registrationId: f.registration);
  late Database database;
  late AccessSubmissionJournal journal;
  var serial = 0;
  setUp(() async {
    database =
        await databaseFactoryMemory.openDatabase('submission-${++serial}');
    journal = AccessSubmissionJournal(database: database, scope: scope);
  });
  tearDown(() async => database.close());
  test(
      'prepare is durable before any send and restart retains exact private input',
      () async {
    await journal.prepareCreate(sample.input(),
        key: 'original-key', applicationName: '阅读', now: f.now);
    final reopened = AccessSubmissionJournal(database: database, scope: scope);
    final operation = (await reopened.inspect()).pending!;
    expect(operation.phase, SubmissionOperationPhase.prepared);
    expect(operation.key, 'original-key');
    expect(operation.input!.toJson(), sample.input().toJson());
    expect(operation.toString(), isNot(contains('继续阅读')));
    await expectLater(
        journal.prepareCreate(sample.input(),
            key: 'new-key', applicationName: '阅读', now: f.now),
        throwsA(isA<AccessFailure>()
            .having((e) => e.code, 'code', 'SUBMISSION_OPERATION_PENDING')));
  });
  test(
      'mark sent then response loss preserves unknown original key across reopen',
      () async {
    await journal.prepareCreate(sample.input(),
        key: 'key', applicationName: '阅读', now: f.now);
    await journal.markSending('key');
    final recovered = AccessSubmissionJournal(database: database, scope: scope);
    expect((await recovered.inspect()).pending!.phase,
        SubmissionOperationPhase.unknown);
    await expectLater(recovered.discardUnsentOrRejected('key'),
        throwsA(isA<AccessFailure>()));
    await recovered.complete(
        'key', AccessSubmission.fromJson(sample.submission()));
    final done = await recovered.inspect();
    expect(done.pending, isNull);
    expect(done.entries.single.value.id, f.request);
  });
  test('mismatched completion never clears the durable operation', () async {
    await journal.prepareCreate(sample.input(),
        key: 'key', applicationName: '阅读', now: f.now);
    await journal.markSending('key');
    await expectLater(
        journal.complete(
            'key',
            AccessSubmission.fromJson(
                sample.submission({'requestedWindowSeconds': 300}))),
        throwsA(isA<AccessFailure>()));
    expect((await journal.inspect()).pending!.key, 'key');
  });
  test('each subject and issuer has independent namespace', () async {
    await journal.prepareCreate(sample.input(),
        key: 'key', applicationName: '阅读', now: f.now);
    final other = AccessSubmissionJournal(
        database: database,
        scope: const DeviceAccessScope(
            issuer: 'other',
            tenantId: f.tenant,
            subjectId: f.subject,
            deviceId: f.device,
            registrationId: f.registration));
    expect((await other.inspect()).pending, isNull);
    await expectLater(
        journal.record(
            AccessSubmission.fromJson(
                sample.submission({'subjectId': f.document})),
            applicationName: '阅读'),
        throwsA(isA<AccessFailure>()));
  });
  test(
      'same version cannot change a fact and old versions cannot replace new facts',
      () async {
    final pending = AccessSubmission.fromJson(sample.submission());
    await journal.record(pending, applicationName: '阅读');
    await expectLater(
        journal.record(
            AccessSubmission.fromJson(
                sample.submission({'reason': 'different'})),
            applicationName: '阅读'),
        throwsA(isA<AccessFailure>()));
    final cancelled = AccessSubmission.fromJson(sample.submission({
      'state': 'CANCELLED',
      'version': 1,
      'reasonCode': 'DEVICE_CANCELLED'
    }));
    await journal.record(cancelled, applicationName: '阅读');
    await journal.record(pending, applicationName: '阅读');
    expect((await journal.inspect()).entries.single.value.state, 'CANCELLED');
  });
  test(
      'cancel retains original version and safe rejection allows explicit reset',
      () async {
    await journal.prepareCancel(AccessSubmission.fromJson(sample.submission()),
        key: 'cancel-key', applicationName: '阅读', now: f.now);
    await journal.markSending('cancel-key');
    final operation = (await journal.inspect()).pending!;
    expect(operation.requestId, f.request);
    expect(operation.version, 0);
    await journal.reject('cancel-key', 'RESOURCE_VERSION_CONFLICT');
    expect((await journal.inspect()).pending!.phase,
        SubmissionOperationPhase.rejected);
    await journal.discardUnsentOrRejected('cancel-key');
    expect((await journal.inspect()).pending, isNull);
  });
  test('ambiguous errors cannot become discardable known rejection', () async {
    await journal.prepareCreate(sample.input(),
        key: 'key', applicationName: '阅读', now: f.now);
    await journal.markSending('key');
    for (final code in [
      'HTTP_FAILURE',
      'INTERNAL_ERROR',
      'IDEMPOTENCY_KEY_EXPIRED',
      'DEVICE_UNAUTHENTICATED'
    ]) {
      await expectLater(
          journal.reject('key', code), throwsA(isA<AccessFailure>()));
      expect((await journal.inspect()).pending!.phase,
          SubmissionOperationPhase.unknown);
    }
  });
  test('successful cancel must advance to cancelled before removing the outbox',
      () async {
    await journal.prepareCancel(AccessSubmission.fromJson(sample.submission()),
        key: 'cancel', applicationName: '阅读', now: f.now);
    await journal.markSending('cancel');
    await expectLater(
        journal.complete(
            'cancel', AccessSubmission.fromJson(sample.submission())),
        throwsA(isA<AccessFailure>()));
    expect((await journal.inspect()).pending!.key, 'cancel');
    await journal.complete(
        'cancel',
        AccessSubmission.fromJson(sample.submission({
          'state': 'CANCELLED',
          'version': 1,
          'reasonCode': 'DEVICE_CANCELLED'
        })));
    expect((await journal.inspect()).pending, isNull);
  });
  test(
      'a newer fact cannot rewrite creation time or the original pending expiry',
      () async {
    await journal.record(AccessSubmission.fromJson(sample.submission()),
        applicationName: '阅读');
    for (final changes in [
      {'createdAt': f.now + 1},
      {'requestExpiresAt': f.now + 2000000}
    ]) {
      await expectLater(
          journal.record(
              AccessSubmission.fromJson(sample.submission(
                  {'state': 'CANCELLED', 'version': 1, ...changes})),
              applicationName: '阅读'),
          throwsA(isA<AccessFailure>()));
    }
  });
  test(
      'cached newer state prevents preparing a cancel from a stale local detail',
      () async {
    await journal.record(
        AccessSubmission.fromJson(
            sample.submission({'state': 'CANCELLED', 'version': 1})),
        applicationName: '阅读');
    await expectLater(
        journal.prepareCancel(AccessSubmission.fromJson(sample.submission()),
            key: 'cancel', applicationName: '阅读', now: f.now),
        throwsA(isA<AccessFailure>()));
    expect((await journal.inspect()).pending, isNull);
  });
  test('failed local completion cannot erase an already sent operation',
      () async {
    await journal.prepareCreate(sample.input(),
        key: 'key', applicationName: '阅读', now: f.now);
    await journal.markSending('key');
    final path = database.path;
    await database.close();
    await expectLater(
        journal.complete('key', AccessSubmission.fromJson(sample.submission())),
        throwsA(isA<AccessFailure>()
            .having((e) => e.code, 'code', 'SUBMISSION_STORAGE_FAILED')));
    database = await databaseFactoryMemory.openDatabase(path);
    journal = AccessSubmissionJournal(database: database, scope: scope);
    expect((await journal.inspect()).pending!.phase,
        SubmissionOperationPhase.unknown);
  });
  test('concurrent distinct creates commit only one unresolved mutation',
      () async {
    final results = await Future.wait(List.generate(8, (index) async {
      try {
        await journal.prepareCreate(sample.input(),
            key: 'key-$index', applicationName: '阅读', now: f.now);
        return true;
      } on AccessFailure {
        return false;
      }
    }));
    expect(results.where((x) => x).length, 1);
    expect((await journal.inspect()).pending, isNotNull);
  });
  test('cache is bounded while the newest stored fact is retained', () async {
    journal = AccessSubmissionJournal(
        database: database, scope: scope, maxEntries: 2);
    for (var i = 1; i <= 3; i++) {
      await journal.record(
          AccessSubmission.fromJson(sample.submission({
            'id': '${f.request.substring(0, 35)}$i',
            'createdAt': f.now + i
          })),
          applicationName: '阅读');
    }
    final view = await journal.inspect();
    expect(view.entries.length, 2);
    expect(view.entries.first.value.id, '${f.request.substring(0, 35)}3');
  });
  test('corrupt persistent union is rejected without deleting its contents',
      () async {
    await journal.prepareCreate(sample.input(),
        key: 'key', applicationName: '阅读', now: f.now);
    final record = stringMapStoreFactory
        .store('submissions-v1-${scope.storageKey}-operation')
        .record('pending');
    final raw = Map<String, Object?>.from((await record.get(database))!);
    raw['kind'] = 'UNRECOGNIZED';
    await record.put(database, raw);
    await expectLater(
        journal.inspect(),
        throwsA(isA<AccessFailure>()
            .having((e) => e.code, 'code', 'SUBMISSION_STORAGE_FAILED')));
    expect((await record.get(database))!['kind'], 'UNRECOGNIZED');
  });
}
