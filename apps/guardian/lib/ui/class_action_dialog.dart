import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/scheduler.dart';
import '../core/api.dart';
import 'design.dart';
import 'editor_draft_text.dart';
import 'owned_dialog_route.dart';

/// Short focused mutations preserve their payload when the server result is unknown.
class ClassActionDialog extends StatefulWidget {
  final String title, description, field, fieldLabel, submitLabel;
  final String? initialName;
  final Map<String, String>? options;
  final Future<Json> Function(Json) onSubmit;
  final VoidCallback? reauth;
  final Listenable? accessChanges;
  final bool Function()? hasAccess;
  const ClassActionDialog(
      {super.key,
      required this.title,
      required this.description,
      required this.field,
      required this.fieldLabel,
      required this.submitLabel,
      required this.onSubmit,
      this.initialName,
      this.options,
      this.reauth,
      this.accessChanges,
      this.hasAccess});
  @override
  State<ClassActionDialog> createState() => _ClassActionDialogState();
}

class _ClassActionDialogState extends State<ClassActionDialog> {
  final form = GlobalKey<FormState>();
  late final TextEditingController name;
  String? choice;
  bool busy = false;
  Object? error;
  Json? pending, recoveryValues;
  bool confirmingUnknownClose = false, _listening = false;
  late final String initialTitle, initialField, initialFieldLabel;
  late final String? initialInput;
  late final Map<String, String>? initialOptions;
  ModalRoute<dynamic>? _route;
  bool _active = true, _revoked = false, _rebuildPending = false;
  bool get locked => busy || pending != null || recoveryStopped || confirmingUnknownClose;
  bool get recoveryStopped => versionConflict || isUnavailableOperationResult(error);
  bool get versionConflict =>
      error is ApiFailure && (error as ApiFailure).status == 412;

  void _observeAccess() {
    if (!_revoked && widget.hasAccess?.call() == false) _revoked = true;
  }

  bool get permitted {
    _observeAccess();
    return !_revoked;
  }

  bool get current =>
      mounted && _active && permitted && _route?.isCurrent == true &&
      (_route is! OwnedDialogRoute<dynamic> ||
          (_route as OwnedDialogRoute<dynamic>).available);

  void _accessChanged() {
    final wasRevoked = _revoked;
    _observeAccess();
    if (wasRevoked || !_revoked || !mounted || !_active) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_rebuildPending) return;
      _rebuildPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _rebuildPending = false;
        if (mounted && _active) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void finish([Json? result]) {
    if (!mounted || !_active) return;
    final route = _route;
    if (route is OwnedDialogRoute<Json>) {
      route.finish(result);
    } else if (route?.isCurrent == true) {
      route!.navigator?.pop(result);
    }
  }

  void close() {
    if (!current || busy) return;
    if (recoveryStopped) {
      finish(<String, dynamic>{'refresh': true});
    } else if (pending != null) {
      if (!confirmingUnknownClose) setState(() => confirmingUnknownClose = true);
    } else {
      finish();
    }
  }

  void keepOriginal() {
    if (!current || busy || recoveryStopped ||
        !confirmingUnknownClose || pending == null) return;
    setState(() => confirmingUnknownClose = false);
  }

  void confirmUnknownClose() {
    if (!current || busy || recoveryStopped ||
        !confirmingUnknownClose || pending == null) return;
    finish(<String, dynamic>{'refresh': true});
  }

  void reauthenticate() {
    if (current && !busy && !recoveryStopped && !confirmingUnknownClose) {
      widget.reauth?.call();
    }
  }

  @override
  void initState() {
    super.initState();
    initialTitle = widget.title;
    initialField = widget.field;
    initialFieldLabel = widget.fieldLabel;
    initialInput = widget.initialName;
    initialOptions = widget.options == null ? null
        : Map<String, String>.unmodifiable(widget.options!);
    name = TextEditingController(text: initialInput);
    _observeAccess();
    if (!_revoked && widget.accessChanges != null) {
      widget.accessChanges!.addListener(_accessChanged);
      _listening = true;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ModalRoute.of(context);
    if (_route != null && !identical(_route, next)) _revoked = true;
    _route = next;
  }

  @override
  void didUpdateWidget(ClassActionDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hasAccess?.call() == false || initialTitle != widget.title ||
        initialField != widget.field || initialFieldLabel != widget.fieldLabel ||
        initialInput != widget.initialName || !mapEquals(initialOptions, widget.options)) {
      _revoked = true;
    }
    _observeAccess();
    if (!identical(oldWidget.accessChanges, widget.accessChanges)) {
      if (_listening) oldWidget.accessChanges?.removeListener(_accessChanged);
      _listening = false;
      if (!_revoked && _active && widget.accessChanges != null) {
        widget.accessChanges!.addListener(_accessChanged);
        _listening = true;
      }
    }
  }

