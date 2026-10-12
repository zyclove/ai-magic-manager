import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/parent_api.dart';
import 'core/parent_session.dart';
import 'core/paged_collection.dart';
import 'ui/commercial_account.dart';
import 'ui/device_capabilities.dart';
import 'ui/enrollment_flow.dart';

const _navy = Color(0xFF17324B);
const _blue = Color(0xFF315E86);
const _paper = Color(0xFFF5F7F7);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final session = ParentSession();
  runApp(ParentApp(session: session));
  session.initialize();
}

class ParentApp extends StatelessWidget {
  final ParentSession session;
  const ParentApp({super.key, required this.session});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '智能管家 · 监护人端',
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: _blue),
          scaffoldBackgroundColor: _paper,
          appBarTheme: const AppBarTheme(
              backgroundColor: _paper, foregroundColor: _navy),
          cardTheme: const CardTheme(
              color: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(18)))),
        ),
        home: AnimatedBuilder(
          animation: session,
          builder: (_, __) {
            if (!session.ready) {
              return const Scaffold(
                  body: Center(child: CircularProgressIndicator()));
            }
            if (!session.authenticated) return _Login(session: session);
            return _Workspace(
                key: ValueKey(
                    '${session.profile?['subject']}:${session.tenant?['id']}:${session.role}'),
                session: session);
          },
        ),
      );
}

class _Login extends StatelessWidget {
  final ParentSession session;
  const _Login({required this.session});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 430),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.shield_outlined, size: 52, color: _navy),
                    const SizedBox(height: 34),
                    const Text('安心连接，清晰守护',
                        style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            color: _navy)),
                    const SizedBox(height: 12),
                    const Text('查看孩子的设备状态、处理临时访问和求助。',
                        style: TextStyle(fontSize: 16, color: _blue)),
                    const SizedBox(height: 40),
                    if (!ParentConfig.valid)
                      const _Notice(
                          '尚未配置 HTTPS 身份服务和 API 地址。请由部署管理员设置 OIDC_ISSUER 与 API_URL。'),
                    if (session.error != null)
                      _Notice('${session.error}', error: true),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: session.busy || !ParentConfig.valid
                            ? null
                            : () => session.signIn(),
                        icon: const Icon(Icons.login),
                        label: Text(session.busy ? '正在打开安全登录…' : '使用管理员账号登录'),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text('身份验证在系统浏览器中完成；此应用不接触你的密码。',
                        style: TextStyle(color: _blue)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class _Workspace extends StatefulWidget {
  final ParentSession session;
  const _Workspace({super.key, required this.session});

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('智能管家', style: TextStyle(fontWeight: FontWeight.w700)),
            Text(session.tenant?['name'] as String? ?? '请选择工作空间',
                style: const TextStyle(fontSize: 12, color: _blue)),
          ],
        ),
      ),
      body: tab == 4
          ? _Account(session: session)
          : session.tenant == null
              ? const _Empty('尚无工作空间', '请先由管理员在管理台创建家庭或机构。')
              : !session.canSeeHelp
                  ? const _Empty('当前角色无监护权限', '请切换到具有监护或机构管理权限的工作空间。')
                  : IndexedStack(index: tab, children: [
                      _Overview(session: session),
                      _ApprovalInbox(session: session),
                      _HelpInbox(session: session),
                      _DeviceList(session: session),
                      const SizedBox.shrink(),
                    ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (index) => setState(() => tab = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: '今日'),
          NavigationDestination(
              icon: Icon(Icons.fact_check_outlined), label: '申请'),
          NavigationDestination(icon: Icon(Icons.favorite_border), label: '求助'),
          NavigationDestination(
              icon: Icon(Icons.devices_outlined), label: '设备'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: '我的'),
        ],
      ),
    );
  }
}

class _Overview extends StatefulWidget {
  final ParentSession session;
  const _Overview({required this.session});

  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  Future<(Json, ParentPage)>? snapshot;

  @override
  void initState() {
    super.initState();
    reload();
  }

