import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/dialog_access.dart';
import '../ui/owned_dialog_route.dart';
import 'device_subflow_scope.dart';
import 'editors.dart';

const _invalidPolicyResponse = ApiFailure(502, 'INVALID_RESPONSE');
const _maxSafePolicyInteger = 9007199254740991;

bool _nonemptyText(Object? value) => value is String && value.trim().isNotEmpty;
bool _nullableText(Object? value) => value == null || _nonemptyText(value);
bool _policyInteger(Object? value, {int minimum = 0}) =>
    value is int && value >= minimum && value <= _maxSafePolicyInteger;
bool _policyPattern(String value, String pattern) {
  final match = RegExp(pattern).firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}

Json _policyObject(Object? value) {
  if (value is! Json) throw _invalidPolicyResponse;
  return value;
}

/// Parse before rendering or capturing action inputs; callbacks never borrow a
/// mutable response map that another route may redact or clear.
Json _readPolicyDraft(Object? value, {String? expectedId}) {
  final draft = _policyObject(value);
  if (!_nonemptyText(draft['id']) ||
      (expectedId != null && draft['id'] != expectedId) ||
      !_nonemptyText(draft['name']) ||
      (draft['name'] as String).length > 100 ||
      !const {'POLICY', 'TEMPLATE'}.contains(draft['kind']) ||
      !_policyInteger(draft['revision']) ||
      !_nullableText(draft['sourceVersionId'])) throw _invalidPolicyResponse;
  return Map<String, dynamic>.unmodifiable({
    'id': draft['id'],
    'name': draft['name'],
    'kind': draft['kind'],
    'revision': draft['revision'],
    'rules': _readPolicyRules(draft['rules']),
    'sourceVersionId': draft['sourceVersionId'],
  });
}

List<Json> _readPolicyRules(Object? value) {
  if (value is! List || value.length > 100) throw _invalidPolicyResponse;
  final ids = <String>{};
  final rules = <Json>[];
  for (final item in value) {
    final rule = _policyObject(item);
    final id = rule['id'], kind = rule['kind'], effect = rule['effect'];
    if (id is! String ||
        !_policyPattern(id, r'[a-z][a-z0-9_-]{0,49}') ||
        !ids.add(id) ||
        rule['required'] is! bool ||
        !const {
          'APP_LAUNCH',
          'APP_INSTALL',
          'APP_UNINSTALL',
          'RUNTIME_PERMISSION',
          'SPECIAL_ACCESS',
          'DAILY_QUOTA',
          'TIME_WINDOW',
          'DOMAIN_ACCESS',
          'USAGE_REMINDER'
        }.contains(kind) ||
        !const {
          'ALLOW',
          'DENY',
          'DEFAULT',
          'GRANT',
          'PROTECT',
          'LIMIT',
          'REMIND'
        }.contains(effect)) throw _invalidPolicyResponse;
    const limits = {
      'applicationId': 36,
      'scheduleId': 36,
      'permission': 150,
      'domain': 253
    };
    for (final entry in limits.entries) {
      final field = rule[entry.key];
      if (!_nullableText(field) ||
          (field is String && field.length > entry.value)) {
        throw _invalidPolicyResponse;
      }
    }
    final seconds = rule['seconds'];
    if (seconds != null &&
        (!_policyInteger(seconds, minimum: 1) || (seconds as int) > 86400)) {
      throw _invalidPolicyResponse;
    }
    final application = rule['applicationId'];
    final schedule = rule['scheduleId'];
    final permission = rule['permission'];
    final domain = rule['domain'];
    final used = <String>{};
    Set<String> effects;
    switch (kind) {
      case 'APP_LAUNCH':
      case 'APP_INSTALL':
        if (application == null) throw _invalidPolicyResponse;
        used.add('applicationId');
        effects = {'ALLOW', 'DENY'};
      case 'APP_UNINSTALL':
        if (application == null) throw _invalidPolicyResponse;
        used.add('applicationId');
        effects = {'ALLOW', 'PROTECT'};
      case 'RUNTIME_PERMISSION':
      case 'SPECIAL_ACCESS':
        if (application == null || permission == null) {
          throw _invalidPolicyResponse;
        }
        used.addAll(['applicationId', 'permission']);
        effects = {'GRANT', 'DENY', 'DEFAULT'};
      case 'DAILY_QUOTA':
      case 'USAGE_REMINDER':
        if (seconds == null) throw _invalidPolicyResponse;
        used.addAll(['applicationId', 'seconds']);
        effects = {kind == 'DAILY_QUOTA' ? 'LIMIT' : 'REMIND'};
      case 'TIME_WINDOW':
        if (schedule == null) throw _invalidPolicyResponse;
        used.addAll(['applicationId', 'scheduleId']);
        effects = {'ALLOW'};
      case 'DOMAIN_ACCESS':
        if (domain == null) throw _invalidPolicyResponse;
        used.add('domain');
        effects = {'ALLOW', 'DENY'};
      default:
        throw _invalidPolicyResponse;
    }
    final fields = {
      'applicationId': application,
      'scheduleId': schedule,
      'permission': permission,
      'domain': domain,
      'seconds': seconds
    };
    if (!effects.contains(effect) ||
        fields.entries
            .any((entry) => entry.value != null && !used.contains(entry.key))) {
      throw _invalidPolicyResponse;
    }
    rules.add(Map<String, dynamic>.unmodifiable({
      'id': id,
      'kind': kind,
      'effect': effect,
      'required': rule['required'],
      ...fields
    }));
  }
  return List<Json>.unmodifiable(rules);
}

