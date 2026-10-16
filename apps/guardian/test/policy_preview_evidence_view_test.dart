@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/policy_preview_results.dart';
import 'fixtures/policy_preview_fixture_data.dart';

// These are local presentation fixtures, not provider or device execution proof.
const _firstDevice = 'device-a';
const _secondDevice = 'device-b';
const _application = 'learning-app';
const _names = <String, String>{
  _firstDevice: '教室平板 A',
  _secondDevice: '教室平板 B',
};

Json _preview({List<String> devices = const [_firstDevice]}) =>
    policyPreviewFixture({'deviceIds': devices});

Json _target(Json preview, String deviceId) =>
    (preview['targets'] as List).cast<Json>().singleWhere(
          (target) => target['deviceId'] == deviceId,
        );

Json _evidence(String deviceId,
    {String state = 'VERIFIED_IDENTITY',
    String reason = 'MANAGED_APPLICATION_PROFILE_UNVERIFIED'}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return {
    'deviceId': deviceId,
    'registrationId': 'registration-$deviceId',
    'applicationId': _application,
    'bindingId': 'binding-$deviceId',
    'bindingVersion': 3,
    'definitionRevision': 'a' * 64,
    'evidenceVersion': 5,
    'state': state,
    'reasonCode': reason,
    'profileScope': 'UNKNOWN',
    'systemControlAvailable': false,
    'reportedAt': now - 60000,
    'retrievedAt': now - 30000,
    'expiresAt': now + 600000,
  };
}

