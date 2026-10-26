import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import '../core/api.dart';
import '../core/labels.dart';
import 'owned_dialog_route.dart';
import 'package:usage_reporting/usage_reporting.dart' show UsageReportFailure;

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
    final failure = switch (error) {
      ApiFailure value => value,
      UsageReportFailure value => ApiFailure(value.status, value.code),
      _ => null,
    };
    final showReauth =
        reauth != null && (failure?.status == 401 || failure == null);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Notice(failure?.message ?? '加载未完成，请重试。', warning: true),
      if (retry != null || showReauth) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          if (retry != null)
            TextButton.icon(
                onPressed: retry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试')),
          if (showReauth)
            TextButton.icon(
                onPressed: reauth,
                icon: const Icon(Icons.verified_user_outlined, size: 18),
                label: const Text('重新安全验证'))
        ]),
      ],
      if (failure != null) ...[
        const SizedBox(height: 8),
        PageStorage(
            key: ValueKey((failure.code, failure.correlationId)),
            bucket: PageStorageBucket(),
            child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(top: 4, bottom: 8),
                expandedAlignment: Alignment.centerLeft,
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                dense: true,
                minTileHeight: 48,
                shape: const Border(),
                collapsedShape: const Border(),
                title: const Text('错误详情',
                    style: TextStyle(fontSize: 12, color: muted)),
                children: [
                  SelectableText('错误代码：${failure.code}',
                      style: const TextStyle(
                          fontSize: 12, color: muted, height: 1.6)),
                  if (failure.correlationId?.isNotEmpty == true)
                    Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: SelectableText('追踪编号：${failure.correlationId}',
                            style: const TextStyle(
                                fontSize: 12, color: muted, height: 1.6))),
                ])),
      ],
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
  final int? minValue, maxValue;
  const FieldSpec(this.key, this.label,
      {this.options,
      this.required = true,
      this.hint,
      this.maxLength = 100,
      this.lines = 1,
      this.numeric = false,
      this.minValue,
      this.maxValue})
      : assert((minValue == null && maxValue == null) ||
            (numeric && options == null)),
        assert(minValue == null || maxValue == null || minValue <= maxValue);
}

/// Capture before an asynchronous action; completion cannot pop a later cover.
VoidCallback captureDialogCompletion(BuildContext context) {
  final owner = ModalRoute.of(context);
  return () {
    if (owner is OwnedDialogRoute<void>) owner.finish();
  };
}

Future<Json?> formDialog(BuildContext context,
    {required String title,
    required List<FieldSpec> fields,
    Json initial = const {},
    String? description,
    String submit = '保存',
    required Future<Json?> Function(Json) onSubmit,
    VoidCallback? reauth,
    Listenable? accessChanges,
    bool Function()? hasAccess}) async {
  final parent = ModalRoute.of(context);
  final parentClosed = ValueNotifier<bool>(false);
  var live = true, allowed = true;
  bool permitted() {
    if (!live ||
        !context.mounted ||
        parentClosed.value ||
        (parent != null && !parent.isActive) ||
        (hasAccess != null && !hasAccess())) allowed = false;
    return allowed;
  }

  parent?.popped.then<void>((_) {
    if (live) parentClosed.value = true;
  });
  try {
    return await presentOwnedDialog<Json>(
        context,
        OwnedDialogRoute<Json>(
            context: context,
            barrierDismissible: false,
            builder: (_) => EditDialog(
                title: title,
                fields: fields,
                initial: initial,
                description: description,
                submit: submit,
                accessChanges: Listenable.merge(
                    [parentClosed, if (accessChanges != null) accessChanges]),
                hasAccess: permitted,
                onSubmit: (values) async {
                  if (!permitted()) {
                    throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                  }
                  final result = await onSubmit(values);
                  if (!permitted()) {
                    throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                  }
                  return result;
                },
                reauth: reauth)));
  } finally {
    live = false;
    parentClosed.dispose();
  }
}

class EditDialog extends StatefulWidget {
  final String title, submit;
  final String? description;
  final List<FieldSpec> fields;
  final Json initial;
  final Future<Json?> Function(Json) onSubmit;
  final VoidCallback? reauth;
  final Listenable? accessChanges;
  final bool Function()? hasAccess;

