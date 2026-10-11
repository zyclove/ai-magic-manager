import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/managed_android.dart';
import '../core/managed_android_repository.dart';
import '../core/session.dart';
import '../ui/design.dart';

/// Institution provisioning console. A provider receipt never changes local device capabilities.
class ManagedAndroidPage extends StatefulWidget {
  final Session session;
  const ManagedAndroidPage({super.key, required this.session});

  @override
  State<ManagedAndroidPage> createState() => _ManagedAndroidPageState();
}

class _ManagedAndroidPageState extends State<ManagedAndroidPage> {
  late final String tenantId, actor, role;
  late final ManagedAndroidRepository repository;
  ManagedEnterpriseBinding? binding;
  List<ManagedEnrollmentIntent> intents = const [];
  List<Json> subjects = const [];
  String? nextCursor, subjectCursor;
  Object? error;
  bool loading = true, busy = false, moreSubjects = false;
  int generation = 0;
  ModalRoute<dynamic>? issuedRoute;

  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.tenant?['id'] == tenantId &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role &&
      widget.session.canOpen('managed-android');
  bool get writable => role == 'OWNER' || role == 'ORG_ADMIN';

  @override
  void initState() {
    super.initState();
    tenantId = widget.session.tenant!['id'] as String;
    actor = widget.session.profile!['subject'] as String;
    role = widget.session.role;
    repository = ManagedAndroidRepository(
        api: widget.session.api, tenantId: tenantId, current: () => current);
    widget.session.addListener(_accessChanged);
    _load();
  }

  void _accessChanged() {
    if (!current) {
      generation++;
      _closeIssued();
      if (mounted) {
        setState(() {
          binding = null;
          intents = const [];
          subjects = const [];
          error = const ApiFailure(409, 'WORKSPACE_CHANGED');
        });
      }
    }
  }

  @override
  void dispose() {
    generation++;
    _closeIssued();
    widget.session.removeListener(_accessChanged);
    super.dispose();
  }

