import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/dialog_access.dart';
import '../ui/owned_dialog_route.dart';
import '../ui/quota_balance.dart';
import '../ui/resource_page.dart';
import '../ui/view_lifetime.dart';
import 'device_subflow_scope.dart';
import 'editors.dart';
import 'quota_plan_editor.dart';

class QuotaPlansPage extends StatefulWidget {
  final Session session;
  final bool Function() parentCurrent;
  final Listenable accessChanges;
  const QuotaPlansPage({
    super.key,
    required this.session,
    required this.parentCurrent,
    required this.accessChanges,
  });
  @override
  State<QuotaPlansPage> createState() => _QuotaPlansPageState();
}

class _QuotaPlansPageState extends State<QuotaPlansPage> {
  final lifetime = ViewLifetime();
  late final Session owner;
  late final String root;
  late final DeviceSubflowScope scope;
  late final bool Function() parentCurrent;
  late final Listenable parentChanges, changes;
  Map<String, String> children = {}, applications = {};

  bool get current => mounted && lifetime.active && scope.current;
  bool get canWrite => current && owner.canWrite;
  bool onTop(BuildContext parent) => current && parent.mounted &&
      ModalRoute.of(parent)?.isCurrent == true;

  @override
  void initState() {
    super.initState();
    owner = widget.session;
    root = owner.tenant == null ? '' : owner.root;
    parentCurrent = widget.parentCurrent;
    parentChanges = widget.accessChanges;
    scope = DeviceSubflowScope(owner,
        permitted: () => mounted && lifetime.active &&
            identical(widget.session, owner) && parentCurrent() &&
            owner.tenant != null && owner.root == root &&
            owner.canOpen('quota'));
    changes = Listenable.merge([scope, lifetime.changes, parentChanges]);
    loadLabels();
  }