  /// Keep true for server writes. False is only for callbacks that do not
  /// persist remote state, such as read-only checks and local draft preparation.
  /// The caller must guarantee that false callbacks perform no remote writes.
  final bool canCommit;
  const EditDialog(
      {super.key,
      required this.title,
      required this.fields,
      required this.initial,
      this.description,
      required this.submit,
      required this.onSubmit,
      this.reauth,
      this.accessChanges,
      this.hasAccess,
      this.canCommit = true});
  @override
  State<EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<EditDialog> {
  final form = GlobalKey<FormState>();
  final controls = <String, TextEditingController>{};
  final selected = <String, String?>{};
  Json? pendingValues;
  Json? recoveryValues;
  bool busy = false;
  bool confirmingUnknownClose = false;
  Object? error;
  ModalRoute<dynamic>? _route;
  bool _active = true, _revoked = false;
  bool _rebuildPending = false;

  void _observeAccess() {
    if (!_revoked && widget.hasAccess?.call() == false) _revoked = true;
  }

  bool get permitted {
    _observeAccess();
    return !_revoked;
  }

  bool get versionConflict =>
      error is ApiFailure && (error as ApiFailure).status == 412;

  bool get recoveryStopped =>
      widget.canCommit &&
      (versionConflict || isUnavailableOperationResult(error));

  String get recoveryDraft => widget.fields.map((field) {
        final value = recoveryValues?[field.key]?.toString() ?? '';
        final display = field.options?[value] ?? value;
        return '${field.label}：${display.isEmpty ? "（空）" : display}';
      }).join('\n');

  bool get current =>
      mounted && _active && permitted && _route?.isCurrent == true;

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

  void cancel() {
    if (!current || busy) return;
    if (pendingValues != null) {
      if (!confirmingUnknownClose) {
        setState(() => confirmingUnknownClose = true);
      }
      return;
    }
    finish();
  }

  void keepOriginal() {
    if (!current || busy || !confirmingUnknownClose) return;
    setState(() => confirmingUnknownClose = false);
  }

  void confirmUnknownClose() {
    if (!current || busy || !confirmingUnknownClose || pendingValues == null) {
      return;
    }
    finish();
  }

  @override
  void initState() {
    super.initState();
    _observeAccess();
    widget.accessChanges?.addListener(_accessChanged);
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ModalRoute.of(context);
    if (_route != null && !identical(_route, next)) _revoked = true;
    _route = next;
  }

  @override
  void didUpdateWidget(EditDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Never reinterpret an in-flight write as read-only within the same form.
    if (oldWidget.canCommit != widget.canCommit) _revoked = true;
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
    for (final c in controls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (!current ||
        busy ||
        recoveryStopped ||
        confirmingUnknownClose ||
        form.currentState?.validate() != true) return;
    final canCommit = widget.canCommit;
    final retryingUnknown = canCommit && pendingValues != null;
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
      final submitted = canCommit ? (pendingValues ?? values) : values;
      if (canCommit) pendingValues = submitted;
      if (!current) return;
      final result = await widget.onSubmit(submitted);
      if (mounted && _active && permitted) finish(result ?? submitted);
    } catch (e) {
      if (canCommit) {
        final attempted = pendingValues;
        final stopped = e is ApiFailure &&
            (e.status == 412 || isUnavailableOperationResult(e));
        if (stopped && attempted != null) {
          recoveryValues = Map<String, dynamic>.unmodifiable(attempted);
        }
        // A later rejection cannot prove that the first uncertain write failed.
        final unknown = retryingUnknown ||
            e is! ApiFailure ||
            e.status == 0 ||
            e.status >= 500 ||
            e.code == 'PENDING_OPERATION_UNCHANGED';
        if (stopped || !unknown) pendingValues = null;
      } else {
        pendingValues = null;
        recoveryValues = null;
        confirmingUnknownClose = false;
      }
      if (mounted && _active && permitted) setState(() => error = e);
    } finally {
      if (mounted && _active) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => !permitted
      ? AlertDialog(
          title: const Text('工作空间或权限已变化'),
          content: Text(widget.canCommit
              ? '已隐藏原表单内容。请关闭后在当前工作空间重新打开；已提交的操作请回到原工作空间刷新列表核对结果。'
              : '已隐藏原表单内容。请关闭后在当前工作空间重新打开。'),
          actions: [TextButton(onPressed: finish, child: const Text('关闭'))])
      : PopScope(
          canPop: !busy && pendingValues == null,
          onPopInvoked: (didPop) {
            if (!didPop) cancel();
          },
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
                                      padding:
                                          const EdgeInsets.only(bottom: 20),
                                      child: Notice(widget.description!)),
                                if (pendingValues != null && !busy)
                                  Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 16),
                                      child: Notice(
                                          confirmingUnknownClose
                                              ? '服务器可能已完成原操作，关闭不会取消提交。关闭后请先刷新列表核对结果，确认后再新建。'
                                              : '上次提交结果尚未确认。重试将发送相同内容；离开后请先刷新列表核对结果，避免重复创建。',
                                          key: confirmingUnknownClose
                                              ? const Key(
                                                  'edit-dialog-unknown-close-notice')
                                              : null,
                                          warning: true)),
                                if (recoveryStopped) ...[
                                  FailureView(error!),
                                  Text(
                                      versionConflict
                                          ? '记录已更新，已停止再次提交。可选中并复制下方草稿；关闭后请刷新原页面，再重新打开表单核对最新内容。'
                                          : '原操作结果已无法恢复，已停止再次提交。请关闭后核对当前记录；不要把结果不可恢复当作操作未执行。',
                                      style: const TextStyle(height: 1.6)),
                                  if (widget.fields.isNotEmpty) ...[
                                    const SizedBox(height: 12),
                                    const Text('保留的草稿',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600)),
                                    const SizedBox(height: 8),
                                    SelectableText(recoveryDraft,
                                        style: const TextStyle(height: 1.6)),
                                  ],
                                ] else
                                  ...widget.fields.map((f) => Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 18),
                                      child: f.options != null
                                          ? DropdownButtonFormField<String>(
                                              value: selected[f.key],
                                              isExpanded: true,
                                              decoration: InputDecoration(
                                                  labelText: f.label),
                                              items: f.options!.entries
                                                  .map((e) => DropdownMenuItem(
                                                      value: e.key,
                                                      child: Text(e.value,
                                                          overflow: TextOverflow
                                                              .ellipsis)))
                                                  .toList(),
                                              onChanged: busy ||
                                                      pendingValues != null
                                                  ? null
                                                  : (v) {
                                                      if (!current ||
                                                          busy ||
                                                          recoveryStopped ||
                                                          confirmingUnknownClose ||
                                                          pendingValues !=
                                                              null ||
                                                          (v != null &&
                                                              !f.options!
                                                                  .containsKey(
                                                                      v))) {
                                                        return;
                                                      }
                                                      setState(() =>
                                                          selected[f.key] = v);
                                                    },
                                              validator: (v) => f.required && (v == null || v.isEmpty)
                                                  ? '请选择${f.label}'
                                                  : null)
                                          : TextFormField(
                                              controller: controls[f.key],
                                              enabled: !busy &&
                                                  pendingValues == null,
                                              autofocus:
                                                  f == widget.fields.first,
                                              decoration: InputDecoration(
                                                  labelText: f.label,
                                                  hintText: f.hint),
                                              maxLines: f.lines,
                                              maxLength: f.maxLength,
                                              keyboardType: f.numeric
                                                  ? TextInputType.number
                                                  : TextInputType.text,
                                              inputFormatters: f.numeric
                                                  ? [FilteringTextInputFormatter.digitsOnly]
                                                  : null,
                                              validator: (v) {
                                                if (f.required &&
                                                    (v ?? '').trim().isEmpty) {
                                                  return '请输入${f.label}';
                                                }
                                                if (f.numeric &&
                                                    v != null &&
                                                    v.isNotEmpty) {
                                                  final number = int.tryParse(v);
                                                  if (number == null) {
                                                    return '请输入有效整数';
                                                  }
                                                  final minimum = f.minValue;
                                                  final maximum = f.maxValue;
                                                  if (minimum != null && number < minimum) {
                                                    return '不能小于 $minimum';
                                                  }
                                                  if (maximum != null && number > maximum) {
                                                    return '不能大于 $maximum';
                                                  }
                                                }
                                                return null;
                                              }))),
                                if (error != null && !recoveryStopped)
                                  FailureView(error!,
                                      reauth: widget.reauth == null
                                          ? null
                                          : () {
                                              if (current &&
                                                  !busy &&
                                                  !recoveryStopped &&
                                                  !confirmingUnknownClose) {
                                                widget.reauth!();
                                              }
                                            })
                              ])))),
              actions: [
                if (recoveryStopped)
                  FilledButton(
                      onPressed: busy ? null : cancel,
                      child: const Text('关闭表单')),
                if (!recoveryStopped && confirmingUnknownClose) ...[
                  TextButton(
                      key: const Key('edit-dialog-keep-original'),
                      onPressed: busy ? null : keepOriginal,
                      child: const Text('继续核对')),
                  FilledButton(
                      key: const Key('edit-dialog-confirm-close'),
                      onPressed: busy ? null : confirmUnknownClose,
                      child: const Text('确认关闭')),
                ],
                if (!recoveryStopped && !confirmingUnknownClose)
                  TextButton(
                      onPressed: busy ? null : cancel,
                      child: Text(pendingValues == null ? '取消' : '暂时关闭')),
                if (!recoveryStopped && !confirmingUnknownClose)
                  FilledButton(
                      onPressed: busy ? null : save,
                      child: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(
                              pendingValues == null ? widget.submit : '重试原提交'))
              ]));
}