  void _closeIssued() {
    final route = issuedRoute;
    issuedRoute = null;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive && route.navigator?.mounted == true) {
        route.navigator!.removeRoute(route);
      }
    });
  }

  Future<void> _load() async {
    if (!current) return;
    final ticket = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final results =
          await Future.wait([repository.binding(), repository.intents()]);
      if (!current || ticket != generation) return;
      final page = results[1] as ManagedEnrollmentPageResult;
      setState(() {
        binding = results[0] as ManagedEnterpriseBinding?;
        intents = page.items;
        nextCursor = page.nextCursor;
      });
    } catch (failure) {
      if (current && ticket == generation) setState(() => error = failure);
    } finally {
      if (current && ticket == generation) setState(() => loading = false);
    }
  }

  Future<void> _moreIntents() async {
    final cursor = nextCursor;
    if (!current || cursor == null || busy) return;
    setState(() => busy = true);
    try {
      final page = await repository.intents(cursor: cursor);
      if (!current) return;
      if (page.items.any((item) => intents.any((old) => old.id == item.id))) {
        throw const ApiFailure(502, 'INVALID_MANAGED_ANDROID_RESPONSE');
      }
      setState(() {
        intents = List.unmodifiable([...intents, ...page.items]);
        nextCursor = page.nextCursor;
      });
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> _loadSubjects({bool more = false}) async {
    if (!current || (more && (subjectCursor == null || moreSubjects))) return;
    setState(() => moreSubjects = true);
    try {
      final page = await widget.session.api.page('/tenants/$tenantId/subjects',
          cursor: more ? subjectCursor : null);
      if (!current) return;
      final rows = page.items
          .where((row) => row['id'] is String && row['nickname'] is String)
          .toList();
      if (rows.length != page.items.length) {
        throw const ApiFailure(502, 'INVALID_MANAGED_ANDROID_RESPONSE');
      }
      setState(() {
        subjects = List.unmodifiable(more ? [...subjects, ...rows] : rows);
        subjectCursor = page.nextCursor;
      });
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (current) setState(() => moreSubjects = false);
    }
  }

  Future<void> _propose() async {
    final enterprise = TextEditingController();
    final contract = TextEditingController();
    try {
      final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('申请绑定机构企业资源'),
                content: SizedBox(
                    width: 480,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Notice('请填写已核对权属的企业资源 ID 和已生效机构合同编号。申请后仍需独立平台审核。'),
                      const SizedBox(height: 16),
                      TextField(
                          controller: enterprise,
                          maxLength: 128,
                          decoration:
                              const InputDecoration(labelText: '企业资源 ID')),
                      TextField(
                          controller: contract,
                          maxLength: 200,
                          decoration: const InputDecoration(labelText: '合同编号'))
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('提交审核'))
                ],
              ));
      if (accepted != true || !current) return;
      setState(() => busy = true);
      try {
        await repository.propose(enterprise.text.trim(), contract.text.trim());
        await _load();
      } catch (failure) {
        if (current) setState(() => error = failure);
      } finally {
        if (current) setState(() => busy = false);
      }
    } finally {
      enterprise.dispose();
      contract.dispose();
    }
  }

  Future<void> _issue() async {
    if (subjects.isEmpty) await _loadSubjects();
    if (!mounted || !current || subjects.isEmpty) return;
    String? selected;
    final subjectId = await showDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: const Text('创建 5 分钟注册材料'),
                  content: SizedBox(
                      width: 480,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Notice('仅用于机构配发并已准备重置的设备。注册资料只显示一次；丢失后需取消并重新创建。',
                            warning: true),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '关联儿童档案'),
                            value: selected,
                            items: subjects
                                .map((row) => DropdownMenuItem<String>(
                                    value: row['id'] as String,
                                    child: Text(row['nickname'] as String,
                                        overflow: TextOverflow.ellipsis)))
                                .toList(),
                            onChanged: (value) =>
                                update(() => selected = value)),
                        if (subjectCursor != null)
                          TextButton(
                              onPressed: () async {
                                await _loadSubjects(more: true);
                                if (context.mounted) update(() {});
                              },
                              child: const Text('加载更多档案'))
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: selected == null
                            ? null
                            : () => Navigator.pop(context, selected),
                        child: const Text('创建'))
                  ],
                )));
    if (subjectId == null || !current) return;
    setState(() => busy = true);
    try {
      final issued = await repository.issue(subjectId);
      if (!current) return;
      await _showIssued(issued);
      if (current) await _load();
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> _showIssued(ManagedEnrollmentIssued issued) async {
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          issuedRoute = ModalRoute.of(context);
          return AlertDialog(
            title: const Text('一次性注册资料'),
            content: SizedBox(
                width: 560,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Notice(
                      '此窗口关闭后无法再次查看。二维码仅在本机生成，不上传至二维码服务。请在五分钟内用待注册设备扫描。'),
                  const SizedBox(height: 16),
                  Center(
                      child: QrImageView(
                          data: issued.qrCode,
                          version: QrVersions.auto,
                          size: 280,
                          backgroundColor: Colors.white,
                          errorStateBuilder: (context, error) => const Notice(
                              '二维码载荷超出可显示范围。可复制注册数据，并使用机构批准的本地离线工具处理。',
                              warning: true))),
                  const SizedBox(height: 12),
                  Text('到期：${dateLabel(issued.intent.expiresAt)}',
                      style: const TextStyle(color: muted))
                ])),
            actions: [
              TextButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: issued.qrCode)),
                  icon: const Icon(Icons.copy),
                  label: const Text('复制注册数据')),
              FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('已保存，关闭'))
            ],
          );
        });
    issuedRoute = null;
  }

  Future<void> _verify(ManagedEnrollmentIntent intent) async {
    final device = TextEditingController();
    try {
      final id = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('核对提供方设备'),
                content: SizedBox(
                    width: 480,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Notice(
                          '仅核对 Android Enterprise 设备注册证据。此操作不会让本地儿童 App 自动获得系统级管控能力。'),
                      const SizedBox(height: 16),
                      TextField(
                          controller: device,
                          maxLength: 128,
                          decoration:
                              const InputDecoration(labelText: '提供方设备 ID'))
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, device.text.trim()),
                      child: const Text('核对'))
                ],
              ));
      if (id == null || !current) return;
      setState(() => busy = true);
      try {
        await repository.verify(intent, id);
        await _load();
      } catch (failure) {
        if (current) setState(() => error = failure);
      } finally {
        if (current) setState(() => busy = false);
      }
    } finally {
      device.dispose();
    }
  }

  Future<void> _cancel(ManagedEnrollmentIntent intent) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('取消注册资料？'),
              content: const Text('提交后会撤销提供方注册令牌；若提供方暂时不可用，状态会显示“待清理”。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('返回')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('确认取消'))
              ],
            ));
    if (confirmed != true || !current) return;
    setState(() => busy = true);
    try {
      await repository.cancel(intent);
      await _load();
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeading('机构受管 Android', '审核企业归属，发放短时注册资料，核对提供方设备证据。',
            action: OutlinedButton.icon(
                onPressed: busy || loading || !current ? null : _load,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新状态'))),
        const Notice('企业绑定与注册核对不等于本地设备已受管。系统级应用限制仍需合规 EMM、真实设备绑定和策略执行回执。',
            warning: true),
        const SizedBox(height: 16),
        if (loading) const LinearProgressIndicator(),
        if (error != null) ...[
          FailureView(error!,
              retry: current ? _load : null,
              reauth: () => widget.session.login(stepUp: true)),
          const SizedBox(height: 16)
        ],
        Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('企业资源绑定', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          if (binding == null) ...[
            const Text('尚未提交企业资源绑定申请。'),
            if (writable) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                  onPressed: busy || loading ? null : _propose,
                  icon: const Icon(Icons.add),
                  label: const Text('申请绑定'))
            ]
          ] else ...[
            Wrap(spacing: 12, runSpacing: 8, children: [
              Chip(
                  label: Text(switch (binding!.state) {
                    'PENDING' => '待平台审核',
                    'ACTIVE' => '企业已审核',
                    _ => '绑定已撤销'
                  }),
                  visualDensity: VisualDensity.compact),
              Text(binding!.providerDisplayName ?? binding!.enterpriseId),
              Text('合同 ${binding!.contractReference}')
            ]),
            const SizedBox(height: 8),
            Text(
                binding!.state == 'PENDING'
                    ? '等待平台独立审核企业权属和机构合同。'
                    : binding!.state == 'ACTIVE'
                        ? '企业资源已审核，可在合规提供方启用后创建短时注册资料。'
                        : '企业绑定已撤销；已注册设备的退管需另行完成。',
                style: const TextStyle(color: muted))
          ]
        ])),
        const SizedBox(height: 16),
        Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 12,
              children: [
                Text('设备注册进度', style: Theme.of(context).textTheme.titleMedium),
                if (writable && binding?.state == 'ACTIVE')
                  FilledButton.icon(
                      onPressed: busy || loading ? null : _issue,
                      icon: const Icon(Icons.add),
                      label: const Text('创建注册资料'))
              ]),
          const SizedBox(height: 16),
          if (!loading && intents.isEmpty)
            const EmptyView('暂无受管注册记录', '完成机构企业绑定审核后可发放短时注册资料。'),
          for (final intent in intents) ...[
            const Divider(),
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      StatusTag(intent.state),
                      Text('档案 ${intent.subjectId}',
                          style: const TextStyle(fontSize: 13)),
                      Text('到期 ${dateLabel(intent.expiresAt)}',
                          style: const TextStyle(color: muted)),
                      if (intent.providerDeviceId != null)
                        Text('提供方设备 ${intent.providerDeviceId}'),
                      if (writable && intent.canVerify)
                        TextButton(
                            onPressed: busy ? null : () => _verify(intent),
                            child: const Text('核对设备')),
                      if (writable && intent.canCancel)
                        TextButton(
                            onPressed: busy ? null : () => _cancel(intent),
                            child: const Text('取消令牌'))
                    ]))
          ],
          if (nextCursor != null)
            TextButton(
                onPressed: busy ? null : _moreIntents,
                child: const Text('加载更多')),
          if (intents.any((intent) => intent.state == 'VERIFIED')) ...[
            const SizedBox(height: 12),
            const Notice('“已核对”只表示提供方注册身份吻合；本地设备、应用限制与执行状态仍需分别核验。')
          ]
        ]))
      ]);
}
