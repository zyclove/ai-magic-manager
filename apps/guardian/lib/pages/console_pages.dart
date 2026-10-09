import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/resource_page.dart';
import 'editors.dart';
import 'device_exit_dialog.dart';

class ConsolePages extends StatelessWidget {
  final String section;
  const ConsolePages({super.key, required this.section});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    final actions = ConsoleActions(context, s);
    if (s.tenant == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const PageHeading('开始你的管理旅程', '创建工作空间，连接家庭或教育机构的设备。'),
        Panel(
            child: EmptyView('还没有工作空间', '所有档案、设备和规则都归属于一个工作空间。',
                action: s.profile?['canCreateTenant'] == true
                    ? FilledButton.icon(
                        onPressed: actions.createTenant,
                        icon: const Icon(Icons.add),
                        label: const Text('创建工作空间'))
                    : null)),
        const SizedBox(height: 16),
        OutlinedButton(
            onPressed: actions.acceptInvitation,
            child: const Text('我有邀请，加入工作空间'))
      ]);
    }
    if (!s.canOpen(section)) {
      return const Panel(
          child: EmptyView('此角色无权访问该页面', '请从导航中选择可用功能，或联系工作空间管理员。'));
    }
    if (section == 'overview' && !s.canWrite) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeading(
            '欢迎，${s.displayName}', '${label(s.role)} · ${s.tenant!['name']}'),
        Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('选择你需要查看的内容',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 20),
          Wrap(spacing: 12, runSpacing: 12, children: [
            if (s.canOpen('subjects'))
              OutlinedButton(
                  onPressed: () => context.go('/subjects'),
                  child: const Text('我的档案')),
            if (s.canOpen('devices'))
              OutlinedButton(
                  onPressed: () => context.go('/devices'),
                  child: const Text('我的设备')),
            if (s.canOpen('approvals'))
              OutlinedButton(
                  onPressed: () => context.go('/approvals'),
                  child: const Text('我的访问申请')),
            if (s.canOpen('policies'))
              OutlinedButton(
                  onPressed: () => context.go('/policies'),
                  child: const Text('查看策略')),
            if (s.canOpen('audit'))
              OutlinedButton(
                  onPressed: () => context.go('/audit'),
                  child: const Text('审计日志')),
          ])
        ]))
      ]);
    }
    ResourcePage resource(
            {required String title,
            required String subtitle,
            required String path,
            required List<ColumnSpec> columns,
            Future<void> Function()? create,
            String createLabel = '新建',
            Future<void> Function(Json)? open,
            String? notice,
            String empty = '暂无记录',
            String description = '创建第一条记录，开始管理。',
            List<Widget> toolbar = const []}) =>
        ResourcePage(
            key: ValueKey('$path-${s.tenant!['id']}'),
            title: title,
            subtitle: subtitle,
            path: '${s.root}/$path',
            api: s.api,
            columns: columns,
            create: create,
            createLabel: createLabel,
            onOpen: open,
            notice: notice,
            emptyTitle: empty,
            emptyDescription: description,
            toolbar: toolbar,
            reauth: () => s.login(stepUp: true));
    switch (section) {
      case 'subjects':
        return resource(
            title: '儿童档案',
            subtitle: '按年龄段建立档案，为每位孩子配置合适的规则。',
            path: 'subjects',
            columns: [
              ColumnSpec(
                  '儿童', (r) => _name(r['nickname'], Icons.person_outline)),
              ColumnSpec('年龄段', (r) => Text(label(r['ageBand']))),
              ColumnSpec(
                  '档案编号',
                  (r) => Text(shortId(r['id']),
                      style: const TextStyle(color: muted)))
            ],
            create: s.canWrite ? () => actions.subject() : null,
            createLabel: '添加儿童',
            open: actions.subjectDetails,
            empty: '还没有儿童档案',
            description: '只记录昵称和年龄段，不需要完整生日。');
      case 'devices':
        return resource(
            title: '设备管理',
            subtitle: '查看设备注册、连接状态和实际管理能力。',
            path: 'devices',
            columns: [
              ColumnSpec(
                  '设备',
                  (r) => _name(
                      r['displayName'],
                      r['platform'] == 'ANDROID_TV'
                          ? Icons.tv_outlined
                          : Icons.smartphone_outlined)),
              ColumnSpec('平台', (r) => Text(label(r['platform']))),
              ColumnSpec('注册状态', (r) => StatusTag(r['state'])),
              ColumnSpec('最近心跳', (r) => Text(dateLabel(r['lastHeartbeatAt'])))
            ],
            create: s.canWrite ? actions.enrollment : null,
            createLabel: '添加设备',
            open: actions.deviceDetails,
            notice: '设备注册成功代表已绑定。策略是否实际执行，需以设备能力和执行回执为准。',
            empty: '尚未连接设备',
            description: '先创建儿童档案，再通过配对流程绑定 Android 或 TV 设备。',
            toolbar: [
              if (s.canWrite)
                TextButton(
                    onPressed: actions.findEnrollment,
                    child: const Text('查询注册进度'))
            ]);
      case 'applications':
        return resource(
            title: '应用目录',
            subtitle: '登记应用身份，供策略和使用计划引用。',
            path: 'applications',
            columns: [
              ColumnSpec(
                  '应用', (r) => _name(r['displayName'], Icons.apps_outlined)),
              ColumnSpec('包名', (r) => Text(r['packageName'])),
              ColumnSpec(
                  '平台 / 空间',
                  (r) =>
                      Text('${label(r['platform'])} · ${label(r['profile'])}')),
              ColumnSpec('身份状态', (r) => StatusTag(r['evidenceStatus']))
            ],
            create: s.canWrite ? actions.application : null,
            createLabel: '登记应用',
            open: (r) => showDetails(context, r['displayName'], {
                  '包名': r['packageName'],
                  '平台': label(r['platform']),
                  '资料空间': label(r['profile']),
                  '签名摘要': (r['signingDigests'] as List).join('\n'),
                  '身份状态': label(r['evidenceStatus']),
                  '应用编号': r['id']
                }),
            notice: '目录中的身份由管理员登记，不代表应用已经安装或完成安全认证。');
      case 'schedules':
        return resource(
            title: '时间计划',
            subtitle: '按每周时段与特殊日期安排设备使用。',
            path: 'schedules',
            columns: [
              ColumnSpec(
                  '计划', (r) => _name(r['name'], Icons.schedule_outlined)),
              ColumnSpec('时区', (r) => Text(r['definition']['timeZone'])),
              ColumnSpec(
                  '每周时段',
                  (r) =>
                      Text('${(r['definition']['weekly'] as List).length} 个')),
              ColumnSpec(
                  '日期例外',
                  (r) => Text(
                      '${(r['definition']['exceptions'] as List).length} 个'))
            ],
            create: s.canWrite ? () => scheduleEditor(context, s) : null,
            createLabel: '创建计划',
            open: actions.scheduleDetails,
            notice: '计划保存后保持不可变，调整时请创建新的计划并更新策略引用。');
      case 'policies':
        return resource(
            title: '策略中心',
            subtitle: '从草稿开始，预览影响，再发布有版本的配置。',
            path: 'policies',
            columns: [
              ColumnSpec(
                  '策略名称', (r) => _name(r['name'], Icons.shield_outlined)),
              ColumnSpec('类型', (r) => StatusTag(r['kind'])),
              ColumnSpec(
                  '规则数', (r) => Text('${(r['rules'] as List).length} 条')),
              ColumnSpec('草稿修订', (r) => Text('v${r['revision']}'))
            ],
            create: s.canWrite ? () => policyEditor(context, s) : null,
            createLabel: '创建策略',
            open: actions.policyDetails,
            notice: '当前支持云端配置保存。设备系统执行适配器未配置时，不会显示“策略已生效”。');
      case 'approvals':
        return resource(
            title: '访问审批',
            subtitle: '审阅儿童的临时访问请求，保留有期限的决定记录。',
            path: 'access-requests',
            columns: [
              ColumnSpec('请求',
                  (r) => _name(shortId(r['id']), Icons.task_alt_outlined)),
              ColumnSpec(
                  '申请时长',
                  (r) =>
                      Text('${(r['requestedWindowSeconds'] / 60).ceil()} 分钟')),
              ColumnSpec('状态', (r) => StatusTag(r['state'])),
              ColumnSpec('创建时间', (r) => Text(dateLabel(r['createdAt'])))
            ],
            open: actions.approvalDetails,
            empty: '暂无访问申请',
            description: '儿童发起访问申请后，将在这里显示。',
            notice: '批准代表同意一个有界访问窗口；当前未接入设备例外执行，批准不会直接解锁设备。');
      case 'members':
        return MembersPage(session: s, actions: actions);
      case 'audit':
        return resource(
            title: '审计日志',
            subtitle: '追踪工作空间中的管理操作与资源变更。',
            path: 'audit-events',
            columns: [
              ColumnSpec('操作', (r) => Text(label(r['action']))),
              ColumnSpec('资源', (r) => Text(shortId(r['resourceId']))),
              ColumnSpec('操作者', (r) => Text(shortId(r['actorId']))),
              ColumnSpec('时间', (r) => Text(dateLabel(r['occurredAt'])))
            ],
            open: (r) => showDetails(context, '审计事件', {
                  '操作': label(r['action']),
                  '资源编号': r['resourceId'],
                  '操作者': r['actorId'],
                  '时间': dateLabel(r['occurredAt']),
                  '关联编号': r['correlationId'],
                  '事件编号': r['id']
                }),
            empty: '暂无活动记录',
            description: '新的管理操作将在这里留下记录。',
            notice: '列表按资源游标稳定分页；记录时间以每条事件的发生时间为准。');
      case 'settings':
        return SettingsPage(session: s, actions: actions);
      default:
        return Dashboard(session: s, actions: actions);
    }
  }

  Widget _name(dynamic value, IconData icon) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
                color: canvas, borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 20, color: navy)),
        const SizedBox(width: 12),
        Flexible(
            child: Text(value?.toString() ?? '—',
                style: const TextStyle(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis))
      ]);
}

