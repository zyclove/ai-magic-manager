import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:guardian/core/api.dart';
import 'package:guardian/core/usage_reports.dart';
import 'package:guardian/core/application_classification.dart';

/// Loopback integration fixture only; uses the production report client and parser.
class FixtureClient extends http.BaseClient {
  final http.Client delegate = http.Client();
  final String token;
  FixtureClient(this.token);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer $token';
    return delegate.send(request);
  }

  @override
  void close() => delegate.close();
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> args) async {
  require(args.length == 1, 'Fixture path required');
  final file = File(args.single);
  require(await file.length() < 16384, 'Fixture too large');
  final v = jsonDecode(await file.readAsString()) as Json,
      uri = Uri.parse(v['apiRoot']);
  require(
      v['testOnly'] == true &&
          uri.scheme == 'http' &&
          uri.host == '127.0.0.1' &&
          uri.hasPort &&
          uri.path == '/api/v1',
      'Loopback test fixture required');
  final ownerClient = FixtureClient(v['ownerToken']),
      childClient = FixtureClient(v['childToken']);
  final target = UsageReportTarget(
      v['deviceId'], v['registrationId'], v['subjectId'], 'Fixture');
  UsageReportRepository repository(http.Client client) => UsageReportRepository(
      api: Api(() async => client, baseUrl: v['apiRoot']),
      root: '/tenants/${v['tenantId']}',
      current: () => true);
  UsageReportQuery query(
          [UsageReportScope scope = const UsageReportScope.devices()]) =>
      UsageReportQuery(
          targets: [target],
          from: v['from'],
          to: v['to'],
          timeZone: 'UTC',
          period: 'DAY',
          scope: scope);
  Future<void> denied(Future<UsageReport> response, int status) async {
    try {
      await response;
      throw StateError('Unexpected authorization success');
    } on ApiFailure catch (error) {
      require(
          error.status == status, 'Unexpected error status ${error.status}');
    }
  }

  try {
    final owner = repository(ownerClient), child = repository(childClient);
    final report = await owner.load(query());
    require(
        report.devices.single.configurationState.configurations.single.rules
                .single.kind ==
            'USAGE_REMINDER',
        'Missing current configuration rule from the real report');
    require(
        report.devices.single.configurationState.configurations.single
                .deliveryState ==
            'PENDING_SIGNATURE',
        'Configuration transport must not become verified execution');
    require(
        report.devices.single.status == 'OBSERVED', 'Missing real observation');
    require(
        report.devices.single.applications.single.classification.source ==
            'NONE',
        'Unclassified observation must preserve explicit source');
    require(
        report.devices.single.applications.single.buckets.single.lowerMillis ==
            2000,
        'Incorrect real aggregate');
    final classifications = ApplicationClassificationRepository(
        api: Api(() async => ownerClient, baseUrl: v['apiRoot']),
        root: '/tenants/${v['tenantId']}',
        applicationId: v['applicationId'],
        identity: const ApplicationClassificationIdentity(
            'ANDROID', 'PRIMARY', 'org.example.reader'),
        current: () => true);
    final before = await classifications.load();
    require(before.version == 0 && before.source == 'NONE',
        'Unexpected initial category');
    final changed = await classifications.save(
        before, 'EDUCATION', 'usage-report-http-classification');
    require(changed.version == 1 && changed.source == 'ADMIN_DECLARED',
        'Missing classification write');
    require(
        (await owner.load(query()))
                .devices
                .single
                .applications
                .single
                .classification
                .category ==
            'EDUCATION',
        'Report did not consume current declared category');
    final own =
        UsageReportScope(kind: 'SUBJECT', id: target.subjectId, label: '自己的档案');
    require((await child.load(query(own))).scope.id == target.subjectId,
        'Child scope lost');
    final classroom = UsageReportScope(
        kind: 'CLASS',
        id: v['classId'],
        version: 0,
        label: '班级',
        subjectIds: [target.subjectId]);
    require((await owner.load(query(classroom))).scope.version == 0,
        'Class version lost');
    await denied(child.load(query(classroom)), 403);
    await denied(
        owner.load(query(UsageReportScope(
            kind: 'CLASS',
            id: v['classId'],
            version: 1,
            label: '旧名册',
            subjectIds: [target.subjectId]))),
        409);
    stdout.writeln(
        'PASS usage report HTTP: production parser, device/subject/class scope, child isolation, stale roster');
  } finally {
    ownerClient.close();
    childClient.close();
  }
}
