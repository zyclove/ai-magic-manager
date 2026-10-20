import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/operation_result_terminal.dart';
import '../core/parent_session.dart';
import '../core/parent_api.dart';

/// A step-up can refresh the same identity's generation. Only an explicitly
/// owned authentication window may adopt it; an observed scope loss is final.
class ParentOperationIdentity {
  static final Expando<_ParentStepUpGroup> _groups = Expando<_ParentStepUpGroup>();
  final ParentSession session;
  final String? _actor, _tenant;
  final String _role;
  final _ParentStepUpGroup _group;
  final VoidCallback? onRevoked;
  final Expando<ParentApi> _scopedApis = Expando<ParentApi>();
  int _generation, _epoch = 0;
  bool _lost = false, _authenticating = false, _disposed = false;
  ParentOperationIdentity(this.session, {this.onRevoked})
      : _actor = session.profile?['subject'] as String?,
        _tenant = session.tenant?['id'] as String?, _role = session.role,
        _generation = session.generation,
        _group = (_groups[session] ??= _ParentStepUpGroup()) {
    _group.guards.add(this);
    session.addListener(_observe);
  }
  bool get _sameFields => _actor != null && _actor.isNotEmpty &&
      session.profile?['subject'] == _actor && session.tenant?['id'] == _tenant &&
      session.role == _role;
  bool get current {
    if (_lost) return false;
    final authenticated = session.authenticated ||
        (_authenticating && _group.authenticating);
    if (!_sameFields || !authenticated ||
        (!_authenticating && session.generation != _generation)) {
      revoke();
    }
    return !_lost;
  }
  bool get dispatchable => current && !_group.authenticating;
  ParentApi scopedApi(ParentApi source) => _scopedApis[source] ??= source.scoped(() {
    final epoch = _epoch;
    return () => dispatchable && _epoch == epoch;
  });
  void _observe() { current; }
  void revoke() {
    if (_lost) return;
    _lost = true;
    _epoch++;
    if (onRevoked != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) onRevoked?.call();
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  List<ParentOperationIdentity> _beginAuthentication() {
    if (!current || _group.authenticating) return const [];
    final participants = _group.guards.where((guard) => guard.current &&
        guard._actor == _actor && guard._tenant == _tenant && guard._role == _role).toList();
    _group.authenticating = true;
    for (final guard in participants) {
      guard._authenticating = true;
      guard._epoch++; // Invalidate every request captured before this window.
    }
    return participants;
  }
  void _endAuthentication(List<ParentOperationIdentity> participants, bool accepted) {
    for (final guard in participants) {
      if (accepted && session.authenticated && !guard._lost && guard._sameFields) {
        guard._generation = session.generation;
      }
      guard._authenticating = false;
      guard._epoch++;
      guard._observe();
    }
    _group.authenticating = false;
    if (_group.guards.isEmpty) _groups[session] = null;
  }
  Future<bool> reauthenticate() async {
    final participants = _beginAuthentication();
    if (participants.isEmpty) return false;
    var accepted = false;
    try {
      accepted = await session.reauthenticate();
      return accepted && session.authenticated && !_lost && _sameFields;
    } finally {
      _endAuthentication(participants, accepted);
    }
  }
  void dispose() {
    _disposed = true;
    revoke();
    session.removeListener(_observe);
    _group.guards.remove(this);
    if (_group.guards.isEmpty && !_group.authenticating) _groups[session] = null;
  }
}

class _ParentStepUpGroup {
  final Set<ParentOperationIdentity> guards = {};
  bool authenticating = false;
}

class ParentKnownOperationReceipt extends StatelessWidget {
  final ParentTerminalOperation operation;
  const ParentKnownOperationReceipt({super.key, required this.operation});
  @override
  Widget build(BuildContext context) => !operation.operationCurrent ||
      !operation.operationKnownSuccessful || operation.resultTerminal != null
      ? const SizedBox.shrink()
      : const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text(
          '本机此前已确认操作成功。当前记录可能已有后续变化，原操作不会再次提交。'));
}

/// A current-record read and ending a local check are independent actions.
class ParentResultTerminalPanel extends StatefulWidget {
  final ParentTerminalOperation operation;
  final Future<void> Function()? onViewCurrent, onEnded;
  final Widget Function(BuildContext)? currentRecordBuilder;
  const ParentResultTerminalPanel({super.key, required this.operation,
    this.onViewCurrent, this.onEnded, this.currentRecordBuilder});
  @override
  State<ParentResultTerminalPanel> createState() => _TerminalPanelState();
}

