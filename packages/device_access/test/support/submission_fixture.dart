import 'package:device_access/device_access.dart';
import '../fixtures.dart' as f;

Map<String, dynamic> submission([Map<String, dynamic> changes = const {}]) => {
      'id': f.request,
      'subjectId': f.subject,
      'deviceId': f.device,
      'registrationId': f.registration,
      'policyId': f.policy,
      'baseVersionId': f.version,
      'applicationId': f.application,
      'ruleIds': ['reading'],
      'requestedWindowSeconds': 600,
      'reason': '继续阅读',
      'state': 'PENDING',
      'requestExpiresAt': f.now + 1800000,
      'grantedWindowSeconds': null,
      'issuedAt': null,
      'absoluteNotAfter': null,
      'reasonCode': null,
      'executionState': 'NOT_ENFORCED',
      'version': 0,
      'createdAt': f.now,
      ...changes
    };
AccessDeviceContext context() => AccessDeviceContext.fromJson({
      'tenantId': f.tenant,
      'subjectId': f.subject,
      'deviceId': f.device,
      'registrationId': f.registration
    });
AccessSubmissionInput input() => AccessSubmissionInput(
    policyId: f.policy,
    baseVersionId: f.version,
    applicationId: f.application,
    ruleIds: ['reading'],
    requestedWindowSeconds: 600,
    reason: '继续阅读');
