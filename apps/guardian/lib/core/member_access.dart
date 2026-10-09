import 'api.dart';
import 'labels.dart';

List<String> memberRoles(String kind, String operatorRole,
    {String? currentRole}) {
  if (!['OWNER', 'ORG_ADMIN'].contains(operatorRole) ||
      currentRole == 'OWNER' ||
      (currentRole == 'ORG_ADMIN' && operatorRole != 'OWNER')) return const [];
  final available = kind == 'FAMILY'
      ? <String>['GUARDIAN', 'AUDITOR', 'CHILD']
      : <String>[
          if (operatorRole == 'OWNER') 'ORG_ADMIN',
          'TEACHER',
          'AUDITOR',
          'CHILD'
        ];
  if (currentRole == null) return available;
  return available
      .where((r) => (r == 'CHILD') == (currentRole == 'CHILD'))
      .toList();
}

bool memberNeedsSubject(String role) => role == 'CHILD' || role == 'TEACHER';
String memberName(Json row) {
  final name = row['displayName'] as String?;
  if (name != null && name.trim().isNotEmpty) return name;
  return shortId(row['actorId']);
}

String memberScope(Json row) {
  final classes = row['classIds'] as List? ?? const [];
  if (classes.isNotEmpty) return '${classes.length} 个班级';
  if (row['subjectId'] != null) {
    return '${row['subjectName'] ?? shortId(row['subjectId'])}${row['subjectArchived'] == true ? '（已归档）' : ''}';
  }
  return row['role'] == 'TEACHER' ? '尚未分配范围' : '工作空间范围';
}

const memberConsequences =
    '保存后立即按新权限访问。该成员发出的未使用邀请、待确认设备配对、临时访问窗口及相关预览将失效。已生效设备和已发布策略保留。';
String memberRoleDescription(String role) => switch (role) {
      'GUARDIAN' => '管理家庭档案、设备和规则；成员管理由所有者负责。',
      'ORG_ADMIN' => '管理机构档案、设备、规则及普通成员；不能交接所有权。',
      'TEACHER' => '查看获授班级内或指定档案的学生和设备状态，可提交与取消本人的有限访问申请。不能审批、修改学生、设备或组织策略。',
      'AUDITOR' => '查看工作空间内允许审计的信息，无权修改配置或成员。',
      'CHILD' => '仅访问所关联的儿童档案范围；不授予成人管理资格。',
      _ => '请核对角色和访问范围。',
    };