class _TerminalPanelState extends State<ParentResultTerminalPanel> {
  _TerminalConfirmation? _confirmation;
  ModalRoute<dynamic>? _owner;
  bool _ownerLost = false, _working = false, _viewing = false;
  Object? _readError;
  ParentTerminalOperation get operation => widget.operation;
  bool get available => mounted && !_ownerLost && operation.operationCurrent &&
      (_owner == null || _owner!.isActive);

  @override
  void initState() {
    super.initState();
    (operation as Listenable).addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_owner == route) return;
    _owner = route;
    route?.popped.then((_) {
      if (_owner != route) return;
      _ownerLost = true;
      _closeConfirmation();
    });
  }

  @override
  void didUpdateWidget(covariant ParentResultTerminalPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.operation == operation) return;
    (oldWidget.operation as Listenable).removeListener(_changed);
    _closeConfirmation();
    _viewing = false;
    _readError = null;
    (operation as Listenable).addListener(_changed);
  }

  void _changed() {
    if (!available) _closeConfirmation();
  }

  void _closeConfirmation() {
    final dialog = _confirmation;
    if (dialog == null) return;
    _confirmation = null;
    void finish() => dialog.finish(false);
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => finish());
    } else {
      finish();
    }
  }

  @override
  void deactivate() {
    _ownerLost = true;
    _closeConfirmation();
    super.deactivate();
  }

  @override
  void dispose() {
    (operation as Listenable).removeListener(_changed);
    _closeConfirmation();
    super.dispose();
  }

  Future<void> _viewCurrent() async {
    if (!available || operation.busy || _working || _owner?.isCurrent == false) return;
    if (widget.onViewCurrent == null) {
      final route = _owner;
      final navigator = Navigator.of(context);
      if (route?.isCurrent == true && navigator.canPop()) navigator.pop();
      return;
    }
    setState(() { _working = true; _readError = null; });
    try {
      await widget.onViewCurrent!();
      if (available) setState(() => _viewing = true);
    } catch (_) {
      if (available) setState(() => _readError = '当前记录暂时无法读取，请稍后重试。');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _end() async {
    if (!available || _owner?.isCurrent != true || operation.busy ||
        _working || _confirmation != null) return;
    final original = operation;
    final request = original.operationRequestId;
    bool current() => available && identical(original, operation) &&
        original.operationRequestId == request && original.resultTerminal != null;
    late final _TerminalConfirmation dialog;
    dialog = _TerminalConfirmation(context: context, builder: (context) {
      if (!current()) return const SizedBox.shrink();
      return AlertDialog(
        title: const Text('结束本机核对？'),
        content: const Text('这会清除本机保存的原操作内容，保留最小防重复标记。'
            '原结果仍不可恢复；这不代表未提交，不会撤销或重新执行操作。'
            '以后如需新操作，请从当前记录重新开始。'),
        actions: [
          TextButton(onPressed: () {
            if (dialog.isCurrent) dialog.finish(false);
          }, child: const Text('继续保留')),
          FilledButton(onPressed: () {
            if (current() && dialog.isCurrent) dialog.finish(true);
          }, child: const Text('结束本机核对')),
        ],
      );
    });
    _confirmation = dialog;
    Navigator.of(context).push(dialog);
    final accepted = await dialog.completion.future;
    await dialog.completed;
    final owned = identical(_confirmation, dialog);
    if (owned) _confirmation = null;
    if (!accepted || !owned || !current() || _owner?.isCurrent != true || original.busy) return;
    final endedCallback = widget.onEnded;
    final owner = _owner;
    setState(() => _working = true);
    try {
      if (await original.endLocalCheck() && original.operationCurrent &&
          (owner == null || owner.isCurrent)) await endedCallback?.call();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final terminal = operation.resultTerminal;
    if (!available || terminal == null) return const SizedBox.shrink();
    final enabled = !_working && !operation.busy;
    return Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [const Icon(Icons.history_toggle_off_outlined),
          const SizedBox(width: 12), Expanded(child: Text(terminal.title,
              style: Theme.of(context).textTheme.titleLarge))]),
        const SizedBox(height: 12),
        Text(terminal.explanation),
        const SizedBox(height: 8),
        Text(terminal.knownSuccessful
            ? '此前已经确认操作成功；原结果无法恢复，不会改变这一事实。当前记录可能已有后续变化。'
            : '这不代表从未提交。请查看当前记录或审计，确认现在的实际状态。'),
        const SizedBox(height: 8),
        const Text('本机继续保留原操作保护。查看当前记录无需先清理，当前记录也不能替代原操作的历史结果。'),
        if (_working || operation.busy) ...[const SizedBox(height: 12), const LinearProgressIndicator()],
        if (operation.terminalStorageError != null) ...[
          const SizedBox(height: 12), Text('本机记录尚未确认落盘，原操作保护仍保留。可重新打开此页后继续核对。',
              style: TextStyle(color: Theme.of(context).colorScheme.error))],
        if (_readError != null) Text('$_readError'),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(onPressed: enabled ? _viewCurrent : null,
              icon: const Icon(Icons.manage_search_outlined), child: const Text('查看当前记录')),
          OutlinedButton(onPressed: enabled ? _end : null, child: const Text('结束本机核对')),
        ]),
        if (_viewing && widget.currentRecordBuilder != null) ...[
          const Divider(height: 32), const Text('本次读取的当前状态'),
          widget.currentRecordBuilder!(context),
        ],
      ],
    )));
  }
}

