import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import 'design.dart';

/// Select only server-returned targets and eligible rules; never accepts raw policy identifiers.
class AccessRequestDialog extends StatefulWidget {
  final Future<PageResult> Function(String path, String? cursor) load;
  final Future<Json> Function(Json body) submit;
  const AccessRequestDialog(
      {super.key, required this.load, required this.submit});
  @override
  State<AccessRequestDialog> createState() => _AccessRequestDialogState();
}

class _AccessRequestDialogState extends State<AccessRequestDialog> {
  final form = GlobalKey<FormState>();
  final scroll = ScrollController();
  final minutes = TextEditingController(text: '15');
  final reason = TextEditingController();
  final devices = <Json>[];
  final options = <String, Json>{};
  final selectedRules = <String>{};
  String? device, option, deviceCursor, optionCursor;
  bool loadingDevices = true, loadingOptions = false, busy = false;
  bool deviceFailed = false, optionFailed = false;
  Object? error;
  Json? pending;
  int generation = 0;
  bool get locked => busy || pending != null;
  Json? get selected => options[option];
  bool get stale =>
      error is ApiFailure &&
      [
        'BASELINE_CHANGED',
        'ACCESS_TARGET_CHANGED',
        'SCOPE_DENIED',
        'WORKSPACE_CHANGED'
      ].contains((error as ApiFailure).code);

  @override
  void initState() {
    super.initState();
    loadDevices();
  }

  @override
  void dispose() {
    generation++;
    scroll.dispose();
    minutes.dispose();
    reason.dispose();
    super.dispose();
  }

