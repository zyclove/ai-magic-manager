import 'console_routes.dart';
import 'overview_summary.dart';

enum OverviewAttentionKind { help, requests, connection }

/// A display suggestion from already-authorized counts, never an access grant.
class OverviewAttention {
  final OverviewAttentionKind kind;
  final String title, description, label, section;
  final bool urgent;

  const OverviewAttention._(this.kind, this.title, this.description, this.label,
      this.section, {this.urgent = false});

  String get location => switch (kind) {
    OverviewAttentionKind.connection => deviceConnectionCheckPath,
    OverviewAttentionKind.requests => accessRequestsPendingPath,
    OverviewAttentionKind.help => '/help-requests',
  };

  static OverviewAttention? pick(OverviewSummary value,
      {required String role,
      required bool organization,
      required bool Function(String) canOpen}) {
    const managers = {'OWNER', 'GUARDIAN', 'ORG_ADMIN'};
    if (!const {'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'TEACHER', 'CHILD', 'AUDITOR'}
        .contains(role)) return null;
    final manager = managers.contains(role);
    final help = value.openHelpRequestCount;
    if ((manager || role == 'TEACHER') &&
        help != null &&
        help > 0 &&
        canOpen('help-requests')) {
      return role == 'TEACHER'
          ? OverviewAttention._(
              OverviewAttentionKind.help,
              '查看授权学生求助',
              '有 $help 条授权学生求助尚未确认看到。请按机构值班流程联系并线下跟进。',
              '查看求助',
              'help-requests',
              urgent: true)
          : OverviewAttention._(
              OverviewAttentionKind.help,
              '先查看${organization ? '学生' : '儿童'}求助',
              '有 $help 条求助尚未确认看到。请核对内容，并实际联系与跟进。',
              '查看求助',
              'help-requests',
              urgent: true);
    }
    final pending = value.pendingRequestCount;
    if (pending > 0 && canOpen('approvals')) {
      if (manager) {
        return OverviewAttention._(
            OverviewAttentionKind.requests,
            '处理待审批的访问申请',
            '有 $pending 条申请等待处理。先查看申请理由，再决定是否允许临时访问。',
            '查看待处理审批',
            'approvals');
      }
      if (role == 'AUDITOR') {
        return OverviewAttention._(
            OverviewAttentionKind.requests,
            '只读查看待处理申请',
            '有 $pending 条待处理申请。可只读核对申请与处理状态。',
            '只读查看申请',
            'approvals');
      }
      return OverviewAttention._(
          OverviewAttentionKind.requests,
          '跟进我的访问申请',
          '有 $pending 条本人提交的申请等待处理。查看当前进度，了解管理员决定。',
          '查看我的申请',
          'approvals');
    }
    final connection = value.connectionCheckCount;
    if (role != 'AUDITOR' &&
        connection != null &&
        connection > 0 &&
        canOpen('devices')) {
      return OverviewAttention._(
          OverviewAttentionKind.connection,
          '检查设备连接',
          '$connection 台设备尚无近期心跳。请检查连接；心跳缺失不能证明设备规则已失效。',
          '查看设备连接',
          'devices');
    }
    return null;
  }
}
