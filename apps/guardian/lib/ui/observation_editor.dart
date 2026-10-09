import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/observation.dart';
import 'design.dart';

/// Result unknown freezes the original payload; only a fresh view can rebase it.
class ObservationEditor extends StatefulWidget {
  final ManagedObservationSettings before;
  final Future<void> Function(Json) onSubmit;
  final VoidCallback? reauth;
  const ObservationEditor(
      {super.key, required this.before, required this.onSubmit, this.reauth});
  @override
  State<ObservationEditor> createState() => _ObservationEditorState();
}

class _ObservationEditorState extends State<ObservationEditor> {
  final form = GlobalKey<FormState>();
  final scroll = ScrollController();
  final reason = TextEditingController();
  late bool inventory, usage;
  bool acknowledged = false,
      busy = false,
      attempted = false,
      missingAcknowledgement = false;
  Object? error;
  Json? pending;
  bool get terminal =>
      error is ApiFailure &&
      const [401, 403, 404, 409, 412, 428]
          .contains((error as ApiFailure).status);
  bool get locked => busy || pending != null || terminal;
  @override
  void initState() {
    super.initState();
    inventory = widget.before.inventoryEnabled;
    usage = widget.before.usageEnabled;
  }

  @override
  void dispose() {
    scroll.dispose();
    reason.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || terminal) return;
    final valid = form.currentState!.validate();
    setState(() => missingAcknowledgement = !acknowledged);
    if (!valid || !acknowledged) return;
    FocusScope.of(context).unfocus();
    final body = pending ??
        <String, dynamic>{
          'inventoryEnabled': inventory,
          'usageEnabled': usage,
          'reason': reason.text.trim()
        };
    setState(() {
      busy = true;
      attempted = true;
      error = null;
    });
    try {
      await widget.onSubmit(body);
      if (mounted) Navigator.pop(context, <String, dynamic>{'refresh': true});
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = failure;
          pending = failure is! ApiFailure ||
                  failure.status == 0 ||
                  failure.status >= 500
              ? Map.unmodifiable(body)
              : null;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && scroll.hasClients) {
            scroll.animateTo(scroll.position.maxScrollExtent,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut);
          }
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget change(String title, bool oldValue, bool newValue) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child:
          Text('$title：${oldValue ? '允许' : '关闭'} → ${newValue ? '允许' : '关闭'}'));
  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('修改观察授权'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: MediaQuery.sizeOf(context).height * .65),
          child: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                  controller: scroll,
                  child: Form(
                      key: form,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Notice(
                                '云端管理员授权与设备系统许可独立。允许观察不会阻止其他应用，也不会开启摄像头。'),
                            const SizedBox(height: 16),
                            Text('当前授权版本：${widget.before.version}',
                                style: const TextStyle(color: muted)),
                            SwitchListTile(
                                key: const Key('observe-inventory'),
                                contentPadding: EdgeInsets.zero,
                                title: const Text('应用清单'),
                                subtitle: const Text(
                                    '仅当前用户可见启动应用、版本和自报签名摘要，不代表完整安装清单。'),
                                value: inventory,
                                onChanged: locked
                                    ? null
                                    : (value) =>
                                        setState(() => inventory = value)),
                            SwitchListTile(
                                key: const Key('observe-usage'),
                                contentPadding: EdgeInsets.zero,
                                title: const Text('系统使用摘要'),
                                subtitle: const Text(
                                    '还需设备系统特殊访问。仅系统聚合区间与时长，不读取原始事件或网页内容。'),
                                value: usage,
                                onChanged: locked
                                    ? null
                                    : (value) => setState(() => usage = value)),
                            const SizedBox(height: 12),
                            // Older Flutter web engines keep a semantic textarea
                            // for disabled fields. Expose the frozen value as
                            // static text instead, while retaining Form state.
                            Semantics(
                              label: locked
                                  ? '本次变更原因（已锁定）：${reason.text.trim()}'
                                  : null,
                              readOnly: locked,
                              child: ExcludeSemantics(
                                excluding: locked,
                                child: TextFormField(
                                    key: const Key('observe-reason'),
                                    controller: reason,
                                    enabled: !locked,
                                    readOnly: locked,
                                    maxLength: 300,
                                    maxLines: 3,
                                    minLines: 1,
                                    decoration: const InputDecoration(
                                        labelText: '本次变更原因',
                                        hintText: '说明授权用途或撤回原因'),
                                    validator: (value) =>
                                        value == null || value.trim().isEmpty
                                            ? '请输入本次授权变更原因'
                                            : value.length > 300
                                                ? '原因不能超过 300 字符'
                                                : !validObservationReason(value)
                                                    ? '原因不能包含不可见控制字符'
                                                    : null),
                              ),
                            ),
                            const SizedBox(height: 12),
                            change('应用清单', widget.before.inventoryEnabled,
                                inventory),
                            change('系统使用摘要', widget.before.usageEnabled, usage),
                            const SizedBox(height: 12),
                            Notice(
                                '保存后会清空当前应用清单，等待设备按新授权版本重报。'
                                '${!usage ? '关闭使用摘要会删除服务器保存的摘要批次及回执头。' : '使用摘要不用于精确计费或强制额度结算。'}'
                                '设备下次联网核对时清理旧待发载荷；不能承诺远程设备本地数据已立即擦除。',
                                warning: true),
                            CheckboxListTile(
                                key: const Key('observe-confirm'),
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: const Text('我已确认采集范围和撤回影响'),
                                value: acknowledged,
                                onChanged: locked
                                    ? null
                                    : (value) => setState(() {
                                          acknowledged = value == true;
                                          missingAcknowledgement = false;
                                        })),
                            if (missingAcknowledgement)
                              const Text('请先确认采集范围和撤回影响',
                                  style: TextStyle(color: Colors.red)),
                            if (error != null) ...[
                              const SizedBox(height: 12),
                              Semantics(
                                  liveRegion: true,
                                  child: Notice(observationError(error!),
                                      warning: true)),
                              if (error is ApiFailure &&
                                  (error as ApiFailure).status == 401 &&
                                  widget.reauth != null)
                                TextButton.icon(
                                    onPressed: widget.reauth,
                                    icon: const Icon(
                                        Icons.verified_user_outlined),
                                    label: const Text('重新安全验证')),
                            ],
                            if (pending != null)
                              const Padding(
                                  padding: EdgeInsets.only(top: 12),
                                  child: Text(
                                      '结果尚未确认，原开关、原因及版本已锁定。请重试原提交；关闭后会重新读取当前设置。')),
                          ])))),
        ),
        actions: [
          TextButton(
              onPressed: busy
                  ? null
                  : () => Navigator.pop(context,
                      attempted ? <String, dynamic>{'refresh': true} : null),
              child: Text(attempted ? '关闭并刷新' : '取消')),
          FilledButton(
              onPressed: busy || terminal ? null : submit,
              child: Text(busy
                  ? '提交中…'
                  : pending != null
                      ? '重试原提交'
                      : '确认授权变更')),
        ],
      ));
}
