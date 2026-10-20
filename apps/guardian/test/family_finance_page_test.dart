import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/family_finance_page.dart';
import 'family_finance_test.dart';

class FinancePageFixture {
  final storage = FinanceMemoryStorage(), changes = ChangeNotifier();
  final sent = <http.Request>[];
  bool current = true, self = false, failReview = false;
  int reauthentications = 0;
  int attempts = 1;
  String taskStatus = 'PARTIAL';
  String? reviewError;
  late final Api api;
  FinancePageFixture() {
    api = Api(
        () async => MockClient((r) async {
              sent.add(r);
              if (r.method == 'POST' && r.url.path.endsWith('/reviews')) {
                return reviewError != null
                    ? financeResponse({'errorCode': reviewError}, status: 403)
                    : failReview
                        ? financeResponse({'errorCode': 'UNAVAILABLE'},
                            status: 503)
                        : financeResponse({
                            'id': refundId,
                            'status': jsonDecode(r.body)['decision'] == 'DENY'
                                ? 'DECLINED'
                                : 'REQUESTED',
                            'externalRefundSubmitted': false
                          });
              }
              if (r.url.path.endsWith('/preview')) {
                return financeResponse(reviewPreview());
              }
              if (r.url.path.endsWith('/refund-requests/$refundId')) {
                return financeResponse(refundCase(canReview: !self));
              }
              if (r.url.path.endsWith('/refund-requests')) {
                return financeResponse({
                  'items': [refundCase(canReview: !self)],
                  'nextCursor': null
                });
              }
              if (r.method == 'POST' &&
                  r.url.path.endsWith('/acknowledgements')) {
                return financeResponse(
                    {...difference(state: 'ACKNOWLEDGED'), 'note': '已经登记人工跟进'});
              }
              if (r.url.path.endsWith('/differences')) {
                return financeResponse({
                  'items': [difference()],
                  'nextCursor': null
                });
              }
              if (r.url.path.endsWith('/tasks/$taskId')) {
                return financeResponse({
                  ...billTask(status: taskStatus),
                  'attemptCount': attempts
                });
              }
              if (r.url.path.endsWith('/tasks')) {
                return financeResponse({
                  'items': [
                    {...billTask(status: taskStatus), 'attemptCount': attempts}
                  ],
                  'nextCursor': null
                });
              }
              return financeResponse({'queued': true, 'resourceId': orderId});
            }),
        baseUrl: 'https://fixture.invalid');
  }
  Widget page(
      {bool refunds = true,
      bool finance = true,
      bool outerScroll = false,
      GlobalKey? boundary}) {
    final child = FamilyFinancePage(
        api: api,
        actor: 'operator',
        canReviewRefunds: refunds,
        canManageFinance: finance,
        changes: changes,
        isCurrent: () => current,
        reauthenticate: () => reauthentications++,
        storage: storage);
    return MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: boundary == null
                ? (outerScroll ? SingleChildScrollView(child: child) : child)
                : RepaintBoundary(
                    key: boundary,
                    child: ColoredBox(color: canvas, child: child))));
  }

  void dispose() => changes.dispose();
}