class ConsoleActions {
  final BuildContext context;
  final Session s;
  final String root;
  ConsoleActions(this.context, this.s) : root = s.tenant == null ? '' : s.root;
  VoidCallback get reauth => () => s.login(stepUp: true);
  Future<void> createTenant() async {
    final key = requestId();
    final result = await formDialog(context,
        title: '创建工作空间',
        fields: [
          const FieldSpec('name', '工作空间名称'),
          FieldSpec('kind', '类型', options: options(['FAMILY', 'ORGANIZATION'])),
          const FieldSpec('timeZone', '时区', hint: 'Asia/Shanghai')
        ],
        initial: {'kind': 'FAMILY', 'timeZone': 'Asia/Shanghai'},
        onSubmit: (v) async =>
            await s.api.send('POST', '/tenants', body: v, key: key) as Json);
    if (result != null) {
      await s.loadTenants();
      await s
          .selectTenant(s.tenants.firstWhere((t) => t['id'] == result['id']));
    }
  }

  Future<void> acceptInvitation() async {
    final result = await formDialog(context,
        title: '接受邀请',
        description: '使用与你当前账户邮箱一致的邀请。成人加入可能需要近期多因素认证。',
        fields: const [FieldSpec('token', '一次性邀请令牌', maxLength: 128)],
        reauth: reauth,
        onSubmit: (v) async =>
            await s.api.send('POST', '/invitations/accept', body: v) as Json);
    if (result != null) await s.loadTenants();
  }

