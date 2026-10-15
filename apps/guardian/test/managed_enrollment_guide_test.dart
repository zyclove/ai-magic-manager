import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/managed_android.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/managed_enrollment_form.dart';
import 'package:guardian/ui/managed_enrollment_guide.dart';

const tenant = '11111111-1111-4111-8111-111111111111';
ManagedEnterpriseBinding binding(String state) =>
    ManagedEnterpriseBinding.parse({
      'tenantId': tenant,
      'provider': 'LOCAL_EMM',
      'enterpriseId': 'org_1',
      'contractReference': 'CN-2026-001',
      'state': state,
      'version': 1,
      'createdAt': 1000,
      'updatedAt': 1000,
    }, tenant);
ManagedProvisioningReadiness ready(String reason) =>
    ManagedProvisioningReadiness.parse({
      'tenantId': tenant,
      'provider': 'LOCAL_EMM',
      'targetCountryCode': 'CN',
      'reasonCode': reason,
      'canIssueEnrollment': reason == 'PROVISIONING_CONFIGURED',
    }, tenant);
ManagedCapacitySnapshot seats(int available) => ManagedCapacitySnapshot.parse({
      'tenantId': tenant,
      'paidCapacity': available,
      'verifiedDevices': 0,
      'reservedIntents': 0,
      'expiredUnresolvedIntents': 0,
      'cancelledUnreconciledIntents': 0,
      'availableForNew': available,
      'overCapacity': false,
      'evaluatedAt': 1000,
    }, tenant);
ManagedEnrollmentIntent intent(String state) => ManagedEnrollmentIntent.parse({
      'id': '22222222-2222-4222-8222-222222222222',
      'tenantId': tenant,
      'subjectId': '33333333-3333-4333-8333-333333333333',
      'provider': 'LOCAL_EMM',
      'enterpriseId': 'org_1',
      'state': state,
      'version': 1,
      'createdAt': 1000,
      'expiresAt': 2000,
      'issuedAt': 1000,
      if (state == 'VERIFIED') ...{
        'providerDeviceId': 'device_1',
        'managementMode': 'DEVICE_OWNER',
        'verifiedAt': 1500
      },
    }, tenant);

