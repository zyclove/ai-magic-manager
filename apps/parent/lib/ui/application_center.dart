import 'package:flutter/material.dart';
import '../core/application_catalog.dart';
import '../core/paged_collection.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';

mixin _CatalogScope<T extends StatefulWidget> on State<T> {
  ParentSession get session;
  late final String tenant, actor, role;
  bool get current =>
      mounted &&
      session.authenticated &&
      session.tenant?['id'] == tenant &&
      session.profile?['subject'] == actor &&
      session.role == role &&
      const {'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'AUDITOR'}.contains(role);
  @override
  void initState() {
    super.initState();
    tenant = session.tenant!['id'];
    actor = session.profile!['subject'];
    role = session.role;
    session.addListener(_changed);
  }

  void _changed() {
    if (!mounted || current) return;
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
  void dispose() {
    session.removeListener(_changed);
    super.dispose();
  }
}

class ApplicationCenter extends StatefulWidget {
  final ParentSession session;
  final bool choosing;
  const ApplicationCenter(
      {super.key, required this.session, this.choosing = false});
  @override
  State<ApplicationCenter> createState() => _ApplicationCenterState();
}

class _ApplicationCenterState extends State<ApplicationCenter>
    with _CatalogScope {
  @override
  ParentSession get session => widget.session;
  late final PagedCollection apps;
  bool navigating = false;
  @override
  void initState() {
    super.initState();
    apps = PagedCollection(session.api, '/tenants/$tenant/applications');
  }

  @override
  void dispose() {
    apps.dispose();
    super.dispose();
  }

  Future<void> _open(String id) async {
    if (!current || navigating) return;
    setState(() => navigating = true);
    final selected = await Navigator.of(context).push<Json>(MaterialPageRoute(
        builder: (_) => _ApplicationDetail(
            session: session, id: id, choosing: widget.choosing)));
    if (!mounted || !current) return;
    setState(() => navigating = false);
    if (widget.choosing && selected != null) {
      Navigator.pop(context, selected);
    } else {
      await apps.reload();
    }
  }

  Future<void> _create() async {
    if (!current || navigating || !session.canDecide) return;
    setState(() => navigating = true);
    final value = await Navigator.of(context).push<Json>(MaterialPageRoute(
        builder: (_) => CatalogOperationPage(session: session)));
    if (!current) return;
    setState(() => navigating = false);
    if (value != null) await _open(value['id']);
    if (current) await apps.reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('应用目录'), actions: [
        if (session.canDecide)
          TextButton.icon(
              onPressed: navigating ? null : _create,
              icon: const Icon(Icons.add),
              label: const Text('登记 / 恢复'))
      ]),
      body: AnimatedBuilder(
          animation: apps,
          builder: (context, _) => RefreshIndicator(
              onRefresh: apps.reload,
              child: ListView(padding: const EdgeInsets.all(20), children: [
                Text('核对应用，再配置规则',
                    style: Theme.of(context).textTheme.headlineSmall),
                const Text('目录是管理员声明，不证明应用已安装、安全或签名经过认证。手机与电视、不同系统资料分开登记。'),
                if (apps.loading || apps.loadingMore)
                  const LinearProgressIndicator(),
                if (apps.error != null) ...[
                  Text('${apps.error}'),
                  TextButton(onPressed: apps.reload, child: const Text('重新读取'))
                ],
                if (apps.loaded && apps.items.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('还没有登记应用。可从右上角登记身份，之后在规则中选择。')),
                for (final app in apps.items)
                  Card(
                      child: ListTile(
                          title: Text(app['displayName'] ?? '未命名应用'),
                          subtitle: Text(
                              '${app['packageName']}\n${appPlatforms[app['platform']] ?? '未知平台'} · ${appProfiles[app['profile']] ?? '未知资料'}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: navigating ? null : () => _open(app['id']))),
                if (apps.hasMore)
                  TextButton(
                      onPressed: apps.loadingMore ? null : apps.loadMore,
                      child: const Text('加载更多应用')),
              ]))));
}

class ApplicationIdentityView extends StatelessWidget {
  final Json application;
  const ApplicationIdentityView({super.key, required this.application});
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(application['displayName'],
            style: Theme.of(context).textTheme.titleLarge),
        SelectableText(application['packageName']),
        Text(
            '${appPlatforms[application['platform']]} · ${appProfiles[application['profile']]}'),
        const Text('来源：管理员登记；不是安装、安全或签名认证。'),
        ExpansionTile(
            title: Text(
                '签名 SHA-256 · ${(application['signingDigests'] as List).length} 份'),
            children: [
              if ((application['signingDigests'] as List).isEmpty)
                const ListTile(title: Text('未登记签名；无法凭此目录确认签名身份。')),
              for (final hash in application['signingDigests'])
                Padding(
                    padding: const EdgeInsets.all(8),
                    child: SelectableText(hash)),
            ]),
      ]);
}

class _ApplicationDetail extends StatefulWidget {
  final ParentSession session;
  final String id;
  final bool choosing;
  const _ApplicationDetail(
      {required this.session, required this.id, required this.choosing});
  @override
  State<_ApplicationDetail> createState() => _ApplicationDetailState();
}

class _ApplicationDetailState extends State<_ApplicationDetail>
    with _CatalogScope {
  @override
  ParentSession get session => widget.session;
  late Future<Json> data;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    data = _load();
  }

  Future<Json> _load() async {
    final app = readApplication(
        await session.api.object('/tenants/$tenant/applications/${widget.id}',
            isCurrent: () => current),
        id: widget.id);
    final category = await session.api.object(
        '/tenants/$tenant/applications/${widget.id}/classification',
        isCurrent: () => current);
    readClassification(category, app);
    return {'application': app, 'classification': category};
  }

  Future<void> _classify(Json value) async {
    if (!current || busy || !session.canDecide) return;
    setState(() => busy = true);
    final result = await Navigator.of(context).push<Json>(MaterialPageRoute(
        builder: (_) => CatalogOperationPage(
            session: session,
            application: value['application'],
            classification: value['classification'])));
    if (!mounted || !current) return;
    if (result != null && result['id'] != widget.id) {
      final selected = await Navigator.of(context).push<Json>(MaterialPageRoute(
          builder: (_) => _ApplicationDetail(
              session: session, id: result['id'], choosing: widget.choosing)));
      if (mounted && current && selected != null && widget.choosing) {
        Navigator.pop(context, selected);
        return;
      }
    }
    if (current) {
      setState(() {
        busy = false;
        data = _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('应用身份详情')),
      body: FutureBuilder<Json>(
          future: data,
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${snap.error}'),
                TextButton(
                    onPressed: () => setState(() => data = _load()),
                    child: const Text('重新读取'))
              ]));
            }
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final app = snap.data!['application'] as Json;
            final category =
                readClassification(snap.data!['classification'], app);
            return ListView(padding: const EdgeInsets.all(20), children: [
              ApplicationIdentityView(application: app),
              const Text('应用身份不可原地覆盖。如平台、资料、包名或签名不同，请登记独立身份并重新选择策略目标。'),
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                '报表分类：${applicationCategories[category.category]}',
                                style: Theme.of(context).textTheme.titleMedium),
                            Text(
                                '来源：${category.source == 'NONE' ? '尚未配置' : '管理员声明'} · 修订 ${category.version}'),
                            if (category.updatedAt != null)
                              Text(
                                  '更新时间（手机时间）：${DateTime.fromMillisecondsSinceEpoch(category.updatedAt!).toString().split('.').first}'),
                            const Text(
                                '同平台、同资料、同包名的不同签名目录项共享分类。分类仅整理报表，不是安全评级，也不修改策略。'),
                            if (session.canDecide)
                              OutlinedButton(
                                  onPressed:
                                      busy ? null : () => _classify(snap.data!),
                                  child: const Text('修改报表分类')),
                          ]))),
              if (widget.choosing && session.canDecide)
                FilledButton.icon(
                    onPressed: busy ? null : () => Navigator.pop(context, app),
                    icon: const Icon(Icons.check),
                    label: const Text('用于当前规则')),
            ]);
          }));
}

