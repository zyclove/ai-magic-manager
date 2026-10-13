import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/core/usage_reports.dart';
import 'package:parent/ui/usage_report_center.dart';
import 'package:usage_reporting/usage_reporting.dart';
import '../../../packages/usage_report_ui/test/fixture.dart' as fixture;

Json _device() => {
      'id': fixture.device,
      'registrationId': fixture.registration,
      'subjectId': fixture.subject,
      'displayName': '平板',
      'platform': 'ANDROID',
      'state': 'ACTIVE'
    };
Json _report(UsageReportQuery q, {String status = 'NO_DATA'}) {
  final data = fixture.reportFixture(),
      generated = DateTime.now().millisecondsSinceEpoch;
  final end = q.to < generated ? q.to : generated;
  data.addAll({
    'generatedAt': generated,
    'from': q.from,
    'to': end,
    'requestedTo': q.to,
    'timeZone': q.timeZone,
    'period': q.period
  });
  (data['devices'][0] as Json).addAll({
    'status': status,
    'sourceBatchCount': 0,
    'sourceTimeZones': [],
    'latestObservedAt': null,
    'latestReceivedAt': null,
    'queryCoverageMillis': 0,
    'uncoveredQueryMillis': end - q.from,
    'applications': [],
    'configurationState': {
      'checkedAt': generated,
      'evidenceStatus': 'DELIVERY_ONLY_NOT_EXECUTION',
      'configurations': []
    }
  });
  return data;
}

http.Response _response(Json data, {Map<String, String>? headers}) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), 200,
        headers: headers ?? {'content-type': 'application/json'});
ParentApi _api({Json? device}) => ParentApi(() async => 'fixture',
    baseUrl: 'https://fixture.invalid/api/v1',
    client: MockClient((_) async => _response(device ?? _device())));

class _Session extends ParentSession {
  final ParentApi fixtureApi;
  _Session(this.fixtureApi) {
    tenant = {'id': 'tenant', 'timeZone': 'UTC'};
    profile = {'subject': 'adult'};
    role = 'GUARDIAN';
  }
  @override
  ParentApi get api => fixtureApi;
  @override
  bool get authenticated => true;
  @override
  Future<String> token() async => 'fixture';
  void revoke() {
    role = 'AUDITOR';
    notifyListeners();
  }
}

void main() {
  test('report transport keeps exact registration and JSON contract', () async {
    final q = fixture.query();
    var requests = 0;
    final loader = ParentUsageReportLoader(
        api: _api(),
        tenant: 'tenant',
        token: () async => 'fixture',
        available: () => true,
        clientFactory: () => MockClient((r) async {
              requests++;
              expect(r.followRedirects, isFalse);
              expect(r.headers['Cache-Control'], 'no-store');
              expect(r.headers['Authorization'], 'Bearer fixture');
              expect(r.url.path, '/api/v1/tenants/tenant/usage-reports');
              return _response(_report(q));
            }));
    final result = await loader.load(q);
    expect(result.devices.single.status, 'NO_DATA');
    expect(result.devices.single.applications, isEmpty);
    expect(requests, 1);
  });
  test('registration change stops report before opening its connection',
      () async {
    var connections = 0;
    final loader = ParentUsageReportLoader(
        api: _api(device: {..._device(), 'registrationId': fixture.subject}),
        tenant: 'tenant',
        token: () async => 'fixture',
        available: () => true,
        clientFactory: () {
          connections++;
          return MockClient((_) async => _response({}));
        });
    await expectLater(
        loader.load(fixture.query()),
        throwsA(isA<UsageReportFailure>()
            .having((e) => e.code, 'code', 'REPORT_SCOPE_CHANGED')));
    expect(connections, 0);
  });
  test('cancelling token wait prevents late report request', () async {
    final token = Completer<String>();
    var connections = 0;
    final loader = ParentUsageReportLoader(
        api: _api(),
        tenant: 'tenant',
        token: () => token.future,
        available: () => true,
        clientFactory: () {
          connections++;
          return MockClient((_) async => _response({}));
        });
    final future = loader.load(fixture.query());
    await Future<void>.delayed(Duration.zero);
    loader.cancel();
    token.complete('later');
    await expectLater(future, throwsA(isA<UsageReportFailure>()));
    expect(connections, 0);
  });
  for (final kind in [
    'wrong-content',
    'oversized',
    'redirect',
    'wrong-registration'
  ]) {
    test('rejects $kind response without presenting activity', () async {
      final q = fixture.query();
      final raw = _report(q);
      if (kind == 'wrong-registration') {
        raw['devices'][0]['registrationId'] = fixture.subject;
      }
      final loader = ParentUsageReportLoader(
          api: _api(),
          tenant: 'tenant',
          token: () async => 'fixture',
          available: () => true,
          clientFactory: () => MockClient.streaming((_, __) async {
                if (kind == 'oversized') {
                  return http.StreamedResponse(const Stream.empty(), 200,
                      contentLength: 8 * 1024 * 1024 + 1);
                }
                return http.StreamedResponse(
                    Stream.value(utf8.encode(jsonEncode(raw))),
                    kind == 'redirect' ? 302 : 200,
                    headers: {
                      'content-type': kind == 'wrong-content'
                          ? 'text/html'
                          : 'application/json'
                    });
              }));
      await expectLater(loader.load(q), throwsA(isA<UsageReportFailure>()));
    });
  }
  test('cancels a hanging body promptly and releases the report stream',
      () async {
    final started = Completer<void>(), cancelled = Completer<void>();
    final stream = StreamController<List<int>>(onCancel: () {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    final loader = ParentUsageReportLoader(
        api: _api(),
        tenant: 'tenant',
        token: () async => 'fixture',
        available: () => true,
        clientFactory: () => MockClient.streaming((_, __) async {
              started.complete();
              return http.StreamedResponse(stream.stream, 200,
                  headers: {'content-type': 'application/json'});
            }));
    final future = loader.load(fixture.query());
    final check = expectLater(future, throwsA(isA<UsageReportFailure>()));
    await started.future;
    await Future<void>.delayed(Duration.zero);
    loader.cancel();
    await check;
    await cancelled.future.timeout(const Duration(seconds: 1));
    await stream.close();
  });
  testWidgets(
      'parent report distinguishes missing authorization and removes content on revoke',
      (tester) async {
    final api = _api(), session = _Session(_api());
    final loader = ParentUsageReportLoader(
        api: api,
        tenant: 'tenant',
        token: () async => 'fixture',
        available: () => session.canDecide,
        clientFactory: () => MockClient((r) async {
              final q = UsageReportQuery(
                  targets: [fixture.target],
                  from: int.parse(r.url.queryParameters['from']!),
                  to: int.parse(r.url.queryParameters['to']!),
                  timeZone: r.url.queryParameters['timeZone']!,
                  period: r.url.queryParameters['period']!);
              return _response(_report(q, status: 'NOT_AUTHORIZED'));
            }));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                        builder: (_) => ParentDeviceReportPage(
                            session: session,
                            target: fixture.target,
                            loader: loader))),
                    child: const Text('查看'))))));
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('使用观察尚未授权'));
    expect(find.text('使用观察尚未授权'), findsOneWidget);
    expect(find.textContaining('当前没有有效的使用观察授权'), findsOneWidget);
    expect(find.text('0 分钟'), findsNothing);
    session.revoke();
    await tester.pumpAndSettle();
    expect(find.text('查看'), findsOneWidget);
    expect(find.text('设备使用情况'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
