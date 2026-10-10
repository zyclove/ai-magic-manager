import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/support.dart';
import '../core/diagnostic_package.dart';
import '../core/diagnostic_package_repository.dart';
import 'support_view_state.dart';

class DiagnosticPackagesView extends StatefulWidget {
  final DiagnosticPackageRepository repository;
  final bool Function() current;
  final Listenable? accessChanges;
  final DiagnosticPackageDraft? target;
  final String targetLabel;
  final VoidCallback onClose, onReauth;
  final Future<void> Function(Uint8List, String, void Function()) save;
  const DiagnosticPackagesView(
      {super.key,
      required this.repository,
      required this.current,
      this.accessChanges,
      this.target,
      this.targetLabel = '当前设备',
      required this.onClose,
      required this.onReauth,
      required this.save});
  @override
  State<DiagnosticPackagesView> createState() => _DiagnosticPackagesViewState();
}

class _DiagnosticPackagesViewState extends State<DiagnosticPackagesView>
    with SupportViewState<DiagnosticPackagesView> {
  bool confirmed = false, following = false, loaded = false;
  int lastPoll = 0, ticks = 0;
  DiagnosticPackageDraft? pendingCreate;
  ({DiagnosticPackage job, String key})? pendingCancel;
  DiagnosticPackage? focused;
  List<DiagnosticPackage> jobs = [];
  String? cursor, confirmingId, notice;
  bool get pendingWrite => pendingCreate != null || pendingCancel != null;
  bool get enabled => usable && !busy && !pendingWrite;
  @override
  bool Function() get scopeCurrent => widget.current;
  @override
  Listenable? get accessChanges => widget.accessChanges;
  @override
  Object get scopeIdentity => (
        widget.repository.actor,
        widget.repository.tenant,
        widget.repository.received,
        widget.target?.deviceId,
        widget.target?.registrationId,
        widget.target?.deviceVersion,
        widget.target?.grantId,
        widget.target?.diagnosticTypes.join(',')
      );
  @override
  void clearSensitive() {
    confirmed = following = loaded = false;
    pendingCreate = null;
    pendingCancel = null;
    focused = null;
    jobs = [];
    cursor = confirmingId = notice = null;
    lastPoll = 0;
  }

  @override
  void timeChanged() {
    ticks++;
    if (following &&
        !busy &&
        !pendingWrite &&
        focused != null &&
        focused!.pendingAt(now) &&
        ticks - lastPoll >= 5) {
      refresh(focused!);
    } else {
      setState(() {
        if (focused?.pendingAt(now) != true) following = false;
      });
    }
  }

  void validate(DiagnosticPackage job) {
    if (focused?.id == job.id) focused!.validateUpdate(job);
    for (final old in jobs) {
      if (old.id == job.id) old.validateUpdate(job);
    }
  }

  void accept(DiagnosticPackage job, {bool focus = false}) {
    validate(job);
    jobs = jobs.map((old) => old.id == job.id ? job : old).toList();
    if (focus || focused?.id == job.id) focused = job;
  }

  void create() {
    if (!usable ||
        busy ||
        pendingCancel != null ||
        widget.target == null ||
        (!confirmed && pendingCreate == null)) return;
    final target = widget.target!;
    pendingCreate ??= target.grant == null
        ? DiagnosticPackageDraft.admin(
            deviceId: target.deviceId,
            registrationId: target.registrationId,
            deviceVersion: target.deviceVersion!)
        : DiagnosticPackageDraft.received(target.grant!);
    notice = null;
    perform(() => widget.repository.create(pendingCreate!), (job) {
      accept(job, focus: true);
      pendingCreate = null;
      confirmed = false;
      following = job.pendingAt(now);
      lastPoll = ticks;
    }, failed: (failure) {
      following = false;
      if (!ambiguousSupportFailure(failure)) {
        pendingCreate = null;
        confirmed = false;
      }
    });
  }

  void load({bool more = false}) {
    if (!enabled || (more && cursor == null)) return;
    final after = more ? cursor : null;
    perform(() => widget.repository.list(cursor: after), (page) {
      for (final job in page.items) {
        validate(job);
        if (more && jobs.any((old) => old.id == job.id))
          invalidDiagnosticPackage();
      }
      for (final job in page.items) {
        if (focused?.id == job.id) focused = job;
      }
      jobs = more ? [...jobs, ...page.items] : page.items;
      cursor = page.nextCursor;
      loaded = true;
      if (focused?.pendingAt(now) != true) following = false;
    });
  }

  void refresh(DiagnosticPackage job) {
    if (!enabled) return;
    lastPoll = ticks;
    perform(() => widget.repository.get(job.id), (next) {
      job.validateUpdate(next);
      accept(next, focus: true);
      following = next.pendingAt(now);
    }, failed: (_) => following = false);
  }

  void cancel(DiagnosticPackage job) {
    if (!usable || busy || pendingCreate != null) return;
    pendingCancel ??= (job: job, key: requestId());
    notice = null;
    final request = pendingCancel!;
    perform(() => widget.repository.cancel(request.job, request.key), (next) {
      accept(next);
      pendingCancel = null;
      confirmingId = null;
      if (focused?.id == next.id) following = false;
    }, failed: (failure) {
      following = false;
      if (!ambiguousSupportFailure(failure)) {
        pendingCancel = null;
        confirmingId = null;
      }
    });
  }

  void download(DiagnosticPackage job) {
    if (!enabled) return;
    notice = null;
    perform(() async {
      final expected = generation;
      final result = await widget.repository.download(job);
      void ensure() {
        if (!usable || generation != expected)
          throw const ApiFailure(409, 'WORKSPACE_CHANGED');
        widget.repository.ensureCurrent();
        if (!result.job.readyAt(now))
          throw const ApiFailure(410, 'DIAGNOSTIC_PACKAGE_EXPIRED');
      }

      ensure();
      validate(result.job);
      await widget.save(
          result.bytes, 'device-diagnostic-${result.job.id}.json', ensure);
      ensure();
      return result.job;
    }, (next) {
      accept(next);
      notice = '已交给浏览器保存，请查看下载列表。';
    });
  }

  Widget types(List<String> values) => Wrap(
      spacing: 8,
      runSpacing: 4,
      children: values
          .map((type) => Chip(label: Text(supportTypeLabels[type] ?? type)))
          .toList());
  Widget card(DiagnosticPackage job) => Card(
      semanticContainer: false,
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Semantics(
                liveRegion: true,
                child: Text(diagnosticPackageState(job.stateAt(now)),
                    style: Theme.of(context).textTheme.titleMedium)),
            const SizedBox(height: 8),
            types(job.diagnosticTypes),
            Text('创建：${supportTime(job.createdAt)}'),
            Text('到期：${supportTime(job.expiresAt)}'),
            if (job.readyAt(now)) Text('文件大小：${job.byteCount} 字节 · JSON'),
            if (job.state == 'FAILED') const Text('本次生成未完成。可重新发起生成；原任务仍保留记录。'),
            if (following && focused?.id == job.id && job.pendingAt(now))
              const Text('正在跟踪此任务，每 5 秒刷新一次。离开页面后停止。'),
            ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('查看任务与设备标识'),
                expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  supportFact(context, '任务标识', job.id),
                  supportFact(context, '设备标识', job.deviceId),
                  supportFact(context, '注册标识', job.registrationId),
                  if (job.grantId != null)
                    supportFact(context, '授权标识', job.grantId!),
                  if (job.sha256 != null)
                    supportFact(context, '文件校验摘要（SHA-256）', job.sha256!),
                ]),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (job.readyAt(now))
                FilledButton.icon(
                    onPressed: enabled ? () => download(job) : null,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('下载 JSON')),
              OutlinedButton(
                  onPressed: enabled ? () => refresh(job) : null,
                  child: const Text('刷新此任务')),
              if (job.activeAt(now) && confirmingId != job.id)
                TextButton(
                    onPressed: enabled
                        ? () => setState(() => confirmingId = job.id)
                        : null,
                    child: const Text('取消并清除')),
            ]),
            if (confirmingId == job.id && job.activeAt(now)) ...[
              const SizedBox(height: 8),
              const Text('确认取消任务并清除服务器上的文件？已保存到本地的副本无法收回。'),
              Wrap(spacing: 8, children: [
                FilledButton(
                    onPressed: enabled ? () => cancel(job) : null,
                    child: const Text('确认取消并清除')),
                TextButton(
                    onPressed: enabled
                        ? () => setState(() => confirmingId = null)
                        : null,
                    child: const Text('保留任务')),
              ])
            ]
          ])));
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
              child:
                  Text('诊断包', style: Theme.of(context).textTheme.titleLarge)),
          IconButton(
              tooltip: '关闭诊断包',
              onPressed: widget.onClose,
              icon: const Icon(Icons.close))
        ]),
        if (!usable)
          Expanded(
              child: Center(
                  child: Text(invalidated || !widget.current()
                      ? '账号或权限已变化，请关闭后重新打开。'
                      : '已进入后台，任务和临时状态已清除。')))
        else
          Expanded(
              child: SingleChildScrollView(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                const Text('诊断包在服务器加密保存，最长保留 30 分钟；授权先到期时提前失效。所有时间按本机时区显示。'),
                if (cleared)
                  const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('为保护设备信息，临时状态已清除。请手动刷新任务列表。')),
                if (widget.target != null) ...[
                  const SizedBox(height: 16),
                  Text(widget.targetLabel,
                      style: Theme.of(context).textTheme.titleMedium),
                  types(widget.target!.diagnosticTypes),
                  const Text('仅包含上方范围内的诊断字段。下载文件为 JSON，请妥善保存；已下载的副本无法远程收回。'),
                  CheckboxListTile(
                      key: const ValueKey('package-confirm'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('我已确认诊断范围与下载后的保存责任'),
                      value: confirmed,
                      onChanged: enabled
                          ? (value) => setState(() => confirmed = value == true)
                          : null),
                  Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                          onPressed: enabled && confirmed ? create : null,
                          icon: const Icon(Icons.note_add_outlined),
                          label: const Text('生成诊断包'))),
                ] else
                  const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('这里显示当前账号发起的任务。生成新诊断包，请从设备详情或收到的有效授权进入。')),
                if (focused != null) card(focused!),
                const SizedBox(height: 20),
                Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('我的任务',
                          style: Theme.of(context).textTheme.titleMedium),
                      OutlinedButton.icon(
                          onPressed: enabled ? () => load() : null,
                          icon: const Icon(Icons.refresh),
                          label: const Text('刷新任务列表'))
                    ]),
                if (loaded && jobs.isEmpty)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('暂无诊断包任务。')),
                for (final job in jobs)
                  if (job.id != focused?.id) card(job),
                if (cursor != null)
                  TextButton(
                      onPressed: enabled ? () => load(more: true) : null,
                      child: const Text('加载更多任务')),
              ]))),
        if (usable) ...[
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            supportFailure(error!, widget.onReauth,
                message: diagnosticPackageError(error!)),
          if (notice != null) Semantics(liveRegion: true, child: Text(notice!)),
          if (!busy && pendingCreate != null)
            FilledButton(onPressed: create, child: const Text('按原请求重试生成')),
          if (!busy && pendingCancel != null)
            FilledButton(
                onPressed: () => cancel(pendingCancel!.job),
                child: const Text('按原请求重试取消')),
        ]
      ]));
}
