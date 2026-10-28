import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/member_access.dart';
import '../core/member_scope_directories.dart';
import 'design.dart';
import 'dialog_access.dart';
import 'editor_draft_text.dart';
import 'member_class_picker.dart';
import 'member_access_review.dart';
import 'owned_dialog_route.dart';

Future<Json?> memberEditorDialog(BuildContext context,
    {required String kind,
    required String operatorRole,
    Map<String, String> subjects = const {},
    Map<String, String> classes = const {},
    MemberScopeDirectories? directories,
    Json? member,
    required Future<Json> Function(Json, bool Function()) onSubmit,
    VoidCallback? reauth,
    bool retryUncertain = true,
    Listenable? accessChanges,
    bool Function()? hasAccess}) async {
  if (!context.mounted || hasAccess?.call() == false) {
    directories?.revoke();
    return null;
  }
  final access = DialogAccessBinding(context,
      accessChanges: accessChanges, hasAccess: hasAccess);
  late final OwnedDialogRoute<Json> route;
  bool accepted() =>
      route.available && route.isActive && access.permitted();
  try {
    if (!access.permitted()) return null;
    route = OwnedDialogRoute<Json>(
            context: context,
            barrierDismissible: false,
            builder: (_) => MemberEditor(
                kind: kind,
                operatorRole: operatorRole,
                subjects: subjects,
                classes: classes,
                directories: directories,
                member: member,
                retryUncertain: retryUncertain,
                accessChanges: access.changes,
                hasAccess: accepted,
                onSubmit: (body) async {
                  if (!accepted()) {
                    throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                  }
                  final result = await onSubmit(body, accepted);
                  if (!accepted()) {
                    throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                  }
                  return result;
                },
                reauth: reauth));
    return await presentOwnedDialog<Json>(context, route);
  } finally {
    directories?.revoke();
    access.dispose();
  }
}

/// The caller captures tenant, access version and retry key before opening.
class MemberEditor extends StatefulWidget {
  final String kind, operatorRole;
  final Map<String, String> subjects;
  final Map<String, String> classes;
  /// The sole option source when supplied; direct maps apply only without it.
  /// Retired with this editor window and never shared across windows.
  final MemberScopeDirectories? directories;
  final Json? member;
  final Future<Json> Function(Json) onSubmit;
  final VoidCallback? reauth;
  final Listenable? accessChanges;
  final bool Function()? hasAccess;
  final bool retryUncertain;
  const MemberEditor(
      {super.key,
      required this.kind,
      required this.operatorRole,
      this.subjects = const {},
      this.classes = const {},
      this.directories,
      required this.onSubmit,
      this.member,
      this.reauth,
      this.accessChanges,
      this.hasAccess,
      this.retryUncertain = true});
  @override
  State<MemberEditor> createState() => _MemberEditorState();
}

class _MemberEditorState extends State<MemberEditor> {
  final form = GlobalKey<FormState>(), errorAnchor = GlobalKey();
  final email = TextEditingController();
  late final List<String> roles;
  late String role;
  String? subject;
  late bool classMode;
  final selectedClasses = <String>{};
  bool busy = false;
  Json? pending, recoveryValues;
  bool confirmingUnknownClose = false, _listening = false;
  late final String initialKind, initialOperatorRole;
  late final bool initialRetryUncertain;
  late final Json? initialMember;
  late final Map<String, String> initialSubjects, initialClasses;
  late final MemberScopeDirectories? initialDirectories;
  final directoryLoading = <MemberScopeDirectory>{};
  final directoryAttempted = <MemberScopeDirectory>{};
  final directoryErrors = <MemberScopeDirectory, Object>{};
  int directoryGeneration = 0;
  Object? error;
  ModalRoute<dynamic>? _route;
  bool _active = true, _revoked = false;
  bool _rebuildPending = false;
  bool get editing => widget.member != null;
  bool get versionConflict =>
      error is ApiFailure && (error as ApiFailure).status == 412;
  bool get recoveryStopped =>
      versionConflict || isUnavailableOperationResult(error);
  bool get locked => busy || pending != null || recoveryStopped || confirmingUnknownClose;
  Json get reviewResult => editing || widget.retryUncertain
      ? <String, dynamic>{'refresh': true}
      : <String, dynamic>{'reviewInvitations': true};

