import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../core/api.dart';
import 'design.dart';
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
  Json? pending;
  ModalRoute<dynamic>? _route;
  bool _active = true, _revoked = false, _rebuildPending = false;
  bool get locked => busy || pending != null;
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
    if (current && !busy) {
      finish(refreshRequired ? <String, dynamic>{'refresh': true} : null);
    }
  }

  void reauthenticate() {
    if (current && !busy) widget.reauth?.call();
  }
  bool get refreshRequired =>
      pending != null ||
      error is ApiFailure && (error as ApiFailure).status == 412;
  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.initialName);
    _observeAccess();
    widget.accessChanges?.addListener(_accessChanged);
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
    if (!identical(oldWidget.accessChanges, widget.accessChanges)) {
      oldWidget.accessChanges?.removeListener(_accessChanged);
      widget.accessChanges?.addListener(_accessChanged);
    }
    _observeAccess();
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
    widget.accessChanges?.removeListener(_accessChanged);
    name.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!current || busy || versionConflict) return;
    if (form.currentState?.validate() != true) return;
    final body = pending ??
        <String, dynamic>{
          widget.field: widget.options == null ? name.text.trim() : choice
        };
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.onSubmit(body);
      if (mounted && _active && permitted) finish(result);
    } catch (e) {
      if (mounted && _active && permitted) {
        setState(() {
          error = e;
          pending = e is! ApiFailure || e.status == 0 || e.status >= 500
              ? Map.unmodifiable(body)
              : null;
        });
      }
    } finally {
      if (mounted && _active) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => !permitted
      ? AlertDialog(
          title: const Text('工作空间或权限已变化'),
          content: const Text('已隐藏原表单内容。请在当前工作空间重新打开；提交过的操作请先刷新列表核对结果。'),
          actions: [
            TextButton(
                onPressed: () {
                  if (_route?.isCurrent == true) finish();
                },
                child: const Text('关闭'))
          ])
      : PopScope(
      canPop: !busy,
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
                                      reauth: widget.reauth == null
                                          ? null
                                          : reauthenticate)),
                            if (pending != null)
                              const Padding(
                                  padding: EdgeInsets.only(top: 12),
                                  child: Text(
                                      '提交结果尚未确认，已锁定原内容。请重试原提交，或关闭后刷新记录。',
                                      style: TextStyle(height: 1.6))),
                          ])))),
          actions: [
            TextButton(
                onPressed: busy ? null : close,
                child: Text(refreshRequired ? '关闭并刷新' : '关闭')),
            FilledButton(
                onPressed: busy ||
                        widget.options?.isEmpty == true ||
                        versionConflict
                    ? null
                    : submit,
                child: Text(busy
                    ? '提交中…'
                    : pending != null
                        ? '重试原提交'
                        : widget.submitLabel))
          ]));
}
