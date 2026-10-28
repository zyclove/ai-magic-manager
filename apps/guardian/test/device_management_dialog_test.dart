import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/device_management.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/device_management_dialog.dart';
import 'package:http/testing.dart';

const deviceId = '11111111-1111-4111-8111-111111111111';
const subjectId = '22222222-2222-4222-8222-222222222222';
const registrationId = '33333333-3333-4333-8333-333333333333';
const tenantId = '44444444-4444-4444-8444-444444444444';
const deviceName = '学习平板';

DeviceManagementRecord deviceRecord({String state = 'ACTIVE'}) =>
    DeviceManagementRecord(
      id: deviceId,
      subjectId: subjectId,
      registrationId: registrationId,
      displayName: deviceName,
      platform: 'ANDROID',
      osVersion: '14',
      state: state,
      managementMode: 'BYOD',
      controlLevel: state == 'REVOKED' ? 'NONE' : 'LIMITED',
      observationStatus: state == 'REVOKED' ? 'REVOKED' : 'RECENT',
      keyThumbprint: 'a' * 43,
      version: 3,
      lastHeartbeatAt: null,
    );

DeviceManagementCapabilities deviceCapabilities() =>
    DeviceManagementCapabilities(const [
      DeviceManagementCapability(
        key: 'usage.report',
        status: 'UNVERIFIED',
        grantStatus: 'GRANTED',
        evidenceSource: 'AGENT_REPORT',
        limitationCode: 'EVIDENCE_NOT_CERTIFIED',
        reportedSupported: true,
        effectiveSupported: false,
        checkedAt: 1791972000000,
      ),
    ]);

DeviceManagementInventory deviceInventory({bool empty = false}) =>
    DeviceManagementInventory(
      deviceId: deviceId,
      registrationId: registrationId,
      visibility: 'VISIBLE_PACKAGES',
      observationStatus: 'RECENT',
      evidenceStatus: 'AGENT_REPORTED_UNVERIFIED',
      sequence: 4,
      receivedAt: 1791972000000,
      applications: empty
          ? []
          : [
              DeviceManagementApplication(
                packageName: 'com.example.study',
                displayName: '学习应用',
                profile: 'PRIMARY',
                signingDigests: ['b' * 64],
                versionCode: 3,
                systemApplication: false,
              ),
              DeviceManagementApplication(
                packageName: 'com.example.video',
                displayName: '视频应用',
                profile: 'PRIMARY',
                signingDigests: ['c' * 64],
                versionCode: 5,
                systemApplication: false,
              ),
            ],
    );

/// Only the widget is under test. Every public controller entry is implemented;
/// no parser, repository operation or unimplemented core method is exercised.
class FakeDeviceManagementController extends DeviceManagementController {
  FakeDeviceManagementController({
    bool writable = true,
    bool applicationsAllowed = true,
  }) : super(
          repository: DeviceManagementRepository(
            api: Api(
              () async => MockClient((_) async {
                throw StateError('Widget fixtures must never issue HTTP.');
              }),
              baseUrl: 'http://mock.invalid/api/v1',
            ),
            root: '/tenants/$tenantId',
            deviceId: deviceId,
            current: () => true,
          ),
          canWrite: writable,
          canReadApplications: applicationsAllowed,
        );

  DeviceManagementRecord? value = deviceRecord();
  DeviceManagementCapabilities? capabilityValue = deviceCapabilities();
  DeviceManagementInventory? inventoryValue = deviceInventory();
  DeviceManagementSection selected = DeviceManagementSection.overview;
  Object? failure;
  DateTime? readAt = DateTime.utc(2026, 10, 14, 10, 5);
  DateTime? sectionReadAt = DateTime.utc(2026, 10, 14, 10, 6);
  bool accessValue = true;
  bool scopeValid = true;
  bool busyValue = false;
  bool writeBusyValue = false;
  bool unknownValue = false;
  bool acceptedAwaitingReadValue = false;
  int initializationCalls = 0;
  int refreshCalls = 0;
  int scopeChecks = 0;
  int revokeCalls = 0;
  int confirmedMutations = 0;
  int actionDispatches = 0;
  int disposalCalls = 0;
  final sections = <DeviceManagementSection>[];

