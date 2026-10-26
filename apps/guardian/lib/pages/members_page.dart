import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/member_access.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/dialog_access.dart';
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
  bool _active = true, _rebuildPending = false, _pageClosed = false;
  final _ownerLost = ValueNotifier<bool>(false);
  late final DeviceSubflowScope _pageScope;
  Session get s => widget.session;
  bool get pageCurrent => mounted && _active && _pageScope.current;

  @override
  void initState() {
    super.initState();
    final session = s;
    final root = session.tenant == null ? null : session.root;
    _pageScope = DeviceSubflowScope(session,
        permitted: () => mounted && _active && !_pageClosed && identical(s, session) &&
            session.tenant != null && session.root == root &&
            session.canManage && session.canOpen('members'));
    _pageScope.addListener(_accessChanged);
  }

  void _accessChanged() {
    if (pageCurrent || !mounted || !_active || _rebuildPending) return;
    _rebuildPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildPending = false;
      if (mounted && _active) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void deactivate() {
    _active = false;
    _pageClosed = true;
    _ownerLost.value = true;
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
    _pageClosed = true;
    _ownerLost.value = true;
    _pageScope.removeListener(_accessChanged);
    _pageScope.dispose();
    _ownerLost.dispose();
    super.dispose();
  }

  bool current(DeviceSubflowScope scope) => pageCurrent && scope.current;

  Listenable flowChanges(DeviceSubflowScope scope) =>
      Listenable.merge([scope, _ownerLost]);

  DeviceSubflowScope capture(String root) => DeviceSubflowScope(s,
      permitted: () => pageCurrent && s.tenant != null && s.root == root);

  Api dialogApi(BuildContext dialog, DeviceSubflowScope scope) {
    final route = ModalRoute.of(dialog);
    return scope.api.scoped(() => current(scope) && dialog.mounted &&
        route?.isActive == true &&
        (route is! OwnedDialogRoute<dynamic> || route.available));
  }

  void reauth() {
    if (pageCurrent) s.login(stepUp: true);
  }

  @override
  Widget build(BuildContext context) {
    if (!pageCurrent) {
      return const Notice('工作空间或权限已变化，请重新打开成员管理。', warning: true);
    }
    final root = s.root;
    final viewingInvitations = invitations;
    return ResourcePage(
      key: ValueKey('$root-$invitations-${s.role}'),
      title: '成员与邀请',
      subtitle: '核对成员身份，按职责分配访问权限和档案范围。',
      path: '$root/${invitations ? 'invitations' : 'members'}',
      api: _pageScope.api,
      reauth: reauth,
      create: () async {
        final scope = capture(root);
        try {
          if (!current(scope)) return;
          final reviewInvitations = await widget.invite(
              accessChanges: flowChanges(scope),
              hasAccess: () => current(scope));
          if (current(scope) && reviewInvitations) {
            setState(() => invitations = true);
          }
        } finally {
          scope.dispose();
        }
      },
      createLabel: '邀请成员',
      toolbar: [
        SegmentedButton<bool>(segments: const [
          ButtonSegment(value: false, label: Text('成员')),
          ButtonSegment(value: true, label: Text('邀请记录'))
        ], selected: {
          invitations
        }, onSelectionChanged: (v) {
          if (pageCurrent && v.isNotEmpty) {
            setState(() => invitations = v.first);
          }
        })
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
      onOpen: (row) async {
        if (!pageCurrent || viewingInvitations != invitations) return;
        await (viewingInvitations
            ? openInvitation(root, row) : openMember(root, row));
      },
    );
  }

  Future<void> openInvitation(String root, Json row) async {
    final scope = capture(root);
    try {
      if (!current(scope)) return;
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
          accessChanges: flowChanges(scope),
          hasAccess: () => current(scope),
          actions: [
            if (row['state'] == 'PENDING' &&
                (row['role'] != 'ORG_ADMIN' || s.role == 'OWNER'))
              DetailAction('取消邀请', (dialog) async {
                final complete = captureDialogCompletion(dialog);
                final api = dialogApi(dialog, scope);
                if (!await confirmAction(dialog, '取消邀请', '取消后此邀请令牌将不再有效。')) {
                  return;
                }
                await api.send('DELETE', '$root/invitations/${row['id']}');
                complete();
              }, destructive: true, closeOnSuccess: false),
          ]);
    } finally {
      scope.dispose();
    }
  }

  Future<void> openMember(String root, Json row) async {
    final scope = capture(root);
    try {
      if (!current(scope)) return;
      final kind = s.tenant!['kind'] as String, operatorRole = s.role;
      final path = '$root/members/${row['cursor']}/access';
      final access = await scope.api.send('GET', path) as Json;
      if (!mounted || !current(scope)) return;
      final classIds = List<String>.unmodifiable(
          List<String>.from(access['classIds'] as List? ?? const []));
      final member = <String, dynamic>{...row, ...access, 'classIds': classIds};
      if (access['subjectId'] != row['subjectId']) {
        member['subjectName'] = null;
        member['subjectArchived'] = false;
      }
      final allowed = memberRoles(kind, operatorRole,
          currentRole: access['role']);
      var edit = false;
      final removalKey = requestId();
      final changes = flowChanges(scope);
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
            DetailAction('权限变更记录', (dialog) => history(dialog, root, member, scope),
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
                if (!await confirmAction(dialog, '撤销成员访问',
                    '将撤销 ${memberName(member)} 的工作空间访问。相关未使用邀请、待确认配对、临时授权和预览会失效。')) {
                  return;
                }
                await api.send('DELETE', path,
                    version: access['version'] as int, key: removalKey);
                complete();
                if (mounted && current(scope)) toast(context, '成员访问已撤销。');
              }, destructive: true, closeOnSuccess: false),
            ],
          ]);
      if (edit && current(scope)) {
        // Fetch again after leaving the detail dialog: never silently replace the version on submit.
        final results = await Future.wait([
          scope.api.send('GET', path),
          scope.api.all('$root/subjects'),
          if (kind == 'ORGANIZATION') scope.api.all('$root/classes')
        ]);
        if (!mounted || !current(scope)) return;
        final latest = results[0] as Json;
        final children = results[1] as List<Json>;
        final key = requestId();
        final result = await memberEditorDialog(context,
                  kind: kind,
                  operatorRole: operatorRole,
                  accessChanges: flowChanges(scope),
                  hasAccess: () => current(scope),
                  member: {
                    ...member,
                    ...latest,
                    'subjectName': {
                      for (final c in children) c['id']: c['nickname']
                    }[latest['subjectId']],
                  },
                  subjects: {
                    for (final c in children)
                      if (c['archived'] != true && c['archivedAt'] == null)
                        c['id'] as String: c['nickname'] as String
                  },
                  classes: {
                    if (results.length > 2)
                      for (final c in results[2] as List<Json>)
                        c['id'] as String: c['name'] as String
                  },
                  reauth: reauth,
                  onSubmit: (body, permitted) async {
                    final updated = await scope.api.send('PATCH', path,
                        body: body,
                        version: latest['version'] as int,
                        key: key, isCurrent: permitted) as Json;
                    final version = updated['version'];
                    if (updated['actorId'] != latest['actorId'] ||
                        updated['memberKey'] != latest['memberKey'] ||
                        updated['role'] != body['role'] || version is! int ||
                        version < (latest['version'] as int)) {
                      throw const ApiFailure(502, 'INVALID_RESPONSE');
                    }
                    return updated;
                  },
                );
        if (mounted && result != null && result['refresh'] != true &&
            current(scope)) {
          toast(context, '成员权限已更新。');
        }
      }
    } finally {
      scope.dispose();
    }
  }

  Future<void> history(BuildContext parent, String root, Json member,
      DeviceSubflowScope owner) async {
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
    final changes = Listenable.merge([scope, parentChanged, _ownerLost]);
    try {
      if (!current(scope)) return;
      Api? historyApi;
      await scopedDetailsDialog(parent, '权限变更记录', {
        '成员': memberName(member),
      }, accessChanges: changes, hasAccess: () => current(scope),
        reauth: reauth,
        extraContent: Builder(builder: (dialog) {
          final api = historyApi ??= dialogApi(dialog, scope);
          return SizedBox(width: 920, child: ResourcePage(
                  api: api,
                  path: '$root/members/${member['memberKey']}/access-history',
                  title: '权限变更记录',
                  subtitle: '${memberName(member)} · 按权限版本从新到旧显示角色调整与撤销记录。',
                  emptyTitle: '暂无权限调整记录',
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
                     hasAccess: () => current(scope), reauth: reauth),
                ));
        }));
    } finally {
      live = false;
      scope.dispose();
      parentChanged.dispose();
    }
  }
}
