@TestOn('browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/policy_preview_results.dart';
import 'fixtures/policy_preview_fixture_data.dart';

// Presentation fixtures mirror committed RuleEvaluation and ScheduleEntry.
// They provide no permission authorization or proof of device execution.
const _device = 'device-a';
const _deviceName = '教室平板 A';
const _scheduleId = 'aaaabbbb-1111-4222-8333-444455556666';
const _otherScheduleId = 'aaaabbbb-1111-4222-8333-444455556667';

Json _rule(String id, String kind,
        {String effect = 'DENY',
        dynamic permission,
        dynamic scheduleId,
        String? applicationId = 'learning-app'}) =>
    {
      'sourceRuleIds': [id],
      'kind': kind,
      'applicationId': applicationId,
      'scheduleId': scheduleId,
      'permission': permission,
      'domain': null,
      'seconds': null,
      'required': true,
      'predictedEffect': effect,
      'effectiveEffect': null,
      'status': 'UNVERIFIED',
      'reasonCode': 'EVIDENCE_NOT_CERTIFIED',
      'warnings': <String>[],
    };

Json _schedule({String id = _scheduleId, String name = '放学后的自由时间'}) => {
      'id': id,
      'name': name,
      'definition': {
        'timeZone': 'Asia/Shanghai',
        'weekly': [
          {'day': 'MONDAY', 'start': '18:00', 'end': '20:00'},
          {'day': 'WEDNESDAY', 'start': '18:15', 'end': '20:45'},
        ],
        'exceptions': [
          {
            'date': '2026-10-18',
            'windows': [
              {'start': '09:00', 'end': '11:30'},
              {'start': '14:00', 'end': '15:00'},
            ],
          },
          {'date': '2026-10-19', 'windows': <Json>[]},
        ],
      },
    };

Json _preview(List<Json> rules, {dynamic schedules = const <Json>[]}) {
  final preview = policyPreviewFixture({
    'deviceIds': [_device],
  });
  (preview['targets'] as List).cast<Json>().single['rules'] = rules;
  final snapshot = preview['snapshot'] as Json;
  snapshot['schedules'] = schedules;
  snapshot['sourceRules'] = <Json>[
    for (final rule in rules)
      {
        'id': (rule['sourceRuleIds'] as List).single,
        'kind': rule['kind'],
        'effect': rule['predictedEffect'],
        'applicationId': rule['applicationId'],
        'scheduleId': rule['scheduleId'],
        'permission': rule['permission'],
        'domain': rule['domain'],
        'seconds': rule['seconds'],
        'required': rule['required'],
      },
  ];
  return preview;
}

Future<void> _mount(WidgetTester tester, Json preview,
    {String deviceName = _deviceName,
    double width = 1100,
    double scale = 1}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
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
          names: {_device: deviceName},
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(deviceName));
  await tester.tap(find.text(deviceName));
  await tester.pumpAndSettle();
}

Finder _ruleCard(String parameter) => find
    .ancestor(of: find.text(parameter), matching: find.byType(Container))
    .first;

Finder _inside(Finder parent, String text) =>
    find.descendant(of: parent, matching: find.text(text));

void _expectPreviewBoundary() {
  expect(find.text('这是发布前检查，尚未执行设备系统管控。'), findsOneWidget);
  expect(find.text('系统控制尚未确认'), findsOneWidget);
  for (final claim in ['已执行', '已应用', '已管控', '已生效', '已授予']) {
    expect(find.textContaining(claim), findsNothing, reason: claim);
  }
  expect(find.bySubtype<FilledButton>(), findsNothing);
  expect(find.bySubtype<OutlinedButton>(), findsNothing);
  expect(find.bySubtype<TextButton>(), findsNothing);
}

