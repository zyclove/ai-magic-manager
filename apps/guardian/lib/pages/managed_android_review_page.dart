import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
  late Session observedSession;
  late _ReviewScope scope;
  final lookup = TextEditingController();
  List<ManagedEnterpriseReview> pending = const [];
  ManagedEnterpriseReview? selected;
  String? nextCursor, failedPendingCursor, failedLookup, actionTarget;
  Object? pendingError, lookupError, actionError, accessError;
  bool pendingLoaded = false, failedPendingMore = false;
  bool loading = false, loadingMore = false, lookupBusy = false, busy = false;
  int pendingGeneration = 0, lookupGeneration = 0, actionGeneration = 0;
  GlobalKey<_ReviewActionDialogState>? activeDialog;

  String get actor => scope.actor;
  bool get current => _currentScope(scope);

  bool _currentScope(_ReviewScope captured) =>
      mounted &&
      identical(scope, captured) &&
      captured.allowed &&
      identical(widget.session, captured.session) &&
      captured.session.authenticated &&
      captured.session.profile?['subject'] == captured.actor &&
      captured.session.role == captured.role &&
      captured.session.scopeGeneration == captured.generation &&
      captured.session.canOpen('managed-android-review');

  ManagedAndroidReviewRepository _repository(
          _ReviewScope captured, bool Function() ticketCurrent) =>
      ManagedAndroidReviewRepository(
          api: captured.session.api,
          current: () => _currentScope(captured) && ticketCurrent());

  @override
  void initState() {
    super.initState();
    observedSession = widget.session;
    scope = _ReviewScope.capture(observedSession);
    observedSession.addListener(_accessChanged);
    if (current) {
      _loadPending();
    } else {
      accessError = const ApiFailure(403, 'SCOPE_DENIED');
    }
  }

  @override
  void didUpdateWidget(covariant ManagedAndroidReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(observedSession, widget.session)) {
      observedSession.removeListener(_accessChanged);
      observedSession = widget.session;
      observedSession.addListener(_accessChanged);
    }
    _accessChanged();
  }

  void _clearReads() {
    pendingGeneration++;
    lookupGeneration++;
    pending = const [];
    selected = null;
    nextCursor = null;
    failedPendingCursor = null;
    failedLookup = null;
    pendingLoaded = false;
    failedPendingMore = false;
    pendingError = null;
    lookupError = null;
    loading = false;
    loadingMore = false;
    lookupBusy = false;
  }

  void _accessChanged() {
    if (!mounted) return;
    final next = _ReviewScope.capture(widget.session);
    if (scope.sameContext(next)) return;
    actionGeneration++;
    setState(() {
      scope = next;
      _clearReads();
      busy = false;
      actionError = null;
      actionTarget = null;
      accessError = next.allowed ? null : const ApiFailure(403, 'SCOPE_DENIED');
      lookup.clear();
    });
    activeDialog?.currentState?.invalidate();
    // 新会话有权限时重新读取；旧请求仍受各自不可变 scope/ticket 约束。
    if (current) _loadPending();
  }

  @override
  void dispose() {
    pendingGeneration++;
    lookupGeneration++;
    actionGeneration++;
    activeDialog?.currentState?.invalidate();
    observedSession.removeListener(_accessChanged);
    lookup.dispose();
    super.dispose();
  }

  Future<void> _loadPending(
      {bool more = false,
      String? retryCursor,
      bool afterAction = false}) async {
    if (!current || loading || loadingMore || (busy && !afterAction)) return;
    final cursor = more ? retryCursor ?? nextCursor : null;
    if (more && cursor == null) return;
    final captured = scope;
    final ticket = ++pendingGeneration;
    bool active() => _currentScope(captured) && ticket == pendingGeneration;
    final repository = _repository(captured, () => ticket == pendingGeneration);
    setState(() {
      loading = !more;
      loadingMore = more;
      pendingError = null;
      failedPendingCursor = null;
      failedPendingMore = false;
    });
    try {
      final page = await repository.pending(cursor: cursor);
      if (!active()) return;
      if (more &&
          page.items.any(
              (item) => pending.any((old) => old.tenantId == item.tenantId))) {
        throw const ApiFailure(502, 'INVALID_MANAGED_ANDROID_RESPONSE');
      }
      setState(() {
        pending =
            List.unmodifiable(more ? [...pending, ...page.items] : page.items);
        nextCursor = page.nextCursor;
        pendingLoaded = true;
      });
    } catch (failure) {
      if (active()) {
        setState(() {
          pendingError = failure;
          failedPendingCursor = cursor;
          failedPendingMore = more;
        });
      }
    } finally {
      if (active()) {
        setState(() {
          loading = false;
          loadingMore = false;
        });
      }
    }
  }

  void _retryPending() =>
      _loadPending(more: failedPendingMore, retryCursor: failedPendingCursor);

  Future<void> _open(String tenantId) async {
    if (!current || lookupBusy || busy) return;
    setState(() {
      lookupError = null;
      actionError = null;
      actionTarget = null;
      failedLookup = tenantId;
      selected = null;
    });
    if (!isManagedTenantId(tenantId)) {
      setState(() => lookupError = const ApiFailure(400, 'INVALID_TENANT_ID'));
      return;
    }
    final captured = scope;
    final ticket = ++lookupGeneration;
    bool active() => _currentScope(captured) && ticket == lookupGeneration;
    final repository = _repository(captured, () => ticket == lookupGeneration);
    setState(() => lookupBusy = true);
    try {
      final result = await repository.get(tenantId);
      if (active()) {
        setState(() {
          selected = result;
          failedLookup = null;
        });
      }
    } catch (failure) {
      if (active()) setState(() => lookupError = failure);
    } finally {
      if (active()) setState(() => lookupBusy = false);
    }
  }

  VoidCallback _readCallback(String tenantId) {
    final captured = scope;
    return () {
      if (_currentScope(captured)) _open(tenantId);
    };
  }

  VoidCallback _queryCallback() {
    final captured = scope;
    return () {
      if (_currentScope(captured)) _open(lookup.text.trim());
    };
  }

  VoidCallback _writeCallback(ManagedEnterpriseReview review, bool approve) {
    final captured = scope;
    return () {
      if (_currentScope(captured)) _act(review, approve);
    };
  }

  Future<void> _act(ManagedEnterpriseReview review, bool approve) async {
    if (!current ||
        busy ||
        lookupBusy ||
        (approve &&
            (review.state != 'PENDING' || review.requestedBy == actor)) ||
        (!approve && review.state != 'ACTIVE')) return;
    final captured = scope;
    final ticket = ++actionGeneration;
    bool active() => _currentScope(captured) && ticket == actionGeneration;
    final repository = _repository(captured, () => ticket == actionGeneration);
    final dialogKey = GlobalKey<_ReviewActionDialogState>();
    activeDialog = dialogKey;
    setState(() {
      busy = true;
      actionError = null;
      actionTarget = null;
    });
    try {
      final decision = await showDialog<_ReviewDecision>(
          context: context,
          builder: (context) => _ReviewActionDialog(
              key: dialogKey, approve: approve, current: active));
      if (decision == null || !active()) return;
      // 写入前失效所有旧读取，晚到的队列/详情不能覆盖审核后的状态。
      setState(_clearReads);
      final result = approve
          ? await repository.approve(review, decision.proof, decision.reason)
          : await repository.revoke(review, decision.reason);
      if (!active()) return;
      setState(() => selected = result);
      await _loadPending(afterAction: true);
    } catch (failure) {
      if (active()) {
        setState(() {
          selected = null;
          actionTarget = review.tenantId;
          actionError = failure;
        });
      }
    } finally {
      if (active()) setState(() => busy = false);
      if (identical(activeDialog, dialogKey)) activeDialog = null;
    }
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeading('受管 Android 企业审核', '独立核实机构合同与企业权属后，决定是否允许设备注册。',
            action: OutlinedButton.icon(
                onPressed: busy || loading || loadingMore || !current
                    ? null
                    : _loadPending,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新待审核'))),
        const Notice('审核通过只建立机构与提供方企业资源的绑定。设备注册、儿童 App 身份和应用策略执行仍须分别核验。'),
        const SizedBox(height: 16),
        if (loading || loadingMore || lookupBusy || busy)
          const LinearProgressIndicator(),
        if (accessError != null) ...[
          FailureView(accessError!),
          const SizedBox(height: 16)
        ],
        if (actionError != null) ...[
          const Notice('请先重新查询当前状态，再继续审核。重试只读取记录。', warning: true),
          FailureView(actionError!,
              retry: current && !busy && !lookupBusy && actionTarget != null
                  ? _readCallback(actionTarget!)
                  : null,
              reauth: () => widget.session.login(stepUp: true)),
          const SizedBox(height: 16)
        ],
        Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('待审核队列', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          if (pendingError != null) ...[
            if (pendingLoaded && pending.isNotEmpty)
              const Notice('列表未能更新，以下为上次成功读取的记录。', warning: true),
            FailureView(pendingError!,
                retry: current && !loading && !loadingMore && !busy
                    ? _retryPending
                    : null,
                reauth: () => widget.session.login(stepUp: true)),
            const SizedBox(height: 12)
          ],
          if (!loading &&
              !loadingMore &&
              pendingLoaded &&
              pendingError == null &&
              pending.isEmpty)
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
                          onPressed: busy || lookupBusy || !current
                              ? null
                              : _readCallback(item.tenantId),
                          child: const Text('查看审核'))
                    ]))
          ],
          if (nextCursor != null)
            TextButton(
                onPressed: busy || loading || loadingMore || !current
                    ? null
                    : () => _loadPending(more: true),
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
                        enabled: current && !busy && !lookupBusy,
                        maxLength: 36,
                        decoration:
                            const InputDecoration(labelText: '机构工作空间 ID'))),
                OutlinedButton(
                    onPressed: busy || lookupBusy || !current
                        ? null
                        : _queryCallback(),
                    child: const Text('查询'))
              ]),
          if (lookupError != null) ...[
            const SizedBox(height: 12),
            if (failedLookup != null && isManagedTenantId(failedLookup!))
              Text('未完成的查询：$failedLookup',
                  style: const TextStyle(color: muted)),
            FailureView(lookupError!,
                retry: current &&
                        !busy &&
                        !lookupBusy &&
                        failedLookup != null &&
                        isManagedTenantId(failedLookup!)
                    ? _readCallback(failedLookup!)
                    : null,
                reauth: () => widget.session.login(stepUp: true)),
          ],
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
              Text('机构 ${selected!.tenantId}'),
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
                  onPressed: busy || lookupBusy || !current
                      ? null
                      : _writeCallback(selected!, true),
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('核实并批准')),
            if (selected!.state == 'PENDING' && selected!.requestedBy == actor)
              const Notice('申请人不能审批自己的企业绑定，请由独立审核员处理。', warning: true),
            if (selected!.state == 'ACTIVE')
              OutlinedButton.icon(
                  onPressed: busy || lookupBusy || !current
                      ? null
                      : _writeCallback(selected!, false),
                  icon: const Icon(Icons.block_outlined),
                  label: const Text('撤销绑定'))
          ]
        ]))
      ]);
}

