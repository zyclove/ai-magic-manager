import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/approval_decision.dart';

Json _fresh() => {
      'id': 'request-1',
      'subjectId': 'subject-1',
      'deviceId': 'device-1',
      'applicationId': 'application-1',
      'registrationId': 'registration-1',
      'state': 'PENDING',
      'requestedWindowSeconds': 95,
      'grantedWindowSeconds': null,
      'version': 3,
    };

Json _delivery() => {
      'requestId': 'request-1',
      'approvalVersion': 3,
      'approvalState': 'APPROVED_PENDING_DELIVERY',
      'action': 'UPSERT_ACCESS_WINDOW',
      'documentId': null,
      'deliveryState': 'NOT_FETCHED',
      'receivedAt': null,
      'executionState': 'NOT_ENFORCED',
      'evidenceStatus': 'DEVICE_REPORT_UNVERIFIED',
      'deliveryAttempt': null,
      'reasonCode': null,
      'retryStatus': 'NOT_NEEDED',
      'retryAfter': null,
    };

Matcher _failure(int status, String code) => throwsA(isA<ApiFailure>()
    .having((error) => error.status, 'status', status)
    .having((error) => error.code, 'code', code)
    .having((error) => error.correlationId, 'no raw value retained', isNull)
    .having((error) => error.message, 'no raw input echoed',
        isNot(contains('private'))));