  void reload() => setState(() {
        final root = widget.session.root;
        snapshot = (
          widget.session.api.object('$root/overview'),
          widget.session.api.page('$root/subjects', limit: 5),
        ).wait;
      });

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: snapshot,
        builder: (context, result) {
          if (result.hasError) {
            return _LoadError(result.error!, retry: reload);
          }
          if (!result.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final (summary, preview) = result.data!;
          final subjects = preview.items;
          return RefreshIndicator(
            onRefresh: () async {
              reload();
              await snapshot;
            },
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const _SectionTitle('今日概览', '掌握设备和待关注事项'),
                const SizedBox(height: 14),
                _Metric(
                    icon: Icons.child_care_outlined,
                    label: '儿童档案',
                    value: '${summary['subjectCount'] ?? '—'}',
                    detail: '已登记的成长档案'),
                _Metric(
                    icon: Icons.devices_outlined,
                    label: '已注册设备',
                    value: '${summary['activeDeviceCount'] ?? '—'}',
                    detail: summary['connectionCheckCount'] is int &&
                            summary['connectionCheckCount'] > 0
                        ? '${summary['connectionCheckCount']} 台需检查连接'
                        : '在线状态和策略执行需逐台核对'),
                _Metric(
                    icon: Icons.fact_check_outlined,
                    label: '待处理申请',
                    value: '${summary['pendingRequestCount'] ?? '—'}',
                    detail: '请核对申请用途和设备'),
                _Metric(
                    icon: Icons.favorite_border,
                    label: '未确认求助',
                    value: '${summary['openHelpRequestCount'] ?? '—'}',
                    detail: '求助不是紧急救援服务'),
                const SizedBox(height: 18),
                const _SectionTitle('最近的孩子档案', '规则与使用情况请在管理工作台查看'),
                const SizedBox(height: 12),
                if (subjects.isEmpty)
                  const _Empty('暂无儿童档案', '请先在管理台添加儿童并完成设备配对。'),
                for (final subject in subjects)
                  Card(
                    child: ListTile(
                      leading:
                          const CircleAvatar(child: Icon(Icons.person_outline)),
                      title: Text(subject['nickname'] as String? ?? '未命名档案'),
                      subtitle: Text(_ageBand(subject['ageBand'])),
                    ),
                  ),
                if (preview.nextCursor != null)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text('仅显示前 5 条；完整档案请在管理工作台查看。',
                        style: TextStyle(color: _blue)),
                  ),
              ],
            ),
          );
        },
      );
}

class _ApprovalInbox extends StatefulWidget {
  final ParentSession session;
  const _ApprovalInbox({required this.session});

  @override
  State<_ApprovalInbox> createState() => _ApprovalInboxState();
}

class _ApprovalInboxState extends State<_ApprovalInbox> {
  late final PagedCollection pending;
  bool sending = false;
  Object? actionError;

  @override
  void initState() {
    super.initState();
    pending = PagedCollection(widget.session.api,
        '${widget.session.root}/access-requests?state=PENDING');
  }

  @override
  void dispose() {
    pending.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    setState(() => actionError = null);
    await pending.reload();
  }

