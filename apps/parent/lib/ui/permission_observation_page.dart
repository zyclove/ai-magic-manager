import 'package:flutter/material.dart';
import 'package:usage_reporting/usage_reporting.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import '../core/permission_observation.dart';
import 'observation_settings_page.dart';
import 'permission_consent_page.dart';

Future<void> openParentPermissions(
    BuildContext context, ParentSession session, Json device) async {
  if (!permissionObservationEnabled ||
      !session.authenticated ||
      !session.canDecide ||
      session.tenant == null ||
      device['state'] != 'ACTIVE' ||
      !const {'ANDROID', 'ANDROID_TV'}.contains(device['platform'])) return;
  if (['id', 'registrationId', 'subjectId', 'displayName']
      .any((k) => device[k] is! String)) return;
  final target = UsageReportTarget(device['id'], device['registrationId'],
      device['subjectId'], device['displayName'],
      platform: device['platform']);
  if (!target.valid) return;
  await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ParentPermissionsPage(session: session, target: target)));
}

/// One device, one selected application, one clear next action. Permission facts
/// are neither durable local records nor proof of remote policy enforcement.
class ParentPermissionsPage extends StatefulWidget {
  final ParentSession session;
  final UsageReportTarget target;
  const ParentPermissionsPage(
      {super.key, required this.session, required this.target});
  @override
  State<ParentPermissionsPage> createState() => _ParentPermissionsPageState();
}

