import 'package:flutter/material.dart';
import 'design.dart';

const destinations = [
  ('overview', '工作台', Icons.space_dashboard_outlined),
  ('subjects', '儿童档案', Icons.person_outline),
  ('classes', '班级与名册', Icons.school_outlined),
  ('device-groups', '机构设备组', Icons.grid_view_outlined),
  ('managed-android', '受管 Android', Icons.phonelink_lock_outlined),
  ('devices', '设备管理', Icons.devices_outlined),
  ('applications', '应用目录', Icons.apps_outlined),
  ('schedules', '时间计划', Icons.schedule_outlined),
  ('quota', '共享额度', Icons.timelapse_outlined),
  ('policies', '策略中心', Icons.shield_outlined),
  ('approvals', '访问审批', Icons.task_alt_outlined),
  ('notifications', '通知中心', Icons.notifications_none_outlined),
  ('help-requests', '儿童求助', Icons.volunteer_activism_outlined),
  ('reports', '使用报表', Icons.bar_chart_outlined),
  ('commercial', '商业账户', Icons.workspace_premium_outlined),
  ('catalog', '平台产品目录', Icons.inventory_2_outlined),
  ('contracts', '平台机构合同', Icons.description_outlined),
  ('family-finance', '家庭售后与对账', Icons.payments_outlined),
  ('identity-providers', '短信与微信', Icons.verified_user_outlined),
  ('managed-android-review', '企业绑定审核', Icons.fact_check_outlined),
  ('institution-contracts', '机构合同', Icons.fact_check_outlined),
  ('members', '成员与邀请', Icons.group_outlined),
  ('ownership', '所有者交接', Icons.swap_horiz_outlined),
  ('audit', '审计日志', Icons.receipt_long_outlined),
  ('exports', '导出任务', Icons.file_download_outlined),
  ('support', '支持协作', Icons.support_agent_outlined),
  ('settings', '设置', Icons.settings_outlined),
];

const navigationGroups = [
  (
    'daily',
    '日常管理',
    [
      'overview',
      'subjects',
      'devices',
      'approvals',
      'help-requests',
      'notifications'
    ]
  ),
  (
    'rules',
    '规则与报表',
    ['policies', 'schedules', 'quota', 'applications', 'reports']
  ),
  (
    'workspace',
    '工作空间',
    [
      'classes',
      'device-groups',
      'managed-android',
      'members',
      'commercial',
      'institution-contracts',
      'ownership',
      'audit',
      'exports',
      'support',
      'settings'
    ]
  ),
  (
    'platform',
    '平台管理',
    [
      'catalog',
      'contracts',
      'managed-android-review',
      'family-finance',
      'identity-providers'
    ]
  ),
];

const _navigationSearchTerms = <String, List<String>>{
  'overview': ['首页', '总览', '仪表盘', '待办'],
  'subjects': ['儿童', '孩子', '学生', '档案'],
  'classes': ['班级', '名册', '花名册', '分班'],
  'device-groups': ['设备分组', '分组', '批量管理'],
  'managed-android': ['安卓', '受管设备', '企业接入', '设备接入', '接入'],
  'devices': ['手机', '平板', '终端', '配对', '绑定设备'],
  'applications': ['应用', 'app', '软件', '白名单'],
  'schedules': ['时间', '时段', '作息', '定时'],
  'quota': ['时长', '配额', '限额', '限时', '共享时长'],
  'policies': ['规则', '管控规则', '限制', '应用限制', '发布规则'],
  'approvals': ['申请', '审批', '访问申请', '授权审批'],
  'notifications': ['消息', '提醒', '通知', '告警'],
  'help-requests': ['求助', '帮助', '孩子求助', '学生求助'],
  'reports': ['统计', '使用统计', '使用时长', '报告', '用量'],
  'commercial': ['套餐', '订阅', '续费', '会员', '计费', '账单'],
  'catalog': ['产品', '商品', '上架', '下架', '定价', '套餐配置'],
  'contracts': ['平台合同', '机构签约', '签约', '合约'],
  'family-finance': ['退款', '售后', '对账', '退费', '结算', '家庭订单', '家庭账单'],
  'identity-providers': [
    '短信',
    '微信',
    '验证码',
    '身份接入',
    '短信接入',
    '微信接入',
    '服务商',
    '接入'
  ],
  'managed-android-review': ['绑定审核', '企业审核', '企业绑定', '接入审核'],
  'institution-contracts': ['机构合同', '机构签约', '签约', '合约'],
  'members': ['成员', '邀请', '加入', '老师', '家长'],
  'ownership': ['交接', '转让', '移交', '所有者', '负责人'],
  'audit': ['日志', '操作记录', '审计', '追溯'],
  'exports': ['导出', '下载', '数据导出'],
  'support': ['支持', '客服', '协作', '工单', '帮助', '售后支持'],
  'settings': ['设置', '配置', '偏好', '工作空间设置'],
};

String navigationLabel(String section, {bool organization = false}) {
  if (organization && section == 'subjects') return '学生档案';
  if (organization && section == 'help-requests') return '学生求助';
  return destinations.where((d) => d.$1 == section).firstOrNull?.$2 ?? '工作台';
}

/// Shared by the desktop sidebar and mobile drawer; access precedes search.
class ConsoleNavigation extends StatefulWidget {
  final String section;
  final bool Function(String) canOpen;
  final ValueChanged<String> onSelect;
  final bool organization;
  const ConsoleNavigation(
      {super.key,
      required this.section,
      required this.canOpen,
      required this.onSelect,
      this.organization = false});
  @override
  State<ConsoleNavigation> createState() => _ConsoleNavigationState();
}

