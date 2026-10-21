import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../core/family.dart';
import '../core/family_suggestion.dart';
import '../core/parent_durable_storage.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import 'family_rules_page.dart';
import 'family_workspace.dart';

class FamilyAssistantPage extends StatefulWidget {
  final ParentSession session;
  final FamilyChild child;
  final String task;
  final ParentDurableStorage? pendingStorage;
  const FamilyAssistantPage(
      {super.key,
      required this.session,
      required this.child,
      required this.task,
      this.pendingStorage});
  @override
  State<FamilyAssistantPage> createState() => _FamilyAssistantPageState();
}

class _FamilyAssistantPageState extends State<FamilyAssistantPage>
    with FamilyScope {
  @override
  ParentSession get session => widget.session;
  final prompt = TextEditingController();
  bool consent = false, busy = false;
  bool restoring = true;
  late final FamilySuggestionCoordinator suggestions;
  Json? result;
  Object? error;
  String? draftKey;
  String? selectedDeviceId;
  @override
  void initState() {
    super.initState();
    if (widget.child.devices.length == 1) {
      selectedDeviceId = widget.child.devices.single.id;
    }
    suggestions = FamilySuggestionCoordinator(
        service: service,
        actor: scopeActor,
        subjectId: widget.child.id,
        task: widget.task,
        storage: widget.pendingStorage);
    restore();
  }

  Future<void> restore() async {
    if (!current) return;
    setState(() {
      restoring = true;
      error = null;
    });
    try {
      await suggestions.restore();
      if (current && suggestions.pendingPrompt != null) {
        prompt.text = suggestions.pendingPrompt!;
        selectedDeviceId =
            suggestions.pending?['deviceId'] as String? ?? selectedDeviceId;
        consent = true;
      }
    } catch (e) {
      if (current) setState(() => error = e);
    } finally {
      if (current) setState(() => restoring = false);
    }
  }

  @override
  void dispose() {
    prompt.dispose();
    super.dispose();
  }

  Future<void> generate() async {
    if (!current ||
        busy ||
        restoring ||
        !suggestions.loaded ||
        !consent ||
        prompt.text.trim().isEmpty) return;
    if (widget.task == 'REPORT_EXPLANATION' && selectedDeviceId == null) {
      setState(() =>
          error = const ParentApiException(400, 'ASSISTANT_DEVICE_REQUIRED'));
      return;
    }
    setState(() {
      busy = true;
      error = null;
      result = null;
      draftKey = null;
    });
    try {
      final value = await suggestions.submit(
          prompt: prompt.text,
          cloudConsent: consent,
          deviceId:
              widget.task == 'REPORT_EXPLANATION' ? selectedDeviceId : null);
      if (current) {
        setState(() {
          result = value;
          consent = false;
        });
      }
    } catch (e) {
      if (current) setState(() => error = e);
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  Future<void> draft() async {
    if (!current ||
        busy ||
        result?['status'] != 'READY' ||
        result?['ruleDraft'] is! Json) return;
    setState(() {
      busy = true;
      error = null;
    });
    draftKey ??= const Uuid().v4();
    try {
      final data = await service.write('POST',
          '/assistant/suggestions/${Uri.encodeComponent(result!['id'])}/drafts',
          body: {}, idempotencyKey: draftKey);
      if (data['requiresConfirmation'] != true ||
          data['subjectId'] != widget.child.id ||
          data['ruleDraft'] is! Json ||
          data['ruleVersion'] is! int) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (!mounted || !current) return;
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => FamilyRulesPage(
              session: session,
              child: widget.child,
              initialDraft: data['ruleDraft'],
              initialDraftVersion: data['ruleVersion'])));
    } catch (e) {
      if (current) setState(() => error = e);
    } finally {
      if (current) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title: Text(widget.task == 'RULE_DRAFT' ? '助手 · 规则草稿' : '助手 · 报告解释')),
      body: !current
          ? const Center(child: Text('当前家庭或权限已变化，请返回重新打开。'))
          : ListView(padding: const EdgeInsets.all(20), children: [
              Text('为${widget.child.nickname}整理一点思路',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700, color: familyInk)),
              const SizedBox(height: 12),
              const Text('建议用于辅助家长判断。助手不会自动保存规则，也不会诊断或评价孩子。',
                  style: TextStyle(color: familyMuted)),
              const SizedBox(height: 20),
              if (widget.task == 'REPORT_EXPLANATION') ...[
                DropdownButtonFormField<String>(
                    value: selectedDeviceId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '解释哪台设备的报告？'),
                    items: widget.child.devices
                        .map((d) => DropdownMenuItem(
                            value: d.id, child: Text(d.displayName)))
                        .toList(),
                    onChanged: busy || restoring || suggestions.pending != null
                        ? null
                        : (value) => setState(() {
                              selectedDeviceId = value;
                              consent = false;
                              result = null;
                            })),
                const SizedBox(height: 16),
              ],
              TextField(
                  controller: prompt,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 500,
                  enabled: !busy && !restoring && suggestions.pending == null,
                  onChanged: (_) => setState(() {
                        consent = false;
                        result = null;
                      }),
                  decoration: InputDecoration(
                      labelText: widget.task == 'RULE_DRAFT'
                          ? '希望怎样安排？'
                          : '想了解报告中的什么？',
                      hintText: '请勿填写真实姓名、联系方式或其他敏感信息')),
              CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: consent,
                  onChanged: busy || restoring || suggestions.pending != null
                      ? null
                      : (v) => setState(() => consent = v == true),
                  title: const Text('同意本次云端处理'),
                  subtitle: const Text('将本次文字和所选孩子必要的规则或已授权报告摘要发送至中国内地模型服务。')),
              const FamilyNotice(
                  '会员每月最多 100 次，试用最多 10 次；剩余次数以服务结果为准。未同意时仍可手动设置规则与查看报告。'),
              if (error != null) FamilyNotice(familyError(error!), error: true),
              if (suggestions.pending != null)
                const FamilyNotice(
                    '上次建议请求结果待核对。原内容和授权已加密保存在本机，继续会重用原请求，不会创建新的计次操作。'),
              if (!suggestions.loaded && !restoring)
                OutlinedButton(
                    onPressed: restore, child: const Text('重新读取助手进度')),
              FilledButton.icon(
                  onPressed:
                      busy || restoring || !suggestions.loaded || !consent
                          ? null
                          : generate,
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: Text(busy
                      ? '正在整理…'
                      : suggestions.pending != null
                          ? '核对原建议请求'
                          : '生成建议')),
              if (busy || restoring)
                const Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator()),
              if (result != null)
                FamilyPanel(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(
                          result!['status'] == 'FALLBACK'
                              ? '当前可用的手动建议'
                              : '请你核对的建议',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 12),
                      SelectableText(result!['summary']),
                      for (final evidence in result!['evidence'])
                        if (evidence is Json &&
                            evidence['label'] is String &&
                            evidence['value'] != null)
                          Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                  '${evidence['label']}：${evidence['value']}')),
                      for (final limitation in result!['limitations'])
                        Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text('说明：$limitation',
                                style: const TextStyle(color: familyMuted))),
                      if (result!['remainingRequests'] is int)
                        Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child:
                                Text('本期剩余 ${result!['remainingRequests']} 次')),
                      if (result!['status'] == 'READY' &&
                          result!['ruleDraft'] is Json) ...[
                        const SizedBox(height: 20),
                        const Text('下一步只打开草稿，仍需逐项核对并确认保存。'),
                        const SizedBox(height: 10),
                        OutlinedButton(
                            onPressed: busy ? null : draft,
                            child: const Text('核对规则草稿')),
                      ],
                    ])),
            ]));
}