class _ParentPermissionsPageState extends State<ParentPermissionsPage>
    with WidgetsBindingObserver {
  late final String tenant, actor, role;
  late final ParentPermissionView view;
  final search = TextEditingController();
  final scroll = ScrollController();
  bool foreground = true;
  int limit = 20;
  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.canDecide &&
      widget.session.tenant?['id'] == tenant &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role;
  @override
  void initState() {
    super.initState();
    tenant = widget.session.tenant!['id'];
    actor = widget.session.profile!['subject'];
    role = widget.session.role;
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    view = ParentPermissionView(
        api: widget.session.api,
        tenant: tenant,
        target: widget.target,
        isCurrent: () => current,
        foreground: () => foreground);
    widget.session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    view.load();
  }

  void _changed() {
    if (!mounted || current) return;
    view.hide();
    search.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || current) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      view.hide();
      search.clear();
    }
    if (mounted) setState(() {});
  }

  Future<void> _authorization({bool inventory = false}) async {
    if (!current || !foreground || view.busy) return;
    view.hide();
    search.clear();
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => inventory
            ? ParentObservationPage(
                session: widget.session, target: widget.target)
            : PermissionConsentPage(
                session: widget.session, target: widget.target)));
    if (current && foreground) await view.load();
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    view.dispose();
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _select(PermissionCandidate app) async {
    await view.load(app: app);
    if (current && foreground && scroll.hasClients) {
      await scroll.animateTo(0,
          duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: view,
      builder: (context, _) {
        final settings = view.settings,
            inventory = view.inventory,
            result = view.result;
        final query = search.text.trim().toLowerCase();
        final apps = inventory?.applications
                .where((app) =>
                    app.displayName.toLowerCase().contains(query) ||
                    app.packageName.toLowerCase().contains(query))
                .toList() ??
            <PermissionCandidate>[];
        return Scaffold(
            appBar: AppBar(title: const Text('应用权限'), actions: [
              IconButton(
                  tooltip: '刷新权限状态',
                  onPressed: !current || !foreground || view.busy
                      ? null
                      : view.refresh,
                  icon: const Icon(Icons.refresh)),
            ]),
            body: !current || !foreground
                ? const Center(child: Text('权限内容已隐藏，返回后请刷新。'))
                : Center(
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: ListView(
                            controller: scroll,
                            padding: const EdgeInsets.all(20),
                            children: [
                              Text(widget.target.displayName,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall),
                              const SizedBox(height: 8),
                              const Text('看清应用需要哪些权限，以及设备最近报告的授权情况。'),
                              const SizedBox(height: 16),
                              if (view.busy) const LinearProgressIndicator(),
                              if (view.error != null)
                                _notice('${view.error}', Icons.info_outline),
                              if (settings != null)
                                Card(
                                    child: ListTile(
                                        leading: Icon(settings.enabled
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined),
                                        title: Text(settings.enabled
                                            ? '权限观察已允许'
                                            : '权限观察未开启'),
                                        subtitle: const Text('不代表已授予应用系统权限'),
                                        trailing:
                                            const Icon(Icons.chevron_right),
                                        onTap: view.busy
                                            ? null
                                            : () => _authorization())),
                              if (settings == null && !view.busy)
                                OutlinedButton(
                                    onPressed: () => view.load(),
                                    child: const Text('重新读取')),
                              if (settings?.enabled == false) ...[
                                const SizedBox(height: 12),
                                _notice('开启后，仅观察所选应用的权限状态。可随时撤回，不采集应用内容。',
                                    Icons.privacy_tip_outlined),
                                FilledButton.icon(
                                    onPressed: () => _authorization(),
                                    icon: const Icon(Icons.tune),
                                    label: const Text('设置权限观察')),
                              ],
                              if (settings?.enabled == true &&
                                  inventory == null) ...[
                                _notice('需要先允许应用清单，才能选择设备上的应用。',
                                    Icons.apps_outlined),
                                OutlinedButton(
                                    onPressed: () =>
                                        _authorization(inventory: true),
                                    child: const Text('设置应用清单授权')),
                              ],
                              if (inventory != null) ...[
                                const SizedBox(height: 12),
                                Text('应用清单 · ${statusLabel(inventory.status)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium),
                                if (inventory.status != 'RECENT')
                                  _notice('清单尚未更新。请让儿童设备联网并重新上报；空清单不代表设备未安装应用。',
                                      Icons.schedule),
                                if (result != null) ..._details(result),
                                if (view.selected != null &&
                                    result == null &&
                                    !view.busy)
                                  _notice('未取得所选应用的权限快照。请刷新后重新选择。',
                                      Icons.help_outline),
                                const SizedBox(height: 16),
                                TextField(
                                    controller: search,
                                    onChanged: (_) =>
                                        setState(() => limit = 20),
                                    decoration: InputDecoration(
                                        labelText: '查找应用',
                                        hintText: '名称或包名',
                                        prefixIcon: const Icon(Icons.search),
                                        suffixIcon: query.isEmpty
                                            ? null
                                            : IconButton(
                                                tooltip: '清除搜索',
                                                onPressed: () => setState(() {
                                                      search.clear();
                                                      limit = 20;
                                                    }),
                                                icon:
                                                    const Icon(Icons.close)))),
                                const SizedBox(height: 8),
                                Text('${apps.length} 个可见应用 · 选择后查看权限',
                                    style:
                                        Theme.of(context).textTheme.bodySmall),
                                if (apps.isEmpty)
                                  const Padding(
                                      padding:
                                          EdgeInsets.symmetric(vertical: 24),
                                      child: Text('没有匹配的应用。可以清除搜索或稍后刷新。')),
                                for (final app in apps.take(limit))
                                  Card(
                                      child: ListTile(
                                          leading:
                                              const Icon(Icons.apps_outlined),
                                          title: Text(app.displayName),
                                          subtitle:
                                              Text(profileLabel(app.profile)),
                                          trailing:
                                              const Icon(Icons.chevron_right),
                                          selected:
                                              view.selected?.packageName ==
                                                      app.packageName &&
                                                  view.selected?.profile ==
                                                      app.profile,
                                          onTap: view.busy
                                              ? null
                                              : () => _select(app))),
                                if (apps.length > limit)
                                  TextButton(
                                      onPressed: () =>
                                          setState(() => limit += 20),
                                      child: const Text('显示更多应用')),
                              ],
                              const SizedBox(height: 20),
                              const ExpansionTile(
                                  title: Text('哪些信息可以确认？'),
                                  children: [
                                    Padding(
                                        padding: EdgeInsets.all(16),
                                        child: Text(
                                            '这里显示设备自报信息，未经系统能力认证。当前仅保留最近一次上报的单个应用快照；其他应用可能暂无数据。'
                                            '普通个人设备不能通过此页面远程授予或撤销系统权限；需要在儿童设备的系统应用设置中操作。电视是否支持还取决于厂商。'))
                                  ]),
                            ]))));
      });
  Widget _notice(String text, IconData icon) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: const Color(0xFF315E86)),
        const SizedBox(width: 10),
        Expanded(child: Text(text))
      ]));
  List<Widget> _details(PermissionObservationResult result) {
    final app = view.selected!;
    final recent = result.status == 'RECENT';
    return [
      const SizedBox(height: 16),
      Card(
          color: const Color(0xFFEAF2F8),
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(app.displayName,
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text('${statusLabel(result.status)} · 设备自报，未经核实'),
                    if (result.receivedAt != null)
                      Text('服务端接收：${_time(result.receivedAt!)}'),
                    if (!recent) const Text('此状态不能用来判断当前权限是否已授予。'),
                    ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('应用详情'),
                        children: [
                          SelectableText(app.packageName),
                          Text(
                              '${profileLabel(app.profile)} · 版本 ${result.versionCode ?? '未知'}'),
                        ]),
                  ]))),
      if (result.permissions.isEmpty)
        _notice(
            switch (result.status) {
              'UNKNOWN' =>
                '还没有这款应用的权限记录。请在儿童设备“使用情况与隐私”中加载应用、选择这款应用完成观察，再点此页刷新。空记录不代表没有权限。',
              'STALE' => '这份记录已过期。请在儿童设备重新选择这款应用完成观察，再刷新本页。旧记录不能代表当前权限。',
              'NOT_AUTHORIZED' => '设备当前未获准上报权限观察。请重新读取授权状态；在恢复授权前不会显示权限明细。',
              _ => 'Android 没有返回可显示的权限明细。空列表不代表没有权限。',
            },
            Icons.help_outline),
      for (final fact in result.permissions)
        Card(
            child: ListTile(
          leading: Icon(fact.observedGrant == 'GRANTED'
              ? Icons.check_circle_outline
              : Icons.info_outline),
          title: Text(permissionLabel(fact.permissionName)),
          subtitle: Text(fact.classification == 'DANGEROUS'
              ? '${recent ? '设备报告' : '历史报告'}：${grantLabel(fact.observedGrant)}'
              : '不属于可在此确认的运行时权限'),
        )),
    ];
  }
}