class _ReviewScope {
  final Session session;
  final String actor, role;
  final int generation;
  final bool allowed;
  const _ReviewScope(
      this.session, this.actor, this.role, this.generation, this.allowed);

  factory _ReviewScope.capture(Session session) {
    final actor = session.profile?['subject'];
    return _ReviewScope(
        session,
        actor is String ? actor : '',
        session.role,
        session.scopeGeneration,
        session.authenticated &&
            actor is String &&
            session.canOpen('managed-android-review'));
  }

  bool sameContext(_ReviewScope other) =>
      identical(session, other.session) &&
      actor == other.actor &&
      role == other.role &&
      generation == other.generation &&
      allowed == other.allowed;
}

class _ReviewDecision {
  final String proof, reason;
  const _ReviewDecision(this.proof, this.reason);
}

class _ReviewActionDialog extends StatefulWidget {
  final bool approve;
  final bool Function() current;
  const _ReviewActionDialog(
      {super.key, required this.approve, required this.current});

  @override
  State<_ReviewActionDialog> createState() => _ReviewActionDialogState();
}

class _ReviewActionDialogState extends State<_ReviewActionDialog> {
  final evidence = TextEditingController();
  final reason = TextEditingController();
  bool invalidated = false, closing = false;
  Object? validationError;

