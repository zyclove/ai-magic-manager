import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/policy_domain_check.dart';
import '../core/policy_draft_change.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/dialog_access.dart';
import '../ui/owned_dialog_route.dart';
import '../ui/policy_domain_check_view.dart';
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
  final sourceRules = readPolicyDraftRules(snapshot['sourceRules']);
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
      {bool Function()? parentCurrent,
      Listenable? accessChanges,
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
      {bool write = false, bool Function()? hasAccess}) async {
    void requireAvailable() {
      requireCurrent(write: write);
      if (hasAccess?.call() == false) {
        throw const ApiFailure(409, 'WORKSPACE_CHANGED');
      }
    }

    try {
      requireAvailable();
      final result = await operation(_scope.api.scoped(
          () => current && (!write || writable) && hasAccess?.call() != false));
      requireAvailable();
      return result;
    } catch (failure) {
      if (failure is ApiFailure &&
          ((failure.code == 'WORKSPACE_CHANGED' &&
                  hasAccess?.call() != false) ||
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

/// True means the list must reread its rows, not that a write succeeded.
Future<bool> openPolicyDetails(BuildContext context, Session session,
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
      parentCurrent: parentCurrent,
      accessChanges: accessChanges,
      readOnly: readOnly);
  var needsRefresh = false;
  try {
    final id = row['id'];
    if (!_nonemptyText(id)) throw const ApiFailure(502, 'INVALID_RESPONSE');
    final value =
        await scope.request((api) => api.send('GET', '$root/policies/$id'));
    scope.requireCurrent();
    if (!context.mounted) return false;
    final draft = readPolicyDraftSnapshot(value, expectedId: id as String);
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
        extraContent: (draft['rules'] as List)
                .any((rule) => rule['kind'] == 'DOMAIN_ACCESS')
            ? ExpansionTile(
                title: const Text('检查域名规则'),
                subtitle: const Text('核对精确匹配，不执行设备策略'),
                children: [
                    Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: PolicyDomainCheckView(
                            draftRevision: draft['revision'],
                            accessChanges: scope,
                            hasAccess: () => scope.current,
                            evaluate: (domain) => scope.request((api) =>
                                evaluatePolicyDomain(api,
                                    root: scope.root,
                                    draft: draft,
                                    domain: domain))))
                  ])
            : null,
        actions: [
          if (scope.writable)
            DetailAction('编辑草稿', (dialog) async {
              scope.requireCurrent(write: true);
              final owner = ModalRoute.of(dialog);
              final changed = await policyEditor(dialog, session,
                  draft: draft,
                  accessChanges: scope,
                  hasAccess: () =>
                      scope.writable && _policyRouteAvailable(owner));
              if (changed) {
                needsRefresh = true;
                _finishPolicyRoute(owner);
              }
            }, closeOnSuccess: false),
          if (scope.writable && draft['kind'] == 'TEMPLATE')
            DetailAction('从模板创建策略', (dialog) async {
              final owner = ModalRoute.of(dialog);
              if (await _copyPolicy(dialog, scope, draft)) {
                needsRefresh = true;
                _finishPolicyRoute(owner);
              }
            }, closeOnSuccess: false),
          if (scope.writable && draft['kind'] == 'POLICY')
            DetailAction('预览与发布', (dialog) async {
              scope.requireCurrent(write: true);
              await preview(dialog, draft);
            }, closeOnSuccess: false),
          DetailAction('版本历史', (dialog) async {
            final owner = ModalRoute.of(dialog);
            if (await _policyVersions(dialog, scope, draft)) {
              needsRefresh = true;
              _finishPolicyRoute(owner);
            }
          }, closeOnSuccess: false)
        ]);
    return needsRefresh && scope.current;
  } finally {
    scope.dispose();
  }
}

Future<void> openPolicyVersions(BuildContext context, Session session,
    {required String root, required Json draft}) async {
  final scope = _PolicyDetailsScope(context, session, root);
  try {
    await _policyVersions(context, scope, readPolicyDraftSnapshot(draft));
  } finally {
    scope.dispose();
  }
}

bool _policyRouteAvailable(ModalRoute<dynamic>? route) =>
    route != null &&
    route.isActive &&
    (route is! OwnedDialogRoute<dynamic> || route.available);

void _finishPolicyRoute(ModalRoute<dynamic>? route) {
  if (route is OwnedDialogRoute<dynamic> && route.available) route.finish();
}

bool _policyWriteUncertain(Object failure) =>
    failure is! ApiFailure ||
    failure.status == 0 ||
    failure.status >= 500 ||
    const {
      'PENDING_OPERATION_UNCHANGED',
      'WORKSPACE_CHANGED',
      'IDEMPOTENCY_KEY_EXPIRED',
      'IDEMPOTENCY_RESPONSE_ERASED'
    }.contains(failure.code);

/// Coverage gates UI actions; removal revokes late authenticated requests.
Future<T?> _scopedDialog<T>(BuildContext context, _PolicyDetailsScope scope,
    {required Widget Function(
            BuildContext, OwnedDialogRoute<T>, DialogAccessBinding)
        builder,
    Listenable? accessChanges,
    bool Function()? hasAccess,
    VoidCallback? redact}) async {
  scope.requireCurrent();
  final changes =
      accessChanges == null ? scope : Listenable.merge([scope, accessChanges]);
  final access = DialogAccessBinding(context,
      accessChanges: changes,
      hasAccess: () => scope.current && hasAccess?.call() != false);
  late final OwnedDialogRoute<T> route;
  void observe() {
    if (!access.permitted()) {
      redact?.call();
      route.finish();
    }
  }

  try {
    if (!access.permitted()) return null;
    route = OwnedDialogRoute<T>(
        context: context,
        barrierDismissible: false,
        builder: (dialog) => AnimatedBuilder(
            animation: access.changes,
            builder: (_, __) => access.permitted()
                ? builder(dialog, route, access)
                : const SizedBox.shrink()));
    access.changes.addListener(observe);
    return await presentOwnedDialog(context, route);
  } finally {
    access.changes.removeListener(observe);
    access.dispose();
  }
}

Future<bool> _copyPolicy(
    BuildContext context, _PolicyDetailsScope scope, Json draft) async {
  scope.requireCurrent(write: true);
  final original = readPolicyDraftSnapshot(draft);
  final id = original['id'], revision = original['revision'];
  final key = requestId();
  var mayHaveChanged = false, staleDraft = false;
  await _scopedDialog<Json>(context, scope,
      builder: (dialog, route, access) => EditDialog(
          key: const Key('policy-copy-form'),
          title: '复制为策略',
          fields: const [FieldSpec('name', '新策略名称')],
          initial: {'name': '${original['name']} · 副本'},
          submit: '保存',
          accessChanges: access.changes,
          hasAccess: () =>
              scope.writable && access.permitted() && route.available,
          reauth: () {
            if (access.permitted() && route.available && route.isCurrent) {
              scope.reauthenticate();
            }
          },
          onSubmit: (values) async {
            final body =
                Map<String, dynamic>.unmodifiable({'name': values['name']});
            try {
              final copied = await scope.request((api) async {
                final value = await api.send(
                    'POST', '${scope.root}/policies/$id/copies',
                    version: revision, key: key, body: body);
                final copied = readPolicyDraftSnapshot(value);
                if (copied['id'] == id ||
                    copied['kind'] != 'POLICY' ||
                    copied['revision'] != 0 ||
                    copied['name'] != body['name'] ||
                    copied['sourceVersionId'] != null ||
                    !_samePolicyValue(copied['rules'], original['rules'])) {
                  throw _invalidPolicyResponse;
                }
                return copied;
              },
                  write: true,
                  hasAccess: () => access.permitted() && route.available);
              mayHaveChanged = true;
              return copied;
            } catch (failure) {
              mayHaveChanged = mayHaveChanged || _policyWriteUncertain(failure);
              staleDraft =
                  staleDraft || failure is ApiFailure && failure.status == 412;
              rethrow;
            }
          }));
  return mayHaveChanged || staleDraft;
}

Future<bool> _policyVersions(
    BuildContext context, _PolicyDetailsScope scope, Json draft) async {
  final access = DialogAccessBinding(context,
      accessChanges: scope, hasAccess: () => scope.current);
  List<Json>? rows;
  try {
    final loaded = await scope.request(
        (api) => api.all('${scope.root}/policies/${draft['id']}/versions'),
        hasAccess: access.permitted);
    rows = loaded;
    if (!context.mounted || !access.permitted()) return false;
    final versions = loaded
        .map((value) => _readPolicyVersion(value, draft['id'] as String))
        .toList(growable: false);
    final changed = await _scopedDialog<bool>(context, scope,
        accessChanges: access.changes,
        hasAccess: access.permitted,
        redact: loaded.clear,
        builder: (dialog, route, dialogAccess) => AlertDialog(
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
                                !dialogAccess.permitted() ||
                                !route.available ||
                                !route.isCurrent) return;
                            final changed = await _versionDetails(
                                dialog, scope, draft, version,
                                accessChanges: dialogAccess.changes,
                                hasAccess: () =>
                                    dialogAccess.permitted() &&
                                    route.available);
                            if (changed && route.available) route.finish(true);
                          }))
                    ]))),
                actions: [
                  TextButton(
                      onPressed: () {
                        if (route.available && route.isCurrent) {
                          route.finish(false);
                        }
                      },
                      child: const Text('关闭'))
                ]));
    return changed == true;
  } finally {
    rows?.clear();
    access.dispose();
  }
}

