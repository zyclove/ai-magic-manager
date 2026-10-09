import 'package:flutter/material.dart';
import '../core/api.dart';
import 'design.dart';

/// Short focused mutations preserve their payload when the server result is unknown.
class ClassActionDialog extends StatefulWidget {
  final String title, description, field, fieldLabel, submitLabel;
  final String? initialName;
  final Map<String, String>? options;
  final Future<Json> Function(Json) onSubmit;
  final VoidCallback? reauth;
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
      this.reauth});
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
  bool get locked => busy || pending != null;
  bool get refreshRequired =>
      pending != null ||
      error is ApiFailure && (error as ApiFailure).status == 412;
  @override
  void initState() {
    super.initState();
    name = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
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
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e;
          pending = e is ApiFailure && (e.status == 0 || e.status >= 500)
              ? Map.unmodifiable(body)
              : null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
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
                                      : (v) => setState(() => choice = v),
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
                                      reauth: widget.reauth)),
                            if (pending != null)
                              const Padding(
                                  padding: EdgeInsets.only(top: 12),
                                  child: Text(
                                      '提交结果尚未确认，已锁定原内容。请重试原提交，或关闭后刷新记录。',
                                      style: TextStyle(height: 1.6))),
                          ])))),
          actions: [
            TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.pop(
                        context,
                        refreshRequired
                            ? <String, dynamic>{'refresh': true}
                            : null),
                child: Text(refreshRequired ? '关闭并刷新' : '关闭')),
            FilledButton(
                onPressed: busy ||
                        widget.options?.isEmpty == true ||
                        error is ApiFailure &&
                            (error as ApiFailure).status == 412
                    ? null
                    : submit,
                child: Text(busy
                    ? '提交中…'
                    : pending != null
                        ? '重试原提交'
                        : widget.submitLabel))
          ]));
}