  Future<void> subject([Json? existing]) async {
    final key = requestId();
    await formDialog(context,
        title: existing == null ? '添加儿童档案' : '编辑儿童档案',
        fields: [
          const FieldSpec('nickname', '昵称', maxLength: 60),
          FieldSpec('ageBand', '年龄段',
              options: options(['UNDER_7', 'AGE_7_12', 'AGE_13_17']))
        ],
        initial: existing ?? {},
        reauth: reauth,
        onSubmit: (v) async => await s.api.send(
            existing == null ? 'POST' : 'PATCH',
            '$root/subjects${existing == null ? '' : '/${existing['id']}'}',
            body: v,
            key: key,
            version: existing?['version']) as Json);
  }

  Future<void> subjectDetails(Json row) async {
    final r = await s.api.send('GET', '$root/subjects/${row['id']}') as Json;
    if (!context.mounted) return;
    await actionDetails(
        context,
        r['nickname'],
        {
          '昵称': r['nickname'],
          '年龄段': label(r['ageBand']),
          '档案编号': r['id'],
          '版本': r['version']
        },
        reauth: reauth,
        actions: s.canWrite
            ? [
                DetailAction('编辑档案', (_) => subject(r)),
                DetailAction('归档', (ctx) async {
                  if (await confirmAction(ctx, '归档儿童档案',
                      '归档后将不再显示在活动档案中，相关临时访问窗口会失效。此操作不会自动解除设备管理。',
                      confirm: '确认归档')) {
                    await s.api.send(
                        'POST', '$root/subjects/${r['id']}/archive',
                        version: r['version']);
                  }
                }, destructive: true)
              ]
            : []);
  }

  Future<void> application() async {
    final key = requestId();
    await formDialog(context,
        title: '登记应用',
        description: '填写准确的 Android 包名。签名摘要可选，使用小写 SHA-256，多个摘要用逗号分隔。',
        fields: [
          const FieldSpec('displayName', '应用名称'),
          const FieldSpec('packageName', 'Android 包名',
              hint: 'com.example.app', maxLength: 255),
          FieldSpec('platform', '平台',
              options: options(['ANDROID', 'ANDROID_TV'])),
          FieldSpec('profile', '资料空间',
              options: options(['PRIMARY', 'WORK', 'SECONDARY', 'UNKNOWN'])),
          const FieldSpec('digests', '签名摘要',
              required: false, maxLength: 519, lines: 2)
        ],
        initial: {
          'platform': 'ANDROID',
          'profile': 'PRIMARY'
        }, onSubmit: (v) async {
      final data = Map<String, dynamic>.from(v);
      final raw = data.remove('digests') as String;
      data['signingDigests'] = raw
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      return await s.api
          .send('POST', '$root/applications', body: data, key: key) as Json;
    });
  }

  Future<void> scheduleDetails(Json r) async {
    final d = r['definition'] as Json;
    await actionDetails(context, r['name'], {
      '时区': d['timeZone'],
      '每周时段': (d['weekly'] as List)
          .map((w) => '${label(w['day'])}  ${w['start']} – ${w['end']}')
          .join('\n'),
      '日期例外': (d['exceptions'] as List)
          .map((e) =>
              '${e['date']}: ${(e['windows'] as List).isEmpty ? '全天关闭' : e['windows']}')
          .join('\n'),
      '说明': '已保存计划不可变；需要调整时创建新计划。'
    }, actions: [
      DetailAction('检查此刻是否允许', (ctx) async {
        final decision = await s.api.send('GET',
                '$root/schedules/${r['id']}/evaluation?at=${Uri.encodeQueryComponent(DateTime.now().toUtc().toIso8601String())}')
            as Json;
        if (ctx.mounted) {
          await showDetails(ctx, '时段计算结果', {
            '结果': decision['allowed'] == true ? '当前在允许时段内' : '当前不在允许时段内',
            '当前允许截止': dateLabel(decision['currentUntil']),
            '下次允许时间': dateLabel(decision['nextAllowedAt']),
            '计算时区': decision['timeZone'],
            '当地日期': decision['localDate']
          });
        }
      })
    ]);
  }

