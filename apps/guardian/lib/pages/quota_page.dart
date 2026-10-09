import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/local_date.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/resource_page.dart';
import '../ui/quota_balance.dart';
import 'editors.dart';
import 'quota_plans_page.dart';

/// Every form captures its workspace and resource version before asynchronous work.
class QuotaPage extends StatefulWidget {
  final Session session;
  const QuotaPage({super.key, required this.session});
  @override
  State<QuotaPage> createState() => _QuotaPageState();
}

class _QuotaPageState extends State<QuotaPage> {
  Session get session => widget.session;
  bool showPlans = false;

  @override
  Widget build(BuildContext context) {
    final root = session.root;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
                value: false,
                label: Text('每日账本'),
                icon: Icon(Icons.today_outlined)),
            ButtonSegment(
                value: true,
                label: Text('重复计划'),
                icon: Icon(Icons.event_repeat_outlined)),
          ],
          selected: {
            showPlans
          },
          onSelectionChanged: (value) =>
              setState(() => showPlans = value.single)),
      const SizedBox(height: 24),
      if (showPlans)
        QuotaPlansPage(key: ValueKey(root), session: session)
      else
        ResourcePage(
          key: ValueKey(root),
          api: session.api,
          path: '$root/quota-pools',
          title: '共享额度',
          subtitle: '按儿童与日期规划总额度，查看跨设备预留和结算。',
          createLabel: '创建每日额度',
          create: session.canWrite ? () => create(context, root) : null,
          reauth: () => session.login(stepUp: true),
          notice: '已结算、预留和可分配余额分别记录。设备尚未完成计时与停止能力验证时，不发放硬额度租约；配置额度不代表设备已经受到限制。',
          emptyTitle: '还没有每日额度',
          emptyDescription: '先为儿童设置当天的总额度，再按需添加应用额度。总额度与应用额度共同约束使用。',
          columns: [
            ColumnSpec(
                '额度计划',
                (r) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(r['name'],
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          Text('${r['periodId']} · ${r['timeZone']}',
                              style:
                                  const TextStyle(color: muted, fontSize: 12)),
                        ])),
            ColumnSpec(
                '范围', (r) => Text(r['scope'] == 'TOTAL' ? '儿童总额度' : '指定应用')),
            ColumnSpec(
                '来源',
                (r) => Text(r['planId'] == null
                    ? '手工设置'
                    : '重复计划 · 第 ${(r['planVersion'] as num).toInt() + 1} 版')),
            ColumnSpec('已结算', (r) => Text(quotaDuration(r['usedSeconds']))),
            ColumnSpec(
                '待确认预留', (r) => Text(quotaDuration(r['reservedSeconds']))),
            ColumnSpec(
                '可分配',
                (r) => Text(quotaDuration(r['availableSeconds']),
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, color: navy))),
          ],
          onOpen: (r) => details(context, root, r['id']),
        )
    ]);
  }

  Future<void> create(BuildContext context, String root) async {
    final zone = session.tenant?['timeZone'] as String? ?? 'Asia/Shanghai';
    final children = await session.api.all('$root/subjects');
    if (!context.mounted) return;
    if (children.isEmpty) {
      toast(context, '请先添加儿童档案。');
      return;
    }
    final apps = await session.api.all('$root/applications');
    if (!context.mounted) return;
    final key = requestId();
    await formDialog(context,
        title: '创建每日额度',
        description:
            '每个日期、儿童和应用范围只能创建一份额度。日期按下方时区计算；同一儿童的额度时区保持一致，避免切换时区重置余额。保存需要近期多因素认证。',
        reauth: () => session.login(stepUp: true),
        fields: [
          const FieldSpec('name', '计划名称'),
          FieldSpec('subjectId', '儿童',
              options: entityOptions(children, 'nickname')),
          FieldSpec('applicationId', '额度范围',
              options: {
                '': '总额度 · 所有适用应用',
                ...entityOptions(apps, 'displayName')
              },
              required: false),
          const FieldSpec('periodId', '当地日期',
              hint: 'YYYY-MM-DD', maxLength: 10),
          const FieldSpec('timeZone', '额度时区', hint: 'Asia/Shanghai'),
          const FieldSpec('minutes', '额度（分钟，0–1440）',
              numeric: true, maxLength: 4),
        ],
        initial: {
          'name': '每日使用额度',
          'applicationId': '',
          'periodId': localDateInZone(DateTime.now(), zone),
          'timeZone': zone,
          'minutes': 60
        },
        onSubmit: (v) async {
          final minutes = v['minutes'] as int;
          if (minutes > 1440) {
            throw const ApiFailure(400, 'QUOTA_LIMIT_INVALID');
          }
          final date = DateTime.tryParse(v['periodId']);
          if (date == null ||
              DateFormat('yyyy-MM-dd').format(date) != v['periodId']) {
            throw const ApiFailure(400, 'INVALID_QUOTA_PERIOD');
          }
          final app = v['applicationId'] as String?;
          return await session.api
              .send('POST', '$root/quota-pools', key: key, body: {
            'name': v['name'],
            'subjectId': v['subjectId'],
            'scope': app == null || app.isEmpty ? 'TOTAL' : 'APPLICATION',
            if (app != null && app.isNotEmpty) 'applicationId': app,
            'periodId': v['periodId'],
            'timeZone': v['timeZone'],
            'limitSeconds': minutes * 60,
          }) as Json;
        });
  }

  Future<void> details(BuildContext context, String root, String id) async {
    final pool = await session.api.send('GET', '$root/quota-pools/$id') as Json;
    if (!context.mounted) return;
    final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(pool['name']),
                content: SizedBox(
                    width: 620,
                    child: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text('${pool['periodId']} · ${pool['timeZone']}',
                              style: const TextStyle(color: muted)),
                          const SizedBox(height: 24),
                          QuotaBalance(pool: pool),
                          const SizedBox(height: 24),
                          if ((pool['reservedSeconds'] as num) > 0)
                            const Notice(
                                '部分额度正在等待设备结算。离线或租约超时不会自动返还，以免重复分配已经消费的时间。'),
                          const SizedBox(height: 12),
                          Text(
                              '周期：${dateLabel(pool['periodStart'])} — ${dateLabel(pool['periodEnd'])}\n以上时间按当前浏览器当地时区显示。',
                              style:
                                  const TextStyle(color: muted, height: 1.7)),
                          const SizedBox(height: 12),
                          const Notice('此页面展示服务端账本。设备实际停止行为需以经验证的执行能力和设备证据为准。'),
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, 'ledger'),
                      child: const Text('查看账本')),
                  if (session.canWrite &&
                      DateTime.fromMillisecondsSinceEpoch(pool['periodEnd'])
                          .isAfter(DateTime.now()))
                    OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, 'adjust'),
                        child: const Text('调整额度')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('关闭')),
                ]));
    if (!context.mounted) return;
    if (action == 'ledger') {
      await ledger(context, root, pool);
    } else if (action == 'adjust') {
      await adjust(context, root, pool);
    }
  }

  Future<void> adjust(BuildContext context, String root, Json pool) async {
    final key = requestId();
    await formDialog(context,
        title: '调整当日额度',
        description: '增加时间与减少额度均记入账本。减少后的总额度不能低于已结算与待确认预留之和，需要近期多因素认证。',
        reauth: () => session.login(stepUp: true),
        fields: const [
          FieldSpec('direction', '调整方式',
              options: {'ADD': '追加使用时间', 'SUBTRACT': '减少额度'}),
          FieldSpec('minutes', '调整分钟数（1–1440）', numeric: true, maxLength: 4)
        ],
        initial: {'direction': 'ADD', 'minutes': 15},
        onSubmit: (v) async {
          final minutes = v['minutes'] as int;
          if (minutes < 1 || minutes > 1440) {
            throw const ApiFailure(400, 'QUOTA_LIMIT_INVALID');
          }
          final add = v['direction'] == 'ADD';
          return await session.api.send(
              'POST', '$root/quota-pools/${pool['id']}/adjustments',
              key: key,
              version: pool['version'],
              body: {
                'deltaSeconds': minutes * 60 * (add ? 1 : -1),
                'reason': add ? 'EXTRA_TIME' : 'CORRECTION',
              }) as Json;
        });
  }

  Future<void> ledger(BuildContext context, String root, Json pool) =>
      showDialog<void>(
          context: context,
          builder: (ctx) => Dialog(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(
                            child: SingleChildScrollView(
                                child: ResourcePage(
                                    api: session.api,
                                    path:
                                        '$root/quota-pools/${pool['id']}/ledger',
                                    title: '额度账本',
                                    subtitle:
                                        '${pool['name']} · ${pool['periodId']}',
                                    emptyTitle: '暂无账本记录',
                                    emptyDescription: '额度创建、调整、预留和结算都会在这里留下记录。',
                                    columns: [
                              ColumnSpec('发生时间',
                                  (r) => Text(dateLabel(r['occurredAt']))),
                              ColumnSpec(
                                  '操作', (r) => Text(quotaKind(r['kind']))),
                              ColumnSpec('总额度变化',
                                  (r) => Text(quotaDelta(r['limitDelta']))),
                              ColumnSpec('结算变化',
                                  (r) => Text(quotaDelta(r['usedDelta']))),
                              ColumnSpec('预留变化',
                                  (r) => Text(quotaDelta(r['reservedDelta']))),
                            ]))),
                        Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('关闭'))),
                      ])),
                ),
              ));
}