  void _observeAccess() {
    if (!_revoked && (widget.hasAccess?.call() == false ||
        initialDirectories?.current == false)) {
      _revoked = true;
      directoryGeneration++;
      initialDirectories?.revoke();
    }
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

  Map<String, String>? get subjectOptions => initialDirectories == null
      ? initialSubjects : initialDirectories!.subjects;
  Map<String, String>? get classOptions => initialDirectories == null
      ? initialClasses : initialDirectories!.classes;
  MemberScopeDirectory? get requiredDirectory => role == 'TEACHER' && classMode
      ? MemberScopeDirectory.classes
      : memberNeedsSubject(role) ? MemberScopeDirectory.subjects : null;
  Map<String, String>? optionsFor(MemberScopeDirectory directory) =>
      directory == MemberScopeDirectory.subjects ? subjectOptions : classOptions;
  bool get optionsReady {
    final directory = requiredDirectory;
    return directory == null ||
        (!directoryLoading.contains(directory) && optionsFor(directory) != null);
  }

  void ensureRequiredDirectory() {
    final directory = requiredDirectory;
    if (directory == null || initialDirectories == null || !current || locked ||
        optionsFor(directory) != null || directoryAttempted.contains(directory)) return;
    unawaited(loadDirectory(directory));
  }

  Future<void> loadDirectory(MemberScopeDirectory directory, {bool refresh = false}) async {
    final repository = initialDirectories;
    if (!current || locked || repository == null || requiredDirectory != directory ||
        directoryLoading.contains(directory) ||
        (!refresh && (optionsFor(directory) != null || directoryAttempted.contains(directory)))) return;
    final generation = directoryGeneration;
    bool belongs() => mounted && _active && generation == directoryGeneration &&
        identical(initialDirectories, repository) && _route?.isActive == true &&
        (_route is! OwnedDialogRoute<dynamic> ||
            (_route as OwnedDialogRoute<dynamic>).available);
    bool accepts() => belongs() && permitted;
    setState(() {
      directoryLoading.add(directory);
      directoryAttempted.add(directory);
      directoryErrors.remove(directory);
    });
    try {
      await repository.load(directory, refresh: refresh);
    } catch (failure) {
      if (belongs()) {
        if (!repository.current ||
            (failure is ApiFailure && failure.code == 'WORKSPACE_CHANGED')) {
          repository.revoke();
          _revoked = true;
          directoryGeneration++;
          setState(() {});
        } else if (accepts()) {
          setState(() => directoryErrors[directory] = failure);
        }
      }
    } finally {
      if (accepts()) setState(() => directoryLoading.remove(directory));
    }
  }

  String missingDirectoryReference(MemberScopeDirectory directory, String id) {
    final kind = directory == MemberScopeDirectory.subjects ? '档案' : '班级';
    return optionsFor(directory) != null ? '原$kind已不可选：$id'
        : directoryErrors.containsKey(directory) ? '原$kind（选项读取失败）：$id'
        : '原$kind（选项未读取）：$id';
  }

  String? validateSubject(String? value) {
    if (subjectOptions == null) return '请先读取档案选项';
    if (value == null) return '请选择关联档案';
    return subjectOptions!.containsKey(value) ? null : '该档案已不可选，请重新选择';
  }

  String? validateClasses() {
    if (classOptions == null) return '请先读取班级选项';
    if (selectedClasses.isEmpty) return '请至少选择一个班级';
    if (selectedClasses.length > 50) return '最多选择 50 个班级';
    return selectedClasses.every(classOptions!.containsKey)
        ? null : '请移除不可用班级后重新选择';
  }

  Widget directoryStatus(MemberScopeDirectory directory) {
    if (initialDirectories == null) return const SizedBox.shrink();
    final kind = directory == MemberScopeDirectory.subjects ? '档案' : '班级';
    final keyName = directory == MemberScopeDirectory.subjects ? 'subjects' : 'classes';
    final options = optionsFor(directory);
    final failure = directoryErrors[directory];
    final loading = directoryLoading.contains(directory);
    final invalidReference = options != null &&
        (directory == MemberScopeDirectory.subjects
            ? subject != null && !options.containsKey(subject)
            : selectedClasses.any((id) => !options.containsKey(id)));
    void refresh() => unawaited(loadDirectory(directory, refresh: true));
    return Padding(padding: const EdgeInsets.only(bottom: 12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (loading) ...[
        LinearProgressIndicator(key: Key('member-$keyName-loading')),
        const SizedBox(height: 6),
        Text('正在读取$kind选项；仍可切换角色或访问范围。',
            style: const TextStyle(color: muted, fontSize: 12)),
      ] else if (failure != null) ...[
        Text('$kind选项读取未完成，原关联编号已保留。可重试或切换角色。'),
        FailureView(failure, retry: locked ? null : refresh,
            reauth: widget.reauth == null || locked ? null : () {
              if (current && !locked && requiredDirectory == directory) {
                widget.reauth!();
              }
            }),
      ] else
        TextButton.icon(key: Key('member-$keyName-refresh'),
            onPressed: locked ? null : refresh,
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(options == null ? '读取$kind选项' : '重新加载选项')),
      if (invalidReference)
        Text('原$kind已不在当前可选范围，请重新选择后保存。',
            style: const TextStyle(color: muted, fontSize: 12)),
    ]));
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
    if (recoveryStopped) {
      finish(reviewResult);
    } else if (pending != null) {
      if (!confirmingUnknownClose) {
        setState(() => confirmingUnknownClose = true);
      }
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
    finish(reviewResult);
  }

  void closeRevoked() {
    if (mounted && _active && _route?.isCurrent == true) finish();
  }

  bool get changed =>
      !editing ||
      role != widget.member!['role'] ||
      (memberNeedsSubject(role) && !(role == 'TEACHER' && classMode)
              ? subject
              : null) !=
          widget.member!['subjectId'] ||
      !setEquals(role == 'TEACHER' && classMode ? selectedClasses : <String>{},
          Set<String>.from(widget.member?['classIds'] as List? ?? const []));
  @override
  void initState() {
    super.initState();
    initialKind = widget.kind;
    initialOperatorRole = widget.operatorRole;
    initialRetryUncertain = widget.retryUncertain;
    initialDirectories = widget.directories;
    initialSubjects = Map<String, String>.unmodifiable(widget.subjects);
    initialClasses = Map<String, String>.unmodifiable(widget.classes);
    initialMember = widget.member == null ? null : Map<String, dynamic>.unmodifiable({
      ...widget.member!,
      if (widget.member!['classIds'] is List)
        'classIds': List<Object?>.unmodifiable(widget.member!['classIds'] as List),
    });
    _observeAccess();
    if (!_revoked && widget.accessChanges != null) {
      widget.accessChanges!.addListener(_accessChanged);
      _listening = true;
    }
    roles = memberRoles(widget.kind, widget.operatorRole,
        currentRole: widget.member?['role']);
    role = widget.member?['role'] as String? ??
        (roles.contains('AUDITOR')
            ? 'AUDITOR'
            : roles.isEmpty
                ? ''
                : roles.first);
    subject = widget.member?['subjectId'] as String?;
    classMode = subject == null;
    selectedClasses.addAll(
        List<String>.from(widget.member?['classIds'] as List? ?? const []));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _active) ensureRequiredDirectory();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = ModalRoute.of(context);
    if (_route != null && !identical(_route, next)) _revoked = true;
    _route = next;
  }

