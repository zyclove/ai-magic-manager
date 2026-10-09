import 'package:intl/intl.dart';

const labels = <String, String>{
  'FAMILY': '家庭',
  'ORGANIZATION': '教育机构',
  'OWNER': '所有者',
  'GUARDIAN': '监护人',
  'ORG_ADMIN': '机构管理员',
  'TEACHER': '教师',
  'CHILD': '儿童',
  'AUDITOR': '审计员',
  'UNDER_7': '7 岁以下',
  'AGE_7_12': '7–12 岁',
  'AGE_13_17': '13–17 岁',
  'ANDROID': 'Android',
  'ANDROID_TV': 'Android TV',
  'PRIMARY': '主空间',
  'WORK': '工作空间',
  'SECONDARY': '次要空间',
  'UNKNOWN': '未知',
  'BYOD': '个人设备',
  'WORK_PROFILE': '工作资料',
  'FULLY_MANAGED': '完全受管',
  'DEDICATED': '专用设备',
  'ACTIVE': '已注册',
  'REVOKED': '已撤销',
  'AWAITING_CONFIRMATION': '等待确认',
  'PENDING': '待处理',
  'EXPIRED': '已过期',
  'CANCELLED': '已取消',
  'ACCEPTED': '已接受',
  'DENIED': '已拒绝',
  'INVALIDATED': '已失效',
  'APPROVED_PENDING_DELIVERY': '已批准 · 等待交付',
  'NOT_ENFORCED': '尚未执行',
  'CONFIGURED_NOT_ENFORCED': '配置已保存 · 未执行',
  'POLICY': '策略',
  'TEMPLATE': '模板',
  'ALLOW': '允许',
  'DENY': '禁止',
  'PROTECT': '保护',
  'GRANT': '授予',
  'DEFAULT': '系统默认',
  'LIMIT': '限制',
  'REMIND': '提醒',
  'APP_LAUNCH': '应用启动',
  'APP_INSTALL': '应用安装',
  'APP_UNINSTALL': '应用卸载',
  'RUNTIME_PERMISSION': '运行时权限',
  'SPECIAL_ACCESS': '特殊访问权限',
  'DAILY_QUOTA': '每日额度',
  'TIME_WINDOW': '使用时段',
  'DOMAIN_ACCESS': '域名访问',
  'USAGE_REMINDER': '使用提醒',
  'TENANT_CREATED': '创建工作空间',
  'TENANT_UPDATED': '更新工作空间',
  'SUBJECT_CREATED': '创建儿童档案',
  'SUBJECT_UPDATED': '更新儿童档案',
  'SUBJECT_ARCHIVED': '归档儿童档案',
  'POLICY_DRAFT_CREATED': '创建策略草稿',
  'SCHEDULE_CREATED': '创建时间计划',
  'APPLICATION_DECLARED': '登记应用',
  'INVITATION_CREATED': '创建邀请',
  'MEMBER_JOINED': '成员加入',
  'MEMBER_REVOKED': '撤销成员',
  'ENROLLMENT_CREATED': '发起设备注册',
  'DECLARED_UNVERIFIED': '已登记 · 未验证',
  'AGENT_REPORTED_UNVERIFIED': '设备自报 · 未验证',
  'CONFIGURE_ONLY': '仅保存配置',
  'ENFORCE': '执行策略',
  'AGENT_UNENROLL': '退出本代理管理',
  'SYSTEM_UNMANAGE': '解除系统管理',
  'DEVICE_WIPE': '擦除设备',
  'MONDAY': '周一',
  'TUESDAY': '周二',
  'WEDNESDAY': '周三',
  'THURSDAY': '周四',
  'FRIDAY': '周五',
  'SATURDAY': '周六',
  'SUNDAY': '周日',
  'ONLINE': '近期在线',
  'STALE': '状态过期',
  'NEVER_SEEN': '尚未连接',
  'OBSERVED': '已观察',
  'RECEIVED': '已接收',
  'STORED': '已保存',
  'REJECTED': '已拒绝',
};
String label(dynamic value) =>
    value == null ? '—' : labels[value.toString()] ?? value.toString();
String dateLabel(dynamic value) {
  if (value == null) return '—';
  final d = value is num
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
      : DateTime.tryParse(value.toString());
  return d == null
      ? value.toString()
      : DateFormat('yyyy-MM-dd HH:mm').format(d.toLocal());
}

String shortId(dynamic id) {
  final s = id?.toString() ?? '—';
  return s.length > 12 ? '${s.substring(0, 8)}…' : s;
}