  @override
  DeviceManagementRecord? get device => value;
  @override
  DeviceManagementCapabilities? get capabilities => capabilityValue;
  @override
  DeviceManagementInventory? get inventory => inventoryValue;
  @override
  DeviceManagementSection get section => selected;
  @override
  Object? get error => failure;
  @override
  DateTime? get updatedAt => readAt;
  @override
  DateTime? get sectionUpdatedAt => sectionReadAt;
  @override
  bool get busy => busyValue;
  @override
  bool get writeBusy => writeBusyValue;
  @override
  bool get hasAccess => accessValue;
  @override
  bool get revokeResultUnknown => unknownValue;
  @override
  bool get revokeAcceptedAwaitingRead => acceptedAwaitingReadValue;
  @override
  bool get canRevoke =>
      canWrite &&
      hasAccess &&
      !busy &&
      !unknownValue &&
      !acceptedAwaitingReadValue &&
      value?.state == 'ACTIVE';

  void publish() => notifyListeners();

  @override
  Future<void> initialize() async {
    initializationCalls++;
    publish();
  }

  @override
  Future<void> refresh() async {
    refreshCalls++;
    if (!hasAccess) return;
    failure = null;
    publish();
  }

  @override
  Future<void> selectSection(DeviceManagementSection value) async {
    if (!hasAccess || busy) return;
    if (value == DeviceManagementSection.applications && !canReadApplications) {
      return;
    }
    sections.add(value);
    selected = value;
    publish();
  }

  @override
  Future<void> revoke(
      Future<bool> Function(DeviceManagementRecord) confirm) async {
    revokeCalls++;
    if (!canRevoke) return;
    final current = value!;
    busyValue = true;
    publish();
    final accepted = await confirm(current);
    if (!accepted || !hasAccess) {
      busyValue = false;
      publish();
      return;
    }
    writeBusyValue = true;
    publish();
    confirmedMutations++;
    value = deviceRecord(state: 'REVOKED');
    writeBusyValue = false;
    busyValue = false;
    await refresh();
  }

  @override
  Future<void> runAction(
      Future<void> Function(DeviceManagementRecord) action,
      {bool refreshAfter = true}) async {
    actionDispatches++;
    if (!hasAccess || busy || value == null) return;
    busyValue = true;
    publish();
    try {
      await action(value!);
    } finally {
      busyValue = false;
      publish();
    }
    if (hasAccess && refreshAfter) await refresh();
  }

  @override
  void checkScope() {
    scopeChecks++;
    if (!scopeValid) accessValue = false;
    // Intentionally retain the private fixture data. The widget must conceal it
    // from hasAccess independently of a model clearing its fields.
    publish();
  }

  @override
  void dispose() {
    disposalCalls++;
    super.dispose();
  }
}

/// Models a host that releases its controller while a confirmation route lives.
/// Late fake completion stays silent, like the real controller after disposal.
class DisposedConfirmationController extends FakeDeviceManagementController {
  int disposedSubscriptions = 0;

  @override
  void addListener(VoidCallback listener) {
    if (disposalCalls > 0) disposedSubscriptions++;
    super.addListener(listener);
  }

  @override
  void publish() {
    if (disposalCalls == 0) super.publish();
  }
}

class Fixture {
  Fixture({FakeDeviceManagementController? controller})
      : controller = controller ?? FakeDeviceManagementController();
  final FakeDeviceManagementController controller;
  final changes = ValueNotifier<int>(0);
  final opened = <String>[];
  int closeCalls = 0;
  int reauthCalls = 0;

  Future<void> open(BuildContext context, String action,
      DeviceManagementRecord record) async {
    expect(record.id, deviceId);
    expect(record.registrationId, registrationId);
    opened.add(action);
    await showDialog<void>(
      context: context,
      builder: (inner) => AlertDialog(
        title: Text('子流程 · $action'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(inner).pop(),
            child: const Text('返回设备管理'),
          ),
        ],
      ),
    );
  }

  Widget host({double scale = 1}) => MaterialApp(
        theme: consoleTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: DeviceManagementDialog(
              controller: controller,
              accessChanges: changes,
              onClose: () => closeCalls++,
              onReauth: () => reauthCalls++,
              onDiagnostic: (value) => open(context, 'diagnostic', value),
              onExecutions: (value) => open(context, 'executions', value),
              onExport: (value) => open(context, 'export', value),
              onSupport: (value) => open(context, 'support', value),
              onPrivacy: (value) => open(context, 'privacy', value),
              onExit: (value) => open(context, 'exit', value),
            ),
          ),
        ),
      );
}

Future<void> mount(WidgetTester tester, Fixture f, {double scale = 1}) async {
  await tester.pumpWidget(f.host(scale: scale));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    f.changes.dispose();
    if (f.controller.disposalCalls == 0) f.controller.dispose();
  });
}

