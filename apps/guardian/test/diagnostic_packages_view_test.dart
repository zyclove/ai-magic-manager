import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../lib/core/api.dart';
import '../lib/core/support.dart';
import '../lib/core/diagnostic_package.dart';
import '../lib/core/diagnostic_package_repository.dart';
import '../lib/ui/diagnostic_packages_view.dart';
import 'fixtures/diagnostic_package.dart';

class PackageFake extends DiagnosticPackageRepository {
  final at = DateTime.now().millisecondsSinceEpoch;
  int creates = 0, lists = 0, gets = 0, cancels = 0, downloads = 0;
  bool failOnce = false;
  ApiFailure createFailure = const ApiFailure(0, 'NETWORK_ERROR');
  bool failCancelOnce = false;
  ApiFailure cancelFailure = const ApiFailure(0, 'NETWORK_ERROR');
  String state = 'QUEUED';
  final drafts = <DiagnosticPackageDraft>[];
  Completer<DiagnosticPackageDownload>? pendingDownload;
  Completer<DiagnosticPackage>? pendingCreation;
  DiagnosticPackage? refreshed;
  final cancelRequests = <({DiagnosticPackage job, String key})>[];
  PackageFake()
      : super(
            api: Api(
                () async => MockClient((_) async => http.Response('', 500))),
            actor: owner,
            tenant: tenant,
            received: false,
            current: () => true);
  DiagnosticPackage get value => DiagnosticPackage.parse(
      packageFixture(now: at, state: state)
        ..['version'] = state == 'CANCELLED'
            ? 3
            : state == 'READY'
                ? 2
                : 0,
      actor: owner,
      mode: 'ADMIN',
      tenant: tenant);
  @override
  Future<DiagnosticPackage> create(DiagnosticPackageDraft draft) async {
    creates++;
    drafts.add(draft);
    if (failOnce && creates == 1) throw createFailure;
    return pendingCreation?.future ?? value;
  }

  @override
  Future<SupportPage<DiagnosticPackage>> list({String? cursor}) async {
    lists++;
    return SupportPage([value], null);
  }

  @override
  Future<DiagnosticPackage> get(String id) async {
    gets++;
    return refreshed ?? value;
  }

  @override
  Future<DiagnosticPackage> cancel(DiagnosticPackage job, String key) async {
    cancels++;
    cancelRequests.add((job: job, key: key));
    if (failCancelOnce && cancels == 1) throw cancelFailure;
    state = 'CANCELLED';
    return value;
  }

  @override
  Future<DiagnosticPackageDownload> download(DiagnosticPackage job) async {
    downloads++;
    return pendingDownload?.future ??
        DiagnosticPackageDownload(
            value, documentBytes(packageDocument(now: at)));
  }
}

Future<void> open(WidgetTester tester, PackageFake repo,
    {bool create = true,
    bool Function()? current,
    Listenable? changes,
    Future<void> Function(Uint8List, String, void Function())? save}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: DiagnosticPackagesView(
              repository: repo,
              current: current ?? () => true,
              accessChanges: changes,
              target: create
                  ? DiagnosticPackageDraft.admin(
                      deviceId: device,
                      registrationId: registration,
                      deviceVersion: 0)
                  : null,
              targetLabel: '客厅平板',
              onClose: () {},
              onReauth: () {},
              save: save ??
                  (bytes, name, ensure) async {
                    ensure();
                  }))));
}