Future<bool> confirmAction(BuildContext context, String title, String body,
    {String confirm = '确认'}) async {
  late final OwnedDialogRoute<bool> route;
  void finish(bool value) {
    if (route.available && route.isCurrent) route.finish(value);
  }

  route = OwnedDialogRoute<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
              title: Text(title),
              content: SizedBox(
                  width: 460,
                  child: Text(body, style: const TextStyle(height: 1.8))),
              actions: [
                TextButton(
                    onPressed: () => finish(false), child: const Text('取消')),
                FilledButton(
                    onPressed: () => finish(true), child: Text(confirm))
              ]));
  return await presentOwnedDialog(context, route) ?? false;
}

Future<void> showDetails(
    BuildContext context, String title, Map<String, dynamic> values,
    {List<Widget> actions = const []}) {
  late final OwnedDialogRoute<void> route;
  void finish() {
    if (route.available && route.isCurrent) route.finish();
  }

  route = OwnedDialogRoute<void>(
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
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  child:
                                      Column(
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
                TextButton(onPressed: finish, child: const Text('关闭'))
              ]));
  return presentOwnedDialog(context, route);
}

class DetailAction {
  final String label;
  final Future<void> Function(BuildContext) run;
  final bool destructive;
  final bool closeOnSuccess;
  const DetailAction(this.label, this.run,
      {this.destructive = false, this.closeOnSuccess = true});
}

