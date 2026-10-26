import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/editor_draft_text.dart';

void main() {
  test('class action recovery preserves its field complete reference and extra settings', () {
    final draft = {'targetClassId': 'target-class-full-reference', 'targetVersion': 7};
    final before = jsonEncode(draft);
    final text = classActionDraftText(draft,
        field: 'targetClassId', fieldLabel: '目标班级',
        options: const {'target-class-full-reference': '七年级二班'});
    expect(text, contains('目标班级：七年级二班（编号：target-class-full-reference）'));
    expect(text, contains('targetVersion'));
    expect(text, contains('7'));
    expect(jsonEncode(draft), before);
    expect(classActionDraftText(draft,
        field: 'targetClassId', fieldLabel: '目标班级', options: const {}),
        contains('编号：target-class-full-reference'));
    expect(classActionDraftText({'name': '原班级名称'},
        field: 'name', fieldLabel: '班级名称'), '班级名称：原班级名称');
  });

  test('member recovery keeps full scope references and never rewrites inputs', () {
    final draft = <String, dynamic>{
      'recipientEmail': 'teacher@fixture.invalid',
      'role': 'TEACHER',
      'classIds': ['class-a-full', 'missing-class-full'],
      'futureSetting': {'enabled': false},
    };
    final before = jsonEncode(draft);
    final text = memberDraftText(draft,
        classes: const {'class-a-full': '七年级一班'});
    for (final value in ['teacher@fixture.invalid', '教师',
        '七年级一班（编号：class-a-full）', '编号：missing-class-full',
        'futureSetting', 'false']) {
      expect(text, contains(value));
    }
    expect(jsonEncode(draft), before);
    expect(memberDraftText({'role': 'CHILD', 'subjectId': 'subject-full'},
        subjects: const {'subject-full': '小明'}),
        contains('小明（编号：subject-full）'));
    expect(memberDraftText({'role': 'TEACHER', 'classIds': null}),
        contains('未提供（null）'));
  });

  test('schedule review keeps every window exception and overnight boundary',
      () {
    final text = scheduleDraftText({
      'name': '完整计划名称（保留原文）',
      'definition': {
        'timeZone': 'America/New_York',
        'weekly': [
          {'day': 'FRIDAY', 'start': '22:00', 'end': '01:00'},
          {'day': 'MONDAY', 'start': '08:15', 'end': '09:45'},
          {'day': 'MONDAY', 'start': '08:15', 'end': '09:45'},
        ],
        'exceptions': [
          {'date': '2026-12-25', 'windows': <Json>[]},
          {
            'date': '2026-12-26',
            'windows': [
              {'start': '10:00', 'end': '11:30'},
              {'start': '23:00', 'end': '02:00'},
            ],
          },
        ],
      },
    });

    for (final value in [
      '完整计划名称（保留原文）',
      'America/New_York',
      '周五',
      '22:00 – 01:00（跨午夜，结束于次日）',
      '2026-12-25：全天关闭',
      '2026-12-26',
      '10:00 – 11:30',
      '23:00 – 02:00（跨午夜，结束于次日）',
    ]) {
      expect(text, contains(value));
    }
    expect('08:15 – 09:45'.allMatches(text).length, 2);
  });

  test('only explicit empty schedule lists receive closed or exception meaning',
      () {
    final empty = scheduleDraftText({
      'name': '仅例外计划',
      'definition': {
        'timeZone': 'UTC',
        'weekly': <Json>[],
        'exceptions': <Json>[],
      },
    });
    expect(empty, contains('未设置每周时段，仅按日期例外安排'));
    expect(empty, contains('日期例外：无'));

    final incomplete = scheduleDraftText({
      'name': '待核对',
      'definition': {
        'weekly': null,
        'exceptions': [
          {'date': '2026-12-25', 'windows': null},
        ],
      },
    });
    expect(incomplete, contains('时区：未提供'));
    expect(incomplete, contains('每周时段：未提供（null）'));
    expect(incomplete, contains('2026-12-25：未提供（null）'));
    expect(incomplete, isNot(contains('全天关闭')));
    expect(incomplete, isNot(contains('仅按日期例外')));
    expect(scheduleDraftText({'name': '缺少定义'}), contains('定义：未提供'));
  });

  test(
      'policy review keeps rule order all fields names and complete references',
      () {
    const app = '11111111-2222-3333-4444-555555555555';
    const schedule = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    final text = policyDraftText(
        {
          'name': '完整策略名称',
          'kind': 'TEMPLATE',
          'rules': [
            {
              'id': 'camera_rule',
              'kind': 'RUNTIME_PERMISSION',
              'effect': 'DENY',
              'required': true,
              'applicationId': app,
              'permission': 'android.permission.CAMERA',
            },
            {
              'id': 'time_rule',
              'kind': 'TIME_WINDOW',
              'effect': 'ALLOW',
              'required': false,
              'applicationId': app,
              'scheduleId': schedule,
            },
            {
              'id': 'quota_rule',
              'kind': 'DAILY_QUOTA',
              'effect': 'LIMIT',
              'required': false,
              'priority': 0,
              'seconds': 300,
            },
            {
              'id': 'domain_rule',
              'kind': 'DOMAIN_ACCESS',
              'effect': 'DENY',
              'required': true,
              'domain': '例子.中国',
            },
          ],
        },
        kind: 'POLICY',
        applications: const [
          {'id': app, 'displayName': '学习应用'},
        ],
        schedules: const [
          {'id': schedule, 'name': '晚间时段'},
        ]);

    for (final value in [
      '完整策略名称',
      '策略类型：模板',
      '类型：运行时权限',
      '效果：禁止',
      '支持要求：必须支持',
      '支持要求：可选执行',
      '学习应用（编号：$app）',
      '晚间时段（编号：$schedule）',
      '优先级：0',
      '时长：300 秒',
      '域名：例子.中国',
      '相机（android.permission.CAMERA）',
      'camera_rule',
      'time_rule',
      'quota_rule',
      'domain_rule',
    ]) {
      expect(text, contains(value));
    }
    expect(text.indexOf('camera_rule'), lessThan(text.indexOf('time_rule')));
    expect(text.indexOf('time_rule'), lessThan(text.indexOf('quota_rule')));
    expect(text.indexOf('quota_rule'), lessThan(text.indexOf('domain_rule')));
  });

  test('missing directory names and unknown settings remain recoverable', () {
    const app = '11111111-2222-3333-4444-555555555555';
    const schedule = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    final text = policyDraftText({
      'name': '原始设置',
      'rules': [
        {
          'id': 'vpn_rule',
          'kind': 'SPECIAL_ACCESS',
          'effect': 'GRANT',
          'required': true,
          'applicationId': app,
          'scheduleId': schedule,
          'permission': 'VPN',
          'futureRule': {
            'values': [false, null, '原值']
          },
        },
        {
          'id': 'custom_permission',
          'kind': 'RUNTIME_PERMISSION',
          'effect': 'DEFAULT',
          'required': false,
          'permission': 'android.permission.CUSTOM_PERMISSION',
        },
      ],
      'futurePolicy': {'enabled': false, 'limit': 0},
    }, kind: 'POLICY');
    for (final value in [
      '策略类型：策略',
      '编号：$app',
      '编号：$schedule',
      'VPN 连接（VPN）',
      'android.permission.CUSTOM_PERMISSION',
      '其他设置',
      '"futureRule"',
      '"values"',
      'false',
      'null',
      '原值',
      '"futurePolicy"',
      '"limit":0',
    ]) {
      expect(text, contains(value));
    }

    final scheduleText = scheduleDraftText({
      'name': '扩展计划',
      'definition': {
        'timeZone': 'UTC',
        'weekly': [
          {'day': 'MONDAY', 'start': '08:00', 'end': '09:00', 'weekTag': 7},
        ],
        'exceptions': [
          {
            'date': '2026-12-25',
            'windows': [
              {'start': '10:00', 'end': '11:00', 'windowTag': false},
            ],
            'exceptionTag': null,
          },
        ],
        'definitionTag': ['原值'],
      },
      'rootTag': 0,
    });
    for (final value in [
      '"weekTag":7',
      '"windowTag":false',
      '"exceptionTag":null',
      '"definitionTag":["原值"]',
      '"rootTag":0',
    ]) {
      expect(scheduleText, contains(value));
    }
  });

  test(
      'missing or null policy values never become an allow or optional default',
      () {
    final text = policyDraftText({
      'name': '不推断默认值',
      'kind': null,
      'rules': [
        {'id': 'incomplete', 'kind': null, 'effect': null, 'required': null},
      ],
    }, kind: 'POLICY');
    expect(text, contains('策略类型：未提供（null）'));
    expect(text, contains('效果：未提供（null）'));
    expect(text, contains('支持要求：未提供（null）'));
    expect(text, isNot(contains('允许')));
    expect(text, isNot(contains('可选')));
    expect(
        policyDraftText({'name': '缺少规则'}, kind: 'POLICY'), contains('规则：未提供'));
    expect(policyDraftText({'name': '空规则', 'rules': <Json>[]}, kind: 'POLICY'),
        contains('规则：无'));
  });

  test(
      'both formatters leave deeply immutable drafts and directories unchanged',
      () {
    const Json policy = {
      'name': '只读策略',
      'rules': [
        {
          'id': 'retained',
          'kind': 'APP_LAUNCH',
          'effect': 'DENY',
          'required': false,
          'applicationId': 'complete-application-id',
          'extra': ['保留', null],
        },
      ],
    };
    const Json schedule = {
      'name': '只读计划',
      'definition': {
        'timeZone': 'UTC',
        'weekly': [],
        'exceptions': [
          {'date': '2026-12-25', 'windows': []},
        ],
      },
    };
    const applications = <Json>[
      {'id': 'complete-application-id', 'displayName': '原应用'},
    ];
    const schedules = <Json>[
      {'id': 'complete-schedule-id', 'name': '原计划'},
    ];
    final before = jsonEncode([policy, schedule, applications, schedules]);

    final first = policyDraftText(policy,
        kind: 'POLICY', applications: applications, schedules: schedules);
    final firstSchedule = scheduleDraftText(schedule);
    expect(
        policyDraftText(policy,
            kind: 'POLICY', applications: applications, schedules: schedules),
        first);
    expect(scheduleDraftText(schedule), firstSchedule);
    expect(jsonEncode([policy, schedule, applications, schedules]), before);
  });
}