Future<void> _mount(WidgetTester tester, Json preview,
    {Map<String, String> names = _names,
    double width = 1100,
    double scale = 1}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(MaterialApp(
    theme: consoleTheme(),
    builder: (context, child) => MediaQuery(
      data:
          MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: PolicyPreviewResults(
          preview: preview,
          names: names,
          selectionSummary: '来自教室设备组的当前选择',
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<Finder> _expand(WidgetTester tester, String name) async {
  final tile = find.widgetWithText(ExpansionTile, name);
  expect(tile, findsOneWidget);
  await tester.ensureVisible(find.text(name));
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
  return tile;
}

Finder _inside(Finder tile, String text) =>
    find.descendant(of: tile, matching: find.text(text));

void _expectNoExecutionClaim() {
  for (final text in ['已执行', '已应用', '已管控', '支持执行', '已生效']) {
    expect(find.text(text), findsNothing, reason: text);
  }
}

void main() {
  testWidgets('application evidence belongs to its exact device',
      (tester) async {
    final preview = _preview(devices: [_firstDevice, _secondDevice]);
    _target(preview, _firstDevice)['applicationEvidence'] = [
      _evidence(_firstDevice),
    ];
    _target(preview, _secondDevice)['applicationEvidence'] = [
      _evidence(_secondDevice,
          state: 'ABSENT', reason: 'MANAGED_APPLICATION_EVIDENCE_REQUIRED'),
    ];
    await _mount(tester, preview);
    final first = await _expand(tester, _names[_firstDevice]!);
    final second = await _expand(tester, _names[_secondDevice]!);
    expect(_inside(first, '应用身份已核验'), findsOneWidget);
    expect(_inside(first, '尚未核验此设备上的应用'), findsNothing);
    expect(_inside(second, '尚未核验此设备上的应用'), findsOneWidget);
    expect(_inside(second, '应用身份已核验'), findsNothing);
    _expectNoExecutionClaim();
    expect(tester.takeException(), isNull);
  });

  testWidgets('verified identity does not claim system control or execution',
      (tester) async {
    final preview = _preview();
    _target(preview, _firstDevice)['applicationEvidence'] = [
      _evidence(_firstDevice),
    ];
    await _mount(tester, preview);
    final tile = await _expand(tester, _names[_firstDevice]!);
    expect(_inside(tile, '学习应用'), findsWidgets);
    expect(_inside(tile, '应用身份已核验'), findsOneWidget);
    expect(_inside(tile, '系统控制尚未确认'), findsOneWidget);
    _expectNoExecutionClaim();
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing application evidence remains unverified',
      (tester) async {
    final preview = _preview();
    _target(preview, _firstDevice).remove('applicationEvidence');
    await _mount(tester, preview);
    final tile = await _expand(tester, _names[_firstDevice]!);
    expect(_inside(tile, '尚未核验此设备上的应用'), findsOneWidget);
    expect(_inside(tile, '应用身份已核验'), findsNothing);
    expect(_inside(tile, '系统控制尚未确认'), findsOneWidget);
    _expectNoExecutionClaim();
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale evidence explains that fresh verification is required',
      (tester) async {
    final preview = _preview();
    final evidence = _evidence(_firstDevice,
        state: 'STALE', reason: 'MANAGED_APPLICATION_CONTEXT_CHANGED');
    evidence['reportedAt'] = null;
    evidence['retrievedAt'] = null;
    evidence['expiresAt'] = null;
    _target(preview, _firstDevice)['applicationEvidence'] = [evidence];
    await _mount(tester, preview);
    final tile = await _expand(tester, _names[_firstDevice]!);
    expect(_inside(tile, '核验结果已过期或设备信息已变化'), findsOneWidget);
    expect(_inside(tile, '应用身份已核验'), findsNothing);
    _expectNoExecutionClaim();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a verified label cannot revive an expired identity record',
      (tester) async {
    final preview = _preview();
    final evidence = _evidence(_firstDevice);
    evidence['expiresAt'] = DateTime.now().millisecondsSinceEpoch - 1000;
    _target(preview, _firstDevice)['applicationEvidence'] = [evidence];
    await _mount(tester, preview);
    final tile = await _expand(tester, _names[_firstDevice]!);
    expect(_inside(tile, '核验结果已过期或设备信息已变化'), findsOneWidget);
    expect(_inside(tile, '应用身份已核验'), findsNothing);
    _expectNoExecutionClaim();
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown evidence states remain neutral', (tester) async {
    final preview = _preview();
    _target(preview, _firstDevice)['applicationEvidence'] = [
      _evidence(_firstDevice, state: 'FUTURE_STATE', reason: 'FUTURE_REASON'),
    ];
    await _mount(tester, preview);
    final tile = await _expand(tester, _names[_firstDevice]!);
    expect(_inside(tile, '应用核验状态待确认'), findsOneWidget);
    expect(_inside(tile, '应用身份已核验'), findsNothing);
    expect(_inside(tile, '系统控制尚未确认'), findsOneWidget);
    _expectNoExecutionClaim();
    expect(tester.takeException(), isNull);
  });

  for (final field in ['deviceId', 'registrationId']) {
    testWidgets('identity evidence rejects mismatched $field', (tester) async {
      final preview = _preview();
      final evidence = _evidence(_firstDevice);
      evidence[field] = 'different-$field';
      _target(preview, _firstDevice)['applicationEvidence'] = [evidence];
      await _mount(tester, preview);
      final tile = await _expand(tester, _names[_firstDevice]!);
      expect(_inside(tile, '应用核验记录与当前设备不匹配'), findsOneWidget);
      expect(_inside(tile, '应用身份已核验'), findsNothing);
      _expectNoExecutionClaim();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'an unrelated application record cannot verify a rule application',
      (tester) async {
    final preview = _preview();
    final evidence = _evidence(_firstDevice);
    evidence['applicationId'] = 'unrelated-app';
    _target(preview, _firstDevice)['applicationEvidence'] = [evidence];
    await _mount(tester, preview);
    final tile = await _expand(tester, _names[_firstDevice]!);
    expect(_inside(tile, '尚未核验此设备上的应用'), findsOneWidget);
    expect(_inside(tile, '应用身份已核验'), findsNothing);
    _expectNoExecutionClaim();
    expect(tester.takeException(), isNull);
  });

  const unavailableCases = [
    (
      'MANAGED_BINDING_REQUIRED',
      '此设备尚未完成受管绑定',
      '完成设备绑定后重新预览',
    ),
    (
      'MANAGED_APPLICATION_ADMIN_REQUIRED',
      '需要机构管理员核验',
      '请联系机构管理员完成核验后重新预览',
    ),
  ];
  for (final unavailable in unavailableCases) {
    testWidgets(
        'unavailable ${unavailable.$1} offers guidance without authority',
        (tester) async {
      final preview = _preview();
      final evidence =
          _evidence(_firstDevice, state: 'UNAVAILABLE', reason: unavailable.$1);
      evidence['reportedAt'] = null;
      evidence['retrievedAt'] = null;
      evidence['expiresAt'] = null;
      _target(preview, _firstDevice)['applicationEvidence'] = [evidence];
      await _mount(tester, preview);
      final tile = await _expand(tester, _names[_firstDevice]!);
      expect(_inside(tile, unavailable.$2), findsOneWidget);
      expect(_inside(tile, unavailable.$3), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byTooltip('刷新应用核验'), findsNothing);
      expect(_inside(tile, '应用身份已核验'), findsNothing);
      _expectNoExecutionClaim();
      expect(tester.takeException(), isNull);
    });
  }

  for (final field in ['reportedAt', 'retrievedAt', 'expiresAt']) {
    for (final badValue in [null, 'not-an-integer', 1.5]) {
      testWidgets('verified evidence needs integer $field ($badValue)',
          (tester) async {
        final preview = _preview();
        final evidence = _evidence(_firstDevice);
        evidence[field] = badValue;
        _target(preview, _firstDevice)['applicationEvidence'] = [evidence];
        await _mount(tester, preview);
        final tile = await _expand(tester, _names[_firstDevice]!);
        expect(_inside(tile, '应用核验状态待确认'), findsOneWidget);
        expect(_inside(tile, '应用身份已核验'), findsNothing);
        _expectNoExecutionClaim();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('nullable and malformed evidence fields render safely',
      (tester) async {
    final preview = _preview();
    final evidence = _evidence(_firstDevice);
    evidence.addAll({
      'state': null,
      'reasonCode': 123,
      'bindingId': null,
      'definitionRevision': null,
      'reportedAt': null,
      'retrievedAt': null,
      'expiresAt': null,
      'futureField': {'nested': true},
    });
    _target(preview, _firstDevice)['applicationEvidence'] = [
      null,
      42,
      'not-a-record',
      evidence,
    ];
    await _mount(tester, preview);
    final tile = await _expand(tester, _names[_firstDevice]!);
    expect(_inside(tile, '应用核验状态待确认'), findsOneWidget);
    expect(_inside(tile, '应用身份已核验'), findsNothing);
    _expectNoExecutionClaim();
    expect(tester.takeException(), isNull);
  });

  testWidgets('an expired preview asks for a fresh preview', (tester) async {
    final preview = _preview();
    preview['expiresAt'] = DateTime.now().millisecondsSinceEpoch - 1000;
    await _mount(tester, preview);
    expect(find.text('预览已过期，请关闭后重新预览。'), findsOneWidget);
    _expectNoExecutionClaim();
    expect(tester.takeException(), isNull);
  });

  testWidgets('fifty devices keep five thousand checks collapsed until opened',
      (tester) async {
    final deviceIds = List<String>.generate(50, (index) => 'device-$index');
    final names = <String, String>{
      for (var index = 0; index < 50; index++)
        deviceIds[index]: '教室平板 ${index + 1}',
    };
    final preview = _preview(devices: deviceIds);
    for (final target in (preview['targets'] as List).cast<Json>()) {
      final domainRule =
          Map<String, dynamic>.from((target['rules'] as List).last as Json);
      target['rules'] = List<Json>.generate(
          100,
          (index) => {
                ...domainRule,
                'sourceRuleIds': ['domain-$index'],
                'domain': 'service-$index.example.edu',
              });
    }
    await _mount(tester, preview, names: names);
    expect(find.text('50 台设备'), findsOneWidget);
    expect(find.text('5000 项检查'), findsOneWidget);
    expect(find.text('待核验 5000 项'), findsOneWidget);
    expect(find.text('域名访问'), findsNothing);
    expect(find.text('service-0.example.edu'), findsNothing);

    final first = await _expand(tester, names[deviceIds.first]!);
    expect(_inside(first, '域名访问'), findsNWidgets(100));
    expect(find.text('域名访问'), findsNWidgets(100));
    expect(find.text('service-0.example.edu'), findsOneWidget);
    final second = find.widgetWithText(ExpansionTile, names[deviceIds[1]]!);
    expect(_inside(second, '域名访问'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byTooltip('刷新应用核验'), findsNothing);
    _expectNoExecutionClaim();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'duplicate application records cannot establish verified identity',
      (tester) async {
    final preview = _preview();
    _target(preview, _firstDevice)['applicationEvidence'] = [
      _evidence(_firstDevice),
      _evidence(_firstDevice),
    ];
    await _mount(tester, preview);
    final tile = await _expand(tester, _names[_firstDevice]!);
    expect(_inside(tile, '应用核验状态待确认'), findsOneWidget);
    expect(_inside(tile, '应用身份已核验'), findsNothing);
    expect(_inside(tile, '系统控制尚未确认'), findsOneWidget);
    expect(find.textContaining('报告时间'), findsNothing);
    _expectNoExecutionClaim();
    expect(tester.takeException(), isNull);
  });

  testWidgets('committed rule kinds have specific readable Chinese titles',
      (tester) async {
    const kinds = <String, String>{
      'APP_LAUNCH': '应用启动',
      'APP_INSTALL': '应用安装',
      'APP_UNINSTALL': '应用卸载',
      'RUNTIME_PERMISSION': '应用权限',
      'SPECIAL_ACCESS': '特殊访问权限',
      'DAILY_QUOTA': '每日使用时长',
      'TIME_WINDOW': '使用时段',
      'DOMAIN_ACCESS': '域名访问',
      'USAGE_REMINDER': '使用提醒',
      'FUTURE_RULE_KIND': '规则检查',
    };
    final preview = _preview();
    final target = _target(preview, _firstDevice);
    final template =
        Map<String, dynamic>.from((target['rules'] as List).first as Json);
    target['rules'] = <Json>[
      for (final kind in kinds.keys)
        {
          ...template,
          'kind': kind,
          'applicationId': null,
          'sourceRuleIds': ['source-$kind'],
          'status': 'UNKNOWN',
        },
    ];
    await _mount(tester, preview);
    final tile = await _expand(tester, _names[_firstDevice]!);
    for (final title in kinds.values) {
      expect(_inside(tile, title), findsOneWidget, reason: title);
    }
    _expectNoExecutionClaim();
    expect(tester.takeException(), isNull);
  });

  testWidgets('long names fit a 390 pixel viewport with double text size',
      (tester) async {
    final preview = _preview();
    const deviceName = '教室平板 A — 很长的设备名称用于小屏幕可读性检查';
    const appName = '学习应用 — 很长的应用名称用于大字号换行检查';
    ((preview['snapshot'] as Json)['applications'] as List)
        .first['displayName'] = appName;
    _target(preview, _firstDevice)['applicationEvidence'] = [
      _evidence(_firstDevice),
    ];
    await _mount(tester, preview,
        names: {_firstDevice: deviceName}, width: 390, scale: 2);
    final tile = await _expand(tester, deviceName);
    expect(_inside(tile, appName), findsWidgets);
    expect(_inside(tile, '应用身份已核验'), findsOneWidget);
    expect(_inside(tile, '系统控制尚未确认'), findsOneWidget);
    await tester.ensureVisible(find.text('系统控制尚未确认'));
    await tester.pumpAndSettle();
    _expectNoExecutionClaim();
    expect(tester.takeException(), isNull);
  });
}