  Future<void> decide(Json item, bool approve) async {
    if (!widget.session.canDecide || sending) return;
    final requested = item['requestedWindowSeconds'] as int? ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(approve ? '批准临时访问？' : '拒绝申请？'),
        content: Text(approve
            ? '最多开放 ${_minutes(requested)}。批准先生成限时访问窗口，是否真正生效仍取决于设备接收和执行结果。'
            : '拒绝后孩子会看到申请结果。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(approve ? '继续安全验证' : '确认拒绝')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final actor = widget.session.profile?['subject'];
    final root = widget.session.root;
    setState(() => sending = true);
    try {
      if (!await widget.session.reauthenticate()) {
        if (mounted && widget.session.error != null) {
          setState(() => actionError = widget.session.error);
        }
        return;
      }
      if (!mounted ||
          widget.session.profile?['subject'] != actor ||
          widget.session.root != root ||
          !widget.session.canDecide) {
        throw const ParentApiException(409, 'SCOPE_DENIED');
      }
      await widget.session.api.send(
          'POST', '$root/access-requests/${item['id']}/decisions',
          version: item['version'] as int,
          body: approve
              ? {'decision': 'APPROVE', 'grantedWindowSeconds': requested}
              : {'decision': 'DENY', 'reasonCode': 'NOT_NOW'});
      reload();
    } catch (failure) {
      if (mounted) setState(() => actionError = failure);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: pending,
        builder: (context, _) {
          if (pending.error != null && !pending.loaded) {
            return _LoadError(pending.error!, retry: reload);
          }
          if (!pending.loaded) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = pending.items
              .where((item) => item['state'] == 'PENDING')
              .toList(growable: false);
          return RefreshIndicator(
            onRefresh: reload,
            child: ListView(padding: const EdgeInsets.all(20), children: [
              const _SectionTitle('临时访问申请', '先核对用途，再决定是否开放'),
              const SizedBox(height: 12),
              if (actionError != null) _Notice('$actionError', error: true),
              if (items.isEmpty)
                _Empty(pending.hasMore ? '本页没有待处理申请' : '暂无待处理申请',
                    pending.hasMore ? '继续加载后续记录。' : '孩子发起的临时访问申请会显示在这里。'),
              for (final item in items)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('访问申请',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text('原因：${item['reason'] ?? '未填写'}'),
                        Text(
                            '申请时长：${_minutes(item['requestedWindowSeconds'] as int? ?? 0)}'),
                        Text('设备：${item['deviceId'] ?? '未知'}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 12),
                        if (widget.session.canDecide)
                          Wrap(spacing: 8, children: [
                            OutlinedButton(
                                onPressed:
                                    sending ? null : () => decide(item, false),
                                child: const Text('拒绝')),
                            FilledButton(
                                onPressed:
                                    sending ? null : () => decide(item, true),
                                child: const Text('批准')),
                          ])
                        else
                          const Text('当前角色只能查看申请。',
                              style: TextStyle(color: _blue)),
                      ],
                    ),
                  ),
                ),
              if (pending.error != null)
                _Notice('${pending.error}', error: true),
              if (pending.loadingMore) const LinearProgressIndicator(),
              if (pending.hasMore)
                TextButton.icon(
                    onPressed: pending.loadingMore ? null : pending.loadMore,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('加载更多申请')),
            ]),
          );
        },
      );
}

class _HelpInbox extends StatefulWidget {
  final ParentSession session;
  const _HelpInbox({required this.session});

  @override
  State<_HelpInbox> createState() => _HelpInboxState();
}

class _HelpInboxState extends State<_HelpInbox> {
  late final PagedCollection requests;
  bool sending = false;
  Object? actionError;

  @override
  void initState() {
    super.initState();
    requests = PagedCollection(
        widget.session.api, '${widget.session.root}/help-requests?state=OPEN');
  }

  @override
  void dispose() {
    requests.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    setState(() => actionError = null);
    await requests.reload();
  }

  Future<void> acknowledge(Json item) async {
    if (sending) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认已看到求助？'),
        content: const Text('此操作只记录你已看到，不能代表已联系孩子或问题已解决。请尽快实际联系。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('已看到')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final root = widget.session.root;
    setState(() => sending = true);
    try {
      if (widget.session.root != root) return;
      await widget.session.api.send(
          'POST', '$root/help-requests/${item['id']}/acknowledge',
          version: item['version'] as int);
      reload();
    } catch (failure) {
      if (mounted) setState(() => actionError = failure);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: requests,
        builder: (context, _) {
          if (requests.error != null && !requests.loaded) {
            return _LoadError(requests.error!, retry: reload);
          }
          if (!requests.loaded) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = requests.items;
          return RefreshIndicator(
            onRefresh: reload,
            child: ListView(padding: const EdgeInsets.all(20), children: [
              const _SectionTitle('孩子的求助', '看到后请通过现实渠道尽快回应'),
              const SizedBox(height: 10),
              const _Notice('这里不是紧急救援服务；遇到即时危险请直接联系当地紧急服务。'),
              if (actionError != null) _Notice('$actionError', error: true),
              if (items.isEmpty) const _Empty('暂无未确认求助', '孩子的求助信息会在这里显示。'),
              for (final item in items)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item['subjectNickname'] as String? ?? '孩子',
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Text(_helpReason(item['reasonCode'])),
                        Text(_time(item['createdAt']),
                            style: const TextStyle(color: _blue)),
                        const SizedBox(height: 10),
                        FilledButton.tonal(
                            onPressed: sending ? null : () => acknowledge(item),
                            child: const Text('确认已看到')),
                      ],
                    ),
                  ),
                ),
              if (requests.error != null)
                _Notice('${requests.error}', error: true),
              if (requests.loadingMore) const LinearProgressIndicator(),
              if (requests.hasMore)
                TextButton.icon(
                    onPressed: requests.loadingMore ? null : requests.loadMore,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('加载更多求助')),
            ]),
          );
        },
      );
}