  Future<void> enrollment() async {
    final children = await s.api.all('$root/subjects');
    if (!context.mounted) return;
    if (children.isEmpty) {
      toast(context, '请先创建儿童档案。');
      context.go('/subjects');
      return;
    }
    final ticket = await formDialog(context,
        title: '添加设备',
        description: '创建一次性注册凭据后，需要在设备端完成密钥证明与配对。当前仅开放个人设备模式。',
        fields: [
          FieldSpec('subjectId', '所属儿童',
              options: entityOptions(children, 'nickname')),
          FieldSpec('platform', '平台',
              options: options(['ANDROID', 'ANDROID_TV']))
        ],
        initial: {'platform': 'ANDROID'},
        reauth: reauth,
        onSubmit: (v) async => await s.api.send('POST', '$root/enrollments',
            body: {...v, 'requestedMode': 'BYOD'}) as Json);
    if (ticket != null && context.mounted) {
      await showDetails(context, '设备注册凭据', {
        '请妥善保存': '一次性凭据只显示此次，不会再次查询到。请在设备端输入并按设备提示完成配对。',
        '注册编号': ticket['id'],
        '一次性注册凭据': ticket['token'],
        '有效期': dateLabel(ticket['expiresAt']),
        '状态': label(ticket['state'])
      });
    }
  }

  Future<void> findEnrollment() async {
    final r = await formDialog(context,
        title: '查询注册进度',
        fields: const [FieldSpec('id', '注册编号', maxLength: 36)],
        onSubmit: (v) async => await s.api.send(
                'GET', '$root/enrollments/${Uri.encodeComponent(v['id'])}')
            as Json);
    if (r == null || !context.mounted) return;
    await actionDetails(
        context,
        '注册进度',
        {
          '注册编号': r['id'],
          '状态': label(r['state']),
          '有效期': dateLabel(r['expiresAt']),
          '设备编号': r['deviceId']
        },
        reauth: reauth,
        actions: s.canWrite
            ? [
                DetailAction('确认配对', (ctx) async {
                  await formDialog(ctx,
                      title: '确认设备配对',
                      description: '核对设备上显示的 8 位配对码。',
                      fields: const [
                        FieldSpec('pairingCode', '配对码', maxLength: 8)
                      ],
                      reauth: reauth,
                      onSubmit: (v) async => await s.api.send(
                          'POST', '$root/enrollments/${r['id']}/confirm',
                          body: v) as Json);
                }),
                DetailAction('取消注册', (ctx) async {
                  if (await confirmAction(ctx, '取消注册', '此注册凭据将不再可用。')) {
                    await s.api
                        .send('DELETE', '$root/enrollments/${r['id']}');
                  }
                }, destructive: true)
              ]
            : []);
  }

  Future<void> deviceDetails(Json row) async {
    final r = await s.api.send('GET', '$root/devices/${row['id']}') as Json;
    if (!context.mounted) return;
    await actionDetails(
        context,
        r['displayName'],
        {
          '平台': '${label(r['platform'])} · ${r['osVersion']}',
          '注册状态': label(r['state']),
          '管理模式': label(r['managementMode']),
          '控制能力': label(r['controlLevel']),
          '最近心跳': dateLabel(r['lastHeartbeatAt']),
          '观察状态': label(r['observationStatus']),
          '设备编号': r['id'],
          '儿童编号': r['subjectId']
        },
        reauth: reauth,
        actions: [
          DetailAction('能力详情', (ctx) async {
            final value = await s.api
                .send('GET', '$root/devices/${r['id']}/capabilities') as Json;
            if (ctx.mounted) {
              await showDetails(ctx, '设备能力', {
                '说明': '设备自报权限不等于系统执行能力已经认证。',
                for (final item in value['items'] as List)
                  label(item['key']): '${label(item['status'])} · ${label(item['grantStatus'])}\n${label(item['limitationCode'])}\n最近检查：${dateLabel(item['checkedAt'])}'
              });
            }
          }),
          DetailAction('应用清单', (ctx) async {
            final value = await s.api.send(
                    'GET', '$root/devices/${r['id']}/application-inventory')
                as Json;
            if (ctx.mounted) {
              await showDetails(ctx, '设备自报应用清单', {
                '观察状态': label(value['observationStatus']),
                '最近上报': dateLabel(value['receivedAt']),
                '可信程度': label(value['evidenceStatus']),
                '可见范围': label(value['visibility']),
                if ((value['applications'] as List).isEmpty) '应用': '尚无可见应用上报，不能据此判断设备未安装应用。',
                for (final app in value['applications'] as List)
                  '${app['displayName']} · ${label(app['profile'])}': '${app['packageName']}\n版本号：${app['versionCode']} · ${app['systemApplication'] == true ? '系统应用' : '普通应用'}'
              });
            }
          }),
          if (s.canWrite && ['ACTIVE', 'REVOKED'].contains(r['state']))
            DetailAction('正常退出管理', (ctx) => deprovision(ctx, r),
                destructive: true),
          if (s.canWrite) DetailAction('退出操作记录', (ctx) => deprovision(ctx, r))
        ]);
  }

  Future<void> deprovision(BuildContext ctx, Json device) async {
    if (s.root != root) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    await openDeviceExit(ctx, s, device);
  }

