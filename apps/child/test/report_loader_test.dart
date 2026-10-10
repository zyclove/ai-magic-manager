import 'dart:async';
import 'dart:convert';
import 'package:child/core/report_loader.dart';
import 'package:device_observation/device_observation.dart';
import 'package:device_reports/device_reports.dart';
import 'package:usage_report_ui/usage_report_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support/identity_fixture.dart';
import 'support/report_fixture.dart' as reports;

void main() {
  late IdentityFixture identity;
  setUp(() async {
    identity = IdentityFixture();
    await identity.activate();
  });
  tearDown(() => identity.close());
  const window =
      DeviceReportWindow(reports.now - 3600000, reports.now, 'UTC', 'DAY');
  const facts = ObservationPlatformState(usageGranted: true, unlocked: true);
  test(
      'host resolves current device context before typed report with fresh credentials',
      () async {
    final session = identity.session();
    await session.initialize();
    addTearDown(session.dispose);
    final requests = <http.Request>[];
    final httpClient = MockClient((r) async {
      requests.add(r);
      return http.Response(
          jsonEncode(r.url.path.endsWith('access-context')
              ? {
                  'tenantId': IdentityFixture.tenant,
                  'deviceId': IdentityFixture.device,
                  'registrationId': IdentityFixture.registration,
                  'subjectId': reports.subject,
                }
              : reports.reportFixture()),
          200,
          headers: {'content-type': 'application/json'});
    });
    final loader = DeviceChildReports(
        session: session,
        apiRoot: Uri.parse('https://service.example/api/v1'),
        inspect: () async => facts,
        contextClient: () => httpClient,
        reportClient: () => httpClient);
    addTearDown(loader.close);
    final report = await loader.load(window);
    expect(report.devices.single.deviceId, IdentityFixture.device);
    expect(requests.map((r) => r.url.path), [
      '/api/v1/device-api/access-context',
      '/api/v1/device-api/usage-report'
    ]);
    expect(
        requests
            .every((r) => r.headers['authorization'] == 'Bearer ${'b' * 43}'),
        isTrue);
  });
  test('wrong cloud binding is rejected without requesting a report', () async {
    final session = identity.session();
    await session.initialize();
    addTearDown(session.dispose);
    var count = 0;
    final client = MockClient((_) async {
      count++;
      return http.Response(
          jsonEncode({
            'tenantId': IdentityFixture.tenant,
            'deviceId': IdentityFixture.device,
            'registrationId': IdentityFixture.enrollment,
            'subjectId': reports.subject,
          }),
          200,
          headers: {'content-type': 'application/json'});
    });
    final loader = DeviceChildReports(
        session: session,
        apiRoot: Uri.parse('https://service.example/api/v1'),
        inspect: () async => facts,
        contextClient: () => client,
        reportClient: () => client);
    addTearDown(loader.close);
    await expectLater(
        loader.load(window),
        throwsA(isA<UsageReportFailure>()
            .having((e) => e.code, 'code', 'ACCESS_TARGET_CHANGED')));
    expect(count, 1);
  });
  test('cancel during platform inspection prevents later network work',
      () async {
    final session = identity.session();
    await session.initialize();
    addTearDown(session.dispose);
    final pending = Completer<ObservationPlatformState>();
    var count = 0;
    final client = MockClient((_) async {
      count++;
      return http.Response('{}', 500);
    });
    final loader = DeviceChildReports(
        session: session,
        apiRoot: Uri.parse('https://service.example/api/v1'),
        inspect: () => pending.future,
        contextClient: () => client,
        reportClient: () => client);
    addTearDown(loader.close);
    final failure =
        expectLater(loader.load(window), throwsA(isA<UsageReportFailure>()));
    loader.cancel();
    pending.complete(facts);
    await failure;
    expect(count, 0);
  });
}