Future<void> submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('package-confirm')));
  await tester.pump();
  await tester.tap(find.text('生成诊断包'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'cancel version conflict allows refresh and a newly confirmed request',
      (tester) async {
    final repo = PackageFake()
      ..failCancelOnce = true
      ..cancelFailure = const ApiFailure(412, 'RESOURCE_VERSION_CONFLICT');
    await open(tester, repo, create: false);
    await tester.tap(find.text('刷新任务列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消并清除'));
    await tester.pump();
    await tester.tap(find.text('确认取消并清除'));
    await tester.pumpAndSettle();
    expect(find.text('按原请求重试取消'), findsNothing);
    repo.state = 'READY';
    await tester.tap(find.text('刷新任务列表'));
    await tester.pumpAndSettle();
    expect(repo.lists, 2);
    await tester.tap(find.text('取消并清除'));
    await tester.pump();
    await tester.tap(find.text('确认取消并清除'));
    await tester.pumpAndSettle();
    expect(repo.cancelRequests[0].job.version, 0);
    expect(repo.cancelRequests[1].job.version, 2);
    expect(repo.cancelRequests[0].key, isNot(repo.cancelRequests[1].key));
  });
  testWidgets(
      'capacity rejection restores access to existing task cancellation',
      (tester) async {
    final repo = PackageFake()
      ..failOnce = true
      ..createFailure =
          const ApiFailure(409, 'DIAGNOSTIC_PACKAGE_CAPACITY_REACHED');
    await open(tester, repo);
    await submit(tester);
    expect(find.text('按原请求重试生成'), findsNothing);
    repo.state = 'READY';
    await tester.tap(find.text('刷新任务列表'));
    await tester.pumpAndSettle();
    expect(repo.lists, 1);
    await tester.ensureVisible(find.text('取消并清除'));
    await tester.tap(find.text('取消并清除'));
    await tester.pump();
    await tester.ensureVisible(find.text('确认取消并清除'));
    await tester.tap(find.text('确认取消并清除'));
    await tester.pumpAndSettle();
    expect(repo.cancels, 1);
    expect(find.text('已取消并清除'), findsOneWidget);
  });
  testWidgets('task details expose an independent accessible action',
      (tester) async {
    final repo = PackageFake()..state = 'READY';
    await open(tester, repo, create: false);
    await tester.tap(find.text('刷新任务列表'));
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.text('查看任务与设备标识')).label, '查看任务与设备标识');
  });
  testWidgets('uncertain cancellation retries the same version and key',
      (tester) async {
    final repo = PackageFake()
      ..state = 'READY'
      ..failCancelOnce = true;
    await open(tester, repo, create: false);
    await tester.tap(find.text('刷新任务列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消并清除'));
    await tester.pump();
    await tester.tap(find.text('确认取消并清除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按原请求重试取消'));
    await tester.pumpAndSettle();
    expect(repo.cancelRequests.length, 2);
    expect(repo.cancelRequests[0].key, repo.cancelRequests[1].key);
    expect(identical(repo.cancelRequests[0].job, repo.cancelRequests[1].job),
        isTrue);
    expect(find.text('已取消并清除'), findsOneWidget);
  });
  testWidgets('late creation is discarded after leaving the foreground',
      (tester) async {
    final repo = PackageFake()
      ..pendingCreation = Completer<DiagnosticPackage>();
    await open(tester, repo);
    await tester.tap(find.byKey(const ValueKey('package-confirm')));
    await tester.pump();
    await tester.tap(find.text('生成诊断包'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    repo.pendingCreation!.complete(repo.value);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('等待生成'), findsNothing);
    expect(find.text('按原请求重试生成'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(repo.gets, 0);
    await tester.tap(find.text('刷新任务列表'));
    await tester.pumpAndSettle();
    expect(find.text('等待生成'), findsOneWidget);
  });
  testWidgets(
      'changed device response stops tracking without replacing the task',
      (tester) async {
    final repo = PackageFake();
    await open(tester, repo);
    await submit(tester);
    repo.refreshed = DiagnosticPackage.parse(
        packageFixture(now: repo.at, state: 'READY')
          ..['deviceId'] = registration,
        actor: owner,
        mode: 'ADMIN',
        tenant: tenant);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('等待生成'), findsOneWidget);
    expect(find.text('可以下载'), findsNothing);
    expect(find.text('诊断包与当前账号或范围不一致，已阻止保存。请刷新后重试。'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(repo.gets, 1);
  });
  testWidgets(
      'creation is explicit confirmed and does not silently load history',
      (tester) async {
    final repo = PackageFake();
    await open(tester, repo);
    expect(repo.creates, 0);
    expect(repo.lists, 0);
    expect(
        tester
            .widget<FilledButton>(find
                .ancestor(
                    of: find.text('生成诊断包'),
                    matching: find
                        .byWidgetPredicate((widget) => widget is FilledButton))
                .first)
            .onPressed,
        isNull);
    await submit(tester);
    expect(repo.creates, 1);
    expect(find.text('等待生成'), findsOneWidget);
  });
  testWidgets(
      'uncertain creation keeps its exact draft and visible retry action',
      (tester) async {
    final repo = PackageFake()..failOnce = true;
    await open(tester, repo);
    await submit(tester);
    expect(find.text('按原请求重试生成'), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const ValueKey('package-confirm')))
            .onChanged,
        isNull);
    await tester.tap(find.text('按原请求重试生成'));
    await tester.pumpAndSettle();
    expect(repo.drafts.length, 2);
    expect(identical(repo.drafts[0], repo.drafts[1]), isTrue);
  });
  testWidgets('visible followed task refreshes and stops when ready',
      (tester) async {
    final repo = PackageFake();
    await open(tester, repo);
    await submit(tester);
    repo.state = 'READY';
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(repo.gets, 1);
    expect(find.text('可以下载'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(repo.gets, 1);
  });
  testWidgets('cancel needs confirmation before clearing an existing artifact',
      (tester) async {
    final repo = PackageFake()..state = 'READY';
    await open(tester, repo, create: false);
    await tester.tap(find.text('刷新任务列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消并清除'));
    await tester.pump();
    expect(repo.cancels, 0);
    await tester.tap(find.text('确认取消并清除'));
    await tester.pumpAndSettle();
    expect(repo.cancels, 1);
    expect(find.text('已取消并清除'), findsOneWidget);
  });
  testWidgets('background clears task state and prevents a late file save',
      (tester) async {
    final repo = PackageFake()
      ..state = 'READY'
      ..pendingDownload = Completer<DiagnosticPackageDownload>();
    int saves = 0;
    await open(tester, repo, create: false, save: (bytes, name, ensure) async {
      ensure();
      saves++;
    });
    await tester.tap(find.text('刷新任务列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载 JSON'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    repo.pendingDownload!.complete(DiagnosticPackageDownload(
        repo.value, documentBytes(packageDocument(now: repo.at))));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(find.text('可以下载'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(repo.gets, 0);
  });
  testWidgets('permission change clears history and blocks every operation',
      (tester) async {
    final repo = PackageFake(), changes = ValueNotifier<int>(0);
    bool current = true;
    await open(tester, repo,
        create: false, current: () => current, changes: changes);
    await tester.tap(find.text('刷新任务列表'));
    await tester.pumpAndSettle();
    current = false;
    changes.value++;
    await tester.pumpAndSettle();
    expect(find.text('可以下载'), findsNothing);
    expect(find.text('账号或权限已变化，请关闭后重新打开。'), findsOneWidget);
    changes.dispose();
  });
  testWidgets('mobile task view is scrollable and keeps error recovery visible',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = PackageFake()..failOnce = true;
    await open(tester, repo);
    await tester.ensureVisible(find.byKey(const ValueKey('package-confirm')));
    await tester.tap(find.byKey(const ValueKey('package-confirm')));
    await tester.pump();
    await tester.ensureVisible(find.text('生成诊断包'));
    await tester.tap(find.text('生成诊断包'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
        find.ancestor(
            of: find.text('按原请求重试生成'), matching: find.byType(Scrollable)),
        findsNothing);
  });
}