  Future<void> policyDetails(Json row) async {
    final r = await s.api.send('GET', '$root/policies/${row['id']}') as Json;
    if (!context.mounted) return;
    await actionDetails(
        context,
        r['name'],
        {
          '类型': label(r['kind']),
          '草稿版本': 'v${r['revision']}',
          '规则': (r['rules'] as List)
              .map((x) =>
                  '${label(x['kind'])} · ${label(x['effect'])} · ${ruleSummary(Map<String, dynamic>.from(x), [], [])}')
              .join('\n'),
          '策略编号': r['id']
        },
        reauth: reauth,
        actions: [
          if (s.canWrite)
            DetailAction('编辑草稿', (_) => policyEditor(context, s, draft: r)),
          if (s.canWrite && r['kind'] == 'TEMPLATE')
            DetailAction('从模板创建策略', (ctx) async {
              final copyKey = requestId();
              await formDialog(ctx,
                  title: '复制为策略',
                  fields: const [FieldSpec('name', '新策略名称')],
                  initial: {'name': '${r['name']} · 副本'},
                  onSubmit: (v) async => await s.api.send(
                      'POST', '$root/policies/${r['id']}/copies',
                      version: r['revision'], key: copyKey, body: v) as Json);
            }),
          if (s.canWrite && r['kind'] == 'POLICY')
            DetailAction('预览与发布', (ctx) => previewPolicy(ctx, r)),
          DetailAction('版本历史', (ctx) => versions(ctx, r))
        ]);
  }

  Future<void> previewPolicy(BuildContext ctx, Json draft) async {
    final devices = (await s.api.all('$root/devices'))
        .where((d) => d['state'] == 'ACTIVE')
        .toList();
    if (!ctx.mounted) return;
    if (devices.isEmpty) {
      toast(ctx, '没有已注册设备，请先完成设备配对。');
      return;
    }
    final picked = await formDialog(ctx,
        title: '选择预览设备',
        fields: [
          FieldSpec('deviceId', '设备',
              options: entityOptions(devices, 'displayName'))
        ],
        onSubmit: (v) async => v);
    if (picked == null) return;
    final p = await s.api.send(
        'POST', '$root/policies/${draft['id']}/previews',
        version: draft['revision'],
        body: {
          'deviceIds': [picked['deviceId']]
        }) as Json;
    if (!ctx.mounted) return;
    final publicationKey = requestId();
    await actionDetails(
        ctx,
        '发布前预览',
        {
          '有效期': dateLabel(p['expiresAt']),
          '执行支持': p['enforceable'] == true ? '支持执行' : '设备能力不足或执行适配器未配置',
          '目标与检查': (p['targets'] as List).map((t) {
            final name = devices.where((d) => d['id'] == t['deviceId']).firstOrNull?['displayName'] ?? shortId(t['deviceId']);
            final rules = (t['rules'] as List).map((r) => '${label(r['kind'])}：${label(r['status'])} · ${label(r['reasonCode'])}').join('\n');
            return '$name · ${label(t['observationStatus'])}\n$rules';
          }).join('\n\n'),
          '发布说明': '仅保存配置不会使设备系统策略生效。发布需近期多因素认证。'
        },
        reauth: reauth,
        actions: [
          DetailAction('仅保存配置', (inner) async {
            if (!await confirmAction(
                inner, '发布配置', '确认保存本次预览中的配置版本？当前不会执行设备系统管控。',
                confirm: '发布配置')) {
              return;
            }
            final result = await s.api.send(
                'POST', '$root/policies/${draft['id']}/publications',
                version: draft['revision'],
                key: publicationKey,
                body: {
                  'previewId': p['id'],
                  'previewHash': p['hash'],
                  'mode': 'CONFIGURE_ONLY'
                }) as Json;
            if (inner.mounted) {
              await showDetails(inner, '发布结果', {
                '状态': label(result['state']), '发布方式': label(result['mode']),
                '版本': result['sequence'], '发布时间': dateLabel(result['createdAt']),
                '操作编号': result['id']
              });
            }
          })
        ]);
  }

