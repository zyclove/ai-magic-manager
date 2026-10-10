import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/access.dart';
import 'package:guardian/core/usage_reports.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const device = '11111111-1111-1111-1111-111111111111';
const registration = '22222222-2222-2222-2222-222222222222';
const subject = '33333333-3333-3333-3333-333333333333';
const now = 1791590400000;
const target = UsageReportTarget(device, registration, subject, '平板');
UsageReportQuery query() => UsageReportQuery(
    targets: [target],
    from: now - 3600000,
    to: now,
    timeZone: 'UTC',
    period: 'DAY');
Json reportFixture() => jsonDecode(jsonEncode({
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
    })) as Json;
UsageReportRepository repository(
        FutureOr<http.Response> Function(http.Request) send,
        {bool Function()? current}) =>
    UsageReportRepository(
        api: Api(() async => MockClient((r) async => send(r))),
        root: '/tenants/$subject',
        current: current ?? () => true);
http.Response response(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});
void main() {
  test('report categories validate package profile and platform provenance',
      () {
    final value = reportFixture();
    final classification =
        value['devices'][0]['applications'][0]['classification'];
    final parsed = UsageReport.parse(value, query());
    expect(parsed.devices.single.applications.single.classification.category,
        'UNCLASSIFIED');
    for (final entry in {
      'platform': 'ANDROID_TV',
      'profile': 'WORK',
      'packageName': 'org.example.other'
    }.entries) {
      final previous = classification['identity'][entry.key];
      classification['identity'][entry.key] = entry.value;
      expect(() => UsageReport.parse(value, query()),
          throwsA(isA<UsageReportFailure>()));
      classification['identity'][entry.key] = previous;
    }
  });
  test('scope query freezes selected roster and rejects devices outside it',
      () {
    final roster = [subject];
    final scope = UsageReportScope(
        kind: 'CLASS',
        id: registration,
        version: 4,
        label: '一班',
        subjectIds: roster);
    final q = UsageReportQuery(
        targets: [target],
        from: now - 3600000,
        to: now,
        timeZone: 'UTC',
        period: 'DAY',
        scope: scope);
    roster.clear();
    expect(q.scope.subjectIds, {subject});
    expect(Uri.parse(q.path).queryParameters['scopeVersion'], '4');
    expect(
        () => UsageReportQuery(
            targets: [target],
            from: now - 3600000,
            to: now,
            timeZone: 'UTC',
            period: 'DAY',
            scope: UsageReportScope(
                kind: 'SUBJECT', id: registration, label: '其他儿童')),
        throwsA(isA<UsageReportFailure>()));
    final data = reportFixture();
    data['scope'] = {'kind': 'CLASS', 'id': registration, 'version': 4};
    expect(UsageReport.parse(data, q).scope.kind, 'CLASS');
    data['scope']['version'] = 4.0;
    expect(
        () => UsageReport.parse(data, q), throwsA(isA<UsageReportFailure>()));
    data['scope']['version'] = 5;
    expect(
        () => UsageReport.parse(data, q), throwsA(isA<UsageReportFailure>()));
  });
  test('calendar windows use the selected IANA zone and preserve DST days', () {
    final spring = usageCalendarWindow(
        DateTime(2026, 3, 8), DateTime(2026, 3, 8), 'America/New_York');
    final autumn = usageCalendarWindow(
        DateTime(2026, 11, 1), DateTime(2026, 11, 1), 'America/New_York');
    expect(spring.$2 - spring.$1, 23 * 3600000);
    expect(autumn.$2 - autumn.$1, 25 * 3600000);
    expect(
        () => usageCalendarWindow(
            DateTime(2026, 3, 8), DateTime(2026, 3, 8), 'bad/zone'),
        throwsA(isA<UsageReportFailure>()));
  });
  test(
      'report roles include child self-service and exclude teacher and auditor',
      () {
    for (final role in ['OWNER', 'GUARDIAN', 'ORG_ADMIN', 'CHILD']) {
      expect(canOpenSection(role, 'reports'), isTrue);
    }
    for (final role in ['TEACHER', 'AUDITOR', 'unknown']) {
      expect(canOpenSection(role, 'reports'), isFalse);
    }
    expect(trustedReturnPath('/reports'), '/reports');
  });
  test('query snapshots selections and encodes repeated device IDs', () {
    final targets = [target];
    final q = UsageReportQuery(
        targets: targets,
        from: now - 1000,
        to: now,
        timeZone: 'Asia/Shanghai',
        period: 'WEEK');
    targets.clear();
    expect(q.targets, hasLength(1));
    expect(Uri.parse(q.path).queryParametersAll['deviceId'], [device]);
    expect(Uri.parse(q.path).queryParameters['timeZone'], 'Asia/Shanghai');
    expect(
        () => UsageReportQuery(
            targets: [target, target],
            from: now - 1000,
            to: now,
            timeZone: 'UTC',
            period: 'DAY'),
        throwsA(isA<UsageReportFailure>()));
  });
  test('daily response cannot silently merge several dates into one bucket',
      () {
    final q = UsageReportQuery(
        targets: [target],
        from: now - 2 * 86400000,
        to: now,
        timeZone: 'UTC',
        period: 'DAY');
    final v = reportFixture();
    v['from'] = q.from;
    v['devices'][0]['queryCoverageMillis'] = 2 * 86400000;
    v['devices'][0]['applications'][0]['buckets'][0]
        .addAll({'start': q.from, 'coveredMillis': 2 * 86400000 - 1000});
    expect(() => UsageReport.parse(v, q), throwsA(isA<UsageReportFailure>()));
  });
  test('strict report accepts ranges and preserves outward duration rounding',
      () {
    final value = UsageReport.parse(reportFixture(), query());
    final bucket = value.devices.single.applications.single.buckets.single;
    expect(bucket.lowerMillis, 1501);
    expect(usageRange(bucket), '1 秒 – 3 秒');
  });
  test('response cannot cross selection registration or subject boundaries',
      () {
    for (final key in ['deviceId', 'registrationId', 'subjectId']) {
      final value = reportFixture();
      value['devices'][0][key] =
          subject == value['devices'][0][key] ? device : subject;
      expect(() => UsageReport.parse(value, query()),
          throwsA(isA<UsageReportFailure>()));
    }
    final value = reportFixture();
    value['from']--;
    expect(() => UsageReport.parse(value, query()),
        throwsA(isA<UsageReportFailure>()));
  });
  test(
      'unknown is never zero and inconsistent totals and coverage are rejected',
      () {
    final value = reportFixture();
    final bucket = value['devices'][0]['applications'][0]['buckets'][0];
    final unknownQuery = UsageReportQuery(
        targets: [target],
        from: now - 2 * 86400000,
        to: now,
        timeZone: 'UTC',
        period: 'DAY');
    value['from'] = unknownQuery.from;
    value['devices'][0]['queryCoverageMillis'] = 2 * 86400000;
    final evidence = <String, dynamic>{
      ...bucket,
      'start': now - 86400000,
      'coveredMillis': 86400000 - 1000
    };
    bucket.addAll({
      'start': unknownQuery.from,
      'end': now - 86400000,
      'status': 'NO_EVIDENCE',
      'lowerMillis': null,
      'upperMillis': null,
      'coveredMillis': 0
    });
    value['devices'][0]['applications'][0]['buckets'].add(evidence);
    expect(
        usageRange(UsageReport.parse(value, unknownQuery)
            .devices
            .single
            .applications
            .single
            .buckets
            .first),
        '无观测证据');
    bucket['lowerMillis'] = 0;
    expect(() => UsageReport.parse(value, unknownQuery),
        throwsA(isA<UsageReportFailure>()));
    for (final change in [
      {'upperMillis': 0},
      {'coveredMillis': 3600001},
      {'status': 'REPORTED_TOTAL'},
      {'end': now - 1}
    ]) {
      final v = reportFixture();
      v['devices'][0]['applications'][0]['buckets'][0].addAll(change);
      expect(() => UsageReport.parse(v, query()),
          throwsA(isA<UsageReportFailure>()));
    }
  });
  test('consent off and absent data cannot carry private observations', () {
    for (final state in ['NOT_AUTHORIZED', 'NO_DATA']) {
      final value = reportFixture();
      value['devices'][0]['status'] = state;
      expect(() => UsageReport.parse(value, query()),
          throwsA(isA<UsageReportFailure>()));
      value['devices'][0].addAll({
        'applications': [],
        'sourceBatchCount': 0,
        'sourceTimeZones': [],
        'latestObservedAt': null,
        'latestReceivedAt': null,
        'queryCoverageMillis': 0,
        'uncoveredQueryMillis': 3600000
      });
      expect(UsageReport.parse(value, query()).devices.single.status, state);
    }
  });
  test(
      'repository sends applied query and rejects late responses after workspace change',
      () async {
    var active = true;
    final pending = Completer<http.Response>();
    final repo = repository((r) {
      expect(r.url.queryParametersAll['deviceId'], [device]);
      return pending.future;
    }, current: () => active);
    final future = repo.load(query());
    final failure = expectLater(
        future,
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'WORKSPACE_CHANGED')));
    await Future<void>.delayed(Duration.zero);
    active = false;
    pending.complete(response(reportFixture()));
    await failure;
  });
  test(
      'repository rejects HTML, oversized responses and preserves structured errors',
      () async {
    for (final reply in [
      http.Response('<html/>', 200),
      http.Response('x' * (8 * 1024 * 1024 + 1), 200)
    ]) {
      await expectLater(
          repository((_) => reply).load(query()), throwsA(isA<ApiFailure>()));
    }
    await expectLater(
        repository((_) =>
                http.Response('{"errorCode":"USAGE_REPORT_TOO_LARGE"}', 413))
            .load(query()),
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'USAGE_REPORT_TOO_LARGE')));
  });
}
