import 'dart:async';
import 'package:flutter/material.dart';
import '../core/help_requests.dart';
import '../core/session.dart';
import 'design.dart';

/// The child's explicit request; a cloud receipt is distinct from adult attention.
class ChildHelpSection extends StatefulWidget {
  final ChildSession session;
  final ChildHelpFactory? factory;
  final bool nativeAvailable;
  const ChildHelpSection(
      {super.key,
      required this.session,
      required this.factory,
      required this.nativeAvailable});

  @override
  State<ChildHelpSection> createState() => _ChildHelpSectionState();
}

class _ChildHelpSectionState extends State<ChildHelpSection>
    with WidgetsBindingObserver {
  ChildHelpCoordinator? coordinator;
  ChildHelpRecord? record;
  String reason = 'NEED_HELP';
  String? errorCode;
  bool loading = true, busy = false, storageBlocked = false;
  bool resumePending = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(_sessionChanged);
    if (widget.nativeAvailable && widget.factory != null) {
      try {
        coordinator = widget.factory!(widget.session);
        unawaited(restore());
      } on ChildHelpFailure catch (failure) {
        errorCode = failure.code;
        loading = false;
      } catch (_) {
        errorCode = 'HELP_UNAVAILABLE';
        loading = false;
      }
    } else {
      loading = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      resumePending = true;
      _sessionChanged();
    } else {
      generation++;
      resumePending = false;
      if (mounted) {
        setState(() {
          record = null;
          busy = false;
          loading = false;
        });
      }
    }
  }

  void _sessionChanged() {
    if (resumePending && coordinator?.current == true) {
      resumePending = false;
      unawaited(restore());
    }
  }

  Future<void> restore() async {
    final owner = coordinator;
    if (owner == null || !owner.current) return;
    final epoch = ++generation;
    setState(() {
      loading = true;
      record = null;
      errorCode = null;
    });
    try {
      final restored = await owner.restore();
      if (mounted && epoch == generation && owner.current) {
        setState(() {
          record = restored;
          storageBlocked = false;
        });
      }
    } on ChildHelpFailure catch (failure) {
      if (mounted && epoch == generation) {
        setState(() {
          storageBlocked = true;
          errorCode = failure.code;
        });
      }
    } finally {
      if (mounted && epoch == generation) setState(() => loading = false);
    }
  }

  Future<void> run(Future<ChildHelpRecord?> Function() action) async {
    final owner = coordinator;
    if (owner == null || busy || storageBlocked || !owner.current) return;
    final epoch = ++generation;
    setState(() {
      busy = true;
      errorCode = null;
    });
    try {
      final next = await action();
      if (mounted && epoch == generation && owner.current) {
        setState(() => record = next);
      }
    } on ChildHelpFailure catch (failure) {
      if (mounted && epoch == generation) {
        setState(() => errorCode = failure.code);
      }
      try {
        final pending = await owner.restore();
        if (mounted && epoch == generation && owner.current) {
          setState(() => record = pending);
        }
      } catch (_) {
        if (mounted && epoch == generation) {
          setState(() => storageBlocked = true);
        }
      }
    } catch (_) {
      if (mounted && epoch == generation) {
        setState(() {
          errorCode = 'HELP_UNAVAILABLE';
          storageBlocked = true;
        });
      }
    } finally {
      if (mounted && epoch == generation) setState(() => busy = false);
    }
  }

  Future<void> submit() async {
    final accepted = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('向监护人发出求助'),
            content: const Text(
                '求助会提交到监护管理台，但没有即时通知或紧急呼叫保证。若有人身危险，请直接联系身边可信任的成人或当地紧急服务。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('返回')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('提交求助'))
            ],
          ),
        ) ??
        false;
    if (accepted && mounted) await run(() => coordinator!.submit(reason));
  }

  String errorText(String code) => switch (code) {
        'HELP_NOT_RECEIVED' => '服务端尚未找到这次请求。可使用下方“重试原请求”，不会生成新编号。',
        'HELP_NETWORK_UNKNOWN' => '网络结果未确认。已保留原求助编号，请先核对；不要卸载本应用。',
        'HELP_REQUEST_RATE_LIMITED' => '短时间内求助次数过多。请直接联系可信任的成人；即时危险请使用当地紧急服务。',
        'HELP_STORAGE_UNAVAILABLE' ||
        'HELP_LOCAL_RECORD_INVALID' =>
          '加密求助记录暂无法读取。已停止新提交，请联系监护人检查设备。',
        'DEVICE_CREDENTIAL_UNAVAILABLE' ||
        'SCOPE_DENIED' ||
        'HELP_CONTEXT_CHANGED' =>
          '设备身份暂不可用。请先检查连接和设备注册状态。',
        'HELP_REQUEST_ID_REUSED' => '原请求编号与云端内容不一致。已停止新提交，请联系监护人。',
        _ => '求助状态暂无法核对。原记录仍保留；请直接联系可信任的成人。',
      };

  String reasonText(String code) => switch (code) {
        'NEED_HELP' => '需要监护人帮助',
        'UNCOMFORTABLE_CONTENT' => '遇到不适宜的内容',
        'DEVICE_PROBLEM' => '设备使用遇到问题',
        _ => '求助',
      };

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(_sessionChanged);
    coordinator?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final owner = coordinator;
    final available = owner != null && owner.current;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('向监护人求助', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const ChildNotice('此功能不是紧急呼叫',
          detail: '提交成功仅表示云端收到。监护人可能尚未看到；有即时危险时请直接寻求现场帮助或当地紧急服务。'),
      const SizedBox(height: 16),
      if (!widget.nativeAvailable || widget.factory == null)
        const Text('请在已连接的 Android 设备上使用求助功能。')
      else if (!available)
        const Text('设备连接或当前身份尚未确认，不能发送新的云端求助。')
      else if (loading)
        const LinearProgressIndicator(semanticsLabel: '正在恢复求助记录')
      else ...[
        if (errorCode != null) ...[
          ChildNotice(errorText(errorCode!), warning: true),
          const SizedBox(height: 12),
        ],
        if (record case final current?) ...[
          Text('最近一次：${reasonText(current.reasonCode)}'),
          const SizedBox(height: 8),
          if (!current.confirmed)
            const ChildNotice('提交结果待核对',
                detail: '原编号已在本机加密保存。请先核对服务器；如果尚未收到，再重试同一请求。')
          else if (current.serverState == 'ACKNOWLEDGED')
            const ChildNotice('管理员已在管理台确认看到',
                detail: '这不代表实际帮助已经完成，请继续与可信任的成人联系。')
          else
            const ChildNotice('云端已收到求助',
                detail: '监护人还没有在管理台确认看到。请在需要时直接联系可信任的成人。'),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, children: [
            OutlinedButton.icon(
                onPressed: busy || storageBlocked
                    ? null
                    : () => run(() => owner.refresh()),
                icon: const Icon(Icons.refresh),
                label: const Text('核对服务器状态')),
            if (!current.confirmed)
              OutlinedButton.icon(
                  onPressed: busy || storageBlocked
                      ? null
                      : () => run(() => owner.retry()),
                  icon: const Icon(Icons.sync),
                  label: const Text('重试原请求')),
          ]),
          const SizedBox(height: 14)
        ],
        if (record == null || record!.confirmed) ...[
          DropdownButtonFormField<String>(
              value: reason,
              decoration: const InputDecoration(labelText: '求助类型'),
              items: const [
                DropdownMenuItem(value: 'NEED_HELP', child: Text('需要监护人帮助')),
                DropdownMenuItem(
                    value: 'UNCOMFORTABLE_CONTENT', child: Text('遇到不适宜的内容')),
                DropdownMenuItem(
                    value: 'DEVICE_PROBLEM', child: Text('设备使用遇到问题')),
              ],
              onChanged: busy || storageBlocked
                  ? null
                  : (value) => setState(() => reason = value ?? reason)),
          const SizedBox(height: 12),
          FilledButton.icon(
              onPressed: busy || storageBlocked ? null : submit,
              icon: const Icon(Icons.volunteer_activism_outlined),
              label: const Text('提交新的求助')),
        ],
        if (storageBlocked)
          TextButton(onPressed: restore, child: const Text('重新读取加密记录')),
        if (busy)
          const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(semanticsLabel: '正在核对求助')),
      ]
    ]);
  }
}