  Future<void> versions(BuildContext ctx, Json draft) async {
    final rows = await s.api.all('$root/policies/${draft['id']}/versions');
    if (!ctx.mounted) return;
    await showDialog<void>(
        context: ctx,
        builder: (dialog) => AlertDialog(
                title: const Text('版本历史'),
                content: SizedBox(
                    width: 620,
                    child: SingleChildScrollView(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (rows.isEmpty)
                        const EmptyView('还没有发布版本', '预览并发布后，可在这里查看历史。'),
                      ...rows.map((r) => ListTile(
                          title: Text(
                              '版本 ${r['sequence'] ?? r['versionNumber'] ?? shortId(r['id'])}'),
                          subtitle: Text(dateLabel(r['createdAt'])),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            final rollbackKey = requestId();
                            await actionDetails(dialog, '历史版本', {
                                  '版本': r['sequence'], '发布方式': label(r['mode']),
                                  '发布时间': dateLabel(r['createdAt']),
                                  '规则数': (r['snapshot']['sourceRules'] as List).length,
                                  '目标设备数': (r['snapshot']['targets'] as List).length,
                                  '版本编号': r['id']
                                },
                                reauth: reauth,
                                actions: s.canWrite
                                    ? [
                                        DetailAction('回滚为草稿', (inner) async {
                                          if (await confirmAction(
                                              inner,
                                              '回滚为草稿',
                                              '将历史规则恢复到当前策略草稿。不会改变已经发布的版本，仍需重新预览并发布。')) {
                                            await s.api.send('POST',
                                                '$root/policies/${draft['id']}/versions/${r['id']}/rollback-drafts',
                                                version: draft['revision'],
                                                key: rollbackKey,
                                                body: {'name': draft['name']});
                                          }
                                        })
                                      ]
                                    : []);
                          }))
                    ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: const Text('关闭'))
                ]));
  }

  Future<void> approvalDetails(Json row) async {
    final r =
        await s.api.send('GET', '$root/access-requests/${row['id']}') as Json;
    if (!context.mounted) return;
    await actionDetails(
        context,
        '临时访问申请',
        {
          '状态': label(r['state']),
          '申请时长': '${r['requestedWindowSeconds']} 秒',
          '申请理由': r['reason'],
          '有效期': dateLabel(r['requestExpiresAt']),
          '设备编号': r['deviceId'],
          '儿童编号': r['subjectId'],
          '执行状态': label(r['executionState'])
        },
        reauth: reauth,
        actions: [
          if (s.canWrite && r['state'] == 'PENDING') ...[
            DetailAction('批准', (ctx) async {
              final key = requestId();
              await formDialog(ctx,
                  title: '批准临时访问',
                  description: '批准只保存有期限的访问窗口，当前不会直接解锁设备。',
                  fields: const [
                    FieldSpec('seconds', '批准时长（秒，最多 3600）',
                        numeric: true, maxLength: 4)
                  ],
                  initial: {'seconds': r['requestedWindowSeconds']},
                  reauth: reauth,
                  onSubmit: (v) async => await s.api.send('POST',
                          '$root/access-requests/${r['id']}/decisions',
                          version: r['version'],
                          key: key,
                          body: {
                            'decision': 'APPROVE',
                            'grantedWindowSeconds': v['seconds']
                          }) as Json);
            }),
            DetailAction('拒绝', (ctx) async {
              final key = requestId();
              await formDialog(ctx,
                  title: '拒绝申请',
                  fields: const [
                    FieldSpec('reasonCode', '原因', options: {
                      'NOT_NOW': '当前不合适',
                      'NOT_ALLOWED': '不允许访问',
                      'OTHER': '其他原因'
                    })
                  ],
                  reauth: reauth,
                  onSubmit: (v) async => await s.api.send(
                      'POST', '$root/access-requests/${r['id']}/decisions',
                      version: r['version'],
                      key: key,
                      body: {'decision': 'DENY', ...v}) as Json);
            }, destructive: true)
          ],
          if (s.canWrite && r['state'] == 'APPROVED_PENDING_DELIVERY')
            DetailAction('撤销批准', (ctx) async {
              if (await confirmAction(ctx, '撤销批准', '撤销此访问窗口并记录审计。')) {
                await s.api.send(
                    'POST', '$root/access-requests/${r['id']}/revoke',
                    version: r['version'], key: requestId());
              }
            }, destructive: true)
        ]);
  }

  Future<void> invite() async {
    final children = await s.api.all('$root/subjects');
    if (!context.mounted) return;
    final result = await formDialog(context,
        title: '邀请成员',
        description: '邀请只适用于指定邮箱，令牌仅展示一次。儿童角色必须选择对应档案。',
        fields: [
          const FieldSpec('recipientEmail', '收件人邮箱', maxLength: 254),
          FieldSpec('role', '成员角色',
              options: options(s.tenant!['kind'] == 'FAMILY'
                  ? ['GUARDIAN', 'CHILD']
                  : ['ORG_ADMIN', 'TEACHER', 'AUDITOR', 'CHILD'])),
          FieldSpec('subjectId', '关联儿童（仅儿童角色）',
              required: false,
              options: {'': '不关联', ...entityOptions(children, 'nickname')})
        ],
        reauth: reauth, onSubmit: (v) async {
      if (v['role'] == 'CHILD' &&
          (v['subjectId'] == null || v['subjectId'] == '')) {
        throw const ApiFailure(400, 'CHILD_SUBJECT_REQUIRED');
      }
      return await s.api.send('POST', '$root/invitations', body: {
        'recipientEmail': v['recipientEmail'],
        'role': v['role'],
        if (v['role'] == 'CHILD') 'subjectId': v['subjectId']
      }) as Json;
    });
    if (result != null && context.mounted) {
      await showDetails(context, '邀请已创建', {
        '说明': '请将以下一次性令牌安全传递给收件人。系统尚未发送邮件。',
        '邀请令牌': result['token'],
        '过期时间': dateLabel(result['expiresAt'])
      }, actions: [
        TextButton.icon(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: result['token'])),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制令牌'))
      ]);
    }
  }

}

class MembersPage extends StatefulWidget {
  final Session session;
  final ConsoleActions actions;
  const MembersPage({super.key, required this.session, required this.actions});
  @override
  State<MembersPage> createState() => _MembersPageState();
}