Future<bool> _versionDetails(
    BuildContext context, _PolicyDetailsScope scope, Json draft, Json version,
    {Listenable? accessChanges, bool Function()? hasAccess}) async {
  scope.requireCurrent();
  final changes =
      accessChanges == null ? scope : Listenable.merge([scope, accessChanges]);
  final access = DialogAccessBinding(context,
      accessChanges: changes,
      hasAccess: () => scope.current && hasAccess?.call() != false);
  var needsRefresh = false;
  try {
    if (!access.permitted()) return false;
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
        accessChanges: access.changes,
        hasAccess: access.permitted,
        reauth: scope.reauthenticate,
        actions: scope.writable
            ? [
                DetailAction('回滚为草稿', (dialog) async {
                  final owner = ModalRoute.of(dialog);
                  if (await _rollbackPolicy(dialog, scope, draft, version,
                      accessChanges: access.changes,
                      hasAccess: access.permitted)) {
                    needsRefresh = true;
                    _finishPolicyRoute(owner);
                  }
                }, closeOnSuccess: false)
              ]
            : []);
    return needsRefresh;
  } finally {
    access.dispose();
  }
}

Future<bool> _rollbackPolicy(
    BuildContext context, _PolicyDetailsScope scope, Json draft, Json version,
    {required Listenable accessChanges,
    required bool Function() hasAccess}) async {
  scope.requireCurrent(write: true);
  final key = requestId();
  final body = Map<String, dynamic>.unmodifiable({'name': draft['name']});
  var mayHaveChanged = false, staleDraft = false;
  await _scopedDialog<Json>(context, scope,
      accessChanges: accessChanges,
      hasAccess: hasAccess,
      builder: (dialog, route, access) => EditDialog(
          key: const Key('policy-rollback-form'),
          title: '回滚为草稿',
          description: '策略名称：${draft['name']}。\n'
              '将历史规则恢复到当前策略草稿。不会改变已经发布的版本，仍需重新预览并发布。',
          fields: const [],
          initial: const {},
          submit: '确认',
          accessChanges: access.changes,
          hasAccess: () =>
              scope.writable && access.permitted() && route.available,
          reauth: () {
            if (access.permitted() && route.available && route.isCurrent) {
              scope.reauthenticate();
            }
          },
          onSubmit: (_) async {
            try {
              final restored = await scope.request((api) async {
                final value = await api.send('POST',
                    '${scope.root}/policies/${draft['id']}/versions/${version['id']}/rollback-drafts',
                    version: draft['revision'], key: key, body: body);
                final restored =
                    readPolicyDraftSnapshot(value, expectedId: draft['id']);
                if (restored['kind'] != draft['kind'] ||
                    restored['revision'] != draft['revision'] + 1 ||
                    restored['sourceVersionId'] != version['id'] ||
                    restored['name'] != body['name'] ||
                    !_samePolicyValue(restored['rules'],
                        version['snapshot']['sourceRules'])) {
                  throw _invalidPolicyResponse;
                }
                return restored;
              },
                  write: true,
                  hasAccess: () => access.permitted() && route.available);
              mayHaveChanged = true;
              return restored;
            } catch (failure) {
              mayHaveChanged = mayHaveChanged || _policyWriteUncertain(failure);
              staleDraft =
                  staleDraft || failure is ApiFailure && failure.status == 412;
              rethrow;
            }
          }));
  return mayHaveChanged || staleDraft;
}
