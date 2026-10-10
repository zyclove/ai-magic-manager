const tenant = '11111111-1111-1111-1111-111111111111';
const device = '22222222-2222-2222-2222-222222222222';
const registration = '33333333-3333-3333-3333-333333333333';
const correlation = '77777777-7777-7777-7777-777777777777';
const now = 1791600000000;

Map<String, dynamic> fixture() => {
      'schemaVersion': 1,
      'generatedAt': now,
      'correlationId': correlation,
      'scope': {
        'tenantId': tenant,
        'deviceId': device,
        'registrationId': registration
      },
      'versions': {
        'os': {'value': '14', 'status': 'REPORTED'},
        'agent': {'value': '1.2.3', 'status': 'REPORTED'},
        'server': {'value': null, 'status': 'UNREPORTED'}
      },
      'device': {
        'platform': 'ANDROID',
        'state': 'ACTIVE',
        'managementMode': 'BYOD',
        'controlLevel': 'LIMITED',
        'observationStatus': 'RECENT',
        'lastHeartbeatAt': now - 1000
      },
      'capabilities': [
        {
          'key': 'usage.report',
          'reportedSupported': true,
          'grantStatus': 'GRANTED',
          'evidenceSource': 'AGENT_REPORT',
          'checkedAt': now - 500,
          'status': 'UNVERIFIED',
          'limitationCode': 'EVIDENCE_NOT_CERTIFIED'
        }
      ],
      'omittedCapabilityCount': 0,
      'configurations': [
        {
          'id': '66666666-6666-6666-6666-666666666666',
          'policyId': '44444444-4444-4444-4444-444444444444',
          'versionId': '55555555-5555-5555-5555-555555555555',
          'sourceSequence': 1,
          'action': 'UPSERT_CONFIGURATION',
          'deliveryState': 'DEVICE_REPORTED_STORED',
          'policyHash': List.filled(64, 'a').join(),
          'configurationHash': null,
          'issuedAt': now - 10000,
          'deliveryExpiresAt': now + 60000,
          'receivedReportedAt': now - 8000,
          'storedReportedAt': now - 7000,
          'rejectionCode': null
        }
      ],
      'evidenceStatus': 'DEVICE_REPORTS_NOT_EXECUTION_PROOF',
    };