class _ConsoleNavigationState extends State<ConsoleNavigation> {
  final search = TextEditingController();
  final searchFocus = FocusNode(debugLabel: 'console-function-search');
  final expanded = <String, bool>{'daily': true, 'rules': true};
  String query = '';
  Set<String> _allowedIds = {};
  String? _lastSubmittedQuery;

  @override
  void initState() {
    super.initState();
    _allowedIds = _availableDestinations().map((d) => d.$1).toSet();
    _revealCurrent();
  }

  @override
  void didUpdateWidget(ConsoleNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextAllowed = _availableDestinations().map((d) => d.$1).toSet();
    final accessChanged = nextAllowed.length != _allowedIds.length ||
        !nextAllowed.containsAll(_allowedIds);
    _allowedIds = nextAllowed;
    if (oldWidget.section != widget.section ||
        oldWidget.organization != widget.organization ||
        accessChanged) {
      search.clear();
      query = '';
      _lastSubmittedQuery = null;
      _revealCurrent();
    }
  }

  void _revealCurrent() {
    for (final group in navigationGroups) {
      if (group.$3.contains(widget.section)) expanded[group.$1] = true;
    }
  }

  @override
  void dispose() {
    searchFocus.dispose();
    search.dispose();
    super.dispose();
  }

  String title((String, String, IconData) destination) =>
      navigationLabel(destination.$1, organization: widget.organization);

  List<(String, String, IconData)> _availableDestinations() =>
      destinations.where((d) => widget.canOpen(d.$1)).toList();

  String _normalizeQuery(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  bool _matches((String, String, IconData) destination, String value) {
    if (value.isEmpty) return true;
    final text = [
      title(destination),
      destination.$2,
      ...?_navigationSearchTerms[destination.$1]
    ].join(' ').toLowerCase();
    return value.split(' ').every((word) => text.contains(word));
  }

  void _clearSearch() {
    if (!mounted) return;
    search.clear();
    setState(() {
      query = '';
      _lastSubmittedQuery = null;
      _revealCurrent();
    });
    searchFocus.requestFocus();
  }

  void _selectDestination(String id) {
    // A visible tile may outlive its permission until the next rebuild.
    if (mounted && widget.canOpen(id)) widget.onSelect(id);
  }

  void _submitSearch(String submitted) {
    if (!mounted) return;
    final value = _normalizeQuery(search.text);
    final composing = search.value.composing;
    if (value.isEmpty ||
        _normalizeQuery(submitted) != value ||
        value == _lastSubmittedQuery ||
        (composing.isValid && !composing.isCollapsed)) {
      return;
    }
    final matches = _availableDestinations()
        .where((d) => _matches(d, value))
        .toList();
    if (matches.length != 1) return;
    // Repeated IME/Enter submissions for the same query open only once.
    _lastSubmittedQuery = value;
    _selectDestination(matches.single.$1);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _availableDestinations()
        .where((d) => _matches(d, query))
        .toList();
    return Column(children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: TextField(
              controller: search,
              focusNode: searchFocus,
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() {
                    query = _normalizeQuery(value);
                    _lastSubmittedQuery = null;
                  }),
              onEditingComplete: () => searchFocus.requestFocus(),
              onSubmitted: _submitSearch,
              decoration: InputDecoration(
                  labelText: '查找功能',
                  hintText: '输入名称或常用关键词',
                  helperText: query.isEmpty
                      ? null
                      : filtered.length == 1
                          ? '找到 1 项，按 Enter 打开'
                          : filtered.isEmpty
                              ? '换个关键词，或清除搜索'
                              : '找到 ${filtered.length} 项，请选择一项',
                  helperMaxLines: 2,
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 19),
                  suffixIcon: search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除功能搜索',
                          onPressed: _clearSearch,
                          icon: const Icon(Icons.close, size: 17))))),
      Expanded(
          child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
            if (filtered.isEmpty)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24, horizontal: 8),
                  child: Text('没有匹配的可用功能，试试其他关键词。',
                      style: TextStyle(color: muted, fontSize: 13))),
            for (final group in navigationGroups)
              if (filtered.any((d) => group.$3.contains(d.$1))) ...[
                Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: Semantics(
                        button: true,
                        expanded:
                            query.isNotEmpty || expanded[group.$1] == true,
                        child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: query.isNotEmpty
                                ? null
                                : () => setState(() => expanded[group.$1] =
                                    !(expanded[group.$1] ?? false)),
                            child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 12),
                                child: Row(children: [
                                  Expanded(
                                      child: Text(group.$2,
                                          style: const TextStyle(
                                              color: muted,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600))),
                                  Icon(
                                      query.isNotEmpty ||
                                              expanded[group.$1] == true
                                          ? Icons.expand_less
                                          : Icons.expand_more,
                                      size: 18,
                                      color: muted)
                                ]))))),
                if (query.isNotEmpty || expanded[group.$1] == true)
                  for (final id in group.$3)
                    for (final d in filtered.where((d) => d.$1 == id))
                      Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: ListTile(
                              minLeadingWidth: 22,
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                              selected: widget.section == id,
                              selectedTileColor: const Color(0xFFEAF2FC),
                              selectedColor: navy,
                              leading: Icon(d.$3, size: 21),
                              title: Text(title(d),
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: widget.section == id
                                          ? FontWeight.w600
                                          : FontWeight.w400)),
                              onTap: () => _selectDestination(id))),
              ],
          ])),
    ]);
  }
}