String statusLabel(String value) => switch (value) {
      'RECENT' => '近期上报',
      'STALE' => '记录已陈旧',
      'NOT_AUTHORIZED' => '尚未授权',
      'REVOKED' => '设备已撤销',
      _ => '暂无可确认数据',
    };
String profileLabel(String value) => switch (value) {
      'PRIMARY' => '设备主用户',
      'WORK' => '工作资料',
      'SECONDARY' => '其他设备用户',
      _ => '用户范围未知',
    };
String grantLabel(String value) =>
    switch (value) { 'GRANTED' => '已授予', 'DENIED' => '未授予', _ => '未知' };
String permissionLabel(String value) =>
    const {
      'android.permission.CAMERA': '相机',
      'android.permission.RECORD_AUDIO': '麦克风',
      'android.permission.ACCESS_FINE_LOCATION': '精确位置',
      'android.permission.ACCESS_COARSE_LOCATION': '大致位置',
      'android.permission.READ_CONTACTS': '读取联系人',
      'android.permission.WRITE_CONTACTS': '修改联系人',
      'android.permission.POST_NOTIFICATIONS': '发送通知',
      'android.permission.READ_MEDIA_IMAGES': '照片',
      'android.permission.READ_MEDIA_VIDEO': '视频',
      'android.permission.READ_MEDIA_AUDIO': '音频',
      'android.permission.READ_PHONE_STATE': '电话状态',
      'android.permission.CALL_PHONE': '拨打电话',
      'android.permission.READ_CALENDAR': '读取日历',
      'android.permission.BODY_SENSORS': '身体传感器',
    }[value] ??
    value;
String _time(int value) {
  final d = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
