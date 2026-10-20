import 'dart:async';
import 'dart:convert';
import '../core/browser_publication_journal.dart';
import '../core/policy_publication.dart';
import '../core/policy_publication_repository.dart';
import '../core/publication_journal.dart';
import 'policy_publication_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../core/api.dart';
import '../core/application_classification.dart';
import '../core/enrollment_recovery.dart';
import '../core/device_management.dart';
import '../core/managed_execution.dart';
import 'managed_execution_dialog_entry.dart';
import '../ui/device_management_dialog.dart';
import '../core/browser_enrollment_journal.dart';
import '../ui/enrollment_dialog.dart';
import 'package:uuid/uuid.dart';
import '../core/labels.dart';
import '../core/observation.dart' show canReadObservation;
import '../core/overview_summary.dart';
import '../core/session.dart';
import '../core/workspace_read_recovery.dart';
import 'device_subflow_scope.dart';
import 'policy_details_entry.dart';
import 'observation_page.dart';
import '../ui/design.dart';
import '../ui/dialog_access.dart';
import '../ui/device_observation_status.dart';
import '../ui/application_classification_dialog.dart';
import '../ui/resource_page.dart';
import '../ui/workbench_view.dart';
import '../ui/workspace_welcome.dart';
import '../ui/family_finance_page.dart';
import '../ui/family_identity_page.dart';
import '../ui/member_editor.dart';
import '../ui/owned_dialog_route.dart';
import '../ui/access_request_dialog.dart';
import '../ui/policy_target_picker.dart';
import 'members_page.dart';
import 'classes_page.dart';
import 'device_groups_page.dart';
import 'managed_android_page.dart';
import 'managed_android_review_page.dart';
import 'audit_page.dart';
import 'audit_exports_page.dart';
import 'usage_reports_page.dart';
import 'editors.dart';
import 'device_exit_dialog.dart';
import 'device_diagnostic_dialog.dart';
import 'diagnostic_packages_dialog.dart';
import 'quota_page.dart';
import 'ownership_page.dart';
import 'notifications_page.dart';
import 'support_page.dart';
import 'help_requests_page.dart';
import 'scoped_overview_page.dart';
import 'commercial_account_page.dart';
import 'commercial_catalog_page.dart';
import 'contracts_page.dart';

final _enrollmentJournal = BrowserEnrollmentJournal();
final _enrollmentChanges = ValueNotifier<int>(0);
final _openEnrollmentScopes = <String>{};