class _DeviceList extends StatefulWidget {
  final ParentSession session;
  const _DeviceList({required this.session});

  @override
  State<_DeviceList> createState() => _DeviceListState();
}

class _DeviceListState extends State<_DeviceList> {
  late final PagedCollection devices;

  @override
  void initState() {
    super.initState();
    devices =
        PagedCollection(widget.session.api, '${widget.session.root}/devices');
  }

  @override
  void dispose() {
    devices.dispose();
    super.dispose();
  }

  Future<void> reload() => devices.reload();

  Future<void> addDevice() async {
    final completed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => EnrollmentFlow(session: widget.session),
    );
    if (completed == true && mounted) reload();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: devices,
        builder: (context, _) {
          if (devices.error != null && !devices.loaded) {
            return _LoadError(devices.error!, retry: reload);
          }
          if (!devices.loaded) {
            return const Center(child: CircularProgressIndicator());
          }
          return RefreshIndicator(
            onRefresh: reload,
            child: ListView(padding: const EdgeInsets.all(20), children: [
              const _SectionTitle('设备状态', '管理模式决定可用的系统能力'),
              const SizedBox(height: 12),
              if (widget.session.canDecide)
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                      onPressed: addDevice,
                      icon: const Icon(Icons.add),
                      label: const Text('连接儿童设备')),
                ),
              const SizedBox(height: 12),
              if (devices.items.isEmpty)
                const _Empty('暂无设备', '请先在管理工作台创建配对并由儿童设备完成确认。'),
              for (final device in devices.items)
                Card(
                  child: ListTile(
                    onTap: () => showDeviceCapabilities(
                        context, widget.session, device['id'] as String),
                    leading: Icon(device['platform'] == 'ANDROID_TV'
                        ? Icons.tv_outlined
                        : Icons.smartphone_outlined),
                    title: Text(device['displayName'] as String? ?? '未命名设备'),
                    subtitle: Text(
                        '${_deviceState(device['state'])} · ${device['managementMode'] ?? '未知模式'}\n${_controlLevel(device['controlLevel'])}'),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                  ),
                ),
              const _Notice(
                  '点开设备可查看逐项能力。设备在线或商业权益生效，不等于系统策略已执行；请在管理工作台查看逐项回执。'),
              if (devices.error != null)
                _Notice('${devices.error}', error: true),
              if (devices.loadingMore) const LinearProgressIndicator(),
              if (devices.hasMore)
                TextButton.icon(
                    onPressed: devices.loadingMore ? null : devices.loadMore,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('加载更多设备')),
            ]),
          );
        },
      );
}

