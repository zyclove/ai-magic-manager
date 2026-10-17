import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/managed_android.dart';
import '../core/managed_android_repository.dart';
import '../core/managed_agent_binding_repository.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/managed_enrollment_guide.dart';
import '../ui/managed_enrollment_form.dart';
import '../ui/managed_agent_binding_dialog.dart';
import 'managed_execution_dialog_entry.dart';

/// Institution provisioning console. A provider receipt never changes local device capabilities.
class ManagedAndroidPage extends StatefulWidget {
  final Session session;
  const ManagedAndroidPage({super.key, required this.session});

  @override
  State<ManagedAndroidPage> createState() => _ManagedAndroidPageState();
}

class _ManagedAndroidPageState extends State<ManagedAndroidPage> {
  late final String tenantId, actor, role;
  late final int scopeGeneration;
  late final ManagedAndroidRepository repository;
  ManagedEnterpriseBinding? binding;
  ManagedProvisioningReadiness? readiness;
  ManagedCapacitySnapshot? capacity;
  List<ManagedEnrollmentIntent> intents = const [];
  final providerStatuses = <String, ManagedProviderStatus>{};
  List<Json> subjects = const [];
  String? nextCursor, subjectCursor;
  Object? error;
  bool loading = true, busy = false, moreSubjects = false;
  String? checkingIntentId;
  int generation = 0;
  ModalRoute<dynamic>? issuedRoute;
  bool dialogOpen = false;

  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.scopeGeneration == scopeGeneration &&
      widget.session.tenant?['id'] == tenantId &&
      widget.session.profile?['subject'] == actor &&
      widget.session.role == role &&
      widget.session.canOpen('managed-android');
  bool get writable => role == 'OWNER' || role == 'ORG_ADMIN';
  bool get canIssue =>
      readiness?.canIssueEnrollment == true &&
      (capacity?.availableForNew ?? 0) > 0;

