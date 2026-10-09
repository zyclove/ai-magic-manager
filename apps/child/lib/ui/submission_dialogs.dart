import 'dart:async';
import 'dart:math' as math;
import 'package:device_access/device_access.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/session.dart';
import 'design.dart';
import 'submission_display.dart';

Future<void> _show(BuildContext context, ChildSession session, Widget child) =>
    showDialog<void>(
        context: context,
        builder: (_) => _PrivateRequestDialog(
            session: session,
            generation: session.submissionGeneration,
            child: child));
Future<void> showSubmissionEditor(BuildContext context, ChildSession session) =>
    _show(context, session, _RequestEditor(session));
Future<void> showSubmissionDetail(
        BuildContext context, ChildSession session, String id) =>
    _show(context, session, _RequestDetail(session, id));
Future<void> showSubmissionRecovery(BuildContext context, ChildSession session,
        {bool discard = false}) =>
    _show(context, session, _OriginalOperation(session, discard));

/// Remove both the private widget tree and its route on a lifecycle/scope change.
class _PrivateRequestDialog extends StatefulWidget {
  final ChildSession session;
  final int generation;
  final Widget child;
  const _PrivateRequestDialog(
      {required this.session, required this.generation, required this.child});
  @override
  State<_PrivateRequestDialog> createState() => _PrivateRequestDialogState();
}

class _PrivateRequestDialogState extends State<_PrivateRequestDialog> {
  bool get valid =>
      widget.session.foreground &&
      widget.session.credentialReady &&
      widget.generation == widget.session.submissionGeneration;
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (!valid) {
      scheduleMicrotask(() {
        if (!mounted) return;
        final route = ModalRoute.of(context);
        if (route?.isCurrent == true) Navigator.of(context).pop();
      });
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      valid ? widget.child : const SizedBox.shrink();
}

class _DialogFrame extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget> actions;
  const _DialogFrame(this.title, {required this.body, required this.actions});
  @override
  Widget build(BuildContext context) => Shortcuts(
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
              child: Dialog(
                  insetPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                  child: ConstrainedBox(
                      constraints: BoxConstraints(
                          maxWidth: 560,
                          maxHeight: math.max(
                              160,
                              MediaQuery.of(context).size.height -
                                  MediaQuery.of(context).viewInsets.bottom -
                                  48)),
                      child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Semantics(
                                    header: true,
                                    child: Text(title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge)),
                                const SizedBox(height: 20),
                                body,
                                const SizedBox(height: 24),
                                Wrap(
                                    alignment: WrapAlignment.end,
                                    spacing: 12,
                                    runSpacing: 12,
                                    children: actions)
                              ]))))));
}

Widget _fact(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style:
              const TextStyle(fontWeight: FontWeight.w600, color: childNavy)),
      Text(value)
    ]));

class _ApplicationChoice {
  final AccessSubmissionOption option;
  final AccessSubmissionApplication application;
  const _ApplicationChoice(this.option, this.application);
}

class _RequestEditor extends StatefulWidget {
  final ChildSession session;
  const _RequestEditor(this.session);
  @override
  State<_RequestEditor> createState() => _RequestEditorState();
}

