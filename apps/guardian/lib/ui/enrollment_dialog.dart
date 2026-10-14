import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/api.dart';
import '../core/enrollment_recovery.dart';
import '../core/enrollment_ticket.dart';
import 'design.dart';

class EnrollmentDialog extends StatefulWidget {
  final EnrollmentController controller;
  final List<Json> subjects;
  final bool organization;
  final VoidCallback onReauthenticate;
  final ValueChanged<String>? onViewDevice;
  final Future<void> Function(String)? copy;
  const EnrollmentDialog(
      {super.key,
      required this.controller,
      required this.subjects,
      required this.onReauthenticate,
      this.organization = false,
      this.onViewDevice,
      this.copy});
  @override
  State<EnrollmentDialog> createState() => _EnrollmentDialogState();
}

class _EnrollmentDialogState extends State<EnrollmentDialog>
    with WidgetsBindingObserver {
  final code = TextEditingController();
  final codeFocus = FocusNode();
  String? selected;
  String platform = 'ANDROID';
  bool foreground = true, copying = false, confirmCancellation = false;
  Timer? clock, poll;
  EnrollmentController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    selected = c.pending?.subjectId ??
        (widget.subjects.isEmpty
            ? null
            : widget.subjects.first['id'] as String);
    platform = c.pending?.platform ?? 'ANDROID';
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    c.addListener(changed);
    codeFocus.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && foreground && c.pending != null) setState(() {});
    });
    poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted &&
          foreground &&
          !confirmCancellation &&
          !codeFocus.hasFocus &&
          c.current &&
          !c.busy &&
          const {'PENDING_CLAIM', 'AWAITING_CONFIRMATION'}
              .contains(c.progress?.state)) {
        unawaited(c.check());
      }
    });
    if (!c.initialized) unawaited(c.initialize());
  }

  void changed() {
    if (!c.busy && !c.canCancel) confirmCancellation = false;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      code.clear();
      c.conceal();
    } else if (!c.busy && c.current) {
      unawaited(c.check());
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    clock?.cancel();
    poll?.cancel();
    c.removeListener(changed);
    codeFocus.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    code.dispose();
    codeFocus.dispose();
    c.conceal();
    super.dispose();
  }

  Future<void> copyTicket() async {
    if (copying || c.busy || !foreground || !c.current || !c.hasSecret) return;
    final ticket = c.ticket!;
    final text = encodeEnrollmentTicket(c.scope.tenantId, ticket.json);
    setState(() => copying = true);
    try {
      if (!c.current || !c.hasSecret) return;
      if (widget.copy != null) {
        await widget.copy!(text);
      } else {
        await Clipboard.setData(ClipboardData(text: text));
      }
      if (mounted && foreground && c.current) {
        toast(context, '已复制，请仅在可信任的设备端粘贴。');
      }
    } catch (_) {
      if (mounted && foreground && c.current) {
        toast(context, '复制未完成，可展开“手动输入”核对凭证。');
      }
    } finally {
      if (mounted) setState(() => copying = false);
    }
  }

  Future<void> confirm() async {
    final value = code.text.trim().toUpperCase();
    if (!RegExp(r'^[0-9A-F]{8}$').hasMatch(value)) {
      toast(context, '请输入设备当前显示的 8 位配对码。');
      return;
    }
    try {
      await c.confirm(value);
    } finally {
      code.clear();
    }
  }

  Future<void> cancel() async {
    if (!foreground || !c.current || !c.canCancel) return;
    setState(() => confirmCancellation = true);
  }

  Future<void> confirmCancel() async {
    if (!foreground || !c.current || !c.canCancel) return;
    setState(() => confirmCancellation = false);
    await c.cancel();
  }

  Widget heading(String title, String description) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(description, style: const TextStyle(color: muted, height: 1.7)),
      ]);

  Widget draft() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        heading('选择设备',
            '选择所属${widget.organization ? '学生' : '儿童'}和设备平台，随后在设备端完成配对。'),
        const SizedBox(height: 20),
        if (widget.subjects.isEmpty)
          const Notice('暂无可用档案。请先添加档案，再回到设备连接。')
        else ...[
          DropdownButtonFormField<String>(
              value: widget.subjects.any((s) => s['id'] == selected)
                  ? selected
                  : null,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: '所属${widget.organization ? '学生' : '儿童'}'),
              items: widget.subjects
                  .map((s) => DropdownMenuItem<String>(
                      value: s['id'] as String,
                      child: Text(s['nickname'] as String,
                          overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: c.canCreate && !c.busy
                  ? (value) => setState(() => selected = value)
                  : null),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
              key: const ValueKey('enrollment-platform'),
              value: platform,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '设备平台'),
              items: const [
                DropdownMenuItem(
                    value: 'ANDROID', child: Text('Android 手机 / 平板')),
                DropdownMenuItem(
                    value: 'ANDROID_TV', child: Text('Android TV')),
              ],
              onChanged: c.canCreate && !c.busy
                  ? (value) => setState(() => platform = value!)
                  : null),
          const SizedBox(height: 16),
          const Notice('普通个人设备模式。实际管理能力以设备授权与执行回执为准。'),
          const SizedBox(height: 20),
          FilledButton.icon(
              onPressed: c.canCreate && selected != null && !c.busy
                  ? () => c.create(subjectId: selected!, platform: platform)
                  : null,
              icon: const Icon(Icons.qr_code_2, size: 18),
              label: const Text('生成配对凭证')),
        ],
      ]);

  Widget progress() {
    final value = c.progress;
    if (value == null) {
      return heading(
          '结果尚未确认',
          c.gateway.supportsCreation
              ? '保留了这次操作。先核对原请求；查不到时可明确继续原操作，原编号和选择会保持不变。'
              : '暂未取得这次注册的进度。请刷新核对，查询不会创建新的配对凭证。');
    }
    if (value.state == 'PENDING_CLAIM') {
      if (!c.hasSecret) {
        return heading(
            '凭证已隐藏，无法重新显示',
            c.gateway.supportsCreation
                ? '一次性凭证只在收到时显示。可以取消这次配对，确认结束后再重新开始。'
                : '查询只显示注册进度。原设备可继续认领；如已失去原凭证，可取消这次配对后关闭窗口，再连接新设备。');
      }
      final ticket = c.ticket!;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        heading('在设备端继续', '在孩子的设备端打开配对功能，扫描二维码，或粘贴复制的配对凭证。'),
        const SizedBox(height: 20),
        Center(
            child: Semantics(
                label: '一次性设备配对二维码',
                child: QrImageView(
                    data: encodeEnrollmentTicket(c.scope.tenantId, ticket.json),
                    size: 200,
                    backgroundColor: Colors.white))),
        const SizedBox(height: 12),
        Center(
            child: OutlinedButton.icon(
                onPressed: c.busy || copying ? null : copyTicket,
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: const Text('复制配对凭证'))),
        const SizedBox(height: 12),
        const Notice('请仅向正在现场配对的可信任设备展示。关闭或离开本页后，凭证会隐藏。'),
        ExpansionTile(
            title: const Text('手动输入'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 16),
            children: [
              SelectableText('注册编号：${ticket.id}'),
              const SizedBox(height: 8),
              SelectableText('一次性凭证：${ticket.token}')
            ]),
      ]);
    }
    if (value.state == 'AWAITING_CONFIRMATION') {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        heading('核对设备上的配对码', '请确认正在连接的是你面前的设备，再输入设备当前显示的 8 位配对码。'),
        const SizedBox(height: 20),
        TextField(
            key: const ValueKey('enrollment-code'),
            controller: code,
            focusNode: codeFocus,
            enabled: c.canConfirm && !c.busy,
            maxLength: 8,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
                labelText: '设备上显示的配对码', hintText: '例如 A1B2C3D4')),
        if (value.pairingFailures > 0) ...[
          const SizedBox(height: 8),
          Notice('已记录 ${value.pairingFailures} 次不匹配。请核对设备当前显示的配对码，不要连续试码。',
              warning: true),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
            onPressed: c.canConfirm && !c.busy ? confirm : null,
            icon: const Icon(Icons.verified_outlined, size: 18),
            label: const Text('确认配对')),
      ]);
    }
    return switch (value.state) {
      'CONFIRMED' => heading('配对已确认', '注册过程已完成。设备当前连接与规则执行状态请到设备详情核对。'),
      'CANCELLED' => heading('配对已取消', '原配对已停止，可以重新选择设备。'),
      'LOCKED' => heading('配对已锁定', '不匹配次数达到服务端上限。此配对已锁定，可以重新开始。'),
      'EXPIRED' => heading('配对已过期', '请取消这次过期配对，核对结束后再重新开始。'),
      _ => const SizedBox.shrink(),
    };
  }

  Widget errors() {
    final error = c.error;
    if (error == null) return const SizedBox.shrink();
    final failure = error is ApiFailure ? error : null;
    return Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Notice(
              switch (failure?.code) {
                'ENROLLMENT_RECOVERY_STORAGE_INVALID' =>
                  '本标签页的恢复记录无法识别。请保留原注册编号，通过“查询注册进度”核对；暂时无法新建配对。',
                'ENROLLMENT_RECOVERY_STORAGE_FAILED' ||
                'ENROLLMENT_STORAGE_UNAVAILABLE' =>
                  '未能保存或读取恢复记录。请保持当前窗口并允许浏览器存储，再重试原操作。',
                'ENROLLMENT_CREATION_UNAVAILABLE' =>
                  '暂未查到原请求。可以刷新进度，或使用“继续原操作”提交相同选择。',
                'INVALID_ENROLLMENT_RESPONSE' => '返回的配对资料未通过核对，已隐藏。请刷新原注册进度。',
                'ENROLLMENT_UNAVAILABLE' => '注册状态已变化，请刷新进度后继续。',
                _ => failure?.message ?? '暂时无法核对，请保留原操作并稍后重试。',
              },
              warning: true),
          if (failure?.status == 401)
            TextButton.icon(
                onPressed: c.busy
                    ? null
                    : () {
                        code.clear();
                        c.conceal();
                        widget.onReauthenticate();
                      },
                icon: const Icon(Icons.verified_user_outlined, size: 18),
                label: const Text('重新安全验证')),
          if (c.pending == null)
            TextButton(
                onPressed: c.busy ? null : c.initialize,
                child: const Text('重新读取恢复记录')),
          if (failure != null)
            ExpansionTile(
                title: const Text('错误信息'),
                tilePadding: EdgeInsets.zero,
                children: [
                  SelectableText(
                      '${failure.code}${failure.correlationId == null ? '' : ' · ${failure.correlationId}'}')
                ]),
        ]));
  }

  @override
  Widget build(BuildContext context) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: 680,
              maxHeight: (MediaQuery.sizeOf(context).height -
                      MediaQuery.viewInsetsOf(context).bottom -
                      48)
                  .clamp(120, double.infinity)
                  .toDouble()),
          child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Expanded(
                        child: Text(
                            c.gateway.supportsCreation ? '连接设备' : '注册进度',
                            style: Theme.of(context).textTheme.titleLarge)),
                    IconButton(
                        tooltip: '关闭设备连接',
                        onPressed: () {
                          c.conceal();
                          Navigator.of(context).maybePop();
                        },
                        icon: const Icon(Icons.close))
                  ]),
                  const SizedBox(height: 8),
                  if (!foreground)
                    heading('连接信息已隐藏', '回到本页后会重新读取进度，不会自动提交。')
                  else if (!c.current)
                    heading('工作空间或权限已变化', '原连接信息已隐藏，请在当前工作空间重新打开。')
                  else if (c.loading)
                    const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()))
                  else ...[
                    const Wrap(spacing: 12, runSpacing: 8, children: [
                      Text('1 · 选择设备', style: TextStyle(color: muted)),
                      Text('2 · 在设备端配对', style: TextStyle(color: muted)),
                      Text('3 · 现场确认', style: TextStyle(color: muted)),
                    ]),
                    const SizedBox(height: 24),
                    if (c.pending == null) draft() else progress(),
                    if (c.busy)
                      const Padding(
                          padding: EdgeInsets.only(top: 16),
                          child: LinearProgressIndicator()),
                    errors(),
                    if (c.pending != null) ...[
                      const SizedBox(height: 20),
                      if (confirmCancellation) ...[
                        const Notice(
                            '原配对凭证将停止使用；已经认领的待确认设备也会撤销云端凭证。核对取消结果后才能重新开始。',
                            warning: true),
                        const SizedBox(height: 12),
                        Wrap(spacing: 10, runSpacing: 10, children: [
                          FilledButton(
                              onPressed: c.busy ? null : confirmCancel,
                              child: const Text('确认取消')),
                          TextButton(
                              onPressed: c.busy
                                  ? null
                                  : () => setState(
                                      () => confirmCancellation = false),
                              child: const Text('继续配对')),
                        ]),
                        const SizedBox(height: 16),
                      ],
                      Wrap(spacing: 10, runSpacing: 10, children: [
                        OutlinedButton.icon(
                            onPressed: c.busy ? null : c.check,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('刷新进度')),
                        if (c.canRetryCreation)
                          FilledButton(
                              onPressed: c.busy ? null : c.retryCreation,
                              child: const Text('继续原操作')),
                        if (c.canCancel)
                          TextButton(
                              onPressed: c.busy ? null : cancel,
                              style: TextButton.styleFrom(
                                  foregroundColor: const Color(0xFFAA3C35)),
                              child: const Text('取消这次配对')),
                        if (c.progress?.state == 'CONFIRMED' &&
                            widget.onViewDevice != null)
                          FilledButton(
                              onPressed: c.busy
                                  ? null
                                  : () => widget
                                      .onViewDevice!(c.progress!.deviceId!),
                              child: const Text('查看设备')),
                        if (c.canStartAgain)
                          OutlinedButton(
                              onPressed: c.busy ? null : c.startAgain,
                              child: Text(c.progress?.state == 'CONFIRMED'
                                  ? '连接另一台设备'
                                  : '重新开始')),
                      ]),
                      ExpansionTile(
                          title: const Text('操作信息'),
                          tilePadding: EdgeInsets.zero,
                          children: [
                            SelectableText('注册编号：${c.pending!.requestId}'),
                            if (c.progress != null)
                              Text(
                                  '有效期：${DateTime.fromMillisecondsSinceEpoch(c.progress!.expiresAt).toLocal()}')
                          ]),
                    ],
                  ],
                ],
              ))));
}