class _MembersPageState extends State<MembersPage> {
  bool invitations = false;
  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final root = s.root;
    if (!s.canManage) return const Notice('当前角色无权查看成员管理。', warning: true);
    return ResourcePage(
        key: ValueKey(invitations),
        title: '成员与邀请',
        subtitle: '管理工作空间访问权限，邀请家庭成员或机构同事。',
        path: '$root/${invitations ? 'invitations' : 'members'}',
        api: s.api,
        reauth: widget.actions.reauth,
        create: widget.actions.invite,
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
                ColumnSpec('过期时间', (r) => Text(dateLabel(r['expiresAt'])))
              ]
            : [
                ColumnSpec(
                    '成员',
                    (r) => Text(r['actorId'] == s.profile?['subject']
                        ? '${s.displayName}（我）'
                        : shortId(r['actorId']))),
                ColumnSpec('角色', (r) => StatusTag(r['role'])),
                ColumnSpec('关联儿童', (r) => Text(shortId(r['subjectId'])))
              ],
        emptyTitle: invitations ? '暂无邀请记录' : '暂无成员',
        emptyDescription: invitations ? '新建邀请后可以在这里查看状态。' : '成员加入后将在这里显示。',
        onOpen: (r) => actionDetails(
                context,
                invitations ? '邀请详情' : '成员详情',
                invitations
                    ? {
                        '邀请编号': r['id'],
                        '角色': label(r['role']),
                        '状态': label(r['state']),
                        '过期时间': dateLabel(r['expiresAt'])
                      }
                    : {
                        '成员标识': r['actorId'],
                        '角色': label(r['role']),
                        '关联儿童': r['subjectId']
                      },
                reauth: widget.actions.reauth,
                actions: [
                  if (invitations && r['state'] == 'PENDING')
                    DetailAction('取消邀请', (ctx) async {
                      if (await confirmAction(ctx, '取消邀请', '取消后此邀请令牌将不再有效。')) {
                        await s.api
                            .send('DELETE', '$root/invitations/${r['id']}');
                      }
                    }, destructive: true),
                  if (!invitations && r['role'] != 'OWNER')
                    DetailAction('撤销访问', (ctx) async {
                      if (await confirmAction(
                          ctx, '撤销成员访问', '该成员将立即失去本工作空间的访问权限，相关临时访问窗口会失效。')) {
                        await s.api.send('DELETE',
                            '$root/members/${Uri.encodeComponent(r['actorId'])}');
                      }
                    }, destructive: true)
                ]));
  }
}

class SettingsPage extends StatelessWidget {
  final Session session;
  final ConsoleActions actions;
  const SettingsPage({super.key, required this.session, required this.actions});
  @override
  Widget build(BuildContext context) {
    final s = session;
    final tenant = Map<String, dynamic>.from(s.tenant!);
    final root = s.root;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PageHeading('设置', '管理工作空间资料、账号安全与连接信息。'),
      Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('工作空间',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 20),
        _setting('名称', s.tenant!['name']),
        _setting('类型', label(s.tenant!['kind'])),
        _setting('时区', s.tenant!['timeZone']),
        _setting('我的角色', label(s.role)),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 10, children: [
          if (s.canManage)
            OutlinedButton.icon(
                onPressed: () async {
                  final result = await formDialog(context,
                      title: '编辑工作空间',
                      fields: const [
                        FieldSpec('name', '名称'),
                        FieldSpec('timeZone', '时区')
                      ],
                      initial: tenant,
                      onSubmit: (v) async => await s.api.send('PATCH', root,
                          body: v, version: tenant['version']) as Json);
                  if (result != null) await s.loadTenants();
                },
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('编辑资料')),
          if (s.profile?['canCreateTenant'] == true)
            OutlinedButton(
                onPressed: actions.createTenant, child: const Text('新建工作空间')),
          TextButton(
              onPressed: actions.acceptInvitation, child: const Text('接受邀请'))
        ])
      ])),
      const SizedBox(height: 20),
      Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('账户安全',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        _setting('登录邮箱', s.profile?['email'] ?? s.displayName),
        const Notice('邀请成员、发布策略、设备退出等操作需要近期多因素认证。先在账户中心绑定验证器，再重新安全验证。'),
        const SizedBox(height: 18),
        Wrap(spacing: 12, runSpacing: 10, children: [
          OutlinedButton.icon(
              onPressed: s.account,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('账户与验证器')),
          FilledButton(
              onPressed: () => s.login(stepUp: true),
              child: const Text('重新安全验证')),
          TextButton(onPressed: s.logout, child: const Text('退出登录'))
        ])
      ])),
      const SizedBox(height: 20),
      const Panel(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('能力说明',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        SizedBox(height: 12),
        Text('管理端连接真实业务 API，配置与审计保存在数据库中。设备系统执行、第三方通知、支付及模型服务需完成相应接入后开放。',
            style: TextStyle(color: muted, height: 1.8))
      ]))
    ]);
  }

  Widget _setting(String key, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 110, child: Text(key, style: const TextStyle(color: muted))),
        Expanded(child: SelectableText(value))
      ]));
}

