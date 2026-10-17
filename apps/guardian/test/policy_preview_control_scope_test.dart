@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/policy_preview_results.dart';
import 'fixtures/policy_preview_fixture_data.dart';

// Synthetic display data; neither provider qualification nor device execution.
const _device = 'device-a';
const _app = 'learning-app';
const _scopeLabel = '可执行范围待设备确认';
const _operationsLabel = '查看 3 项可尝试操作';

Json _operation(String kind, String effect, [String? permission]) => {
      'kind': kind,
      'effect': effect,
      'permission': permission,
    };

Json _evidence() {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'deviceId': _device,
    'registrationId': 'registration-$_device',
    'applicationId': _app,
    'bindingId': 'binding-a',
    'bindingVersion': 3,
    'definitionRevision': 'a' * 64,
    'evidenceVersion': 5,
    'state': 'VERIFIED_IDENTITY',
    'reasonCode': 'MANAGED_APPLICATION_CONTROL_VERIFIED',
    'profileScope': 'PRIMARY',
    'systemControlAvailable': true,
    'reportedAt': now - 60000,
    'retrievedAt': now - 30000,
    'expiresAt': now + 600000,
    'controlOperations': <Object?>[
      _operation('APP_LAUNCH', 'DENY'),
      _operation('RUNTIME_PERMISSION', 'DEFAULT', 'android.permission.CAMERA'),
      _operation('APP_INSTALL', 'ALLOW'),
    ],
  };
}

Json _preview(Json evidence) {
  final preview = policyPreviewFixture({
    'deviceIds': [_device]
  });
  final target = (preview['targets'] as List).single as Json;
  target['managementMode'] = 'DEVICE_OWNER';
  target['applicationEvidence'] = [evidence];
  return preview;
}

Future<void> _mount(WidgetTester tester, Json preview,
    {double width = 1100, double scale = 1}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: consoleTheme(),
    builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: PolicyPreviewResults(
            preview: preview, names: const {_device: '教室平板 A'}),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('教室平板 A'));
  await tester.tap(find.text('教室平板 A'));
  await tester.pumpAndSettle();
}

Future<void> _expandOperations(WidgetTester tester) async {
  await tester.ensureVisible(find.text(_operationsLabel));
  await tester.tap(find.text(_operationsLabel));
  await tester.pumpAndSettle();
}

void _noExecutionOrWriteClaim() {
  for (final text in ['已执行', '已应用', '已管控', '已生效', '支持执行']) {
    expect(find.text(text), findsNothing, reason: text);
  }
  expect(find.byType(FilledButton), findsNothing);
  expect(find.byType(OutlinedButton), findsNothing);
  expect(find.byType(TextButton), findsNothing);
}

