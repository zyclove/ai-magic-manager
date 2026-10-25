import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/api.dart';
import '../core/policy_domain_check.dart';
import 'design.dart';
import 'owned_dialog_route.dart';

/// A single read-only prediction, owned by the detail and access that opened it.
class PolicyDomainCheckView extends StatefulWidget {
  final Future<PolicyDomainEvaluation> Function(String domain) evaluate;
  final int draftRevision;
  final bool Function() hasAccess;
  final Listenable accessChanges;
  const PolicyDomainCheckView(
      {super.key,
      required this.evaluate,
      required this.draftRevision,
      required this.hasAccess,
      required this.accessChanges});

  @override
  State<PolicyDomainCheckView> createState() => _PolicyDomainCheckViewState();
}

class _PolicyDomainCheckViewState extends State<PolicyDomainCheckView> {
  final _domain = TextEditingController();
  late final Listenable _accessChanges;
  late final bool Function() _hasAccess;
  ModalRoute<dynamic>? _route;
  bool _routeBound = false, _listening = true, _revoked = false;
  bool _pending = false, _stale = false, _publicationQueued = false;
  int _generation = 0;
  String _inputText = '';
  String? _validation;
  Object? _error;
  PolicyDomainEvaluation? _result;

  @override
  void initState() {
    super.initState();
    _accessChanges = widget.accessChanges;
    _hasAccess = widget.hasAccess;
    _accessChanges.addListener(_accessChanged);
    _domain.addListener(_inputChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!_routeBound) {
      _routeBound = true;
      _route = route;
      route?.popped.then<void>((_) {
        if (mounted) _revoke();
      });
    } else if (!identical(route, _route)) {
      _revoke();
    }
    _scopeCurrent();
  }

  @override
  void didUpdateWidget(covariant PolicyDomainCheckView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.draftRevision != widget.draftRevision ||
        oldWidget.evaluate != widget.evaluate ||
        oldWidget.hasAccess != widget.hasAccess ||
        oldWidget.accessChanges != widget.accessChanges) _revoke();
  }

  void _publish() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_publicationQueued) return;
      _publicationQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _publicationQueued = false;
        if (!mounted) return;
        if (_revoked) _domain.clear();
        setState(() {});
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    } else {
      if (_revoked) _domain.clear();
      setState(() {});
    }
  }

  void _revoke() {
    if (_revoked) return;
    _revoked = true;
    _generation++;
    _inputText = '';
    _pending = false;
    _result = null;
    _error = null;
    _validation = null;
    if (_listening) {
      _listening = false;
      _accessChanges.removeListener(_accessChanged);
    }
    _publish();
  }

  bool _scopeCurrent() {
    if (!mounted || _revoked) return false;
    var allowed = false;
    try {
      allowed = _hasAccess();
    } catch (_) {/* A lost owner is revoked. */}
    final route = _route;
    if (!allowed ||
        (route != null && !route.isActive) ||
        (route is OwnedDialogRoute<dynamic> && !route.available)) {
      _revoke();
      return false;
    }
    return true;
  }

  void _accessChanged() {
    _scopeCurrent();
  }

  void _inputChanged() {
    if (_revoked || _inputText == _domain.text) return;
    _inputText = _domain.text;
    _generation++;
    _result = null;
    _error = null;
    _validation = null;
    _publish();
  }

  Future<void> _submit() async {
    if (!_scopeCurrent() || _route?.isCurrent == false || _pending || _stale) {
      return;
    }
    final domain = _domain.text.trim();
    if (domain.isEmpty ||
        domain.length > 253 ||
        RegExp(r'[:/\\?#*@\s]').hasMatch(domain)) {
      _result = null;
      _error = null;
      _validation = '请输入单个域名，不含协议、端口或路径。';
      _publish();
      return;
    }
    final generation = _generation;
    final evaluate = widget.evaluate;
    _pending = true;
    _result = null;
    _error = null;
    _validation = null;
    _publish();
    try {
      final result = await evaluate(domain);
      if (_scopeCurrent() && generation == _generation) _result = result;
    } catch (error) {
      if (!_scopeCurrent()) return;
      if (error is ApiFailure) {
        if (error.code == 'WORKSPACE_CHANGED' ||
            error.status == 403 ||
            (error.status == 401 && error.code != 'REAUTH_REQUIRED')) {
          _revoke();
          return;
        }
        if (error.status == 412) {
          _stale = true;
          _result = null;
          _error = null;
          return;
        }
      }
      if (generation == _generation) _error = error;
    } finally {
      if (mounted && !_revoked) {
        _pending = false;
        _publish();
      }
    }
  }

  @override
  void dispose() {
    _revoked = true;
    _generation++;
    _inputText = '';
    _result = null;
    if (_listening) _accessChanges.removeListener(_accessChanged);
    _domain.removeListener(_inputChanged);
    _domain.clear();
    _domain.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_scopeCurrent()) {
      return const Notice('此检查已失效，请关闭后重新打开有权限的详情。', warning: true);
    }
    final result = _result;
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('域名规则检查', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          const Text('检查精确域名，不包含子域。仅预测草稿规则，不证明设备拦截。',
              style: TextStyle(color: muted)),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, constraints) {
            final input = TextField(
                key: const Key('policy-domain-input'),
                controller: _domain,
                readOnly: _stale,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                    labelText: '域名',
                    hintText: '例如 example.com',
                    errorText: _validation,
                    errorMaxLines: 3),
                onSubmitted: (_) => _submit());
            final button = FilledButton.icon(
                key: const Key('policy-domain-submit'),
                onPressed: _pending || _stale ? null : _submit,
                icon: _pending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search),
                label: Text(_pending ? '正在检查…' : '检查域名'));
            return constraints.maxWidth < 480
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [input, const SizedBox(height: 10), button])
                : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: input),
                    const SizedBox(width: 12),
                    button
                  ]);
          }),
          if (_stale) ...[
            const SizedBox(height: 12),
            const Notice('草稿已更新，请关闭后重新打开当前详情，再检查域名。', warning: true),
          ] else if (_error != null) ...[
            const SizedBox(height: 12),
            FailureView(_error!),
          ],
          if (result != null) ...[
            const SizedBox(height: 12),
            Container(
                key: const Key('policy-domain-result'),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    border: Border.all(color: line),
                    borderRadius: BorderRadius.circular(8)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                          switch (result.predictedEffect) {
                            'ALLOW' => '规则预测：允许',
                            'DENY' => '规则预测：拒绝',
                            _ => '规则预测：未匹配',
                          },
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 6),
                      Text(result.canonicalDomain),
                      const SizedBox(height: 6),
                      Text(
                          result.predictedEffect == 'NO_MATCH'
                              ? '当前草稿没有匹配的域名规则，不代表已允许或已拦截。'
                              : '这是当前草稿的规则预测，设备是否实际执行需另行核实。',
                          style: const TextStyle(color: muted)),
                      if (result.predictedEffect == 'DENY' &&
                          result.matchingRuleIds.length > 1) ...[
                        const SizedBox(height: 6),
                        const Text('多条精确规则命中时，拒绝优先。',
                            style: TextStyle(color: muted)),
                      ],
                      if (result.matchingRuleIds.isNotEmpty)
                        ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: const EdgeInsets.only(bottom: 8),
                            title: Text(
                                '查看匹配规则（${result.matchingRuleIds.length}）'),
                            children: [
                              for (final id in result.matchingRuleIds)
                                Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(id))
                            ]),
                    ])),
          ],
        ]);
  }
}
