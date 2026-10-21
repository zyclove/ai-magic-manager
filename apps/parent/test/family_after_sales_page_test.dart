import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family.dart';
import 'package:parent/core/family_payment.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/ui/family_membership.dart';
import 'package:parent/ui/family_workspace.dart';
import 'family_device_access_test.dart' show SelectionMemoryStorage;
import 'family_workspace_test.dart' show FamilySession;
import 'family_after_sales_test.dart' show refundValue;

class AfterSalesFixture {
  final store = SelectionMemoryStorage();
  final sent = <http.Request>[];
  final String orderStatus;
  final bool expired, paymentAvailable;
  Json? refund;
  int refundAttempts = 0;
  bool failRefund = false;
  late final ParentApi api;
  late final FamilySession session;
  AfterSalesFixture(
      {this.orderStatus = 'PAID',
      this.expired = false,
      this.paymentAvailable = false,
      this.refund}) {
    api = ParentApi(() async => 'fixture', baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async {
      sent.add(r);
      if (r.method == 'POST' && r.url.path.endsWith('/refund-requests')) {
        refundAttempts++;
        if (failRefund) {
          return http.Response('{"errorCode":"UNAVAILABLE"}', 503);
        }
        refund = refundValue();
        return response(refund!);
      }
      if (r.url.path.endsWith('/subscription')) {
        return response(
            {'tenantId': 'family', 'paymentAvailable': paymentAvailable});
      }
      if (r.url.path.endsWith('/orders/order-1')) {
        return response({
          'id': 'order-1',
          'tenantId': 'family',
          'status': orderStatus,
          'planKey': 'FAMILY_MONTH',
          'currency': 'CNY',
          'priceMinor': 1900,
          'createdAt': 1792051200000,
          'expiresAt': expired ? 1 : 4102444800000,
          'periodStart': 1792051200000,
          'periodEnd': 1794729600000,
        });
      }
      if (r.url.path.endsWith('/refund-requests')) {
        return response({
          'items': refund == null ? [] : [refund]
        });
      }
      if (r.url.path.contains('/refund-requests/')) return response(refund!);
      return response({});
    }));
    session = FamilySession(api);
  }
  http.Response response(Json value) => http.Response(jsonEncode(value), 200,
      headers: {'content-type': 'application/json; charset=utf-8'});
  Widget page({GlobalKey? screenshot}) {
    final payment = FamilyPaymentCoordinator(
        service:
            FamilyService(api: api, tenantId: 'family', available: () => true),
        actor: 'adult',
        storage: store);
    final child = FamilyOrderPage(
        session: session,
        orderId: 'order-1',
        payment: payment,
        refundStorage: store);
    return MaterialApp(
        theme: familyTheme(),
        home: screenshot == null
            ? child
            : RepaintBoundary(key: screenshot, child: child));
  }

  void dispose() {
    session.dispose();
    api.close();
  }
}

Future<void> applyRefund(WidgetTester tester) async {
  await tester.scrollUntilVisible(find.text('申请原路全额退款'), 150,
      scrollable: find.byType(Scrollable).first);
  await tester.tap(find.text('申请原路全额退款'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), '暂时不需要');
  await tester.tap(find.text('确认申请'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'guardian sees order and progress without paid or refund mutations',
      (tester) async {
    final f = AfterSalesFixture();
    addTearDown(f.dispose);
    f.session.role = 'GUARDIAN';
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    expect(find.text('申请原路全额退款'), findsNothing);
    expect(find.textContaining('家庭所有者'), findsOneWidget);
    expect(f.sent.where((r) => r.method != 'GET'), isEmpty);
  });
  testWidgets(
      'approved refund is advanced by service and refresh only reads facts',
      (tester) async {
    final f = AfterSalesFixture(refund: refundValue(status: 'REQUESTED'));
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('审核通过，等待原路退款'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('提交原路全额退款'), findsNothing);
    expect(find.text('核验退款结果'), findsNothing);
    await tester.scrollUntilVisible(find.text('刷新订单与退款进度'), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('刷新订单与退款进度'));
    await tester.pumpAndSettle();
    expect(f.sent.where((r) => r.method != 'GET'), isEmpty);
  });
  testWidgets(
      'expired payment waits for authoritative close and cannot launch pay',
      (tester) async {
    final f = AfterSalesFixture(
        orderStatus: 'CREATED', expired: true, paymentAvailable: true);
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    expect(find.text('付款结果待核实'), findsOneWidget);
    expect(find.textContaining('正在核对付款和关单结果'), findsOneWidget);
    expect(find.text('使用微信支付'), findsNothing);
    expect(f.sent.where((r) => r.method != 'GET'), isEmpty);
  });
  testWidgets('server closed order is displayed as closed', (tester) async {
    final f = AfterSalesFixture(orderStatus: 'CLOSED');
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    expect(find.text('订单已关闭'), findsOneWidget);
    expect(find.text('使用微信支付'), findsNothing);
  });
  testWidgets(
      'unknown refund after page recreation needs explicit original confirmation',
      (tester) async {
    final f = AfterSalesFixture()..failRefund = true;
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    await applyRefund(tester);
    expect(f.refundAttempts, 1);
    expect(f.store.values, isNotEmpty);
    final first = f.sent.singleWhere((r) => r.method == 'POST');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    expect(f.refundAttempts, 1);
    await tester.scrollUntilVisible(find.text('核对原退款申请'), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('核对原退款申请'));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂时不需要'), findsWidgets);
    f.failRefund = false;
    await tester.tap(find.text('确认并继续原申请'));
    await tester.pumpAndSettle();
    expect(f.refundAttempts, 2);
    final last = f.sent.lastWhere((r) => r.method == 'POST');
    expect(last.body, first.body);
    expect(last.headers['Idempotency-Key'], first.headers['Idempotency-Key']);
    expect(f.store.values, isEmpty);
  });
  testWidgets(
      'backgrounding an open refund confirmation invalidates its submit',
      (tester) async {
    final f = AfterSalesFixture();
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('申请原路全额退款'), 150,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('申请原路全额退款'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '暂时不需要');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('确认申请'), findsNothing);
    expect(f.refundAttempts, 0);
  });
  testWidgets(
      'late reads cannot repopulate an order after leaving and returning',
      (tester) async {
    final f = AfterSalesFixture();
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    f.session.leaveAndReturn();
    await tester.pumpAndSettle();
    expect(find.text('已支付'), findsNothing);
    expect(find.textContaining('当前家庭或权限已变化'), findsOneWidget);
  });
  testWidgets('after sales supports 320 width and double font without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final f = AfterSalesFixture(refund: refundValue(status: 'ABNORMAL'));
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('需要人工协助'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
  });
  testWidgets('capture fictional reviewed refund state', (tester) async {
    if (!const bool.fromEnvironment('CAPTURE_FAMILY_AFTER_SALES')) return;
    await tester.runAsync(() async {
      final font = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
      await (FontLoader('Roboto')
            ..addFont(Future.value(ByteData.sublistView(font))))
          .load();
      final icons = await File(
              'D:/softwares/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
          .readAsBytes();
      await (FontLoader('MaterialIcons')
            ..addFont(Future.value(ByteData.sublistView(icons))))
          .load();
    });
    tester.view.physicalSize = const Size(430, 1150);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final f = AfterSalesFixture(refund: refundValue(status: 'AWAITING_REVIEW'));
    addTearDown(f.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(f.page(screenshot: key));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image = await (key.currentContext!.findRenderObject()
              as RenderRepaintBoundary)
          .toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File(
              '../../.local/family-p0-commerce-20261016/after-sales-fictional.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
  });
}
