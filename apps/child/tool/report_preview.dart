import 'dart:convert';
import 'dart:math' as math;
import 'package:child/core/report_loader.dart';
import 'package:child/ui/child_app.dart';
import 'package:device_observation/device_observation.dart';
import 'package:device_reports/device_reports.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../test/support/identity_fixture.dart';

/// Explicit, standalone visual acceptance target. Never imported by main.dart.
/// All credentials, identity and responses are isolated in-memory fixtures.
Future<void> main() async {
  if (!const bool.fromEnvironment('REPORT_PREVIEW_FIXTURE')) {
    throw StateError('Explicit report fixture build required');
  }
  WidgetsFlutterBinding.ensureInitialized();
  final identity = IdentityFixture();
  await identity.activate();
  final session = identity.session();
  var reads = 0;
  final mode = Uri.base.queryParameters['scenario'] ?? 'observed';
  final client = MockClient((request) async {
    if (request.url.path.endsWith('access-context')) {
      return _response({
        'tenantId': IdentityFixture.tenant,
        'deviceId': IdentityFixture.device,
        'registrationId': IdentityFixture.registration,
        'subjectId': '55555555-5555-5555-5555-555555555555'
      });
    }
    if (request.url.path.endsWith('usage-report')) {
      reads++;
      if (mode == 'retry' && reads == 2) {
        return _response({'errorCode': 'SERVER_ERROR'}, 503);
      }
      return _response(_document(request.url, mode));
    }
    return _response({'errorCode': 'INPUT_INVALID'}, 400);
  });
  runApp(ChildApp(
      session: session,
      nativeAvailable: true,
      serviceLabel: '隔离报表界面夹具',
      reportFactory: (session) => DeviceChildReports(
          session: session,
          apiRoot: Uri.parse('https://report-fixture.example/api/v1'),
          inspect: () async => const ObservationPlatformState(
              usageGranted: true, unlocked: true),
          contextClient: () => client,
          reportClient: () => client)));
}

http.Response _response(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _document(Uri uri, String mode) {
  final from = int.parse(uri.queryParameters['from']!),
      requestedTo = int.parse(uri.queryParameters['to']!);
  final zone = uri.queryParameters['timeZone']!,
      period = uri.queryParameters['period']!;
  final now = DateTime.now().millisecondsSinceEpoch,
      to = math.min(now, requestedTo);
  final observed = mode != 'no-data' && mode != 'not-authorized';
  final buckets = <Map<String, dynamic>>[];
  var cursor = from;
  while (cursor < to) {
    final local = usageLocalTime(cursor, zone),
        day = DateTime(local.year, local.month, local.day);
    final last =
        period == 'WEEK' ? day.add(Duration(days: 7 - local.weekday)) : day;
    final stop = math.min(to, usageCalendarWindow(day, last, zone).$2);
    final duration = stop - cursor;
    final lower = math.min(duration ~/ 3, (buckets.length + 1) * 900000);
    final upper = math.min(duration, lower + 600000);
    buckets.add({
      'start': cursor,
      'end': stop,
      'lowerMillis': lower,
      'upperMillis': upper,
      'coveredMillis': duration,
      'status': 'REPORTED_RANGE'
    });
    cursor = stop;
  }
  return {
    'schemaVersion': 1,
    'scope': {'kind': 'DEVICES', 'id': null, 'version': null},
    'generatedAt': now,
    'from': from,
    'to': to,
    'requestedTo': requestedTo,
    'timeZone': zone,
    'period': period,
    'precision': 'OS_AGGREGATE',
    'evidenceStatus': 'AGENT_REPORTED_UNVERIFIED',
    'devices': [
      {
        'deviceId': IdentityFixture.device,
        'registrationId': IdentityFixture.registration,
        'subjectId': '55555555-5555-5555-5555-555555555555',
        'displayName': '我的学习平板',
        'status': mode == 'not-authorized'
            ? 'NOT_AUTHORIZED'
            : observed
                ? 'OBSERVED'
                : 'NO_DATA',
        'authorizationVersion': 1,
        'retentionFrom': now - 30 * 86400000,
        'sourceBatchCount': observed ? 7 : 0,
        'sourceTimeZones': observed ? [zone] : [],
        'latestObservedAt': observed ? now : null,
        'latestReceivedAt': observed ? now : null,
        'queryCoverageMillis': observed ? to - from : 0,
        'uncoveredQueryMillis': observed ? 0 : to - from,
        'applications': observed
            ? [
                for (final item in [
                  ['阅读练习', 'org.example.reader', 'EDUCATION', 'PRIMARY'],
                  ['课堂视频', 'org.example.classroom', 'EDUCATION', 'PRIMARY'],
                  ['益智休息', 'org.example.puzzle', 'GAMES', 'SECONDARY'],
                ])
                  {
                    'displayName': item[0],
                    'packageName': item[1],
                    'profile': item[3],
                    'classification': {
                      'identity': {
                        'platform': 'ANDROID',
                        'profile': item[3],
                        'packageName': item[1]
                      },
                      'category': item[2],
                      'source': 'ADMIN_DECLARED',
                      'version': 1,
                      'updatedAt': now - 3600000
                    },
                    'selectedIntervals': 7,
                    'discardedOverlaps': 1,
                    'buckets': buckets
                  }
              ]
            : [],
        'configurationState': {
          'checkedAt': now,
          'evidenceStatus': 'DELIVERY_ONLY_NOT_EXECUTION',
          'configurations': [
            {
              'id': '11111111-1111-1111-1111-111111111111',
              'policyId': '22222222-2222-2222-2222-222222222222',
              'versionId': '33333333-3333-3333-3333-333333333333',
              'sourceSequence': 1,
              'action': 'UPSERT_CONFIGURATION',
              'deliveryState': 'DEVICE_REPORTED_STORED',
              'issuedAt': now - 60000,
              'deliveryExpiresAt': now + 60000,
              'firstServedAt': now - 50000,
              'receivedReportedAt': now - 40000,
              'storedReportedAt': now - 30000,
              'rejectionCode': null,
              'name': '晚间学习提醒',
              'rules': [
                {
                  'kind': 'USAGE_REMINDER',
                  'predictedEffect': 'REMIND',
                  'status': 'UNKNOWN',
                  'reasonCode': 'CAPABILITY_NOT_VERIFIED',
                  'applicationName': null,
                  'platform': null,
                  'profile': null,
                  'packageName': null,
                  'scheduleName': null,
                  'permission': null,
                  'domain': null,
                  'seconds': 900,
                  'required': false
                }
              ]
            }
          ]
        },
      }
    ]
  };
}
