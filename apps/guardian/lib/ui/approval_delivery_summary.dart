import 'dart:async';
import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/approval_decision.dart';
import '../core/labels.dart';
import 'design.dart';
import 'dialog_access.dart';

/// Delivery reports enrich a fixed approval; they never replace its version.
class ApprovalDeliverySummary extends StatefulWidget {
  final Api api;
  final String path;
  final ApprovalRequestSnapshot request;
  final Listenable accessChanges;
  final bool Function() isCurrent;
  final ValueChanged<Object> onReadDenied;
  final VoidCallback onReviewNeeded;
  final VoidCallback? reauth;
  const ApprovalDeliverySummary({super.key, required this.api,
    required this.path, required this.request, required this.accessChanges,
    required this.isCurrent, required this.onReadDenied,
    required this.onReviewNeeded, this.reauth});

  @override
  State<ApprovalDeliverySummary> createState() => _ApprovalDeliverySummaryState();
}

class _ApprovalDeliverySummaryState extends State<ApprovalDeliverySummary> {
  DialogAccessBinding? _access;
  late final Api _sourceApi, _api;
  late final String _path;
  late final ApprovalRequestSnapshot _request;
  late final ValueChanged<Object> _onReadDenied;
  late final VoidCallback _onReviewNeeded;
  late final VoidCallback? _reauth;
  ApprovalDeliverySnapshot? _summary;
  Object? _error;
  bool _active = true, _lost = false, _loading = false;
  int _generation = 0;

  bool get _current => mounted && _active && !_lost &&
      _access?.permitted() == true;

  void _retire() {
    if (_lost) return;
    // A pending GET may already have reconciled server-side expiry. Signal
    // the original journey; its callback must only record a review need.
    if (_loading) _onReviewNeeded();
    _lost = true;
    _generation++;
    _summary = null;
    _error = null;
    _loading = false;
  }

  void _accessChanged() {
    if (!mounted || !_active || _current) return;
    setState(_retire);
  }

  void _parentFinished() {
    if (mounted && _active) _retire();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_access != null) return;
    _sourceApi = widget.api;
    _path = widget.path;
    _request = widget.request;
    _onReadDenied = widget.onReadDenied;
    _onReviewNeeded = widget.onReviewNeeded;
    _reauth = widget.reauth;
    final permitted = widget.isCurrent;
    _access = DialogAccessBinding(context,
        accessChanges: widget.accessChanges,
        hasAccess: () => _active && !_lost && permitted());
    _access!.changes.addListener(_accessChanged);
    _access!.parent?.popped.then<void>((_) => _parentFinished());
    _access!.parent?.completed.then<void>((_) => _parentFinished());
    _api = _sourceApi.scoped(() => _current);
    if (_current) unawaited(_load());
  }

  @override
  void didUpdateWidget(ApprovalDeliverySummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.api, _sourceApi) || widget.path != _path ||
        !identical(widget.request, _request) ||
        !identical(widget.accessChanges, oldWidget.accessChanges)) {
      _retire();
    }
  }

  @override
  void deactivate() {
    _active = false;
    _retire();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void dispose() {
    _active = false;
    _retire();
    _access?.changes.removeListener(_accessChanged);
    _access?.dispose();
    super.dispose();
  }

  bool _interactive(int generation) => _current && !_loading &&
      generation == _generation && _access!.parent?.isCurrent == true;

  Future<void> _load() async {
    if (!_current || _loading) return;
    final generation = ++_generation;
    bool accepts() => _current && generation == _generation;
    setState(() {
      _loading = true;
      _summary = null;
      _error = null;
    });
    try {
      final raw = await _api.send('GET', _path, isCurrent: accepts);
      if (!accepts()) return;
      final summary = ApprovalDeliverySnapshot.read(raw, request: _request);
      if (summary.approvalVersion > _request.version) _onReviewNeeded();
      if (accepts()) setState(() => _summary = summary);
    } catch (failure) {
      if (!accepts()) return;
      if (failure is ApiFailure && failure.code != 'REAUTH_REQUIRED' &&
          (failure.status == 401 || failure.status == 403 ||
              failure.code == 'WORKSPACE_CHANGED')) {
        // Keep this target refusal distinct from a recoverable report error.
        _retire();
        _onReadDenied(failure);
        if (mounted && _active) setState(() {});
      } else {
        if (failure is! ApiFailure || failure.status == 0 ||
            failure.status == 408 || failure.status == 429 ||
            failure.status >= 500) {
          _onReviewNeeded();
        }
        if (accepts()) setState(() => _error = failure);
      }
    } finally {
      if (accepts()) setState(() => _loading = false);
    }
  }

  Widget _field(String name, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(fontSize: 12, color: muted)),
        const SizedBox(height: 4),
        SelectableText(value, style: const TextStyle(fontSize: 14, height: 1.6)),
      ]));

  @override
  Widget build(BuildContext context) {
    if (!_current) return const SizedBox.shrink();
    final generation = _generation;
    final summary = _summary;
    final reauthenticate = _reauth;
    return Padding(padding: const EdgeInsets.symmetric(vertical: 9),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_loading) ...[
        const LinearProgressIndicator(key: Key('approval-delivery-loading')),
        const SizedBox(height: 8),
        Semantics(liveRegion: true,
            child: const Text('正在读取交付状态；申请资料已可查看。',
                style: TextStyle(fontSize: 12, color: muted))),
      ] else if (_error != null) ...[
        const Text('交付状态暂未读到，可单独重试。',
            style: TextStyle(fontSize: 12, color: muted)),
        const SizedBox(height: 8),
        FailureView(_error!, key: const Key('approval-delivery-failure'),
            retry: () {
              if (_interactive(generation)) unawaited(_load());
            },
            reauth: reauthenticate == null ? null : () {
              if (_interactive(generation)) reauthenticate();
            }),
      ] else if (summary != null) ...[
        if (summary.approvalVersion != _request.version)
          const Notice('审批状态已更新，请关闭后重新打开。', warning: true)
        else ...[
          _field('当前文档', summary.action == null
              ? '尚无批准窗口' : label(summary.action)),
          _field('文档交付 / 设备报告', label(summary.deliveryState)),
          if (summary.receivedAt != null)
            _field('最近回执', dateLabel(summary.receivedAt)),
          _field('交付尝试', summary.deliveryAttempt == null ? '尚未开始'
              : '第 ${summary.deliveryAttempt} 次（最多 10 次）'),
          if (summary.reasonCode != null)
            _field('设备拒收原因', accessRejectionLabel(summary.reasonCode)),
          if (summary.deliveryState == 'REJECTED') ...[
            _field('恢复状态', accessRetryLabel(summary.retryStatus)),
            if (summary.retryAfter != null)
              _field('最早可重试', dateLabel(summary.retryAfter)),
            const Text('重试由设备端发起，原文档和批准截止时间保持不变。旧尝试的回执仅保留追溯。',
                style: TextStyle(fontSize: 12, color: muted)),
          ],
        ],
      ],
    ]));
  }
}
