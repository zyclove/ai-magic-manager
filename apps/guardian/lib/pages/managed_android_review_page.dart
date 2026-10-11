import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/managed_android.dart';
import '../core/managed_android_repository.dart';
import '../core/session.dart';
import '../ui/design.dart';

/// Platform-only, independent enterprise binding review surface.
class ManagedAndroidReviewPage extends StatefulWidget {
  final Session session;
  const ManagedAndroidReviewPage({super.key, required this.session});

  @override
  State<ManagedAndroidReviewPage> createState() =>
      _ManagedAndroidReviewPageState();
}

class _ManagedAndroidReviewPageState extends State<ManagedAndroidReviewPage> {
  late final String actor;
  late final ManagedAndroidReviewRepository repository;
  final lookup = TextEditingController();
  List<ManagedEnterpriseReview> pending = const [];
  ManagedEnterpriseReview? selected;
  String? nextCursor;
  Object? error;
  bool loading = true, busy = false;
  int generation = 0;

  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.profile?['subject'] == actor &&
      widget.session.canOpen('managed-android-review');

  @override
  void initState() {
    super.initState();
    actor = widget.session.profile!['subject'] as String;
    repository = ManagedAndroidReviewRepository(
        api: widget.session.api, current: () => current);
    widget.session.addListener(_accessChanged);
    _loadPending();
  }

  void _accessChanged() {
    if (!current && mounted) {
      generation++;
      setState(() {
        pending = const [];
        selected = null;
        nextCursor = null;
        error = const ApiFailure(403, 'SCOPE_DENIED');
      });
    }
  }

  @override
  void dispose() {
    generation++;
    widget.session.removeListener(_accessChanged);
    lookup.dispose();
    super.dispose();
  }

  Future<void> _loadPending({bool more = false}) async {
    if (!current || (more && (nextCursor == null || busy))) return;
    final ticket = ++generation;
    setState(() {
      if (more) {
        busy = true;
      } else {
        loading = true;
      }
      error = null;
    });
    try {
      final page = await repository.pending(cursor: more ? nextCursor : null);
      if (!current || ticket != generation) return;
      if (more &&
          page.items.any(
              (item) => pending.any((old) => old.tenantId == item.tenantId))) {
        throw const ApiFailure(502, 'INVALID_MANAGED_ANDROID_RESPONSE');
      }
      setState(() {
        pending =
            List.unmodifiable(more ? [...pending, ...page.items] : page.items);
        nextCursor = page.nextCursor;
      });
    } catch (failure) {
      if (current && ticket == generation) setState(() => error = failure);
    } finally {
      if (current && ticket == generation) {
        setState(() {
          loading = false;
          busy = false;
        });
      }
    }
  }