Json _readPolicyVersion(Object? value, String policyId) {
  final version = _policyObject(value);
  final hash = version['previewHash'];
  if (!_nonemptyText(version['id']) ||
      version['policyId'] != policyId ||
      !_policyInteger(version['draftRevision']) ||
      !_policyInteger(version['sequence'], minimum: 1) ||
      hash is! String ||
      !_policyPattern(hash, r'[0-9a-f]{64}') ||
      !const {'CONFIGURE_ONLY', 'ENFORCE'}.contains(version['mode']) ||
      !_nullableText(version['sourceVersionId']) ||
      !_policyInteger(version['createdAt'])) throw _invalidPolicyResponse;
  final snapshot = _policyObject(version['snapshot']);
  if (snapshot['schemaVersion'] != 1 ||
      snapshot['schemaVersion'] is! int ||
      !_nonemptyText(snapshot['name']) ||
      (snapshot['name'] as String).length > 100) throw _invalidPolicyResponse;
  final sourceRules = _readPolicyRules(snapshot['sourceRules']);
  for (final key in ['applications', 'schedules', 'targets']) {
    final records = snapshot[key];
    if (records is! List || records.any((record) => record is! Json)) {
      throw _invalidPolicyResponse;
    }
  }
  final exemptions = snapshot['protectedPackageExemptions'];
  if (exemptions is! List || exemptions.any((value) => !_nonemptyText(value))) {
    throw _invalidPolicyResponse;
  }
  final group = snapshot['groupSelection'];
  if (group != null &&
      (group is! Json ||
          !_nonemptyText(group['groupId']) ||
          !_policyInteger(group['groupVersion']))) throw _invalidPolicyResponse;
  return _freezePolicyValue({
    ...version,
    'snapshot': {...snapshot, 'sourceRules': sourceRules}
  }) as Json;
}

Object? _freezePolicyValue(Object? value) {
  if (value is Json) {
    return Map<String, dynamic>.unmodifiable({
      for (final entry in value.entries)
        entry.key: _freezePolicyValue(entry.value)
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezePolicyValue));
  }
  if (value == null ||
      value is String ||
      value is bool ||
      (value is num && value.isFinite)) return value;
  throw _invalidPolicyResponse;
}

