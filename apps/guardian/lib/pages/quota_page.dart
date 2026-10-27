import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../core/api.dart';
import '../core/labels.dart';
import '../core/local_date.dart';
import '../core/quota_pool_change.dart';
import '../core/session.dart';
import '../ui/design.dart';
import '../ui/dialog_access.dart';
import '../ui/owned_dialog_route.dart';
import '../ui/view_lifetime.dart';
import '../ui/resource_page.dart';
import '../ui/quota_balance.dart';
import 'editors.dart';
import 'quota_plans_page.dart';
import 'device_subflow_scope.dart';

/// Every form captures its workspace and resource version before asynchronous work.
class QuotaPage extends StatefulWidget {
  final Session session;
  const QuotaPage({super.key, required this.session});
  @override
  State<QuotaPage> createState() => _QuotaPageState();
}

class _QuotaPageState extends State<QuotaPage> {
  late final Session session;
  late final String ownerRoot;
  late final DeviceSubflowScope pageScope;
  final lifetime = ViewLifetime();
  late final Listenable changes;
  bool showPlans = false;
  int viewGeneration = 0;

  bool permitted() => mounted && lifetime.active &&
      identical(widget.session, session) && session.tenant != null &&
      session.root == ownerRoot && session.canOpen('quota');
  bool current() => mounted && lifetime.active && pageScope.current;
  bool interactive(BuildContext target) {
    if (!current() || !target.mounted) return false;
    final route = ModalRoute.of(target);
    return route?.isActive == true && route?.isCurrent == true &&
        (route is! OwnedDialogRoute<dynamic> || route.available);
  }

  void rejectPrivateAccess(Object failure, {ResourceActionLease? lease}) {
    if (!current() || lease?.current == false || failure is! ApiFailure) return;
    if (failure.status != 403 && failure.code != 'WORKSPACE_CHANGED' &&
        (failure.status != 401 || failure.code == 'REAUTH_REQUIRED')) return;
    lease?.retire();
    lifetime.invalidate();
  }

  Future<T> request<T>(ResourceActionLease lease, Future<T> Function() send) async {
    if (!current() || !lease.current) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    try {
      return await send();
    } catch (failure) {
      rejectPrivateAccess(failure, lease: lease);
      rethrow;
    }
  }

  bool includePoolRow(Json row) {
    readQuotaPoolSnapshot(row);
    return true;
  }

  bool includeLedgerRow(Json row) {
    readQuotaLedgerEntry(row);
    return true;
  }

  @override
  void initState() {
    super.initState();
    session = widget.session;
    ownerRoot = session.tenant == null ? '' : session.root;
    pageScope = DeviceSubflowScope(session, permitted: permitted);
    changes = Listenable.merge([pageScope, lifetime.changes]);
  }