Future<void> press(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

DeviceManagementRecord namedDevice(String name) {
  final source = deviceRecord();
  return DeviceManagementRecord(
    id: source.id,
    subjectId: source.subjectId,
    registrationId: source.registrationId,
    displayName: name,
    platform: source.platform,
    osVersion: source.osVersion,
    state: source.state,
    managementMode: source.managementMode,
    controlLevel: source.controlLevel,
    observationStatus: source.observationStatus,
    keyThumbprint: source.keyThumbprint,
    version: source.version,
    lastHeartbeatAt: source.lastHeartbeatAt,
  );
}

Widget controlledHost(ValueNotifier<FakeDeviceManagementController?> selection,
        GlobalKey<NavigatorState> navigatorKey,
        {Future<void> Function(DeviceManagementRecord)? onDiagnostic,
        VoidCallback? onClose,
        VoidCallback? onReauth}) =>
    MaterialApp(
      navigatorKey: navigatorKey,
      theme: consoleTheme(),
      home: ValueListenableBuilder<FakeDeviceManagementController?>(
        valueListenable: selection,
        builder: (_, controller, __) => Scaffold(
          body: controller == null
              ? const Text('设备窗口已移除')
              : DeviceManagementDialog(
                  key: const Key('controlled-device-window'),
                  controller: controller,
                  onDiagnostic: onDiagnostic,
                  onClose: onClose ?? () {},
                  onReauth: onReauth,
                ),
        ),
      ),
    );

void main() {
  testWidgets('initializes itself and displays the last actual device read',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    expect(f.controller.initializationCalls, 1);
    expect(find.text(deviceName), findsOneWidget);
    expect(find.textContaining('最近读取'), findsWidgets);
    expect(find.textContaining('2026-10-14'), findsWidgets);
    expect(f.controller.refreshCalls, 0);
  });

  testWidgets('capabilities and overview switch in the same parent window',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    await press(tester, 'device-section-capabilities');
    expect(f.controller.sections, [DeviceManagementSection.capabilities]);
    expect(
        find.byKey(const Key('device-capabilities-content')), findsOneWidget);
    expect(find.byKey(const Key('device-management-dialog')), findsOneWidget);
    expect(f.closeCalls, 0);
    await press(tester, 'device-section-overview');
    expect(f.controller.section, DeviceManagementSection.overview);
    expect(find.text(deviceName), findsOneWidget);
    expect(f.closeCalls, 0);
  });

  testWidgets('application search is local and matches names and packages',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    await press(tester, 'device-section-applications');
    expect(find.text('学习应用'), findsOneWidget);
    expect(find.text('视频应用'), findsOneWidget);
    final selectedCalls = f.controller.sections.length;
    final search = find.byKey(const Key('device-app-search'));
    await tester.enterText(search, '学习');
    await tester.pump();
    expect(find.text('学习应用'), findsOneWidget);
    expect(find.text('视频应用'), findsNothing);
    await tester.enterText(search, 'COM.EXAMPLE.VIDEO');
    await tester.pump();
    expect(find.text('视频应用'), findsOneWidget);
    expect(find.text('学习应用'), findsNothing);
    await tester.enterText(search, '');
    await tester.pump();
    expect(find.text('学习应用'), findsOneWidget);
    expect(find.text('视频应用'), findsOneWidget);
    expect(f.controller.sections.length, selectedCalls);
    expect(f.controller.refreshCalls, 0);
    expect(f.closeCalls, 0);
  });

  testWidgets('empty visible inventory does not imply no apps are installed',
      (tester) async {
    final f = Fixture();
    f.controller.inventoryValue = deviceInventory(empty: true);
    await mount(tester, f);
    await press(tester, 'device-section-applications');
    expect(find.textContaining('不能据此判断设备未安装应用'), findsOneWidget);
    expect(find.text('设备未安装应用'), findsNothing);
  });

  testWidgets('every nested flow runs through the controller and returns here',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    const actions = ['diagnostic', 'executions', 'privacy', 'export', 'support', 'exit'];
    var refreshes = 0;
    for (var index = 0; index < actions.length; index++) {
      final action = actions[index];
      await press(tester, 'device-management-$action');
      expect(find.text('子流程 · $action'), findsOneWidget);
      expect(f.controller.actionDispatches, index + 1);
      await tester.tap(find.text('返回设备管理'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device-management-dialog')), findsOneWidget);
      expect(find.text(deviceName), findsOneWidget);
      expect(f.closeCalls, 0);
      if (action != 'diagnostic') refreshes++;
      expect(f.controller.refreshCalls, refreshes);
    }
    expect(f.opened, actions);
  });

  testWidgets('read-only role hides writes and forbidden application section',
      (tester) async {
    final f = Fixture(
      controller: FakeDeviceManagementController(
        writable: false,
        applicationsAllowed: false,
      ),
    );
    await mount(tester, f);
    expect(find.text(deviceName), findsOneWidget);
    expect(
        find.byKey(const Key('device-management-diagnostic')), findsOneWidget);
    expect(find.byKey(const Key('device-management-privacy')), findsOneWidget);
    for (final action in ['export', 'support', 'exit', 'revoke']) {
      expect(find.byKey(Key('device-management-$action')), findsNothing);
    }
    expect(find.byKey(const Key('device-section-applications')), findsNothing);
  });

  testWidgets('scope signal conceals retained private fields and all actions',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    expect(find.text(deviceName), findsOneWidget);
    f.controller.scopeValid = false;
    f.changes.value++;
    await tester.pumpAndSettle();
    expect(f.controller.scopeChecks, greaterThan(0));
    expect(find.text(deviceName), findsNothing);
    expect(find.textContaining(deviceId), findsNothing);
    expect(find.textContaining('权限已变化'), findsOneWidget);
    for (final action in [
      'diagnostic',
      'privacy',
      'export',
      'support',
      'exit',
      'revoke',
      'refresh',
      'check-result'
    ]) {
      expect(find.byKey(Key('device-management-$action')), findsNothing);
    }
    expect(f.controller.value, isNotNull,
        reason: 'The UI must honor hasAccess rather than trust DTO clearing.');
    await press(tester, 'device-management-close');
    expect(f.closeCalls, 1,
        reason: 'Losing access must still allow closing the device window.');
  });

  testWidgets('read denial hides old inventory and capability content',
      (tester) async {
    final f = Fixture();
    f.controller.selected = DeviceManagementSection.applications;
    f.controller.failure = const ApiFailure(403, 'SCOPE_DENIED');
    f.controller.accessValue = false;
    await mount(tester, f);
    expect(find.textContaining('权限已变化'), findsOneWidget);
    expect(find.text(deviceName), findsNothing);
    expect(find.text('学习应用'), findsNothing);
    expect(find.textContaining('com.example.study'), findsNothing);
    expect(find.byKey(const Key('device-capabilities-content')), findsNothing);
    expect(find.byKey(const Key('device-management-privacy')), findsNothing);
  });

  testWidgets('transient read failure retains facts and offers read retry',
      (tester) async {
    final f = Fixture();
    f.controller.failure = const ApiFailure(0, 'NETWORK_ERROR');
    final lastRead = f.controller.updatedAt;
    await mount(tester, f);
    expect(find.text(deviceName), findsOneWidget);
    expect(find.byKey(const Key('device-management-read-warning')),
        findsOneWidget);
    expect(find.textContaining('尚未更新'), findsWidgets);
    expect(f.controller.updatedAt, lastRead);
    await press(tester, 'device-management-refresh');
    expect(f.controller.refreshCalls, 1);
    expect(f.controller.confirmedMutations, 0);
    expect(find.text(deviceName), findsOneWidget);
    expect(f.closeCalls, 0);
  });

  testWidgets('unknown cloud revoke only checks and never invokes revoke again',
      (tester) async {
    final f = Fixture();
    f.controller.unknownValue = true;
    f.controller.failure = const ApiFailure(0, 'DEVICE_REVOKE_RESULT_UNKNOWN');
    await mount(tester, f);
    expect(find.byKey(const Key('device-management-check-result')),
        findsOneWidget);
    expect(find.byKey(const Key('device-management-revoke')), findsNothing);
    await press(tester, 'device-management-check-result');
    expect(f.controller.refreshCalls, 1);
    expect(f.controller.revokeCalls, 0);
    expect(f.controller.confirmedMutations, 0);
    expect(f.controller.device?.state, 'ACTIVE');
    expect(f.controller.revokeResultUnknown, isTrue);
    expect(find.byKey(const Key('device-management-check-result')),
        findsOneWidget);
    await press(tester, 'device-management-close');
    expect(f.closeCalls, 1);
  });

  testWidgets('accepted revoke awaiting a read stays in the check-only flow',
      (tester) async {
    final f = Fixture();
    f.controller.acceptedAwaitingReadValue = true;
    await mount(tester, f);
    expect(find.textContaining('已接受'), findsWidgets);
    expect(find.byKey(const Key('device-management-revoke')), findsNothing);
    await press(tester, 'device-management-check-result');
    expect(f.controller.refreshCalls, 1);
    expect(f.controller.revokeCalls, 0);
    expect(f.closeCalls, 0);
  });

  testWidgets(
      'cloud revoke explains local limits and cancellation does not write',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    await press(tester, 'device-management-revoke');
    expect(find.textContaining('不会向设备发送本地清理命令'), findsOneWidget);
    expect(find.textContaining('本地数据已删除'), findsOneWidget);
    expect(find.text('确认撤销云端访问'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(f.controller.revokeCalls, 1);
    expect(f.controller.confirmedMutations, 0);
    expect(f.controller.refreshCalls, 0);
    expect(f.closeCalls, 0);
    expect(find.byKey(const Key('device-management-dialog')), findsOneWidget);
  });

  testWidgets('explicit cloud confirmation updates the existing detail',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    await press(tester, 'device-management-revoke');
    expect(f.controller.confirmedMutations, 0);
    await tester.tap(find.text('确认撤销云端访问'));
    await tester.pumpAndSettle();
    expect(f.controller.revokeCalls, 1);
    expect(f.controller.confirmedMutations, 1);
    expect(f.controller.refreshCalls, 1);
    expect(f.controller.device?.state, 'REVOKED');
    expect(find.byKey(const Key('device-management-revoke')), findsNothing);
    expect(find.byKey(const Key('device-management-exit')), findsOneWidget);
    expect(find.byKey(const Key('device-management-dialog')), findsOneWidget);
    expect(f.closeCalls, 0);
  });

  testWidgets(
      'scope loss while confirming conceals the target and sends no write',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    await press(tester, 'device-management-revoke');
    expect(find.text('确认撤销云端访问'), findsOneWidget);
    f.controller.scopeValid = false;
    f.changes.value++;
    await tester.pumpAndSettle();
    expect(find.textContaining(deviceName), findsNothing);
    expect(find.text('确认撤销云端访问'), findsNothing);
    expect(f.controller.confirmedMutations, 0);
    expect(f.closeCalls, 0);
    expect(find.byKey(const Key('device-management-dialog')), findsOneWidget);
  });

  testWidgets(
      'detached parent invalidates its retained confirmation and queued acceptance',
      (tester) async {
    final controller = FakeDeviceManagementController();
    final selection =
        ValueNotifier<FakeDeviceManagementController?>(controller);
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      selection.dispose();
      if (controller.disposalCalls == 0) controller.dispose();
    });
    await tester.pumpWidget(controlledHost(selection, navigatorKey));
    await tester.pumpAndSettle();
    await press(tester, 'device-management-revoke');
    final queuedAcceptance = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '确认撤销云端访问'))
        .onPressed!;
    final navigator = navigatorKey.currentState;
    selection.value = null;
    await tester.pumpAndSettle();
    expect(navigatorKey.currentState, same(navigator));
    expect(find.byType(DeviceManagementDialog), findsNothing);
    expect(controller.disposalCalls, 0);
    expect(controller.hasAccess, isTrue,
        reason:
            'The host retains a live controller after removing its widget.');
    final targetStillVisible =
        find.textContaining(deviceName).evaluate().isNotEmpty;
    final confirmationStillVisible =
        find.text('确认撤销云端访问').evaluate().isNotEmpty;
    if (find.byType(AlertDialog).evaluate().isNotEmpty) {
      // Simulate acceptance already queued before the parent disappeared. The
      // retained route may remain with generic text, or may be closed safely.
      queuedAcceptance();
      await tester.pumpAndSettle();
    }
    expect(controller.confirmedMutations, 0);
    expect(targetStillVisible, isFalse);
    expect(confirmationStillVisible, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'controller replacement invalidates the old confirmation and queued acceptance',
      (tester) async {
    final original = FakeDeviceManagementController();
    final replacement = FakeDeviceManagementController()
      ..value = namedDevice('另一台平板');
    final selection = ValueNotifier<FakeDeviceManagementController?>(original);
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      selection.dispose();
      for (final controller in [original, replacement]) {
        if (controller.disposalCalls == 0) controller.dispose();
      }
    });
    var opened = 0;
    await tester.pumpWidget(controlledHost(selection, navigatorKey,
        onDiagnostic: (_) async { opened++; }));
    await tester.pumpAndSettle();
    final queuedDiagnostic = tester.widget<ButtonStyleButton>(find.byKey(
        const Key('device-management-diagnostic'))).onPressed!;
    await press(tester, 'device-management-revoke');
    final queuedAcceptance = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '确认撤销云端访问'))
        .onPressed!;
    final windowState = tester.state(find.byType(DeviceManagementDialog));
    selection.value = replacement;
    await tester.pumpAndSettle();
    expect(
        tester.state(find.byType(DeviceManagementDialog)), same(windowState));
    expect(replacement.initializationCalls, 1);
    expect(original.disposalCalls, 0);
    expect(original.hasAccess, isTrue,
        reason:
            'Changing the widget does not dispose or revoke the old owner.');
    final targetStillVisible =
        find.textContaining(deviceName).evaluate().isNotEmpty;
    final confirmationStillVisible =
        find.text('确认撤销云端访问').evaluate().isNotEmpty;
    if (find.byType(AlertDialog).evaluate().isNotEmpty) {
      queuedAcceptance();
      await tester.pumpAndSettle();
    }
    expect(original.confirmedMutations, 0);
    expect(replacement.confirmedMutations, 0);
    if (find.text('返回设备管理').evaluate().isNotEmpty) {
      await tester.tap(find.text('返回设备管理'));
      await tester.pumpAndSettle();
    }
    expect(ModalRoute.of(tester.element(find.byType(DeviceManagementDialog)))!
        .isCurrent, isTrue);
    queuedDiagnostic();
    await tester.pumpAndSettle();
    expect(opened, 0);
    expect(original.actionDispatches, 0);
    expect(replacement.actionDispatches, 0,
        reason: 'A queued old button must not silently target the new device.');
    await press(tester, 'device-management-diagnostic');
    expect(opened, 1);
    expect(replacement.actionDispatches, 1);
    expect(replacement.refreshCalls, 0);
    expect(targetStillVisible, isFalse);
    expect(confirmationStillVisible, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'queued controls stay retired across controller replacement and return',
      (tester) async {
    final original = FakeDeviceManagementController()
      ..selected = DeviceManagementSection.applications
      ..failure = const ApiFailure(401, 'REAUTH_REQUIRED');
    final replacement = FakeDeviceManagementController()
      ..selected = DeviceManagementSection.applications
      ..value = namedDevice('另一台平板')
      ..failure = const ApiFailure(401, 'REAUTH_REQUIRED');
    final selection = ValueNotifier<FakeDeviceManagementController?>(original);
    final navigatorKey = GlobalKey<NavigatorState>();
    var closeCalls = 0, reauthCalls = 0, opened = 0;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      selection.dispose();
      for (final controller in [original, replacement]) {
        if (controller.disposalCalls == 0) controller.dispose();
      }
    });
    await tester.pumpWidget(controlledHost(selection, navigatorKey,
        onDiagnostic: (_) async { opened++; },
        onClose: () => closeCalls++,
        onReauth: () => reauthCalls++));
    await tester.pumpAndSettle();
    final windowState = tester.state(find.byType(DeviceManagementDialog));
    final search = find.byKey(const Key('device-app-search'));
    final clear = find.byWidgetPredicate((widget) =>
        widget is IconButton && widget.tooltip == '清除应用查找');
    await tester.enterText(search, '学习');
    await tester.pump();
    final queuedSearchChanged = tester.widget<TextField>(search).onChanged!;
    final queuedButtons = <VoidCallback>[
      for (final key in [
        'device-section-capabilities',
        'device-management-refresh',
        'device-management-revoke',
        'device-management-reauth',
        'device-management-diagnostic',
      ])
        tester.widget<ButtonStyleButton>(find.byKey(Key(key))).onPressed!,
      tester.widget<IconButton>(find.byKey(
          const Key('device-management-close'))).onPressed!,
      tester.widget<IconButton>(clear).onPressed!,
    ];

    for (final current in [replacement, original]) {
      selection.value = current;
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(DeviceManagementDialog)),
          same(windowState));
      await tester.enterText(search, 'com.example.video');
      await tester.pump();
      for (final queued in queuedButtons) {
        queued();
      }
      queuedSearchChanged('学习');
      await tester.pumpAndSettle();
      for (final controller in [original, replacement]) {
        expect(controller.sections, isEmpty);
        expect(controller.refreshCalls, 0,
            reason: 'A retained refresh must not read either controller.');
        expect(controller.revokeCalls, 0);
        expect(controller.actionDispatches, 0);
      }
      expect(closeCalls, 0);
      expect(reauthCalls, 0);
      expect(opened, 0);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.widget<TextField>(search).controller!.text,
          'com.example.video');
      expect(find.text('视频应用'), findsOneWidget);
      expect(find.text('学习应用'), findsNothing);
      expect(tester.takeException(), isNull);
    }

    await tester.ensureVisible(clear);
    await tester.tap(clear);
    await tester.pump();
    expect(tester.widget<TextField>(search).controller!.text, isEmpty);
    expect(find.text('学习应用'), findsOneWidget);
    await press(tester, 'device-section-capabilities');
    await press(tester, 'device-section-applications');
    expect(original.sections, [
      DeviceManagementSection.capabilities,
      DeviceManagementSection.applications,
    ]);
    await press(tester, 'device-management-diagnostic');
    expect(opened, 1);
    expect(original.actionDispatches, 1);
    await press(tester, 'device-management-reauth');
    expect(reauthCalls, 1);
    await press(tester, 'device-management-refresh');
    expect(original.refreshCalls, 1);
    await press(tester, 'device-management-revoke');
    expect(find.text('确认撤销云端访问'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(original.revokeCalls, 1);
    expect(original.confirmedMutations, 0);
    await press(tester, 'device-management-close');
    expect(closeCalls, 1);
    expect(replacement.refreshCalls, 0);
    expect(replacement.revokeCalls, 0);
    expect(replacement.actionDispatches, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'retained confirmation survives media changes after its host disposes the controller',
      (tester) async {
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = DisposedConfirmationController();
    final selection =
        ValueNotifier<FakeDeviceManagementController?>(controller);
    final scale = ValueNotifier<double>(1);
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      selection.dispose();
      scale.dispose();
      if (controller.disposalCalls == 0) controller.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      theme: consoleTheme(),
      builder: (context, child) => ValueListenableBuilder<double>(
        valueListenable: scale,
        builder: (_, value, __) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(value)),
          child: child!,
        ),
      ),
      home: ValueListenableBuilder<FakeDeviceManagementController?>(
        valueListenable: selection,
        builder: (_, selected, __) => Scaffold(
          body: selected == null
              ? const Text('设备窗口已移除')
              : DeviceManagementDialog(
                  controller: selected,
                  onClose: () {},
                ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await press(tester, 'device-management-revoke');
    final queuedAcceptance = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '确认撤销云端访问'))
        .onPressed!;
    final navigator = navigatorKey.currentState;
    final confirmationRoute =
        ModalRoute.of(tester.element(find.byType(AlertDialog)));
    selection.value = null;
    await tester.pumpAndSettle();
    expect(find.byType(DeviceManagementDialog), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget,
        reason: 'Keep the original confirmation route and Navigator alive.');
    controller.dispose();
    expect(controller.disposalCalls, 1);

    tester.view.physicalSize = const Size(390, 844);
    scale.value = 1.5;
    await tester.pumpAndSettle();
    expect(navigatorKey.currentState, same(navigator));
    expect(controller.disposedSubscriptions, 0,
        reason: 'A media rebuild must not subscribe to a released controller.');
    expect(tester.takeException(), isNull);
    expect(ModalRoute.of(tester.element(find.byType(AlertDialog))),
        same(confirmationRoute));
    expect(find.textContaining(deviceName), findsNothing);
    expect(find.text('确认撤销云端访问'), findsNothing);
    final back = find.widgetWithText(TextButton, '返回设备管理');
    expect(back, findsOneWidget);
    expect(tester.widget<TextButton>(back).onPressed, isNotNull);
    await tester.tap(back);
    await tester.pumpAndSettle();
    queuedAcceptance();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('设备窗口已移除'), findsOneWidget);
    expect(controller.confirmedMutations, 0);
    expect(controller.refreshCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('close is disabled during writes but remains usable during reads',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    final close = find.byKey(const Key('device-management-close'));
    final queuedClose = tester.widget<IconButton>(close).onPressed!;
    final queuedRefresh = tester.widget<ButtonStyleButton>(find.byKey(
        const Key('device-management-refresh'))).onPressed!;
    final queuedRevoke = tester.widget<ButtonStyleButton>(find.byKey(
        const Key('device-management-revoke'))).onPressed!;
    f.controller.busyValue = true;
    f.controller.writeBusyValue = true;
    f.controller.publish();
    await tester.pump();
    expect(tester.widget<IconButton>(close).onPressed, isNull);
    queuedClose();
    queuedRefresh();
    queuedRevoke();
    await tester.pump();
    expect(f.closeCalls, 0);
    expect(f.controller.refreshCalls, 0);
    expect(f.controller.revokeCalls, 0);
    f.controller.writeBusyValue = false;
    f.controller.publish();
    await tester.pump();
    expect(tester.widget<IconButton>(close).onPressed, isNotNull);
    await tester.tap(close);
    await tester.pump();
    expect(f.closeCalls, 1);
    expect(f.controller.confirmedMutations, 0);
  });

  testWidgets(
      'host retains controller ownership and detached signals do nothing',
      (tester) async {
    final f = Fixture();
    f.controller.selected = DeviceManagementSection.applications;
    await mount(tester, f);
    expect(f.controller.initializationCalls, 1);
    final queuedSearchChanged = tester.widget<TextField>(find.byKey(
        const Key('device-app-search'))).onChanged!;
    await tester.pumpWidget(const SizedBox.shrink());
    expect(f.controller.disposalCalls, 0);
    final checked = f.controller.scopeChecks;
    f.changes.value++;
    expect(() => queuedSearchChanged('学习'), returnsNormally);
    await tester.pump();
    expect(f.controller.scopeChecks, checked);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'MFA retry delegates reauthentication without closing readable facts',
      (tester) async {
    final f = Fixture();
    f.controller.failure = const ApiFailure(401, 'REAUTH_REQUIRED');
    await mount(tester, f);
    expect(find.text(deviceName), findsOneWidget);
    await press(tester, 'device-management-reauth');
    expect(f.reauthCalls, 1);
    expect(f.closeCalls, 0);
    expect(f.controller.confirmedMutations, 0);
  });

  testWidgets('opaque identifiers are secondary and can be expanded in place',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    expect(find.text(deviceName), findsOneWidget);
    expect(find.textContaining(deviceId), findsNothing);
    expect(find.textContaining(subjectId), findsNothing);
    await press(tester, 'device-management-identifiers');
    expect(find.textContaining(deviceId), findsOneWidget);
    expect(find.textContaining(subjectId), findsOneWidget);
    expect(find.textContaining(registrationId), findsOneWidget);
    expect(f.controller.refreshCalls, 0);
    expect(f.closeCalls, 0);
  });

  testWidgets(
      'device-reported grant does not become verified effective capability',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    await press(tester, 'device-section-capabilities');
    expect(
        find.byKey(const Key('device-capabilities-content')), findsOneWidget);
    expect(find.textContaining('设备自报'), findsWidgets);
    expect(find.textContaining('尚未认证'), findsWidgets);
    expect(find.text('已验证支持'), findsNothing);
    expect(f.controller.capabilities?.effectiveCount, 0);
  });

  testWidgets(
      '390 wide large text keeps navigation and accessible close reachable',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    try {
      final f = Fixture();
      await mount(tester, f, scale: 1.5);
      expect(find.text(deviceName), findsOneWidget);
      await press(tester, 'device-section-applications');
      final search = find.byKey(const Key('device-app-search'));
      await tester.ensureVisible(search);
      await tester.enterText(search, '学习');
      await tester.pump();
      expect(find.text('学习应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final close = find.byKey(const Key('device-management-close'));
      await tester.ensureVisible(close);
      expect(
          tester.getSemantics(close).hasFlag(SemanticsFlag.isButton), isTrue);
      expect(
          tester.getSemantics(close).hasFlag(SemanticsFlag.isEnabled), isTrue);
      expect(find.byTooltip('关闭设备管理'), findsOneWidget);
      await tester.tap(close);
      await tester.pump();
      expect(f.closeCalls, 1);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
      'legal 100 character name at double text scale keeps navigation and close reachable',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    try {
      final fullName = '学习' * 50;
      final f = Fixture();
      f.controller.value = namedDevice(fullName);
      await mount(tester, f, scale: 2);
      expect(tester.takeException(), isNull);
      expect(
          find.bySemanticsLabel(RegExp(RegExp.escape(fullName))), findsWidgets,
          reason:
              'A shortened title must retain its complete accessible name.');
      for (final section in ['capabilities', 'applications', 'overview']) {
        await press(tester, 'device-section-$section');
        expect(tester.takeException(), isNull);
      }
      final close = find.byKey(const Key('device-management-close'));
      await tester.ensureVisible(close);
      expect(tester.widget<IconButton>(close).onPressed, isNotNull);
      await tester.tap(close);
      await tester.pump();
      expect(f.closeCalls, 1);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
      'keyboard insets keep application search usable inside its scroll viewport',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final f = Fixture();
    await mount(tester, f, scale: 2);
    await press(tester, 'device-section-applications');
    final search = find.byKey(const Key('device-app-search'));
    await tester.ensureVisible(search);
    await tester.tap(search);
    tester.view.viewInsets = const FakeViewPadding(bottom: 420);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(search);
    await tester.enterText(search, 'com.example.video');
    await tester.pump();
    final scrollable =
        find.ancestor(of: search, matching: find.byType(Scrollable)).first;
    final viewport = tester.getRect(scrollable);
    final field = tester.getRect(search);
    expect(field.top, greaterThanOrEqualTo(viewport.top - 1));
    expect(field.bottom, lessThanOrEqualTo(viewport.bottom + 1),
        reason:
            'The keyboard must leave a usable viewport for the search field.');
    expect(find.text('视频应用'), findsOneWidget);
    expect(find.text('学习应用'), findsNothing);
    await tester.ensureVisible(find.text('视频应用'));
    await tester.pump();
    await tester.ensureVisible(search);
    await tester.enterText(search, '');
    await tester.pump();
    expect(find.text('学习应用'), findsOneWidget);
    expect(f.controller.refreshCalls, 0);
    expect(f.controller.sections, [DeviceManagementSection.applications]);
    expect(tester.takeException(), isNull);
  });
}
