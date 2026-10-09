import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/api.dart';
import '../core/labels.dart';

const navy = Color(0xFF19335C);
const ink = Color(0xFF172238);
const muted = Color(0xFF67758A);
const line = Color(0xFFE2E8F0);
const canvas = Color(0xFFF5F7FB);
ThemeData consoleTheme() => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
          seedColor: navy, primary: navy, surface: Colors.white),
      scaffoldBackgroundColor: canvas,
      fontFamily: 'Microsoft YaHei',
      textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 14, color: ink, height: 1.5),
          bodySmall: TextStyle(fontSize: 12, color: muted),
          titleLarge:
              TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: ink),
          titleMedium:
              TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ink)),
      appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0),
      inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: line)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: line))),
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)))),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 42),
              side: const BorderSide(color: line),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)))),
      dividerTheme: const DividerThemeData(color: line, space: 1),
      dialogTheme: DialogTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
      dataTableTheme: const DataTableThemeData(
          headingRowColor: WidgetStatePropertyAll(Color(0xFFF7F9FC)),
          headingTextStyle: TextStyle(
              color: muted, fontSize: 12, fontWeight: FontWeight.w600),
          dataTextStyle: TextStyle(color: ink, fontSize: 14),
          dividerThickness: 0.5,
          dataRowMinHeight: 64,
          dataRowMaxHeight: 80),
    );

class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const Panel(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(24)});
  @override
  Widget build(BuildContext context) => Container(
      padding: padding,
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: line)),
      child: child);
}

class PageHeading extends StatelessWidget {
  final String title, subtitle;
  final Widget? action;
  const PageHeading(this.title, this.subtitle, {super.key, this.action});
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 24,
          runSpacing: 16,
          children: [
            SizedBox(
                width: MediaQuery.sizeOf(context).width < 600
                    ? double.infinity
                    : null,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              color: ink)),
                      const SizedBox(height: 6),
                      Text(subtitle,
                          style: const TextStyle(color: muted, fontSize: 14))
                    ])),
            if (action != null) action!
          ]));
}

class StatusTag extends StatelessWidget {
  final dynamic value;
  const StatusTag(this.value, {super.key});
  @override
  Widget build(BuildContext context) {
    final raw = value?.toString() ?? '';
    final positive =
        ['ACTIVE', 'ACCEPTED', 'ONLINE', 'STORED', 'CONNECTED'].contains(raw);
    final negative = ['REVOKED', 'DENIED', 'EXPIRED', 'INVALIDATED', 'REJECTED']
        .contains(raw);
    final color = positive
        ? const Color(0xFF00886C)
        : negative
            ? const Color(0xFFA7473C)
            : const Color(0xFF68788F);
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
            color: color.withOpacity(.08),
            borderRadius: BorderRadius.circular(6)),
        child: Text(label(value),
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w500)));
  }
}

class Notice extends StatelessWidget {
  final String text;
  final bool warning;
  const Notice(this.text, {super.key, this.warning = false});
  @override
  Widget build(BuildContext context) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: warning ? const Color(0xFFFFF7E9) : const Color(0xFFEDF4FC),
          borderRadius: BorderRadius.circular(8)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(warning ? Icons.info_outline : Icons.lightbulb_outline,
            size: 20, color: warning ? const Color(0xFF916018) : navy),
        const SizedBox(width: 10),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    color: warning ? const Color(0xFF795016) : navy,
                    fontSize: 13,
                    height: 1.6)))
      ]));
}

class FailureView extends StatelessWidget {
  final Object error;
  final VoidCallback? retry, reauth;
  const FailureView(this.error, {super.key, this.retry, this.reauth});
  @override
  Widget build(BuildContext context) {
    final failure = error is ApiFailure ? error as ApiFailure : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Notice(failure?.message ?? '加载未完成，请重试。', warning: true),
      if (failure != null)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SelectableText(
                '${failure.code}${failure.correlationId == null ? '' : ' · ${failure.correlationId}'}',
                style: const TextStyle(fontSize: 11, color: muted))),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [
        if (retry != null)
          TextButton.icon(
              onPressed: retry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试')),
        if (reauth != null && (failure?.status == 401 || failure == null))
          TextButton.icon(
              onPressed: reauth,
              icon: const Icon(Icons.verified_user_outlined, size: 18),
              label: const Text('重新安全验证'))
      ])
    ]);
  }
}

