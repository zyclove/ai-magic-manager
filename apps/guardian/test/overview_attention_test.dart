import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/overview_attention.dart';
import 'package:guardian/core/overview_summary.dart';

OverviewSummary _summary({int? help, int requests = 0, int? connection}) =>
    OverviewSummary.parse({
      'subjectCount': null,
      'activeDeviceCount': null,
      'connectionCheckCount': connection,
      'policyDraftCount': null,
      'pendingRequestCount': requests,
      'openHelpRequestCount': help,
      'recentActivity': [],
    });

void main() {
  test('management attention preserves copy and chooses the first available task',
      () {
    final value = _summary(help: 2, requests: 3, connection: 4);
    for (final role in ['OWNER', 'GUARDIAN', 'ORG_ADMIN']) {
      for (final organization in [false, true]) {
        final subject = organization ? '学生' : '儿童';
        final help = OverviewAttention.pick(value, role: role,
            organization: organization, canOpen: (_) => true)!;
        expect(help.kind, OverviewAttentionKind.help);
        expect(help.title, '先查看$subject求助');
        expect(help.description,
            '有 2 条求助尚未确认看到。请核对内容，并实际联系与跟进。');
        expect(help.label, '查看求助');
        expect(help.section, 'help-requests');
        expect(help.urgent, isTrue);
        final requests = OverviewAttention.pick(value, role: role,
            organization: organization,
            canOpen: (section) => section != 'help-requests')!;
        expect(requests.kind, OverviewAttentionKind.requests);
        expect(requests.title, '处理待审批的访问申请');
        expect(requests.description,
            '有 3 条申请等待处理。先查看申请理由，再决定是否允许临时访问。');
        expect(requests.label, '查看待处理审批');
        expect(requests.section, 'approvals');
        expect(requests.location, '/approvals?state=PENDING');
        expect(requests.urgent, isFalse);
        final connection = OverviewAttention.pick(value, role: role,
            organization: organization,
            canOpen: (section) => section == 'devices')!;
        expect(connection.kind, OverviewAttentionKind.connection);
        expect(connection.title, '检查设备连接');
        expect(connection.description,
            '4 台设备尚无近期心跳。请检查连接；心跳缺失不能证明设备规则已失效。');
        expect(connection.label, '查看设备连接');
        expect(connection.section, 'devices');
        expect(connection.location, '/devices?connection=NEEDS_CHECK');
        expect(connection.urgent, isFalse);
      }
    }
  });

  test('scoped roles respect their tasks and never infer unavailable counts', () {
    final value = _summary(help: 2, requests: 3, connection: 4);
    final teacher = OverviewAttention.pick(value, role: 'TEACHER',
        organization: true, canOpen: (_) => true)!;
    expect(teacher.kind, OverviewAttentionKind.help);
    expect(teacher.title, contains('授权学生求助'));
    expect(teacher.description, contains('线下跟进'));
    expect(teacher.urgent, isTrue);
    for (final role in ['TEACHER', 'CHILD']) {
      final requests = OverviewAttention.pick(value, role: role,
          organization: true,
          canOpen: (section) => section != 'help-requests')!;
      expect(requests.kind, OverviewAttentionKind.requests);
      expect(requests.title, '跟进我的访问申请');
      expect(requests.label, '查看我的申请');
      expect(requests.section, 'approvals');
      expect(requests.location, '/approvals?state=PENDING');
      expect(requests.description, isNot(contains('决定是否允许')));
      final connection = OverviewAttention.pick(value, role: role,
          organization: true, canOpen: (section) => section == 'devices')!;
      expect(connection.kind, OverviewAttentionKind.connection);
    }
    final child = OverviewAttention.pick(value, role: 'CHILD',
        organization: false, canOpen: (_) => true)!;
    expect(child.kind, OverviewAttentionKind.requests,
        reason: 'A positive help count cannot grant a child adult follow-up.');
    final auditLookups = <String>[];
    final audit = OverviewAttention.pick(value, role: 'AUDITOR',
        organization: true, canOpen: (section) {
      auditLookups.add(section);
      return true;
    })!;
    expect(audit.kind, OverviewAttentionKind.requests);
    expect(audit.description, contains('只读'));
    expect(audit.label, '只读查看申请');
    expect(audit.location, '/approvals?state=PENDING');
    expect(auditLookups, ['approvals']);
    expect(OverviewAttention.pick(_summary(help: 2, connection: 4),
        role: 'AUDITOR', organization: true, canOpen: (_) => true), isNull);
    expect(OverviewAttention.pick(value, role: 'UNKNOWN', organization: true,
        canOpen: (_) => throw StateError('Unknown roles have no task target.')),
        isNull);
    for (final role in ['OWNER', 'GUARDIAN', 'ORG_ADMIN', 'TEACHER', 'CHILD', 'AUDITOR']) {
      expect(OverviewAttention.pick(_summary(), role: role,
          organization: true, canOpen: (_) => true), isNull);
      expect(OverviewAttention.pick(_summary(help: 0, connection: 0), role: role,
          organization: false, canOpen: (_) => true), isNull);
      expect(OverviewAttention.pick(value, role: role,
          organization: true, canOpen: (_) => false), isNull);
    }
  });
}