  Future<void> _open(String tenantId) async {
    if (!current) return;
    if (!isManagedTenantId(tenantId)) {
      setState(() => error = const ApiFailure(400, 'INVALID_TENANT_ID'));
      return;
    }
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = null;
      selected = null;
    });
    try {
      final result = await repository.get(tenantId);
      if (current && ticket == generation) setState(() => selected = result);
    } catch (failure) {
      if (current && ticket == generation) setState(() => error = failure);
    } finally {
      if (current && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> _act(ManagedEnterpriseReview review, bool approve) async {
    if (!current ||
        busy ||
        (approve &&
            (review.state != 'PENDING' || review.requestedBy == actor)) ||
        (!approve && review.state != 'ACTIVE')) return;
    final evidence = TextEditingController();
    final reason = TextEditingController();
    try {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(approve ? '独立审核企业绑定' : '撤销企业绑定'),
                content: SizedBox(
                    width: 520,
                    child: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      Notice(
                          approve
                              ? '请先在线下核对机构合同、企业权属证明和提供方资源。提供方可读不代表客户所有权。'
                              : '撤销会阻止新的受管操作，不会自动解除已经注册的设备系统管理。',
                          warning: true),
                      const SizedBox(height: 16),
                      if (approve) ...[
                        TextField(
                            controller: evidence,
                            maxLength: 200,
                            decoration: const InputDecoration(
                                labelText: '权属证明索引',
                                helperText: '填写已核验的外部证据编号，不粘贴原始证件或密钥')),
                        const SizedBox(height: 8)
                      ],
                      TextField(
                          controller: reason,
                          minLines: 2,
                          maxLines: 4,
                          maxLength: 500,
                          decoration: InputDecoration(
                              labelText: approve ? '审核理由' : '撤销理由'))
                    ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('返回')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(approve ? '确认批准' : '确认撤销'))
                ],
              ));
      if (confirmed != true || !current) return;
      final explanation = reason.text.trim();
      final proof = evidence.text.trim();
      if (explanation.length < 5 ||
          explanation.length > 500 ||
          (approve && (proof.length < 8 || proof.length > 200))) {
        setState(() => error = ApiFailure(
            400,
            approve && (proof.length < 8 || proof.length > 200)
                ? 'INVALID_OWNERSHIP_EVIDENCE'
                : 'INVALID_BINDING_REASON'));
        return;
      }
      setState(() => busy = true);
      try {
        final result = approve
            ? await repository.approve(review, proof, explanation)
            : await repository.revoke(review, explanation);
        if (!current) return;
        setState(() => selected = result);
        await _loadPending();
      } catch (failure) {
        if (current) setState(() => error = failure);
      } finally {
        if (current) setState(() => busy = false);
      }
    } finally {
      evidence.dispose();
      reason.dispose();
    }
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeading('受管 Android 企业审核', '独立核实机构合同与企业权属后，决定是否允许设备注册。',
            action: OutlinedButton.icon(
                onPressed: busy || loading || !current ? null : _loadPending,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新待审核'))),
        const Notice('审核通过只建立机构与提供方企业资源的绑定。设备注册、儿童 App 身份和应用策略执行仍须分别核验。'),
        const SizedBox(height: 16),
        if (loading) const LinearProgressIndicator(),
        if (error != null) ...[
          FailureView(error!,
              retry: current ? _loadPending : null,
              reauth: () => widget.session.login(stepUp: true)),
          const SizedBox(height: 16)
        ],
        Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('待审核队列', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          if (!loading && pending.isEmpty)
            const EmptyView('暂无待审核申请', '可通过机构工作空间 ID 查询已批准或已撤销记录。'),
          for (final item in pending) ...[
            const Divider(),
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(item.enterpriseId,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text('机构 ${item.tenantId}',
                          style: const TextStyle(color: muted)),
                      Text('合同 ${item.contractReference}'),
                      TextButton(
                          onPressed: busy ? null : () => _open(item.tenantId),
                          child: const Text('查看审核'))
                    ]))
          ],
          if (nextCursor != null)
            TextButton(
                onPressed: busy ? null : () => _loadPending(more: true),
                child: const Text('加载更多'))
        ])),
        const SizedBox(height: 16),
        Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('按机构查询', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                    width: 340,
                    child: TextField(
                        controller: lookup,
                        maxLength: 36,
                        decoration:
                            const InputDecoration(labelText: '机构工作空间 ID'))),
                OutlinedButton(
                    onPressed: busy || !current
                        ? null
                        : () => _open(lookup.text.trim()),
                    child: const Text('查询'))
              ]),
          if (selected != null) ...[
            const Divider(),
            const SizedBox(height: 12),
            Wrap(spacing: 16, runSpacing: 10, children: [
              Chip(
                  label: Text(switch (selected!.state) {
                'PENDING' => '待平台审核',
                'ACTIVE' => '企业已审核',
                _ => '绑定已撤销'
              })),
              Text('企业 ${selected!.enterpriseId}'),
              Text('合同 ${selected!.contractReference}'),
              Text('申请人 ${selected!.requestedBy}'),
              Text('申请时间 ${dateLabel(selected!.createdAt)}')
            ]),
            if (selected!.approvedBy != null) ...[
              const SizedBox(height: 10),
              Text(
                  '审核人 ${selected!.approvedBy} · 证据索引 ${selected!.ownershipEvidenceReference}',
                  style: const TextStyle(color: muted))
            ],
            const SizedBox(height: 16),
            if (selected!.state == 'PENDING' && selected!.requestedBy != actor)
              FilledButton.icon(
                  onPressed: busy ? null : () => _act(selected!, true),
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('核实并批准')),
            if (selected!.state == 'PENDING' && selected!.requestedBy == actor)
              const Notice('申请人不能审批自己的企业绑定，请由独立审核员处理。', warning: true),
            if (selected!.state == 'ACTIVE')
              OutlinedButton.icon(
                  onPressed: busy ? null : () => _act(selected!, false),
                  icon: const Icon(Icons.block_outlined),
                  label: const Text('撤销绑定'))
          ]
        ]))
      ]);
}
