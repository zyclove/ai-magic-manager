import 'package:audit_client/audit_client.dart';
import 'parent_api.dart';
export 'package:audit_client/audit_client.dart';

/// Read-only adapter. The session guard is checked after token refresh and after
/// every reply; cursor possession never replaces server authorization.
class ParentAuditRepository {
  final ParentApi api;
  final String tenant;
  final bool Function() current;
  ParentAuditRepository(
      {required this.api, required this.tenant, required this.current});

  Future<dynamic> _get(String suffix) async {
    if (!current()) throw const ParentApiException(409, 'SCOPE_DENIED');
    try {
      final result = await api.send(
          'GET', '/tenants/$tenant/audit-events$suffix',
          isCurrent: current);
      if (!current()) throw const ParentApiException(409, 'SCOPE_DENIED');
      return result;
    } catch (_) {
      if (!current()) throw const ParentApiException(409, 'SCOPE_DENIED');
      rethrow;
    }
  }

  Future<AuditPage> load(AuditQuery query, {String? cursor}) async {
    try {
      query.validate();
      if (cursor != null && (cursor.isEmpty || cursor.length > 256)) {
        throw const AuditProtocolException();
      }
    } on AuditProtocolException {
      throw const ParentApiException(400, 'INVALID_AUDIT_QUERY');
    }
    final params = {...query.parameters, if (cursor != null) 'cursor': cursor};
    final raw = await _get('/search?${Uri(queryParameters: params).query}');
    try {
      return AuditPage.parse(raw, query, cursor: cursor);
    } on AuditProtocolException {
      throw const ParentApiException(502, 'INVALID_AUDIT_RESPONSE');
    }
  }

  Future<AuditEvent> detail(String id) async {
    if (!auditUuid.hasMatch(id)) {
      throw const ParentApiException(400, 'INVALID_AUDIT_ID');
    }
    final raw = await _get('/$id');
    try {
      final item = AuditEvent.parse(raw);
      if (item.id != id) throw const AuditProtocolException();
      return item;
    } on AuditProtocolException {
      throw const ParentApiException(502, 'INVALID_AUDIT_RESPONSE');
    }
  }
}

/// Common user-facing actions. Unknown server actions remain visible verbatim.
const auditActionNames = <String, String>{
  'SUBJECT_CREATED': '添加儿童或学生',
  'SUBJECT_UPDATED': '更新儿童或学生档案',
  'SUBJECT_ARCHIVED': '归档儿童或学生',
  'TENANT_CREATED': '创建工作空间',
  'TENANT_UPDATED': '更新工作空间',
  'POLICY_DRAFT_CREATED': '创建策略草稿',
  'POLICY_DRAFT_UPDATED': '更新策略草稿',
  'POLICY_ROLLBACK_DRAFT_CREATED': '从历史版本创建草稿',
  'POLICY_PREVIEW_CREATED': '预览策略支持情况',
  'POLICY_CONFIGURATION_RECORDED': '保存策略配置版本',
  'SCHEDULE_CREATED': '创建时间计划',
  'APPLICATION_DECLARED': '登记应用',
  'INVITATION_CREATED': '创建成员邀请',
  'INVITATION_REVOKED': '取消成员邀请',
  'MEMBER_JOINED': '成员加入',
  'MEMBER_REVOKED': '撤销成员',
  'MEMBER_INVITED': '邀请成员',
  'MEMBERSHIP_REVOKED': '撤销成员访问',
  'MEMBERSHIP_ACCESS_CHANGED': '调整成员权限',
  'CONTRACT_CUSTOMER_ACCEPTED': '机构确认合同',
  'ENROLLMENT_CREATED': '发起设备配对',
  'ENROLLMENT_CONFIRMED': '确认设备配对',
  'OWNERSHIP_TRANSFER_PROPOSED': '发起所有者交接',
  'OWNERSHIP_TRANSFER_ACCEPTED': '完成所有者交接',
  'OWNERSHIP_TRANSFER_CANCELLED': '撤销所有者交接',
  'OWNERSHIP_TRANSFER_DECLINED': '拒绝所有者交接',
};

String auditActionName(String action) => auditActionNames[action] ?? action;

String auditError(Object error) => error is ParentApiException
    ? switch (error.code) {
        'INVALID_AUDIT_QUERY' => '筛选条件不完整，请核对时间和编号。',
        'INVALID_AUDIT_RESPONSE' => '操作记录未通过核对，请刷新后重试。',
        'AUDIT_EVENT_UNAVAILABLE' => '这条记录当前已不可查看，请返回列表重新查询。',
        'INVALID_CURSOR' => '分页条件已失效，请刷新后重新查询。',
        _ => error.toString(),
      }
    : '暂时无法读取操作记录，请稍后重试。';