bool _samePolicyValue(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every((key) =>
            right.containsKey(key) && _samePolicyValue(left[key], right[key]));
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_samePolicyValue(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}

/// A details journey keeps its original authority through all child dialogs.
class _PolicyDetailsScope extends ChangeNotifier {
  final BuildContext context;
  final Session session;
  final String root;
  final bool readOnly;
  late final DeviceSubflowScope _scope;
  late final DialogAccessBinding _parentAccess;
  bool _lost = false, _disposed = false;

  _PolicyDetailsScope(this.context, this.session, this.root,
      {bool Function()? parentCurrent, Listenable? accessChanges,
        this.readOnly = false}) {
    // Capture the original route before the first read. Independent route
    // removal must revoke this entire details journey even without session I/O.
    _parentAccess = DialogAccessBinding(context,
        accessChanges: accessChanges, hasAccess: parentCurrent);
    _scope = DeviceSubflowScope(session,
        permitted: () =>
            _parentAccess.permitted() &&
            context.mounted &&
            session.tenant != null &&
            session.root == root &&
            session.canOpen('policies'));
    _scope.addListener(_observe);
    _parentAccess.changes.addListener(_observe);
  }

  bool get current => !_disposed && !_lost && context.mounted && _scope.current;
  bool get writable => current && !readOnly && session.canWrite;

  void _observe() {
    if (!current) _revoke();
  }

  void _revoke() {
    if (_disposed || _lost) return;
    _lost = true;
    notifyListeners();
  }

  void requireCurrent({bool write = false}) {
    if (!current) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    if (write && !writable) throw const ApiFailure(403, 'SCOPE_DENIED');
  }

  Future<T> request<T>(Future<T> Function(Api) operation,
      {bool write = false}) async {
    try {
      requireCurrent(write: write);
      final result = await operation(_scope.api.scoped(() => current));
      requireCurrent(write: write);
      return result;
    } catch (failure) {
      if (failure is ApiFailure &&
          (failure.code == 'WORKSPACE_CHANGED' ||
              failure.status == 403 ||
              (failure.status == 401 && failure.code != 'REAUTH_REQUIRED'))) {
        _revoke();
      }
      rethrow;
    }
  }

  void reauthenticate() {
    if (current) session.login(stepUp: true);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _scope.removeListener(_observe);
    _parentAccess.changes.removeListener(_observe);
    _scope.dispose();
    _parentAccess.dispose();
    super.dispose();
  }
}

Future<void> openPolicyDetails(BuildContext context, Session session,
    {required String root,
    required Json row,
    required Future<void> Function(BuildContext, Json) preview,
    bool Function()? parentCurrent,
    Listenable? accessChanges,
    bool readOnly = false}) async {
  if (!context.mounted || parentCurrent?.call() == false) {
    throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }
  final scope = _PolicyDetailsScope(context, session, root,
      parentCurrent: parentCurrent, accessChanges: accessChanges,
      readOnly: readOnly);
  try {
    final id = row['id'];
    if (!_nonemptyText(id)) throw const ApiFailure(502, 'INVALID_RESPONSE');
    final value =
        await scope.request((api) => api.send('GET', '$root/policies/$id'));
    scope.requireCurrent();
    if (!context.mounted) return;
    final draft = _readPolicyDraft(value, expectedId: id as String);
    await actionDetails(
        context,
        readOnly ? '查看当前策略 · ${draft['name']}' : draft['name'],
        {
          if (readOnly) '核对说明': '正在查看当前策略与版本记录，不会再次发布原操作。',
          '类型': label(draft['kind']),
          '草稿版本': 'v${draft['revision']}',
          '规则': (draft['rules'] as List)
              .map((rule) =>
                  '${label(rule['kind'])} · ${label(rule['effect'])} · ${ruleSummary(Map<String, dynamic>.from(rule), [], [])}')
              .join('\n'),
          '策略编号': draft['id']
        },
        accessChanges: scope,
        hasAccess: () => scope.current,
        reauth: scope.reauthenticate,
        actions: [
          if (scope.writable)
            DetailAction('编辑草稿', (dialog) async {
              scope.requireCurrent(write: true);
              await policyEditor(dialog, session, draft: draft);
            }),
          if (scope.writable && draft['kind'] == 'TEMPLATE')
            DetailAction(
                '从模板创建策略', (dialog) => _copyPolicy(dialog, scope, draft)),
          if (scope.writable && draft['kind'] == 'POLICY')
            DetailAction('预览与发布', (dialog) async {
              scope.requireCurrent(write: true);
              await preview(dialog, draft);
            }, closeOnSuccess: false),
          DetailAction(
              '版本历史', (dialog) => _policyVersions(dialog, scope, draft))
        ]);
  } finally {
    scope.dispose();
  }
}

Future<void> openPolicyVersions(BuildContext context, Session session,
    {required String root, required Json draft}) async {
  final scope = _PolicyDetailsScope(context, session, root);
  try {
    await _policyVersions(context, scope, _readPolicyDraft(draft));
  } finally {
    scope.dispose();
  }
}

/// Scope loss removes this route, including when another route covers it.
Future<T?> _scopedDialog<T>(BuildContext context, _PolicyDetailsScope scope,
    {required Widget Function(OwnedDialogRoute<T>) builder,
    VoidCallback? redact}) async {
  scope.requireCurrent();
  late final OwnedDialogRoute<T> route;
  void observe() {
    if (!scope.current) {
      redact?.call();
      route.finish();
    }
  }

  route = OwnedDialogRoute<T>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AnimatedBuilder(
          animation: scope,
          builder: (_, __) =>
              scope.current ? builder(route) : const SizedBox.shrink()));
  scope.addListener(observe);
  try {
    scope.requireCurrent();
    return await presentOwnedDialog(context, route);
  } finally {
    scope.removeListener(observe);
  }
}