class _RequestEditorState extends State<_RequestEditor> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController(),
      _minutes = TextEditingController(text: '10');
  final _search = TextEditingController();
  late final List<_ApplicationChoice> _choices;
  _ApplicationChoice? _choice;
  final _selected = <String>{};
  bool _preview = false, _ruleError = false, _sent = false;
  int _visible = 20;
  ChildSession get session => widget.session;
  List<AccessSubmissionRule> get _rules =>
      [...?_choice?.option.commonRules, ...?_choice?.application.rules];
  @override
  void initState() {
    super.initState();
    _choices = [
      for (final option in session.submissions.options)
        for (final app in option.applications) _ApplicationChoice(option, app)
    ];
  }

  @override
  void dispose() {
    _reason.clear();
    _reason.dispose();
    _minutes.dispose();
    _search.dispose();
    super.dispose();
  }

  void _select(_ApplicationChoice choice) => setState(() {
        _choice = choice;
        _selected.clear();
        _selected.addAll(_rules.take(20).map((r) => r.id));
        _ruleError = false;
      });
  void _confirm() {
    final valid = _form.currentState!.validate();
    setState(() => _ruleError = _selected.isEmpty || _selected.length > 20);
    if (valid && !_ruleError) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _preview = true);
    }
  }

  Future<void> _submit() async {
    if (_sent || session.busy || _choice == null) return;
    setState(() => _sent = true);
    final choice = _choice!;
    await session.createSubmission(
        AccessSubmissionInput(
            policyId: choice.option.id,
            baseVersionId: choice.option.baseVersionId,
            applicationId: choice.application.id,
            ruleIds: _selected.toList(),
            requestedWindowSeconds: int.parse(_minutes.text) * 60,
            reason: _reason.text.trim().isEmpty ? null : _reason.text),
        applicationName: choice.application.displayName);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final enabled = !session.busy && !_sent;
        if (_choice == null) {
          final query = _search.text.trim().toLowerCase();
          final choices = _choices
              .where((c) => '${c.application.displayName} ${c.option.name}'
                  .toLowerCase()
                  .contains(query))
              .toList();
          return _DialogFrame('选择申请应用',
              body: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('只能选择监护人规则中允许申请的应用。相同应用可能对应不同安排。'),
                    const SizedBox(height: 16),
                    TextField(
                        controller: _search,
                        decoration: const InputDecoration(
                            labelText: '查找应用或安排',
                            prefixIcon: Icon(Icons.search)),
                        onChanged: (_) => setState(() => _visible = 20)),
                    const SizedBox(height: 12),
                    if (choices.isEmpty) const Text('没有匹配的应用。可以返回后继续查找其他页。'),
                    for (final choice in choices.take(_visible))
                      MergeSemantics(
                          child: Semantics(
                              button: true,
                              child: ListTile(
                                  autofocus: identical(choice, choices.first),
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(choice.application.displayName),
                                  subtitle: Text(choice.option.name),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap:
                                      enabled ? () => _select(choice) : null))),
                    if (choices.length > _visible)
                      TextButton(
                          onPressed: () => setState(() => _visible += 20),
                          child: const Text('显示更多应用'))
                  ]),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回'))
              ]);
        }
        final choice = _choice!;
        if (_preview) {
          return _DialogFrame('确认申请内容',
              body: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fact('应用', choice.application.displayName),
                    _fact('监护安排', choice.option.name),
                    _fact('申请时长', '${int.parse(_minutes.text)} 分钟'),
                    _fact('申请的限制', '${_selected.length} 条'),
                    _fact(
                        '申请理由',
                        _reason.text.trim().isEmpty
                            ? '未填写'
                            : _reason.text.trim()),
                    const ChildNotice('提交后等待监护人审批',
                        detail: '监护人可以拒绝或批准较短时长。批准后仍需同步配置和核对设备能力，不会自动延长原截止时间。')
                  ]),
              actions: [
                TextButton(
                    onPressed:
                        enabled ? () => setState(() => _preview = false) : null,
                    child: const Text('返回修改')),
                FilledButton(
                    onPressed: enabled ? () => unawaited(_submit()) : null,
                    child: const Text('提交给监护人'))
              ]);
        }
        return _DialogFrame('填写访问申请',
            body: Form(
                key: _form,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _fact('应用', choice.application.displayName),
                      _fact('监护安排', choice.option.name),
                      TextButton(
                          onPressed: enabled
                              ? () => setState(() => _choice = null)
                              : null,
                          child: const Text('更换应用')),
                      const SizedBox(height: 12),
                      TextFormField(
                          key: const Key('submission-minutes'),
                          controller: _minutes,
                          enabled: enabled,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          decoration: const InputDecoration(
                              labelText: '申请时长（分钟）',
                              helperText: '1–60 分钟，监护人可批准较短时长'),
                          validator: (text) {
                            final value = int.tryParse(text ?? '');
                            return value == null || value < 1 || value > 60
                                ? '请输入 1–60 分钟'
                                : null;
                          }),
                      const SizedBox(height: 12),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final minutes in [5, 10, 15, 30, 60])
                          ActionChip(
                              label: Text('$minutes 分钟'),
                              onPressed: enabled
                                  ? () =>
                                      setState(() => _minutes.text = '$minutes')
                                  : null)
                      ]),
                      const SizedBox(height: 20),
                      Text('选择需要临时调整的限制（${_selected.length}/20）'),
                      for (var i = 0; i < _rules.length; i++)
                        CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _selected.contains(_rules[i].id),
                            title: Text(
                                '${_rules[i].kind == 'APP_LAUNCH' ? '应用启动' : '可用时段'}限制 ${i + 1}'),
                            onChanged: enabled &&
                                    (_selected.length < 20 ||
                                        _selected.contains(_rules[i].id))
                                ? (value) => setState(() {
                                      if (value == true) {
                                        _selected.add(_rules[i].id);
                                      } else {
                                        _selected.remove(_rules[i].id);
                                      }
                                      _ruleError = false;
                                    })
                                : null),
                      if (_ruleError)
                        Text('请选择 1–20 条限制',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      const SizedBox(height: 20),
                      TextFormField(
                          key: const Key('submission-reason'),
                          controller: _reason,
                          enabled: enabled,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                              labelText: '申请理由（选填）',
                              helperText: '简要告诉监护人这次需要完成什么'),
                          validator: (text) => (text?.length ?? 0) > 300
                              ? '理由过长，请减少文字或表情'
                              : null)
                    ])),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回')),
              FilledButton(
                  onPressed: enabled ? _confirm : null,
                  child: const Text('核对申请'))
            ]);
      });
}

SubmissionCacheEntry? _entry(ChildSession session, String id) {
  for (final entry in session.submissions.journal?.entries ??
      const <SubmissionCacheEntry>[]) {
    if (entry.value.id == id) return entry;
  }
  return null;
}

