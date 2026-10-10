import 'dart:convert';
import 'dart:io';
import 'package:child/core/report_loader.dart';
import 'package:child/core/session.dart';
import 'package:child/ui/child_app.dart';
import 'package:device_identity/device_identity.dart';
import 'package:device_observation/device_observation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Secrets implements DeviceSecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String record) async {
    value = record;
  }
}

class _TraceClient extends http.BaseClient {
  final http.Client delegate = http.Client();
  final List<String> statuses;
  _TraceClient(this.statuses);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await delegate.send(request);
    statuses.add('${request.url.path.split('/').last}:${response.statusCode}');
    return response;
  }

  @override
  void close() => delegate.close();
}

/// JVM-owned isolated fixture. Real context/report HTTP and product session/UI;
/// registration and native platform facts are explicit controlled substitutes.
void main() {
  testWidgets('real device report through ChildSession and ChildApp',
      (tester) async {
    final file = File(Platform.environment['CHILD_REPORT_HTTP_FIXTURE']!);
    final raw = await tester.runAsync(file.readAsString);
    final data = jsonDecode(raw!) as Map<String, dynamic>;
    final root = Uri.parse(data['apiRoot']);
    expect(data['testOnly'], true);
    expect(root.scheme, 'http');
    expect(root.host, '127.0.0.1');
    expect(root.path, '/api/v1');
    final now = DateTime.now().millisecondsSinceEpoch;
    final identityClient = MockClient((request) async {
      final claim = request.url.path.endsWith('enrollment-claims');
      return http.Response(
          jsonEncode(claim
              ? {
                  'deviceId': data['deviceId'],
                  'registrationId': data['registrationId'],
                  'credential': data['deviceToken'],
                  'expiresAt': now + 86400000,
                  'pairingCode': '12345678',
                  'confirmBefore': now + 600000,
                  'state': 'AWAITING_CONFIRMATION',
                }
              : {
                  'registrationId': data['registrationId'],
                  'sequence': (jsonDecode(request.body) as Map)['sequence'],
                  'receivedAt': now
                }),
          claim ? 201 : 200,
          headers: {'content-type': 'application/json'});
    });
    final identity = DeviceIdentityManager(
        api: DeviceIdentityApi(
            apiRoot: Uri.parse('https://registration-fixture.example/api/v1'),
            client: identityClient),
        secrets: _Secrets(),
        nowMillis: () => now);
    final session = ChildSession(identity: identity, nowMillis: () => now);
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    final statuses = <String>[], clients = <_TraceClient>[];
    http.Client client() {
      final value = _TraceClient(statuses);
      clients.add(value);
      return value;
    }

    Future<void> waitFor(bool Function() ready) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!ready()) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('Child report fixture deadline exceeded');
        }
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)));
      }
      await tester.pumpAndSettle();
    }

    try {
      await tester.runAsync(() async {
        await identity.begin(
            EnrollmentTicket(
                tenantId: data['tenantId'],
                enrollmentId: '22222222-2222-2222-2222-222222222222',
                token: 'a' * 43,
                expiresAt: now + 600000),
            displayName: '报表联调设备',
            osVersion: 'controlled fixture');
        await identity.heartbeat(
            agentVersion: 'report-http-acceptance', capabilities: const []);
      });
      await tester.pumpWidget(ChildApp(
          session: session,
          nativeAvailable: true,
          reportFactory: (session) => DeviceChildReports(
              session: session,
              apiRoot: root,
              allowLoopbackHttp: true,
              inspect: () async => const ObservationPlatformState(
                  usageGranted: true, unlocked: true),
              contextClient: client,
              reportClient: client)));
      await waitFor(() => session.initialized && !session.busy);
      await tester.tap(find.text('使用'));
      await tester.pump();
      if (data['deviceExpectedStatus'] == 401) {
        await waitFor(
            () => find.textContaining('设备连接或访问权限已变化').evaluate().isNotEmpty);
        expect(statuses, contains('access-context:401'));
        expect(statuses.any((v) => v.startsWith('usage-report:')), isFalse);
        expect(find.text('使用趋势'), findsNothing);
        stdout.writeln('PASS child device report revoked HTTP');
      } else {
        await waitFor(() => find.text('使用趋势').evaluate().isNotEmpty);
        expect(
            statuses, containsAll(['access-context:200', 'usage-report:200']));
        final rules = find.textContaining('当前规则与下发状态');
        await tester.ensureVisible(rules);
        await tester.tap(rules);
        await tester.pumpAndSettle();
        expect(find.text('使用提醒 · 配置目标：提醒'), findsOneWidget);
        expect(find.text('配置时长：15 分钟'), findsOneWidget);
        stdout.writeln('PASS child device report HTTP');
      }
      await tester.tap(find.text('设备'));
      await tester.pumpAndSettle();
      expect(find.text('使用趋势'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      for (final value in clients) {
        value.close();
      }
      identityClient.close();
      HttpOverrides.global = previous;
    }
  });
}