  @override
  void didUpdateWidget(covariant QuotaPlansPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.session, owner) ||
        !identical(widget.accessChanges, parentChanges)) {
      lifetime.invalidate();
    }
  }

  @override
  void deactivate() {
    lifetime.invalidate();
    super.deactivate();
  }

  @override
  void dispose() {
    lifetime.dispose();
    scope.dispose();
    super.dispose();
  }

  Future<void> loadLabels() async {
    if (!current) return;
    Future<Map<String, String>> labels(String path, String field) async {
      try {
        return entityOptions(await scope.api.all('$root/$path'), field);
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
    if (!current) return;
    setState(() {
      children = values[0];
      applications = values[1];
    });
  }

  String childLabel(Json plan) =>
      children[plan['subjectId']] ?? '儿童 ${plan['subjectId']}';
  String scopeLabel(Json plan) => plan['scope'] == 'TOTAL'
      ? '儿童总额度'
      : applications[plan['applicationId']] ?? '应用 ${plan['applicationId']}';
  String targetDescription(Json plan) =>
      '儿童：${childLabel(plan)}\n额度范围：${scopeLabel(plan)}';

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: changes,
        builder: (_, __) => !current
            ? const Panel(
                child: EmptyView(
                    '工作空间或权限已变化', '已隐藏原计划，请重新打开当前工作空间的额度页面。'))
            : ResourcePage(
        key: ValueKey((owner, scope.actorId, scope.tenantId,
            scope.role, scope.generation)),
        api: scope.api,
        isCurrent: () => current,
        canInteract: () => onTop(context),
        path: '$root/quota-plans',
        title: '重复计划',
        subtitle: '按星期安排额度，日期例外单独设置，每天自动生成。',
        createLabel: '创建重复计划',
        create: canWrite ? () => edit(context) : null,
        reauth: () {
          if (onTop(context)) owner.login(stepUp: true);
        },
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
        onOpen: (r) => details(context, r['id'])));
  }

  Future<void> edit(BuildContext parent, {Json? plan}) async {
    if (!onTop(parent) || !canWrite) return;
    final access = DialogAccessBinding(parent,
        accessChanges: changes, hasAccess: () => canWrite);
    try {
      if (!access.permitted()) return;
      final api = scope.api.scoped(access.permitted);
      final defaultZone = plan?['timeZone'] as String? ??
          owner.tenant?['timeZone'] as String? ?? 'Asia/Shanghai';
      final key = requestId();
      final version = plan?['version'] as int?;
      final path = plan == null
          ? '$root/quota-plans' : '$root/quota-plans/${plan['id']}';
      final children = plan == null
          ? await api.all('$root/subjects') : <Json>[];
      if (!onTop(parent) || !access.permitted()) return;
      if (plan == null && children.isEmpty) {
        toast(parent, '请先添加儿童档案。');
        return;
      }
      final apps = plan == null
          ? await api.all('$root/applications') : <Json>[];
      if (!onTop(parent) || !access.permitted()) return;
      late final OwnedDialogRoute<void> route;
      bool accepted() => canWrite && access.permitted() &&
          route.available && route.isActive;
      final editorApi = api.scoped(accepted);
      final editorChanges = access.changes;
      route = OwnedDialogRoute<void>(
          context: parent,
          barrierDismissible: false,
          builder: (_) => QuotaPlanEditor(
              children: entityOptions(children, 'nickname'),
              applications: entityOptions(apps, 'displayName'),
              plan: plan,
              targetDescription: plan == null ? null : targetDescription(plan),
              accessChanges: editorChanges,
              hasAccess: accepted,
              loadCalendar: (subject) async {
                if (!accepted()) {
                  throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                }
                return await editorApi.send('GET',
                    '$root/quota-plans/calendar?subjectId=${Uri.encodeQueryComponent(subject)}&defaultTimeZone=${Uri.encodeQueryComponent(defaultZone)}') as Json;
              },
              reauth: () {
                if (accepted() && route.isCurrent) owner.login(stepUp: true);
              },
              onSubmit: (body) async {
                if (!accepted()) {
                  throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                }
                await editorApi.send(plan == null ? 'POST' : 'PUT', path,
                    key: key, version: version, body: body);
              }));
      await presentOwnedDialog<void>(parent, route);
    } finally {
      access.dispose();
    }
  }

  Future<void> details(BuildContext parent, String id) async {
    if (!onTop(parent)) return;
    final access = DialogAccessBinding(parent,
        accessChanges: changes, hasAccess: () => current);
    try {
      if (!access.permitted()) return;
      final api = scope.api.scoped(access.permitted);
      final plan = await api.send('GET', '$root/quota-plans/$id') as Json;
      if (!onTop(parent) || !access.permitted()) return;
      final overrides = Map<String, dynamic>.from(plan['dateOverrides'] as Map);
      final detailChanges = access.changes;
      var requestedEdit = false;
      await scopedDetailsDialog(parent, plan['name'], {
        '最新保存': '第 ${(plan['version'] as num).toInt() + 1} 版 · 从 ${plan['effectiveFrom']} 生效',
        '额度目标': targetDescription(plan),
        '时区': plan['timeZone'],
      },
          accessChanges: detailChanges,
          hasAccess: () => current && access.permitted(),
          reauth: () {
            if (current && access.permitted()) owner.login(stepUp: true);
          },
          extraContent: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),
                Notice(plan['state'] == 'PAUSED'
                    ? '该配置生效后暂停自动生成。已有每日额度保留；如需改变今天的额度，请到每日账本调整。'
                    : '每天按下列设置生成额度。已有每日额度不会重复生成或覆盖，日期例外优先于星期规则。'),
                const SizedBox(height: 20),
                for (final day in quotaWeek.entries)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Row(children: [
                        Expanded(child: Text(day.value)),
                        Text(quotaDuration((plan['weeklyLimits'] as Map)[day.key]),
                            style: const TextStyle(fontWeight: FontWeight.w600))
                      ])),
                const SizedBox(height: 18),
                const Text('日期例外',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                if (overrides.isEmpty)
                  const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('暂无例外', style: TextStyle(color: muted))),
                for (final date in (overrides.keys.toList()..sort()))
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('$date · ${quotaDuration(overrides[date])}')),
              ]),
          actions: [
            DetailAction('版本历史', (dialog) async {
              final route = ModalRoute.of(dialog);
              if (!current || !access.permitted() ||
                  route is! OwnedDialogRoute<void> ||
                  !route.available || !route.isCurrent) return;
              await history(dialog, plan);
            }, closeOnSuccess: false),
            if (canWrite)
              DetailAction('修改计划', (dialog) async {
                final route = ModalRoute.of(dialog);
                if (!canWrite || !access.permitted() ||
                    route is! OwnedDialogRoute<void> ||
                    !route.available || !route.isCurrent) return;
                requestedEdit = true;
                route.finish();
              }, closeOnSuccess: false),
          ]);
      if (requestedEdit && onTop(parent) && canWrite && access.permitted()) {
        await edit(parent, plan: plan);
      }
    } finally {
      access.dispose();
    }
  }

  Future<void> history(BuildContext parent, Json plan) async {
    if (!onTop(parent)) return;
    final access = DialogAccessBinding(parent,
        accessChanges: changes, hasAccess: () => current);
    try {
      if (!access.permitted()) return;
      late final OwnedDialogRoute<void> route;
      bool accepted() => current && access.permitted() &&
          route.available && route.isActive;
      void closeCurrent() {
        if (route.available && route.isCurrent) route.finish();
      }
      final api = scope.api.scoped(accepted);
      final historyChanges = access.changes;
      route = OwnedDialogRoute<void>(
          context: parent,
          builder: (_) => AnimatedBuilder(
              animation: historyChanges,
              builder: (_, __) => !accepted()
                  ? AlertDialog(
                      title: const Text('工作空间或权限已变化'),
                      content: const Text('已隐藏原计划版本，请关闭窗口后重新打开。'),
                      actions: [
                        TextButton(onPressed: closeCurrent,
                            child: const Text('关闭'))
                      ])
                  : Dialog(
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 920),
                          child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                        child: SingleChildScrollView(
                                            child: ResourcePage(
                                                api: api,
                                                isCurrent: accepted,
                                                canInteract: () => route.isCurrent,
                                                path: '$root/quota-plans/${plan['id']}/revisions',
                                                title: '计划版本历史',
                                                subtitle: plan['name'],
                                                emptyTitle: '暂无版本',
                                                emptyDescription: '计划修改后可在这里查看历史配置。',
                                                reauth: () {
                                                  if (accepted() && route.isCurrent) {
                                                    owner.login(stepUp: true);
                                                  }
                                                },
                                                columns: [
                                                  ColumnSpec('版本', (r) => Text('第 ${(r['version'] as num).toInt() + 1} 版')),
                                                  ColumnSpec('生效日期', (r) => Text(r['effectiveFrom'])),
                                                  ColumnSpec('配置', (r) => Text(r['configuration']['state'] == 'ACTIVE' ? '自动生成' : '暂停生成')),
                                                  ColumnSpec('周一 / 周六', (r) => Text('${quotaDuration(r['configuration']['weeklyLimits']['MONDAY'])} / ${quotaDuration(r['configuration']['weeklyLimits']['SATURDAY'])}')),
                                                ]))),
                                    Align(
                                        alignment: Alignment.centerRight,
                                        child: TextButton(
                                            onPressed: closeCurrent,
                                            child: const Text('关闭'))),
                                  ]))))));
      await presentOwnedDialog<void>(parent, route);
    } finally {
      access.dispose();
    }
  }
}
