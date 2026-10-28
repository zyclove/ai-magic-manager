import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/member_access.dart';
import '../core/member_scope_directories.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/dialog_access.dart';
import '../ui/leased_dialog.dart';
import '../ui/member_class_scope.dart';
import '../ui/member_editor.dart';
import '../ui/owned_dialog_route.dart';
import '../ui/resource_page.dart';
import 'device_subflow_scope.dart';

class MembersPage extends StatefulWidget {
  final Session session;
  final Future<bool> Function({Listenable? accessChanges,
      bool Function()? hasAccess}) invite;
  const MembersPage({super.key, required this.session, required this.invite});
  @override
  State<MembersPage> createState() => _MembersPageState();
}

class _MembersPageState extends State<MembersPage> {
  bool invitations = false;
  bool _busy = false;
  int _viewGeneration = 0;
  ModalRoute<dynamic>? _owner;
  bool _active = true, _rebuildPending = false, _pageClosed = false;
  bool _retirementQueued = false, _pageReadDenied = false;
  final _ownerLost = ValueNotifier<bool>(false);
  late final DeviceSubflowScope _pageScope;
  Session get s => widget.session;
  bool get pageCurrent =>
      mounted && _active && !_pageReadDenied && _pageScope.current;
  bool get pageInteractive => pageCurrent &&
      (_owner == null || (_owner!.isActive && _owner!.isCurrent));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _owner ??= ModalRoute.of(context);
  }

  @override
  void initState() {
    super.initState();
    final session = s;
    final root = session.tenant == null ? null : session.root;
    _pageScope = DeviceSubflowScope(session,
        permitted: () => mounted && _active && !_pageClosed &&
            !_pageReadDenied && identical(s, session) &&
            session.tenant != null && session.root == root &&
            session.canManage && session.canOpen('members'));
    _pageScope.addListener(_accessChanged);
  }

  void _accessChanged() {
    if (pageCurrent || !mounted || !_active || _rebuildPending) return;
    _rebuildPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildPending = false;
      if (mounted && _active) {
        _ownerLost.value = true;
        setState(() {});
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool rejectPageRead(Object failure, bool Function() available) {
    if (failure is! ApiFailure || failure.code == 'REAUTH_REQUIRED' ||
        !available()) return false;
    if (failure.status != 401 && failure.status != 403 &&
        failure.code != 'WORKSPACE_CHANGED') return false;
    _pageReadDenied = true;
    _accessChanged();
    return true;
  }

  void _retirePage() {
    _active = false;
    _pageClosed = true;
    if (_retirementQueued) return;
    _retirementQueued = true;
    // Old callbacks stop immediately; route retirement waits for the tree lock.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ownerLost.value = true;
      _ownerLost.dispose();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void deactivate() {
    _retirePage();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void dispose() {
    _retirePage();
    _pageScope.removeListener(_accessChanged);
    _pageScope.dispose();
    super.dispose();
  }

  bool current(DeviceSubflowScope scope) => pageCurrent && scope.current;

  Listenable flowChanges(DeviceSubflowScope scope,
      {ResourceActionLease? listLease}) =>
      Listenable.merge([scope, _ownerLost, if (listLease != null) listLease]);

  DeviceSubflowScope capture(String root,
      {ResourceActionLease? listLease, bool Function()? permitted}) =>
      DeviceSubflowScope(s, permitted: () => pageCurrent &&
          s.tenant != null && s.root == root && listLease?.current != false &&
          (permitted?.call() ?? true));

  Api dialogApi(BuildContext dialog, DeviceSubflowScope scope) {
    final route = ModalRoute.of(dialog);
    return scope.api.scoped(() => current(scope) && dialog.mounted &&
        route?.isActive == true &&
        (route is! OwnedDialogRoute<dynamic> || route.available));
  }

  void reauth() {
    if (pageCurrent) s.login(stepUp: true);
  }

  void selectView(Set<bool> selection, int view) {
    if (!pageInteractive || _busy || view != _viewGeneration ||
        selection.length != 1 || selection.single == invitations) return;
    setState(() {
      invitations = selection.single;
      _viewGeneration++;
    });
  }

  Future<bool> performListAction(ResourceActionLease lease, int view,
      Future<bool> Function() callback) async {
    if (!pageInteractive || _busy || !lease.current ||
        view != _viewGeneration) return false;
    setState(() => _busy = true);
    try {
      return await callback();
    } finally {
      if (pageCurrent) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!pageCurrent) {
      return const Notice('工作空间或权限已变化，请重新打开成员管理。', warning: true);
    }
    final root = s.root;
    final viewingInvitations = invitations;
    final view = _viewGeneration;
    return ResourcePage(
      key: ValueKey('$root-$invitations-${s.role}'),
      title: '成员与邀请',
      subtitle: '核对成员身份，按职责分配访问权限和档案范围。',
      path: '$root/${invitations ? 'invitations' : 'members'}',
      api: _pageScope.api,
      reauth: reauth,
      isCurrent: () => pageCurrent,
      onReadDenied: (failure) => rejectPageRead(failure,
          () => pageCurrent && view == _viewGeneration),
      canInteract: () => pageInteractive,
      onCreateChanged: (lease) => performListAction(lease, view, () async {
        final scope = capture(root, listLease: lease);
        try {
          if (!current(scope)) return false;
          final reviewInvitations = await widget.invite(
              accessChanges: flowChanges(scope, listLease: lease),
              hasAccess: () => current(scope));
          if (!current(scope)) return false;
          if (reviewInvitations && !viewingInvitations) {
            setState(() {
              invitations = true;
              _viewGeneration++;
            });
            return false;
          }
          return reviewInvitations;
        } finally {
          scope.dispose();
        }
      }),
      createLabel: '邀请成员',
      toolbar: [
        SegmentedButton<bool>(segments: const [
          ButtonSegment(value: false, label: Text('成员')),
          ButtonSegment(value: true, label: Text('邀请记录'))
        ], selected: {
          invitations
        }, onSelectionChanged: pageInteractive && !_busy
            ? (selection) => selectView(selection, view)
            : null)
      ],
      columns: invitations
          ? [
              ColumnSpec('邀请编号', (r) => Text(shortId(r['id']))),
              ColumnSpec('角色', (r) => Text(label(r['role']))),
              ColumnSpec('状态', (r) => StatusTag(r['state'])),
              ColumnSpec('有效期至', (r) => Text(dateLabel(r['expiresAt']))),
            ]
          : [
              ColumnSpec(
                  '成员',
                  (r) => Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                '${memberName(r)}${r['actorId'] == s.profile?['subject'] ? '（我）' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 3),
                            Text(
                                r['verifiedEmail'] as String? ??
                                    shortId(r['actorId']),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12, color: muted)),
                          ])),
              ColumnSpec('角色', (r) => StatusTag(r['role'])),
              ColumnSpec(
                  '访问范围',
                  (r) => Text(memberScope(r),
                      maxLines: 2, overflow: TextOverflow.ellipsis)),
            ],
      emptyTitle: invitations ? '暂无邀请记录' : '暂无成员',
      emptyDescription:
          invitations ? '创建邀请后可在这里查看状态、取消未使用的邀请。' : '成员加入后将在这里显示。',
      onOpenChanged: (row, lease) => performListAction(lease, view, () async {
        if (!pageCurrent || !lease.current || viewingInvitations != invitations) {
          return false;
        }
        return viewingInvitations
            ? await openInvitation(root, row, listLease: lease)
            : await openMember(root, row, listLease: lease);
      }),
    );
  }

  Future<bool> openInvitation(String root, Json row,
      {ResourceActionLease? listLease}) async {
    final scope = capture(root, listLease: listLease);
    final changes = flowChanges(scope, listLease: listLease);
    var needsReview = false;
    try {
      if (!current(scope)) return false;
      await scopedDetailsDialog(
          context,
          '邀请详情',
          {
            '邀请编号': row['id'],
            '角色': label(row['role']),
            '关联档案标识': row['subjectId'],
            if ((row['classIds'] as List? ?? []).isNotEmpty)
              '班级标识': (row['classIds'] as List).join('\n'),
            '状态': label(row['state']),
            '有效期至': dateLabel(row['expiresAt']),
            '令牌说明': '令牌仅在创建成功时展示。未取得令牌时，请取消此邀请，再重新创建。',
          },
          reauth: reauth,
          accessChanges: changes,
          hasAccess: () => current(scope),
          actions: [
            if (row['state'] == 'PENDING' &&
                (row['role'] != 'ORG_ADMIN' || s.role == 'OWNER'))
              DetailAction('取消邀请', (dialog) async {
                final complete = captureDialogCompletion(dialog);
                final api = dialogApi(dialog, scope);
                if (!await confirmLeasedAction(dialog, '取消邀请',
                    '邀请编号：${row['id']}\n角色：${label(row['role'])}\n'
                    '有效期至：${dateLabel(row['expiresAt'])}\n\n取消后此邀请令牌将不再有效。',
                    accessChanges: changes, hasAccess: () => current(scope),
                    confirm: '确认取消邀请')) return;
                if (!current(scope)) return;
                needsReview = true;
                await api.send('DELETE', '$root/invitations/${row['id']}');
                complete();
              }, destructive: true, closeOnSuccess: false),
          ]);
      return current(scope) && needsReview;
    } finally {
      scope.dispose();
    }
  }

  Json memberPresentation(Json row, MemberAccessSnapshot access) {
    final sameSubject = access.subjectId != null &&
        access.subjectId == row['subjectId'];
    final updatedAt = row['profileUpdatedAt'];
    return Map<String, dynamic>.unmodifiable({
      ...access.toJson(),
      'displayName': row['displayName'] is String ? row['displayName'] : null,
      'verifiedEmail': access.role != 'CHILD' && row['verifiedEmail'] is String
          ? row['verifiedEmail'] : null,
      'profileUpdatedAt': updatedAt is String || updatedAt is num ? updatedAt : null,
      'subjectName': sameSubject && row['subjectName'] is String
          ? row['subjectName'] : null,
      'subjectArchived': sameSubject && row['subjectArchived'] == true,
    });
  }

  Future<bool> openMember(String root, Json row,
      {ResourceActionLease? listLease}) async {
    final targetLost = ValueNotifier<bool>(false);
    var targetDenied = false, flowLive = true, needsReview = false;
    final scope = capture(root, listLease: listLease,
        permitted: () => !targetDenied);
    bool sourceCurrent() => pageCurrent && s.tenant != null &&
        s.root == root && listLease?.current != false;
    bool rejectTargetRead(Object failure) {
      if (!current(scope) || failure is! ApiFailure ||
          failure.code == 'REAUTH_REQUIRED') return false;
      if (failure.status == 401 || failure.code == 'WORKSPACE_CHANGED') {
        return rejectPageRead(failure, sourceCurrent);
      }
      if (failure.status != 403) return false;
      // A concealed or revoked target also returns 403. Recheck the list
      // before concluding that access to every member has been lost.
      needsReview = true;
      targetDenied = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (flowLive) targetLost.value = true;
      });
      WidgetsBinding.instance.ensureVisualUpdate();
      toast(context, '当前无法查看该成员，将核对成员列表。');
      return true;
    }
    try {
      if (!current(scope)) return false;
      final kind = s.tenant!['kind'] as String, operatorRole = s.role;
      final target = MemberAccessTarget.fromRow(row);
      final path = '$root/members/${target.memberKey}/access';
      Future<MemberAccessSnapshot?> readAccess(
          {MemberAccessSnapshot? previous}) async {
        try {
          final raw = await scope.api.send('GET', path);
          if (!current(scope)) return null;
          return MemberAccessSnapshot.read(raw,
              kind: kind, target: target, previous: previous);
        } catch (failure) {
          if (rejectTargetRead(failure)) return null;
          rethrow;
        }
      }
      final access = await readAccess();
      if (access == null || !current(scope)) {
        return sourceCurrent() && needsReview;
      }
      needsReview = access.version != row['version'];
      final classIds = access.classIds;
      final member = memberPresentation(row, access);
      final allowed = memberRoles(kind, operatorRole, currentRole: access.role);
      var edit = false;
      final removalKey = requestId();
      final changes = Listenable.merge([
        flowChanges(scope, listLease: listLease), targetLost,
      ]);
      Api? classScopeApi;
      await scopedDetailsDialog(
          context,
          '成员详情',
          {
            '姓名': memberName(member),
            '完整账号标识': member['actorId'],
            if (member['role'] != 'CHILD')
              '已验证邮箱': member['verifiedEmail'] ?? '暂无已验证邮箱资料',
            '角色': label(member['role']),
            '访问范围': memberScope(member),
            if (member['subjectId'] != null) '档案标识': member['subjectId'],
            '权限版本': member['version'],
            '资料最近同步': dateLabel(member['profileUpdatedAt']),
            if (member['role'] == 'OWNER') '所有者权限': '如需转交，请使用“所有者交接”，由对方确认接收。',
          },
          reauth: reauth,
          accessChanges: changes,
          hasAccess: () => current(scope),
          closeOnAccessLost: true,
          extraContent: classIds.isEmpty ? null : Builder(builder: (dialog) {
            if (!dialog.mounted || !current(scope)) return const SizedBox.shrink();
            final route = ModalRoute.of(dialog);
            bool available() => dialog.mounted && current(scope) &&
                route?.isActive == true &&
                (route is! OwnedDialogRoute<dynamic> || route.available);
            if (!available()) return const SizedBox.shrink();
            return MemberClassScope(
                api: classScopeApi ??= dialogApi(dialog, scope),
                path: '$root/classes?includeArchived=true',
                classIds: classIds,
                accessChanges: changes,
                isCurrent: available);
          }),
          actions: [
            DetailAction('权限变更记录', (dialog) =>
                history(dialog, root, member, scope, listLease: listLease,
                    targetChanges: targetLost, onReadDenied: rejectTargetRead),
                closeOnSuccess: false),
            if (allowed.isNotEmpty) ...[
              DetailAction('调整权限', (dialog) async {
                final complete = captureDialogCompletion(dialog);
                edit = true;
                complete();
              }, closeOnSuccess: false),
              DetailAction('撤销访问', (dialog) async {
                final complete = captureDialogCompletion(dialog);
                final api = dialogApi(dialog, scope);
                if (!await confirmLeasedAction(dialog, '撤销成员访问',
                    '成员：${memberName(member)}\n账号：${member['actorId']}\n'
                    '成员编号：${member['memberKey']}\n权限版本：${access.version}\n\n'
                    '将撤销该成员的工作空间访问。相关未使用邀请、待确认配对、临时授权和预览会失效。',
                    accessChanges: changes, hasAccess: () => current(scope),
                    confirm: '确认撤销访问')) return;
                if (!current(scope)) return;
                needsReview = true;
                await api.send('DELETE', path,
                    version: access.version, key: removalKey);
                complete();
                if (mounted && current(scope)) toast(context, '成员访问已撤销。');
              }, destructive: true, closeOnSuccess: false),
            ],
          ]);
      if (edit && current(scope)) {
        // Fetch again after leaving the detail dialog: never silently replace the version on submit.
        final latest = await readAccess(previous: access);
        if (latest == null || !current(scope)) {
          return sourceCurrent() && needsReview;
        }
        needsReview = needsReview || latest.version != access.version;
        if (memberRoles(kind, operatorRole, currentRole: latest.role).isEmpty) {
          toast(context, '该成员当前不支持权限调整，请核对最新成员资料。');
          return true;
        }
        final key = requestId();
        final result = await memberEditorDialog(context,
                  kind: kind,
                  operatorRole: operatorRole,
                  accessChanges: changes,
                  hasAccess: () => current(scope),
                  member: memberPresentation(row, latest),
                  directories: MemberScopeDirectories(
                      api: scope.api, root: root,
                      current: () => current(scope)),
                  reauth: reauth,
                  onSubmit: (body, permitted) async {
                    needsReview = true;
                    final updated = await scope.api.send('PATCH', path,
                        body: body, version: latest.version,
                        key: key, isCurrent: permitted);
                    return latest.verifyUpdate(updated, body: body).toJson();
                  },
                );
        if (result != null) needsReview = true;
        if (mounted && result != null && result['refresh'] != true &&
            current(scope)) {
          toast(context, '成员权限已更新。');
        }
      }
      return sourceCurrent() && needsReview;
    } finally {
      flowLive = false;
      scope.dispose();
      targetLost.dispose();
    }
  }

  Future<void> history(BuildContext parent, String root, Json member,
      DeviceSubflowScope owner, {ResourceActionLease? listLease,
      required Listenable targetChanges,
      required ValueChanged<Object> onReadDenied}) async {
    final route = ModalRoute.of(parent);
    final parentChanged = ValueNotifier<bool>(false);
    var live = true, parentClosed = false;
    route?.popped.then<void>((_) {
      if (!live) return;
      parentClosed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (live) parentChanged.value = true;
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
    final scope = DeviceSubflowScope(s,
        permitted: () => !parentClosed && current(owner) && parent.mounted &&
            route?.isActive == true);
    final changes = Listenable.merge([
      scope, parentChanged, _ownerLost, targetChanges,
      if (listLease != null) listLease
    ]);
    try {
      if (!current(scope)) return;
      Api? historyApi;
      await scopedDetailsDialog(parent, '权限变更记录', {
        '成员': memberName(member),
      }, accessChanges: changes, hasAccess: () => current(scope),
        closeOnAccessLost: true, reauth: reauth,
        extraContent: Builder(builder: (dialog) {
          final historyRoute = ModalRoute.of(dialog);
          bool available() => current(scope) && dialog.mounted &&
              historyRoute?.isActive == true &&
              (historyRoute is! OwnedDialogRoute<dynamic> ||
                  historyRoute.available);
          final api = historyApi ??= dialogApi(dialog, scope);
          return SizedBox(width: 920, child: ResourcePage(
                  api: api,
                  isCurrent: available,
                  onReadDenied: (failure) {
                    if (available()) onReadDenied(failure);
                  },
                  path: '$root/members/${member['memberKey']}/access-history',
                  title: '权限变更记录',
                  subtitle: '${memberName(member)} · 按权限版本从新到旧显示角色调整与撤销记录。',
                  emptyTitle: '暂无权限调整记录',
                  refreshAfterOpen: false,
                  emptyDescription: '角色或档案范围调整、撤销访问后会记录在这里。所有者交接请查看交接记录。',
                  columns: [
                    ColumnSpec('版本', (r) => Text('v${r['memberVersion']}')),
                    ColumnSpec(
                        '变更',
                        (r) => Text(
                            '${label(r['previousRole'])} → ${r['role'] == null ? '已撤销' : label(r['role'])}')),
                    ColumnSpec('时间', (r) => Text(dateLabel(r['occurredAt']))),
                  ],
                  onOpen: (r) => scopedDetailsDialog(dialog, '权限变更详情', {
                    '权限版本': r['memberVersion'],
                    '原角色': label(r['previousRole']),
                    '原档案': r['previousSubjectId'] ??
                        ((r['previousClassIds'] as List? ?? []).isNotEmpty
                            ? '班级范围（见下方）'
                            : '工作空间范围'),
                    if ((r['previousClassIds'] as List? ?? []).isNotEmpty)
                      '原班级': (r['previousClassIds'] as List).join('\n'),
                    '调整后角色': r['role'] == null ? '已撤销' : label(r['role']),
                    '调整后档案': r['role'] == null
                        ? '无访问权限'
                        : r['subjectId'] ??
                            ((r['classIds'] as List? ?? []).isNotEmpty
                                ? '班级范围（见下方）'
                                : '工作空间范围'),
                    if ((r['classIds'] as List? ?? []).isNotEmpty)
                      '调整后班级': (r['classIds'] as List).join('\n'),
                    '操作账号': r['changedByActorId'],
                    '操作时间': dateLabel(r['occurredAt']),
                  }, accessChanges: changes,
                     hasAccess: () => current(scope), reauth: reauth,
                     closeOnAccessLost: true),
                ));
        }));
    } finally {
      live = false;
      scope.dispose();
      parentChanged.dispose();
    }
  }
}