void main() {
  for (final state in ['FAILED', 'UNAVAILABLE']) {
    testWidgets(
        '$state names the application check entry in device association',
        (tester) async {
      final evidence = _evidence()
        ..['state'] = state
        ..['reasonCode'] = 'MANAGED_APPLICATION_PROVIDER_UNAVAILABLE';
      await _mount(tester, _preview(evidence));
      expect(
          find.textContaining('机构受管 Android → 关联儿童端 → 应用核验'), findsOneWidget);
      expect(find.textContaining('设备应用核验页面'), findsNothing);
      _noExecutionOrWriteClaim();
    });
  }

  testWidgets('reviewed operations show exact read-only scope pending feedback',
      (tester) async {
    await _mount(tester, _preview(_evidence()));
    expect(find.text(_scopeLabel), findsOneWidget);
    expect(find.text('系统控制尚未确认'), findsNothing);
    expect(find.text(_operationsLabel), findsOneWidget);
    expect(find.text('应用启动 · 禁止'), findsNothing);
    await _expandOperations(tester);
    expect(find.text('应用启动 · 禁止'), findsOneWidget);
    expect(find.text('应用安装 · 允许'), findsOneWidget);
    expect(find.text('相机 · CAMERA · 恢复用户询问'), findsOneWidget);
    expect(find.text('操作范围通过核验，尚未执行；实际结果请查看执行记录。'), findsOneWidget);
    _noExecutionOrWriteClaim();
    expect(tester.takeException(), isNull);
  });

  for (final fixture in <String, Json Function()>{
    'report within configured skew': () {
      final now = DateTime.now().millisecondsSinceEpoch;
      return {
        ..._evidence(),
        'reportedAt': now + 10000,
        'retrievedAt': now - 5000,
        'expiresAt': now + 600000,
      };
    },
    'report beyond reuse deadline': () {
      final now = DateTime.now().millisecondsSinceEpoch;
      return {
        ..._evidence(),
        'reportedAt': now + 25000,
        'retrievedAt': now - 5000,
        'expiresAt': now + 20000,
      };
    },
  }.entries) {
    testWidgets(
        'report clock tolerance: ${fixture.key} preserves reviewed scope',
        (tester) async {
      // The server accepts up to 30 seconds of configured report clock skew;
      // its independent reuse deadline can precede the device report time.
      await _mount(tester, _preview(fixture.value()));
      expect(find.text(_scopeLabel), findsOneWidget);
      expect(find.text(_operationsLabel), findsOneWidget);
      await _expandOperations(tester);
      expect(find.text('应用启动 · 禁止'), findsOneWidget);
      expect(find.text('应用安装 · 允许'), findsOneWidget);
      expect(find.text('相机 · CAMERA · 恢复用户询问'), findsOneWidget);
      _noExecutionOrWriteClaim();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unsupported rule operation has a specific readable next step',
      (tester) async {
    final preview = _preview(_evidence());
    final target = (preview['targets'] as List).single as Json;
    final rule = (target['rules'] as List).first as Json;
    rule['status'] = 'UNVERIFIED';
    rule['reasonCode'] = 'APPLICATION_CONTROL_OPERATION_NOT_VERIFIED';
    await _mount(tester, preview);
    expect(find.text('此应用的该项操作尚未核验，请调整规则或更新应用核验。'), findsOneWidget);
    _noExecutionOrWriteClaim();
    expect(tester.takeException(), isNull);
  });

  final invalid = <String, void Function(Json)>{
    'identity-only reason': (e) =>
        e['reasonCode'] = 'MANAGED_APPLICATION_PROFILE_UNVERIFIED',
    'false control flag': (e) => e['systemControlAvailable'] = false,
    'string control flag': (e) => e['systemControlAvailable'] = 'true',
    'unknown profile': (e) => e['profileScope'] = 'UNKNOWN',
    'wrong device': (e) => e['deviceId'] = 'device-b',
    'wrong registration': (e) => e['registrationId'] = 'registration-b',
    'expired evidence': (e) =>
        e['expiresAt'] = DateTime.now().millisecondsSinceEpoch - 1,
    'future report': (e) => e['reportedAt'] = (e['retrievedAt'] as int) + 31000,
    'unrecognized state': (e) => e['state'] = 'FUTURE_STATE',
    'missing operations': (e) => e.remove('controlOperations'),
    'empty operations': (e) => e['controlOperations'] = <Json>[],
    'malformed operations': (e) => e['controlOperations'] = 'not-a-list',
    'mixed malformed item': (e) => (e['controlOperations'] as List).add(null),
    'duplicate operation': (e) =>
        (e['controlOperations'] as List).add(_operation('APP_LAUNCH', 'DENY')),
    'unknown kind': (e) =>
        (e['controlOperations'] as List).add(_operation('FUTURE_KIND', 'DENY')),
    'automatic grant': (e) => (e['controlOperations'] as List).add(
        _operation('RUNTIME_PERMISSION', 'GRANT', 'android.permission.CAMERA')),
    'wildcard permission': (e) => (e['controlOperations'] as List)
        .add(_operation('RUNTIME_PERMISSION', 'DENY', 'android.permission.*')),
    'unsupported permission': (e) => (e['controlOperations'] as List).add(
        _operation('RUNTIME_PERMISSION', 'DENY', 'android.permission.FUTURE')),
    'permission on launch': (e) => (e['controlOperations'] as List)
        .add(_operation('APP_LAUNCH', 'ALLOW', 'android.permission.CAMERA')),
    'missing operation field': (e) => (e['controlOperations'] as List)
        .add({'kind': 'APP_INSTALL', 'effect': 'DENY'}),
    'unexpected operation field': (e) => (e['controlOperations'] as List)
        .add({..._operation('APP_INSTALL', 'DENY'), 'provider': 'PRIVATE'}),
    'oversized list': (e) => e['controlOperations'] =
        List<Json>.generate(129, (_) => _operation('APP_INSTALL', 'ALLOW')),
  };
  for (final entry in invalid.entries) {
    testWidgets('${entry.key} cannot present reviewed control scope',
        (tester) async {
      final evidence = _evidence();
      entry.value(evidence);
      await _mount(tester, _preview(evidence));
      expect(find.text(_scopeLabel), findsNothing);
      expect(find.text(_operationsLabel), findsNothing);
      expect(find.text('系统控制尚未确认'), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      _noExecutionOrWriteClaim();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('expired preview hides qualified operation scope',
      (tester) async {
    final preview = _preview(_evidence());
    preview['expiresAt'] = DateTime.now().millisecondsSinceEpoch - 1;
    await _mount(tester, preview);
    expect(find.text('预览已过期，请关闭后重新预览。'), findsOneWidget);
    expect(find.text(_scopeLabel), findsNothing);
    expect(find.text(_operationsLabel), findsNothing);
    _noExecutionOrWriteClaim();
    expect(tester.takeException(), isNull);
  });

  for (final change in <String, Object>{
    'state': 'RETIRED',
    'managementMode': 'BYOD',
  }.entries) {
    testWidgets('inconsistent target ${change.key} hides qualified scope',
        (tester) async {
      final preview = _preview(_evidence());
      ((preview['targets'] as List).single as Json)[change.key] = change.value;
      await _mount(tester, preview);
      expect(find.text(_scopeLabel), findsNothing);
      expect(find.text(_operationsLabel), findsNothing);
      _noExecutionOrWriteClaim();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('conflicting duplicate records cannot show qualified scope',
      (tester) async {
    final evidence = _evidence();
    final preview = _preview(evidence);
    ((preview['targets'] as List).single as Json)['applicationEvidence'] = [
      evidence,
      {...evidence, 'evidenceVersion': 6}
    ];
    await _mount(tester, preview);
    expect(find.text('应用核验状态待确认'), findsOneWidget);
    expect(find.text(_scopeLabel), findsNothing);
    expect(find.text(_operationsLabel), findsNothing);
    _noExecutionOrWriteClaim();
    expect(tester.takeException(), isNull);
  });

  for (final deadline in ['evidence', 'preview']) {
    testWidgets('expanded scope disappears when $deadline expires',
        (tester) async {
      final evidence = _evidence();
      final preview = _preview(evidence);
      final target = (preview['targets'] as List).single as Json;
      final rule = (target['rules'] as List).first as Json;
      rule['status'] = 'SUPPORTED_PENDING';
      rule['reasonCode'] = 'AWAITING_EXECUTION';
      final expires = DateTime.now().millisecondsSinceEpoch + 5000;
      if (deadline == 'evidence') {
        evidence['expiresAt'] = expires;
      } else {
        preview['expiresAt'] = expires;
      }
      await _mount(tester, preview);
      await _expandOperations(tester);
      expect(find.text('应用启动 · 禁止'), findsOneWidget);
      expect(find.text('支持条件满足 1 项'), findsOneWidget);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5100)));
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text(_scopeLabel), findsNothing);
      expect(find.text(_operationsLabel), findsNothing);
      expect(find.text('应用启动 · 禁止'), findsNothing);
      expect(find.text('支持条件满足 0 项'), findsOneWidget);
      expect(find.text('支持条件满足 · 尚未执行'), findsNothing);
      _noExecutionOrWriteClaim();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('exact operation list remains usable at 320px with 2x text',
      (tester) async {
    await _mount(tester, _preview(_evidence()), width: 320, scale: 2);
    expect(find.text(_scopeLabel), findsOneWidget);
    await _expandOperations(tester);
    await tester.ensureVisible(find.text('相机 · CAMERA · 恢复用户询问'));
    await tester.pumpAndSettle();
    expect(find.text('相机 · CAMERA · 恢复用户询问'), findsOneWidget);
    _noExecutionOrWriteClaim();
    expect(tester.takeException(), isNull);
  });
}