Future<void> _copyPolicy(
    BuildContext context, _PolicyDetailsScope scope, Json draft) async {
  scope.requireCurrent(write: true);
  final original = _readPolicyDraft(draft);
  final id = original['id'], revision = original['revision'];
  final key = requestId();
  final name = TextEditingController(text: '${original['name']} · 副本');
  try {
    await _scopedDialog<Json>(context, scope,
        redact: name.clear,
        builder: (route) => _CopyPolicyForm(
            name: name,
            scope: scope,
            route: route,
            submit: (values) => scope.request((api) async {
                  final value = await api.send(
                      'POST', '${scope.root}/policies/$id/copies',
                      version: revision, key: key, body: values);
                  final copied = _readPolicyDraft(value);
                  if (copied['id'] == id ||
                      copied['kind'] != 'POLICY' ||
                      copied['revision'] != 0 ||
                      copied['name'] != values['name'] ||
                      copied['sourceVersionId'] != null ||
                      !_samePolicyValue(copied['rules'], original['rules'])) {
                    throw const ApiFailure(502, 'INVALID_RESPONSE');
                  }
                  return copied;
                }, write: true)));
  } finally {
    name.clear();
    name.dispose();
  }
}

class _CopyPolicyForm extends StatefulWidget {
  final TextEditingController name;
  final _PolicyDetailsScope scope;
  final OwnedDialogRoute<Json> route;
  final Future<Json> Function(Json) submit;
  const _CopyPolicyForm(
      {required this.name,
      required this.scope,
      required this.route,
      required this.submit});
  @override
  State<_CopyPolicyForm> createState() => _CopyPolicyFormState();
}

class _CopyPolicyFormState extends State<_CopyPolicyForm> {
  final form = GlobalKey<FormState>();
  bool busy = false;
  Json? pending;
  Object? error;
  bool get current =>
      mounted &&
      widget.scope.writable &&
      widget.route.available &&
      widget.route.isCurrent;