/// A normal recovery confirmation owns its route and never closes a covering
/// window. Its result is usable only after that exact route has left the stack.
Future<bool> parentOperationConfirmation(BuildContext context, {
  required ParentTerminalOperation operation, required Listenable accessChanges,
  required bool Function() isCurrent, required String title,
  required String description, required String confirmLabel,
  String cancelLabel = '返回',
}) async {
  final owner = ModalRoute.of(context);
  final request = operation.operationRequestId;
  bool current() => context.mounted && isCurrent() && operation.operationCurrent &&
      operation.operationRequestId == request && owner?.isActive == true;
  if (!current() || owner?.isCurrent != true || operation.busy) return false;
  final navigator = Navigator.of(context);
  late final _TerminalConfirmation dialog;
  var disposed = false;
  void close() {
    void finish() { if (!disposed) dialog.finish(false); }
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => finish());
      WidgetsBinding.instance.ensureVisualUpdate();
    } else {
      finish();
    }
  }
  void changed() { if (!current()) close(); }
  dialog = _TerminalConfirmation(context: context, builder: (context) {
    if (!current()) return const SizedBox.shrink();
    return AlertDialog(title: Text(title),
      content: SingleChildScrollView(child: Text(description)), actions: [
        TextButton(onPressed: () {
          if (dialog.isCurrent) dialog.finish(false);
        }, child: Text(cancelLabel)),
        FilledButton(onPressed: () {
          if (current() && dialog.isCurrent) dialog.finish(true);
        }, child: Text(confirmLabel)),
      ]);
  });
  final changes = Listenable.merge([operation as Listenable, accessChanges]);
  changes.addListener(changed);
  owner!.popped.then((_) { if (!disposed) close(); });
  try {
    navigator.push(dialog);
    final accepted = await dialog.completion.future;
    await dialog.completed;
    return accepted && current() && owner!.isCurrent;
  } finally {
    disposed = true;
    changes.removeListener(changed);
  }
}

class _TerminalConfirmation extends DialogRoute<bool> {
  final Completer<bool> completion = Completer<bool>();
  _TerminalConfirmation({required super.context, required super.builder})
      : super(barrierDismissible: false);
  void finish(bool value) {
    if (!completion.isCompleted) completion.complete(value);
    final owner = navigator;
    if (owner == null || !isActive) return;
    if (isCurrent) { owner.pop(value); } else { owner.removeRoute(this); }
  }
  @override
  bool didPop(bool? result) {
    final popped = super.didPop(result);
    if (popped && !completion.isCompleted) completion.complete(result ?? false);
    return popped;
  }
  @override
  void dispose() {
    if (!completion.isCompleted) completion.complete(false);
    super.dispose();
  }
}

Widget parentResultTerminalPage(BuildContext context, {
  required String title, required ParentTerminalOperation operation,
  Future<void> Function()? onViewCurrent, Future<void> Function()? onEnded,
  Widget Function(BuildContext)? currentRecordBuilder,
}) {
  final route = ModalRoute.of(context);
  final navigator = Navigator.of(context);
  Future<void> returnToCurrent() async {
    if (operation.operationCurrent && route?.isCurrent == true && navigator.canPop()) {
      navigator.pop();
    }
  }
  return Scaffold(appBar: AppBar(title: Text(title)), body: SafeArea(
  child: ListView(padding: const EdgeInsets.all(16), children: [
    ParentResultTerminalPanel(operation: operation, onViewCurrent: onViewCurrent,
        onEnded: onEnded ?? returnToCurrent, currentRecordBuilder: currentRecordBuilder),
  ]),
));
}