void main() {
  testWidgets('two runtime permissions identify their own proposed behavior',
      (tester) async {
    await _mount(
        tester,
        _preview([
          _rule('camera', 'RUNTIME_PERMISSION',
              permission: 'android.permission.CAMERA'),
          _rule('microphone', 'RUNTIME_PERMISSION',
              permission: 'android.permission.RECORD_AUDIO', effect: 'DEFAULT'),
        ]));

    expect(find.text('权限：相机 · CAMERA'), findsOneWidget);
    expect(find.text('权限：麦克风 · RECORD_AUDIO'), findsOneWidget);
    final camera = _ruleCard('权限：相机 · CAMERA');
    final microphone = _ruleCard('权限：麦克风 · RECORD_AUDIO');
    expect(_inside(camera, '拟配置：禁止'), findsOneWidget);
    expect(_inside(camera, '拟配置：系统默认'), findsNothing);
    expect(_inside(microphone, '拟配置：系统默认'), findsOneWidget);
    expect(_inside(microphone, '拟配置：禁止'), findsNothing);
    _expectPreviewBoundary();
    expect(tester.takeException(), isNull);
  });

  const specialAccessNames = {
    'USAGE_ACCESS': '使用情况访问',
    'OVERLAY': '悬浮窗',
    'NOTIFICATION_ACCESS': '通知读取',
    'ACCESSIBILITY': '无障碍服务',
    'VPN': 'VPN 连接',
  };
  for (final permission in specialAccessNames.entries) {
    testWidgets('special access ${permission.key} retains its editor name',
        (tester) async {
      await _mount(
          tester,
          _preview([
            _rule('special-access', 'SPECIAL_ACCESS',
                permission: permission.key),
          ]));
      expect(find.text('权限：${permission.value}'), findsOneWidget);
      expect(find.text('特殊访问权限'), findsOneWidget);
      expect(find.text('拟配置：禁止'), findsOneWidget);
      _expectPreviewBoundary();
      expect(tester.takeException(), isNull);
    });
  }

  for (final kind in ['RUNTIME_PERMISSION', 'SPECIAL_ACCESS']) {
    testWidgets('unknown $kind permissions keep distinct original codes',
        (tester) async {
      await _mount(
          tester,
          _preview([
            _rule('future-one', kind,
                permission: 'android.permission.FUTURE_PERMISSION_ONE'),
            _rule('future-two', kind,
                permission: 'android.permission.FUTURE_PERMISSION_TWO'),
          ]));
      expect(find.text('权限代码：android.permission.FUTURE_PERMISSION_ONE'),
          findsOneWidget);
      expect(find.text('权限代码：android.permission.FUTURE_PERMISSION_TWO'),
          findsOneWidget);
      expect(find.text('权限信息未提供'), findsNothing);
      _expectPreviewBoundary();
      expect(tester.takeException(), isNull);
    });

    for (final value in [null, '', 42]) {
      testWidgets(
          'missing or malformed $kind permission ($value) stays neutral',
          (tester) async {
        await _mount(
            tester,
            _preview([
              _rule('missing-permission', kind, permission: value),
            ]));
        expect(find.text('权限信息未提供'), findsOneWidget);
        expect(find.textContaining('权限代码：'), findsNothing);
        expect(find.textContaining('权限：'), findsNothing);
        _expectPreviewBoundary();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('time window uses the exact snapshot id and complete definition',
      (tester) async {
    final unrelated = _schedule(id: _otherScheduleId, name: '不属于此规则的计划');
    (unrelated['definition'] as Json)['timeZone'] = 'UTC';
    await _mount(
        tester,
        _preview([
          _rule('allowed-time', 'TIME_WINDOW',
              effect: 'ALLOW', scheduleId: _scheduleId),
        ], schedules: [
          unrelated,
          _schedule()
        ]));

    expect(find.text('时间计划：放学后的自由时间'), findsOneWidget);
    expect(find.text('时区：Asia/Shanghai'), findsOneWidget);
    expect(find.text('每周时段：周一 18:00–20:00'), findsOneWidget);
    expect(find.text('每周时段：周三 18:15–20:45'), findsOneWidget);
    expect(
        find.text('日期例外：2026-10-18 09:00–11:30、14:00–15:00'), findsOneWidget);
    expect(find.text('日期例外：2026-10-19 全天关闭'), findsOneWidget);
    expect(find.textContaining('不属于此规则的计划'), findsNothing);
    expect(find.text('时区：UTC'), findsNothing);
    expect(find.text('拟配置：允许'), findsOneWidget);
    _expectPreviewBoundary();
    expect(tester.takeException(), isNull);
  });

  testWidgets('an overnight window makes the following day explicit',
      (tester) async {
    final schedule = _schedule();
    (schedule['definition'] as Json)['weekly'] = [
      {'day': 'FRIDAY', 'start': '22:00', 'end': '01:00'},
    ];
    (schedule['definition'] as Json)['exceptions'] = <Json>[];
    await _mount(
        tester,
        _preview([
          _rule('overnight', 'TIME_WINDOW',
              effect: 'ALLOW', scheduleId: _scheduleId),
        ], schedules: [
          schedule
        ]));
    expect(find.text('每周时段：周五 22:00–次日 01:00'), findsOneWidget);
    _expectPreviewBoundary();
    expect(tester.takeException(), isNull);
  });

  const missingScheduleCases = [
    ('missing id', null, <Json>[]),
    ('unknown id', _scheduleId, <Json>[]),
    ('malformed id', 42, <Json>[]),
    ('malformed schedules', _scheduleId, 'not-a-list'),
  ];
  for (final scenario in missingScheduleCases) {
    testWidgets('${scenario.$1} does not invent a time plan', (tester) async {
      await _mount(
          tester,
          _preview([
            _rule('missing-plan', 'TIME_WINDOW',
                effect: 'ALLOW', scheduleId: scenario.$2),
          ], schedules: scenario.$3));
      expect(find.text('时间计划信息未提供'), findsOneWidget);
      expect(find.textContaining('每周时段：'), findsNothing);
      expect(find.textContaining('日期例外：'), findsNothing);
      expect(find.textContaining('时区：'), findsNothing);
      _expectPreviewBoundary();
      expect(tester.takeException(), isNull);
    });
  }

  const malformedDefinitions = <String, Json>{
    'missing definition': {},
    'wrong time zone type': {
      'timeZone': 42,
      'weekly': <Json>[],
      'exceptions': <Json>[],
    },
    'wrong weekly type': {
      'timeZone': 'Asia/Shanghai',
      'weekly': 'MONDAY',
      'exceptions': <Json>[],
    },
    'unknown weekday': {
      'timeZone': 'Asia/Shanghai',
      'weekly': [
        {'day': 'FUTURE_DAY', 'start': '18:00', 'end': '20:00'},
      ],
      'exceptions': <Json>[],
    },
    'invalid start': {
      'timeZone': 'Asia/Shanghai',
      'weekly': [
        {'day': 'MONDAY', 'start': '25:00', 'end': '20:00'},
      ],
      'exceptions': <Json>[],
    },
    'missing end': {
      'timeZone': 'Asia/Shanghai',
      'weekly': [
        {'day': 'MONDAY', 'start': '18:00', 'end': null},
      ],
      'exceptions': <Json>[],
    },
    'invalid date': {
      'timeZone': 'Asia/Shanghai',
      'weekly': <Json>[],
      'exceptions': [
        {'date': '2026-02-30', 'windows': <Json>[]},
      ],
    },
    'missing exception windows': {
      'timeZone': 'Asia/Shanghai',
      'weekly': <Json>[],
      'exceptions': [
        {'date': '2026-10-19', 'windows': null},
      ],
    },
  };
  for (final scenario in malformedDefinitions.entries) {
    testWidgets('${scenario.key} does not invent time plan parameters',
        (tester) async {
      final schedule = _schedule();
      schedule['definition'] = scenario.value;
      await _mount(
          tester,
          _preview([
            _rule('invalid-plan', 'TIME_WINDOW',
                effect: 'ALLOW', scheduleId: _scheduleId),
          ], schedules: [
            schedule
          ]));
      expect(find.text('时间计划：放学后的自由时间'), findsOneWidget);
      expect(find.text('时间计划信息不完整'), findsOneWidget);
      expect(find.textContaining('每周时段：'), findsNothing);
      expect(find.textContaining('日期例外：'), findsNothing);
      expect(find.textContaining('时区：'), findsNothing);
      _expectPreviewBoundary();
      expect(tester.takeException(), isNull);
    });
  }

  for (final clock in ['18:00:01', '18:00:00.1']) {
    testWidgets('clock $clock outside the HTTP schema stays incomplete',
        (tester) async {
      final schedule = _schedule();
      (schedule['definition'] as Json)['weekly'] = [
        {'day': 'MONDAY', 'start': clock, 'end': '20:00'},
      ];
      await _mount(
          tester,
          _preview([
            _rule('invalid-clock', 'TIME_WINDOW',
                effect: 'ALLOW', scheduleId: _scheduleId),
          ], schedules: [
            schedule
          ]));
      expect(find.text('时间计划：放学后的自由时间'), findsOneWidget);
      expect(find.text('时间计划信息不完整'), findsOneWidget);
      expect(find.textContaining('每周时段：'), findsNothing);
      expect(find.textContaining('日期例外：'), findsNothing);
      expect(find.textContaining('时区：'), findsNothing);
      _expectPreviewBoundary();
      expect(tester.takeException(), isNull);
    });
  }

  for (final zone in ['Invalid/Zone', ' Asia/Shanghai ']) {
    testWidgets('zone $zone is not presented as a complete time plan',
        (tester) async {
      final schedule = _schedule();
      (schedule['definition'] as Json)['timeZone'] = zone;
      await _mount(
          tester,
          _preview([
            _rule('invalid-zone', 'TIME_WINDOW',
                effect: 'ALLOW', scheduleId: _scheduleId),
          ], schedules: [
            schedule
          ]));
      expect(find.text('时间计划：放学后的自由时间'), findsOneWidget);
      expect(find.text('时间计划信息不完整'), findsOneWidget);
      expect(find.textContaining('每周时段：'), findsNothing);
      expect(find.textContaining('日期例外：'), findsNothing);
      expect(find.textContaining('时区：'), findsNothing);
      _expectPreviewBoundary();
      expect(tester.takeException(), isNull);
    });
  }

  final oversizedDefinitions = <String, Json>{
    'weekly entries above 56': {
      'timeZone': 'Asia/Shanghai',
      'weekly': List<Json>.generate(
        57,
        (_) => {'day': 'MONDAY', 'start': '18:00', 'end': '20:00'},
      ),
      'exceptions': <Json>[],
    },
    'date exceptions above 366': {
      'timeZone': 'Asia/Shanghai',
      'weekly': <Json>[],
      'exceptions': List<Json>.generate(
        367,
        (index) => {
          'date': DateTime.utc(2026)
              .add(Duration(days: index))
              .toIso8601String()
              .split('T')
              .first,
          'windows': <Json>[],
        },
      ),
    },
    'date windows above 8': {
      'timeZone': 'Asia/Shanghai',
      'weekly': <Json>[],
      'exceptions': [
        {
          'date': '2026-10-19',
          'windows': List<Json>.generate(
            9,
            (_) => {'start': '09:00', 'end': '11:30'},
          ),
        },
      ],
    },
    'time zone length above 100': {
      'timeZone': 'A' * 101,
      'weekly': <Json>[],
      'exceptions': <Json>[],
    },
  };
  for (final scenario in oversizedDefinitions.entries) {
    testWidgets('${scenario.key} stays incomplete at the definition limit',
        (tester) async {
      final schedule = _schedule();
      schedule['definition'] = scenario.value;
      await _mount(
          tester,
          _preview([
            _rule('oversized-plan', 'TIME_WINDOW',
                effect: 'ALLOW', scheduleId: _scheduleId),
          ], schedules: [
            schedule
          ]));
      expect(find.text('时间计划：放学后的自由时间'), findsOneWidget);
      expect(find.text('时间计划信息不完整'), findsOneWidget);
      expect(find.textContaining('每周时段：'), findsNothing);
      expect(find.textContaining('日期例外：'), findsNothing);
      expect(find.textContaining('时区：'), findsNothing);
      _expectPreviewBoundary();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('duplicate schedule ids do not choose either plan name',
      (tester) async {
    await _mount(
        tester,
        _preview([
          _rule('ambiguous-plan', 'TIME_WINDOW',
              effect: 'ALLOW', scheduleId: _scheduleId),
        ], schedules: [
          _schedule(name: '同标识的第一个计划'),
          _schedule(name: '同标识的第二个计划'),
        ]));
    expect(find.text('时间计划信息不完整'), findsOneWidget);
    expect(find.textContaining('同标识的第一个计划'), findsNothing);
    expect(find.textContaining('同标识的第二个计划'), findsNothing);
    expect(find.textContaining('每周时段：'), findsNothing);
    expect(find.textContaining('日期例外：'), findsNothing);
    expect(find.textContaining('时区：'), findsNothing);
    _expectPreviewBoundary();
    expect(tester.takeException(), isNull);
  });

  testWidgets('schedule name above 100 does not display a complete plan',
      (tester) async {
    final name = 'A' * 101;
    await _mount(
        tester,
        _preview([
          _rule('oversized-name', 'TIME_WINDOW',
              effect: 'ALLOW', scheduleId: _scheduleId),
        ], schedules: [
          _schedule(name: name)
        ]));
    expect(find.text('时间计划信息不完整'), findsOneWidget);
    expect(find.textContaining(name), findsNothing);
    expect(find.textContaining('每周时段：'), findsNothing);
    expect(find.textContaining('日期例外：'), findsNothing);
    expect(find.textContaining('时区：'), findsNothing);
    _expectPreviewBoundary();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'long permission and plan names fit 390 pixels at double text size',
      (tester) async {
    const deviceName = '教室平板 A · 很长的设备名称用于管理员大字号查看';
    const appName = '学习应用 · 很长的应用名称用于管理员查看规则配置';
    const scheduleName = '放学后的自由时间 · 很长的计划名称用于小屏幕查看每周时段和日期例外';
    const permission =
        'android.permission.FUTURE_PERMISSION_WITH_A_LONG_DISTINCT_ORIGINAL_CODE';
    final preview = _preview([
      _rule('long-permission', 'RUNTIME_PERMISSION', permission: permission),
      _rule('long-plan', 'TIME_WINDOW',
          effect: 'ALLOW', scheduleId: _scheduleId),
    ], schedules: [
      _schedule(name: scheduleName)
    ]);
    ((preview['snapshot'] as Json)['applications'] as List)
        .first['displayName'] = appName;
    await _mount(tester, preview, deviceName: deviceName, width: 390, scale: 2);

    expect(find.text(appName), findsWidgets);
    expect(find.text('权限代码：$permission'), findsOneWidget);
    expect(find.text('时间计划：$scheduleName'), findsOneWidget);
    expect(find.text('每周时段：周一 18:00–20:00'), findsOneWidget);
    expect(find.text('日期例外：2026-10-19 全天关闭'), findsOneWidget);
    for (final text in [
      '权限代码：$permission',
      '时间计划：$scheduleName',
      '日期例外：2026-10-19 全天关闭',
    ]) {
      final bounds = tester.getRect(find.text(text));
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(390));
    }
    await tester.ensureVisible(find.text('日期例外：2026-10-19 全天关闭'));
    await tester.pumpAndSettle();
    _expectPreviewBoundary();
    expect(tester.takeException(), isNull);
  });
}