void main() {
  test('list names detach and bind only to the complete fresh reference', () {
    final row = {
      ..._fresh(),
      'subjectName': '小明',
      'deviceName': '平板',
      'applicationName': '绘画应用',
      'applicationPackageName': 'com.example.draw',
    };
    final context = ApprovalListContext.capture(row, role: 'GUARDIAN');
    final audit = ApprovalListContext.capture(row, role: 'AUDITOR');
    row.clear();
    final fresh = {..._fresh(), 'version': 8, 'state': 'DENIED',
      'requestedWindowSeconds': 37};
    final snapshot = ApprovalRequestSnapshot.read(fresh,
        expectedId: 'request-1', context: context);
    expect(snapshot.subjectId, 'subject-1');
    expect(snapshot.deviceId, 'device-1');
    expect(snapshot.applicationId, 'application-1');
    expect(snapshot.version, 8);
    expect(snapshot.state, 'DENIED');
    expect(snapshot.requestedSeconds, 37);
    expect(snapshot.subjectName, '小明');
    expect(snapshot.deviceName, '平板');
    expect(snapshot.applicationName, '绘画应用');
    expect(snapshot.applicationPackageName, 'com.example.draw');
    fresh.clear();
    expect(snapshot.version, 8);
    expect(snapshot.subjectName, '小明');
    expect(audit.subjectName, isNull);
    expect(audit.deviceName, isNull);
    expect(audit.applicationName, isNull);
    expect(audit.applicationPackageName, isNull);

    for (final changed in <Json>[
      {'id': 'request-2'},
      {'subjectId': 'subject-2'},
      {'deviceId': 'device-2'},
      {'applicationId': 'application-2'},
      {'registrationId': 'registration-2'},
      {'registrationId': null},
    ]) {
      final current = {..._fresh(), ...changed};
      final result = ApprovalRequestSnapshot.read(current,
          expectedId: current['id'] as String, context: context);
      expect(result.subjectName, isNull);
      expect(result.deviceName, isNull);
      expect(result.applicationName, isNull);
      expect(result.applicationPackageName, isNull);
      expect(result.subjectId, current['subjectId']);
    }
    final withoutReferences = ApprovalListContext.capture(
        {'id': 'request-1', 'subjectName': 'private-list-name'}, role: 'OWNER');
    expect(ApprovalRequestSnapshot.read(_fresh(), expectedId: 'request-1',
        context: withoutReferences).subjectName, isNull);
    expect(ApprovalRequestSnapshot.read(_fresh(), expectedId: 'request-1',
        context: audit).subjectName, isNull);
    for (final invalid in <Object?>[
      null,
      'private-response',
      {..._fresh(), 'id': 'different-request'},
      {..._fresh(), 'subjectId': ''},
      {..._fresh(), 'deviceId': {'private': 'raw'}},
      {..._fresh(), 'applicationId': 1},
      {..._fresh(), 'state': 'PRIVATE_UNKNOWN'},
      {..._fresh(), 'requestedWindowSeconds': 0},
      {..._fresh(), 'requestedWindowSeconds': 3601},
      {..._fresh(), 'requestedWindowSeconds': 1.5},
      {..._fresh(), 'version': -1},
      {..._fresh(), 'version': 3.0},
      {..._fresh(), 'version': 9007199254740992},
      {..._fresh(), 'version': 'private-version'},
    ]) {
      expect(() => ApprovalRequestSnapshot.read(invalid, expectedId: 'request-1'),
          _failure(502, 'INVALID_RESPONSE'));
    }
  });

  test('request grants distinguish never approved and previously approved states', () {
    for (final example in <({String state, int? grant})>[
      (state: 'PENDING', grant: null),
      (state: 'DENIED', grant: null),
      (state: 'CANCELLED', grant: null),
      (state: 'INVALIDATED', grant: null),
      (state: 'APPROVED_PENDING_DELIVERY', grant: 1),
      (state: 'APPROVED_PENDING_DELIVERY', grant: 95),
      (state: 'REVOKED', grant: 45),
      (state: 'EXPIRED', grant: null),
      (state: 'EXPIRED', grant: 45),
    ]) {
      final raw = {..._fresh(), 'state': example.state,
        'grantedWindowSeconds': example.grant, 'version': 9007199254740991};
      final snapshot = ApprovalRequestSnapshot.read(raw, expectedId: 'request-1');
      raw.clear();
      expect(snapshot.state, example.state);
      expect(snapshot.grantedSeconds, example.grant);
      expect(snapshot.requestedSeconds, 95);
      expect(snapshot.version, 9007199254740991);
    }
    for (final invalid in <Json>[
      _fresh()..remove('grantedWindowSeconds'),
      for (final state in ['APPROVED_PENDING_DELIVERY', 'REVOKED'])
        {..._fresh(), 'state': state},
      for (final state in ['PENDING', 'DENIED', 'CANCELLED', 'INVALIDATED'])
        {..._fresh(), 'state': state, 'grantedWindowSeconds': 1},
      for (final grant in <Object>[0, -1, 96, 1.5, '45', true])
        {..._fresh(), 'state': 'EXPIRED', 'grantedWindowSeconds': grant},
    ]) {
      expect(() => ApprovalRequestSnapshot.read(invalid, expectedId: 'request-1'),
          _failure(502, 'INVALID_RESPONSE'));
    }
  });

  test('delivery snapshots preserve empty documents and device report facts', () {
    final request = ApprovalRequestSnapshot.read(
        {..._fresh(), 'state': 'APPROVED_PENDING_DELIVERY',
          'grantedWindowSeconds': 95},
        expectedId: 'request-1');
    final raw = _delivery();
    final empty = ApprovalDeliverySnapshot.read(raw, request: request);
    raw.clear();
    expect(empty.requestId, request.id);
    expect(empty.approvalVersion, 3);
    expect(empty.approvalState, request.state);
    expect(empty.action, 'UPSERT_ACCESS_WINDOW');
    expect(empty.documentId, isNull);
    expect(empty.deliveryState, 'NOT_FETCHED');
    expect(empty.receivedAt, isNull);
    expect(empty.deliveryAttempt, isNull);
    expect(empty.reasonCode, isNull);
    expect(empty.retryStatus, 'NOT_NEEDED');
    expect(empty.retryAfter, isNull);
    expect(empty.executionState, 'NOT_ENFORCED');
    expect(empty.evidenceStatus, 'DEVICE_REPORT_UNVERIFIED');

    final deniedRequest = ApprovalRequestSnapshot.read(
        {..._fresh(), 'state': 'DENIED'}, expectedId: 'request-1');
    final notGranted = ApprovalDeliverySnapshot.read({
      ..._delivery(), 'approvalState': 'DENIED',
      'action': null, 'deliveryState': 'NOT_GRANTED',
    }, request: deniedRequest);
    expect(notGranted.action, isNull);
    expect(notGranted.documentId, isNull);
    expect(notGranted.deliveryState, 'NOT_GRANTED');
    final initial = ApprovalRequestSnapshot.read(
        {..._fresh(), 'version': 0}, expectedId: 'request-1');
    expect(ApprovalDeliverySnapshot.read({
      ..._delivery(), 'approvalVersion': 0, 'approvalState': 'PENDING',
      'action': null, 'deliveryState': 'NOT_GRANTED',
    }, request: initial).approvalVersion, 0);

    final stored = ApprovalDeliverySnapshot.read({
      ..._delivery(), 'documentId': 'document-1', 'deliveryState': 'STORED',
      'deliveryAttempt': 2, 'receivedAt': 1700000000000,
    }, request: request);
    expect(stored.documentId, 'document-1');
    expect(stored.deliveryAttempt, 2);
    expect(stored.receivedAt, 1700000000000);
    expect(stored.executionState, 'NOT_ENFORCED');
    expect(stored.evidenceStatus, 'DEVICE_REPORT_UNVERIFIED');
    final rejected = ApprovalDeliverySnapshot.read({
      ..._delivery(), 'documentId': 'document-1', 'deliveryState': 'REJECTED',
      'deliveryAttempt': 2, 'receivedAt': 1700000000000,
      'reasonCode': 'STORAGE_FAILED', 'retryStatus': 'WAITING',
      'retryAfter': 1700000060000,
    }, request: request);
    expect(rejected.reasonCode, 'STORAGE_FAILED');
    expect(rejected.retryStatus, 'WAITING');
    expect(rejected.retryAfter, 1700000060000);
  });

  test('delivery binds its target and exact version without replacing the request', () {
    final request = ApprovalRequestSnapshot.read(
        {..._fresh(), 'state': 'APPROVED_PENDING_DELIVERY',
          'grantedWindowSeconds': 95},
        expectedId: 'request-1');
    final newer = ApprovalDeliverySnapshot.read({
      ..._delivery(), 'approvalVersion': 4, 'approvalState': 'REVOKED',
      'action': 'REMOVE_ACCESS_WINDOW',
    }, request: request);
    expect(newer.approvalVersion, 4);
    expect(newer.approvalState, 'REVOKED');
    expect(newer.action, 'REMOVE_ACCESS_WINDOW');
    expect(newer.documentId, isNull);
    expect(newer.deliveryState, 'NOT_FETCHED');
    expect(request.version, 3);
    expect(request.state, 'APPROVED_PENDING_DELIVERY');
    final expired = ApprovalDeliverySnapshot.read({
      ..._delivery(), 'approvalVersion': 5, 'approvalState': 'EXPIRED',
      'action': null, 'deliveryState': 'NOT_GRANTED',
    }, request: ApprovalRequestSnapshot.read(_fresh(), expectedId: 'request-1'));
    expect(expired.approvalState, 'EXPIRED');
    expect(expired.action, isNull);
    for (final changed in <Json>[
      {'requestId': 'private-other-request'},
      {'approvalVersion': 2},
      {'approvalVersion': 3.5},
      {'approvalVersion': 9007199254740992},
      {'approvalState': 'REVOKED', 'action': 'REMOVE_ACCESS_WINDOW'},
    ]) {
      expect(() => ApprovalDeliverySnapshot.read(
          {..._delivery(), ...changed}, request: request),
          _failure(502, 'INVALID_RESPONSE'));
    }
  });

  test('delivery rejects fabricated execution and inconsistent transport facts', () {
    final request = ApprovalRequestSnapshot.read(
        {..._fresh(), 'state': 'APPROVED_PENDING_DELIVERY',
          'grantedWindowSeconds': 95},
        expectedId: 'request-1');
    for (final changed in <Json>[
      {'executionState': 'APPLIED'},
      {'evidenceStatus': 'VERIFIED_APPLIED'},
      {'action': 'CONFIGURE_ONLY'},
      {'deliveryState': 'NOT_ISSUED'},
      {'deliveryAttempt': 1},
      {'receivedAt': -1},
      {'documentId': 'document-1', 'deliveryState': 'STORED',
        'deliveryAttempt': 1},
      {'documentId': 'document-1', 'deliveryState': 'REJECTED',
        'deliveryAttempt': 1, 'receivedAt': 1700000000000,
        'retryStatus': 'AVAILABLE', 'retryAfter': 1700000030000},
    ]) {
      expect(() => ApprovalDeliverySnapshot.read(
          {..._delivery(), ...changed}, request: request),
          _failure(502, 'INVALID_RESPONSE'));
    }
    final incomplete = _delivery()..remove('evidenceStatus');
    expect(() => ApprovalDeliverySnapshot.read(incomplete, request: request),
        _failure(502, 'INVALID_RESPONSE'));
  });

  test('approval duration and RPC keep exact seconds and reject excess grants', () {
    expect(approvalDuration(0), '0 秒');
    expect(approvalDuration(45), '45 秒');
    expect(approvalDuration(60), '1 分钟');
    expect(approvalDuration(95), '1 分钟 35 秒');
    expect(approvalDuration(3599), '59 分钟 59 秒');
    expect(approvalDuration(3600), '60 分钟');
    final values = <String, dynamic>{
      'minutes': 0, 'seconds': 45, 'decision': 'DENY',
      'private': {'raw': 'not-forwarded'},
    };
    final exact = approvalGrantBody(values, requestedSeconds: 45);
    values.clear();
    expect(exact, {'decision': 'APPROVE', 'grantedWindowSeconds': 45});
    expect(() => exact['decision'] = 'DENY', throwsUnsupportedError);
    for (final example in [(0, 1, 1), (1, 35, 95), (59, 59, 3599), (60, 0, 3600)]) {
      expect(approvalGrantBody({'minutes': example.$1, 'seconds': example.$2},
          requestedSeconds: example.$3),
          {'decision': 'APPROVE', 'grantedWindowSeconds': example.$3});
    }
    for (final invalid in <Json>[
      {},
      {'minutes': 'private-minutes', 'seconds': 0},
      {'minutes': 1.0, 'seconds': 0},
      {'minutes': -1, 'seconds': 0},
      {'minutes': 61, 'seconds': 0},
      {'minutes': 0, 'seconds': -1},
      {'minutes': 0, 'seconds': 60},
      {'minutes': 0, 'seconds': 0},
    ]) {
      expect(() => approvalGrantBody(invalid, requestedSeconds: 3600),
          _failure(400, 'INVALID_APPROVAL_DURATION'));
    }
    for (final example in [(0, 46, 45), (1, 0, 59), (60, 1, 3600)]) {
      expect(() => approvalGrantBody(
          {'minutes': example.$1, 'seconds': example.$2},
          requestedSeconds: example.$3),
          _failure(400, 'GRANT_EXCEEDS_REQUEST'));
    }
  });
}
