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
      'version': 3,
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
      {..._fresh(), 'version': 'private-version'},
    ]) {
      expect(() => ApprovalRequestSnapshot.read(invalid, expectedId: 'request-1'),
          _failure(502, 'INVALID_RESPONSE'));
    }
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
