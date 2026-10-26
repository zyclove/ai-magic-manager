const deviceConnectionCheckPath = '/devices?connection=NEEDS_CHECK';

/// Client presentation metadata only; API authorization stays on the server.
enum ConsoleModuleGroup {
  daily('daily', '日常管理', initiallyExpanded: true),
  rules('rules', '规则与报表', initiallyExpanded: true),
  workspace('workspace', '工作空间'),
  platform('platform', '平台管理');

  final String id;
  final String label;
  final bool initiallyExpanded;

  const ConsoleModuleGroup(this.id, this.label,
      {this.initiallyExpanded = false});
}

class ConsoleModule {
  final String id;
  final String label;
  final ConsoleModuleGroup group;
  final String? organizationLabel;
  final List<String> searchTerms;

  const ConsoleModule(this.id, this.label, this.group,
      {this.organizationLabel, this.searchTerms = const []});

  String labelFor({bool organization = false}) =>
      organization ? organizationLabel ?? label : label;

  String get path => id == 'overview' ? '/' : '/$id';
}

/// Order within a group is its display order on both desktop and mobile.
/// This fixed catalogue does not enable features, grant rights, or load plugins.
const consoleModules = <ConsoleModule>[
  ConsoleModule('overview', '工作台', ConsoleModuleGroup.daily,
      searchTerms: ['首页', '总览', '仪表盘', '待办']),
  ConsoleModule('subjects', '儿童档案', ConsoleModuleGroup.daily,
      organizationLabel: '学生档案', searchTerms: ['儿童', '孩子', '学生', '档案']),
  ConsoleModule('devices', '设备管理', ConsoleModuleGroup.daily,
      searchTerms: ['手机', '平板', '终端', '配对', '绑定设备']),
  ConsoleModule('approvals', '访问审批', ConsoleModuleGroup.daily,
      searchTerms: ['申请', '审批', '访问申请', '授权审批']),
  ConsoleModule('help-requests', '儿童求助', ConsoleModuleGroup.daily,
      organizationLabel: '学生求助', searchTerms: ['求助', '帮助', '孩子求助', '学生求助']),
  ConsoleModule('notifications', '通知中心', ConsoleModuleGroup.daily,
      searchTerms: ['消息', '提醒', '通知', '告警']),
  ConsoleModule('policies', '策略中心', ConsoleModuleGroup.rules,
      searchTerms: ['规则', '管控规则', '限制', '应用限制', '发布规则']),
  ConsoleModule('schedules', '时间计划', ConsoleModuleGroup.rules,
      searchTerms: ['时间', '时段', '作息', '定时']),
  ConsoleModule('quota', '共享额度', ConsoleModuleGroup.rules,
      searchTerms: ['时长', '配额', '限额', '限时', '共享时长']),
  ConsoleModule('applications', '应用目录', ConsoleModuleGroup.rules,
      searchTerms: ['应用', 'app', '软件', '白名单']),
  ConsoleModule('reports', '使用报表', ConsoleModuleGroup.rules,
      searchTerms: ['统计', '使用统计', '使用时长', '报告', '用量']),
  ConsoleModule('classes', '班级与名册', ConsoleModuleGroup.workspace,
      searchTerms: ['班级', '名册', '花名册', '分班']),
  ConsoleModule('device-groups', '机构设备组', ConsoleModuleGroup.workspace,
      searchTerms: ['设备分组', '分组', '批量管理']),
  ConsoleModule('managed-android', '受管 Android', ConsoleModuleGroup.workspace,
      searchTerms: ['安卓', '受管设备', '企业接入', '设备接入', '接入']),
  ConsoleModule('members', '成员与邀请', ConsoleModuleGroup.workspace,
      searchTerms: ['成员', '邀请', '加入', '老师', '家长']),
  ConsoleModule('commercial', '商业账户', ConsoleModuleGroup.workspace,
      searchTerms: ['套餐', '订阅', '续费', '会员', '计费', '账单']),
  ConsoleModule('institution-contracts', '机构合同', ConsoleModuleGroup.workspace,
      searchTerms: ['机构合同', '机构签约', '签约', '合约']),
  ConsoleModule('ownership', '所有者交接', ConsoleModuleGroup.workspace,
      searchTerms: ['交接', '转让', '移交', '所有者', '负责人']),
  ConsoleModule('audit', '审计日志', ConsoleModuleGroup.workspace,
      searchTerms: ['日志', '操作记录', '审计', '追溯']),
  ConsoleModule('exports', '导出任务', ConsoleModuleGroup.workspace,
      searchTerms: ['导出', '下载', '数据导出']),
  ConsoleModule('support', '支持协作', ConsoleModuleGroup.workspace,
      searchTerms: ['支持', '客服', '协作', '工单', '帮助', '售后支持']),
  ConsoleModule('settings', '设置', ConsoleModuleGroup.workspace,
      searchTerms: ['设置', '配置', '偏好', '工作空间设置']),
  ConsoleModule('catalog', '平台产品目录', ConsoleModuleGroup.platform,
      searchTerms: ['产品', '商品', '上架', '下架', '定价', '套餐配置']),
  ConsoleModule('contracts', '平台机构合同', ConsoleModuleGroup.platform,
      searchTerms: ['平台合同', '机构签约', '签约', '合约']),
  ConsoleModule('managed-android-review', '企业绑定审核', ConsoleModuleGroup.platform,
      searchTerms: ['绑定审核', '企业审核', '企业绑定', '接入审核']),
  ConsoleModule('family-finance', '家庭售后与对账', ConsoleModuleGroup.platform,
      searchTerms: ['退款', '售后', '对账', '退费', '结算', '家庭订单', '家庭账单']),
  ConsoleModule('identity-providers', '短信与微信', ConsoleModuleGroup.platform,
      searchTerms: ['短信', '微信', '验证码', '身份接入', '短信接入', '微信接入', '服务商', '接入']),
];

final _modulesById = Map<String, ConsoleModule>.unmodifiable({
  for (final module in consoleModules) module.id: module,
});

ConsoleModule? consoleModule(String id) => _modulesById[id];

// Exact strings only: no URL decoding, normalization, or unlisted queries/fragments.
final _returnPaths = Set<String>.unmodifiable({
  '/',
  deviceConnectionCheckPath,
  for (final module in consoleModules) '/${module.id}',
});

String consoleReturnPath(String? value) =>
    _returnPaths.contains(value) ? value! : '/';