  @override
  void deactivate() {
    _active = false;
    _revoked = true;
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
    _revoked = true;
    if (_listening) widget.accessChanges?.removeListener(_accessChanged);
    name.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!current || busy || recoveryStopped || confirmingUnknownClose) return;
    final retryingUnknown = pending != null;
    if (!retryingUnknown && form.currentState?.validate() != true) return;
    final body = pending ?? Map<String, dynamic>.unmodifiable({
      initialField: initialOptions == null ? name.text.trim() : choice,
    });
    setState(() {
      busy = true;
      error = null;
      pending = body;
    });
    try {
      if (!current) return;
      final result = await widget.onSubmit(body);
      if (mounted && _active && permitted) finish(result);
    } catch (failure) {
      if (mounted && _active && permitted) {
        setState(() {
          error = failure;
          final stopped = failure is ApiFailure &&
              (failure.status == 412 || isUnavailableOperationResult(failure));
          final unknown = retryingUnknown || failure is! ApiFailure ||
              failure.status == 0 || failure.status >= 500 ||
              failure.code == 'PENDING_OPERATION_UNCHANGED';
          if (stopped) {
            recoveryValues ??= body;
            pending = null;
            confirmingUnknownClose = false;
          } else if (!unknown) {
            pending = null;
          }
        });
      }
    } finally {
      if (mounted && _active) setState(() => busy = false);
    }
  }

  Widget stoppedDialog() => PopScope(
      canPop: false,
      onPopInvoked: (didPop) { if (!didPop) close(); },
      child: AlertDialog(
          title: const Text('已停止再次提交'),
          content: SizedBox(width: 520, child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                FailureView(error!),
                Text(versionConflict
                    ? '记录已更新，已停止再次提交。可复制下方草稿；关闭后先核对最新记录，再重新操作。'
                    : '原操作结果已无法恢复，已停止再次提交。请核对当前记录；结果不可恢复不代表操作未执行。',
                    style: const TextStyle(height: 1.6)),
                const SizedBox(height: 12),
                const Text('保留的草稿', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SelectableText(classActionDraftText(recoveryValues ?? const {},
                    field: initialField, fieldLabel: initialFieldLabel, options: initialOptions),
                    key: const Key('class-action-recovery-draft'),
                    style: const TextStyle(height: 1.6)),
              ]))),
          actions: [TextButton(key: const Key('class-action-close'),
              onPressed: busy ? null : close, child: const Text('关闭并核对记录'))]));

  @override
  Widget build(BuildContext context) => !permitted
      ? AlertDialog(
          title: const Text('工作空间或权限已变化'),
          content: const Text('已隐藏原表单内容。请关闭后在当前工作空间重新打开；已提交的操作请回到原工作空间刷新列表核对结果。'),
          actions: [
            TextButton(
                onPressed: () {
                  if (_route?.isCurrent == true) finish();
                },
                child: const Text('关闭'))
          ])
      : recoveryStopped ? stoppedDialog() : PopScope(
      canPop: !busy && pending == null && !confirmingUnknownClose,
      onPopInvoked: (didPop) { if (!didPop) close(); },
      child: AlertDialog(
          title: Text(widget.title),
          content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                  child: Form(
                      key: form,
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (confirmingUnknownClose) ...[
                              const Notice(
                                  '服务器可能已完成原操作，关闭不会取消提交。关闭后请先核对原记录，确认结果后再操作，避免重复提交。',
                                  key: Key('class-action-unknown-close-notice'), warning: true),
                              const SizedBox(height: 16),
                            ],
                            Text(widget.description,
                                style:
                                    const TextStyle(color: muted, height: 1.6)),
                            const SizedBox(height: 20),
                            if (widget.options == null)
                              TextFormField(
                                  key: const Key('class-name'),
                                  controller: name,
                                  enabled: !locked,
                                  maxLength: 100,
                                  autofocus: true,
                                  decoration: InputDecoration(
                                      labelText: widget.fieldLabel),
                                  validator: (v) =>
                                      v == null || v.trim().isEmpty
                                          ? '请输入${widget.fieldLabel}'
                                          : null)
                            else
                              DropdownButtonFormField<String>(
                                  key: const Key('class-choice'),
                                  isExpanded: true,
                                  value: choice,
                                  decoration: InputDecoration(
                                      labelText: widget.fieldLabel),
                                  items: widget.options!.entries
                                      .map((e) => DropdownMenuItem(
                                          value: e.key,
                                          child: Text(e.value,
                                              overflow: TextOverflow.ellipsis)))
                                      .toList(),
                                  onChanged: locked
                                      ? null
                                      : (v) {
                                          if (!current || locked ||
                                              !widget.options!.containsKey(v)) {
                                            return;
                                          }
                                          setState(() => choice = v);
                                        },
                                  validator: (v) => v == null
                                      ? '请选择${widget.fieldLabel}'
                                      : null),
                            if (widget.options?.isEmpty == true)
                              const Padding(
                                  padding: EdgeInsets.only(top: 12),
                                  child: Notice('暂无可选记录，请先创建或刷新后重试。')),
                            if (error != null)
                              Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: FailureView(error!,
                                      reauth: widget.reauth == null || recoveryStopped ||
                                              confirmingUnknownClose
                                          ? null
                                          : reauthenticate)),
                            if (pending != null && !confirmingUnknownClose)
                              const Padding(
                                  padding: EdgeInsets.only(top: 12),
                                  child: Text(
                                      '提交结果尚未确认，已锁定原内容。请重试原提交，或关闭后刷新记录。',
                                      style: TextStyle(height: 1.6))),
                          ])))),
          actions: [
            if (confirmingUnknownClose) ...[
              TextButton(onPressed: busy ? null : keepOriginal,
                  child: const Text('继续处理原提交')),
              FilledButton(onPressed: busy ? null : confirmUnknownClose,
                  child: const Text('关闭并核对记录')),
            ] else ...[
              TextButton(key: const Key('class-action-close'),
                  onPressed: busy ? null : close,
                  child: Text(pending != null ? '暂时关闭' : '关闭')),
              FilledButton(key: const Key('class-action-submit'),
                  onPressed: busy || (pending == null && widget.options?.isEmpty == true)
                      ? null : submit,
                  child: Text(busy ? '提交中…' : pending != null ? '重试原提交' : widget.submitLabel)),
            ],
          ]));
}
