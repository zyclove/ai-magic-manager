import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import 'design.dart';
import 'dialog_access.dart';

/// Select only server-returned targets and eligible rules; never accepts raw policy identifiers.
class AccessRequestDialog extends StatefulWidget {
  final Future<PageResult> Function(String path, String? cursor) load;
  final Future<Json> Function(Json body) submit;
  final ValueChanged<Json?> onComplete;
  const AccessRequestDialog(
      {super.key, required this.load, required this.submit,
      required this.onComplete});
  @override
  State<AccessRequestDialog> createState() => _AccessRequestDialogState();
}

class _AccessRequestDialogState extends State<AccessRequestDialog> {
  final form = GlobalKey<FormState>();
  final scroll = ScrollController();
  final minutes = TextEditingController(text: '15');
  final seconds = TextEditingController();
  final reason = TextEditingController();
  final devices = <Json>[];
  final options = <String, Json>{};
  final selectedRules = <String>{};
  String? device, option, deviceCursor, optionCursor;
  bool loadingDevices = false, loadingOptions = false, busy = false;
  bool deviceFailed = false, deviceCursorExpired = false, optionFailed = false;
  Object? error;
  Json? pending;
  bool stopped = false, active = true, finished = false, readDenied = false;
  DialogAccessBinding? access;
  bool initialized = false;
  ModalRoute<dynamic>? get owner => access?.parent;
  int generation = 0;
  bool get windowCurrent => mounted && active && !finished &&
      access?.permitted() != false;
  bool get dataCurrent => windowCurrent && !readDenied;
  bool get interactive => windowCurrent &&
      (owner == null || (owner!.isActive && owner!.isCurrent));
  bool editing(int view) => interactive && !locked && !loadingOptions &&
      generation == view;

  VoidCallback viewAction(VoidCallback callback, int view) => () {
    if (interactive && !readDenied && generation == view) callback();
  };
  bool get locked => busy || pending != null || stopped || readDenied;

  int? get requestedSeconds {
    final minute = int.tryParse(minutes.text.trim());
    final second = seconds.text.trim().isEmpty
        ? 0 : int.tryParse(seconds.text.trim());
    if (minute == null || minute < 0 || minute > 60 ||
        second == null || second < 0 || second > 59) return null;
    final total = minute * 60 + second;
    return total < 1 || total > 3600 ? null : total;
  }

  Json? get selected => options[option];
  bool get stale =>
      error is ApiFailure &&
      [
        'BASELINE_CHANGED',
        'ACCESS_TARGET_CHANGED',
        'SCOPE_DENIED',
        'WORKSPACE_CHANGED'
      ].contains((error as ApiFailure).code);

  void finish([Json? result]) {
    if (!windowCurrent) return;
    finished = true;
    generation++;
    widget.onComplete(result);
  }

  void close() {
    if (interactive && !busy) finish();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    access ??= DialogAccessBinding(context);
    if (!initialized && interactive) {
      initialized = true;
      loadDevices();
    }
  }

  @override
  void deactivate() {
    active = false;
    generation++;
    super.deactivate();
  }

  @override
  void dispose() {
    active = false;
    generation++;
    scroll.dispose();
    minutes.dispose();
    seconds.dispose();
    reason.dispose();
    access?.dispose();
    super.dispose();
  }

  bool rejectPrivateRead(Object failure) {
    if (!dataCurrent || failure is! ApiFailure ||
        !((failure.code != 'REAUTH_REQUIRED' &&
                (failure.status == 401 || failure.status == 403)) ||
            failure.code == 'WORKSPACE_CHANGED')) return false;
    setState(() {
      readDenied = true;
      generation++;
      devices.clear();
      options.clear();
      selectedRules.clear();
      device = null;
      option = null;
      deviceCursor = null;
      optionCursor = null;
      deviceFailed = false;
      deviceCursorExpired = false;
      optionFailed = false;
      loadingDevices = false;
      loadingOptions = false;
      minutes.clear();
      seconds.clear();
      reason.clear();
      error = failure;
    });
    return true;
  }

