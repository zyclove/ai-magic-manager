import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import '../lib/core/api.dart';
import '../lib/core/support.dart';
import '../lib/core/support_repository.dart';
import '../lib/ui/support_grant_view.dart';
import '../lib/ui/support_center_view.dart';
import 'fixtures/support.dart';

class FakeSupport extends SupportRepository {
  final pairCreatedAt = DateTime.now().millisecondsSinceEpoch;
  int pairCalls = 0, resolveCalls = 0, grantCalls = 0;
  int revokes = 0;
  final drafts = <SupportGrantDraft>[];
  bool failOnce = false;
  Completer<CreatedSupportPairing>? pendingPair;
  bool replayWithoutCode = false;
  String pairState = 'PENDING';
  FakeSupport()
      : super(
            api: Api(
                () async => MockClient((_) async => http.Response('', 500))),
            actor: owner,
            tenant: tenant,
            current: () => true);
  @override
  Future<SupportPairing> resolve(String value) async {
    resolveCalls++;
    return SupportPairing.parse(pairingFixture(now: pairCreatedAt));
  }

  @override
  Future<SupportGrant> createGrant(SupportGrantDraft draft) async {
    grantCalls++;
    drafts.add(draft);
    if (failOnce && grantCalls == 1) throw const ApiFailure(0, 'NETWORK_ERROR');
    return SupportGrant.parse(grantFixture(types: draft.diagnosticTypes));
  }

  @override
  Future<CreatedSupportPairing> createPairing(String key) async {
    pairCalls++;
    return pendingPair?.future ??
        CreatedSupportPairing.parse({
          'request': pairingFixture(now: pairCreatedAt)..['state'] = pairState,
          'code': replayWithoutCode ? null : code
        }, recipient);
  }

  @override
  Future<SupportPage<SupportGrant>> grants(
          {required bool received, String? cursor}) async =>
      SupportPage([SupportGrant.parse(grantFixture())], null);
  @override
  Future<SupportPage<SupportPairing>> pairings({String? cursor}) async =>
      SupportPage([
        SupportPairing.parse(pairingFixture(now: pairCreatedAt)
          ..['state'] = pairState
          ..['version'] = pairState == 'PENDING' ? 0 : 1)
      ], null);
  @override
  Future<SupportGrant> revoke(SupportGrant grant, String key) async {
    revokes++;
    return SupportGrant.parse(grantFixture()
      ..['state'] = 'REVOKED'
      ..['version'] = 1);
  }

  @override
  Future<SupportPairing> cancelPairing(SupportPairing pair, String key) async =>
      SupportPairing.parse(pairingFixture()
        ..['state'] = 'CANCELLED'
        ..['version'] = 1);
}

Future<void> openGrant(WidgetTester tester, FakeSupport repo,
    {bool Function()? current,
    Listenable? changes,
    String registrationId = registration}) async {
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SupportGrantView(
              repository: repo,
              deviceId: device,
              registrationId: registrationId,
              deviceVersion: 0,
              deviceName: '客厅平板',
              current: current ?? () => true,
              accessChanges: changes,
              onClose: () {},
              onReauth: () {}))));
}