class _Account extends StatelessWidget {
  final ParentSession session;
  const _Account({required this.session});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _SectionTitle('我的账号', session.displayName),
          const SizedBox(height: 12),
          Card(
            child: Column(children: [
              for (final item in session.tenants)
                RadioListTile<String>(
                  title: Text(item['name'] as String? ?? '工作空间'),
                  subtitle: Text(item['kind'] == 'ORGANIZATION' ? '机构' : '家庭'),
                  value: item['id'] as String,
                  groupValue: session.tenant?['id'] as String?,
                  onChanged: (value) async {
                    if (value == null || value == session.tenant?['id']) return;
                    try {
                      await session.selectTenant(item);
                    } catch (failure) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text('$failure')));
                      }
                    }
                  },
                ),
            ]),
          ),
          if (session.tenant != null &&
              const {'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'AUDITOR'}
                  .contains(session.role)) ...[
            const SizedBox(height: 24),
            CommercialAccount(session: session),
          ],
          const SizedBox(height: 20),
          OutlinedButton.icon(
              onPressed: session.signOut,
              icon: const Icon(Icons.logout),
              label: const Text('退出登录')),
          const SizedBox(height: 18),
          const Text('版本 1.0 · 中国大陆机构合同试点阶段',
              textAlign: TextAlign.center,
              style: TextStyle(color: _blue, fontSize: 12)),
        ],
      );
}

class _SectionTitle extends StatelessWidget {
  final String title, subtitle;
  const _SectionTitle(this.title, this.subtitle);

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: _navy, fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          Text(subtitle, style: const TextStyle(color: _blue)),
        ],
      );
}

class _Metric extends StatelessWidget {
  final IconData icon;
  final String label, value, detail;
  const _Metric(
      {required this.icon,
      required this.label,
      required this.value,
      required this.detail});

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            CircleAvatar(radius: 25, child: Icon(icon)),
            const SizedBox(width: 16),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(label, style: const TextStyle(color: _blue)),
                  Text(value,
                      style: const TextStyle(
                          fontSize: 24,
                          color: _navy,
                          fontWeight: FontWeight.w700)),
                  Text(detail,
                      style: const TextStyle(color: _blue, fontSize: 12)),
                ])),
          ]),
        ),
      );
}

class _Notice extends StatelessWidget {
  final String message;
  final bool error;
  const _Notice(this.message, {this.error = false});

  @override
  Widget build(BuildContext context) => Card(
        color: error ? const Color(0xFFFFF1EE) : const Color(0xFFEAF2F8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(error ? Icons.error_outline : Icons.info_outline,
                color: error ? const Color(0xFF9A3931) : _blue),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ]),
        ),
      );
}

class _Empty extends StatelessWidget {
  final String title, detail;
  const _Empty(this.title, this.detail);

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(25),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.inbox_outlined, size: 38, color: _blue),
            const SizedBox(height: 12),
            Text(title,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 5),
            Text(detail, textAlign: TextAlign.center),
          ]),
        ),
      );
}

class _LoadError extends StatelessWidget {
  final Object error;
  final VoidCallback retry;
  const _LoadError(this.error, {required this.retry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _Notice('$error', error: true),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: retry, child: const Text('重新加载')),
          ]),
        ),
      );
}

String _ageBand(Object? value) => switch (value) {
      'UNDER_7' => '7 岁以下',
      'AGE_7_12' => '7–12 岁',
      'AGE_13_17' => '13–17 岁',
      _ => '年龄段未设置',
    };

String _helpReason(Object? value) => switch (value) {
      'UNCOMFORTABLE_CONTENT' => '看到了不舒服的内容',
      'DEVICE_PROBLEM' => '设备遇到问题',
      _ => '需要帮助',
    };

String _deviceState(Object? value) => switch (value) {
      'ACTIVE' => '已注册',
      'AWAITING_CONFIRMATION' => '等待确认',
      'REVOKED' => '已解除管理',
      _ => '状态未知',
    };

String _controlLevel(Object? value) => switch (value) {
      'SYSTEM' => '受管系统能力，请核对执行回执',
      _ => '有限控制，不能防止系统层面绕过',
    };

String _minutes(int seconds) => seconds < 60
    ? '$seconds 秒'
    : seconds % 60 == 0
        ? '${seconds ~/ 60} 分钟'
        : '${seconds ~/ 60} 分 ${seconds % 60} 秒';

String _time(Object? milliseconds) {
  if (milliseconds is! int) return '时间未知';
  final time = DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal();
  return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}