Future<void> openReview(WidgetTester tester) async {
  await tester.tap(find.text('查看并审核'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.widgetWithText(FilledButton, '通过退款审核'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('通过退款审核'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('exhausted task offers manual attention and no more retry action',
      (tester) async {
    final f = FinancePageFixture()
      ..taskStatus = 'ATTENTION'
      ..attempts = 50;
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page(refunds: false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看账单'));
    await tester.pumpAndSettle();
    expect(find.text('重新核对原账单'), findsNothing);
    expect(find.textContaining('已达到核对尝试上限'), findsOneWidget);
    expect(f.sent.where((r) => r.method != 'GET'), isEmpty);
  });
  testWidgets(
      'finance fits actual console outer scroll host without an unbounded viewport',
      (tester) async {
    final f = FinancePageFixture();
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page(outerScroll: true));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('查看并审核'), findsOneWidget);
  });
  testWidgets('denying a refund explicitly says no refund is initiated',
      (tester) async {
    final f = FinancePageFixture();
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看并审核'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(OutlinedButton, '不通过退款审核'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不通过退款审核'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '此申请暂不通过退款审核');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认不通过'));
    await tester.pumpAndSettle();
    expect(find.text('审核已记录：未通过。不会由此发起退款。'), findsOneWidget);
    expect(find.textContaining('退款由服务自动办理'), findsNothing);
  });
  testWidgets(
      'opening platform finance is read only and refund-only role avoids bill APIs',
      (tester) async {
    final f = FinancePageFixture();
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page(finance: false));
    await tester.pumpAndSettle();
    expect(find.text('退款售后'), findsWidgets);
    expect(find.text('日账单'), findsNothing);
    expect(f.sent.where((r) => r.method != 'GET'), isEmpty);
    expect(f.sent.where((r) => r.url.path.contains('reconciliation')), isEmpty);
  });
  testWidgets('self refund cannot expose a review action', (tester) async {
    final f = FinancePageFixture()..self = true;
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    expect(find.text('查看并审核'), findsNothing);
    expect(find.textContaining('不可审核'), findsOneWidget);
  });
  testWidgets(
      'refund preview shows preserved renewals before explicit decision',
      (tester) async {
    final f = FinancePageFixture();
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    await openReview(tester);
    expect(find.textContaining('保留其他续费'), findsWidgets);
    await tester.enterText(find.byType(TextField).last, '核对后同意全额原路退款');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认通过'));
    await tester.pumpAndSettle();
    final post = f.sent.singleWhere((r) => r.method == 'POST');
    expect(jsonDecode(post.body), {
      'decision': 'APPROVE',
      'previewHash': previewHash,
      'note': '核对后同意全额原路退款'
    });
    expect(find.textContaining('审核已记录'), findsOneWidget);
  });
  testWidgets(
      'unknown review reopens exact original operation instead of silently posting',
      (tester) async {
    final f = FinancePageFixture()..failReview = true;
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    await openReview(tester);
    await tester.enterText(find.byType(TextField).last, '核对后同意全额原路退款');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认通过'));
    await tester.pumpAndSettle();
    final original = f.sent.singleWhere((r) => r.method == 'POST');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    expect(f.sent.where((r) => r.method == 'POST').length, 1);
    await tester.ensureVisible(find.widgetWithText(OutlinedButton, '继续核对原操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续核对原操作'));
    await tester.pumpAndSettle();
    f.failReview = false;
    await tester.tap(find.text('确认重试原操作'));
    await tester.pumpAndSettle();
    final last = f.sent.lastWhere((r) => r.method == 'POST');
    expect(last.body, original.body);
    expect(last.url, original.url);
    expect(
        last.headers['Idempotency-Key'], original.headers['Idempotency-Key']);
  });
  testWidgets('partial bill remains an incomplete result after opening details',
      (tester) async {
    final f = FinancePageFixture();
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page(refunds: false));
    await tester.pumpAndSettle();
    expect(find.text('部分核对，仍需检查'), findsOneWidget);
    await tester.tap(find.text('查看账单'));
    await tester.pumpAndSettle();
    expect(find.textContaining('仍需核对'), findsWidgets);
    expect(find.text('已对平'), findsNothing);
  });
  testWidgets(
      'recent MFA keeps pending operation and requires explicit confirmation after return',
      (tester) async {
    final f = FinancePageFixture()..reviewError = 'REAUTH_REQUIRED';
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    await openReview(tester);
    await tester.enterText(find.byType(TextField).last, '核对后同意全额原路退款');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认通过'));
    await tester.pumpAndSettle();
    expect(f.storage.values, isNotEmpty);
    await tester.ensureVisible(find.widgetWithText(OutlinedButton, '完成安全验证'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成安全验证'));
    await tester.pumpAndSettle();
    expect(f.reauthentications, 1);
    expect(f.sent.where((r) => r.method == 'POST').length, 1);
  });
  testWidgets(
      'scope revocation removes private details and cannot revive on return',
      (tester) async {
    final f = FinancePageFixture();
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    f.current = false;
    f.changes.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('暂时不需要'), findsNothing);
    f.current = true;
    f.changes.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.textContaining('权限或身份已变化'), findsOneWidget);
  });
  testWidgets(
      'background cancels an open review confirmation without submitting',
      (tester) async {
    final f = FinancePageFixture();
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page());
    await tester.pumpAndSettle();
    await openReview(tester);
    await tester.enterText(find.byType(TextField).last, '核对后同意全额原路退款');
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('确认通过'), findsNothing);
    expect(f.sent.where((r) => r.method == 'POST'), isEmpty);
  });
  testWidgets(
      'finance supports narrow screens and doubled fonts without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final f = FinancePageFixture();
    addTearDown(f.dispose);
    await tester.pumpWidget(f.page(refunds: false));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('查看账单'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
  });
  testWidgets('capture fictional operator finance states', (tester) async {
    if (!const bool.fromEnvironment('CAPTURE_FAMILY_FINANCE')) return;
    await tester.runAsync(() async {
      final bytes = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
      await (FontLoader('Microsoft YaHei')
            ..addFont(Future.value(ByteData.sublistView(bytes))))
          .load();
      final icon = await File(
              'D:/softwares/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
          .readAsBytes();
      await (FontLoader('MaterialIcons')
            ..addFont(Future.value(ByteData.sublistView(icon))))
          .load();
    });
    tester.view.physicalSize = const Size(1180, 980);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final f = FinancePageFixture();
    addTearDown(f.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(f.page(boundary: key));
    await tester.pumpAndSettle();
    for (final tab in ['refund', 'bill']) {
      if (tab == 'bill') {
        await tester.tap(find.text('日账单'));
        await tester.pumpAndSettle();
      }
      await tester.runAsync(() async {
        final frame = await (key.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
        frame.dispose();
        await File(
                '../../.local/family-p0-commerce-20261016/operator-$tab-fictional.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      });
    }
  });
}
