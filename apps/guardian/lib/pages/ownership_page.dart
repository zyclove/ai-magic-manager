import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/member_access.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/resource_page.dart';

String ownershipState(dynamic state) => switch (state) {
      'PENDING' => '等待对方确认',
      'ACCEPTED' => '交接已完成',
      'DECLINED' => '接收人已拒绝',
      'CANCELLED' => '发起人已撤销',
      'EXPIRED' => '申请已过期',
      'INVALIDATED' => '申请已失效',
      _ => '未知状态',
    };

const ownershipConsequences =
    '交接后，原所有者未完成的成员邀请、设备配对、退出预览和临时授权将失效，未发布的策略需要重新预览。已发布策略和已确认的设备退出保留。支付与账单责任不会自动转移。';

class OwnershipPage extends StatelessWidget {
  final Session session;
  const OwnershipPage({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final s = session;
    final root = s.root;
    return ResourcePage(
        key: ValueKey('$root-ownership-${s.role}'),
        title: '所有者交接',
        subtitle: '由现任所有者发起，对方完成安全验证并接受后生效。',
        path: '$root/ownership-transfers',
        api: s.api,
        reauth: () => s.login(stepUp: true),
        create: s.role == 'OWNER' ? () => propose(context, root) : null,
        createLabel: '发起交接',
        emptyTitle: '暂无交接申请',
        emptyDescription: s.role == 'OWNER'
            ? '先在“成员与邀请”中添加可信任的成人，再发起交接。申请有效期为 24 小时。'
            : '现任所有者向你发起交接后，申请会显示在这里。',
        notice: s.role == 'OWNER'
            ? '每个工作空间只能有一份待确认申请。双方权限或工作空间版本变化后，需要重新发起。'
            : '这里只显示你参与的交接。接受前请核对双方账号和权限变化；你也可以拒绝。',
        columns: [
          ColumnSpec('发起人', (r) => Text(who(r['sourceActorId']))),
          ColumnSpec('接收人', (r) => Text(who(r['targetActorId']))),
          ColumnSpec('状态', (r) => Text(ownershipState(r['state']))),
          ColumnSpec('有效期至', (r) => Text(dateLabel(r['expiresAt']))),
        ],
        onOpen: (row) => open(context, root, row['id'] as String));
  }

  String who(dynamic id) => id == session.profile?['subject']
      ? '${session.displayName}（我）'
      : shortId(id);

  Future<void> propose(BuildContext context, String root) async {
    final s = session;
    final tenantId = s.tenant!['id'];
    final results = await Future.wait([
      s.api.all('$root/members'),
      s.api.all('/tenants'),
    ]);
    if (!context.mounted || s.root != root) return;
    final tenant = results[1].firstWhere((t) => t['id'] == tenantId);
    final formerRole = tenant['kind'] == 'FAMILY' ? 'GUARDIAN' : 'ORG_ADMIN';
    final eligible = results[0]
        .where((m) =>
            m['subjectId'] == null &&
            [formerRole, 'AUDITOR'].contains(m['role']))
        .toList();
    if (eligible.isEmpty) {
      await showDetails(context, '先添加接收成员', {
        '当前没有符合条件的接收人':
            '请在“成员与邀请”中邀请成人${label(formerRole)}或审计员。对方接受邀请后，再发起所有者交接。'
      });
      return;
    }
    final selection = await formDialog(context,
        title: '选择接收人',
        description: '请选择已经核实身份的成人成员。下一步将显示完整账号标识和交接影响。',
        fields: [
          FieldSpec('targetActorId', '接收成员', options: {
            for (final member in eligible)
              member['actorId'] as String:
                  '${memberName(member)} · ${member['verifiedEmail'] ?? shortId(member['actorId'])} · ${label(member['role'])}'
          })
        ],
        submit: '查看交接内容',
        onSubmit: (values) async => values);
    if (selection == null || !context.mounted || s.root != root) return;
    final target =
        eligible.firstWhere((m) => m['actorId'] == selection['targetActorId']);
    final key = requestId();
    Json? created;
    await actionDetails(
        context,
        '确认发起所有者交接',
        {
          '工作空间': tenant['name'],
          '接收账号（请核对完整标识）': target['actorId'],
          '接收人的权限变化': '${label(target['role'])} → 所有者',
          '你的权限变化': '所有者 → ${label(formerRole)}',
          '生效条件': '24 小时内由对方完成近期多因素认证并接受；发起后你的所有者权限暂时保留。',
          '交接影响': ownershipConsequences,
        },
        reauth: () => s.login(stepUp: true),
        actions: [
          DetailAction('确认发起，等待对方接受', (dialog) async {
            final result = await s.api.send('POST', '$root/ownership-transfers',
                body: {'targetActorId': target['actorId']},
                version: tenant['version'] as int,
                key: key) as Json;
            created = result;
            if (dialog.mounted) Navigator.pop(dialog);
          }, closeOnSuccess: false)
        ]);
    // Keep the page action alive through the follow-up dialog so its final
    // refresh includes a cancellation or decision made immediately after creation.
    if (created != null && context.mounted && s.root == root) {
      toast(context, '交接申请已发起，请通知接收人前往“所有者交接”查看。');
      await open(context, root, created!['id'] as String);
    }
  }

  Future<void> open(BuildContext context, String root, String id) async {
    final s = session;
    final path = '$root/ownership-transfers/$id';
    final r = await s.api.send('GET', path) as Json;
    if (!context.mounted || s.root != root) return;
    final actor = s.profile?['subject'];
    final pending = r['state'] == 'PENDING';
    final keys = {
      for (final action in ['accept', 'decline', 'cancel']) action: requestId()
    };
    Future<void> act(BuildContext dialog, String action) async {
      final title = switch (action) {
        'accept' => '接受并成为所有者',
        'decline' => '拒绝本次交接',
        _ => '撤销本次交接',
      };
      if (!await confirmAction(
          dialog,
          title,
          action == 'accept'
              ? '你将成为当前工作空间唯一所有者，${r['sourceActorId']} 将变为${label(r['formerOwnerRole'])}。\n\n$ownershipConsequences'
              : '此申请将结束，工作空间所有者保持不变。需要交接时可重新发起。',
          confirm: title)) return;
      final result = await s.api.send('POST', '$path/$action',
          version: r['version'] as int, key: keys[action]) as Json;
      // A successful HTTP response can carry a freshly expired or invalidated state.
      final completed = result['state'] == 'ACCEPTED';
      if (dialog.mounted) Navigator.pop(dialog);
      if (context.mounted) {
        toast(context,
            completed ? '交接完成，正在刷新你的权限。' : ownershipState(result['state']));
      }
      await s.loadTenants();
    }

    await actionDetails(
        context,
        '交接详情',
        {
          '状态': ownershipState(r['state']),
          '发起账号': r['sourceActorId'],
          '接收账号': r['targetActorId'],
          '接收人权限': '${label(r['targetRole'])} → 所有者',
          '原所有者权限': '所有者 → ${label(r['formerOwnerRole'])}',
          '申请时间': dateLabel(r['createdAt']),
          '确认截止时间': dateLabel(r['expiresAt']),
          if (r['reason'] != null)
            '结束原因': switch (r['reason']) {
              'TENANT_CHANGED' => '工作空间已更新，请现任所有者重新发起。',
              'MEMBERSHIP_CHANGED' => '双方成员或权限发生变化，请重新核对后发起。',
              'TIME_EXPIRED' => '超过 24 小时确认期限。',
              _ => '申请已不可用，请刷新后重新发起。',
            },
          '交接影响': ownershipConsequences,
        },
        reauth: () => s.login(stepUp: true),
        actions: [
          if (pending && actor == r['targetActorId']) ...[
            DetailAction('接受并成为所有者', (d) => act(d, 'accept'),
                closeOnSuccess: false),
            DetailAction('拒绝交接', (d) => act(d, 'decline'),
                destructive: true, closeOnSuccess: false),
          ],
          if (pending && actor == r['sourceActorId'] && s.role == 'OWNER')
            DetailAction('撤销申请', (d) => act(d, 'cancel'),
                destructive: true, closeOnSuccess: false),
        ]);
  }
}