Future<void> confirm(WidgetTester tester) async {
  await tester.enterText(
      find.byKey(const ValueKey('support-pairing-code')), code);
  await tester.tap(find.text('核对接收人'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('我已核对接收人身份与授权范围'));
  await tester.tap(find.text('我已核对接收人身份与授权范围'));
  await tester.pump();
}

void main() {
  testWidgets(
      'refreshing a consumed pairing clears its displayed one-time code',
      (tester) async {
    final repo = FakeSupport();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: SupportCenterView(
                    repository: repo,
                    current: () => true,
                    canAdmin: false,
                    onReauth: () {},
                    onOpenDevices: () {})))));
    await tester.tap(find.text('生成配对码'));
    await tester.pumpAndSettle();
    expect(find.text(code), findsOneWidget);
    repo.pairState = 'CONSUMED';
    await tester.tap(find.text('刷新配对请求'));
    await tester.pumpAndSettle();
    expect(find.text(code), findsNothing);
    expect(find.text('查看收到的授权'), findsOneWidget);
  });
  testWidgets(
      'consumed pairing replay routes to received grants without cancellation',
      (tester) async {
    final repo = FakeSupport()
      ..replayWithoutCode = true
      ..pairState = 'CONSUMED';
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: SupportCenterView(
                    repository: repo,
                    current: () => true,
                    canAdmin: false,
                    onReauth: () {},
                    onOpenDevices: () {})))));
    await tester.tap(find.text('生成配对码'));
    await tester.pumpAndSettle();
    expect(find.text('已用于授权'), findsOneWidget);
    expect(find.text('取消当前配对'), findsNothing);
    expect(find.text('查看收到的授权'), findsOneWidget);
  });
  testWidgets(
      'rebuilding with another registration clears old confirmed identity',
      (tester) async {
    final repo = FakeSupport();
    await openGrant(tester, repo);
    await confirm(tester);
    await openGrant(tester, repo, registrationId: device);
    await tester.pump();
    expect(find.text('技术支持接收人'), findsNothing);
    expect(find.textContaining('账号或工作空间已变化'), findsOneWidget);
    expect(repo.grantCalls, 0);
  });
  testWidgets(
      'displayed pairing code is cleared on background and not recreated',
      (tester) async {
    final repo = FakeSupport();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: SupportCenterView(
                    repository: repo,
                    current: () => true,
                    canAdmin: false,
                    onReauth: () {},
                    onOpenDevices: () {})))));
    await tester.tap(find.text('生成配对码'));
    await tester.pumpAndSettle();
    expect(find.text(code), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text(code), findsNothing);
    expect(repo.pairCalls, 1);
  });
  testWidgets('lost initial pairing code offers cancellation before recreation',
      (tester) async {
    final repo = FakeSupport()..replayWithoutCode = true;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: SupportCenterView(
                    repository: repo,
                    current: () => true,
                    canAdmin: false,
                    onReauth: () {},
                    onOpenDevices: () {})))));
    await tester.tap(find.text('生成配对码'));
    await tester.pumpAndSettle();
    expect(find.text('请求已创建，但原配对码不会再次显示。请取消此请求后重新生成。'), findsOneWidget);
    await tester.ensureVisible(find.text('取消当前配对'));
    await tester.tap(find.text('取消当前配对'));
    await tester.pumpAndSettle();
    expect(find.text('取消当前配对'), findsNothing);
    await tester.ensureVisible(find.text('生成配对码'));
    await tester.tap(find.text('生成配对码'));
    await tester.pumpAndSettle();
    expect(repo.pairCalls, 2);
  });
  testWidgets(
      'customer revoke needs explicit confirmation and updates current status',
      (tester) async {
    final repo = FakeSupport();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: SupportCenterView(
                    repository: repo,
                    current: () => true,
                    canAdmin: true,
                    onReauth: () {},
                    onOpenDevices: () {})))));
    await tester.tap(find.text('本空间授权'));
    await tester.pump();
    await tester.tap(find.text('刷新授权列表'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('撤销授权'));
    await tester.tap(find.text('撤销授权'));
    await tester.pump();
    expect(repo.revokes, 0);
    await tester.ensureVisible(find.text('确认撤销'));
    await tester.tap(find.text('确认撤销'));
    await tester.pumpAndSettle();
    expect(repo.revokes, 1);
    expect(find.text('已撤销'), findsOneWidget);
  });
  testWidgets(
      'requires identity resolution and explicit confirmation before granting',
      (tester) async {
    final repo = FakeSupport();
    await openGrant(tester, repo);
    expect(repo.resolveCalls, 0);
    expect(repo.grantCalls, 0);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认授权'))
            .onPressed,
        isNull);
    await confirm(tester);
    expect(find.text('技术支持接收人'), findsOneWidget);
    await tester.tap(find.text('确认授权'));
    await tester.pumpAndSettle();
    expect(repo.grantCalls, 1);
    expect(repo.drafts.single.durationMinutes, 60);
    expect(repo.drafts.single.diagnosticTypes, ['DEVICE_STATUS']);
    expect(find.text('授权记录已确认'), findsOneWidget);
    expect(find.text(code), findsNothing);
  });
  testWidgets('ambiguous grant submission freezes input and reuses same draft',
      (tester) async {
    final repo = FakeSupport()..failOnce = true;
    await openGrant(tester, repo);
    await confirm(tester);
    await tester.tap(find.text('确认授权'));
    await tester.pumpAndSettle();
    expect(tester.getBottomRight(find.textContaining('提交结果尚未确认')).dy,
        lessThanOrEqualTo(tester.getBottomRight(find.byType(Scaffold)).dy));
    expect(
        find.descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.textContaining('提交结果尚未确认')),
        findsNothing);
    expect(find.byType(EditableText), findsNothing);
    await tester.tap(find.text('按原内容重试'));
    await tester.pumpAndSettle();
    expect(repo.drafts, hasLength(2));
    expect(identical(repo.drafts.first, repo.drafts.last), isTrue);
  });
  testWidgets(
      'background clears pairing code and confirmation without automatic reload',
      (tester) async {
    final repo = FakeSupport();
    await openGrant(tester, repo);
    await confirm(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('support-pairing-code')))
            .controller!
            .text,
        isEmpty);
    expect(find.text('技术支持接收人'), findsNothing);
    expect(repo.grantCalls, 0);
  });
  testWidgets(
      'pairing is explicit and late code is discarded after scope change',
      (tester) async {
    final repo = FakeSupport()
      ..pendingPair = Completer<CreatedSupportPairing>();
    var current = true;
    final changes = ChangeNotifier();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: SupportCenterView(
                    repository: repo,
                    current: () => current,
                    accessChanges: changes,
                    canAdmin: false,
                    onReauth: () {},
                    onOpenDevices: () {})))));
    expect(repo.pairCalls, 0);
    await tester.tap(find.text('生成配对码'));
    await tester.pump();
    current = false;
    changes.notifyListeners();
    await tester.pump();
    repo.pendingPair!.complete(CreatedSupportPairing.parse(
        {'request': pairingFixture(), 'code': code}, recipient));
    await tester.pumpAndSettle();
    expect(find.text(code), findsNothing);
    expect(find.textContaining('账号或工作空间已变化'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    changes.dispose();
  });
  testWidgets('narrow grant form remains scrollable and has no layout overflow',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await openGrant(tester, FakeSupport());
    await confirm(tester);
    await tester.tap(find.text('确认授权'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