  bool sameMember(Json? first, Json? second) {
    if (first == null || second == null) return first == null && second == null;
    final left = Map<String, dynamic>.from(first)..remove('classIds');
    final right = Map<String, dynamic>.from(second)..remove('classIds');
    return mapEquals(left, right) &&
        listEquals(first['classIds'] as List?, second['classIds'] as List?);
  }

  @override
  void didUpdateWidget(MemberEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasRevoked = _revoked;
    if (oldWidget.hasAccess?.call() == false ||
        initialKind != widget.kind || initialOperatorRole != widget.operatorRole ||
        initialRetryUncertain != widget.retryUncertain ||
        !identical(initialDirectories, widget.directories) ||
        (initialDirectories == null &&
            (!mapEquals(initialSubjects, widget.subjects) ||
             !mapEquals(initialClasses, widget.classes))) ||
        !sameMember(initialMember, widget.member)) _revoked = true;
    if (_revoked) {
      if (!wasRevoked) directoryGeneration++;
      initialDirectories?.revoke();
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
    directoryGeneration++;
    initialDirectories?.revoke();
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
    directoryGeneration++;
    initialDirectories?.revoke();
    if (_listening) widget.accessChanges?.removeListener(_accessChanged);
    email.dispose();
    super.dispose();
  }

  void revealError() {
    if (!current) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!current) return;
      final target = errorAnchor.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target,
            alignment: 1,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut);
      }
    });
  }

  Json draftBody() {
    final classes = selectedClasses.toList()..sort();
    return Map<String, dynamic>.unmodifiable({
      if (!editing) 'recipientEmail': email.text.trim(),
      'role': role,
      if (memberNeedsSubject(role) && !(role == 'TEACHER' && classMode))
        'subjectId': subject,
      if (role == 'TEACHER' && classMode)
        'classIds': List<String>.unmodifiable(classes),
    });
  }

  Future<void> save() async {
    if (!current || busy || recoveryStopped || confirmingUnknownClose ||
        (pending != null && !widget.retryUncertain)) return;
    final retryingUnknown = pending != null;
    if (!retryingUnknown &&
        (!optionsReady || form.currentState?.validate() != true || roles.isEmpty || !changed)) return;
    final body = pending ?? draftBody();
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
          // Rejection of a retry cannot prove that the first write failed.
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
        revealError();
      }
    } finally {
      if (mounted && _active && permitted) setState(() => busy = false);
    }
  }

  Widget stoppedDialog() => PopScope(
      canPop: false,
      onPopInvoked: (didPop) { if (!didPop) cancel(); },
      child: AlertDialog(
          title: const Text('已停止再次提交'),
          content: SizedBox(width: 560, child: SingleChildScrollView(
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
                SelectableText(memberDraftText(recoveryValues ?? const {},
                    subjects: subjectOptions ?? const {}, classes: classOptions ?? const {}),
                    key: const Key('member-editor-recovery-draft'),
                    style: const TextStyle(height: 1.6)),
              ]))),
          actions: [TextButton(key: const Key('member-editor-close'),
              onPressed: busy ? null : cancel,
              child: const Text('关闭并核对记录'))]));

  @override
  Widget build(BuildContext context) => !permitted
      ? AlertDialog(
          title: const Text('工作空间或权限已变化'),
          content: const Text('已隐藏原表单内容。请关闭后在当前工作空间重新打开；已提交的操作请回到原工作空间刷新列表核对结果。'),
          actions: [TextButton(onPressed: closeRevoked, child: const Text('关闭'))])
      : recoveryStopped ? stoppedDialog() : PopScope(
      canPop: !busy && pending == null && !confirmingUnknownClose,
      onPopInvoked: (didPop) { if (!didPop) cancel(); },
      child: AlertDialog(
        title: Text(editing ? '调整成员权限' : '邀请成员'),
        content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
                child: Form(
                    key: form,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (confirmingUnknownClose) ...[
                            const Notice(
                                '服务器可能已完成原操作，关闭不会取消提交。关闭后请先核对原记录，确认结果后再创建或调整，避免重复操作。',
                                key: Key('member-editor-unknown-close-notice'),
                                warning: true),
                            const SizedBox(height: 16),
                          ],
                          if (editing) ...[
                            Text(memberName(widget.member!),
                                style: const TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            SelectableText(widget.member!['actorId'] as String),
                            const SizedBox(height: 12),
                            Text(
                                '当前权限：${label(widget.member!['role'])} · ${memberScope(widget.member!)}',
                                style:
                                    const TextStyle(color: muted, height: 1.5)),
                          ] else ...[
                            const Text('收件人需要使用已验证的同一邮箱接受邀请。成人角色还需完成安全验证。',
                                style: TextStyle(color: muted, height: 1.6)),
                            const SizedBox(height: 20),
                            TextFormField(
                                key: const Key('member-email'),
                                controller: email,
                                enabled: !locked,
                                maxLength: 254,
                                keyboardType: TextInputType.emailAddress,
                                autofillHints: const [AutofillHints.email],
                                decoration:
                                    const InputDecoration(labelText: '收件人邮箱'),
                                validator: (v) => v == null ||
                                        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                            .hasMatch(v.trim())
                                    ? '请输入有效邮箱'
                                    : null),
                          ],
                          const SizedBox(height: 20),
                          DropdownButtonFormField<String>(
                              key: const Key('member-role'),
                              value: roles.contains(role) ? role : null,
                              isExpanded: true,
                              decoration:
                                  const InputDecoration(labelText: '成员角色'),
                              items: roles
                                  .map((r) => DropdownMenuItem(
                                      value: r, child: Text(label(r))))
                                  .toList(),
                              onChanged: locked
                                  ? null
                                  : (v) {
                                      if (!current ||
                                          locked ||
                                          v == null ||
                                          !roles.contains(v)) return;
                                      setState(() => role = v);
                                      ensureRequiredDirectory();
                                    },
                              validator: (v) =>
                                  v == null ? '当前成员不可调整角色' : null),
                          const SizedBox(height: 10),
                          Text(memberRoleDescription(role),
                              style:
                                  const TextStyle(color: muted, height: 1.6)),
                          if (role == 'TEACHER') ...[
                            const SizedBox(height: 20),
                            DropdownButtonFormField<bool>(
                              key: const Key('member-scope-mode'),
                              value: classMode,
                              decoration:
                                  const InputDecoration(labelText: '教师访问范围'),
                              items: const [
                                DropdownMenuItem(
                                    value: true, child: Text('一个或多个班级')),
                                DropdownMenuItem(
                                    value: false, child: Text('单个档案'))
                              ],
                              onChanged: locked
                                  ? null
                                  : (v) {
                                      if (!current || locked || v == null) return;
                                      setState(() => classMode = v);
                                      ensureRequiredDirectory();
                                    },
                            ),
                            if (classMode) ...[
                              const SizedBox(height: 14),
                              directoryStatus(MemberScopeDirectory.classes),
                              FormField<Set<String>>(
                                initialValue: selectedClasses,
                                validator: (_) => validateClasses(),
                                builder: (field) => Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (classOptions?.isEmpty == true &&
                                          selectedClasses.isEmpty)
                                        const Notice('暂无可选班级。请先在“班级与名册”中新建班级。'),
                                      MemberClassPicker(
                                          options: classOptions,
                                          selectedIds: Set<String>.unmodifiable(selectedClasses),
                                          enabled: !locked,
                                          canInteract: () => current && !locked &&
                                              role == 'TEACHER' && classMode,
                                          unavailableLabel: (id) => missingDirectoryReference(
                                              MemberScopeDirectory.classes, id),
                                          onChanged: (id, selected) {
                                            if (!current || locked || role != 'TEACHER' || !classMode ||
                                                selectedClasses.contains(id) == selected ||
                                                (selected && (selectedClasses.length >= 50 ||
                                                    classOptions?.containsKey(id) != true))) return;
                                            setState(() {
                                              if (selected) {
                                                selectedClasses.add(id);
                                              } else {
                                                selectedClasses.remove(id);
                                              }
                                            });
                                            field.didChange(Set.of(selectedClasses));
                                          }),
                                      if (field.hasError)
                                        Padding(
                                            padding:
                                                const EdgeInsets.only(top: 8),
                                            child: Text(field.errorText!,
                                                style: TextStyle(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .error))),
                                    ]),
                              ),
                            ],
                          ],
                          if (memberNeedsSubject(role) &&
                              !(role == 'TEACHER' && classMode)) ...[
                            const SizedBox(height: 20),
                            directoryStatus(MemberScopeDirectory.subjects),
                            DropdownButtonFormField<String>(
                                key: const Key('member-subject'),
                                value: subject,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                    labelText: '关联档案', hintText: '请选择档案'),
                                items: [
                                  for (final entry in (subjectOptions ?? const <String, String>{}).entries)
                                    DropdownMenuItem(value: entry.key,
                                        child: Text(entry.value, overflow: TextOverflow.ellipsis)),
                                  if (subject != null && subjectOptions?.containsKey(subject) != true)
                                    DropdownMenuItem(value: subject, enabled: false,
                                        child: Text(missingDirectoryReference(
                                            MemberScopeDirectory.subjects, subject!),
                                            overflow: TextOverflow.ellipsis)),
                                ],
                                onChanged: locked
                                    ? null
                                    : (v) {
                                        if (!current || locked || !memberNeedsSubject(role) ||
                                            (role == 'TEACHER' && classMode) ||
                                            (v != null &&
                                                !(subjectOptions ?? const <String, String>{}).containsKey(v))) return;
                                        setState(() => subject = v);
                                      },
                                validator: validateSubject),
                            if (subjectOptions?.isEmpty == true)
                              const Padding(
                                  padding: EdgeInsets.only(top: 10),
                                  child: Notice('暂无可选档案。请先在“儿童档案”中创建档案。',
                                      warning: true)),
                          ],
                          const SizedBox(height: 20),
                          if (editing) ...[
                            MemberAccessReview(original: initialMember!,
                                proposed: pending ?? recoveryValues ?? draftBody(),
                                subjectNames: subjectOptions ?? const {},
                                classNames: classOptions ?? const {}),
                            const SizedBox(height: 16),
                          ],
                          Notice(editing
                              ? memberConsequences
                              : '邀请有效期为 24 小时。创建后请复制令牌并安全交给收件人；系统尚未发送邮件。'),
                          if (error != null)
                            Padding(
                                key: errorAnchor,
                                padding: const EdgeInsets.only(top: 16),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      FailureView(error!,
                                          reauth: widget.reauth == null ||
                                                  recoveryStopped || confirmingUnknownClose
                                              ? null
                                              : () {
                                                  if (current &&
                                                      !busy &&
                                                      !recoveryStopped &&
                                                      !confirmingUnknownClose) {
                                                    widget.reauth!();
                                                  }
                                                }),
                                      if (pending != null && !confirmingUnknownClose)
                                        Padding(
                                            padding:
                                                const EdgeInsets.only(top: 10),
                                            child: Text(
                                                widget.retryUncertain
                                                    ? '提交结果尚未确认，已锁定原内容。请重试原提交，或关闭后刷新记录。'
                                                    : '邀请可能已创建。请先查看邀请记录；如未取得令牌，取消对应的待接受邀请后再创建。',
                                                style: const TextStyle(
                                                    height: 1.6))),
                                    ])),
                        ])))),
        actions: [
          if (confirmingUnknownClose) ...[
            TextButton(onPressed: busy ? null : keepOriginal,
                child: const Text('继续核对原提交')),
            FilledButton(onPressed: busy ? null : confirmUnknownClose,
                child: const Text('关闭并核对记录')),
          ] else ...[
            TextButton(key: const Key('member-editor-close'),
                onPressed: busy ? null : cancel,
                child: Text(pending != null
                    ? widget.retryUncertain ? '暂时关闭' : '查看邀请记录'
                    : '取消')),
            if (pending == null || widget.retryUncertain)
              FilledButton(
                  key: const Key('member-editor-save'),
                  onPressed: busy || roles.isEmpty || (pending == null && (!changed || !optionsReady))
                      ? null : save,
                  child: busy
                      ? const Row(mainAxisSize: MainAxisSize.min, children: [
                          SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 8),
                          Text('提交中…')
                        ])
                      : Text(pending != null ? '重试原提交'
                          : editing ? '保存权限' : '创建邀请')),
          ],
        ],
      ));
}
