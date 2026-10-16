import 'package:guardian/core/api.dart';

/// Mirrors the committed PolicyPreview/PolicySnapshot records. These are UI
/// fixtures; no device execution or external provider certification is implied.
Json policyPreviewFixture(Json selection) {
  final checkedAt = DateTime.now().millisecondsSinceEpoch - 60000;
  final targets = <Json>[
    for (final id in selection['deviceIds'] as List)
      {
        'deviceId': id,
        'registrationId': 'registration-$id',
        'platform': 'ANDROID',
        'state': 'ACTIVE',
        'managementMode': 'BYOD',
        'osVersion': '14',
        'deviceVersion': 1,
        'observationStatus': 'UNKNOWN',
        'applicationEvidence': <Json>[],
        'capabilities': [
          {
            'key': 'app.launch_block',
            'reportedSupported': true,
            'grantStatus': 'UNKNOWN',
            'evidenceSource': 'DEVICE_AGENT',
            'checkedAt': checkedAt,
            'status': 'UNVERIFIED',
            'effectiveSupported': false,
            'limitationCode': 'EVIDENCE_NOT_CERTIFIED',
          },
        ],
        'rules': [
          {
            'sourceRuleIds': ['app-one', 'app-two'],
            'kind': 'APP_LAUNCH',
            'applicationId': 'learning-app',
            'scheduleId': null,
            'permission': null,
            'domain': null,
            'seconds': null,
            'required': true,
            'predictedEffect': 'DENY',
            'effectiveEffect': null,
            'status': 'UNVERIFIED',
            'reasonCode': 'EVIDENCE_NOT_CERTIFIED',
            'warnings': <String>[],
          },
          {
            'sourceRuleIds': ['domain-one'],
            'kind': 'DOMAIN_ACCESS',
            'applicationId': null,
            'scheduleId': null,
            'permission': null,
            'domain': 'example.edu',
            'seconds': null,
            'required': true,
            'predictedEffect': 'DENY',
            'effectiveEffect': null,
            'status': 'UNKNOWN',
            'reasonCode': 'CAPABILITY_NOT_VERIFIED',
            'warnings': <String>[],
          },
        ],
      },
  ];
  return {
    'id': 'preview-a',
    'policyId': 'policy-a',
    'draftRevision': 7,
    'phase': 'PREVIEW',
    'hash': 'a' * 64,
    'expiresAt': DateTime.now().millisecondsSinceEpoch + 1200000,
    'enforceable': false,
    'targets': targets,
    'snapshot': {
      'schemaVersion': 1,
      'name': '学习时间规则',
      'sourceRules': [
        for (final id in ['app-one', 'app-two', 'domain-one'])
          {
            'id': id,
            'kind': id == 'domain-one' ? 'DOMAIN_ACCESS' : 'APP_LAUNCH',
            'effect': 'DENY',
            'applicationId': id == 'domain-one' ? null : 'learning-app',
            'scheduleId': null,
            'permission': null,
            'domain': id == 'domain-one' ? 'example.edu' : null,
            'seconds': null,
            'required': true,
          },
      ],
      'applications': [
        {
          'id': 'learning-app',
          'displayName': '学习应用',
          'platform': 'ANDROID',
          'packageName': 'org.example.learning',
          'profile': 'PRIMARY',
          'signingDigests': <String>[],
          'evidenceStatus': 'UNVERIFIED',
        },
      ],
      'schedules': <Json>[],
      'protectedPackageExemptions': <String>[],
      'targets': targets,
      if (selection['groupId'] != null)
        'groupSelection': {
          'groupId': selection['groupId'],
          'groupVersion': selection['groupVersion'],
        },
    },
  };
}
