import 'package:flutter/material.dart';
import '../core/family.dart';
import '../core/parent_session.dart';
import 'enrollment_flow.dart';
import 'family_rules_page.dart';
import 'family_assistant.dart';
import 'family_device_access_page.dart';
import 'usage_report_center.dart';

const familyInk = Color(0xFF17324B);
const familyMuted = Color(0xFF536B7A);

ThemeData familyTheme() => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2F627E), brightness: Brightness.light),
      scaffoldBackgroundColor: const Color(0xFFF4F7F8),
      textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 16, height: 1.5),
          bodyLarge: TextStyle(fontSize: 16, height: 1.5),
          bodySmall: TextStyle(fontSize: 14, height: 1.4)),
      appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF4F7F8),
          foregroundColor: familyInk,
          elevation: 0),
      cardTheme: const CardTheme(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)))),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 14))),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 14))),
      inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)))),
    );

class FamilyPanel extends StatelessWidget {
  final Widget child;
  const FamilyPanel({super.key, required this.child});
  @override
  Widget build(BuildContext context) =>
      Card(child: Padding(padding: const EdgeInsets.all(20), child: child));
}

class FamilyHero extends StatelessWidget {
  final String title, subtitle;
  const FamilyHero({super.key, required this.title, required this.subtitle});
  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minHeight: 160),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
            color: const Color(0xFF1C4F72),
            borderRadius: BorderRadius.circular(20),
            image: const DecorationImage(
                image: AssetImage('assets/family/horizon.png'),
                colorFilter:
                    ColorFilter.mode(Color(0xB8002038), BlendMode.srcATop),
                fit: BoxFit.cover)),
        child: LayoutBuilder(
            builder: (context, constraints) => Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                    width: constraints.maxWidth * .76,
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(title,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      height: 1.25)),
                          const SizedBox(height: 10),
                          Text(subtitle,
                              style: const TextStyle(
                                  color: Color(0xFFE2EFF6), height: 1.5)),
                        ])))),
      );
}

class FamilyNotice extends StatelessWidget {
  final String text;
  final bool error;
  const FamilyNotice(this.text, {super.key, this.error = false});
  @override
  Widget build(BuildContext context) => Semantics(
      liveRegion: error,
      child: Container(
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
              color: error
                  ? Theme.of(context).colorScheme.errorContainer
                  : const Color(0xFFEAF1F5),
              borderRadius: BorderRadius.circular(14)),
          child: Text(text,
              style: TextStyle(
                  color: error
                      ? Theme.of(context).colorScheme.onErrorContainer
                      : familyInk))));
}

/// Opened routes stop displaying private data as soon as identity or role changes.
mixin FamilyScope<T extends StatefulWidget> on State<T> {
  ParentSession get session;
  late final String scopeTenant, scopeActor, scopeRole;
  late final int scopeGeneration;
  bool scopeInvalidated = false;
  bool get current =>
      mounted &&
      !scopeInvalidated &&
      session.generation == scopeGeneration &&
      session.authenticated &&
      session.canDecide &&
      session.tenant?['kind'] == 'FAMILY' &&
      session.tenant?['id'] == scopeTenant &&
      session.profile?['subject'] == scopeActor &&
      session.role == scopeRole;
  late final FamilyService service;
  @override
  void initState() {
    super.initState();
    scopeTenant = session.tenant!['id'];
    scopeActor = session.profile!['subject'];
    scopeRole = session.role;
    scopeGeneration = session.generation;
    service = FamilyService(
        api: session.api, tenantId: scopeTenant, available: () => current);
    session.addListener(_scopeChanged);
  }

  void _scopeChanged() {
    if (mounted && !current) setState(() => scopeInvalidated = true);
  }

  @override
  void dispose() {
    session.removeListener(_scopeChanged);
    super.dispose();
  }
}

class FamilyWorkspace extends StatefulWidget {
  final ParentSession session;
  final Widget account, firstUse;
  final Widget? notificationShortcut;
  final VoidCallback onApprovals, onHelp, onDevices;
  const FamilyWorkspace(
      {super.key,
      required this.session,
      required this.account,
      required this.firstUse,
      required this.onApprovals,
      required this.onHelp,
      required this.onDevices,
      this.notificationShortcut});
  @override
  State<FamilyWorkspace> createState() => _FamilyWorkspaceState();
}

class _FamilyWorkspaceState extends State<FamilyWorkspace> {
  int tab = 0;
  String? selectedId;
  Future<FamilyDashboard>? snapshot;
  late final String? tenant, actor, role;
  late final int scopeGeneration;
  FamilyService? service;
  bool invalidated = false;
  bool get current =>
      mounted &&
      !invalidated &&
      widget.session.generation == scopeGeneration &&
      widget.session.authenticated &&
      widget.session.canDecide &&
      widget.session.tenant?['id'] == tenant &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;
  @override
  void initState() {
    super.initState();
    tenant = widget.session.tenant?['id'];
    actor = widget.session.profile?['subject'];
    role = widget.session.role;
    scopeGeneration = widget.session.generation;
    widget.session.addListener(_changed);
    if (tenant != null && widget.session.canDecide) {
      service = FamilyService(
          api: widget.session.api, tenantId: tenant!, available: () => current);
      snapshot = service!.dashboard();
    }
  }