class CatalogOperationPage extends StatefulWidget {
  final ParentSession session;
  final Json? application, classification;
  final CatalogOperationStore? store;
  const CatalogOperationPage(
      {super.key,
      required this.session,
      this.application,
      this.classification,
      this.store});
  @override
  State<CatalogOperationPage> createState() => _CatalogOperationPageState();
}

class _CatalogOperationPageState extends State<CatalogOperationPage>
    with _CatalogScope {
  @override
  ParentSession get session => widget.session;
  late final CatalogOperationController controller;
  final name = TextEditingController(),
      packageName = TextEditingController(),
      digests = TextEditingController();
  final form = GlobalKey<FormState>();
  String platform = 'ANDROID', profile = 'PRIMARY', category = 'UNCLASSIFIED';
  bool dirty = false, leaving = false;
  @override
  void initState() {
    super.initState();
    if (widget.application != null) {
      category = readClassification(widget.classification, widget.application!)
          .category;
    }
    controller = CatalogOperationController(
        api: session.api,
        store: widget.store ?? CatalogOperationStore(),
        tenant: tenant,
        actor: actor,
        isCurrent: () => current && session.canDecide);
    controller.load();
  }

  @override
  void dispose() {
    controller.dispose();
    name.dispose();
    packageName.dispose();
    digests.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    if (controller.busy) return;
    if (dirty && controller.pending == null) {
      final discard = await showDialog<bool>(
          context: context,
          builder: (ctx) =>
              AlertDialog(title: const Text('放弃未保存的目录修改？'), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('继续编辑')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('放弃修改'))
              ]));
      if (discard != true || !current) return;
    }
    if (!mounted) return;
    setState(() => leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _save() async {
    if (!current ||
        controller.busy ||
        !session.canDecide ||
        !form.currentState!.validate()) return;
    Json input;
    try {
      if (widget.application != null) {
        input = {
          'operation': 'CLASSIFY',
          'application': widget.application,
          'version': widget.classification!['version'],
          'category': category
        };
      } else {
        final hashes = digests.text.trim().isEmpty
            ? <String>[]
            : digests.text
                .trim()
                .split(RegExp(r'\s+'))
                .map((s) => s.replaceAll(':', '').toLowerCase())
                .toList()
          ..sort();
        final definition = <String, dynamic>{
          'displayName': name.text.trim(),
          'packageName': packageName.text.trim(),
          'platform': platform,
          'profile': profile,
          'signingDigests': hashes
        };
        validateApplication(definition);
        input = {'operation': 'DECLARE', 'definition': definition};
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title:
                    Text(widget.application == null ? '登记此应用身份？' : '保存报表分类？'),
                content: SingleChildScrollView(
                    child: widget.application == null
                        ? ApplicationIdentityView(
                            application: input['definition'])
                        : Text(
                            '${widget.application!['displayName']}\n${widget.application!['packageName']}\n分类：${applicationCategories[category]}\n同平台、资料、包名共享分类；不会改变设备规则。')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('返回核对')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('确认保存'))
                ]));
    if (confirmed == true && current) await controller.execute(input);
  }

  Future<void> _acknowledge() async {
    final result = controller.result;
    if (result == null) {
      final yes = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: const Text('已核对应用目录及分类？'),
                  content: const Text('无查询结果不能证明未提交。清除仅删除本机标记，不会撤销服务端登记或修改。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('保留记录')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('已核对，清除'))
                  ]));
      if (yes != true || !current) return;
    }
    if (await controller.acknowledge() && current) {
      setState(() => leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (current) Navigator.pop(context, result?['application']);
      });
    }
  }

  Widget _select(String title, String value, Map<String, String> choices,
          ValueChanged<String> change) =>
      DropdownButtonFormField<String>(
          value: value,
          isExpanded: true,
          decoration: InputDecoration(labelText: title),
          items: choices.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: controller.busy
              ? null
              : (v) {
                  if (v != null) {
                    setState(() {
                      change(v);
                      dirty = true;
                    });
                  }
                });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final pending = controller.pending;
        return PopScope(
            canPop: leaving ||
                !dirty && !controller.busy ||
                pending != null && !controller.busy,
            onPopInvoked: (didPop) {
              if (!didPop) _leave();
            },
            child: Scaffold(
                appBar: AppBar(
                    title: Text(pending != null
                        ? '核对原目录操作'
                        : widget.application == null
                            ? '登记应用身份'
                            : '修改报表分类'),
                    leading: IconButton(
                        tooltip: '返回',
                        onPressed: _leave,
                        icon: const Icon(Icons.arrow_back))),
                body: ListView(padding: const EdgeInsets.all(20), children: [
                  if (controller.busy) const LinearProgressIndicator(),
                  if (controller.error != null) Text('${controller.error}'),
                  if (!controller.loaded && !controller.busy)
                    OutlinedButton(
                        onPressed: controller.load,
                        child: const Text('重新读取待核对记录')),
                  if (controller.loaded && pending == null)
                    Form(
                        key: form,
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (widget.application == null) ...[
                                const Text('管理员声明应用身份；不会安装、卸载应用或证明应用安全。'),
                                TextFormField(
                                    controller: name,
                                    enabled: !controller.busy,
                                    maxLength: 100,
                                    decoration: const InputDecoration(
                                        labelText: '应用名称'),
                                    onChanged: (_) =>
                                        setState(() => dirty = true),
                                    validator: (v) => v == null ||
                                            v.trim().isEmpty ||
                                            v.length > 100
                                        ? '请输入 1–100 字符名称'
                                        : null),
                                _select('设备平台', platform, appPlatforms,
                                    (v) => platform = v),
                                _select('系统资料', profile, appProfiles,
                                    (v) => profile = v),
                                TextFormField(
                                    controller: packageName,
                                    enabled: !controller.busy,
                                    maxLength: 255,
                                    autocorrect: false,
                                    decoration: const InputDecoration(
                                        labelText: '应用包名',
                                        helperText:
                                            '例如 org.example.reader；区分大小写'),
                                    onChanged: (_) =>
                                        setState(() => dirty = true),
                                    validator: (v) => v == null ||
                                            !RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
                                                .hasMatch(v.trim())
                                        ? '请输入合法包名，不含网址或路径'
                                        : null),
                                TextFormField(
                                    controller: digests,
                                    enabled: !controller.busy,
                                    minLines: 3,
                                    maxLines: 6,
                                    maxLength: 800,
                                    autocorrect: false,
                                    decoration: const InputDecoration(
                                        labelText: '签名 SHA-256',
                                        helperText:
                                            '每行一份，最多 8 份；可留空，不能据此认证签名。支持冒号分隔十六进制。'),
                                    onChanged: (_) =>
                                        setState(() => dirty = true)),
                              ] else ...[
                                ApplicationIdentityView(
                                    application: widget.application!),
                                const Text('此分类在相同平台、资料和包名下共享，不修改使用权限。'),
                                _select('报表分类', category, applicationCategories,
                                    (v) => category = v),
                              ],
                              const SizedBox(height: 20),
                              FilledButton(
                                  onPressed: controller.busy ? null : _save,
                                  child: const Text('核对并保存')),
                            ])),
                  if (pending != null) ...[
                    Text(pending['body']['operation'] == 'DECLARE'
                        ? '原操作：登记应用'
                        : '原操作：修改报表分类'),
                    ApplicationIdentityView(
                        application: pending['body']['operation'] == 'DECLARE'
                            ? pending['body']['definition']
                            : pending['body']['application']),
                    if (pending['body']['operation'] == 'CLASSIFY')
                      Text(
                          '原修订 ${pending['body']['version']} → ${applicationCategories[pending['body']['category']]}'),
                    SelectableText('请求编号：${pending['requestId']}'),
                    const Text('本机已保留原请求；结果未知时只查询，不自动重发。'),
                    if (controller.result != null)
                      Card(
                          child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('已确认当次操作提交'),
                                    if (controller.result!['current'] != null)
                                      Text(
                                          '当次修订 ${controller.result!['committed']['version']}\n当前修订 ${controller.result!['current']['version']} · ${applicationCategories[controller.result!['current']['category']]}'),
                                    const Text('目录登记或分类更新不代表设备限制已执行。'),
                                  ]))),
                    OutlinedButton(
                        onPressed: controller.busy ? null : controller.query,
                        child: const Text('查询原操作结果')),
                    if (controller.queried && controller.result == null)
                      const Text('未找到可核对结果。请先返回目录核对，不要直接重复提交。'),
                    if (controller.queried)
                      FilledButton(
                          onPressed: controller.busy ? null : _acknowledge,
                          child: Text(controller.result != null
                              ? '完成核对，打开应用'
                              : '核对后清除本机记录')),
                  ],
                ])));
      });
}