  Future<void> save() async {
    if (!current || busy || form.currentState?.validate() != true) return;
    setState(() {
      busy = true;
      error = null;
    });
    final submitted = pending ??
        Map<String, dynamic>.unmodifiable({'name': widget.name.text.trim()});
    pending = submitted;
    try {
      final result = await widget.submit(submitted);
      if (mounted && widget.scope.writable) widget.route.finish(result);
    } catch (failure) {
      if (failure is ApiFailure &&
          failure.status != 0 &&
          failure.status < 500) {
        pending = null;
      }
      if (mounted && widget.scope.current) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    pending = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: AlertDialog(
          title: const Text('复制为策略'),
          content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                  child: Form(
                      key: form,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        if (pending != null && !busy)
                          const Notice('上次提交结果尚未确认。重试将发送相同名称；离开后请先刷新策略列表核对结果。',
                              warning: true),
                        TextFormField(
                            controller: widget.name,
                            enabled: !busy && pending == null,
                            autofocus: true,
                            maxLength: 100,
                            decoration:
                                const InputDecoration(labelText: '新策略名称'),
                            validator: (value) => (value ?? '').trim().isEmpty
                                ? '请输入新策略名称'
                                : null),
                        if (error != null)
                          FailureView(error!, reauth: () {
                            if (current && !busy) widget.scope.reauthenticate();
                          })
                      ])))),
          actions: [
            TextButton(
                onPressed: busy
                    ? null
                    : () {
                        if (current) widget.route.finish();
                      },
                child: const Text('取消')),
            FilledButton(
                onPressed: busy ? null : save,
                child: Text(busy
                    ? '保存中…'
                    : pending == null
                        ? '保存'
                        : '重试原提交'))
          ]));
}

Future<void> _policyVersions(
    BuildContext context, _PolicyDetailsScope scope, Json draft) async {
  final rows = await scope.request(
      (api) => api.all('${scope.root}/policies/${draft['id']}/versions'));
  scope.requireCurrent();
  if (!context.mounted) return;
  try {
    final versions = rows
        .map((value) => _readPolicyVersion(value, draft['id'] as String))
        .toList(growable: false);
    await _scopedDialog<void>(context, scope,
        redact: rows.clear,
        builder: (route) => AlertDialog(
                title: const Text('版本历史'),
                content: SizedBox(
                    width: 620,
                    child: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      if (versions.isEmpty)
                        const EmptyView('还没有发布版本', '预览并发布后，可在这里查看历史。'),
                      ...versions.map((version) => ListTile(
                          title: Text('版本 ${version['sequence']}'),
                          subtitle: Text(dateLabel(version['createdAt'])),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            if (!scope.current ||
                                !route.available ||
                                !route.isCurrent) return;
                            await _versionDetails(
                                context, scope, draft, version);
                          }))
                    ]))),
                actions: [
                  TextButton(
                      onPressed: () {
                        if (route.available && route.isCurrent) route.finish();
                      },
                      child: const Text('关闭'))
                ]));
  } finally {
    rows.clear();
  }
}

Future<void> _versionDetails(BuildContext context, _PolicyDetailsScope scope,
    Json draft, Json version) async {
  scope.requireCurrent();
  final key = requestId();
  await actionDetails(
      context,
      '历史版本',
      {
        '版本': version['sequence'],
        '发布方式': label(version['mode']),
        '发布时间': dateLabel(version['createdAt']),
        '规则数': (version['snapshot']['sourceRules'] as List).length,
        '目标设备数': (version['snapshot']['targets'] as List).length,
        '版本编号': version['id']
      },
      accessChanges: scope,
      hasAccess: () => scope.current,
      reauth: scope.reauthenticate,
      actions: scope.writable
          ? [
              DetailAction('回滚为草稿', (dialog) async {
                scope.requireCurrent(write: true);
                final confirmed = await _scopedDialog<bool>(dialog, scope,
                    builder: (route) => AlertDialog(
                            title: const Text('回滚为草稿'),
                            content: const SizedBox(
                                width: 460,
                                child: Text(
                                    '将历史规则恢复到当前策略草稿。不会改变已经发布的版本，仍需重新预览并发布。',
                                    style: TextStyle(height: 1.8))),
                            actions: [
                              TextButton(
                                  onPressed: () {
                                    if (route.available && route.isCurrent) {
                                      route.finish(false);
                                    }
                                  },
                                  child: const Text('取消')),
                              FilledButton(
                                  onPressed: () {
                                    if (scope.writable &&
                                        route.available &&
                                        route.isCurrent) route.finish(true);
                                  },
                                  child: const Text('确认'))
                            ]));
                if (confirmed != true) return;
                await scope.request(
                    (api) => api.send('POST',
                        '${scope.root}/policies/${draft['id']}/versions/${version['id']}/rollback-drafts',
                        version: draft['revision'],
                        key: key,
                        body: {'name': draft['name']}),
                    write: true);
              })
            ]
          : []);
}
