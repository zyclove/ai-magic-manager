import 'dart:convert';
import 'package:device_reports/device_reports.dart';

const device = '33333333-3333-3333-3333-333333333333';
const registration = '44444444-4444-4444-4444-444444444444';
const subject = '55555555-5555-5555-5555-555555555555';
const now = 1791590400000;
const target = UsageReportTarget(device, registration, subject, '平板');
UsageReportQuery query() => UsageReportQuery(
    targets: [target],
    from: now - 3600000,
    to: now,
    timeZone: 'UTC',
    period: 'DAY');
ReportJson reportFixture() => jsonDecode(jsonEncode({
      'schemaVersion': 1,
      'scope': {'kind': 'DEVICES', 'id': null, 'version': null},
      'generatedAt': now,
      'from': now - 3600000,
      'to': now,
      'requestedTo': now,
      'timeZone': 'UTC',
      'period': 'DAY',
      'precision': 'OS_AGGREGATE',
      'evidenceStatus': 'AGENT_REPORTED_UNVERIFIED',
      'devices': [
        {
          'deviceId': device,
          'registrationId': registration,
          'subjectId': subject,
          'displayName': '平板',
          'status': 'OBSERVED',
          'authorizationVersion': 1,
          'retentionFrom': now - 30 * 86400000,
          'sourceBatchCount': 1,
          'configurationState': {
            'checkedAt': now,
            'evidenceStatus': 'DELIVERY_ONLY_NOT_EXECUTION',
            'configurations': []
          },
          'sourceTimeZones': ['UTC'],
          'latestObservedAt': now,
          'latestReceivedAt': now,
          'queryCoverageMillis': 3600000,
          'uncoveredQueryMillis': 0,
          'applications': [
            {
              'profile': 'PRIMARY',
              'packageName': 'org.example.reader',
              'displayName': '阅读',
              'classification': {
                'identity': {
                  'platform': 'ANDROID',
                  'profile': 'PRIMARY',
                  'packageName': 'org.example.reader'
                },
                'category': 'UNCLASSIFIED',
                'source': 'NONE',
                'version': 0,
                'updatedAt': null
              },
              'selectedIntervals': 1,
              'discardedOverlaps': 0,
              'buckets': [
                {
                  'start': now - 3600000,
                  'end': now,
                  'lowerMillis': 1501,
                  'upperMillis': 2501,
                  'coveredMillis': 3599000,
                  'status': 'REPORTED_RANGE'
                }
              ]
            }
          ]
        }
      ]
    })) as ReportJson;