class _RequestDetail extends StatefulWidget {
  final ChildSession session;
  final String id;
  const _RequestDetail(this.session, this.id);
  @override
  State<_RequestDetail> createState() => _RequestDetailState();
}

class _RequestDetailState extends State<_RequestDetail> {
  AccessSubmission? _cancelling;
  ChildSession get session => widget.session;
  Future<void> _cancel(SubmissionCacheEntry entry) async {
    await session.cancelSubmission(entry.value,
        applicationName: entry.applicationName);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final entry = _entry(session, widget.id);
        if (entry == null) {
          return _DialogFrame('申请暂不可用',
              body: const Text('请返回列表重新核对。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回'))
              ]);
        }
        final value = entry.value,
            confirmed =
                session.submissions.confirmedRequestIds.contains(widget.id);
        final canCancel = confirmed &&
            value.state == 'PENDING' &&
            value.requestExpiresAt > session.nowMillis() &&
            !session.busy &&
            session.submissions.journal?.pending == null;
        if (_cancelling != null) {
          return _DialogFrame('确认取消这份申请？',
              body: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fact('应用', entry.applicationName),
                    const Text('取消后监护人不能再批准这份申请。已发送的取消如结果不明，会保留原操作用于确认。'),
                    if (!canCancel || _cancelling!.version != value.version)
                      const ChildNotice('申请状态已变化，请返回重新核对。', warning: true)
                  ]),
              actions: [
                TextButton(
                    onPressed: () => setState(() => _cancelling = null),
                    child: const Text('保留申请')),
                FilledButton(
                    onPressed:
                        canCancel && _cancelling!.version == value.version
                            ? () => unawaited(_cancel(entry))
                            : null,
                    child: const Text('确认取消'))
              ]);
        }
        return _DialogFrame('申请详情',
            body:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _fact('应用', entry.applicationName),
              _fact('申请状态', submissionState(value)),
              if (!confirmed)
                const ChildNotice('上次保存，待核对',
                    detail: '本次未能取得最新详情，不能据此取消或认定已经放行。'),
              _fact('申请时长', submissionDuration(value.requestedWindowSeconds)),
              _fact('待审期限', submissionTime(context, value.requestExpiresAt)),
              if (value.state == 'PENDING' &&
                  value.requestExpiresAt <= session.nowMillis())
                const ChildNotice('待审期限已到，请刷新确认服务端状态。'),
              if (value.grantedWindowSeconds != null)
                _fact('批准时长', submissionDuration(value.grantedWindowSeconds!)),
              if (value.absoluteNotAfter != null)
                _fact('原批准截止时间',
                    submissionTime(context, value.absoluteNotAfter!)),
              _fact('申请理由',
                  value.reason?.isNotEmpty == true ? value.reason! : '未填写'),
              const Text(
                  '时间按设备本地时区显示。重启、离线和重试不会延长原期限。申请状态不代表系统执行；已批准的安排还需要同步配置。')
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭')),
              if (value.state == 'PENDING')
                OutlinedButton(
                    onPressed: canCancel
                        ? () => setState(() => _cancelling = value)
                        : null,
                    child: const Text('取消申请'))
            ]);
      });
}

class _OriginalOperation extends StatefulWidget {
  final ChildSession session;
  final bool discard;
  const _OriginalOperation(this.session, this.discard);
  @override
  State<_OriginalOperation> createState() => _OriginalOperationState();
}

class _OriginalOperationState extends State<_OriginalOperation> {
  late final String? _key = widget.session.submissions.journal?.pending?.key;
  Future<void> _apply() async {
    if (widget.discard) {
      await widget.session.discardSubmission();
    } else {
      await widget.session.retrySubmission();
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: widget.session,
      builder: (context, _) {
        final original = widget.session.submissions.journal?.pending;
        if (original == null || original.key != _key) {
          return _DialogFrame('原操作已更新',
              body: const Text('请返回列表查看当前状态。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回'))
              ]);
        }
        final allowed = widget.discard
            ? original.phase != SubmissionOperationPhase.unknown
            : original.phase != SubmissionOperationPhase.rejected;
        return _DialogFrame(widget.discard ? '放弃本次操作？' : '确认原操作',
            body:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _fact('应用', original.applicationName),
              _fact('操作', original.kind == 'CREATE' ? '申请临时访问' : '取消原申请'),
              if (original.input != null) ...[
                _fact('原申请时长',
                    submissionDuration(original.input!.requestedWindowSeconds)),
                _fact(
                    '原申请理由',
                    original.input!.reason?.isNotEmpty == true
                        ? original.input!.reason!
                        : '未填写')
              ],
              Text(widget.discard
                  ? '仅放弃从未发送或已明确拒绝的本地操作，不删除服务端申请。结果未知的操作不能放弃。'
                  : '使用原内容确认结果，不创建另一份申请、不延长期限。恢复记录暂不可用时仍保留待确认状态。')
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回')),
              FilledButton(
                  onPressed: allowed && !widget.session.busy
                      ? () => unawaited(_apply())
                      : null,
                  child: Text(widget.discard ? '确认放弃' : '确认重试'))
            ]);
      });
}
