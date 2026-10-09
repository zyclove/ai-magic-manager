import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/quota_balance.dart';
import '../ui/resource_page.dart';
import 'editors.dart';
import 'quota_plan_editor.dart';

class QuotaPlansPage extends StatefulWidget {
  final Session session;
  const QuotaPlansPage({super.key, required this.session});
  @override
  State<QuotaPlansPage> createState() => _QuotaPlansPageState();
}

class _QuotaPlansPageState extends State<QuotaPlansPage> {
  Session get session => widget.session;
  Map<String, String> children = {}, applications = {};

  @override
  void initState() {
    super.initState();
    loadLabels();
  }

  Future<void> loadLabels() async {
    final root = session.root;
    Future<Map<String, String>> labels(String path, String field) async {
      try {
        return entityOptions(await session.api.all('$root/$path'), field);
      } catch (_) {
        // Optional display metadata may be unavailable to a read-only role.
        // The scoped plan still exposes its exact target identifier below.
        return {};
      }
    }

    final values = await Future.wait([
      labels('subjects', 'nickname'),
      labels('applications', 'displayName')
    ]);
    if (mounted && session.root == root) {
      setState(() {
        children = values[0];
        applications = values[1];
      });
    }
  }

  String childLabel(Json plan) =>
      children[plan['subjectId']] ?? '儿童 ${plan['subjectId']}';
  String scopeLabel(Json plan) => plan['scope'] == 'TOTAL'
      ? '儿童总额度'
      : applications[plan['applicationId']] ?? '应用 ${plan['applicationId']}';
  String targetDescription(Json plan) =>
      '儿童：${childLabel(plan)}\n额度范围：${scopeLabel(plan)}';