  @override
  void initState() {
    super.initState();
    tenantId = widget.session.tenant!['id'] as String;
    actor = widget.session.profile!['subject'] as String;
    role = widget.session.role;
    scopeGeneration = widget.session.scopeGeneration;
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
          readiness = null;
          capacity = null;
          intents = const [];
          providerStatuses.clear();
          subjects = const [];
          checkingIntentId = null;
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

  /// All enrollment dialogs belong to the originating workspace, including forms.
  Future<T?> _prompt<T>(
      {required WidgetBuilder builder, bool barrierDismissible = true}) async {
    if (!current || dialogOpen) return null;
    dialogOpen = true;
    try {
      return await showDialog<T>(
          context: context,
          barrierDismissible: barrierDismissible,
          builder: (dialogContext) {
            issuedRoute = ModalRoute.of(dialogContext);
            return builder(dialogContext);
          });
    } finally {
      issuedRoute = null;
      dialogOpen = false;
    }
  }

  Future<void> _load() async {
    if (!current) return;
    final ticket = ++generation;
    setState(() {
      loading = true;
      error = null;
      checkingIntentId = null;
    });
    try {
      final results = await Future.wait([
        repository.binding(),
        repository.intents(),
        repository.readiness(),
        repository.capacity()
      ]);
      if (!current || ticket != generation) return;
      final page = results[1] as ManagedEnrollmentPageResult;
      setState(() {
        binding = results[0] as ManagedEnterpriseBinding?;
        intents = page.items;
        readiness = results[2] as ManagedProvisioningReadiness;
        capacity = results[3] as ManagedCapacitySnapshot;
        providerStatuses.clear();
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
    if (!current || cursor == null || busy || loading || error != null) return;
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
    if (!current || moreSubjects || (more && subjectCursor == null)) return;
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
    if (!current || !writable || busy || loading || error != null) return;
    final input = await _prompt<({String id, String contract})>(
        builder: (_) => const ManagedEnrollmentForm(binding: true));
    if (input == null || !current) return;
    setState(() => busy = true);
    try {
      await repository.propose(input.id, input.contract);
      await _load();
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> _issue() async {
    if (!current ||
        !writable ||
        busy ||
        loading ||
        moreSubjects ||
        dialogOpen ||
        error != null ||
        !canIssue) {
      return;
    }
    if (subjects.isEmpty) await _loadSubjects();
    if (!mounted || !current || error != null) return;
    if (subjects.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在“儿童 / 学生档案”中创建档案，再接入设备。')));
      return;
    }
    String? selected;
    final subjectId = await _prompt<String>(
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  scrollable: true,
                  title: const Text('选择要接入设备的学生'),
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
                        child: const Text('生成一次性二维码'))
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
    await _prompt<void>(
        barrierDismissible: false,
        builder: (context) {
          final qrSize = (MediaQuery.sizeOf(context).width - 128)
              .clamp(120, 280)
              .toDouble();
          return AlertDialog(
            scrollable: true,
            title: const Text('扫描二维码完成注册'),
            content: SizedBox(
                width: 560,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Notice(
                      '此窗口关闭后无法再次查看。二维码仅在本机生成，不上传至二维码服务。请在五分钟内用待注册设备扫描。'),
                  const SizedBox(height: 16),
                  Center(
                      child: SizedBox.square(
                          dimension: qrSize,
                          child: QrImageView(
                              data: issued.qrCode,
                              version: QrVersions.auto,
                              size: qrSize,
                              backgroundColor: Colors.white,
                              errorStateBuilder: (context, error) =>
                                  const Notice(
                                      '二维码载荷超出可显示范围。可复制注册数据，并使用机构批准的本地离线工具处理。',
                                      warning: true)))),
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
                  child: const Text('关闭资料窗口'))
            ],
          );
        });
    issuedRoute = null;
  }

  Future<void> _verify(ManagedEnrollmentIntent intent) async {
    if (!current || !writable || busy || loading || error != null) return;
    final input = await _prompt<({String id, String contract})>(
        builder: (_) => const ManagedEnrollmentForm(binding: false));
    if (input == null || !current) return;
    setState(() => busy = true);
    try {
      await repository.verify(intent, input.id);
      await _load();
    } catch (failure) {
      if (current) setState(() => error = failure);
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> _cancel(ManagedEnrollmentIntent intent) async {
    if (!current || !writable || busy || loading || error != null) return;
    final confirmed = await _prompt<bool>(
        builder: (context) => AlertDialog(
              scrollable: true,
              title: const Text('取消注册资料？'),
              content: const Text('提交后会撤销提供方注册令牌；若提供方暂时不可用，状态会显示“待清理”。'
                  '令牌已取消也不能证明没有设备在取消前完成注册，合同名额需另行核对。'),
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

  Future<void> _checkProvider(ManagedEnrollmentIntent intent) async {
    if (!current ||
        busy ||
        loading ||
        error != null ||
        checkingIntentId != null ||
        intent.state != 'VERIFIED') {
      return;
    }
    final ticket = generation;
    setState(() {
      checkingIntentId = intent.id;
      providerStatuses.remove(intent.id);
      error = null;
    });
    try {
      final status = await repository.providerStatus(intent);
      if (current &&
          ticket == generation &&
          intents.any(
              (row) => row.id == intent.id && row.version == intent.version)) {
        setState(() => providerStatuses[intent.id] = status);
      }
    } catch (failure) {
      if (current && ticket == generation) setState(() => error = failure);
    } finally {
      if (current && ticket == generation) {
        setState(() => checkingIntentId = null);
      }
    }
  }

  Future<void> _agentBinding(ManagedEnrollmentIntent intent) async {
    if (!current ||
        busy ||
        loading ||
        error != null ||
        intent.state != 'VERIFIED') return;
    await _prompt<void>(
        barrierDismissible: false,
        builder: (bindingContext) => ManagedAgentBindingDialog(
            repository: ManagedAgentBindingRepository(
                api: widget.session.api,
                tenantId: tenantId,
                enrollmentId: intent.id,
                subjectId: intent.subjectId,
                current: () => current),
            writable: writable,
            onExecutions: (association) => openManagedExecutions(
                bindingContext, widget.session,
                deviceId: association.deviceId,
                registrationId: association.registrationId,
                deviceName: '已关联的儿童端设备',
                readOnly: true,
                current: () => current && bindingContext.mounted),
            reauthenticate: () => widget.session.login(stepUp: true)));
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeading('机构受管 Android', '审核企业归属，发放短时注册资料，核对提供方设备证据。',
            action: OutlinedButton.icon(
                onPressed: busy || loading || !current ? null : _load,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新状态'))),
        if (loading) const LinearProgressIndicator(),
        if (error != null) ...[
          FailureView(error!,
              retry: current ? _load : null,
              reauth: () => widget.session.login(stepUp: true)),
          const SizedBox(height: 16),
        ],
        if (readiness != null && capacity != null) ...[
          ManagedEnrollmentGuide(
              binding: binding,
              readiness: readiness!,
              capacity: capacity!,
              writable: writable,
              enabled: current && !busy && !loading && error == null,
              onPropose: _propose,
              onIssue: _issue),
          const SizedBox(height: 16),
        ],
        if (capacity case final seats?) ...[
          Panel(
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                  title: Text(
                      '可新增 ${seats.availableForNew} 台 · 合同名额 ${seats.paidCapacity} 台'),
                  subtitle: Text(
                      '已核对 ${seats.verifiedDevices} · 预留 / 待核对 ${seats.reservedIntents}'),
                  initiallyExpanded: seats.overCapacity ||
                      seats.availableForNew == 0 ||
                      seats.expiredUnresolvedIntents > 0 ||
                      seats.cancelledUnreconciledIntents > 0,
                  childrenPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '合同名额 ${seats.paidCapacity} · 已核对 ${seats.verifiedDevices} · '
                        '预留/待核对 ${seats.reservedIntents} · 可新增 ${seats.availableForNew}'),
                    const SizedBox(height: 12),
                    Text(
                        '统计时间 ${dateLabel(seats.evaluatedAt)}。待处理注册资料会预留名额；'
                        '离线、令牌到期、取消令牌或合同降级都不能单独证明设备已退管。',
                        style: const TextStyle(color: muted)),
                    if (seats.expiredUnresolvedIntents > 0) ...[
                      const SizedBox(height: 12),
                      Notice(
                          '有 ${seats.expiredUnresolvedIntents} 份已到期但未完成清理的注册资料，'
                          '仍占用名额。请核对提供方并完成取消。',
                          warning: true)
                    ],
                    if (seats.cancelledUnreconciledIntents > 0) ...[
                      const SizedBox(height: 12),
                      Notice(
                          '有 ${seats.cancelledUnreconciledIntents} 份令牌已取消，'
                          '仍需核对提供方没有关联设备，名额暂不释放。',
                          warning: true)
                    ],
                    if (seats.overCapacity || seats.availableForNew == 0) ...[
                      const SizedBox(height: 12),
                      Notice(
                          seats.overCapacity
                              ? '当前占用超过有效合同名额，已暂停新增；现有儿童安全规则不会自动解除。'
                              : '当前没有可新增名额。请先处理待清理注册资料或核对机构合同。',
                          warning: true)
                    ]
                  ])),
          const SizedBox(height: 16)
        ],
        Panel(
            padding: EdgeInsets.zero,
            child: ExpansionTile(
                title: const Text('机构资格与接入详情'),
                subtitle: Text(binding == null
                    ? '尚未申请'
                    : binding!.state == 'ACTIVE'
                        ? '机构已审核'
                        : binding!.state == 'PENDING'
                            ? '等待平台审核'
                            : '绑定已撤销'),
                childrenPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (readiness case final state?) ...[
                    Text(
                        '目标地区 ${state.targetCountryCode} · 提供方 ${label(state.provider)}'),
                    const SizedBox(height: 8),
                    Text(readinessExplanation(state.reasonCode)),
                    const SizedBox(height: 12),
                  ],
                  if (binding == null) ...[
                    const Text('尚未提交企业资源绑定申请。'),
                  ] else ...[
                    Wrap(spacing: 12, runSpacing: 8, children: [
                      Chip(
                          label: Text(switch (binding!.state) {
                            'PENDING' => '待平台审核',
                            'ACTIVE' => '企业已审核',
                            _ => '绑定已撤销'
                          }),
                          visualDensity: VisualDensity.compact),
                      Text(binding!.providerDisplayName ??
                          binding!.enterpriseId),
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
          Text('设备注册记录', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          if (!loading && intents.isEmpty)
            const EmptyView('还没有设备注册记录', '请先按上方“下一步”完成机构接入条件。'),
          for (final intent in intents) ...[
            const Divider(),
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Chip(
                          label: Text(
                              enrollmentInstruction(intent, DateTime.now())
                                  .title)),
                      Text('档案 ${intent.subjectId}',
                          style: const TextStyle(fontSize: 13)),
                      Text('到期 ${dateLabel(intent.expiresAt)}',
                          style: const TextStyle(color: muted)),
                      if (intent.providerDeviceId != null)
                        Text('提供方设备 ${intent.providerDeviceId}'),
                      if (writable && intent.canVerify)
                        TextButton(
                            onPressed:
                                busy || loading || !current || error != null
                                    ? null
                                    : () => _verify(intent),
                            child: const Text('核对设备')),
                      if (writable && intent.canCancel)
                        TextButton(
                            onPressed:
                                busy || loading || !current || error != null
                                    ? null
                                    : () => _cancel(intent),
                            child: const Text('取消令牌')),
                      if (intent.state == 'VERIFIED')
                        TextButton.icon(
                            onPressed:
                                busy || loading || !current || error != null
                                    ? null
                                    : () => _agentBinding(intent),
                            icon: const Icon(Icons.phonelink_setup),
                            label: Text(writable ? '关联儿童端' : '查看儿童端关联')),
                      if (intent.state == 'VERIFIED')
                        TextButton.icon(
                            onPressed: busy ||
                                    loading ||
                                    !current ||
                                    error != null ||
                                    checkingIntentId != null
                                ? null
                                : () => _checkProvider(intent),
                            icon: const Icon(Icons.fact_check_outlined),
                            label: const Text('实时复核提供方'))
                    ])),
            Text(enrollmentInstruction(intent, DateTime.now()).detail,
                style: const TextStyle(color: muted)),
            const SizedBox(height: 12),
            if (checkingIntentId == intent.id) const LinearProgressIndicator(),
            if (providerStatuses[intent.id] case final status?)
              Notice(
                  '本次提供方读取：${switch (status.state) {
                    'APPLIED' => '初始安全策略已报告应用',
                    'NON_COMPLIANT' => '提供方报告不合规',
                    'DRIFT' => '提供方策略已偏离初始版本',
                    'STALE' => '提供方报告已过期',
                    _ => '执行尚未确认'
                  }}。读取时间 ${dateLabel(status.checkedAt)}；最近策略同步 ${dateLabel(status.lastPolicySyncAt)}。儿童端身份关联请单独查看关联记录；本项只复核提供方初始策略。',
                  warning: status.state != 'APPLIED')
          ],
          if (nextCursor != null)
            TextButton(
                onPressed: busy || loading || !current || error != null
                    ? null
                    : _moreIntents,
                child: const Text('加载更多')),
          if (intents.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Notice(
                '令牌到期或取消后，若设备此前已注册，仍可凭提供方设备 ID 补做核对；这类名额不会仅因删除令牌而释放。“已核对”只表示提供方注册身份吻合；本地设备、应用限制与执行状态仍需分别核验。')
          ]
        ]))
      ]);
}
