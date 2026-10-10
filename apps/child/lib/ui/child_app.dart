import 'dart:async';
import 'package:device_identity/device_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../core/session.dart';
import 'design.dart';
import 'observation_section.dart';
import 'access_section.dart';
import 'submission_section.dart';
import 'report_section.dart';
import '../core/report_loader.dart';

class ChildApp extends StatelessWidget {
  final ChildSession? session;
  final String? serviceLabel;
  final String osVersion;
  final bool nativeAvailable;
  final bool tvMode;
  final bool deploymentInvalid;
  final ChildReportFactory? reportFactory;
  const ChildApp(
      {super.key,
      this.session,
      this.serviceLabel,
      this.osVersion = 'Android',
      this.nativeAvailable = false,
      this.tvMode = false,
      this.reportFactory,
      this.deploymentInvalid = false});
  @override
  Widget build(BuildContext context) => MaterialApp(
      title: '智能管家',
      debugShowCheckedModeBanner: false,
      theme: childTheme(television: tvMode),
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: _ChildHome(this));
}

class _ChildHome extends StatefulWidget {
  final ChildApp configuration;
  const _ChildHome(this.configuration);
  @override
  State<_ChildHome> createState() => _ChildAppState();
}

class _ChildAppState extends State<_ChildHome> with WidgetsBindingObserver {
  ChildApp get app => widget.configuration;
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _ticket = TextEditingController();
  var _tab = 0;
  ChildSession? get session => app.session;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    session?.addListener(_changed);
    unawaited(session?.initialize() ?? Future.value());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (!foreground) _ticket.clear();
    unawaited(session?.setForeground(foreground) ?? Future.value());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    session?.removeListener(_changed);
    session?.dispose();
    _name.dispose();
    _ticket.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_form.currentState!.validate()) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final input = _ticket.text;
    await session!
        .pair(input, displayName: _name.text.trim(), osVersion: app.osVersion);
    if (session!.identityView != null) _ticket.clear();
  }

  String _error(String code) => switch (code) {
        'INVALID_REGISTRATION_TICKET' => '凭据格式不完整。请重新复制监护人提供的完整注册凭据。',
        'AWAITING_GUARDIAN' => '监护人尚未完成确认，请在管理端输入此设备的配对码。',
        'NETWORK_TIMEOUT' ||
        'NETWORK_UNAVAILABLE' =>
          '暂时无法连接。已保存的状态会保留，请检查网络后重试。',
        'SECURE_STORAGE_FAILED' ||
        'SECURE_STORAGE_UNAVAILABLE' =>
          '无法读取或保存设备身份。请检查设备安全存储；不要卸载或重新注册。',
        'ENROLLMENT_EXPIRED' => '注册凭据已到期。请监护人检查注册流程。',
        'ENROLLMENT_UNAVAILABLE' => '服务器暂未找到原认领记录。可以重试原连接，或请监护人检查注册状态。',
        'DEVICE_CREDENTIAL_UNAVAILABLE' => '设备连接凭据暂不可用。请先检查连接状态，或联系监护人。',
        'CONFIGURATION_TRUST_UNAVAILABLE' => '此安装尚未配置规则验证信息。请交付管理员检查应用配置。',
        'CLOCK_UNTRUSTED' => '设备时间异常。请校准时间并联系监护人核对。',
        'SIGNATURE_INVALID' ||
        'IDENTITY_MISMATCH' =>
          '规则验证未通过，已拒绝保存。请监护人检查部署配置。',
        'STORAGE_FAILURE' => '规则存储暂不可用。未完成的回执会在恢复后继续处理。',
        _ => '本次操作未完成，原设备状态会保留。请重试或联系监护人。'
      };
  Widget _button(String label, Future<bool> Function() action) => SizedBox(
      width: double.infinity,
      child: FilledButton(
          onPressed: session!.busy || !app.nativeAvailable
              ? null
              : () => unawaited(action()),
          child: Text(label,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))));
  Widget _heading(String title, String detail) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(
            header: true,
            child:
                Text(title, style: Theme.of(context).textTheme.headlineMedium)),
        const SizedBox(height: 12),
        Text(detail, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 24)
      ]);
  Widget _helpLink(String label) => Column(children: [
        const Divider(),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.help_outline, color: childNavy),
            title: Text(label, style: const TextStyle(color: childNavy)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _helpDialog())
      ]);
  void _helpDialog() => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
              title: const Text('连接设备需要监护人'),
              content: const SingleChildScrollView(
                  child: Text('1. 监护人在管理端创建儿童档案并添加设备。\n\n'
                      '2. 复制完整注册凭据，在这台设备粘贴并连接。\n\n'
                      '3. 将设备显示的八位配对码告诉监护人，由其重新认证并完成确认。\n\n'
                      '4. 返回设备检查连接，再同步规则。收到规则不代表系统限制已经生效。\n\n'
                      '凭据过期、身份损坏或设备需要解绑时，请监护人处理；儿童端不能修改管理规则或重置身份。')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('知道了'))
              ]));
  Widget _pair() => Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _heading('连接我的设备', '请监护人在管理端生成注册凭据，并在下方填写完成设备连接。'),
        ChildNotice('服务地址由部署预设', detail: app.serviceLabel),
        if (app.tvMode) ...[
          const SizedBox(height: 16),
          const ChildNotice('电视输入提示',
              detail: '可使用电视系统键盘或外接键盘输入监护人提供的凭据；配对码仍需由监护人在管理端确认。')
        ],
        const SizedBox(height: 24),
        Text('设备名称', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextFormField(
            controller: _name,
            maxLength: 100,
            enabled: app.nativeAvailable && session?.busy != true,
            decoration:
                const InputDecoration(hintText: '例如：我的手机', counterText: ''),
            textInputAction: TextInputAction.next,
            validator: (s) => s == null || s.trim().isEmpty ? '请输入设备名称' : null),
        const SizedBox(height: 24),
        Text('完整注册凭据', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextFormField(
            controller: _ticket,
            minLines: 4,
            maxLines: 6,
            maxLength: 8192,
            enabled: app.nativeAvailable && session?.busy != true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: const InputDecoration(
                hintText: '粘贴监护人复制的完整凭据', counterText: ''),
            validator: (s) {
              try {
                parseRegistrationTicket(s ?? '');
                return null;
              } catch (_) {
                return '请粘贴完整注册凭据';
              }
            }),
        const SizedBox(height: 16),
        const Text('凭据仅用于此次配对，请勿分享给其他人。'),
        const SizedBox(height: 28),
        SizedBox(
            width: double.infinity,
            child: FilledButton(
                onPressed:
                    session == null || session!.busy || !app.nativeAvailable
                        ? null
                        : _connect,
                child: const Text('安全连接',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w600)))),
        _helpLink('如何获取注册凭据')
      ]));
  Widget _waiting() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _heading('等待监护人确认', '请将下方配对码告诉监护人，并在监护人确认后返回此页面检查状态。'),
        Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 12),
            decoration: BoxDecoration(
                color: childSoft, borderRadius: BorderRadius.circular(10)),
            child: Column(children: [
              const Text('配对码'),
              const SizedBox(height: 24),
              Semantics(
                  label: session!.pairingCode == null
                      ? '配对码已隐藏'
                      : '设备配对码 ${session!.pairingCode}',
                  child: ExcludeSemantics(
                      child: FittedBox(
                          child: Text(_formattedCode(),
                              style: const TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 5,
                                  color: childNavy)))))
            ])),
        const SizedBox(height: 24),
        const ChildNotice('此设备尚未获得系统管控能力。', detail: '请等待监护人完成确认。'),
        const SizedBox(height: 32),
        _button('检查确认状态', session!.checkConnection),
        const Divider(),
        const Text('如已完成确认但状态未更新，请检查网络连接后重试。'),
        _helpLink('查看连接帮助')
      ]);
  String _formattedCode() {
    final code = session!.pairingCode;
    if (code == null) return '•••• ••••';
    return '${code.substring(0, 4)} ${code.substring(4)}';
  }

  Widget _recover() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _heading('继续设备连接', '上次连接的结果尚未确认。原密钥和注册状态已保留，请继续恢复。'),
        const ChildNotice('请勿重新注册或卸载应用。', detail: '恢复会使用原凭据，不会延长注册有效期。'),
        const SizedBox(height: 24),
        _button('恢复原连接', session!.recoverClaim),
        if (session!.errorCode == 'ENROLLMENT_UNAVAILABLE') ...[
          const SizedBox(height: 12),
          _button('重试原连接', session!.retryClaim)
        ],
        _helpLink('查看连接帮助')
      ]);
  Widget _ruleSection() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('规则同步', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.description_outlined, color: childMuted),
            title: Text(session!.rules.configurations.isEmpty
                ? '尚未收到配置'
                : '已保存 ${session!.rules.configurations.length} 份配置'),
            subtitle: Text(session!.rules.configurations.isEmpty
                ? '还未接收到监护人下发的规则配置。'
                : '配置已验签并保存，系统执行尚不支持。')),
        const SizedBox(height: 12),
        _button(session!.rules.hasMore ? '继续同步规则' : '同步规则',
            session!.synchronizeRules),
        const SizedBox(height: 16),
        const ChildNotice('当前为个人设备模式，收到配置不代表已限制其他应用。'),
        if (session!.rules.pendingReceipts > 0)
          Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('还有 ${session!.rules.pendingReceipts} 条保存回执等待发送。'))
      ]);
  Widget _maintenance() {
    final phase = session!.identityView!.phase;
    return ExpansionTile(
        initiallyExpanded: phase != IdentityPhase.active,
        tilePadding: EdgeInsets.zero,
        title: const Text('连接维护'),
        children: [
          const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('连接凭据更新只维护设备身份，不改变监护规则。')),
          if (phase == IdentityPhase.active)
            _button('更新连接凭据', session!.requestRotation),
          if (phase == IdentityPhase.rotationPending)
            _button('完成连接更新', session!.activateRotation),
          if (phase == IdentityPhase.activationUncertain)
            _button('继续确认连接更新', session!.activateRotation),
          if (phase == IdentityPhase.rotationRequested ||
              phase == IdentityPhase.rotationPending) ...[
            const SizedBox(height: 12),
            _button('取消未完成的更新', session!.cancelRotation)
          ],
          const SizedBox(height: 16)
        ]);
  }

  Widget _device() {
    final blocked = session!.identityView!.cloudAuthenticationBlocked ||
        !session!.credentialReady;
    final updating = session!.identityView!.phase != IdentityPhase.active;
    final attention = blocked || updating;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _heading('我的设备', '与监护人管理端保持连接。'),
      Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color:
                  attention ? const Color(0xFFFFF6E8) : const Color(0xFFE7F4F1),
              borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            Icon(attention ? Icons.info_outline : Icons.check_circle,
                color: attention ? const Color(0xFF946000) : childTeal,
                size: 36),
            const SizedBox(width: 16),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(
                      updating
                          ? '连接更新待完成'
                          : blocked
                              ? '连接需要检查'
                              : '设备身份已确认',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color:
                              attention ? const Color(0xFF805300) : childTeal)),
                  const Text('系统管控能力另行核对。')
                ]))
          ])),
      const Divider(),
      _ruleSection(),
      if (session!.observationFactory != null) ...[
        const Divider(),
        ObservationSection(
            view: session!.observationView,
            busy: session!.busy,
            available: app.nativeAvailable && session!.credentialReady,
            errorCode: session!.observationErrorCode,
            refresh: () =>
                unawaited(session!.refreshObservationAuthorization()),
            synchronize: () => unawaited(session!.synchronizeObservations()),
            openSettings: () => unawaited(session!.openObservationSettings()))
      ],
      const Divider(),
      Text('设备能力', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      const ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.phone_android, color: childMuted),
          title: Text('个人设备模式'),
          subtitle: Text('尚不支持系统级应用限制、防卸载或阻止强制停止。')),
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.sync, color: childNavy),
          title: const Text('检查连接'),
          trailing: const Icon(Icons.chevron_right),
          onTap: session!.busy || !app.nativeAvailable
              ? null
              : () => unawaited(session!.checkConnection())),
      const Divider(height: 1),
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.help_outline, color: childNavy),
          title: const Text('查看帮助'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _helpDialog),
      _maintenance()
    ]);
  }

  Widget _rules() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _heading('我的规则', '这里展示已验签并保存的配置意图。实际系统限制需要另外确认。'),
        _ruleSection(),
        const SizedBox(height: 24),
        for (final rule in session!.rules.configurations) ...[
          const Divider(height: 1),
          ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(rule.document?['name'] as String? ?? '已保存配置',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  '包含 ${(rule.document?['rules'] as List?)?.length ?? 0} 条规则；系统执行尚不支持。'))
        ],
        if (session!.submissionFactory != null) ...[
          const Divider(),
          SubmissionSection(session: session!, available: app.nativeAvailable)
        ],
        if (session!.accessFactory != null) ...[
          const Divider(),
          AccessSection(
              view: session!.access,
              busy: session!.busy,
              available: app.nativeAvailable && session!.credentialReady,
              errorCode: session!.accessErrorCode,
              correlationId: session!.accessCorrelationId,
              synchronize: () => unawaited(session!.synchronizeAccess()))
        ]
      ]);
  Widget _help() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _heading('设备帮助', '连接或使用遇到问题时，请先与监护人一起检查。'),
        const ChildNotice('已保存状态会保留', detail: '断网后不能据此认定监护规则已解除；临时放行也不会自动延长。'),
        const SizedBox(height: 24),
        const Text('当前应用接收配置并维护设备身份，尚未实现其他应用的系统级阻止。卸载和强制停止的能力由设备管理模式决定。'),
        const Divider(),
        Text('服务地址', style: Theme.of(context).textTheme.titleMedium),
        SelectableText(app.serviceLabel ?? '尚未配置'),
        const SizedBox(height: 24),
        OutlinedButton(onPressed: _helpDialog, child: const Text('查看连接步骤'))
      ]);

  /// A remote-first rail leaves the active page visible while focus moves.
  Widget _tvNavigation() => NavigationRail(
        extended: true,
        minExtendedWidth: 220,
        backgroundColor: childSoft,
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
        leading: const Padding(
            padding: EdgeInsets.fromLTRB(20, 24, 20, 32),
            child: Text('智能管家',
                style: TextStyle(
                    color: childNavy,
                    fontSize: 22,
                    fontWeight: FontWeight.w700))),
        destinations: const [
          NavigationRailDestination(
              icon: Icon(Icons.phone_android), label: Text('设备')),
          NavigationRailDestination(
              icon: Icon(Icons.description_outlined), label: Text('规则')),
          NavigationRailDestination(
              icon: Icon(Icons.bar_chart_outlined), label: Text('使用')),
          NavigationRailDestination(
              icon: Icon(Icons.help_outline), label: Text('帮助'))
        ],
      );

  Widget _contentPane(Widget content) => SafeArea(
        child: LayoutBuilder(
          builder: (context, bounds) => Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: app.tvMode ? 900 : 520),
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                    horizontal: bounds.maxWidth < 380 ? 20 : 24, vertical: 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.verified_user_outlined,
                          color: childNavy, size: 36),
                      const SizedBox(width: 12),
                      Text('智能管家',
                          style: Theme.of(context).textTheme.titleLarge)
                    ]),
                    const SizedBox(height: 40),
                    if (!app.nativeAvailable && app.session != null) ...[
                      const ChildNotice('浏览器仅供查看界面',
                          detail: '请在 Android 安装设备端，才能安全保存身份并连接。'),
                      const SizedBox(height: 24)
                    ],
                    if (session?.errorCode != null && app.nativeAvailable) ...[
                      Semantics(
                          liveRegion: true,
                          child: ChildNotice(_error(session!.errorCode!),
                              warning: true)),
                      const SizedBox(height: 24)
                    ],
                    if (session?.busy == true)
                      const Padding(
                          padding: EdgeInsets.only(bottom: 20),
                          child:
                              LinearProgressIndicator(semanticsLabel: '正在处理')),
                    content
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Builder(builder: (context) {
        final view = session?.identityView;
        final connected = session?.identityReadSucceeded == true &&
            view != null &&
            view.phase != IdentityPhase.claimUncertain &&
            view.phase != IdentityPhase.awaitingConfirmation;
        Widget content;
        if (app.session == null) {
          content =
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _heading('设备端尚未配置', '请交付管理员为此安装配置服务地址，再开始连接。'),
            ChildNotice(app.deploymentInvalid
                ? '部署配置无效，请管理员检查。'
                : '服务地址由部署预设，儿童不能自行更改。'),
            _helpLink('查看连接帮助')
          ]);
        } else if (!session!.initialized) {
          content = const Center(
              child: Padding(
                  padding: EdgeInsets.all(48),
                  child: CircularProgressIndicator(semanticsLabel: '读取设备状态')));
        } else if (!session!.identityReadSucceeded && app.nativeAvailable) {
          content =
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _heading('设备身份暂不可用', '未确认本地身份状态前不能开始新的注册。请检查安全存储后重新读取。'),
            _button('重新读取状态', session!.reloadIdentity),
            _helpLink('查看连接帮助')
          ]);
        } else if (view == null) {
          content = _pair();
        } else if (view.phase == IdentityPhase.claimUncertain) {
          content = _recover();
        } else if (view.phase == IdentityPhase.awaitingConfirmation) {
          content = _waiting();
        } else {
          content = switch (_tab) {
            1 => _rules(),
            2 => ChildReportSection(
                key: ValueKey(
                    '${view.tenantId}/${view.deviceId}/${view.registrationId}/${session!.observationView.authorization?.version}'),
                session: session!,
                factory: app.reportFactory,
                nativeAvailable: app.nativeAvailable,
                reconnect: () => setState(() => _tab = 0)),
            3 => _help(),
            _ => _device()
          };
        }
        return Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.arrowDown):
                  DirectionalFocusIntent(TraversalDirection.down),
              SingleActivator(LogicalKeyboardKey.arrowUp):
                  DirectionalFocusIntent(TraversalDirection.up),
              SingleActivator(LogicalKeyboardKey.arrowLeft):
                  DirectionalFocusIntent(TraversalDirection.left),
              SingleActivator(LogicalKeyboardKey.arrowRight):
                  DirectionalFocusIntent(TraversalDirection.right)
            },
            child: FocusTraversalGroup(
                child: Scaffold(
                    body: Row(children: [
                      if (connected && app.tvMode) ...[
                        SafeArea(child: _tvNavigation()),
                        const VerticalDivider(width: 1)
                      ],
                      Expanded(child: _contentPane(content))
                    ]),
                    bottomNavigationBar: connected && !app.tvMode
                        ? NavigationBar(
                            selectedIndex: _tab,
                            onDestinationSelected: (index) =>
                                setState(() => _tab = index),
                            destinations: const [
                                NavigationDestination(
                                    icon: Icon(Icons.phone_android),
                                    label: '设备'),
                                NavigationDestination(
                                    icon: Icon(Icons.description_outlined),
                                    label: '规则'),
                                NavigationDestination(
                                    icon: Icon(Icons.bar_chart_outlined),
                                    label: '使用'),
                                NavigationDestination(
                                    icon: Icon(Icons.help_outline), label: '帮助')
                              ])
                        : null)));
      });
}