  Future<void> loadDevices() async {
    setState(() {
      loadingDevices = true;
      error = null;
    });
    try {
      final page = await widget.load('devices', deviceCursor);
      if (!mounted) return;
      setState(() {
        final existing = devices.map((e) => e['id']).toSet();
        devices.addAll(page.items.where(
            (e) => e['state'] == 'ACTIVE' && !existing.contains(e['id'])));
        deviceCursor = page.nextCursor;
        deviceFailed = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e;
          deviceFailed = true;
        });
      }
    } finally {
      if (mounted) setState(() => loadingDevices = false);
    }
  }

  Future<void> loadOptions({bool reset = false}) async {
    final current = device;
    if (current == null) return;
    final epoch = ++generation;
    setState(() {
      loadingOptions = true;
      error = null;
      if (reset) {
        options.clear();
        option = null;
        optionCursor = null;
        selectedRules.clear();
      }
    });
    try {
      final page = await widget.load(
          'access-requests/options?deviceId=$current', optionCursor);
      if (!mounted || epoch != generation) return;
      setState(() {
        for (final policy in page.items) {
          for (final app in policy['applications'] as List) {
            options['${policy['id']}/${app['id']}'] = {
              'policyId': policy['id'],
              'policyName': policy['name'],
              'baseVersionId': policy['baseVersionId'],
              'applicationId': app['id'],
              'name': app['displayName'],
              'rules': [
                ...(policy['commonRules'] as List? ?? []),
                ...(app['rules'] as List)
              ],
            };
          }
        }
        optionCursor = page.nextCursor;
        optionFailed = false;
      });
    } catch (e) {
      if (mounted && epoch == generation) {
        setState(() {
          error = e;
          optionFailed = true;
        });
      }
    } finally {
      if (mounted && epoch == generation) {
        setState(() => loadingOptions = false);
      }
    }
  }

  Future<void> send() async {
    if (!form.currentState!.validate()) return;
    if (pending == null &&
        (selected == null ||
            selectedRules.isEmpty ||
            selectedRules.length > 20)) {
      setState(() => error = const ApiFailure(400, 'EXCEPTION_RULE_INVALID'));
      return;
    }
    FocusScope.of(context).unfocus();
    final body = pending ??
        <String, dynamic>{
          'deviceId': device,
          'policyId': selected!['policyId'],
          'baseVersionId': selected!['baseVersionId'],
          'applicationId': selected!['applicationId'],
          'ruleIds': selectedRules.toList()..sort(),
          'requestedWindowSeconds': int.parse(minutes.text.trim()) * 60,
          'reason': reason.text.trim().isEmpty ? null : reason.text.trim(),
        };
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.submit(body);
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e;
          pending = e is ApiFailure && (e.status == 0 || e.status >= 500)
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

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !busy,
        child: AlertDialog(
          title: const Text('申请临时访问'),
          content: SizedBox(
              width: 600,
              child: SingleChildScrollView(
                  controller: scroll,
                  child: Form(
                    key: form,
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('选择当前范围内的设备与应用，说明所需时间。管理员审批后形成限时窗口。',
                              style: TextStyle(color: muted, height: 1.6)),
                          const SizedBox(height: 16),
                          const Notice('当前仅记录和交付访问配置，不会直接解除设备限制或增加使用额度。'),
                          const SizedBox(height: 20),
                          DropdownButtonFormField<String>(
                            key: const Key('request-device'),
                            value: device,
                            isExpanded: true,
                            decoration: const InputDecoration(labelText: '设备'),
                            items: devices
                                .map((e) => DropdownMenuItem<String>(
                                    value: e['id'],
                                    child: Text(
                                        '${e['displayName']} · ${shortId(e['id'])}',
                                        overflow: TextOverflow.ellipsis)))
                                .toList(),
                            onChanged: locked || loadingOptions
                                ? null
                                : (v) {
                                    setState(() => device = v);
                                    loadOptions(reset: true);
                                  },
                            validator: (v) => v == null ? '请选择设备' : null,
                          ),
                          if (loadingDevices)
                            const Padding(
                                padding: EdgeInsets.all(12),
                                child: LinearProgressIndicator()),
                          if (!loadingDevices && devices.isEmpty)
                            const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text('当前没有可申请的已连接设备。')),
                          if (deviceCursor != null || deviceFailed)
                            TextButton(
                                onPressed: locked || loadingDevices
                                    ? null
                                    : loadDevices,
                                child:
                                    Text(deviceFailed ? '重试加载设备' : '加载更多设备')),
                          if (device != null) ...[
                            const SizedBox(height: 20),
                            DropdownButtonFormField<String>(
                              key: ValueKey('option-$device'),
                              value: option,
                              isExpanded: true,
                              decoration:
                                  const InputDecoration(labelText: '应用与策略'),
                              items: options.entries
                                  .map((e) => DropdownMenuItem<String>(
                                      value: e.key,
                                      child: Text(
                                          '${e.value['name']} · ${e.value['policyName']}',
                                          overflow: TextOverflow.ellipsis)))
                                  .toList(),
                              onChanged: locked || loadingOptions
                                  ? null
                                  : (v) => setState(() {
                                        option = v;
                                        selectedRules.clear();
                                        final rules =
                                            selected?['rules'] as List? ?? [];
                                        if (rules.length <= 20) {
                                          selectedRules.addAll(rules
                                              .map((r) => r['id'] as String));
                                        }
                                      }),
                              validator: (v) => v == null ? '请选择应用与策略' : null,
                            ),
                            if (loadingOptions)
                              const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: LinearProgressIndicator()),
                            if (!loadingOptions && options.isEmpty)
                              Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(optionCursor == null
                                      ? '暂无可申请的规则。仅支持该设备最新配置中的应用禁止启动和使用时段规则。'
                                      : '本页没有可申请规则，可继续加载。')),
                            Wrap(spacing: 8, children: [
                              if (optionCursor != null || optionFailed)
                                TextButton(
                                    onPressed: locked || loadingOptions
                                        ? null
                                        : () => loadOptions(),
                                    child: Text(
                                        optionFailed ? '重试加载规则' : '加载更多规则')),
                              if (!stale)
                                TextButton(
                                    onPressed: locked || loadingOptions
                                        ? null
                                        : () => loadOptions(reset: true),
                                    child: const Text('刷新可申请规则')),
                            ]),
                          ],
                          if (selected != null) ...[
                            const SizedBox(height: 12),
                            Text('申请放宽的规则（${selectedRules.length}/20）',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            ...((selected!['rules'] as List)
                                .map((r) => CheckboxListTile(
                                      value: selectedRules.contains(r['id']),
                                      contentPadding: EdgeInsets.zero,
                                      controlAffinity:
                                          ListTileControlAffinity.leading,
                                      title: Text(label(r['kind'])),
                                      subtitle: Text('规则 ${r['id']}'),
                                      onChanged: locked ||
                                              selectedRules.length >= 20 &&
                                                  !selectedRules
                                                      .contains(r['id'])
                                          ? null
                                          : (v) => setState(() {
                                                if (v == true &&
                                                    selectedRules.length < 20) {
                                                  selectedRules.add(r['id']);
                                                }
                                                if (v != true) {
                                                  selectedRules.remove(r['id']);
                                                }
                                              }),
                                    ))),
                            const Text('未选择的规则和安全底线继续保留。',
                                style: TextStyle(color: muted)),
                          ],
                          const SizedBox(height: 20),
                          TextFormField(
                              key: const Key('request-minutes'),
                              controller: minutes,
                              enabled: !locked,
                              keyboardType: TextInputType.number,
                              maxLength: 2,
                              decoration: const InputDecoration(
                                  labelText: '申请时长（1–60 分钟）'),
                              validator: (v) {
                                final n = int.tryParse(v?.trim() ?? '');
                                return n == null || n < 1 || n > 60
                                    ? '请输入 1–60 的整数'
                                    : null;
                              }),
                          const SizedBox(height: 12),
                          TextFormField(
                              key: const Key('request-reason'),
                              controller: reason,
                              enabled: !locked,
                              maxLength: 300,
                              minLines: 2,
                              maxLines: 4,
                              decoration: const InputDecoration(
                                  labelText: '申请理由（选填）',
                                  hintText: '例如：课堂活动需要使用此应用 15 分钟')),
                          if (error != null)
                            Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: FailureView(error!)),
                          if (stale && device != null)
                            TextButton(
                                onPressed: locked || loadingOptions
                                    ? null
                                    : () => loadOptions(reset: true),
                                child: const Text('刷新可申请规则')),
                          if (pending != null)
                            const Padding(
                                padding: EdgeInsets.only(top: 12),
                                child: Notice(
                                    '提交结果尚未确认，原内容已锁定。重试会使用同一次提交，也可关闭后刷新申请列表。')),
                        ]),
                  ))),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('关闭并刷新')),
            FilledButton(
                onPressed: busy || loadingOptions || loadingDevices || stale
                    ? null
                    : send,
                child: Text(busy
                    ? '提交中…'
                    : pending != null
                        ? '重试原提交'
                        : '提交申请')),
          ],
        ),
      );
}