class EmptyView extends StatelessWidget {
  final String title, description;
  final Widget? action;
  const EmptyView(this.title, this.description, {super.key, this.action});
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
      child: Center(
          child: Column(children: [
        const Icon(Icons.inbox_outlined, size: 40, color: Color(0xFF9AA8BA)),
        const SizedBox(height: 14),
        Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(description,
            textAlign: TextAlign.center,
            style: const TextStyle(color: muted, height: 1.6)),
        if (action != null)
          Padding(padding: const EdgeInsets.only(top: 20), child: action!)
      ])));
}

void toast(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));

class FieldSpec {
  final String key, label;
  final Map<String, String>? options;
  final bool required;
  final String? hint;
  final int maxLength;
  final int lines;
  final bool numeric;
  const FieldSpec(this.key, this.label,
      {this.options,
      this.required = true,
      this.hint,
      this.maxLength = 100,
      this.lines = 1,
      this.numeric = false});
}

Future<Json?> formDialog(BuildContext context,
        {required String title,
        required List<FieldSpec> fields,
        Json initial = const {},
        String? description,
        String submit = '保存',
        required Future<Json?> Function(Json) onSubmit,
        VoidCallback? reauth}) =>
    showDialog<Json>(
        context: context,
        barrierDismissible: false,
        builder: (_) => EditDialog(
            title: title,
            fields: fields,
            initial: initial,
            description: description,
            submit: submit,
            onSubmit: onSubmit,
            reauth: reauth));

class EditDialog extends StatefulWidget {
  final String title, submit;
  final String? description;
  final List<FieldSpec> fields;
  final Json initial;
  final Future<Json?> Function(Json) onSubmit;
  final VoidCallback? reauth;
  const EditDialog(
      {super.key,
      required this.title,
      required this.fields,
      required this.initial,
      this.description,
      required this.submit,
      required this.onSubmit,
      this.reauth});
  @override
  State<EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<EditDialog> {
  final form = GlobalKey<FormState>();
  final controls = <String, TextEditingController>{};
  final selected = <String, String?>{};
  Json? pendingValues;
  bool busy = false;
  Object? error;
  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      if (f.options != null) {
        selected[f.key] = widget.initial[f.key]?.toString();
      } else {
        controls[f.key] = TextEditingController(
            text: widget.initial[f.key]?.toString() ?? '');
      }
    }
  }

  @override
  void dispose() {
    for (final c in controls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final values = <String, dynamic>{};
      for (final f in widget.fields) {
        final v =
            f.options != null ? selected[f.key] : controls[f.key]!.text.trim();
        values[f.key] =
            f.numeric ? (v == null || v.isEmpty ? null : int.parse(v)) : v;
      }
      final submitted = pendingValues ?? values;
      pendingValues = submitted;
      final result = await widget.onSubmit(submitted);
      if (mounted) Navigator.pop(context, result ?? values);
    } catch (e) {
      if (e is! ApiFailure || (e.status != 0 && e.status < 500)) {
        pendingValues = null;
      }
      if (mounted) setState(() => error = e);
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
                            if (widget.description != null)
                              Padding(
                                  padding: const EdgeInsets.only(bottom: 20),
                                  child: Notice(widget.description!)),
                            if (pendingValues != null && !busy)
                              const Padding(
                                  padding: EdgeInsets.only(bottom: 16),
                                  child: Notice(
                                      '上次提交结果尚未确认。重试将发送相同内容；离开后请先刷新列表核对结果，避免重复创建。',
                                      warning: true)),
                            ...widget.fields.map((f) => Padding(
                                padding: const EdgeInsets.only(bottom: 18),
                                child: f.options != null
                                    ? DropdownButtonFormField<String>(
                                        value: selected[f.key],
                                        isExpanded: true,
                                        decoration:
                                            InputDecoration(labelText: f.label),
                                        items: f.options!.entries
                                            .map((e) => DropdownMenuItem(
                                                value: e.key,
                                                child: Text(e.value,
                                                    overflow:
                                                        TextOverflow.ellipsis)))
                                            .toList(),
                                        onChanged: busy || pendingValues != null
                                            ? null
                                            : (v) => setState(
                                                () => selected[f.key] = v),
                                        validator: (v) => f.required &&
                                                (v == null || v.isEmpty)
                                            ? '请选择${f.label}'
                                            : null)
                                    : TextFormField(
                                        controller: controls[f.key],
                                        enabled: !busy && pendingValues == null,
                                        autofocus: f == widget.fields.first,
                                        decoration: InputDecoration(
                                            labelText: f.label,
                                            hintText: f.hint),
                                        maxLines: f.lines,
                                        maxLength: f.maxLength,
                                        keyboardType: f.numeric
                                            ? TextInputType.number
                                            : TextInputType.text,
                                        inputFormatters: f.numeric
                                            ? [
                                                FilteringTextInputFormatter
                                                    .digitsOnly
                                              ]
                                            : null,
                                        validator: (v) {
                                          if (f.required &&
                                              (v ?? '').trim().isEmpty) {
                                            return '请输入${f.label}';
                                          }
                                          if (f.numeric &&
                                              v != null &&
                                              v.isNotEmpty &&
                                              int.tryParse(v) == null) {
                                            return '请输入有效整数';
                                          }
                                          return null;
                                        }))),
                            if (error != null)
                              FailureView(error!, reauth: widget.reauth)
                          ])))),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
                onPressed: busy ? null : save,
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(pendingValues == null ? widget.submit : '重试原提交'))
          ]));
}

