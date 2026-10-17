import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/api.dart';
import '../core/labels.dart';
import '../core/managed_application_evidence.dart';
import 'design.dart';
import 'managed_application_evidence_controller.dart';

/// A current binding's application check. The host owns the controller,
/// authentication handoff, parent refresh and the route's safe completion.
class ManagedApplicationEvidenceDialog extends StatefulWidget {
  final ManagedApplicationEvidenceController controller;
  final VoidCallback onClose;
  final VoidCallback reauthenticate;
  final VoidCallback? onParentRefresh;

  const ManagedApplicationEvidenceDialog({
    super.key,
    required this.controller,
    required this.onClose,
    required this.reauthenticate,
    this.onParentRefresh,
  });

  @override
  State<ManagedApplicationEvidenceDialog> createState() =>
      _ManagedApplicationEvidenceDialogState();
}

class _ManagedApplicationEvidenceDialogState
    extends State<ManagedApplicationEvidenceDialog> {
  final search = TextEditingController();
  final scroll = ScrollController();
  bool closing = false;
  bool frameRefreshScheduled = false;
  int generation = 0;
  ManagedApplicationEvidenceController get c => widget.controller;

  VoidCallback guarded(VoidCallback action) {
    final owner = c, ticket = generation;
    return () {
      if (mounted && generation == ticket && identical(c, owner)) {
        action();
      }
    };
  }

  ValueChanged<T> guardedValue<T>(ValueChanged<T> action) {
    final owner = c, ticket = generation;
    return (value) {
      if (mounted && generation == ticket && identical(c, owner)) {
        action(value);
      }
    };
  }

  bool get canAct =>
      mounted &&
      !closing &&
      c.hasAccess &&
      ModalRoute.of(context)?.isCurrent == true &&
      ModalRoute.of(context)?.isActive == true;

  bool get canChoose => c.canChoose;

  @override
  void initState() {
    super.initState();
    c.addListener(changed);
    loadInitialCatalog();
  }

  void loadInitialCatalog() {
    final owner = c, ticket = generation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !closing &&
          generation == ticket &&
          identical(c, owner) &&
          owner.hasAccess) {
        unawaited(owner.loadApplications());
      }
    });
  }

  @override
  void didUpdateWidget(covariant ManagedApplicationEvidenceDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != c) {
      generation++;
      frameRefreshScheduled = false;
      oldWidget.controller.removeListener(changed);
      c.addListener(changed);
      search.clear();
      closing = false;
      loadInitialCatalog();
    }
  }

  void changed() {
    if (!mounted) {
      return;
    }
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (frameRefreshScheduled) return;
      frameRefreshScheduled = true;
      final owner = c, ticket = generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != ticket || !identical(c, owner)) return;
        frameRefreshScheduled = false;
        changed();
      });
      return;
    }
    if (!c.hasAccess || c.needsParentRefresh) {
      search.clear();
    }
    setState(() {});
  }

  @override
  void dispose() {
    closing = true;
    generation++;
    c.removeListener(changed);
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  void close() {
    // The injected callback finishes only this OwnedDialogRoute, including
    // when an unrelated notice has become the current route above it.
    if (!mounted || closing) {
      return;
    }
    setState(() => closing = true);
    widget.onClose();
  }

  void reauthenticate() {
    if (!canAct || c.busy || !c.needsReauth) {
      return;
    }
    setState(() => closing = true);
    widget.reauthenticate();
  }

  void refreshParent() {
    if (!canAct ||
        c.busy ||
        !c.needsParentRefresh ||
        widget.onParentRefresh == null) {
      return;
    }
    setState(() => closing = true);
    widget.onParentRefresh!();
  }

  void choose(ManagedEvidenceApplication application) {
    if (!canAct || !canChoose) {
      return;
    }
    unawaited(c.selectApplication(application));
  }

  void primary(ManagedEvidenceApplication application, {required bool read}) {
    if (!canAct || c.busy || !identical(c.selected, application)) {
      return;
    }
    if (read) {
      if (c.canCheck) {
        unawaited(c.check());
      }
    } else if (c.canRefresh) {
      unawaited(c.refresh());
    }
  }

  void loadMore() {
    if (canAct && canChoose && c.nextCursor != null) {
      unawaited(c.loadMore());
    }
  }

  void reloadCatalog() {
    if (canAct && canChoose && c.selected == null) {
      unawaited(c.loadApplications());
    }
  }

  String timeLabel(int? value) {
    if (value == null) {
      return '尚无';
    }
    try {
      return dateLabel(value);
    } on RangeError {
      return '时间超出显示范围';
    }
  }

  String stateTitle(String state) => switch (state) {
        'VERIFIED_IDENTITY' => '应用身份已核验',
        'PENDING' => '正在核验',
        'WAITING_REPORT' => '等待可信报告',
        'FAILED' => '本次核验未完成',
        'REJECTED' => '本次核验未通过',
        'STALE' => '核验已过期',
        _ => '尚未核验',
      };

  String stateDetail(ManagedApplicationEvidence value, String state) {
    if (state == 'VERIFIED_IDENTITY') {
      return value.systemControlAvailable
          ? '已取得当前应用的身份与具体操作范围；不代表限制已生效。完成后请重新生成策略预览，发布后的结果仍需设备确认。'
          : '应用身份已核验，控制能力待确认。当前结果不能用于推定系统限制或权限控制已生效。';
    }
    return switch (state) {
      'PENDING' => '核验请求已登记，请稍后查询结果。等待或冷却到期不会自动再次核验。',
      'WAITING_REPORT' => '暂未取得可使用的应用报告。缺少报告不代表应用未安装，请检查设备联网和提供方接入后查询或重新核验。',
      'FAILED' => '暂时未取得完整的核验结果，可查询当前记录，或在允许时间后重新核验。',
      'REJECTED' => '收到的报告未通过当前身份或接入条件校验，未展示可尝试的系统操作。',
      'STALE' => '原结果已到期或上下文已变化。旧操作范围已隐藏，请重新核验当前设备与应用。',
      _ => '此设备与应用尚无核验结果。选择“开始核验”后，由服务端读取可信提供方报告。',
    };
  }

  String? reasonDetail(String code) => switch (code) {
        'MANAGED_APPLICATION_REPORT_MISSING' => '提供方尚未返回可信应用报告。',
        'MANAGED_APPLICATION_PROVIDER_UNAVAILABLE' => '设备提供方暂时不可用。',
        'MANAGED_APPLICATION_PROFILE_UNVERIFIED' => '应用身份有效，但当前用户空间尚未满足系统控制要求。',
        'MANAGED_APPLICATION_PLATFORM_MISMATCH' => '应用目录中的平台与当前设备不一致。',
        'MANAGED_APPLICATION_CONNECTOR_UNSUPPORTED' => '当前提供方尚未接入此应用的核验能力。',
        'EMM_DEVICE_IDENTITY_CHANGED' ||
        'MANAGED_APPLICATION_CONTEXT_CHANGED' =>
          '设备身份或关联资料已变化，请返回关联详情重新核对。',
        'MANAGED_APPLICATION_ATTEMPT_EXPIRED' => '这次核验尝试已到期，需要重新发起。',
        'MANAGED_APPLICATION_STORED_EVIDENCE_INVALID' =>
          '保存的核验资料未通过校验，已隐藏操作范围。',
        _ => null,
      };

  String errorDetail(Object error) {
    if (c.unknownOutcome) {
      return '上次核验结果尚未确认。请先查询核验结果；不会自动重发核验请求。';
    }
    if (error is! ApiFailure) {
      return '暂时未能完成操作，请先查询当前记录后再决定是否重新核验。';
    }
    return switch (error.status) {
      401 => '此操作需要近期多因素认证，请主动完成安全验证后重新进入。',
      429 => '当前核验请求较多。请先查询核验结果，按服务端返回的允许时间再操作。',
      _ => switch (error.code) {
          'INVALID_MANAGED_APPLICATION_EVIDENCE_RESPONSE' =>
            '返回的核验资料未通过校验，旧结果已隐藏。请查询当前记录。',
          'INVALID_MANAGED_APPLICATION_CATALOG_RESPONSE' =>
            '应用目录未通过校验，请重新加载目录或联系管理员。',
          'MANAGED_APPLICATION_CONTEXT_CHANGED' => '设备与应用的核验条件已变化，请返回关联详情重新核对。',
          _ => '暂时未能完成操作，请查询当前记录后重试。',
        },
    };
  }

  Widget catalog() {
    final query = search.text.trim().toLowerCase();
    final visible = c.items.where((application) =>
        query.isEmpty ||
        application.displayName.toLowerCase().contains(query) ||
        application.packageName.toLowerCase().contains(query));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('1 选择应用', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      const Text('目录登记不代表设备已安装，也不代表签名或控制能力已核验。'),
      const SizedBox(height: 12),
      TextField(
          key: const Key('managed-evidence-search'),
          controller: search,
          enabled: !closing && canChoose,
          onChanged: guardedValue<String>((_) {
            if (canAct) {
              setState(() {});
            }
          }),
          decoration: InputDecoration(
              labelText: '搜索已加载的应用',
              helperText: '按应用名称或包名查找；更多目录可在下方加载。',
              helperMaxLines: 4,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除应用搜索',
                      onPressed: closing
                          ? null
                          : guarded(() {
                              if (canAct) {
                                setState(search.clear);
                              }
                            }),
                      icon: const Icon(Icons.close)))),
      const SizedBox(height: 8),
      if (visible.isEmpty && !c.busy && c.error == null)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(query.isEmpty
                ? '应用目录中还没有可选择的 Android 应用，请先完善机构应用目录。'
                : '已加载目录中没有匹配应用，请更换关键词或加载更多目录。')),
      for (final application in visible)
        RadioListTile<String>(
            key: ValueKey('managed-evidence-application-${application.id}'),
            contentPadding: EdgeInsets.zero,
            title: Text(application.displayName),
            subtitle: Text(application.packageName),
            value: application.id,
            groupValue: c.selected?.id,
            onChanged: !closing && canChoose
                ? guardedValue<String?>((_) => choose(application))
                : null),
      if (c.nextCursor != null)
        TextButton(
            key: const Key('managed-evidence-load-more'),
            onPressed: !closing && canChoose ? guarded(loadMore) : null,
            child: const Text('加载更多应用')),
    ]);
  }

  Widget evidence(ManagedApplicationEvidence value, DateTime now) {
    final state = value.stateAt(now);
    final control = value.controlAt(now);
    final reason = reasonDetail(value.reasonCode);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 20),
      Text('2 查看核验结果', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 10),
      Container(
          key: const Key('managed-evidence-status'),
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: state == 'VERIFIED_IDENTITY'
                  ? const Color(0xffeff9f3)
                  : const Color(0xfff2f6fc),
              borderRadius: BorderRadius.circular(12)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(stateTitle(state),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(stateDetail(value, state)),
            if (reason != null) ...[
              const SizedBox(height: 8),
              Text(reason),
            ],
            if (value.retrievedAt != null) ...[
              const SizedBox(height: 12),
              Text('核验时间 ${timeLabel(value.retrievedAt)}'),
            ],
            if (value.expiresAt != null)
              Text('有效至 ${timeLabel(value.expiresAt)}'),
            if (value.nextRefreshAt != null &&
                value.nextRefreshAt! > now.millisecondsSinceEpoch) ...[
              const SizedBox(height: 8),
              Text('下次允许核验 ${timeLabel(value.nextRefreshAt)}'),
              const Text('仍可查询现有结果；查询不会延长有效期。'),
            ],
          ])),
      if (control != null && control.operations.isNotEmpty) ...[
        const SizedBox(height: 8),
        ExpansionTile(
            key: const Key('managed-evidence-operations'),
            tilePadding: EdgeInsets.zero,
            title: const Text('查看当前可尝试的操作范围'),
            subtitle: Text('${control.operations.length} 项已核验操作'),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            childrenPadding: const EdgeInsets.only(bottom: 12),
            children: [
              const Text('仅适用于当前设备、应用和有效期，仍需策略预览及设备执行回执确认。'),
              const SizedBox(height: 8),
              for (final operation in control.operations)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(operation.label)),
            ]),
      ],
    ]);
  }

  Widget body(DateTime now, bool access) {
    if (closing) {
      return const Text('正在关闭应用核验…');
    }
    if (!access) {
      return const Notice('权限已变化，当前应用核验已失效。请关闭窗口，在当前工作空间重新进入。', warning: true);
    }
    if (c.needsParentRefresh) {
      return const Notice('关联已变化，旧应用结果已隐藏。请返回并刷新关联记录，再重新进入应用核验。',
          warning: true);
    }
    final value = c.evidence;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      catalog(),
      if (c.busy) ...[
        const SizedBox(height: 12),
        Semantics(liveRegion: true, child: const Text('正在读取或核验，请稍候…')),
        const SizedBox(height: 8),
        const LinearProgressIndicator(),
      ],
      if (value != null) evidence(value, now),
      if (c.error != null) ...[
        const SizedBox(height: 12),
        Semantics(
            liveRegion: true,
            child: Notice(errorDetail(c.error!), warning: true)),
        if (c.selected == null && !c.needsReauth && !c.busy)
          TextButton(
              onPressed: guarded(reloadCatalog), child: const Text('重新加载目录')),
      ],
      if (c.selected == null && !c.busy && c.error == null) ...[
        const SizedBox(height: 12),
        const Text('选择应用后读取现有核验状态；只有点击核验按钮才会向提供方申请新核验。'),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final access = c.hasAccess;
    final now = c.clock();
    final selected = c.selected;
    final queryOnly = c.unknownOutcome ||
        c.evidence?.state == 'PENDING' ||
        (c.error is ApiFailure && (c.error as ApiFailure).status == 429) ||
        c.evidence == null;
    final ready = !closing && access && !c.busy;
    final primaryLabel = queryOnly
        ? '查询核验结果'
        : c.evidence?.state == 'ABSENT'
            ? '开始核验'
            : '重新核验';
    final height = (MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).bottom -
            48)
        .clamp(120.0, double.infinity);
    return PopScope(
        canPop: !c.busy,
        onPopInvoked: guardedValue<bool>((didPop) {
          if (didPop) {
            // The host observes Route.popped; discard the closing view's callbacks.
            closing = true;
            generation++;
          }
        }),
        child: Dialog(
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
            child: ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: 720, maxHeight: height.toDouble()),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                          child: Text('应用核验',
                              style: Theme.of(context).textTheme.titleLarge)),
                      Flexible(
                          child: Scrollbar(
                              controller: scroll,
                              thumbVisibility: true,
                              child: SingleChildScrollView(
                                  controller: scroll,
                                  padding:
                                      const EdgeInsets.fromLTRB(20, 0, 20, 16),
                                  child: body(now, access)))),
                      const Divider(height: 1),
                      Padding(
                          padding: const EdgeInsets.all(12),
                          child: Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                TextButton(
                                    key: const Key('managed-evidence-close'),
                                    onPressed: closing ? null : guarded(close),
                                    child: const Text('关闭')),
                                if (access && c.needsParentRefresh)
                                  FilledButton(
                                      key: const Key(
                                          'managed-evidence-parent-refresh'),
                                      onPressed: ready &&
                                              widget.onParentRefresh != null
                                          ? guarded(refreshParent)
                                          : null,
                                      child: const Text('返回并刷新关联'))
                                else if (access && c.needsReauth)
                                  FilledButton(
                                      key: const Key('managed-evidence-reauth'),
                                      onPressed: ready
                                          ? guarded(reauthenticate)
                                          : null,
                                      child: const Text('重新安全验证'))
                                else if (access && selected != null) ...[
                                  if (!queryOnly)
                                    OutlinedButton(
                                        key:
                                            const Key('managed-evidence-query'),
                                        onPressed: ready && c.canCheck
                                            ? guarded(() =>
                                                primary(selected, read: true))
                                            : null,
                                        child: const Text('查询当前状态')),
                                  FilledButton(
                                      key:
                                          const Key('managed-evidence-primary'),
                                      onPressed: ready &&
                                              (queryOnly
                                                  ? c.canCheck
                                                  : c.canRefresh)
                                          ? guarded(() => primary(selected,
                                              read: queryOnly))
                                          : null,
                                      child: Text(primaryLabel)),
                                ],
                              ])),
                    ]))));
  }
}
