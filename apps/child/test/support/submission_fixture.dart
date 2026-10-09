import 'dart:async';
import 'package:child/core/submissions.dart';
import 'package:device_access/device_access.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_memory.dart';
import 'identity_fixture.dart';

/// Controlled service boundary backed by the real request journal. No app demo mode.
class SubmissionFixture implements ChildSubmissions {
  static const subject = '55555555-5555-5555-5555-555555555555';
  static const policy = '66666666-6666-6666-6666-666666666666';
  static const version = '77777777-7777-7777-7777-777777777777';
  static const application = '88888888-8888-8888-8888-888888888888';
  static const request = '99999999-9999-9999-9999-999999999999';
  static int _serial = 0;
  late final Database database;
  late final AccessSubmissionJournal journal;
  AccessTransportFailure? failure;
  Completer<void>? refreshGate;
  bool loseResponse = false, closed = false;
  int restores = 0, refreshes = 0, mutations = 0;
  String? optionsCursor, requestsCursor;
  List<AccessSubmissionOption> options = [option()];
  AccessSubmission? currentFact;
  static AccessSubmissionOption option() => AccessSubmissionOption.fromJson({
        'id': policy,
        'name': '学习安排',
        'baseVersionId': version,
        'commonRules': [],
        'applications': [
          {
            'id': application,
            'displayName': '阅读空间',
            'rules': [
              {'id': 'reading', 'kind': 'APP_LAUNCH'}
            ]
          }
        ]
      });
  static AccessSubmissionInput input() => AccessSubmissionInput(
      policyId: policy,
      baseVersionId: version,
      applicationId: application,
      ruleIds: ['reading'],
      requestedWindowSeconds: 600,
      reason: '完成阅读');
  static AccessSubmission fact([Map<String, dynamic> changes = const {}]) =>
      AccessSubmission.fromJson({
        'id': request,
        'subjectId': subject,
        'deviceId': IdentityFixture.device,
        'registrationId': IdentityFixture.registration,
        'policyId': policy,
        'baseVersionId': version,
        'applicationId': application,
        'ruleIds': ['reading'],
        'requestedWindowSeconds': 600,
        'reason': '完成阅读',
        'state': 'PENDING',
        'requestExpiresAt': IdentityFixture.now + 1800000,
        'grantedWindowSeconds': null,
        'issuedAt': null,
        'absoluteNotAfter': null,
        'reasonCode': null,
        'executionState': 'NOT_ENFORCED',
        'version': 0,
        'createdAt': IdentityFixture.now,
        ...changes
      });
  Future<void> open() async {
    database = await databaseFactoryMemory.openDatabase('session-${_serial++}');
    journal = AccessSubmissionJournal(
        database: database,
        scope: const DeviceAccessScope(
            issuer: 'session-fixture',
            tenantId: IdentityFixture.tenant,
            subjectId: subject,
            deviceId: IdentityFixture.device,
            registrationId: IdentityFixture.registration));
  }

  Future<ChildSubmissionSnapshot> snapshot({bool online = false}) async =>
      ChildSubmissionSnapshot(
          journal: await journal.inspect(),
          contextReady: true,
          onlineConfirmed: online,
          options: online ? options : const [],
          confirmedRequestIds: online ? {request} : const {},
          optionsCursor: optionsCursor,
          requestsCursor: requestsCursor,
          lastCheckedAt: IdentityFixture.now);
  @override
  Future<ChildSubmissionSnapshot> restore() async {
    restores++;
    return snapshot();
  }

  @override
  Future<ChildSubmissionSnapshot> refresh() async {
    refreshes++;
    await refreshGate?.future;
    if (failure != null) throw failure!;
    return snapshot(online: true);
  }

  @override
  Future<ChildSubmissionSnapshot> create(AccessSubmissionInput input,
      {required String applicationName, required String key}) async {
    await journal.prepareCreate(input,
        key: key, applicationName: applicationName, now: IdentityFixture.now);
    return retry();
  }

  @override
  Future<ChildSubmissionSnapshot> retry() async {
    final original = (await journal.inspect()).pending!;
    await journal.markSending(original.key);
    mutations++;
    if (loseResponse) {
      throw const AccessTransportFailure('NETWORK_TIMEOUT',
          retryable: true,
          outcomeUnknown: true,
          correlationId: 'fixture-correlation');
    }
    final result = original.kind == 'CREATE'
        ? fact(original.input!.toJson())
        : fact({
            ...?currentFact?.toJson(),
            'state': 'CANCELLED',
            'version': original.version! + 1
          });
    await journal.complete(original.key, result);
    currentFact = result;
    return snapshot(online: true);
  }

  @override
  Future<ChildSubmissionSnapshot> cancel(AccessSubmission value,
      {required String applicationName, required String key}) async {
    await journal.prepareCancel(value,
        key: key, applicationName: applicationName, now: IdentityFixture.now);
    return retry();
  }

  @override
  Future<ChildSubmissionSnapshot> discard() async {
    await journal
        .discardUnsentOrRejected((await journal.inspect()).pending!.key);
    return snapshot();
  }

  @override
  Future<ChildSubmissionSnapshot> detail(String id) async {
    currentFact ??= fact();
    await journal.record(currentFact!, applicationName: '阅读空间');
    return snapshot(online: true);
  }

  @override
  Future<ChildSubmissionSnapshot> moreOptions() async {
    options = [option()];
    optionsCursor = null;
    return snapshot(online: true);
  }

  @override
  Future<ChildSubmissionSnapshot> moreRequests() async {
    requestsCursor = null;
    return detail(request);
  }

  @override
  void pause() {}
  @override
  void resume() {}
  @override
  Future<void> close() async {
    closed = true;
  }

  Future<void> dispose() => database.close();
}