Future<bool> confirmAction(BuildContext context, String title, String body,
        {String confirm = '确认'}) async =>
    await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(title),
                content: SizedBox(
                    width: 460,
                    child: Text(body, style: const TextStyle(height: 1.8))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(confirm))
                ])) ??
    false;

Future<void> showDetails(
        BuildContext context, String title, Map<String, dynamic> values,
        {List<Widget> actions = const []}) =>
    showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(title),
                content: SizedBox(
                    width: 650,
                    child: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: values.entries
                                .map((e) => Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 10),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(e.key,
                                              style: const TextStyle(
                                                  fontSize: 12, color: muted)),
                                          const SizedBox(height: 4),
                                          SelectableText(
                                              e.value?.toString() ?? '—',
                                              style: const TextStyle(
                                                  fontSize: 14, height: 1.6))
                                        ])))
                                .toList()))),
                actions: [
                  ...actions,
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('关闭'))
                ]));

class DetailAction {
  final String label;
  final Future<void> Function(BuildContext) run;
  final bool destructive;
  const DetailAction(this.label, this.run, {this.destructive = false});
}

Future<void> actionDetails(
        BuildContext context, String title, Map<String, dynamic> values,
        {List<DetailAction> actions = const [], VoidCallback? reauth}) =>
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ActionDetails(title, values, actions, reauth));

class _ActionDetails extends StatefulWidget {
  final String title;
  final Map<String, dynamic> values;
  final List<DetailAction> actions;
  final VoidCallback? reauth;
  const _ActionDetails(this.title, this.values, this.actions, this.reauth);
  @override
  State<_ActionDetails> createState() => _ActionDetailsState();
}

class _ActionDetailsState extends State<_ActionDetails> {
  bool busy = false;
  Object? error;
  Future<void> perform(DetailAction action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action.run(context);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e);
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
              width: 680,
              child: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    ...widget.values.entries.map((e) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.key,
                                  style: const TextStyle(
                                      fontSize: 12, color: muted)),
                              const SizedBox(height: 4),
                              SelectableText(e.value?.toString() ?? '—',
                                  style: const TextStyle(
                                      fontSize: 14, height: 1.6))
                            ]))),
                    if (error != null)
                      FailureView(error!, reauth: widget.reauth)
                  ]))),
          actions: [
            ...widget.actions.map((a) => OutlinedButton(
                onPressed: busy ? null : () => perform(a),
                style: a.destructive
                    ? OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFB44439))
                    : null,
                child: Text(a.label))),
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: Text(busy ? '处理中…' : '关闭'))
          ]));
}