Future<void> actionDetails(
    BuildContext context, String title, Map<String, dynamic> values,
    {List<DetailAction> actions = const [],
    VoidCallback? reauth,
    Listenable? accessChanges,
    bool Function()? hasAccess,
    Widget? extraContent}) async {
  var live = true, allowed = true;
  bool permitted() {
    if (!live) return false;
    if (hasAccess != null && !hasAccess()) allowed = false;
    return allowed;
  }

  void observeAccess() {
    permitted();
  }

  accessChanges?.addListener(observeAccess);
  late final OwnedDialogRoute<void> route;
  void closeCurrent() {
    if (route.available && route.isCurrent) route.finish();
  }

  try {
    route = OwnedDialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          Widget content() => !permitted()
              ? AlertDialog(
                  title: const Text('工作空间或权限已变化'),
                  content: const Text('已隐藏原窗口内容。请关闭窗口，在当前工作空间重新打开。'),
                  actions: [
                      TextButton(
                          onPressed: closeCurrent, child: const Text('关闭'))
                    ])
              : _ActionDetails(
                  title,
                  values,
                  actions,
                  reauth,
                  extraContent,
                  permitted,
                  () => route.available && route.isCurrent,
                  () => route.finish());
          return accessChanges == null
              ? content()
              : AnimatedBuilder(
                  animation: accessChanges, builder: (_, __) => content());
        });
    await presentOwnedDialog(context, route);
  } finally {
    live = false;
    accessChanges?.removeListener(observeAccess);
  }
}

class _ActionDetails extends StatefulWidget {
  final String title;
  final Map<String, dynamic> values;
  final List<DetailAction> actions;
  final VoidCallback? reauth;
  final Widget? extraContent;
  final bool Function() permitted, onTop;
  final VoidCallback finish;
  const _ActionDetails(this.title, this.values, this.actions, this.reauth,
      this.extraContent, this.permitted, this.onTop, this.finish);
  @override
  State<_ActionDetails> createState() => _ActionDetailsState();
}

class _ActionDetailsState extends State<_ActionDetails> {
  bool busy = false;
  Object? error;
  Future<void> perform(DetailAction action) async {
    if (!mounted || busy || !widget.permitted() || !widget.onTop()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action.run(context);
      if (mounted && widget.permitted() && action.closeOnSuccess) {
        widget.finish();
      }
    } catch (e) {
      if (mounted && widget.permitted()) setState(() => error = e);
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
                        child: Semantics(
                            label: '${e.key}：${e.value?.toString() ?? '—'}',
                            child: ExcludeSemantics(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text(e.key,
                                      style: const TextStyle(
                                          fontSize: 12, color: muted)),
                                  const SizedBox(height: 4),
                                  SelectableText(e.value?.toString() ?? '—',
                                      style: const TextStyle(
                                          fontSize: 14, height: 1.6))
                                ]))))),
                    if (widget.extraContent != null) widget.extraContent!,
                    if (error != null)
                      FailureView(error!,
                          reauth: widget.reauth == null
                              ? null
                              : () {
                                  if (mounted &&
                                      widget.permitted() &&
                                      widget.onTop()) widget.reauth!();
                                })
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
                onPressed: busy
                    ? null
                    : () {
                        if (mounted && widget.onTop()) widget.finish();
                      },
                child: Text(busy ? '处理中…' : '关闭'))
          ]));
}