  Future<void> loadDevices() async {
    if (!interactive || locked || loadingDevices) return;
    final restarting = deviceCursorExpired;
    final requestCursor = restarting ? null : deviceCursor;
    setState(() {
      loadingDevices = true;
      error = null;
    });
    try {
      final page = await widget.load('devices', requestCursor);
      if (!dataCurrent) return;
      setState(() {
        final selectionReturned = restarting &&
            device != null &&
            page.items.any((entry) => entry['id'] == device);
        final selectionRevoked = selectionReturned &&
            page.items.any(
                (entry) => entry['id'] == device && entry['state'] != 'ACTIVE');
        final retained = restarting && device != null && !selectionReturned
            ? devices.where((entry) => entry['id'] == device).toList()
            : const <Json>[];
        if (restarting) devices.clear();
        final existing = devices.map((e) => e['id']).toSet();
        for (final entry in page.items) {
          if (entry['state'] == 'ACTIVE' && existing.add(entry['id'])) {
            devices.add(entry);
          }
        }
        for (final entry in retained) {
          if (existing.add(entry['id'])) devices.add(entry);
        }
        deviceCursor = page.nextCursor;
        deviceFailed = false;
        deviceCursorExpired = false;
        if (selectionRevoked) {
          generation++;
          device = null;
          option = null;
          options.clear();
          selectedRules.clear();
          optionCursor = null;
          optionFailed = false;
          loadingOptions = false;
          error = const ApiFailure(409, 'ACCESS_TARGET_CHANGED');
        }
      });
    } catch (e) {
      if (dataCurrent) {
        if (rejectPrivateRead(e)) return;
        setState(() {
          error = e;
          deviceFailed = true;
          if (e is ApiFailure && e.code == 'INVALID_CURSOR') {
            deviceCursorExpired = true;
          }
        });
      }
    } finally {
      if (dataCurrent) setState(() => loadingDevices = false);
    }
  }