class ConsolePages extends StatelessWidget {
  final String section;
  const ConsolePages({super.key, required this.section});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    final actions = ConsoleActions(context, s);
    if (section == 'identity-providers') {
      if (!s.canOpen(section)) {
        return const Panel(child:EmptyView('没有短信与微信配置权限','请使用已授权的平台管理员账号登录。'));
      }
      final actor=s.profile!['subject'] as String,generation=s.scopeGeneration;
      final read=s.canReadIdentityProviders,manage=s.canManageIdentityProviders,test=s.canTestIdentityProviders;
      final publish=s.canPublishIdentityProviders,rollback=s.canRollbackIdentityProviders;
      return IdentityProvidersPage(key:ValueKey((actor,generation,read,manage,test,publish,rollback)),api:s.api,actor:actor,
        canRead:read,canManage:manage,canTest:test,changes:s,storage:s.identityProviderOperationStorage,
        canPublish:publish,canRollback:rollback,
        isCurrent:()=>context.mounted && s.authenticated && s.profile?['subject'] == actor &&
          s.scopeGeneration == generation && s.canReadIdentityProviders == read &&
          s.canManageIdentityProviders == manage && s.canTestIdentityProviders == test &&
          s.canPublishIdentityProviders == publish && s.canRollbackIdentityProviders == rollback,
        reauthenticate:()=>s.login(stepUp:true));
    }
    if (section == 'family-finance') {
      if (!s.canOpen(section)) {
        return const Panel(child: EmptyView('没有家庭售后权限', '请使用已授权的售后或财务账号登录。'));
      }
      final actor = s.profile!['subject'] as String;
      final generation = s.scopeGeneration;
      final review = s.canReviewFamilyRefunds;
      final finance = s.canManageFamilyFinance;
      return FamilyFinancePage(
        key: ValueKey((actor, generation, review, finance)),
        api: s.api,
        actor: actor,
        canReviewRefunds: review,
        canManageFinance: finance,
        changes: s,
        isCurrent: () =>
            context.mounted &&
            s.authenticated &&
            s.profile?['subject'] == actor &&
            s.scopeGeneration == generation &&
            s.canReviewFamilyRefunds == review &&
            s.canManageFamilyFinance == finance,
        reauthenticate: () => s.login(stepUp: true),
      );
    }
    if (section == 'support') {
      return SupportWorkspacePage(s,
          key: ValueKey((
            s.profile?['subject'],
            s.tenant?['id'],
            s.role,
            s.scopeGeneration,
            s.profile?['canCreateTenant'] == true
          )));
    }
    if (section == 'catalog') {
      return s.canOpen('catalog')
          ? CommercialCatalogPage(
              key: ValueKey(s.profile?['subject']), session: s)
          : const Panel(child: EmptyView('没有平台目录权限', '此功能仅向平台运营与独立审批角色开放。'));
    }
    if (section == 'contracts') {
      return s.canOpen('contracts')
          ? ContractsPage(
              key: ValueKey('platform-contracts-${s.profile?['subject']}'),
              session: s,
              platform: true)
          : const Panel(child: EmptyView('没有合同审核权限', '此功能仅向平台合同运营与独立审批角色开放。'));
    }
    if (section == 'managed-android-review') {
      return s.canOpen('managed-android-review')
          ? ManagedAndroidReviewPage(
              key: ValueKey('managed-review-${s.profile?['subject']}'),
              session: s)
          : const Panel(child: EmptyView('没有企业绑定审核权限', '此功能仅向经过授权的独立平台审核员开放。'));
    }
    if (s.tenant == null) {
      final authenticatedProfile = s.profile;
      bool current() =>
          context.mounted &&
          s.authenticated &&
          identical(s.profile, authenticatedProfile);
      return WorkspaceWelcome(
          key: ValueKey(authenticatedProfile),
          authenticationIdentity: authenticatedProfile,
          isCurrent: current,
          onCreate: s.profile?['canCreateTenant'] == true
              ? () => actions.createTenant(onReadFailure: (failure) async {
                    throw failure;
                  })
              : null,
          onJoin: () =>
              actions.acceptInvitation(onReadFailure: (failure) async {
                throw failure;
              }),
          onRefresh: s.loadTenants,
          onSignOut: s.logout,
          onReauthenticate: actions.reauth,
          platformTools: [
            if (s.canOpen('identity-providers'))
              OutlinedButton.icon(onPressed:()=>context.go('/identity-providers'),
                icon:const Icon(Icons.verified_user_outlined,size:18),label:const Text('短信与微信')),
            if (s.canOpen('family-finance'))
              OutlinedButton.icon(
                  onPressed: () => context.go('/family-finance'),
                  icon: const Icon(Icons.payments_outlined, size: 18),
                  label: const Text('家庭售后与对账')),
            if (s.canOpen('catalog'))
              OutlinedButton.icon(
                  onPressed: () => context.go('/catalog'),
                  icon: const Icon(Icons.inventory_2_outlined, size: 18),
                  label: const Text('平台产品目录')),
            if (s.canOpen('contracts'))
              OutlinedButton.icon(
                  onPressed: () => context.go('/contracts'),
                  icon: const Icon(Icons.description_outlined, size: 18),
                  label: const Text('平台机构合同')),
            if (s.canOpen('managed-android-review'))
              OutlinedButton.icon(
                  onPressed: () => context.go('/managed-android-review'),
                  icon: const Icon(Icons.fact_check_outlined, size: 18),
                  label: const Text('企业绑定审核')),
          ]);
    }
    if (!s.canOpen(section)) {
      return const Panel(
          child: EmptyView('此角色无权访问该页面', '请从导航中选择可用功能，或联系工作空间管理员。'));
    }
    if (section == 'help-requests') {
      return HelpRequestsPage(key: ValueKey('${s.root}/${s.role}'), session: s);
    }
    if (section == 'overview' && !s.canWrite) {
      return ScopedOverviewPage(
          key: ValueKey('${s.root}/${s.role}'), session: s);
    }
    if (section == 'classes') {
      return ClassesPage(key: ValueKey((s.profile?['subject'],
          s.tenant?['id'], s.role, s.scopeGeneration)), session: s);
    }
    if (section == 'device-groups') {
      return DeviceGroupsPage(key: ValueKey((s.profile?['subject'],
          s.tenant?['id'], s.role, s.scopeGeneration)), session: s);
    }
    if (section == 'managed-android') {
      return ManagedAndroidPage(
          key: ValueKey('${s.root}-${s.role}'), session: s);
    }
    if (section == 'reports') {
      return UsageReportsPage(key: ValueKey('${s.root}-${s.role}'), session: s);
    }
    if (section == 'commercial') {
      return CommercialAccountPage(
          key: ValueKey('${s.root}-${s.role}'), session: s);
    }
    if (section == 'institution-contracts') {
      return ContractsPage(
          key: ValueKey('institution-contracts-${s.root}-${s.role}'),
          session: s,
          platform: false);
    }
    if (section == 'notifications') {
      return NotificationsPage(
          key: ValueKey('${s.root}-${s.role}'),
          session: s,
          onOpen: (id) => actions.approvalDetails({'id': id}));
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
      case 'quota':
        return QuotaPage(session: s);
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
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          enrollmentRecoveryNotice(s, actions),
          resource(
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
                ColumnSpec('心跳观察',
                    (r) => DeviceObservationStatus(r['observationStatus'])),
                ColumnSpec('最近心跳', (r) => Text(dateLabel(r['lastHeartbeatAt'])))
              ],
              create: s.canWrite ? actions.enrollment : null,
              createLabel: '添加设备',
              open: actions.deviceDetails,
              notice:
                  '心跳仅反映服务端近期能否观察设备。心跳过期需检查连接，不能据此判断规则已失效。策略执行仍以设备能力和执行回执为准。',
              empty: '尚未连接设备',
              description: '先创建儿童档案，再通过配对流程绑定 Android 或 TV 设备。',
              toolbar: [
                if (s.canWrite)
                  TextButton(
                      onPressed: actions.findEnrollment,
                      child: const Text('查询注册进度'))
              ]),
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
            open: (r) => actionDetails(context, r['displayName'], {
                  '包名': r['packageName'],
                  '平台': label(r['platform']),
                  '资料空间': label(r['profile']),
                  '签名摘要': (r['signingDigests'] as List).join('\n'),
                  '身份状态': label(r['evidenceStatus']),
                  '应用编号': r['id']
                }, actions: [
                  DetailAction(
                      '查看与设置分类', (_) => actions.applicationClassification(r))
                ]),
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
            title: s.role == 'TEACHER' ? '我的访问申请' : '访问审批',
            subtitle: s.role == 'TEACHER'
                ? '仅查看当前授课范围内由本人提交的申请；范围失效后申请将同步失效。'
                : '查看临时访问请求，保留有期限的决定记录。',
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
            create: ['TEACHER', 'CHILD'].contains(s.role)
                ? actions.createAccessRequest
                : null,
            createLabel: '申请临时访问',
            open: actions.approvalDetails,
            empty: '暂无访问申请',
            description: ['TEACHER', 'CHILD'].contains(s.role)
                ? '选择范围内的设备，向管理员说明需要临时访问的应用与时长。'
                : '儿童或教师提交申请后，将在这里显示。',
            notice: '批准后设备可获取带固定截止时间的签名文档。接收与保存回执单独记录；当前尚未接入设备例外执行。');
      case 'members':
        return MembersPage(key: ValueKey((s.profile?['subject'],
            s.tenant?['id'], s.role, s.scopeGeneration)),
            session: s, invite: actions.invite);
      case 'ownership':
        return OwnershipPage(session: s);
      case 'audit':
        return AuditExplorerPage(
            key: ValueKey('audit-${s.root}-${s.role}'), session: s);
      case 'exports':
        return AuditExportsPage(
            key: ValueKey('exports-${s.root}-${s.role}'), session: s);
      case 'settings':
        return SettingsPage(session: s, actions: actions);
      default:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          enrollmentRecoveryNotice(s, actions),
          Dashboard(session: s, actions: actions),
        ]);
    }
  }

  Widget enrollmentRecoveryNotice(Session s, ConsoleActions actions) {
    if (!s.authenticated ||
        s.tenant == null ||
        !s.canWrite ||
        s.profile?['subject'] is! String) return const SizedBox.shrink();
    final scope = EnrollmentScope(
        actorId: s.profile!['subject'] as String,
        tenantId: s.tenant!['id'] as String,
        role: s.role);
    final generation = s.scopeGeneration;
    return EnrollmentResumeNotice(
        key: ValueKey('enrollment-${scope.key}-$generation'),
        journal: _enrollmentJournal,
        scope: scope,
        changes: _enrollmentChanges,
        isCurrent: () =>
            s.authenticated &&
            s.canWrite &&
            s.scopeGeneration == generation &&
            s.profile?['subject'] == scope.actorId &&
            s.tenant?['id'] == scope.tenantId &&
            s.role == scope.role,
        onOpen: actions.enrollment);
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
  Future<Json?> _tenantForm(
      {BuildContext? parent,
      required String title,
      required String section,
      required List<FieldSpec> fields,
      Json initial = const {},
      String? description,
      required Future<Json?> Function(Api, Json) onSubmit}) async {
    final owner = parent ?? context;
    final scope = DeviceSubflowScope(s,
        permitted: () =>
            context.mounted && owner.mounted &&
            s.tenant != null && s.root == root &&
            s.canWrite && s.canOpen(section));
    try {
      if (!scope.current) return null;
      return await formDialog(owner,
          title: title,
          fields: fields,
          initial: initial,
          description: description,
          accessChanges: scope,
          hasAccess: () => scope.current,
          reauth: reauth,
          onSubmit: (values) => onSubmit(scope.api, values));
    } finally {
      scope.dispose();
    }
  }

  Future<void> _readCompletedWorkspace(
      Json authenticatedProfile, String completedMessage,
      {String? preferredTenantId,
      Future<void> Function(WorkspaceReadRecovery)? onReadFailure}) async {
    bool current() =>
        context.mounted &&
        s.authenticated &&
        identical(s.profile, authenticatedProfile);
    Future<void> reload() async {
      if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
      await s.loadTenants(preferredTenantId: preferredTenantId);
      if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }

    if (!current()) return;
    try {
      await reload();
    } catch (failure) {
      if (!current()) return;
      final recovery = WorkspaceReadRecovery(
          completedMessage: completedMessage,
          error: failure,
          reload: reload,
          isCurrent: current);
      if (onReadFailure != null) {
        await onReadFailure(recovery);
      } else {
        if (!context.mounted) {
          return;
        }
        await showWorkspaceReadRecoveryDialog(context, recovery,
            accessChanges: s, onSignOut: s.logout, onReauthenticate: reauth);
      }
    }
  }

  Future<void> createTenant(
      {Future<void> Function(WorkspaceReadRecovery)? onReadFailure}) async {
    final authenticatedProfile = s.profile;
    if (!s.authenticated ||
        authenticatedProfile == null ||
        s.profile?['canCreateTenant'] != true) return;
    final scope = DeviceSubflowScope(s,
        permitted: () =>
            context.mounted &&
            identical(s.profile, authenticatedProfile) &&
            s.profile?['canCreateTenant'] == true);
    try {
      if (!scope.current) return;
      final key = requestId();
      final result = await formDialog(context,
          title: '创建工作空间',
          accessChanges: scope,
          hasAccess: () => scope.current,
          fields: [
            const FieldSpec('name', '工作空间名称'),
            FieldSpec('kind', '类型',
                options: options(['FAMILY', 'ORGANIZATION'])),
            const FieldSpec('timeZone', '时区', hint: 'Asia/Shanghai')
          ],
          initial: {'kind': 'FAMILY', 'timeZone': 'Asia/Shanghai'},
          onSubmit: (v) async => await scope.api
              .send('POST', '/tenants', body: v, key: key) as Json);
      if (result != null && scope.current) {
        await _readCompletedWorkspace(
            authenticatedProfile, '工作空间已创建，工作空间资料暂未加载。',
            preferredTenantId: result['id'] as String,
            onReadFailure: onReadFailure);
      }
    } finally {
      scope.dispose();
    }
  }

  Future<void> acceptInvitation(
      {Future<void> Function(WorkspaceReadRecovery)? onReadFailure}) async {
    final authenticatedProfile = s.profile;
    if (!s.authenticated || authenticatedProfile == null) return;
    final scope = DeviceSubflowScope(s,
        permitted: () =>
            context.mounted && identical(s.profile, authenticatedProfile));
    try {
      if (!scope.current) return;
      final result = await formDialog(context,
          title: '接受邀请',
          accessChanges: scope,
          hasAccess: () => scope.current,
          description: '使用与你当前账户邮箱一致的邀请。成人加入可能需要近期多因素认证。',
          fields: const [FieldSpec('token', '一次性邀请令牌', maxLength: 128)],
          reauth: reauth,
          onSubmit: (v) async => await scope.api
              .send('POST', '/invitations/accept', body: v) as Json);
      if (result != null && scope.current) {
        await _readCompletedWorkspace(
            authenticatedProfile, '已加入工作空间，工作空间资料暂未加载。',
            onReadFailure: onReadFailure);
      }
    } finally {
      scope.dispose();
    }
  }

  Future<void> subject([Json? existing]) async {
    final key = requestId();
    await _tenantForm(
        title: existing == null ? '添加儿童档案' : '编辑儿童档案',
        section: 'subjects',
        fields: [
          const FieldSpec('nickname', '昵称', maxLength: 60),
          FieldSpec('ageBand', '年龄段',
              options: options(['UNDER_7', 'AGE_7_12', 'AGE_13_17']))
        ],
        initial: existing ?? {},
        onSubmit: (api, v) async => await api.send(
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
    await _tenantForm(
        title: '登记应用',
        section: 'applications',
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
        }, onSubmit: (api, v) async {
      final data = Map<String, dynamic>.from(v);
      final raw = data.remove('digests') as String;
      data['signingDigests'] = raw
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      return await api
          .send('POST', '$root/applications', body: data, key: key) as Json;
    });
  }

  Future<void> applicationClassification(Json application) async {
    final capturedRole = s.role;
    final repository = ApplicationClassificationRepository(
        api: s.api,
        root: root,
        applicationId: application['id'],
        identity: ApplicationClassificationIdentity(application['platform'],
            application['profile'], application['packageName']),
        current: () =>
            s.authenticated &&
            s.tenant != null &&
            s.root == root &&
            s.role == capturedRole);
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ApplicationClassificationDialog(
            repository: repository,
            applicationName: application['displayName'],
            canEdit: s.canWrite,
            accessChanges: s));
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

  Future<void> enrollment() => _connectEnrollment();

  Future<void> _connectEnrollment({String? lookupId}) async {
    if (!s.authenticated || s.tenant == null || !s.canWrite) return;
    final scope = EnrollmentScope(
        actorId: s.profile!['subject'] as String,
        tenantId: s.tenant!['id'] as String,
        role: s.role);
    final generation = s.scopeGeneration;
    bool current() =>
        context.mounted &&
        s.authenticated &&
        s.canWrite &&
        s.profile?['subject'] == scope.actorId &&
        s.tenant?['id'] == scope.tenantId &&
        s.role == scope.role &&
        s.scopeGeneration == generation;
    if (!current() || root != s.root || !_openEnrollmentScopes.add(scope.key)) {
      return;
    }
    final gateway = lookupId == null
        ? EnrollmentGateway(s.api)
        : EnrollmentGateway.lookup(s.api);
    EnrollmentController? controller;
    ModalRoute<dynamic>? route;
    void accessChanged() {
      if (current()) return;
      controller?.invalidate();
      final active = route;
      if (active != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (active.isActive) active.navigator?.removeRoute(active);
        });
      }
    }

    s.addListener(accessChanged);
    try {
      EnrollmentJournal journal = _enrollmentJournal;
      if (lookupId != null) {
        final intent = await gateway.lookupIntent(scope, lookupId,
            now: DateTime.now().millisecondsSinceEpoch, isCurrent: current);
        if (!context.mounted || !current()) return;
        journal = EnrollmentLookupJournal(intent);
      }
      final active = EnrollmentController(
          scope: scope,
          journal: journal,
          gateway: gateway,
          isCurrent: current,
          newId: () => const Uuid().v4(),
          now: () => DateTime.now().millisecondsSinceEpoch);
      controller = active;
      await active.initialize();
      if (!context.mounted || !current()) return;
      var children = <Json>[];
      final failure = active.error;
      final denied = failure is ApiFailure &&
          (failure.status == 401 || failure.status == 403);
      if (lookupId == null &&
          !denied &&
          (active.pending != null || active.error == null)) {
        try {
          children = await s.api.all('$root/subjects', isCurrent: current);
        } catch (_) {
          if (active.pending == null) rethrow;
        }
        if (!context.mounted || !current()) return;
        if (children.isEmpty && active.pending == null) {
          toast(context, '请先创建儿童或学生档案。');
          context.go('/subjects');
          return;
        }
      }
      if (!context.mounted || !current()) return;
      await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) {
            route = ModalRoute.of(dialogContext);
            return EnrollmentDialog(
                controller: active,
                subjects: children,
                organization: s.tenant?['kind'] == 'ORGANIZATION',
                onReauthenticate: () {
                  if (current()) {
                    active.conceal();
                    s.login(stepUp: true);
                  }
                },
                onViewDevice: (id) {
                  if (!context.mounted || !current()) return;
                  Navigator.of(dialogContext).pop();
                  WidgetsBinding.instance.addPostFrameCallback((_) async {
                    if (!context.mounted || !current()) return;
                    try {
                      await _enrollmentDeviceDetails(id, scope, current,
                          subjectId: active.pending!.subjectId,
                          platform: active.pending!.platform);
                    } catch (failure) {
                      if (context.mounted && current()) {
                        toast(context, failure.toString());
                      }
                    }
                  });
                });
          });
    } catch (failure) {
      if (context.mounted && current()) toast(context, failure.toString());
    } finally {
      s.removeListener(accessChanged);
      controller?.dispose();
      _openEnrollmentScopes.remove(scope.key);
      _enrollmentChanges.value++;
    }
  }

  Future<void> findEnrollment() async {
    if (!s.authenticated || s.tenant == null || !s.canWrite) return;
    final generation = s.scopeGeneration;
    final workspace = root;
    final result = await formDialog(context,
        title: '查询注册进度',
        accessChanges: s,
        hasAccess: () => context.mounted && s.authenticated &&
            s.tenant != null && s.scopeGeneration == generation &&
            s.root == workspace && s.canWrite,
        description: '输入原注册编号，在同一窗口核对进度、现场确认或取消。',
        submit: '查询进度',
        fields: const [FieldSpec('id', '注册编号', maxLength: 36)],
        onSubmit: (values) async {
      final id = (values['id'] as String).trim();
      if (!RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
          .hasMatch(id)) {
        throw const ApiFailure(400, 'INVALID_ENROLLMENT_ID');
      }
      return {'id': id};
    });
    if (result == null ||
        !context.mounted ||
        !s.authenticated ||
        s.scopeGeneration != generation ||
        s.root != workspace) return;
    await _connectEnrollment(lookupId: result['id'] as String);
  }

  Future<void> _enrollmentDeviceDetails(
      String id, EnrollmentScope scope, bool Function() current,
      {required String subjectId, required String platform}) async {
    if (!context.mounted || !current()) return;
    final value = await s.api.send(
        'GET', '/tenants/${scope.tenantId}/devices/$id',
        isCurrent: current);
    if (!context.mounted || !current()) return;
    if (value is! Json ||
        value['id'] != id ||
        value['subjectId'] != subjectId ||
        value['platform'] != platform ||
        value['displayName'] is! String) {
      throw const ApiFailure(502, 'INVALID_ENROLLMENT_RESPONSE');
    }
    await actionDetails(
        context,
        value['displayName'] as String,
        {
          '平台': '${label(value['platform'])} · ${value['osVersion']}',
          '注册状态': label(value['state']),
          '管理模式': label(value['managementMode']),
          '控制能力': label(value['controlLevel']),
          '最近心跳': dateLabel(value['lastHeartbeatAt']),
          '观察状态': label(value['observationStatus']),
          '观察说明':
              DeviceObservationStatus.explanation(value['observationStatus']),
          '设备编号': value['id'],
        },
        accessChanges: s,
        hasAccess: current);
  }

  Future<void> deviceDetails(Json row) async {
    if (!context.mounted ||
        !s.authenticated ||
        s.tenant == null ||
        !s.canOpen('devices') ||
        s.root != root) return;
    final actor = s.profile?['subject'], tenant = s.tenant!['id'];
    final openedRole = s.role, generation = s.scopeGeneration;
    final workspace = root;
    if (actor is! String || tenant is! String || row['id'] is! String) return;
    bool live = true;
    bool current() =>
        live &&
        s.authenticated &&
        s.profile?['subject'] == actor &&
        s.tenant?['id'] == tenant &&
        s.role == openedRole &&
        s.scopeGeneration == generation &&
        s.canOpen('devices');
    final controller = DeviceManagementController(
        repository: DeviceManagementRepository(
            api: s.api,
            root: workspace,
            deviceId: row['id'] as String,
            current: current),
        canWrite: s.canWrite,
        canReadApplications: openedRole != 'TEACHER');
    Future<void> child(Future<void> Function() action) async {
      if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
      await action();
      if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }

    try {
      await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => DeviceManagementDialog(
              controller: controller,
              accessChanges: s,
              onReauth: reauth,
              onClose: () => Navigator.of(dialogContext).pop(),
              onExecutions: canReadManagedExecutions(openedRole)
                  ? (device) => child(() => openManagedExecutions(
                      dialogContext, s,
                      deviceId: device.id,
                      registrationId: device.registrationId,
                      deviceName: device.displayName,
                      current: () =>
                          current() &&
                          controller.hasAccess &&
                          controller.device?.id == device.id &&
                          controller.device?.registrationId ==
                              device.registrationId,
                      targetChanges: controller))
                  : null,
              onDiagnostic: canReadDiagnostics(openedRole)
                  ? (device) => child(() =>
                      openDeviceDiagnostic(dialogContext, s, device.toJson()))
                  : null,
              onExport: s.canWrite
                  ? (device) => child(() => openDiagnosticPackages(
                      dialogContext, s, device: device.toJson()))
                  : null,
              onSupport: s.canWrite
                  ? (device) => child(
                      () => openSupportGrant(dialogContext, s, device.toJson()))
                  : null,
              onPrivacy: canReadObservation(openedRole)
                  ? (device) => child(
                      () => openDeviceObservation(dialogContext, s, device.toJson()))
                  : null,
              onExit: s.canWrite ? (device) => child(() => openDeviceExit(dialogContext, s, device.toJson())) : null));
    } finally {
      live = false;
      controller.dispose();
    }
  }

  Future<void> policyDetails(Json row) => openPolicyDetails(context, s,
      root: root, row: row, preview: previewPolicy);

  Future<void> previewPolicy(BuildContext ctx, Json draft,
      {PublicationJournal? journal}) async {
    final policyValue = draft['id'], revisionValue = draft['revision'];
    final actor = s.profile?['subject'], tenant = s.tenant?['id'];
    final role = s.role, workspace = root;
    final parentRoute = ModalRoute.of(ctx);
    if (!ctx.mounted ||
        parentRoute == null ||
        !parentRoute.isActive ||
        !parentRoute.isCurrent ||
        !s.authenticated ||
        !s.canWrite ||
        !s.canOpen('policies') ||
        actor is! String ||
        tenant is! String ||
        workspace != s.root) return;
    if (!isPublicationOpaqueId(policyValue) ||
        revisionValue is! int ||
        revisionValue < 0 ||
        revisionValue > publicationMaximumSafeInteger) {
      throw const ApiFailure(502, 'INVALID_POLICY_PREVIEW_RESPONSE');
    }
    final policyId = policyValue as String, revision = revisionValue;
    var journeyLive = true;
    final revoked = ValueNotifier<bool>(false);
    // Capture the originating route before local storage or HTTP can await.
    // Its permanent revocation is published safely to independently pushed pages.
    final parentAccess = DialogAccessBinding(ctx);
    // Capture and listen before the very first await, including local storage.
    // An actor/tenant/role/generation ABA cannot establish a fresh scope later.
    final scope = DeviceSubflowScope(s,
        permitted: () =>
            journeyLive &&
            parentAccess.permitted() &&
            !revoked.value &&
            ctx.mounted &&
            parentRoute.isActive &&
            (parentRoute is! OwnedDialogRoute<dynamic> || parentRoute.available) &&
            s.tenant != null &&
            s.root == workspace &&
            s.canWrite &&
            s.canOpen('policies'));
    bool current() => journeyLive && scope.current;
    void requireCurrent() {
      if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }

    void revokePrivateFailure(Object failure) {
      if (journeyLive &&
          failure is ApiFailure &&
          (failure.code == 'WORKSPACE_CHANGED' ||
              failure.status == 403 ||
              (failure.status == 401 && failure.code != 'REAUTH_REQUIRED'))) {
        revoked.value = true;
      }
    }

    try {
      requireCurrent();
      final owner = PublicationOwner(
          actorId: actor,
          tenantId: tenant,
          apiBaseUrl: s.api.baseUrl,
          issuer: Session.issuer);
      final publicationJournal = journal ?? BrowserPublicationJournal();
      final repository = PolicyPublicationRepository(
          api: scope.api,
          owner: owner,
          policyId: policyId,
          current: current,
          onDenied: revokePrivateFailure);
      final changes = Listenable.merge([scope, revoked, parentAccess.changes]);

      Future<bool> finishPublication(PublicationDialogResult result) async {
        if (!ctx.mounted || !current() || !parentRoute.isCurrent) return false;
        switch (result.reason) {
          case PublicationExitReason.repreview:
            return true;
          case PublicationExitReason.currentPolicy:
            if (!s.canOpen('policies')) return false;
            await openPolicyDetails(ctx, s, root: workspace,
                row: {'id': policyId}, preview: previewPolicy,
                parentCurrent: current, accessChanges: changes, readOnly: true);
            return false;
          case PublicationExitReason.audit:
            final query = result.auditQuery;
            if (!s.canOpen('audit') || query == null) return false;
            query.validate();
            final auditRoute = MaterialPageRoute<void>(builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('核对策略操作记录')),
                    body: SingleChildScrollView(padding: const EdgeInsets.all(24),
                        child: AuditExplorerPage(session: s, initialQuery: query,
                            parentCurrent: current, accessChanges: changes,
                            contextNotice: query.resourceId == null
                                ? '已按配置保存操作和原操作附近日期筛选。'
                                  '这些记录不代表与原操作精确关联；未查到记录也不代表原操作未执行。'
                                : '已按此前确认的配置版本筛选。审计记录反映已记录的管理操作，不代表设备已执行。'))));
            await Navigator.of(ctx, rootNavigator: true).push<void>(auditRoute);
            // Keep the journey's notifiers alive through the pushed page's exit.
            await auditRoute.completed;
            return false;
          case PublicationExitReason.closed:
          case PublicationExitReason.acknowledged:
            return false;
        }
      }

      Future<bool> groupCurrent(PolicyTargetSelection target,
          {bool Function()? isCurrent}) async {
        final valid = isCurrent ?? current;
        if (target.groupId == null) return valid();
        if (!valid() || !s.canOpen('device-groups')) return false;
        try {
          final latest = await scope.api.send('GET',
              '$workspace/device-groups/${Uri.encodeComponent(target.groupId!)}',
              isCurrent: valid);
          return valid() &&
              latest is Json &&
              latest['id'] == target.groupId &&
              latest['state'] == 'ACTIVE' &&
              latest['version'] == target.groupVersion;
        } catch (failure) {
          revokePrivateFailure(failure);
          rethrow;
        }
      }

      Future<void> preflight(PublicationIntent original,
          [PolicyTargetSelection? selection]) async {
        requireCurrent();
        if (original.previewExpiresAt <= DateTime.now().millisecondsSinceEpoch) {
          throw const ApiFailure(409, 'PREVIEW_EXPIRED');
        }
        if (selection != null &&
            selection.groupId != null &&
            !await groupCurrent(selection)) {
          throw const ApiFailure(409, 'POLICY_GROUP_CHANGED');
        }
        requireCurrent();
        if (original.previewExpiresAt <= DateTime.now().millisecondsSinceEpoch) {
          throw const ApiFailure(409, 'PREVIEW_EXPIRED');
        }
      }

      while (current() && parentRoute.isCurrent) {
        PublicationPending? pending;
        try {
          pending = await publicationJournal.read(owner, policyId);
          if (!current()) return;
          if (pending != null &&
              (pending.intent.owner != owner ||
                  pending.intent.policyId != policyId)) {
            throw const PublicationLocalRecoveryUnavailable();
          }
        } catch (_) {
          if (!current()) return;
          // Only this local read is normalized. Never turn a read failure into
          // an empty journal and permit a new POST.
          throw const PublicationLocalRecoveryUnavailable();
        }
        if (!ctx.mounted || !current() || !parentRoute.isCurrent) return;
        if (pending != null) {
          final original = pending.intent;
          final result = await showPolicyPublication(ctx,
              repository: repository,
              journal: publicationJournal,
              intent: original,
              pending: pending,
              parentCurrent: current,
              accessChanges: changes,
              // Recovery GET never invokes this preflight. A known not-sent
              // retry checks only original TTL/current; the server rechecks its
              // original snapshot without inventing another group selection.
              preflight: () => preflight(original),
              reauthenticate: reauth,
              canViewAudit: () => current() && s.canOpen('audit'));
          if (!await finishPublication(result)) return;
          continue;
        }

        Json? validatedPreview;
        final picked = await showPolicyTargetPicker(
            context: ctx,
            session: s,
            root: workspace,
            actor: actor,
            role: role,
            onPreview: (selected, isActive) async {
              bool previewCurrent() => current() && isActive();
              try {
                if (selected.groupId != null &&
                    !await groupCurrent(selected, isCurrent: previewCurrent)) {
                  throw const ApiFailure(409, 'POLICY_GROUP_CHANGED');
                }
                if (!previewCurrent()) {
                  throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                }
                final response = await scope.api.send('POST',
                    '$workspace/policies/${Uri.encodeComponent(policyId)}/previews',
                    version: revision,
                    isCurrent: previewCurrent,
                    body: {
                      'deviceIds': selected.deviceIds,
                      if (selected.groupId != null) 'groupId': selected.groupId,
                      if (selected.groupVersion != null)
                        'groupVersion': selected.groupVersion
                    });
                if (!previewCurrent()) {
                  throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                }
                if (response is! Json) {
                  throw const ApiFailure(502, 'INVALID_POLICY_PREVIEW_RESPONSE');
                }
                final p = response;
                if (p['id'] is! String ||
                    (p['id'] as String).length != 36 ||
                    !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
                        .hasMatch(p['id'] as String) ||
                    p['policyId'] != policyId ||
                    p['draftRevision'] is! int ||
                    p['draftRevision'] != revision ||
                    p['phase'] != 'PREVIEW' ||
                    p['hash'] is! String ||
                    (p['hash'] as String).length != 64 ||
                    !RegExp(r'^[a-f0-9]{64}$').hasMatch(p['hash'] as String) ||
                    p['expiresAt'] is! int ||
                    (p['expiresAt'] as int) < 1 ||
                    (p['expiresAt'] as int) > publicationMaximumTimestamp ||
                    p['enforceable'] is! bool) {
                  throw const ApiFailure(502, 'INVALID_POLICY_PREVIEW_RESPONSE');
                }
                if (selected.groupId != null &&
                    (p['snapshot'] is! Json ||
                        (p['snapshot'] as Json)['groupSelection'] is! Json ||
                        ((p['snapshot'] as Json)['groupSelection']
                                as Json)['groupId'] !=
                            selected.groupId ||
                        ((p['snapshot'] as Json)['groupSelection']
                                as Json)['groupVersion'] !=
                            selected.groupVersion)) {
                  throw const ApiFailure(502, 'INVALID_POLICY_PREVIEW_RESPONSE');
                }
                final targets = p['targets'];
                if (targets is! List) {
                  throw const ApiFailure(502, 'INVALID_POLICY_PREVIEW_RESPONSE');
                }
                final returnedRegistrations = <String, String>{};
                for (final target in targets) {
                  if (target is! Json ||
                      target['deviceId'] is! String ||
                      target['registrationId'] is! String ||
                      target['observationStatus'] is! String ||
                      target['rules'] is! List ||
                      (target['rules'] as List).any((rule) =>
                          rule is! Json ||
                          rule['kind'] is! String ||
                          rule['status'] is! String ||
                          (rule['reasonCode'] != null &&
                              rule['reasonCode'] is! String)) ||
                      returnedRegistrations.containsKey(target['deviceId'])) {
                    throw const ApiFailure(
                        502, 'INVALID_POLICY_PREVIEW_RESPONSE');
                  }
                  returnedRegistrations[target['deviceId'] as String] =
                      target['registrationId'] as String;
                }
                if (returnedRegistrations.length != selected.deviceIds.length ||
                    !returnedRegistrations.keys
                        .toSet()
                        .containsAll(selected.deviceIds)) {
                  throw const ApiFailure(502, 'INVALID_POLICY_PREVIEW_RESPONSE');
                }
                if (selected.groupRegistrations.entries.any(
                    (entry) => returnedRegistrations[entry.key] != entry.value)) {
                  throw const ApiFailure(409, 'POLICY_GROUP_CHANGED');
                }
                // Detach the entire Json tree before the picker completes;
                // later mutation/redaction of an outside map cannot change it.
                validatedPreview = Map<String, dynamic>.unmodifiable(
                    jsonDecode(jsonEncode(p)) as Json);
              } catch (failure) {
                revokePrivateFailure(failure);
                rethrow;
              }
            });
        if (!ctx.mounted ||
            !current() ||
            !parentRoute.isCurrent ||
            picked == null ||
            validatedPreview == null) return;
        final p = validatedPreview!;
        final names = Map<String, String>.unmodifiable(picked.names);
        final selectionSummary = picked.groupId == null
            ? '手动选择 ${picked.deviceIds.length} 台设备'
            : '设备组“${picked.groupName}”第 ${picked.groupVersion} 版 · ${picked.deviceIds.length} 台设备';
        final original = PublicationIntent(
            owner: owner,
            policyId: policyId,
            revision: revision,
            previewId: p['id'] as String,
            previewHash: p['hash'] as String,
            previewExpiresAt: p['expiresAt'] as int,
            createdAt: DateTime.now().millisecondsSinceEpoch,
            idempotencyKey: const Uuid().v4());
        final result = await showPolicyPublication(ctx,
            repository: repository,
            journal: publicationJournal,
            intent: original,
            preview: p,
            names: names,
            selectionSummary: selectionSummary,
            parentCurrent: current,
            accessChanges: changes,
            preflight: () => preflight(original, picked),
            reauthenticate: reauth,
            canViewAudit: () => current() && s.canOpen('audit'));
        // Only the independent explicit repreview exit can start another loop.
        if (!await finishPublication(result)) return;
      }
    } finally {
      journeyLive = false;
      scope.dispose();
      revoked.dispose();
      parentAccess.dispose();
    }
  }

  Future<void> versions(BuildContext ctx, Json draft) =>
      openPolicyVersions(ctx, s, root: root, draft: draft);

  Future<void> createAccessRequest() async {
    final workspace = root, key = requestId();
    void currentWorkspace() {
      if (s.root != workspace) {
        throw const ApiFailure(409, 'WORKSPACE_CHANGED');
      }
    }

    await showDialog<Json>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AccessRequestDialog(load: (path, cursor) async {
              currentWorkspace();
              final page = await s.api.page('$workspace/$path', cursor: cursor);
              currentWorkspace();
              return page;
            }, submit: (body) async {
              currentWorkspace();
              return await s.api.send('POST', '$workspace/access-requests',
                  key: key, body: body) as Json;
            }));
  }

  Future<void> approvalDetails(Json row) async {
    final workspace = root;
    final scope = DeviceSubflowScope(s,
        permitted: () => context.mounted && s.tenant != null &&
            s.root == workspace && s.canOpen('approvals'));
    bool current() => scope.current;
    try {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    final api = scope.api;
    final cancelKey = requestId();
    final r = await api.send('GET', '$workspace/access-requests/${row['id']}')
        as Json;
    final delivery = await api.send(
        'GET', '$workspace/access-requests/${row['id']}/delivery') as Json;
    if (!context.mounted) return;
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    await actionDetails(
        context,
        '临时访问申请',
        {
          '状态': label(r['state']),
          if (r['reasonCode'] != null) '状态说明': label(r['reasonCode']),
          '申请时长': '${r['requestedWindowSeconds']} 秒',
          '申请理由': r['reason'],
          '有效期': dateLabel(r['requestExpiresAt']),
          '设备编号': r['deviceId'],
          '学生 / 儿童编号': r['subjectId'],
          '批准截止': dateLabel(r['absoluteNotAfter']),
          '当前文档': label(delivery['action']),
          '文档交付 / 设备报告': delivery['approvalVersion'] == r['version']
              ? label(delivery['deliveryState'])
              : '审批状态已更新，请关闭后重新打开',
          '最近回执': dateLabel(delivery['receivedAt']),
          '交付尝试': delivery['deliveryAttempt'] == null
              ? '尚未开始'
              : '第 ${delivery['deliveryAttempt']} 次（最多 10 次）',
          if (delivery['reasonCode'] != null)
            '设备拒收原因': accessRejectionLabel(delivery['reasonCode']),
          if (delivery['deliveryState'] == 'REJECTED') ...{
            '恢复状态': accessRetryLabel(delivery['retryStatus']),
            if (delivery['retryAfter'] != null)
              '最早可重试': dateLabel(delivery['retryAfter']),
            '恢复说明': '重试由设备端发起，原文档和批准截止时间保持不变。旧尝试的回执仅保留追溯。'
          },
          '执行状态': label(r['executionState']),
          '回执说明': '当前尚未接入设备例外执行。接收或保存回执仅表示文档状态；下载与重试不会延长原批准截止时间。'
        },
        accessChanges: scope,
        hasAccess: current,
        reauth: reauth,
        actions: [
          if (['TEACHER', 'CHILD'].contains(s.role) && r['state'] == 'PENDING')
            DetailAction('取消我的申请', (ctx) async {
              final finish = captureDialogCompletion(ctx);
              if (await confirmAction(ctx, '取消我的申请', '取消后管理员将无法批准此申请。')) {
                if (!current()) {
                  throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                }
                await api.send(
                    'POST', '$workspace/access-requests/${r['id']}/cancel',
                    version: r['version'], key: cancelKey);
                finish();
              }
            }, destructive: true, closeOnSuccess: false),
          DetailAction('交付历史', (ctx) => approvalDeliveryHistory(ctx, r['id']),
              closeOnSuccess: false),
          if (s.canWrite && r['state'] == 'PENDING') ...[
            DetailAction('批准', (ctx) async {
              final key = requestId();
              await _tenantForm(
                  parent: ctx,
                  title: '批准临时访问',
                  section: 'approvals',
                  description: '批准只保存有期限的访问窗口，当前不会直接解锁设备。',
                  fields: const [
                    FieldSpec('seconds', '批准时长（秒，最多 3600）',
                        numeric: true, maxLength: 4)
                  ],
                  initial: {'seconds': r['requestedWindowSeconds']},
                  onSubmit: (api, v) async => await api.send(
                          'POST', '$root/access-requests/${r['id']}/decisions',
                          version: r['version'],
                          key: key,
                          body: {
                            'decision': 'APPROVE',
                            'grantedWindowSeconds': v['seconds']
                          }) as Json);
            }),
            DetailAction('拒绝', (ctx) async {
              final key = requestId();
              await _tenantForm(
                  parent: ctx,
                  title: '拒绝申请',
                  section: 'approvals',
                  fields: const [
                    FieldSpec('reasonCode', '原因', options: {
                      'NOT_NOW': '当前不合适',
                      'NOT_ALLOWED': '不允许访问',
                      'OTHER': '其他原因'
                    })
                  ],
                  onSubmit: (api, v) async => await api.send(
                      'POST', '$root/access-requests/${r['id']}/decisions',
                      version: r['version'],
                      key: key,
                      body: {'decision': 'DENY', ...v}) as Json);
            }, destructive: true)
          ],
          if (s.canWrite && r['state'] == 'APPROVED_PENDING_DELIVERY')
            DetailAction('撤销批准', (ctx) async {
              if (await confirmAction(ctx, '撤销批准', '撤销此访问窗口并记录审计。')) {
                await api.send(
                    'POST', '$root/access-requests/${r['id']}/revoke',
                    version: r['version'], key: requestId());
              }
            }, destructive: true)
        ]);
    } finally {
      scope.dispose();
    }
  }

  Future<void> approvalDeliveryHistory(BuildContext ctx, String id) =>
      showDialog<void>(
          context: ctx,
          builder: (dialog) => Dialog(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 940),
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(
                            child: SingleChildScrollView(
                                child: ResourcePage(
                                    api: s.api,
                                    path: '$root/access-requests/$id/documents',
                                    title: '审批文档交付历史',
                                    subtitle: '选择记录查看各次尝试与拒收原因。旧回执不会覆盖当前状态。',
                                    emptyTitle: '设备尚未获取文档',
                                    emptyDescription:
                                        '设备获取批准或撤回文档后，这里会显示签发和回执记录。',
                                    onOpen: (d) => approvalAttemptHistory(
                                        dialog, id, d['documentId']),
                                    columns: [
                              ColumnSpec('审批版本',
                                  (d) => Text('${d['approvalVersion']}')),
                              ColumnSpec('动作', (d) => Text(label(d['action']))),
                              ColumnSpec('交付 / 设备报告',
                                  (d) => Text(label(d['deliveryState']))),
                              ColumnSpec('尝试次数',
                                  (d) => Text('${d['deliveryAttempt'] ?? 1}')),
                              ColumnSpec(
                                  '适用版本',
                                  (d) =>
                                      Text(d['current'] == true ? '当前' : '历史')),
                              ColumnSpec(
                                  '签发时间',
                                  (d) =>
                                      Text(dateLabel(d['documentIssuedAt']))),
                              ColumnSpec('回执时间',
                                  (d) => Text(dateLabel(d['receivedAt']))),
                            ]))),
                        Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                                onPressed: () => Navigator.pop(dialog),
                                child: const Text('关闭')))
                      ])))));

  Future<void> approvalAttemptHistory(
          BuildContext ctx, String request, String document) =>
      showDialog<void>(
          context: ctx,
          builder: (dialog) => Dialog(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 980),
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(
                            child: SingleChildScrollView(
                                child: ResourcePage(
                                    api: s.api,
                                    path:
                                        '$root/access-requests/$request/documents/$document/attempts',
                                    title: '交付尝试记录',
                                    subtitle:
                                        '每份文档最多 10 次尝试。接收与保存是设备报告，均不代表系统执行。',
                                    emptyTitle: '暂无交付尝试',
                                    emptyDescription: '设备获取文档后会建立第一次交付记录。',
                                    columns: [
                              ColumnSpec('尝试',
                                  (a) => Text('第 ${a['deliveryAttempt']} 次')),
                              ColumnSpec('交付状态',
                                  (a) => Text(label(a['deliveryState']))),
                              ColumnSpec(
                                  '拒收原因',
                                  (a) => Text(
                                      accessRejectionLabel(a['reasonCode']))),
                              ColumnSpec(
                                  '适用记录',
                                  (a) =>
                                      Text(a['current'] == true ? '当前' : '历史')),
                              ColumnSpec('开始时间',
                                  (a) => Text(dateLabel(a['createdAt']))),
                              ColumnSpec('回执时间',
                                  (a) => Text(dateLabel(a['receivedAt']))),
                            ]))),
                        Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                                onPressed: () => Navigator.pop(dialog),
                                child: const Text('关闭')))
                      ])))));

  Future<bool> invite({Listenable? accessChanges,
      bool Function()? hasAccess}) async {
    if (!s.authenticated || s.tenant == null || !s.canManage ||
        hasAccess?.call() == false) return false;
    final capturedRoot = root;
    final kind = s.tenant!['kind'] as String, operatorRole = s.role;
    final parent = ModalRoute.of(context);
    final scope = DeviceSubflowScope(s,
        permitted: () => context.mounted && s.tenant != null &&
            hasAccess?.call() != false &&
            (parent == null || parent.isActive) &&
            s.root == capturedRoot && s.canManage && s.canOpen('members'));
    final changes = Listenable.merge([
      scope,
      if (accessChanges != null) accessChanges
    ]);
    try {
      if (!scope.current) return false;
      final children = await scope.api.all('$capturedRoot/subjects');
      final classes = kind == 'ORGANIZATION'
          ? await scope.api.all('$capturedRoot/classes')
          : <Json>[];
      if (!scope.current) return false;
      final result = await memberEditorDialog(context,
                kind: kind,
                operatorRole: operatorRole,
                accessChanges: changes,
                hasAccess: () => scope.current,
                subjects: {
                  for (final child in children)
                    if (child['archived'] != true && child['archivedAt'] == null)
                      child['id'] as String: child['nickname'] as String
                },
                classes: {
                  for (final c in classes) c['id'] as String: c['name'] as String
                },
                reauth: reauth,
                retryUncertain: false,
                onSubmit: (body, permitted) async {
                  final issued = await scope.api.send('POST', '$capturedRoot/invitations',
                      body: body, isCurrent: permitted) as Json;
                  final token = issued['token'];
                  if (token is! String || token.isEmpty) {
                    throw const ApiFailure(502, 'INVALID_RESPONSE');
                  }
                  return issued;
                },
              );
      if (!scope.current) return false;
      if (result?['reviewInvitations'] == true || result?['refresh'] == true) {
        return true;
      }
      if (result != null) {
        final token = result['token'];
        if (token is! String || token.isEmpty) {
          throw const ApiFailure(502, 'INVALID_RESPONSE');
        }
        await scopedDetailsDialog(context, '邀请已创建', {
          '说明': '请将以下一次性令牌安全传递给收件人。系统尚未发送邮件。',
          '邀请令牌': token,
          '过期时间': dateLabel(result['expiresAt'])
        }, accessChanges: changes, hasAccess: () => scope.current,
          reauth: reauth, actions: [
          DetailAction('复制令牌', (dialog) async {
                final route = ModalRoute.of(dialog);
                bool current() => scope.current && dialog.mounted &&
                    route?.isActive == true &&
                    (route is! OwnedDialogRoute<dynamic> || route.available);
                if (!current()) return;
                try {
                  await Clipboard.setData(ClipboardData(text: token));
                  if (current()) toast(context, '邀请令牌已复制。');
                } catch (_) {
                  if (current()) toast(context, '复制失败，请选中令牌手动复制。');
                }
              }, closeOnSuccess: false)
        ]);
      }
      return result != null;
    } finally {
      scope.dispose();
    }
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
                  final scope = DeviceSubflowScope(s,
                      permitted: () => context.mounted && s.tenant != null &&
                          s.root == root && s.canManage);
                  try {
                  if (!scope.current) return;
                  final result = await formDialog(context,
                      title: '编辑工作空间',
                      accessChanges: scope,
                      hasAccess: () => scope.current,
                      fields: const [
                        FieldSpec('name', '名称'),
                        FieldSpec('timeZone', '时区')
                      ],
                      initial: tenant,
                      onSubmit: (v) async => await scope.api.send('PATCH', root,
                          body: v, version: tenant['version']) as Json);
                  if (result != null && scope.current) await s.loadTenants();
                  } finally {
                    scope.dispose();
                  }
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
  OverviewSummary? data;
  Object? error;
  DateTime? refreshedAt;
  DeviceSubflowScope? _scope;
  Object? _scopeOwner;
  Object? _actionOwner;
  bool actionBusy = false, reading = false;
  bool _active = true, _rebuildPending = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(Dashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!current(_scope)) {
      load();
    }
  }

  bool current(DeviceSubflowScope? scope) =>
      scope != null &&
      mounted &&
      _active &&
      identical(_scope, scope) &&
      identical(widget.session, scope.session) &&
      scope.current;

  void _requestBuild() {
    if (!mounted || !_active || _rebuildPending) {
      return;
    }
    _rebuildPending = true;
    // Scope changes may arrive while the parent is rebuilding or disposing.
    // Revoke synchronously; render only after the tree has become writable.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildPending = false;
      if (mounted && _active) {
        setState(() {});
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _clearScopeState() {
    generation++;
    _scopeOwner = null;
    data = null;
    error = null;
    refreshedAt = null;
    reading = false;
    actionBusy = false;
    _actionOwner = null;
  }

  void _scopeChanged() {
    if (current(_scope)) {
      return;
    }
    _clearScopeState();
    _requestBuild();
  }

  void _releaseScope() {
    final previous = _scope;
    _scope = null;
    previous?.removeListener(_scopeChanged);
    previous?.dispose();
  }

  DeviceSubflowScope? _captureScope() {
    if (current(_scope)) {
      return _scope;
    }
    _releaseScope();
    _clearScopeState();
    final s = widget.session;
    if (!mounted || !_active || !s.authenticated ||
        s.tenant == null || !s.canWrite) {
      return null;
    }
    final root = s.root;
    final owner = Object();
    _scopeOwner = owner;
    final next = DeviceSubflowScope(s,
        permitted: () => mounted && _active &&
            identical(_scopeOwner, owner) &&
            identical(widget.session, s) && s.tenant != null &&
            s.root == root && s.canWrite);
    _scope = next;
    next.addListener(_scopeChanged);
    return next;
  }

  Future<void> load({bool refreshAfterAction = false}) async {
    if (!mounted || !_active || (actionBusy && !refreshAfterAction)) {
      return;
    }
    final scope = _captureScope();
    if (scope == null) {
      _requestBuild();
      return;
    }
    if (reading && !refreshAfterAction) {
      return;
    }
    final epoch = ++generation;
    final root = scope.session.root;
    reading = true;
    error = null;
    _requestBuild();
    try {
      final result = OverviewSummary.parse(
          await scope.api.send('GET', '$root/overview'));
      if (result.subjectCount == null ||
          result.activeDeviceCount == null ||
          result.connectionCheckCount == null ||
          result.policyDraftCount == null ||
          result.openHelpRequestCount == null) {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
      if (epoch == generation && current(scope)) {
        data = result;
        refreshedAt = DateTime.now();
      }
    } catch (e) {
      if (epoch == generation && current(scope)) {
        error = e;
      }
    } finally {
      if (epoch == generation && current(scope)) {
        reading = false;
        _requestBuild();
      }
    }
  }

  Future<void> perform(DeviceSubflowScope? scope,
      Future<void> Function() action) async {
    if (actionBusy || !current(scope)) {
      return;
    }
    final owner = Object();
    // A previously started refresh must not overwrite this action's outcome.
    generation++;
    reading = false;
    _actionOwner = owner;
    actionBusy = true;
    error = null;
    _requestBuild();
    try {
      await action();
      if (current(scope) && identical(_actionOwner, owner)) {
        // A read started before the action may finish afterwards. Supersede it
        // with a fresh read rather than displaying its pre-action summary.
        await load(refreshAfterAction: true);
      }
    } catch (e) {
      if (current(scope) && identical(_actionOwner, owner)) {
        error = e;
      }
    } finally {
      if (current(scope) && identical(_actionOwner, owner)) {
        _actionOwner = null;
        actionBusy = false;
        _requestBuild();
      }
    }
  }

  void open(DeviceSubflowScope? scope, String section) {
    if (actionBusy || !current(scope) ||
        !widget.session.canOpen(section)) {
      return;
    }
    context.go('/$section');
  }

  @override
  void deactivate() {
    _active = false;
    // Evaluating current also permanently revokes this capture before a
    // possible reactivation; old requests and callbacks cannot be revived.
    _scopeChanged();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    load();
  }

  @override
  void dispose() {
    _active = false;
    _clearScopeState();
    _releaseScope();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    if (!s.authenticated || s.tenant == null || !s.canWrite) {
      return const Panel(child: EmptyView('工作空间或权限已变化', '请重新打开工作台。'));
    }
    final scope = _scope;
    final visible = current(scope);
    bool canOpen(String section) =>
        visible && current(scope) && s.canOpen(section);
    return WorkbenchView(
        workspaceName: s.tenant!['name'] as String,
        role: s.role,
        organization: s.tenant!['kind'] == 'ORGANIZATION',
        summary: visible ? data : null,
        error: visible ? error : null,
        refreshedAt: visible ? refreshedAt : null,
        busy: actionBusy,
        refreshing: reading,
        canOpen: canOpen,
        onOpen: (section) => open(scope, section),
        onAddSubject: canOpen('subjects')
            ? () => perform(scope, () => widget.actions.subject())
            : null,
        onAddDevice: canOpen('devices')
            ? () => perform(scope, widget.actions.enrollment)
            : null,
        onRefresh: () async {
          if (current(scope)) {
            await load();
          }
        },
        onReauth: () {
          if (current(scope)) {
            s.login(stepUp: true);
          }
        });
  }
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
