import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/family.dart';

Map<String, dynamic> ruleView({int version = 3}) => {
      'subjectId': 'child',
      'version': version,
      'enabled': true,
      'dailyAllowanceSeconds': 1800,
      'timeZoneId': 'Asia/Shanghai',
      'meteredPackages': ['com.example.game'],
      'allowedWindows': [
        {
          'daysOfWeek': [1, 2, 3, 4, 5],
          'startMinute': 1080,
          'endMinute': 1200
        }
      ],
      'deliveryState': 'CONFIGURED_NOT_ENFORCED'
    };

void main() {
  test(
      'rule save carries explicit version and idempotency and never saves on stale scope',
      () async {
    http.Request? request;
    var current = true;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      request = r;
      return http.Response(jsonEncode(ruleView(version: 4)), 200);
    }));
    addTearDown(api.close);
    final service =
        FamilyService(api: api, tenantId: 'family', available: () => current);
    final rules = FamilyRules.fromJson(ruleView());
    final saved = await service.saveRules('child', rules,
        idempotencyKey: 'same-operation');
    expect(saved.version, 4);
    expect(request!.url.path, '/tenants/family/subjects/child/family-rules');
    expect(request!.headers['If-Match'], '"3"');
    expect(request!.headers['Idempotency-Key'], 'same-operation');
    expect(jsonDecode(request!.body), {
      'enabled': true,
      'dailyAllowanceSeconds': 1800,
      'timeZoneId': 'Asia/Shanghai',
      'meteredPackages': ['com.example.game'],
      'allowedWindows': [
        {
          'daysOfWeek': [1, 2, 3, 4, 5],
          'startMinute': 1080,
          'endMinute': 1200
        }
      ]
    });
    request = null;
    current = false;
    await expectLater(
        service.saveRules('child', rules, idempotencyKey: 'same-operation'),
        throwsA(isA<ParentApiException>()));
    expect(request, isNull);
  });

  test('malformed allowance and mismatched child rules are rejected', () async {
    expect(
        () =>
            FamilyRules.fromJson({...ruleView(), 'dailyAllowanceSeconds': -1}),
        throwsA(isA<ParentApiException>()));
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => http.Response(
            jsonEncode({...ruleView(), 'subjectId': 'other'}), 200)));
    addTearDown(api.close);
    final service =
        FamilyService(api: api, tenantId: 'family', available: () => true);
    await expectLater(
        service.rules('child'), throwsA(isA<ParentApiException>()));
  });

  test('a missing dashboard runtime cannot become zero usage', () {
    final dashboard = FamilyDashboard.fromJson({
      'tenantId': 'family',
      'generatedAt': 1792051200000,
      'systemEnforced': false,
      'pendingRequestCount': 0,
      'openHelpRequestCount': 0,
      'children': [
        {
          'id': 'child',
          'nickname': '小明',
          'ageBand': 'AGE_7_12',
          'rules': null,
          'devices': [
            {
              'id': 'device',
              'displayName': '手机',
              'registrationId': 'registration',
              'lastHeartbeatAt': null,
              'runtime': null,
              'ruleState': 'NOT_CONFIGURED'
            }
          ]
        }
      ]
    });
    expect(dashboard.children.single.devices.single.observedSeconds, isNull);
  });

  test(
      'AI requests require explicit cloud consent and send only selected context',
      () async {
    http.Request? request;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      request = r;
      return http.Response(
          jsonEncode({
            'id': 's',
            'task': 'RULE_DRAFT',
            'status': 'FALLBACK',
            'summary': '服务暂不可用',
            'evidence': [],
            'limitations': ['未调用云模型'],
            'ruleDraft': null,
            'expiresAt': 1792051200000,
            'model': null,
            'remainingRequests': null
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }));
    addTearDown(api.close);
    final service =
        FamilyService(api: api, tenantId: 'family', available: () => true);
    await expectLater(
        service.suggest(
            task: 'RULE_DRAFT',
            subjectId: 'child',
            prompt: '安排放学时间',
            idempotencyKey: 'same-ai-operation',
            cloudConsent: false),
        throwsA(isA<ParentApiException>()));
    expect(request, isNull);
    final suggestion = await service.suggest(
        task: 'RULE_DRAFT',
        subjectId: 'child',
        prompt: '安排放学时间',
        idempotencyKey: 'same-ai-operation',
        cloudConsent: true);
    expect(suggestion['status'], 'FALLBACK');
    expect(request!.headers['Idempotency-Key'], 'same-ai-operation');
    expect(jsonDecode(request!.body), {
      'task': 'RULE_DRAFT',
      'subjectId': 'child',
      'prompt': '安排放学时间',
      'cloudConsent': true
    });
  });
}