  void _changed() {
    if (tenant != null && mounted && !current) {
      setState(() => invalidated = true);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    super.dispose();
  }

  Future<void> reload() async {
    if (!current || service == null) return;
    setState(() => snapshot = service!.dashboard());
    try {
      await snapshot;
    } catch (_) {/* Render the scoped error below. */}
  }

  Future<void> connect() async {
    if (!current) return;
    await showDialog<bool>(
        context: context,
        builder: (_) => EnrollmentFlow(session: widget.session));
    await reload();
  }

  void report(FamilyChild child) =>
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              UsageReportCenter(session: widget.session, subjectId: child.id)));
  Future<void> edit(FamilyChild child) async {
    if (!current) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            FamilyRulesPage(session: widget.session, child: child)));
    await reload();
  }

  Future<void> deviceAccess() async {
    if (!current) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => FamilyDeviceAccessPage(session: widget.session)));
    await reload();
  }

  Widget content(FamilyDashboard data) {
    final child = data.children.where((c) => c.id == selectedId).firstOrNull ??
        data.children.firstOrNull;
    return RefreshIndicator(
        onRefresh: reload,
        child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            children: [
              if (data.children.isNotEmpty) ...[
                FamilyHero(
                    title: tab == 0
                        ? '今天，陪伴有方向'
                        : tab == 1
                            ? '一起约定使用规则'
                            : '看见每一步成长',
                    subtitle: '家庭辅助限制，共同安排数字生活'),
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final item in data.children)
                    ChoiceChip(
                        avatar: const Icon(Icons.face_outlined, size: 20),
                        label: Text(item.nickname),
                        selected: item.id == child?.id,
                        onSelected: (_) => setState(() => selectedId = item.id))
                ]),
                const SizedBox(height: 12),
              ],
              if (tab == 0 && data.deviceAccess != null)
                FamilyDeviceAccessSummary(
                    snapshot: data.deviceAccess!, onOpen: deviceAccess),
              if (child == null) _onboarding(),
              if (child != null && tab == 0) ...[
                FamilyPanel(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(child.nickname,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 18),
                      if (child.devices.every((d) => d.observedSeconds == null))
                        Center(
                            child: Image.asset('assets/family/usage-empty.png',
                                width: 112,
                                height: 68,
                                excludeFromSemantics: true)),
                      const Text('今日使用', style: TextStyle(color: familyMuted)),
                      const SizedBox(height: 6),
                      Text(
                          child.devices.every((d) => d.observedSeconds == null)
                              ? '尚无使用数据'
                              : '已收到部分使用数据',
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                                  color: familyInk,
                                  fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      const Text('使用记录需要有效观察授权。缺少数据不代表没有使用。',
                          style: TextStyle(color: familyMuted)),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                          onPressed: () => report(child),
                          icon: const Icon(Icons.insights_outlined),
                          label: const Text('查看使用报告')),
                    ])),
                FamilyPanel(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('今天的约定',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 10),
                      Text(child.rules == null || !child.rules!.enabled
                          ? '暂未启用辅助限制'
                          : child.rules!.dailyAllowanceSeconds == 86400
                              ? '不设每日用时上限'
                              : '每日所选应用 ${child.rules!.dailyAllowanceSeconds ~/ 60} 分钟'),
                      const SizedBox(height: 8),
                      const Text('儿童设备提供辅助限制，关闭授权或退出应用可能中断。请查看设备的当前状态。',
                          style: TextStyle(color: familyMuted)),
                      TextButton.icon(
                          onPressed: () => edit(child),
                          icon: const Icon(Icons.tune),
                          label: const Text('调整规则')),
                    ])),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                      onPressed: widget.onApprovals,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: Text('待处理申请 ${data.pendingRequestCount}')),
                  OutlinedButton.icon(
                      onPressed: widget.onHelp,
                      icon: const Icon(Icons.favorite_border),
                      label: Text('孩子的求助 ${data.openHelpRequestCount}')),
                ]),
                const SizedBox(height: 18),
                Text('孩子的设备',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                if (child.devices.isEmpty)
                  const FamilyNotice('还没有连接设备，扫码连接后再核对权限和规则。'),
                for (final device in child.devices)
                  FamilyPanel(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(device.displayName,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text(
                            device.lastHeartbeatAt == null
                                ? '尚未收到设备联系'
                                : '最近联系：${familyDate(device.lastHeartbeatAt)}',
                            style: const TextStyle(color: familyMuted)),
                        Text(
                            device.runtime == null
                                ? '辅助运行状态待核对'
                                : '已收到运行状态，请核对设备权限',
                            style: const TextStyle(color: familyMuted)),
                        const SizedBox(height: 4),
                        TextButton(
                            onPressed: widget.onDevices,
                            child: const Text('查看设备与权限')),
                      ])),
                OutlinedButton.icon(
                    onPressed: connect,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('再连接一台设备')),
              ],
              if (child != null && tab == 1) ...[
                FamilyPanel(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Icon(Icons.tune, color: familyInk, size: 30),
                      const SizedBox(height: 14),
                      Text('${child.nickname}的日常安排',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 10),
                      const Text('选择需要辅助限制的应用，约定每日用时与可用时段。'),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                          onPressed: () => edit(child),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('编辑家庭规则')),
                    ])),
                FamilyPanel(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('需要一点建议？',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      const Text('助手可以整理规则草稿。你核对并保存后才会生效。'),
                      TextButton.icon(
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => FamilyAssistantPage(
                                      session: widget.session,
                                      child: child,
                                      task: 'RULE_DRAFT'))),
                          icon: const Icon(Icons.auto_awesome_outlined),
                          label: const Text('请助手起草')),
                    ])),
                const FamilyNotice('辅助限制不等于系统强制，不能防卸载，也不能保证无法绕过。紧急联系始终优先。'),
              ],
              if (child != null && tab == 2) ...[
                FamilyPanel(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Icon(Icons.insights_outlined,
                          size: 32, color: familyInk),
                      const SizedBox(height: 14),
                      Text('${child.nickname}的使用与成长',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 10),
                      const Text('从有授权的使用区间和趋势开始，一起商量更适合的节奏。'),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                          onPressed: () => report(child),
                          icon: const Icon(Icons.bar_chart_outlined),
                          label: const Text('打开使用报告')),
                    ])),
                const FamilyNotice('报告只展示已授权的使用记录。数据不完整时会标出缺口，不会把缺失记录当作零使用。'),
                FamilyPanel(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('一起读懂报告',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      const Text('助手按已授权范围解释报告，不能诊断孩子或替代家长判断。'),
                      TextButton.icon(
                          onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => FamilyAssistantPage(
                                      session: widget.session,
                                      child: child,
                                      task: 'REPORT_EXPLANATION'))),
                          icon: const Icon(Icons.auto_awesome_outlined),
                          label: const Text('请助手解释')),
                    ])),
              ],
              if (child != null) ...[
                const SizedBox(height: 18),
                Text('数据更新：${familyDate(data.generatedAt)}',
                    style: const TextStyle(color: familyMuted, fontSize: 12))
              ],
            ]));
  }

  Widget _onboarding() => FamilyPanel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.family_restroom, size: 44, color: familyInk),
        const SizedBox(height: 20),
        Text('连接孩子的第一台设备',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        const Text('1. 添加孩子的昵称和年龄段\n2. 用家长手机扫描儿童端二维码\n3. 核对设备权限，再一起约定规则'),
        const SizedBox(height: 18),
        FilledButton.icon(
            onPressed: connect,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('扫码连接设备')),
        const SizedBox(height: 16),
        const Text('符合条件的家庭可在设备实际激活后领取 7 天试用。试用状态以服务返回为准。',
            style: TextStyle(color: familyMuted)),
        const SizedBox(height: 12),
        const Text('辅助限制需要孩子设备授权；紧急联系、系统设置和退出入口始终保留。',
            style: TextStyle(color: familyMuted)),
      ]));
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(widget.session.tenant?['name'] as String? ?? '我的家庭',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            actions: [
              if (widget.session.tenant != null &&
                  widget.session.canDecide) ...[
                IconButton(
                    tooltip: '孩子的求助',
                    onPressed: widget.onHelp,
                    icon: const Icon(Icons.favorite_border)),
                if (widget.notificationShortcut != null)
                  widget.notificationShortcut!,
              ],
            ]),
        body: tab == 3
            ? widget.account
            : widget.session.tenant == null
                ? widget.firstUse
                : !current
                    ? const Center(
                        child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('当前账号没有家庭监护权限，请切换家庭或联系所有者。')))
                    : FutureBuilder<FamilyDashboard>(
                        future: snapshot,
                        builder: (context, result) {
                          if (result.hasError) {
                            return ListView(
                                padding: const EdgeInsets.all(24),
                                children: [
                                  FamilyNotice(familyError(result.error!),
                                      error: true),
                                  OutlinedButton(
                                      onPressed: reload,
                                      child: const Text('重新读取'))
                                ]);
                          }
                          if (!result.hasData) {
                            return const Center(
                                child: CircularProgressIndicator());
                          }
                          return content(result.data!);
                        }),
        bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (value) => setState(() => tab = value),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: '今日'),
              NavigationDestination(
                  icon: Icon(Icons.tune_outlined),
                  selectedIcon: Icon(Icons.tune),
                  label: '规则'),
              NavigationDestination(
                  icon: Icon(Icons.insights_outlined),
                  selectedIcon: Icon(Icons.insights),
                  label: '成长'),
              NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: '我的'),
            ]),
      );
}
