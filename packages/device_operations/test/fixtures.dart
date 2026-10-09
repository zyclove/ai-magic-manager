const tenantId = '00000000-0000-4000-8000-000000000001';
const deviceId = '00000000-0000-4000-8000-000000000002';
const registrationId = '00000000-0000-4000-8000-000000000003';
const previewId = '00000000-0000-4000-8000-000000000004';
const operationId = '00000000-0000-4000-8000-000000000005';
const commandId = '00000000-0000-4000-8000-000000000006';
const requestKey = '00000000-0000-4000-8000-000000000007';
const previewHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final now = DateTime.utc(2026, 10, 9, 5);

Map<String, dynamic> deviceJson() => {
      'id': deviceId,
      'registrationId': registrationId,
      'displayName': '学习平板',
      'managementMode': 'BYOD',
      'state': 'ACTIVE',
      'version': 7,
    };
Map<String, dynamic> previewJson() => {
      'id': previewId,
      'deviceId': deviceId,
      'registrationId': registrationId,
      'deviceVersion': 7,
      'action': 'AGENT_UNENROLL',
      'hash': previewHash,
      'expiresAt': now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      'consequences': [
        'REVOKE_REMOTE_BUSINESS_CREDENTIALS',
        'INVALIDATE_ACCESS_REQUESTS',
        'REQUEST_OWN_AGENT_CACHE_AND_CREDENTIAL_CLEANUP',
        'REMOVE_REGISTRATION_KEY_AFTER_ACK'
      ],
      'limitations': [
        'LOCAL_ERASURE_UNVERIFIED',
        'NO_SYSTEM_UNMANAGE',
        'NO_DEVICE_WIPE',
        'NO_OTHER_APP_DATA_REMOVAL',
        'NO_CLOUD_HISTORY_DELETION',
        'CACHED_COMMAND_CANNOT_BE_RECALLED_OFFLINE'
      ],
    };
Map<String, dynamic> operationJson(
        {String state = 'WAITING_FOR_AGENT', int version = 1}) =>
    {
      'id': operationId,
      'deviceId': deviceId,
      'registrationId': registrationId,
      'commandId': commandId,
      'action': 'AGENT_UNENROLL',
      'state': state,
      'remoteAccess': 'REVOKED',
      'localEvidence':
          state == 'CLEANUP_REPORTED' ? 'DEVICE_REPORT_UNVERIFIED' : 'NONE',
      'reasonCode': null,
      'issuedAt': now.millisecondsSinceEpoch,
      'notAfter': now.add(const Duration(days: 1)).millisecondsSinceEpoch,
      'version': version,
    };
