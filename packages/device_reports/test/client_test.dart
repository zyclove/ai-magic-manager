import 'dart:async';
import 'dart:convert';
import 'package:device_reports/device_reports.dart';
import 'package:device_policy/device_policy.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'fixture.dart';

void main() {
  DeviceUsageReportClient client(
      Future<http.Response> Function(http.Request) send,
      {bool Function()? current}) {
    final transport = DeviceConfigurationTransport(
      apiRoot: Uri.parse('https://reports.example/api/v1'),
      credential: () async => 'A' * 43,
      client: MockClient(send),
    );
    addTearDown(transport.close);
    return DeviceUsageReportClient(
        transport: transport, target: target, current: current ?? () => true);
  }

  Future<UsageReport> load(DeviceUsageReportClient reader) =>
      reader.load(from: now - 3600000, to: now, timeZone: 'UTC');
  http.Response response(ReportJson value) =>
      http.Response(jsonEncode(value), 200,
          headers: {'content-type': 'application/json'});

  test('typed device reader uses only self route and shared evidence models',
      () async {
    final reader = client((request) async {
      expect(request.url.path, '/api/v1/device-api/usage-report');
      expect(request.url.queryParameters.keys.toSet(),
          {'from', 'to', 'timeZone', 'period'});
      return response(reportFixture());
    });
    final value = await load(reader);
    expect(value.devices.single.deviceId, device);
    expect(value.devices.single.applications.single.buckets.single.lowerMillis,
        1501);
    expect(() => value.devices.clear(), throwsUnsupportedError);
  });
  test('binding substitutions are rejected before exposing data', () async {
    for (final field in ['deviceId', 'registrationId', 'subjectId']) {
      final value = reportFixture();
      value['devices'][0][field] = '44444444-4444-4444-4444-444444444444';
      await expectLater(load(client((_) async => response(value))),
          throwsA(isA<UsageReportFailure>()));
    }
  });
  test('session change discards late successful responses', () async {
    var active = true;
    final pending = Completer<http.Response>();
    final started = Completer<void>();
    final reader = client((_) {
      started.complete();
      return pending.future;
    }, current: () => active);
    final result = load(reader);
    final failed = expectLater(
        result,
        throwsA(isA<UsageReportFailure>()
            .having((e) => e.code, 'code', 'DEVICE_CONTEXT_CHANGED')));
    await started.future;
    active = false;
    pending.complete(response(reportFixture()));
    await failed;
  });
  test('disposed reader refuses further requests and hides in-flight responses',
      () async {
    var count = 0;
    final started = Completer<void>();
    final pending = Completer<http.Response>();
    final reader = client((_) {
      count++;
      started.complete();
      return pending.future;
    });
    final failed =
        expectLater(load(reader), throwsA(isA<UsageReportFailure>()));
    await started.future;
    reader.dispose();
    pending.complete(response(reportFixture()));
    await failed;
    await expectLater(load(reader), throwsA(isA<UsageReportFailure>()));
    expect(count, 1);
  });
  test('invalid timezone or inactive host fails before any request', () async {
    var count = 0;
    final reader = client((_) async {
      count++;
      return response(reportFixture());
    });
    await expectLater(
        reader.load(from: now - 3600000, to: now, timeZone: 'Invalid/Zone'),
        throwsA(isA<UsageReportFailure>()));
    await expectLater(
        load(client((_) async {
          count++;
          return response(reportFixture());
        }, current: () => false)),
        throwsA(isA<UsageReportFailure>()));
    expect(count, 0);
  });
}
