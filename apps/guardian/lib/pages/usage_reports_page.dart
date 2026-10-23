import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../core/usage_reports.dart';
import '../core/usage_report_jobs.dart';
import '../core/wellbeing_insight.dart';
import '../core/report_job_resume.dart';
import '../core/bounded_json.dart';
import '../core/browser_json_download.dart';
import '../ui/usage_reports_view.dart';
import '../ui/usage_report_job_dialog.dart';
import '../ui/usage_report_jobs_view.dart';
import '../ui/design.dart';
import '../ui/owned_dialog_route.dart';
import 'device_subflow_scope.dart';

class UsageReportsPage extends StatefulWidget {
  final Session session;
  const UsageReportsPage({super.key, required this.session});
  @override
  State<UsageReportsPage> createState() => _UsageReportsPageState();
}

class _UsageReportsPageState extends State<UsageReportsPage>
    with WidgetsBindingObserver {
  late final Session sessionOwner;
  late final String root, role, timeZone;
  late final bool organization;
  late final DeviceSubflowScope scope;
  late final UsageReportRepository repository;
  late final UsageReportJobRepository jobs;
  late final WellbeingInsightRepository insights;
  bool showJobs = false, foreground = true;
  OwnedDialogRoute<UsageReportJob>? dialog;
  bool permitted() =>
      mounted &&
      identical(widget.session, sessionOwner) &&
      sessionOwner.tenant != null &&
      sessionOwner.root == root &&
      sessionOwner.canOpen('reports') &&
      usageReportRoles.contains(sessionOwner.role);
  bool current() => mounted && scope.current;

  void reauthenticate() {
    if (current() && foreground) sessionOwner.login(stepUp: true);
  }
  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    sessionOwner = widget.session;
    root = sessionOwner.root;
    role = sessionOwner.role;
    timeZone = sessionOwner.tenant?['timeZone'] as String? ?? 'UTC';
    organization = sessionOwner.tenant?['kind'] == 'ORGANIZATION' &&
        const {'OWNER', 'ORG_ADMIN'}.contains(role);
    scope = DeviceSubflowScope(sessionOwner, permitted: permitted);
    repository = UsageReportRepository(
        api: scope.api, root: root, current: current);
    jobs = UsageReportJobRepository(
        api: scope.api,
        root: root,
        current: () => current() && usageReportJobRoles.contains(role));
    insights = WellbeingInsightRepository(
        api: scope.api,
        root: root,
        tenantId: sessionOwner.tenant!['id'] as String,
        current: () => current() && role != 'CHILD' && foreground);
    WidgetsBinding.instance.addObserver(this);
    scope.addListener(accessChanged);
    final resume = sessionOwner.takeReportResume();
    if (resume != null && jobs.current()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && current()) {
          createJob(resume.draft, requestKey: resume.requestKey);
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant UsageReportsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!current()) closeDialog();
  }

  void closeDialog() {
    final route = dialog;
    dialog = null;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      route.finish();
    });
  }

  void accessChanged() {
    if (!current()) closeDialog();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) closeDialog();
  }

  @override
  void dispose() {
    scope.removeListener(accessChanged);
    scope.dispose();
    closeDialog();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> createJob(UsageReportJobDraft draft,
      {String? requestKey}) async {
    if (!jobs.current() || !foreground || dialog != null ||
        ModalRoute.of(context)?.isCurrent == false) return;
    late final OwnedDialogRoute<UsageReportJob> route;
    route = OwnedDialogRoute<UsageReportJob>(
        context: context,
        barrierDismissible: false,
        builder: (_) => UsageReportJobDialog(
            repository: jobs,
            draft: draft,
            requestKey: requestKey,
            accessChanges: scope,
            hasAccess: () => current() && foreground &&
                identical(dialog, route) && route.available,
            onReauth: (draft, key) {
              if (jobs.current() && foreground && identical(dialog, route) &&
                  route.available) {
                sessionOwner.reauthenticateReport(ReportJobResume(draft, key));
              }
            },
            onCreated: (job) {
              if (jobs.current() && foreground && identical(dialog, route) &&
                  route.available) {
                route.finish(job);
              }
            }));
    dialog = route;
    try {
      final created = await presentOwnedDialog(context, route);
      if (created != null && jobs.current() && foreground &&
          identical(dialog, route)) {
        setState(() => showJobs = true);
      }
    } finally {
      if (identical(dialog, route)) dialog = null;
    }
  }

  Future<UsageReportTarget> resultTarget(UsageReportJobPart part) async {
    final value = await boundedJson(
        scope.api, 'GET', '$root/devices/${part.deviceId}',
        ensureCurrent: jobs.ensureCurrent);
    if (value is! Json ||
        value['id'] != part.deviceId ||
        value['registrationId'] != part.registrationId ||
        value['subjectId'] != part.subjectId ||
        value['state'] != 'ACTIVE' ||
        value['displayName'] is! String ||
        value['platform'] is! String) {
      throw const ApiFailure(409, 'REPORT_SCOPE_CHANGED');
    }
    final target = UsageReportTarget(value['id'], value['registrationId'],
        value['subjectId'], value['displayName'],
        platform: value['platform']);
    if (!target.valid) {
      throw const ApiFailure(502, 'INVALID_USAGE_REPORT_RESPONSE');
    }
    return target;
  }

  Future<List<UsageReportTarget>> targets() async {
    repository.ensureCurrent();
    final values = await Future.wait([
      scope.api.all('$root/devices'),
      scope.api.all('$root/subjects')
    ]);
    repository.ensureCurrent();
    final names = {
      for (final subject in values[1]) subject['id']: subject['nickname']
    };
    final result = <UsageReportTarget>[];
    for (final device in values[0].where((d) => d['state'] == 'ACTIVE')) {
      if (device['id'] is! String ||
          device['registrationId'] is! String ||
          device['subjectId'] is! String ||
          device['platform'] is! String ||
          device['displayName'] is! String) {
        throw const ApiFailure(502, 'INVALID_USAGE_REPORT_RESPONSE');
      }
      result.add(UsageReportTarget(
          device['id'],
          device['registrationId'],
          device['subjectId'],
          '${device['displayName']} · ${names[device['subjectId']] ?? '未命名档案'}',
          platform: device['platform']));
    }
    return List.unmodifiable(result);
  }

  Future<List<UsageReportScope>> scopes() async {
    repository.ensureCurrent();
    final values = await Future.wait([
      scope.api.all('$root/subjects'),
      organization
          ? scope.api.all('$root/classes')
          : Future.value(<Json>[])
    ]);
    repository.ensureCurrent();
    try {
      return [
        for (final s in values[0])
          UsageReportScope(
              kind: 'SUBJECT', id: s['id'], label: '儿童 · ${s['nickname']}'),
        for (final c in values[1].where((c) => c['state'] == 'ACTIVE'))
          UsageReportScope(
              kind: 'CLASS',
              id: c['id'],
              version: c['version'],
              label: '班级 · ${c['name']}')
      ];
    } catch (_) {
      throw const ApiFailure(502, 'INVALID_USAGE_REPORT_RESPONSE');
    }
  }

  Future<UsageReportScope> resolveScope(UsageReportScope selection) async {
    repository.ensureCurrent();
    final members =
        await scope.api.all('$root/classes/${selection.id}/students');
    final currentClass =
        await scope.api.send('GET', '$root/classes/${selection.id}');
    repository.ensureCurrent();
    if (currentClass is! Json ||
        currentClass['id'] != selection.id ||
        currentClass['state'] != 'ACTIVE' ||
        currentClass['version'] != selection.version) {
      throw const ApiFailure(409, 'REPORT_SCOPE_CHANGED');
    }
    try {
      return UsageReportScope(
          kind: selection.kind,
          id: selection.id,
          version: selection.version,
          label: selection.label,
          subjectIds: members
              .where((s) => s['archived'] != true)
              .map((s) => s['id'] as String));
    } catch (_) {
      throw const ApiFailure(502, 'INVALID_USAGE_REPORT_RESPONSE');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: scope,
      builder: (_, __) => current()
          ? buildContent(context)
          : const Panel(
              child: EmptyView('工作空间或权限已变化', '已隐藏旧报表，请重新打开使用报表。')));

  Widget buildContent(BuildContext context) => showJobs &&
          usageReportJobRoles.contains(role)
      ? UsageReportJobsView(
          repository: jobs,
          resolveTarget: resultTarget,
          loadTargets: targets,
          saveFile: (bytes, name) => saveBrowserJson(bytes, name, () {
                jobs.ensureCurrent();
                if (!foreground) {
                  throw const ApiFailure(409, 'WORKSPACE_CHANGED');
                }
              }),
          accessChanges: scope,
          reauth: reauthenticate,
          onQuery: () {
            if (current() && foreground) setState(() => showJobs = false);
          })
      : UsageReportsView(
          repository: repository,
          loadTargets: targets,
          loadScopes: scopes,
          resolveScope: resolveScope,
          timeZone: timeZone,
          accessChanges: scope,
          onBackground: usageReportJobRoles.contains(role) ? createJob : null,
          onJobs: usageReportJobRoles.contains(role)
              ? () {
                  if (current() && foreground) setState(() => showJobs = true);
                }
              : null,
          onReviewRules: sessionOwner.canWrite
              ? () {
                  if (current() && foreground && sessionOwner.canOpen('policies')) {
                    context.go('/policies');
                  }
                }
              : null,
          onCheckDevice: sessionOwner.canWrite
              ? () {
                  if (current() && foreground && sessionOwner.canOpen('devices')) {
                    context.go('/devices');
                  }
                }
              : null,
          loadInsight: role == 'CHILD' ? null : insights.load,
          reauth: reauthenticate);
}
