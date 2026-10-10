import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/session.dart';
import '../core/usage_reports.dart';
import '../core/usage_report_jobs.dart';
import '../core/report_job_resume.dart';
import '../core/bounded_json.dart';
import '../core/browser_json_download.dart';
import '../ui/usage_reports_view.dart';
import '../ui/usage_report_job_dialog.dart';
import '../ui/usage_report_jobs_view.dart';

class UsageReportsPage extends StatefulWidget {
  final Session session;
  const UsageReportsPage({super.key, required this.session});
  @override
  State<UsageReportsPage> createState() => _UsageReportsPageState();
}

class _UsageReportsPageState extends State<UsageReportsPage>
    with WidgetsBindingObserver {
  late final String root, role, actor;
  late final UsageReportRepository repository;
  late final UsageReportJobRepository jobs;
  bool showJobs = false, foreground = true;
  ModalRoute<dynamic>? dialog;
  bool current() =>
      widget.session.authenticated &&
      widget.session.tenant != null &&
      widget.session.root == root &&
      widget.session.role == role &&
      widget.session.profile?['subject'] == actor &&
      usageReportRoles.contains(role);
  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    root = widget.session.root;
    role = widget.session.role;
    actor = widget.session.profile!['subject'];
    repository = UsageReportRepository(
        api: widget.session.api, root: root, current: current);
    jobs = UsageReportJobRepository(
        api: widget.session.api,
        root: root,
        current: () => current() && usageReportJobRoles.contains(role));
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(accessChanged);
    final resume = widget.session.takeReportResume();
    if (resume != null && jobs.current()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && current()) {
          createJob(resume.draft, requestKey: resume.requestKey);
        }
      });
    }
  }

  void closeDialog() {
    final route = dialog;
    dialog = null;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) route.navigator!.removeRoute(route);
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
    closeDialog();
    widget.session.removeListener(accessChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> createJob(UsageReportJobDraft draft,
      {String? requestKey}) async {
    if (!jobs.current() || !foreground || dialog != null) return;
    final created = await showDialog<UsageReportJob>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          dialog = ModalRoute.of(context);
          return UsageReportJobDialog(
              repository: jobs,
              draft: draft,
              requestKey: requestKey,
              accessChanges: widget.session,
              onReauth: (draft, key) => widget.session
                  .reauthenticateReport(ReportJobResume(draft, key)),
              onCreated: (job) {
                if (mounted &&
                    current() &&
                    foreground &&
                    dialog?.isActive == true) Navigator.pop(context, job);
              });
        });
    dialog = null;
    if (created != null && mounted && jobs.current() && foreground) {
      setState(() => showJobs = true);
    }
  }

  Future<UsageReportTarget> resultTarget(UsageReportJobPart part) async {
    final value = await boundedJson(
        widget.session.api, 'GET', '$root/devices/${part.deviceId}',
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
      widget.session.api.all('$root/devices'),
      widget.session.api.all('$root/subjects')
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
    final organization = widget.session.tenant?['kind'] == 'ORGANIZATION' &&
        const {'OWNER', 'ORG_ADMIN'}.contains(role);
    final values = await Future.wait([
      widget.session.api.all('$root/subjects'),
      organization
          ? widget.session.api.all('$root/classes')
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
        await widget.session.api.all('$root/classes/${selection.id}/students');
    final currentClass =
        await widget.session.api.send('GET', '$root/classes/${selection.id}');
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
  Widget build(BuildContext context) => showJobs &&
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
          accessChanges: widget.session,
          reauth: () => widget.session.login(stepUp: true),
          onQuery: () => setState(() => showJobs = false))
      : UsageReportsView(
          repository: repository,
          loadTargets: targets,
          loadScopes: scopes,
          resolveScope: resolveScope,
          timeZone: widget.session.tenant?['timeZone'] as String? ?? 'UTC',
          accessChanges: widget.session,
          onBackground: usageReportJobRoles.contains(role) ? createJob : null,
          onJobs: usageReportJobRoles.contains(role)
              ? () => setState(() => showJobs = true)
              : null,
          reauth: () => widget.session.login(stepUp: true));
}
