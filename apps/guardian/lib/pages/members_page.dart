import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/member_access.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/member_editor.dart';
import '../ui/resource_page.dart';

class MembersPage extends StatefulWidget {
  final Session session;
  final Future<bool> Function() invite;
  const MembersPage({super.key, required this.session, required this.invite});
  @override
  State<MembersPage> createState() => _MembersPageState();
}

class _MembersPageState extends State<MembersPage> {
  bool invitations = false;
  Session get s => widget.session;
  void reauth() => s.login(stepUp: true);
  void requireWorkspace(String root) {
    if (s.root != root) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  @override
  Widget build(BuildContext context) {
    final root = s.root;
    if (!s.canManage) return const Notice('当前角色无权查看成员管理。', warning: true);
    return ResourcePage(
      key: ValueKey('$root-$invitations-${s.role}'),
      title: '成员与邀请',
      subtitle: '核对成员身份，按职责分配访问权限和档案范围。',
      path: '$root/${invitations ? 'invitations' : 'members'}',
      api: s.api,
      reauth: reauth,
      create: () async {
        final reviewInvitations = await widget.invite();
        if (mounted && s.root == root && reviewInvitations) {
          setState(() => invitations = true);
        }
      },
      createLabel: '邀请成员',
      toolbar: [
        SegmentedButton<bool>(segments: const [
          ButtonSegment(value: false, label: Text('成员')),
          ButtonSegment(value: true, label: Text('邀请记录'))
        ], selected: {
          invitations
        }, onSelectionChanged: (v) => setState(() => invitations = v.first))
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
      onOpen: (row) =>
          invitations ? openInvitation(root, row) : openMember(root, row),
    );
  }

  Future<void> openInvitation(String root, Json row) async {
    await actionDetails(
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
        actions: [
          if (row['state'] == 'PENDING' &&
              (row['role'] != 'ORG_ADMIN' || s.role == 'OWNER'))
            DetailAction('取消邀请', (dialog) async {
              if (!await confirmAction(dialog, '取消邀请', '取消后此邀请令牌将不再有效。')) {
                return;
              }
              requireWorkspace(root);
              await s.api.send('DELETE', '$root/invitations/${row['id']}');
              if (dialog.mounted) Navigator.pop(dialog);
            }, destructive: true, closeOnSuccess: false),
        ]);
  }

  Future<void> openMember(String root, Json row) async {
    final path = '$root/members/${row['cursor']}/access';
    final sources = await Future.wait([
      s.api.send('GET', path),
      if (s.tenant!['kind'] == 'ORGANIZATION')
        s.api.all('$root/classes?includeArchived=true')
    ]);
    final access = sources[0] as Json;
    final classNames = {
      if (sources.length > 1)
        for (final c in sources[1] as List<Json>)
          c['id']: '${c['name']}${c['state'] == 'ARCHIVED' ? '（已归档）' : ''}'
    };
    if (!mounted || s.root != root) return;
    final current = <String, dynamic>{...row, ...access};
    if (access['subjectId'] != row['subjectId']) {
      current['subjectName'] = null;
      current['subjectArchived'] = false;
    }
    final allowed = memberRoles(s.tenant!['kind'] as String, s.role,
        currentRole: access['role']);
    var edit = false;
    final removalKey = requestId();
    await actionDetails(
        context,
        '成员详情',
        {
          '姓名': memberName(current),
          '完整账号标识': current['actorId'],
          if (current['role'] != 'CHILD')
            '已验证邮箱': current['verifiedEmail'] ?? '暂无已验证邮箱资料',
          '角色': label(current['role']),
          '访问范围': memberScope(current),
          if (current['subjectId'] != null) '档案标识': current['subjectId'],
          if ((current['classIds'] as List? ?? []).isNotEmpty)
            '获授班级': (current['classIds'] as List)
                .map((id) => '${classNames[id] ?? '不可用班级'} · $id')
                .join('\n'),
          '权限版本': current['version'],
          '资料最近同步': dateLabel(current['profileUpdatedAt']),
          if (current['role'] == 'OWNER') '所有者权限': '如需转交，请使用“所有者交接”，由对方确认接收。',
        },
        reauth: reauth,
        actions: [
          DetailAction('权限变更记录', (dialog) => history(dialog, root, current),
              closeOnSuccess: false),
          if (allowed.isNotEmpty) ...[
            DetailAction('调整权限', (dialog) async {
              edit = true;
              Navigator.pop(dialog);
            }, closeOnSuccess: false),
            DetailAction('撤销访问', (dialog) async {
              if (!await confirmAction(dialog, '撤销成员访问',
                  '将撤销 ${memberName(current)} 的工作空间访问。相关未使用邀请、待确认配对、临时授权和预览会失效。')) {
                return;
              }
              requireWorkspace(root);
              await s.api.send('DELETE', path,
                  version: access['version'] as int, key: removalKey);
              if (dialog.mounted) Navigator.pop(dialog);
              if (mounted) toast(context, '成员访问已撤销。');
            }, destructive: true, closeOnSuccess: false),
          ],
        ]);
    if (edit && mounted && s.root == root) {
      // Fetch again after leaving the detail dialog: never silently replace the version on submit.
      final results = await Future.wait([
        s.api.send('GET', path),
        s.api.all('$root/subjects'),
        if (s.tenant!['kind'] == 'ORGANIZATION') s.api.all('$root/classes')
      ]);
      if (!mounted || s.root != root) return;
      final latest = results[0] as Json;
      final children = results[1] as List<Json>;
      final key = requestId();
      final result = await showDialog<Json>(
          context: context,
          barrierDismissible: false,
          builder: (_) => MemberEditor(
                kind: s.tenant!['kind'] as String,
                operatorRole: s.role,
                member: {
                  ...current,
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
                onSubmit: (body) async {
                  requireWorkspace(root);
                  return await s.api.send('PATCH', path,
                      body: body,
                      version: latest['version'] as int,
                      key: key) as Json;
                },
              ));
      if (result != null && mounted && s.root == root) {
        toast(context, '成员权限已更新。');
      }
    }
  }

  Future<void> history(BuildContext parent, String root, Json member) =>
      showDialog<void>(
        context: parent,
        builder: (dialog) => Dialog(
            child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920, maxHeight: 720),
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                    child: SingleChildScrollView(
                        child: ResourcePage(
                  api: s.api,
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
                  onOpen: (r) => showDetails(dialog, '权限变更详情', {
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
                  }),
                ))),
                Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                        onPressed: () => Navigator.pop(dialog),
                        child: const Text('关闭记录'))),
              ])),
        )),
      );
}
