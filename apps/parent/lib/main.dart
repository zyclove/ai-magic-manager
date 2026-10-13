import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import 'core/parent_api.dart';
import 'core/parent_session.dart';
import 'core/paged_collection.dart';
import 'core/pending_decisions.dart';
import 'ui/access_history.dart';
import 'ui/commercial_account.dart';
import 'ui/device_capabilities.dart';
import 'ui/device_exit.dart';
import 'ui/enrollment_flow.dart';
import 'ui/policy_center.dart';
import 'ui/device_group_center.dart';

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
  final _decisionStore = PendingDecisionStore();
  List<PendingDecision> _recoveries = const [];
  final _recoveryStatus = <String, String>{};
  final _checkedRecoveries = <String>{};
  String? _lastDecisionId;
  bool _lastDecisionApproved = false;
  bool sending = false;
  bool _recoveryBusy = false;
  bool _recoveriesLoaded = false;
  Object? actionError;

  @override
  void initState() {
    super.initState();
    pending = PagedCollection(widget.session.api,
        '${widget.session.root}/access-requests?state=PENDING');
    _loadRecoveries();
  }

  @override
  void dispose() {
    pending.dispose();
    super.dispose();
  }

  Future<void> reload({bool afterDecision = false}) async {
    if ((sending && !afterDecision) || _recoveryBusy) return;
    setState(() => actionError = null);
    await _loadRecoveries();
    await pending.reload();
  }

  Future<void> _loadRecoveries() async {
    if (mounted) setState(() => _recoveriesLoaded = false);
    final actor = widget.session.profile?['subject'];
    final tenantId = widget.session.tenant?['id'];
    if (actor is! String || tenantId is! String || !widget.session.canDecide) {
      if (mounted) setState(() => _recoveriesLoaded = true);
      return;
    }
    try {
      final records = await _decisionStore.load(tenantId, actor);
      if (_sameDecisionScope(actor, tenantId)) {
        setState(() {
          _recoveries = records;
          _checkedRecoveries.removeWhere(
              (key) => !records.any((record) => record.idempotencyKey == key));
          _recoveriesLoaded = true;
        });
      }
    } catch (failure) {
      if (_sameDecisionScope(actor, tenantId)) {
        setState(() {
          actionError = failure;
          _recoveriesLoaded = false;
        });
      }
    }
  }

  Future<void> decide(Json item, bool approve) async {
    if (!widget.session.canDecide ||
        sending ||
        _recoveryBusy ||
        !_recoveriesLoaded) return;
    final requested = item['requestedWindowSeconds'] as int? ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(approve ? '批准临时访问？' : '拒绝申请？'),
        content: Text(approve
            ? '儿童：${_requestLabel(item['subjectName'], '未命名儿童')}\n应用：${_requestLabel(item['applicationName'], '未命名应用')}\n包名：${_requestLabel(item['applicationPackageName'], '未知')}\n设备：${_requestLabel(item['deviceName'], '未命名设备')}\n申请原因：${_requestLabel(item['reason'], '未填写')}\n\n最多开放 ${_minutes(requested)}。批准先生成限时访问窗口，是否真正生效仍取决于设备接收和执行结果。'
            : '儿童：${_requestLabel(item['subjectName'], '未命名儿童')}\n应用：${_requestLabel(item['applicationName'], '未命名应用')}\n包名：${_requestLabel(item['applicationPackageName'], '未知')}\n设备：${_requestLabel(item['deviceName'], '未命名设备')}\n\n拒绝后孩子会看到申请结果。'),
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
    if (confirmed != true ||
        !mounted ||
        sending ||
        _recoveryBusy ||
        !_recoveriesLoaded) return;
    final actor = widget.session.profile?['subject'];
    final tenantId = widget.session.tenant?['id'];
    if (actor is! String || tenantId is! String) {
      setState(
          () => actionError = const ParentApiException(401, 'UNAUTHENTICATED'));
      return;
    }
    final root = '/tenants/$tenantId';
    final requestId = item['id'];
    final requestVersion = item['version'];
    if (requestId is! String || requestVersion is! int) {
      setState(() =>
          actionError = const ParentApiException(502, 'INVALID_RESPONSE'));
      return;
    }
    if (_recoveries.any((record) =>
        record.requestId == requestId && record.version == requestVersion)) {
      setState(() => actionError = '同一申请已有待核对操作，请先查询原申请。');
      return;
    }
    final decisionKey = const Uuid().v4();
    final marker = PendingDecision(
      requestId: requestId,
      version: requestVersion,
      idempotencyKey: decisionKey,
      choice: approve ? 'APPROVE' : 'DENY',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    var recorded = false;
    var submitted = false;
    setState(() => sending = true);
    try {
      if (!await widget.session.reauthenticate()) {
        if (mounted && widget.session.error != null) {
          setState(() => actionError = widget.session.error);
        }
        return;
      }
      if (!_sameDecisionScope(actor, tenantId)) {
        throw const ParentApiException(409, 'SCOPE_DENIED');
      }
      await _decisionStore.add(tenantId, actor, marker);
      recorded = true;
      if (!_sameDecisionScope(actor, tenantId)) return;
      setState(() => _recoveries = [..._recoveries, marker]);
      submitted = true;
      await widget.session.api.send(
          'POST', '$root/access-requests/$requestId/decisions',
          version: requestVersion,
          idempotencyKey: decisionKey,
          body: approve
              ? {'decision': 'APPROVE', 'grantedWindowSeconds': requested}
              : {'decision': 'DENY', 'reasonCode': 'NOT_NOW'});
      await _decisionStore.remove(tenantId, actor, decisionKey);
      recorded = false;
      if (_sameDecisionScope(actor, tenantId)) {
        setState(() {
          _recoveries = _recoveries
              .where((item) => item.idempotencyKey != decisionKey)
              .toList();
          _lastDecisionId = requestId;
          _lastDecisionApproved = approve;
        });
        await reload(afterDecision: true);
      }
    } catch (failure) {
      if (!_sameDecisionScope(actor, tenantId)) return;
      if (submitted &&
          (failure is! ParentApiException ||
              failure.status == 0 ||
              failure.status >= 500 ||
              failure.code == 'REQUEST_IN_PROGRESS' ||
              failure.code == 'IDEMPOTENCY_KEY_CONFLICT')) {
        final message =
            await _reconcileUncertainDecision(root, requestId, requestVersion);
        if (!_sameDecisionScope(actor, tenantId)) return;
        await pending.reload();
        if (mounted) setState(() => actionError = message);
      } else {
        if (recorded) {
          try {
            await _decisionStore.remove(tenantId, actor, decisionKey);
            if (!_sameDecisionScope(actor, tenantId)) return;
            setState(() => _recoveries = _recoveries
                .where((item) => item.idempotencyKey != decisionKey)
                .toList());
          } catch (_) {
            if (_sameDecisionScope(actor, tenantId)) {
              setState(() => actionError = '操作未完成，且本机待核对记录未能清理。请在此页查询原申请。');
            }
            return;
          }
        }
        setState(() => actionError = failure);
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  bool _sameDecisionScope(String actor, String tenantId) =>
      mounted &&
      widget.session.profile?['subject'] == actor &&
      widget.session.tenant?['id'] == tenantId &&
      widget.session.canDecide;

  /// A failed transport cannot prove that the decision transaction rolled back.
  /// Read the same request once; never silently send a second decision.
  Future<String> _reconcileUncertainDecision(
      String root, String requestId, int expectedVersion) async {
    try {
      final current =
          await widget.session.api.object('$root/access-requests/$requestId');
      if (current['id'] != requestId ||
          current['version'] is! int ||
          current['state'] is! String) {
        return '审批提交后的结果无法核对。请到管理台查看原申请，暂勿重复操作。';
      }
      if (current['state'] == 'PENDING' &&
          current['version'] == expectedVersion) {
        return '提交时连接中断；服务端目前仍显示待处理。请先刷新并核对原申请，再决定是否重试。';
      }
      return '申请状态已变化。本次提交是否生效尚不能仅凭网络错误确认，请核对原申请和设备执行回执。';
    } catch (_) {
      return '审批提交后的结果暂时无法查询。请恢复网络后核对原申请，暂勿重复操作。';
    }
  }

  Future<void> _checkRecovery(PendingDecision record) async {
    final actor = widget.session.profile?['subject'];
    final tenantId = widget.session.tenant?['id'];
    if (actor is! String ||
        tenantId is! String ||
        sending ||
        _recoveryBusy ||
        !_sameDecisionScope(actor, tenantId)) return;
    setState(() => _recoveryBusy = true);
    String message;
    var verified = false;
    try {
      final current = await widget.session.api
          .object('/tenants/$tenantId/access-requests/${record.requestId}');
      if (current['id'] != record.requestId ||
          current['version'] is! int ||
          current['state'] is! String) {
        message = '服务端返回的数据无法核对，请稍后重试。';
      } else if (current['version'] == record.version) {
        verified = true;
        message =
            '服务端原申请版本未变化，当前状态：${current['state']}。无法证明上次提交到达；请核对后再决定是否重试。';
      } else {
        verified = true;
        message = '服务端当前状态：${current['state']}。请核对原申请和设备执行回执；状态变化不能证明由本机提交造成。';
      }
    } catch (_) {
      message = '暂时无法查询服务端原申请，请恢复网络后重试。';
    } finally {
      if (_sameDecisionScope(actor, tenantId)) {
        setState(() => _recoveryBusy = false);
      }
    }
    if (_sameDecisionScope(actor, tenantId)) {
      setState(() {
        if (verified) _checkedRecoveries.add(record.idempotencyKey);
        _recoveryStatus[record.idempotencyKey] = message;
      });
    }
  }

  Future<void> _clearRecovery(PendingDecision record) async {
    final actor = widget.session.profile?['subject'];
    final tenantId = widget.session.tenant?['id'];
    if (actor is! String ||
        tenantId is! String ||
        sending ||
        _recoveryBusy ||
        !_sameDecisionScope(actor, tenantId)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除本机待核对提醒？'),
        content: const Text('这只删除手机上的提醒，不会批准、拒绝或撤销申请。请先核对服务端原申请。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('已核对，清除提醒')),
        ],
      ),
    );
    if (confirmed != true ||
        sending ||
        _recoveryBusy ||
        !_checkedRecoveries.contains(record.idempotencyKey) ||
        !_sameDecisionScope(actor, tenantId)) return;
    setState(() => _recoveryBusy = true);
    try {
      await _decisionStore.remove(tenantId, actor, record.idempotencyKey);
      if (!_sameDecisionScope(actor, tenantId)) return;
      setState(() {
        _recoveries = _recoveries
            .where((item) => item.idempotencyKey != record.idempotencyKey)
            .toList();
        _recoveryStatus.remove(record.idempotencyKey);
        _checkedRecoveries.remove(record.idempotencyKey);
      });
    } catch (failure) {
      if (_sameDecisionScope(actor, tenantId)) {
        setState(() => actionError = failure);
      }
    } finally {
      if (_sameDecisionScope(actor, tenantId)) {
        setState(() => _recoveryBusy = false);
      }
    }
  }

  List<Widget> _recoveryCards() => [
        if (_recoveries.isNotEmpty)
          const _Notice('有上次提交后尚未核对的审批或撤销。请查询原申请；这里不会自动重新提交。'),
        for (final record in _recoveries)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      '待核对：${switch (record.choice) {
                        'APPROVE' => '批准申请',
                        'DENY' => '拒绝申请',
                        _ => '撤销临时访问'
                      }}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  SelectableText('申请编号：${record.requestId}'),
                  Text('提交时间：${_time(record.createdAt)}'),
                  if (_recoveryStatus[record.idempotencyKey] != null)
                    Text(_recoveryStatus[record.idempotencyKey]!),
                  Wrap(spacing: 8, children: [
                    OutlinedButton(
                        onPressed: sending || _recoveryBusy
                            ? null
                            : () => _checkRecovery(record),
                        child: const Text('查询原申请')),
                    TextButton(
                        onPressed: sending ||
                                _recoveryBusy ||
                                !_checkedRecoveries
                                    .contains(record.idempotencyKey)
                            ? null
                            : () => _clearRecovery(record),
                        child: const Text('已核对')),
                  ]),
                ],
              ),
            ),
          ),
      ];

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: pending,
        builder: (context, _) {
          if (pending.error != null && !pending.loaded) {
            return Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: OutlinedButton.icon(
                  onPressed: sending || _recoveryBusy
                      ? null
                      : () async {
                          await showAccessHistory(context, widget.session);
                          if (mounted) await _loadRecoveries();
                        },
                  icon: const Icon(Icons.history),
                  label: const Text('查看申请记录与交付状态'),
                ),
              ),
              if (actionError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: _Notice('$actionError', error: true),
                ),
              if (_recoveries.isNotEmpty)
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(children: _recoveryCards()),
                  ),
                ),
              Expanded(child: _LoadError(pending.error!, retry: reload)),
            ]);
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
              OutlinedButton.icon(
                onPressed: sending || _recoveryBusy
                    ? null
                    : () async {
                        await showAccessHistory(context, widget.session);
                        if (mounted) await _loadRecoveries();
                      },
                icon: const Icon(Icons.history),
                label: const Text('查看申请记录与交付状态'),
              ),
              const SizedBox(height: 10),
              if (_lastDecisionId != null) ...[
                _Notice(
                    _lastDecisionApproved ? '批准决定已保存；设备系统执行仍需核对。' : '拒绝决定已保存。'),
                TextButton.icon(
                  onPressed: sending || _recoveryBusy
                      ? null
                      : () async {
                          await showAccessRequestDetail(
                              context, widget.session, _lastDecisionId!);
                          if (mounted) await _loadRecoveries();
                        },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('查看本次申请状态'),
                ),
              ],
              if (actionError != null) _Notice('$actionError', error: true),
              ..._recoveryCards(),
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
                        Text(
                            '${_requestLabel(item['subjectName'], '儿童')}申请使用${_requestLabel(item['applicationName'], '应用')}',
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Text(
                            '应用包名：${_requestLabel(item['applicationPackageName'], '未知')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        Text('原因：${_requestLabel(item['reason'], '未填写')}'),
                        Text(
                            '申请时长：${_minutes(item['requestedWindowSeconds'] as int? ?? 0)}'),
                        Text(
                            '设备：${_requestLabel(item['deviceName'], '未命名设备')} · ${item['deviceId'] ?? '未知'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 12),
                        if (widget.session.canDecide)
                          Wrap(spacing: 8, children: [
                            OutlinedButton(
                                onPressed: sending ||
                                        _recoveryBusy ||
                                        !_recoveriesLoaded ||
                                        _recoveries.any((record) =>
                                            record.requestId == item['id'] &&
                                            record.version == item['version'])
                                    ? null
                                    : () => decide(item, false),
                                child: const Text('拒绝')),
                            FilledButton(
                                onPressed: sending ||
                                        _recoveryBusy ||
                                        !_recoveriesLoaded ||
                                        _recoveries.any((record) =>
                                            record.requestId == item['id'] &&
                                            record.version == item['version'])
                                    ? null
                                    : () => decide(item, true),
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
    final actor = widget.session.profile?['subject'];
    final tenantId = widget.session.tenant?['id'];
    final requestId = item['id'];
    final version = item['version'];
    if (actor is! String ||
        tenantId is! String ||
        requestId is! String ||
        version is! int) {
      setState(() =>
          actionError = const ParentApiException(502, 'INVALID_RESPONSE'));
      return;
    }
    final root = '/tenants/$tenantId';
    var submitted = false;
    setState(() => sending = true);
    try {
      if (!_sameHelpScope(actor, tenantId)) return;
      submitted = true;
      await widget.session.api.send(
          'POST', '$root/help-requests/$requestId/acknowledge',
          version: version);
      if (_sameHelpScope(actor, tenantId)) await reload();
    } catch (failure) {
      if (!_sameHelpScope(actor, tenantId)) return;
      if (submitted &&
          (failure is! ParentApiException ||
              failure.status == 0 ||
              failure.status >= 500)) {
        final message = await _reconcileUncertainAcknowledge(root, requestId);
        if (!_sameHelpScope(actor, tenantId)) return;
        await requests.reload();
        if (mounted) setState(() => actionError = message);
      } else {
        setState(() => actionError = failure);
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  bool _sameHelpScope(String actor, String tenantId) =>
      mounted &&
      widget.session.profile?['subject'] == actor &&
      widget.session.tenant?['id'] == tenantId &&
      widget.session.canSeeHelp;

  Future<String> _reconcileUncertainAcknowledge(
      String root, String requestId) async {
    try {
      final current =
          await widget.session.api.object('$root/help-requests/$requestId');
      if (current['id'] != requestId || current['state'] is! String) {
        return '求助确认结果无法核对。请在管理台查看原记录，并尽快联系孩子。';
      }
      if (current['state'] == 'ACKNOWLEDGED') {
        return '服务端显示这条求助已被看到；请仍通过现实渠道尽快联系孩子。';
      }
      return '提交时连接中断，服务端目前仍显示未确认。请核对原记录，并尽快联系孩子。';
    } catch (_) {
      return '求助确认结果暂时无法查询。请恢复网络后核对原记录，并尽快联系孩子。';
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: requests,
        builder: (context, _) {
          if (requests.error != null && !requests.loaded) {
            return Column(children: [
              if (actionError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: _Notice('$actionError', error: true),
                ),
              Expanded(child: _LoadError(requests.error!, retry: reload)),
            ]);
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
                    trailing: widget.session.canDecide &&
                            device['managementMode'] == 'BYOD' &&
                            const {'ACTIVE', 'REVOKED'}
                                .contains(device['state'])
                        ? PopupMenuButton<String>(
                            tooltip: '设备操作',
                            onSelected: (action) {
                              if (action == 'exit') {
                                openParentDeviceExit(
                                    context, widget.session, device);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                  value: 'exit', child: Text('正常退出管理')),
                            ],
                          )
                        : const Icon(Icons.chevron_right),
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
            const SizedBox(height: 18),
            Card(
              child: ListTile(
                leading: const Icon(Icons.shield_outlined, color: _blue),
                title: const Text('策略中心'),
                subtitle: const Text('查看草稿并按设备预览规则支持情况'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showPolicyCenter(context, session),
              ),
            ),
          ],
          if (session.tenant?['kind'] == 'ORGANIZATION' &&
              const {'OWNER', 'ORG_ADMIN'}.contains(session.role))
            Card(
                child: ListTile(
              leading: const Icon(Icons.devices_outlined, color: _blue),
              title: const Text('机构设备组'),
              subtitle: const Text('维护班级设备、清理失效关联与核对操作结果'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DeviceGroupCenter(session: session))),
            )),
          if (session.tenant != null &&
              session.canDecide &&
              ParentConfig.console != null) ...[
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  if (!await launchUrl(ParentConfig.console!,
                          mode: LaunchMode.externalApplication) &&
                      context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('无法打开管理台，请检查浏览器和部署地址。')));
                  }
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('无法打开管理台，请检查浏览器和部署地址。')));
                  }
                }
              },
              icon: const Icon(Icons.open_in_browser),
              label: const Text('打开完整管理台'),
            ),
            const Text('策略编辑、批量管理和合同审核在系统浏览器中完成。',
                style: TextStyle(color: _blue)),
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

String _requestLabel(Object? value, String fallback) {
  final label = value is String ? value.trim() : '';
  return label.isEmpty ? fallback : label;
}

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
