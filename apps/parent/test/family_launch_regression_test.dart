import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family.dart';
import 'package:parent/core/family_payment.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/ui/family_assistant.dart';
import 'package:parent/ui/family_membership.dart';
import 'package:parent/ui/family_rules_page.dart';
import 'family_workspace_test.dart' show FamilySession, familyDashboard;
import 'family_service_test.dart' show ruleView;

class MemoryStore extends ParentDurableStorage {
  final values = <String, String>{};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

http.Response response(Object value, {int status = 200}) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
void main() {
  test(
      'definite obsolete quote clears only an uncreated order and permits a fresh reviewed quote',
      () async {
    final sent = <http.Request>[], storage = MemoryStore();
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      sent.add(r);
      return sent.length == 1
          ? response({'errorCode': 'FAMILY_OFFER_CHANGED'}, status: 409)
          : response(
              {'id': 'order', 'tenantId': 'family', 'status': 'CREATED'});
    }));
    addTearDown(api.close);
    final payment = FamilyPaymentCoordinator(
        service:
            FamilyService(api: api, tenantId: 'family', available: () => true),
        actor: 'adult',
        storage: storage);
    await payment.restore();
    await expectLater(payment.createOrder('FAMILY_MONTH'),
        throwsA(isA<ParentApiException>()));
    expect(storage.values, isEmpty);
    expect(payment.pendingPlanKey, isNull);
    await payment.createOrder('FAMILY_YEAR', offerVersion: 2);
    expect(jsonDecode(sent.last.body),
        {'planKey': 'FAMILY_YEAR', 'offerVersion': 2});
    expect(sent.last.headers['Idempotency-Key'],
        isNot(sent.first.headers['Idempotency-Key']));
  });
  testWidgets('report explanation sends the explicit current device',
      (tester) async {
    final sent = <http.Request>[];
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      sent.add(r);
      return response({
        'id': 'suggestion',
        'task': 'REPORT_EXPLANATION',
        'status': 'FALLBACK',
        'summary': '记录不足，请先核对授权。',
        'evidence': [],
        'limitations': ['本次未调用模型'],
        'ruleDraft': null
      });
    }));
    final session = FamilySession(api);
    addTearDown(session.dispose);
    final child = FamilyDashboard.fromJson(familyDashboard()).children.single;
    await tester.pumpWidget(MaterialApp(
        home: FamilyAssistantPage(
            session: session,
            child: child,
            task: 'REPORT_EXPLANATION',
            pendingStorage: MemoryStore())));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '看看本周使用记录');
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.ensureVisible(find.text('生成建议'));
    await tester.tap(find.text('生成建议'));
    await tester.pumpAndSettle();
    expect(sent.length, 1);
    expect(jsonDecode(sent.single.body)['deviceId'], child.devices.single.id);
  });
  testWidgets('stale AI draft cannot be rebased onto a newly saved rule',
      (tester) async {
    final calls = <http.Request>[];
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      calls.add(r);
      return response(ruleView(version: 3));
    }));
    final session = FamilySession(api);
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        home: FamilyRulesPage(
            session: session,
            child: FamilyDashboard.fromJson(familyDashboard()).children.single,
            initialDraft: FamilyRules.fromJson(ruleView(version: 2)).toBody(),
            initialDraftVersion: 2)));
    await tester.pumpAndSettle();
    expect(find.text('重新读取规则'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(calls.where((r) => r.method != 'GET'), isEmpty);
  });
  for (final state in ['PAID', 'PAYMENT_PENDING']) {
    testWidgets(
        'order $state restores authoritative refund and payment actions',
        (tester) async {
      final reads = <String>[];
      final api = ParentApi(() async => 'fixture',
          baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
        reads.add(r.url.path);
        if (r.url.path.endsWith('/subscription')) {
          return response({'tenantId': 'family', 'paymentAvailable': true});
        }
        if (r.url.path.endsWith('/refund-requests')) {
          return response({
            'items': state == 'PAID'
                ? [
                    {
                      'id': 'refund',
                      'orderId': 'order',
                      'status': 'AWAITING_REVIEW',
                      'priceMinor': 1900,
                      'currency': 'CNY',
                      'reason': '暂时不需要',
                      'createdAt': 1792051200000
                    }
                  ]
                : []
          });
        }
        return response({
          'id': 'order',
          'tenantId': 'family',
          'status': state,
          'priceMinor': 1900,
          'currency': 'CNY',
          'expiresAt': 4102444800000,
          'createdAt': 1792051200000,
          'periodStart': 1792051200000,
          'periodEnd': 1794733200000
        });
      }));
      final session = FamilySession(api);
      addTearDown(session.dispose);
      final payment = FamilyPaymentCoordinator(
          service: FamilyService(
              api: api, tenantId: 'family', available: () => true),
          actor: 'adult',
          storage: MemoryStore());
      await tester.pumpWidget(MaterialApp(
          home: FamilyOrderPage(
              session: session,
              orderId: 'order',
              payment: payment,
              refundStorage: MemoryStore())));
      await tester.pumpAndSettle();
      expect(reads, contains('/tenants/family/orders/order/refund-requests'));
      if (state == 'PAID') {
        await tester.ensureVisible(find.text('退款申请审核中'));
        await tester.pumpAndSettle();
        expect(find.text('退款申请审核中'), findsOneWidget);
        expect(find.text('申请原路全额退款'), findsNothing);
      } else {
        expect(find.text('使用微信支付'), findsOneWidget);
        expect(find.text('核对付款结果'), findsOneWidget);
      }
    });
  }
  testWidgets('unknown refund read blocks another refund request',
      (tester) async {
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/subscription')) {
        return response({'tenantId': 'family', 'paymentAvailable': true});
      }
      if (r.url.path.endsWith('/refund-requests')) {
        return response({'errorCode': 'UNAVAILABLE'}, status: 503);
      }
      return response({
        'id': 'order',
        'tenantId': 'family',
        'status': 'PAID',
        'priceMinor': 1900,
        'currency': 'CNY',
        'expiresAt': 4102444800000,
        'createdAt': 1792051200000,
        'periodStart': 1792051200000,
        'periodEnd': 1794733200000
      });
    }));
    final session = FamilySession(api);
    addTearDown(session.dispose);
    final payment = FamilyPaymentCoordinator(
        service:
            FamilyService(api: api, tenantId: 'family', available: () => true),
        actor: 'adult',
        storage: MemoryStore());
    await tester.pumpWidget(MaterialApp(
        home: FamilyOrderPage(
            session: session,
            orderId: 'order',
            payment: payment,
            refundStorage: MemoryStore())));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '申请原路全额退款'))
            .onPressed,
        isNull);
  });
}