class Dashboard extends StatefulWidget {
  final Session session;
  final ConsoleActions actions;
  const Dashboard({super.key, required this.session, required this.actions});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  List<List<Json>>? data;
  Object? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      error = null;
      data = null;
    });
    try {
      final s = widget.session;
      final result = await Future.wait([
        'subjects',
        'devices',
        'policies',
        'access-requests',
        'audit-events'
      ].map((p) => s.api.all('${s.root}/$p')));
      if (mounted) setState(() => data = result);
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final wide = MediaQuery.sizeOf(context).width > 1150;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageHeading('工作台', '家庭设备与访问管理',
          action: s.canWrite
              ? FilledButton.icon(
                  onPressed: () async {
                    await widget.actions.subject();
                    if (mounted) load();
                  },
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加儿童'))
              : null),
      if (error != null)
        Panel(
            child: FailureView(error!,
                retry: load, reauth: () => s.login(stepUp: true)))
      else if (data == null)
        const Panel(
            child: SizedBox(
                height: 260,
                child:
                    Center(child: CircularProgressIndicator(strokeWidth: 2))))
      else ...[
        Panel(
            child: LayoutBuilder(
                builder: (ctx, box) =>
                    Wrap(spacing: 16, runSpacing: 24, children: [
                      _metric('儿童档案', data![0].length, Icons.person_outline,
                          box.maxWidth),
                      _metric(
                          '已注册设备',
                          data![1].where((r) => r['state'] == 'ACTIVE').length,
                          Icons.devices_outlined,
                          box.maxWidth),
                      _metric('策略草稿', data![2].length,
                          Icons.description_outlined, box.maxWidth),
                      _metric(
                          '待处理审批',
                          data![3].where((r) => r['state'] == 'PENDING').length,
                          Icons.schedule_outlined,
                          box.maxWidth)
                    ]))),
        const SizedBox(height: 24),
        Flex(
            direction: wide ? Axis.horizontal : Axis.vertical,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FlexibleIf(
                  wide: wide,
                  flex: 2,
                  child: Panel(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        const Text('开始管理',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 12),
                        _step('1', '创建儿童档案', '录入昵称和年龄段，建立专属档案。', '创建档案',
                            '/subjects'),
                        const Divider(),
                        _step('2', '连接第一台设备', '通过一次性凭据和配对码完成绑定。', '添加设备',
                            '/devices'),
                        const Divider(),
                        _step('3', '配置时间与规则', '设置使用时段，预览配置影响。', '创建策略',
                            '/policies')
                      ]))),
              SizedBox(width: wide ? 20 : 0, height: wide ? 0 : 20),
              FlexibleIf(
                  wide: wide,
                  flex: 1,
                  child: Panel(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        const Text('系统连接',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 22),
                        _connection('业务服务', '已连接', Icons.cloud_outlined, true),
                        const Divider(),
                        _connection(
                            '身份认证', '已连接', Icons.verified_user_outlined, true),
                        const Divider(),
                        _connection(
                            '策略执行', '尚未接入', Icons.settings_outlined, false)
                      ])))
            ]),
        const SizedBox(height: 24),
        Panel(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('最近活动',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton(
                onPressed: () => context.go('/audit'),
                child: const Text('查看全部'))
          ]),
          const SizedBox(height: 12),
          if (data![4].isEmpty)
            const EmptyView('暂无活动记录', '新的管理操作将在这里显示。')
          else
            ..._recent().map((r) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.receipt_long_outlined, color: muted),
                title: Text(label(r['action']),
                    style: const TextStyle(fontSize: 14)),
                subtitle: Text(shortId(r['resourceId']),
                    style: const TextStyle(fontSize: 12)),
                trailing: Text(dateLabel(r['occurredAt']),
                    style: const TextStyle(fontSize: 12, color: muted))))
        ])),
        const SizedBox(height: 16),
        Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
                onPressed: load,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('刷新数据')))
      ]
    ]);
  }

  List<Json> _recent() {
    final rows = [...data![4]];
    rows.sort(
        (a, b) => (b['occurredAt'] as num).compareTo(a['occurredAt'] as num));
    return rows.take(5).toList();
  }

  Widget _metric(String title, int value, IconData icon, double width) =>
      SizedBox(
          width: width > 700 ? (width - 48) / 4 : (width - 16) / 2,
          child: Row(children: [
            Icon(icon, color: muted, size: 28),
            const SizedBox(width: 14),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(color: muted, fontSize: 13)),
              const SizedBox(height: 10),
              Text('$value',
                  style: const TextStyle(
                      fontSize: 30, fontWeight: FontWeight.w700, color: ink))
            ])
          ]));
  Widget _step(
          String num, String title, String text, String button, String path) =>
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
                radius: 20,
                backgroundColor: const Color(0xFFEDF4FC),
                child: Text(num, style: const TextStyle(color: navy))),
            const SizedBox(width: 16),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text(text,
                      style: const TextStyle(
                          color: muted, fontSize: 12, height: 1.6)),
                  if (MediaQuery.sizeOf(context).width < 650)
                    TextButton(
                        onPressed: () => context.go(path), child: Text(button))
                ])),
            if (MediaQuery.sizeOf(context).width >= 650)
              OutlinedButton(
                  onPressed: () => context.go(path), child: Text(button))
          ]));
  Widget _connection(String name, String state, IconData icon, bool ok) =>
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: Row(children: [
            Icon(icon, color: muted, size: 24),
            const SizedBox(width: 14),
            Expanded(child: Text(name)),
            Icon(Icons.circle,
                size: 8,
                color: ok ? const Color(0xFF00886C) : const Color(0xFFD49522)),
            const SizedBox(width: 6),
            Text(state,
                style: TextStyle(
                    color: ok ? const Color(0xFF00886C) : muted, fontSize: 12))
          ]));
}

class FlexibleIf extends StatelessWidget {
  final bool wide;
  final int flex;
  final Widget child;
  const FlexibleIf(
      {super.key, required this.wide, required this.flex, required this.child});
  @override
  Widget build(BuildContext context) => wide
      ? Expanded(flex: flex, child: child)
      : SizedBox(width: double.infinity, child: child);
}