  @override
  void didUpdateWidget(QuotaPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) lifetime.invalidate();
  }

  @override
  void deactivate() {
    lifetime.invalidate();
    super.deactivate();
  }

  @override
  void dispose() {
    lifetime.dispose();
    pageScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: changes,
      builder: (_, __) => current()
          ? content(context)
          : const Panel(child: EmptyView('工作空间或权限已变化',
              '已隐藏旧额度资料，请在当前工作空间重新打开额度管理。')));

  Widget content(BuildContext context) {
    final root = ownerRoot;
    final generation = viewGeneration;
    bool viewCurrent() => current() && viewGeneration == generation;
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
          onSelectionChanged: (value) {
            if (value.length == 1 && value.single != showPlans &&
                viewCurrent() && interactive(context)) {
              setState(() {
                viewGeneration++;
                showPlans = value.single;
              });
            }
          }),
      const SizedBox(height: 24),
      if (showPlans)
        QuotaPlansPage(
            key: ValueKey((root, pageScope, generation)), session: session,
            parentCurrent: viewCurrent, accessChanges: changes)
      else
        ResourcePage(
          key: ValueKey((root, pageScope, generation)),
          api: pageScope.api,
          isCurrent: viewCurrent,
          canInteract: () => viewCurrent() && interactive(context),
          path: '$root/quota-pools',
          includeRow: includePoolRow,
          onReadDenied: (failure) {
            if (viewCurrent()) rejectPrivateAccess(failure);
          },
          title: '共享额度',
          subtitle: '按儿童与日期规划总额度，查看跨设备预留和结算。',
          createLabel: '创建每日额度',
          onCreateChanged: session.canWrite
              ? (lease) => create(context, root, lease) : null,
          reauth: () {
            if (viewCurrent() && interactive(context)) session.login(stepUp: true);
          },
          notice: '已结算、预留和可分配余额分别记录。设备尚未完成计时与停止能力验证时，不发放硬额度租约；配置额度不代表设备已经受到限制。',
          emptyTitle: '还没有每日额度',
          emptyDescription: session.canWrite
              ? '先为儿童设置当天的总额度，再按需添加应用额度。总额度与应用额度共同约束使用。'
              : '当前范围内没有可查看的每日额度。',
          columns: [
            ColumnSpec(
                '每日额度',
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
          onOpenChanged: (r, lease) => details(context, root, r['id'], lease),
        )
    ]);
  }

  Future<bool> create(BuildContext context, String root, ResourceActionLease lease) async {
    if (!interactive(context) || root != ownerRoot ||
        !session.canWrite || !lease.current) return false;
    var attempted = false;
    String? reviewNotice;
    final s = session;
    final access = DialogAccessBinding(context,
        accessChanges: Listenable.merge([changes, lease]),
        hasAccess: () => current() && lease.current);
    final scope = DeviceSubflowScope(s,
        permitted: () => current() && access.permitted() &&
            context.mounted && identical(session, s) &&
            s.tenant != null && s.root == root && s.canWrite);
    try {
      if (!scope.current) return false;
      final zone = s.tenant?['timeZone'] as String? ?? 'Asia/Shanghai';
      final children = await request(lease, () => scope.api.all('$root/subjects'));
      if (!context.mounted) return false;
      if (!scope.current || !interactive(context)) return false;
      if (children.isEmpty) {
        toast(context, '请先添加儿童档案。');
        return false;
      }
      final apps = await request(lease, () => scope.api.all('$root/applications'));
      if (!context.mounted) return false;
      if (!scope.current || !interactive(context)) return false;
      final key = const Uuid().v4();
      final result = await formDialog(context,
          title: '创建每日额度',
          accessChanges: access.changes,
          hasAccess: () => scope.current,
          description:
              '每个日期、儿童和应用范围只能创建一份额度。日期按下方时区计算；同一儿童的额度时区保持一致，避免切换时区重置余额。保存需要近期多因素认证。',
          reauth: () {
            if (scope.current) s.login(stepUp: true);
          },
          fields: [
            const FieldSpec('name', '额度名称'),
            FieldSpec('subjectId', '儿童',
                options: entityOptions(children, 'nickname')),
            FieldSpec('applicationId', '额度范围',
                options: {
                  '': '总额度 · 所有适用应用',
                  ...entityOptions(apps, 'displayName')
                },
                required: false),
            FieldSpec('periodId', '当地日期', hint: 'YYYY-MM-DD', maxLength: 10,
                validator: quotaPoolPeriodError),
            const FieldSpec.timeZone('timeZone', '额度时区'),
            const FieldSpec('minutes', '额度（分钟，0–1440）',
                numeric: true, maxLength: 4, minValue: 0, maxValue: 1440),
            const FieldSpec('seconds', '秒（可选）', numeric: true, required: false,
                maxLength: 2, minValue: 0, maxValue: 59, hint: '可留空，按 0 秒计算'),
          ],
          initial: {
            'name': '每日使用额度',
            if (children.length == 1) 'subjectId': children.single['id'],
            'applicationId': '',
            'periodId': localDateInZone(DateTime.now(), zone),
            'timeZone': zone,
            'minutes': 60,
            'seconds': 0,
          },
          recoverLabel: '查询原保存结果',
          onSubmit: (v) async {
            final original = QuotaPoolChange.create(v);
            attempted = true;
            final value = await request(lease, () => scope.api.send('POST',
                '$root/quota-pools', key: key, body: original.body));
            if (!scope.current) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
            return original.committed(value);
          },
          onRecoverUnknown: (v) async {
            final original = QuotaPoolChange.create(v);
            final value = await request(lease, () => scope.api.send('POST',
                '$root/quota-pools/creation-results/$key/query', body: original.body));
            if (!scope.current) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
            final result = original.queryResult(value, requestId: key);
            if (result.current['version'] > result.committed['version']) {
              reviewNotice = '原操作已核对，账本已有后续变化，请核对当前列表。';
            }
            return result.committed;
          });
      if (result != null && reviewNotice != null && scope.current && interactive(context)) {
        toast(context, reviewNotice!);
      }
      return attempted && scope.current && lease.current;
    } finally {
      scope.dispose();
      access.dispose();
    }
  }

  Future<bool> details(BuildContext context, String root, String id, ResourceActionLease lease) async {
    if (!interactive(context) || root != ownerRoot || !lease.current) return false;
    var needsReview = false;
    final access = DialogAccessBinding(context,
        accessChanges: Listenable.merge([changes, lease]),
        hasAccess: () => current() && lease.current);
    final api = pageScope.api.scoped(access.permitted);
    try {
      final value = await request(lease, () => api.send('GET', '$root/quota-pools/$id'));
      if (!context.mounted) return false;
      if (!access.permitted() || !interactive(context)) return false;
      final pool = readQuotaPoolSnapshot(value, expectedId: id);
      await scopedDetailsDialog(context, pool['name'], const {},
          accessChanges: access.changes,
          hasAccess: access.permitted,
          reauth: () {
            if (access.permitted()) session.login(stepUp: true);
          },
          extraContent: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${pool['periodId']} · ${pool['timeZone']}',
                    style: const TextStyle(color: muted)),
                const SizedBox(height: 24),
                QuotaBalance(pool: pool),
                const SizedBox(height: 24),
                if ((pool['reservedSeconds'] as num) > 0)
                  const Notice('部分额度正在等待设备结算。离线或租约超时不会自动返还，以免重复分配已经消费的时间。'),
                const SizedBox(height: 12),
                Text('周期：${dateLabel(pool['periodStart'])} — ${dateLabel(pool['periodEnd'])}\n以上时间按当前浏览器当地时区显示。',
                    style: const TextStyle(color: muted, height: 1.7)),
                const SizedBox(height: 12),
                const Notice('此页面展示服务端账本。设备实际停止行为需以经验证的执行能力和设备证据为准。'),
              ]),
          actions: [
            DetailAction('查看账本', (dialogContext) async {
              if (access.permitted() && interactive(dialogContext)) {
                await ledger(dialogContext, root, pool, lease);
              }
            }, closeOnSuccess: false),
            if (session.canWrite &&
                DateTime.fromMillisecondsSinceEpoch(pool['periodEnd'])
                    .isAfter(DateTime.now()))
              DetailAction('调整额度', (dialogContext) async {
                final route = ModalRoute.of(dialogContext);
                if (!access.permitted() || route is! OwnedDialogRoute<void> ||
                    !route.available || !route.isCurrent) return;
                final changed = await adjust(dialogContext, root, pool, lease);
                needsReview = needsReview || changed;
                if (changed && access.permitted() && route.available) {
                  route.finish();
                }
              }, closeOnSuccess: false),
          ]);
      return needsReview && current() && lease.current && access.permitted();
    } finally {
      access.dispose();
    }
  }

  Future<bool> adjust(BuildContext context, String root, Json pool, ResourceActionLease lease) async {
    if (!interactive(context) || root != ownerRoot ||
        !session.canWrite || !lease.current) return false;
    var attempted = false;
    String? reviewNotice;
    final s = session;
    final access = DialogAccessBinding(context,
        accessChanges: Listenable.merge([changes, lease]),
        hasAccess: () => current() && lease.current);
    final scope = DeviceSubflowScope(s,
        permitted: () => current() && access.permitted() &&
            context.mounted && identical(session, s) &&
            s.tenant != null && s.root == root && s.canWrite);
    try {
      if (!scope.current) return false;
      final key = const Uuid().v4();
      final result = await formDialog(context,
          title: '调整当日额度',
          accessChanges: access.changes,
          hasAccess: () => scope.current,
          description: '增加时间与减少额度均记入账本。减少后的总额度不能低于已结算与待确认预留之和，需要近期多因素认证。',
          reauth: () {
            if (scope.current) s.login(stepUp: true);
          },
          fields: const [
            FieldSpec('direction', '调整方式',
                options: {'ADD': '追加使用时间', 'SUBTRACT': '减少额度'}),
            FieldSpec('minutes', '调整分钟数（0–1440）', numeric: true, maxLength: 4,
                minValue: 0, maxValue: 1440),
            FieldSpec('seconds', '秒（可选）', numeric: true, required: false,
                maxLength: 2, minValue: 0, maxValue: 59, hint: '可留空，按 0 秒计算'),
          ],
          initial: {'direction': 'ADD', 'minutes': 15, 'seconds': 0},
          recoverLabel: '查询原保存结果',
          onSubmit: (v) async {
            final original = QuotaPoolChange.adjust(pool, v);
            attempted = true;
            final value = await request(lease, () => scope.api.send('POST',
                '$root/quota-pools/${pool['id']}/adjustments', key: key,
                version: pool['version'], body: original.body));
            if (!scope.current) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
            return original.committed(value);
          },
          onRecoverUnknown: (v) async {
            final original = QuotaPoolChange.adjust(pool, v);
            final value = await request(lease, () => scope.api.send('POST',
                '$root/quota-pools/${pool['id']}/adjustment-results/$key/query',
                version: pool['version'], body: original.body));
            if (!scope.current) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
            final result = original.queryResult(value, requestId: key);
            if (result.current['version'] > result.committed['version']) {
              reviewNotice = '原操作已核对，账本已有后续变化，请核对当前列表。';
            }
            return result.committed;
          });
      if (result != null && reviewNotice != null && scope.current && interactive(context)) {
        toast(context, reviewNotice!);
      }
      return attempted && scope.current && lease.current;
    } finally {
      scope.dispose();
      access.dispose();
    }
  }

  Future<void> ledger(BuildContext context, String root, Json pool, ResourceActionLease lease) async {
    if (!interactive(context) || root != ownerRoot || !lease.current) return;
    final access = DialogAccessBinding(context,
        accessChanges: Listenable.merge([changes, lease]),
        hasAccess: () => current() && lease.current);
    late final OwnedDialogRoute<void> route;
    late final Api api;
    bool accepted() => access.permitted() && route.available && route.isActive;
    void close() {
      if (route.available && route.isCurrent) route.finish();
    }
    route = OwnedDialogRoute<void>(context: context, builder: (_) => AnimatedBuilder(
        animation: access.changes,
        builder: (_, __) => !accepted()
            ? AlertDialog(
                title: const Text('工作空间或权限已变化'),
                content: const Text('已隐藏旧账本，请关闭窗口后重新打开。'),
                actions: [TextButton(onPressed: close, child: const Text('关闭'))])
            : Dialog(child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: Padding(padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(child: SingleChildScrollView(child: ResourcePage(
                          api: api, isCurrent: accepted,
                          includeRow: includeLedgerRow,
                          onReadDenied: (failure) => rejectPrivateAccess(failure, lease: lease),
                          canInteract: () => route.isCurrent,
                          reauth: () {
                            if (accepted() && route.isCurrent) session.login(stepUp: true);
                          },
                          path: '$root/quota-pools/${pool['id']}/ledger',
                          title: '额度账本', subtitle: '${pool['name']} · ${pool['periodId']}',
                          emptyTitle: '暂无账本记录',
                          emptyDescription: '额度创建、调整、预留和结算都会在这里留下记录。',
                          columns: [
                            ColumnSpec('发生时间', (r) => Text(dateLabel(r['occurredAt']))),
                            ColumnSpec('操作', (r) => Text(quotaKind(r['kind']))),
                            ColumnSpec('总额度变化', (r) => Text(quotaDelta(r['limitDelta']))),
                            ColumnSpec('结算变化', (r) => Text(quotaDelta(r['usedDelta']))),
                            ColumnSpec('预留变化', (r) => Text(quotaDelta(r['reservedDelta']))),
                          ]))),
                      Align(alignment: Alignment.centerRight,
                          child: TextButton(onPressed: close, child: const Text('关闭'))),
                    ]))))));
    api = pageScope.api.scoped(accepted);
    try {
      if (access.permitted() && interactive(context)) await presentOwnedDialog(context, route);
    } finally {
      access.dispose();
    }
  }
}