  Future<void> loadOptions({bool reset = false}) async {
    final current = device;
    if (!interactive || locked || loadingOptions || current == null) return;
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
      if (!dataCurrent || epoch != generation) return;
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
      if (dataCurrent && epoch == generation) {
        if (rejectPrivateRead(e)) return;
        setState(() {
          error = e;
          optionFailed = true;
        });
      }
    } finally {
      if (dataCurrent && epoch == generation) {
        setState(() => loadingOptions = false);
      }
    }
  }

  void selectDevice(String? value, int view) {
    if (!editing(view) || value == device ||
        (value != null && !devices.any((row) => row['id'] == value))) return;
    setState(() {
      device = value;
      if (value == null) {
        generation++;
        option = null;
        options.clear();
        selectedRules.clear();
        optionCursor = null;
        optionFailed = false;
      }
    });
    if (value != null) loadOptions(reset: true);
  }

  void selectOption(String? value, int view, String? selectedDevice) {
    if (!editing(view) || device != selectedDevice || value == option ||
        (value != null && !options.containsKey(value))) return;
    setState(() {
      generation++;
      option = value;
      selectedRules.clear();
      final rules = selected?['rules'] as List? ?? [];
      if (rules.length <= 20) {
        selectedRules.addAll(rules.map((rule) => rule['id'] as String));
      }
    });
  }

  void selectRule(String id, bool? value, int view,
      String? selectedDevice, String? selectedOption) {
    if (!editing(view) || device != selectedDevice || option != selectedOption ||
        selectedRules.contains(id) == (value == true) ||
        (value == true && selectedRules.length >= 20)) return;
    setState(() {
      if (value == true) {
        selectedRules.add(id);
      } else {
        selectedRules.remove(id);
      }
    });
  }

  Future<void> send() async {
    if (!interactive || readDenied || busy || stopped ||
        loadingOptions || loadingDevices || stale) {
      return;
    }
    final retryingUnknown = pending != null;
    if (!retryingUnknown && !form.currentState!.validate()) return;
    if (pending == null &&
        (selected == null ||
            selectedRules.isEmpty ||
            selectedRules.length > 20)) {
      setState(() => error = const ApiFailure(400, 'EXCEPTION_RULE_INVALID'));
      return;
    }
    FocusScope.of(context).unfocus();
    final body = pending ??
        Map<String, dynamic>.unmodifiable({
          'deviceId': device,
          'policyId': selected!['policyId'],
          'baseVersionId': selected!['baseVersionId'],
          'applicationId': selected!['applicationId'],
          'ruleIds': List<String>.unmodifiable(selectedRules.toList()..sort()),
          'requestedWindowSeconds': requestedSeconds!,
          'reason': reason.text.trim().isEmpty ? null : reason.text.trim(),
        });
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.submit(body);
      finish(result);
    } catch (e) {
      if (windowCurrent) {
        setState(() {
          error = e;
          if (e is ApiFailure &&
              (e.status == 412 || isUnavailableOperationResult(e))) {
            stopped = true;
            pending ??= body;
          } else if (retryingUnknown || e is! ApiFailure ||
              e.status == 0 || e.status == 408 || e.status >= 500 ||
              e.code == 'PENDING_OPERATION_UNCHANGED') {
            // A later rejection cannot prove that the original write failed.
            pending ??= body;
          } else {
            pending = null;
          }
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (windowCurrent && scroll.hasClients) {
            scroll.animateTo(scroll.position.maxScrollExtent,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut);
          }
        });
      }
    } finally {
      if (windowCurrent) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!windowCurrent) return const SizedBox.shrink();
    if (readDenied) {
      return PopScope(
          canPop: !busy,
          child: AlertDialog(
              title: const Text('读取权限已变化'),
              content: const Text('原申请资料已隐藏。请关闭窗口，在当前工作空间重新打开申请。'),
              actions: [
                TextButton(onPressed: busy ? null : close,
                    child: const Text('关闭')),
              ]));
    }
    final view = generation;
    final selectedDevice = device, selectedOption = option;
    return PopScope(
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
                                : (v) => selectDevice(v, view),
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
                          if (device == null &&
                              error is ApiFailure &&
                              (error as ApiFailure).code ==
                                  'ACCESS_TARGET_CHANGED')
                            const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Notice('当前选择的设备已失效，已保留时长和理由。请重新选择设备。',
                                    warning: true)),
                          if (deviceCursorExpired)
                            const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Notice(
                                    '设备列表位置已失效，已保留当前选择和填写内容。请从首页重新加载设备。',
                                    warning: true)),
                          if (deviceCursor != null || deviceFailed)
                            TextButton(
                                onPressed: locked || loadingDevices
                                    ? null
                                    : viewAction(loadDevices, view),
                                child: Text(deviceCursorExpired
                                    ? '从首页重新加载设备'
                                    : deviceFailed
                                        ? '重试加载设备'
                                        : '加载更多设备')),
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
                                  : (v) => selectOption(v, view, selectedDevice),
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
                                        : viewAction(() => loadOptions(), view),
                                    child: Text(
                                        optionFailed ? '重试加载规则' : '加载更多规则')),
                              if (!stale)
                                TextButton(
                                    onPressed: locked || loadingOptions
                                        ? null
                                        : viewAction(() => loadOptions(reset: true), view),
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
                                          : (v) => selectRule(r['id'] as String, v,
                                              view, selectedDevice, selectedOption),
                                    ))),
                            const Text('未选择的规则和安全底线继续保留。',
                                style: TextStyle(color: muted)),
                          ],
                          const SizedBox(height: 20),
                          const Text('申请时长',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          Wrap(spacing: 12, runSpacing: 8, children: [
                            SizedBox(width: 230, child: TextFormField(
                                key: const Key('request-minutes'),
                                controller: minutes,
                                enabled: !locked,
                                keyboardType: TextInputType.number,
                                maxLength: 2,
                                decoration: const InputDecoration(
                                    labelText: '分钟', errorMaxLines: 2),
                                validator: (v) {
                                  final minute = int.tryParse(v?.trim() ?? '');
                                  if (minute == null || minute < 0 || minute > 60) {
                                    return '请输入 0–60 的整数';
                                  }
                                  final second = seconds.text.trim().isEmpty
                                      ? 0 : int.tryParse(seconds.text.trim());
                                  return second != null && second >= 0 && second <= 59 &&
                                          requestedSeconds == null
                                      ? '合计需为 1 秒至 60 分钟' : null;
                                })),
                            SizedBox(width: 180, child: TextFormField(
                                key: const Key('request-seconds'),
                                controller: seconds,
                                enabled: !locked,
                                keyboardType: TextInputType.number,
                                maxLength: 2,
                                decoration: const InputDecoration(
                                    labelText: '秒（选填）', errorMaxLines: 2),
                                validator: (v) {
                                  final text = v?.trim() ?? '';
                                  final second = text.isEmpty ? 0 : int.tryParse(text);
                                  return second == null || second < 0 || second > 59
                                      ? '请输入 0–59 的整数或留空' : null;
                                })),
                          ]),
                          const Text('合计 1 秒至 60 分钟；秒数可留空。',
                              style: TextStyle(color: muted)),
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
                          if (stale && pending == null && !stopped && device != null)
                            TextButton(
                                onPressed: locked || loadingOptions
                                    ? null
                                    : viewAction(() => loadOptions(reset: true), view),
                                child: const Text('刷新可申请规则')),
                          if (pending != null)
                            Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Notice(stopped
                                    ? '原提交已停止，内容只读保留。请关闭后核对申请列表，不能再次提交旧请求。'
                                    : stale
                                        ? '原提交内容已锁定，当前范围或配置已变化。请关闭后核对申请列表。'
                                        : '提交结果尚未确认，原内容已锁定。重试会使用同一次提交，也可关闭后刷新申请列表。')),
                        ]),
                  ))),
          actions: [
            TextButton(
                onPressed: busy ? null : close,
                child: const Text('关闭')),
            FilledButton(
                onPressed: busy || stopped || loadingOptions || loadingDevices || stale
                    ? null
                    : viewAction(send, view),
                child: Text(busy
                    ? '提交中…'
                    : stopped
                        ? '原提交已停止'
                        : pending != null ? '重试原提交' : '提交申请')),
          ],
        ),
      );
  }
}