  @override
  void initState() {
    super.initState();
    invalidated = !widget.current();
  }

  void invalidate() {
    if (!mounted || invalidated) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => invalidate());
      return;
    }
    evidence.clear();
    reason.clear();
    setState(() {
      invalidated = true;
      validationError = null;
    });
  }

  bool get canClose =>
      mounted && !closing && ModalRoute.of(context)?.isCurrent == true;

  void _close([_ReviewDecision? decision]) {
    if (!canClose) return;
    setState(() => closing = true);
    Navigator.pop(context, decision);
  }

  void _confirm() {
    if (!canClose) return;
    if (invalidated || !widget.current()) {
      invalidate();
      return;
    }
    final proof = evidence.text.trim();
    final explanation = reason.text.trim();
    final invalidProof =
        widget.approve && (proof.length < 8 || proof.length > 200);
    if (invalidProof || explanation.length < 5 || explanation.length > 500) {
      setState(() => validationError = ApiFailure(
          400,
          invalidProof
              ? 'INVALID_OWNERSHIP_EVIDENCE'
              : 'INVALID_BINDING_REASON'));
      return;
    }
    _close(_ReviewDecision(proof, explanation));
  }

  @override
  void dispose() {
    evidence.dispose();
    reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.approve ? '独立审核企业绑定' : '撤销企业绑定'),
          content: SizedBox(
              width: 520,
              child: invalidated
                  ? const Notice('会话或操作范围已变化，请返回后重新查询当前记录。', warning: true)
                  : SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Notice(
                          widget.approve
                              ? '请先在线下核对机构合同、企业权属证明和提供方资源。提供方可读不代表客户所有权。'
                              : '撤销会阻止新的受管操作，不会自动解除已经注册的设备系统管理。',
                          warning: true),
                      const SizedBox(height: 16),
                      if (widget.approve) ...[
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
                              labelText: widget.approve ? '审核理由' : '撤销理由')),
                      if (validationError != null) ...[
                        const SizedBox(height: 12),
                        FailureView(validationError!)
                      ]
                    ]))),
          actions: [
            TextButton(
                onPressed: closing ? null : () => _close(),
                child: const Text('返回')),
            if (!invalidated)
              FilledButton(
                  onPressed: closing ? null : _confirm,
                  child: Text(widget.approve ? '确认批准' : '确认撤销'))
          ]);
}