class EnrollmentResumeNotice extends StatefulWidget {
  final EnrollmentJournal journal;
  final EnrollmentScope scope;
  final Listenable? changes;
  final bool Function() isCurrent;
  final Future<void> Function() onOpen;
  const EnrollmentResumeNotice(
      {super.key,
      required this.journal,
      required this.scope,
      required this.isCurrent,
      required this.onOpen,
      this.changes});
  @override
  State<EnrollmentResumeNotice> createState() => _EnrollmentResumeNoticeState();
}

class _EnrollmentResumeNoticeState extends State<EnrollmentResumeNotice> {
  EnrollmentIntent? pending;
  Object? error;
  bool opening = false;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(changed);
    unawaited(read());
  }

  void changed() {
    unawaited(read());
  }

  Future<void> read() async {
    final epoch = ++generation;
    try {
      final value = await widget.journal.read(widget.scope);
      if (mounted && epoch == generation && widget.isCurrent()) {
        setState(() {
          pending = value;
          error = null;
        });
      }
    } catch (failure) {
      if (mounted && epoch == generation && widget.isCurrent()) {
        setState(() {
          pending = null;
          error = failure;
        });
      }
    }
  }

  @override
  void didUpdateWidget(EnrollmentResumeNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes?.removeListener(changed);
      widget.changes?.addListener(changed);
    }
    if (oldWidget.scope.key != widget.scope.key ||
        oldWidget.journal != widget.journal) {
      pending = null;
      error = null;
      unawaited(read());
    }
  }

  @override
  void dispose() {
    generation++;
    widget.changes?.removeListener(changed);
    super.dispose();
  }

  Future<void> open() async {
    if (opening || !widget.isCurrent()) return;
    setState(() => opening = true);
    try {
      await widget.onOpen();
    } finally {
      if (mounted) {
        setState(() => opening = false);
        await read();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isCurrent() || (pending == null && error == null)) {
      return const SizedBox.shrink();
    }
    return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Panel(
            padding: const EdgeInsets.all(18),
            child: Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(error == null ? '有一项设备连接尚未核对完成' : '设备连接恢复记录暂不可用',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  OutlinedButton.icon(
                      onPressed: opening ? null : open,
                      icon: const Icon(Icons.restore, size: 18),
                      label: Text(error == null ? '继续连接设备' : '检查恢复记录')),
                ])));
  }
}
