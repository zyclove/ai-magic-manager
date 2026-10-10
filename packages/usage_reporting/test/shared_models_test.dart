import 'package:test/test.dart';
import 'package:usage_reporting/usage_reporting.dart';
import 'fixture.dart';

void main() {
  test('shared model preserves ranges, evidence and immutable results', () {
    final report = UsageReport.parse(reportFixture(), query());
    final deviceReport = report.devices.single;
    expect(deviceReport.deviceId, device);
    expect(deviceReport.applications.single.buckets.single.lowerMillis, 1501);
    expect(deviceReport.configurationState.configurations, isEmpty);
    expect(() => report.devices.clear(), throwsUnsupportedError);
    expect(() => deviceReport.applications.clear(), throwsUnsupportedError);
  });
  test('shared model rejects binding, provenance and calendar substitutions',
      () {
    final mutations = <void Function(ReportJson)>[
      (v) => v['devices'][0]['registrationId'] = subject,
      (v) => v['devices'][0]['subjectId'] = registration,
      (v) => v['devices'][0]['deviceId'] = subject,
      (v) => v['evidenceStatus'] = 'VERIFIED',
      (v) => v['timeZone'] = 'Asia/Shanghai',
      (v) =>
          v['devices'][0]['configurationState']['evidenceStatus'] = 'ENFORCED',
      (v) => v['devices'][0]['applications'][0]['classification']['source'] =
          'VERIFIED',
      (v) => v['devices'][0]['applications'][0]['buckets'][0]['end'] = now - 1,
    ];
    for (final mutate in mutations) {
      final value = reportFixture();
      mutate(value);
      expect(() => UsageReport.parse(value, query()),
          throwsA(isA<UsageReportFailure>()));
    }
  });
}