  Future<Json> calendar(
          String root, String subject, String defaultZone) async =>
      await session.api.send('GET',
              '$root/quota-plans/calendar?subjectId=${Uri.encodeQueryComponent(subject)}&defaultTimeZone=${Uri.encodeQueryComponent(defaultZone)}')
          as Json;
  @override
  Widget build(BuildContext context) {
    final root = session.root;
    return ResourcePage(
        key: ValueKey(root),
        api: session.api,
        path: '$root/quota-plans',
        title: '重复计划',
        subtitle: '按星期安排额度，日期例外单独设置，每天自动生成。',
        createLabel: '创建重复计划',
        create: session.canWrite ? () => edit(context, root) : null,
        reauth: () => session.login(stepUp: true),
        notice:
            '计划修改或暂停从次日生效。已经生成的每日额度保留，已结算和待确认预留不会被重置。设备执行能力尚未验证时，额度配置不会被标为已执行。',
        emptyTitle: '还没有重复计划',
        emptyDescription: '为儿童创建总额度计划，再按需添加应用计划，免去每天手工配置。',
        columns: [
          ColumnSpec(
              '计划',
              (r) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(r['name'],
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        Text(r['timeZone'],
                            style: const TextStyle(color: muted, fontSize: 12))
                      ])),
          ColumnSpec('儿童', (r) => Text(childLabel(r))),
          ColumnSpec('范围', (r) => Text(scopeLabel(r))),
          ColumnSpec(
              '最新配置', (r) => Text(r['state'] == 'ACTIVE' ? '自动生成' : '暂停生成')),
          ColumnSpec('配置生效日', (r) => Text(r['effectiveFrom'])),
          ColumnSpec(
              '配置版本', (r) => Text('第 ${(r['version'] as num).toInt() + 1} 版')),
        ],
        onOpen: (r) => details(context, root, r['id']));
  }

  Future<void> edit(BuildContext context, String root, {Json? plan}) async {
    final defaultZone = plan?['timeZone'] as String? ??
        session.tenant?['timeZone'] as String? ??
        'Asia/Shanghai';
    final key = requestId();
    final children =
        plan == null ? await session.api.all('$root/subjects') : <Json>[];
    if (!context.mounted) return;
    if (plan == null && children.isEmpty) {
      toast(context, '请先添加儿童档案。');
      return;
    }
    final apps =
        plan == null ? await session.api.all('$root/applications') : <Json>[];
    if (!context.mounted) return;
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => QuotaPlanEditor(
            children: entityOptions(children, 'nickname'),
            applications: entityOptions(apps, 'displayName'),
            plan: plan,
            targetDescription: plan == null ? null : targetDescription(plan),
            loadCalendar: (subject) => calendar(root, subject, defaultZone),
            reauth: () => session.login(stepUp: true),
            onSubmit: (body) async {
              await session.api.send(
                  plan == null ? 'POST' : 'PUT',
                  plan == null
                      ? '$root/quota-plans'
                      : '$root/quota-plans/${plan['id']}',
                  key: key,
                  version: plan?['version'],
                  body: body);
            }));
  }

  Future<void> details(BuildContext context, String root, String id) async {
    final plan = await session.api.send('GET', '$root/quota-plans/$id') as Json;
    if (!context.mounted) return;
    final overrides = Map<String, dynamic>.from(plan['dateOverrides'] as Map);
    final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(plan['name']),
                content: SizedBox(
                    width: 620,
                    child: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(
                              '最新保存：第 ${(plan['version'] as num).toInt() + 1} 版 · 从 ${plan['effectiveFrom']} 生效',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          Text(targetDescription(plan),
                              style: const TextStyle(height: 1.6)),
                          const SizedBox(height: 8),
                          Text('时区：${plan['timeZone']}',
                              style: const TextStyle(color: muted)),
                          const SizedBox(height: 16),
                          Notice(plan['state'] == 'PAUSED'
                              ? '该配置生效后暂停自动生成。已有每日额度保留；如需改变今天的额度，请到每日账本调整。'
                              : '每天按下列设置生成额度。已有每日额度不会重复生成或覆盖，日期例外优先于星期规则。'),
                          const SizedBox(height: 20),
                          for (final day in quotaWeek.entries)
                            Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 7),
                                child: Row(children: [
                                  Expanded(child: Text(day.value)),
                                  Text(
                                      quotaDuration((plan['weeklyLimits']
                                          as Map)[day.key]),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600))
                                ])),
                          const SizedBox(height: 18),
                          const Text('日期例外',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          if (overrides.isEmpty)
                            const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text('暂无例外',
                                    style: TextStyle(color: muted))),
                          for (final date in (overrides.keys.toList()..sort()))
                            Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                    '$date · ${quotaDuration(overrides[date])}')),
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, 'history'),
                      child: const Text('版本历史')),
                  if (session.canWrite)
                    OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, 'edit'),
                        child: const Text('修改计划')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('关闭')),
                ]));
    if (!context.mounted) return;
    if (action == 'edit') {
      await edit(context, root, plan: plan);
    } else if (action == 'history') {
      await history(context, root, plan);
    }
  }

  Future<void> history(BuildContext context, String root, Json plan) =>
      showDialog<void>(
          context: context,
          builder: (ctx) => Dialog(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(
                            child: SingleChildScrollView(
                                child: ResourcePage(
                                    api: session.api,
                                    path:
                                        '$root/quota-plans/${plan['id']}/revisions',
                                    title: '计划版本历史',
                                    subtitle: plan['name'],
                                    emptyTitle: '暂无版本',
                                    emptyDescription: '计划修改后可在这里查看历史配置。',
                                    columns: [
                              ColumnSpec(
                                  '版本',
                                  (r) => Text(
                                      '第 ${(r['version'] as num).toInt() + 1} 版')),
                              ColumnSpec(
                                  '生效日期', (r) => Text(r['effectiveFrom'])),
                              ColumnSpec(
                                  '配置',
                                  (r) => Text(
                                      r['configuration']['state'] == 'ACTIVE'
                                          ? '自动生成'
                                          : '暂停生成')),
                              ColumnSpec(
                                  '周一 / 周六',
                                  (r) => Text(
                                      '${quotaDuration(r['configuration']['weeklyLimits']['MONDAY'])} / ${quotaDuration(r['configuration']['weeklyLimits']['SATURDAY'])}')),
                            ]))),
                        Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('关闭'))),
                      ])))));
}
