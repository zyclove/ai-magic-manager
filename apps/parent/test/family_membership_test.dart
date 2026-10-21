import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/ui/family_membership.dart';
import 'family_workspace_test.dart' show FamilySession;
import 'family_device_access_test.dart' show deviceAccessView;

class _PaymentStore extends ParentDurableStorage {
  @override
  Future<String?> read({required String key}) async => null;
}

void main() {
  testWidgets('guardian membership is read only even when payment is available',
      (tester) async {
    final writes = <String>[];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method != 'GET') writes.add(r.url.path);
      final data = r.url.path.endsWith('/family-device-access')
          ? deviceAccessView(status: 'FREE')
          : r.url.path.endsWith('/subscription')
              ? {
                  'tenantId': 'family',
                  'status': 'NONE',
                  'childDeviceLimit': 1,
                  'renewalMode': 'MANUAL',
                  'paymentAvailable': true,
                  'trialEligible': true
                }
              : r.url.path.endsWith('/subscription-offers')
                  ? {
                      'items': [
                        {
                          'planKey': 'FAMILY_MONTH',
                          'period': 'MONTH',
                          'priceMinor': 1900,
                          'currency': 'CNY',
                          'childDeviceLimit': 3,
                          'renewalMode': 'MANUAL',
                          'paymentAvailable': true
                        }
                      ]
                    }
                  : {'items': [], 'nextCursor': null};
      return http.Response(jsonEncode(data), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    })))
      ..role = 'GUARDIAN';
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        home: FamilyMembershipPage(
            session: session, paymentStorage: _PaymentStore())));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('19/月'), 150);
    expect(find.text('创建待支付订单'), findsNothing);
    expect(find.text('核对激活并领取 7 天试用'), findsNothing);
    expect(find.textContaining('家庭所有者'), findsOneWidget);
    expect(writes, isEmpty);
  });
  testWidgets(
      'unavailable payment shows real offers but cannot create a paid order',
      (tester) async {
    final writes = <String>[];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method != 'GET') writes.add(r.url.path);
      final data = r.url.path.endsWith('/family-device-access')
          ? deviceAccessView(status: 'FREE')
          : r.url.path.endsWith('/subscription')
              ? {
                  'tenantId': 'family',
                  'status': 'NONE',
                  'periodStart': null,
                  'periodEnd': null,
                  'childDeviceLimit': 0,
                  'renewalMode': 'MANUAL',
                  'paymentAvailable': false,
                  'trialEligible': false
                }
              : r.url.path.endsWith('/subscription-offers')
                  ? {
                      'items': [
                        {
                          'planKey': 'FAMILY_MONTH',
                          'period': 'MONTH',
                          'priceMinor': 1900,
                          'currency': 'CNY',
                          'childDeviceLimit': 3,
                          'renewalMode': 'MANUAL',
                          'paymentAvailable': false
                        },
                        {
                          'planKey': 'FAMILY_YEAR',
                          'period': 'YEAR',
                          'priceMinor': 19900,
                          'currency': 'CNY',
                          'childDeviceLimit': 3,
                          'renewalMode': 'MANUAL',
                          'paymentAvailable': false
                        }
                      ]
                    }
                  : {'items': [], 'nextCursor': null};
      return http.Response(jsonEncode(data), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    })));
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        home: FamilyMembershipPage(
            session: session, paymentStorage: _PaymentStore())));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.textContaining('19/月'), 160);
    expect(find.textContaining('19/月'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('199/年'), 160);
    expect(find.textContaining('199/年'), findsOneWidget);
    await tester.scrollUntilVisible(find.textContaining('微信支付尚未开放'), -160);
    expect(find.textContaining('微信支付尚未开放'), findsWidgets);
    await tester.scrollUntilVisible(find.text('当前没有生效的会员'), -240);
    expect(find.text('当前没有生效的会员'), findsOneWidget);
    expect(writes, isEmpty);
  });
}