void main() {
  Future<void> show(WidgetTester tester,
      {String? state,
      String reason = 'PROVISIONING_CONFIGURED',
      bool writable = true,
      bool enabled = true,
      int available = 10,
      VoidCallback? issue,
      VoidCallback? propose,
      double width = 1000,
      double scale = 1}) async {
    tester.view.physicalSize = Size(width, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: SingleChildScrollView(
                    child: ManagedEnrollmentGuide(
                  binding: state == null ? null : binding(state),
                  readiness: ready(reason),
                  capacity: seats(available),
                  writable: writable,
                  enabled: enabled,
                  onIssue: issue ?? () {},
                  onPropose: propose ?? () {},
                ))))));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'unbound institution has one actionable first step even before provider is configured',
      (tester) async {
    var calls = 0;
    await show(tester,
        reason: 'PROVIDER_NOT_CONFIGURED', propose: () => calls++);
    expect(find.text('先申请机构资格审核'), findsOneWidget);
    expect(find.textContaining('提供方尚未开通'), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is FilledButton),
        findsOneWidget);
    await tester.tap(find.text('申请机构审核'));
    expect(calls, 1);
    expect(find.text('接入一台设备'), findsNothing);
  });
  for (final state in ['PENDING', 'REVOKED']) {
    testWidgets('$state never offers issuance even with configured readiness',
        (tester) async {
      await show(tester, state: state);
      expect(find.byWidgetPredicate((widget) => widget is FilledButton),
          findsNothing);
      expect(find.text(state == 'PENDING' ? '等待平台审核' : '请联系平台复核机构资格'),
          findsOneWidget);
    });
  }
  for (final reason in [
    'REGION_PROVIDER_UNAVAILABLE',
    'PROVIDER_CHANGED',
    'CONTRACT_REQUIRED',
    'BOOTSTRAP_POLICY_REQUIRED'
  ]) {
    testWidgets('$reason explains blocker without issuing', (tester) async {
      await show(tester, state: 'ACTIVE', reason: reason);
      expect(find.text(readinessExplanation(reason)), findsOneWidget);
      expect(find.byWidgetPredicate((widget) => widget is FilledButton),
          findsNothing);
    });
  }
  testWidgets('ready administrator gets one primary action', (tester) async {
    var calls = 0;
    await show(tester, state: 'ACTIVE', issue: () => calls++);
    expect(find.byWidgetPredicate((widget) => widget is FilledButton),
        findsOneWidget);
    await tester.tap(find.text('接入一台设备'));
    expect(calls, 1);
    expect(find.textContaining('管控效果需单独查看'), findsOneWidget);
  });
  testWidgets('capacity exhaustion explains seat recovery', (tester) async {
    await show(tester, state: 'ACTIVE', available: 0);
    expect(find.text('先处理设备名额'), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is FilledButton),
        findsNothing);
  });
  testWidgets('auditor is read only', (tester) async {
    await show(tester, state: 'ACTIVE', writable: false);
    expect(find.textContaining('当前为只读查看'), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is FilledButton),
        findsNothing);
  });
  testWidgets('stale or loading view cannot dispatch action', (tester) async {
    await show(tester, state: 'ACTIVE', enabled: false);
    expect(
        tester
            .widget<FilledButton>(
                find.byWidgetPredicate((widget) => widget is FilledButton))
            .onPressed,
        isNull);
  });
  testWidgets('320 pixel view supports enlarged text', (tester) async {
    await show(tester, state: 'ACTIVE', width: 320, scale: 2);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('接入一台设备'));
    expect(tester.takeException(), isNull);
  });
  test('expiry never rewrites provider state or late verification eligibility',
      () {
    final row = intent('ISSUED');
    expect(
        enrollmentInstruction(row, DateTime.fromMillisecondsSinceEpoch(1999))
            .title,
        '等待设备注册');
    expect(
        enrollmentInstruction(row, DateTime.fromMillisecondsSinceEpoch(2000))
            .title,
        '资料已到期，待核对');
    expect(row.state, 'ISSUED');
    expect(row.canVerify, isTrue);
    expect(enrollmentInstruction(intent('VERIFIED'), DateTime(2030)).title,
        '身份已核对');
    expect(
        enrollmentInstruction(intent('CANCEL_PENDING'), DateTime(2030)).title,
        '取消处理中');
    expect(enrollmentInstruction(intent('CANCELLED'), DateTime(2030)).title,
        '令牌已取消');
    expect(
        enrollmentInstruction(intent('FAILED'), DateTime(2030)).title, '创建未完成');
    expect(enrollmentInstruction(intent('PREPARING'), DateTime(2030)).title,
        '正在准备');
  });

  Future<void> form(WidgetTester tester, bool forBinding,
      void Function(({String id, String contract})?) result,
      {double width = 800}) async {
    tester.view.physicalSize = Size(width, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () async => result(
                        await showDialog<({String id, String contract})>(
                            context: context,
                            builder: (_) =>
                                ManagedEnrollmentForm(binding: forBinding))),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('invalid identifier stays in dialog and retains contract',
      (tester) async {
    ({String id, String contract})? result;
    await form(tester, true, (value) => result = value);
    await tester.enterText(
        find.byType(TextFormField).first, 'https://example.invalid/device');
    await tester.enterText(find.byType(TextFormField).last, 'CN-001');
    await tester.tap(find.text('提交审核'));
    await tester.pumpAndSettle();
    expect(find.byType(ManagedEnrollmentForm), findsOneWidget);
    expect(find.text('CN-001'), findsOneWidget);
    expect(result, isNull);
    await tester.enterText(find.byType(TextFormField).first, '  org_1  ');
    await tester.tap(find.text('提交审核'));
    await tester.pumpAndSettle();
    expect(result, (id: 'org_1', contract: 'CN-001'));
  });
  testWidgets('blank contract cannot submit', (tester) async {
    await form(tester, true, (_) {});
    await tester.enterText(find.byType(TextFormField).first, 'org_1');
    await tester.tap(find.text('提交审核'));
    await tester.pumpAndSettle();
    expect(find.text('请填写已生效的合同编号'), findsOneWidget);
  });
  testWidgets('device form works at 320 pixels and submits trimmed ID',
      (tester) async {
    ({String id, String contract})? result;
    await form(tester, false, (value) => result = value, width: 320);
    await tester.enterText(find.byType(TextFormField), ' device_1 ');
    await tester.tap(find.widgetWithText(FilledButton, '核对身份'));
    await tester.pumpAndSettle();
    expect(result?.id, 'device_1');
    expect(tester.takeException(), isNull);
  });
}
