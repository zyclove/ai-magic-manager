import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/usage_report_jobs.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'usage_reports_test.dart'
    show device, registration, subject, now, target, reportFixture;

const jobId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
UsageReportJobDraft draft() => UsageReportJobDraft(
    deviceIds: [device],
    from: now - 3600000,
    to: now,
    timeZone: 'UTC',
    period: 'DAY');
Json jobFixture({String state = 'READY'}) => {
      'id': jobId,
      'state': state,
      'createdAt': now,
      'updatedAt': now + 1000,
      'expiresAt': now + 86400000,
      'totalDevices': 1,
      'completedDevices': state == 'READY' ? 1 : 0,
      'byteCount': state == 'READY' ? 1024 : 0,
      'failureCode': null,
      'selection': draft().body,
      'parts': [
        {
          'ordinal': 0,
          'deviceId': device,
          'registrationId': registration,
          'subjectId': subject,
          'authorizationVersion': 1,
          'usageEnabled': true,
          'byteCount': state == 'READY' ? 1024 : null,
          'generatedAt': state == 'READY' ? now : null
        }
      ]
    };
UsageReportJobRepository repository(
        FutureOr<http.Response> Function(http.Request) send,
        {bool Function()? current}) =>
    UsageReportJobRepository(
        api: Api(() async => MockClient((r) async => send(r))),
        root: '/tenants/$subject',
        current: current ?? () => true);
http.Response response(Object value, {int status = 200}) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json'});

void main() {
  test('download validates the stored result before producing JSON bytes',
      () async {
    final payload = reportFixture(), value = jobFixture();
    final bytes = utf8.encode(jsonEncode(payload));
    value['byteCount'] = bytes.length;
    value['parts'][0]['byteCount'] = bytes.length;
    final job = UsageReportJob.parse(value);
    final repo = repository((r) => response(payload));
    final downloaded = await repo.download(job, job.parts.single, target);
    expect(jsonDecode(utf8.decode(downloaded)), payload);
    payload['devices'][0]['registrationId'] = subject;
    await expectLater(repo.download(job, job.parts.single, target),
        throwsA(isA<ApiFailure>()));
  });
  test('strict immutable task metadata binds selection and completed parts',
      () {
    final job = UsageReportJob.parse(jobFixture());
    expect(job.ready, true);
    expect(job.parts.single.deviceId, device);
    expect(() => job.parts.clear(), throwsUnsupportedError);
    for (final mutate in <void Function(Json)>[
      (v) => v['completedDevices'] = 0,
      (v) => v['byteCount'] = 512,
      (v) => (v['parts'] as List).single['registrationId'] = 'invalid',
      (v) => (v['parts'] as List).single['deviceId'] = jobId,
      (v) => (v['selection'] as Json)['extra'] = true,
      (v) => v['unexpected'] = 'ignored',
    ]) {
      final bad = jobFixture();
      mutate(bad);
      expect(() => UsageReportJob.parse(bad), throwsA(isA<ApiFailure>()));
    }
  });
  test('draft allows 200 devices but rejects duplicates and invalid dates', () {
    final ids = List.generate(
        200,
        (i) =>
            '${i.toRadixString(16).padLeft(8, '0')}-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
    expect(
        UsageReportJobDraft(
                deviceIds: ids,
                from: now - 1000,
                to: now,
                timeZone: 'UTC',
                period: 'DAY')
            .deviceIds
            .length,
        200);
    expect(
        () => UsageReportJobDraft(
            deviceIds: [device, device],
            from: now - 1000,
            to: now,
            timeZone: 'UTC',
            period: 'DAY'),
        throwsA(isA<ApiFailure>()));
    expect(
        () => UsageReportJobDraft(
            deviceIds: [device],
            from: now - 33 * 86400000,
            to: now,
            timeZone: 'UTC',
            period: 'DAY'),
        throwsA(isA<ApiFailure>()));
  });
  test('unknown creation retries exact key and frozen body', () async {
    final requests = <http.Request>[];
    final repo = repository((r) {
      requests.add(r);
      return requests.length == 1
          ? response({'errorCode': 'TEMPORARY'}, status: 503)
          : response(jobFixture(state: 'QUEUED'), status: 202);
    });
    await expectLater(
        repo.create(draft(), 'same-key'), throwsA(isA<ApiFailure>()));
    await repo.create(draft(), 'same-key');
    expect(requests[0].body, requests[1].body);
    expect(requests[1].headers['Idempotency-Key'], 'same-key');
  });
  test('mismatched creation response is rejected', () async {
    final value = jobFixture(state: 'QUEUED');
    (value['selection'] as Json)['period'] = 'WEEK';
    await expectLater(
        repository((_) => response(value, status: 202)).create(draft(), 'key'),
        throwsA(isA<ApiFailure>()));
  });
  test('late workspace response cannot publish', () async {
    bool current = true;
    final pending = Completer<http.Response>();
    final repo = repository((_) => pending.future, current: () => current);
    final future = repo.get(jobId);
    current = false;
    pending.complete(response(jobFixture()));
    await expectLater(
        future,
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'WORKSPACE_CHANGED')));
  });
  test(
      'saved report reuses strict report parser and checks authorization version',
      () async {
    final body = reportFixture();
    final size = utf8.encode(jsonEncode(body)).length;
    final metadata = jobFixture();
    metadata['byteCount'] = size;
    (metadata['parts'] as List).single['byteCount'] = size;
    final job = UsageReportJob.parse(metadata);
    final repo = repository((r) {
      expect(r.url.path.endsWith('/usage-report-jobs/$jobId/parts/0'), true);
      return response(body);
    });
    final report = await repo.result(job, job.parts.single, target);
    expect(report.devices.single.deviceId, device);
    (body['devices'] as List).single['authorizationVersion'] = 2;
    await expectLater(
        repo.result(job, job.parts.single, target), throwsA(isA<ApiFailure>()));
  });
  test('task page rejects duplicate and invalid cursor metadata', () async {
    await expectLater(
        repository((_) => response({
              'items': [jobFixture(), jobFixture()],
              'nextCursor': null
            })).load(),
        throwsA(isA<ApiFailure>()));
    await expectLater(
        repository((_) => response({
              'items': [jobFixture()],
              'nextCursor': jobId
            })).load(),
        throwsA(isA<ApiFailure>()));
  });
}
