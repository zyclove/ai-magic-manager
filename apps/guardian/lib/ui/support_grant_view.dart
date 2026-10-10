import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/api.dart';
import '../core/support.dart';
import '../core/support_repository.dart';
import 'support_view_state.dart';

class SupportGrantView extends StatefulWidget {
  final SupportRepository repository;
  final String deviceId, registrationId, deviceName;
  final int deviceVersion;
  final bool Function() current;
  final Listenable? accessChanges;
  final VoidCallback onClose, onReauth;
  const SupportGrantView(
      {super.key,
      required this.repository,
      required this.deviceId,
      required this.registrationId,
      required this.deviceVersion,
      required this.deviceName,
      required this.current,
      this.accessChanges,
      required this.onClose,
      required this.onReauth});
  @override
  State<SupportGrantView> createState() => _SupportGrantViewState();
}

class _SupportGrantViewState extends State<SupportGrantView>
    with SupportViewState<SupportGrantView> {
  final code = TextEditingController(),
      duration = TextEditingController(text: '60');
  final selected = <String>{'DEVICE_STATUS'};
  SupportPairing? recipient;
  SupportGrantDraft? pending;
  SupportGrant? created;
  bool confirmed = false;
  bool createdExpiryShown = false;
  @override
  bool Function() get scopeCurrent => widget.current;
  @override
  Listenable? get accessChanges => widget.accessChanges;
  @override
  Object get scopeIdentity => (
        widget.repository.actor,
        widget.repository.tenant,
        widget.deviceId,
        widget.registrationId,
        widget.deviceVersion
      );
  @override
  void clearSensitive() {
    code.clear();
    duration.text = '60';
    recipient = null;
    pending = null;
    created = null;
    confirmed = false;
    createdExpiryShown = false;
    selected
      ..clear()
      ..add('DEVICE_STATUS');
  }

  @override
  void timeChanged() {
    if (created != null &&
        created!.state == 'ACTIVE' &&
        created!.expiresAt <= now &&
        !createdExpiryShown) setState(() => createdExpiryShown = true);
    if (recipient != null && !recipient!.pendingAt(now) && pending == null)
      setState(() {
        recipient = null;
        confirmed = false;
        code.clear();
        error = const ApiFailure(404, 'SUPPORT_PAIRING_UNAVAILABLE');
      });
  }

  @override
  void dispose() {
    code.dispose();
    duration.dispose();
    super.dispose();
  }

  bool get editable => usable && !busy && pending == null && created == null;
  Future<void> resolve() async {
    if (!editable) return;
    setState(() {
      recipient = null;
      confirmed = false;
    });
    await perform(() => widget.repository.resolve(code.text.trim()), (value) {
      if (!value.pendingAt(now)) {
        error = const ApiFailure(404, 'SUPPORT_PAIRING_UNAVAILABLE');
        return;
      }
      recipient = value;
    });
  }

  Future<void> submit() async {
    if (!usable || busy || created != null) return;
    if (pending == null) {
      final minutes = int.tryParse(duration.text), pair = recipient;
      if (!confirmed ||
          pair == null ||
          !pair.pendingAt(now) ||
          minutes == null ||
          minutes < 5 ||
          minutes > 1440 ||
          selected.isEmpty) {
        setState(
            () => error = const ApiFailure(400, 'INVALID_SUPPORT_SELECTION'));
        return;
      }
      pending = SupportGrantDraft(
          tenantId: widget.repository.tenant!,
          deviceId: widget.deviceId,
          registrationId: widget.registrationId,
          recipientActorId: pair.recipientActorId,
          pairingCode: code.text.trim(),
          deviceVersion: widget.deviceVersion,
          durationMinutes: minutes,
          diagnosticTypes: selected.toList());
    }
    final draft = pending!;
    await perform(() => widget.repository.createGrant(draft), (value) {
      created = value;
      pending = null;
      recipient = null;
      confirmed = false;
      code.clear();
    }, failed: (failure) {
      if (!ambiguousSupportFailure(failure)) {
        pending = null;
        if (failure.code == 'SUPPORT_PAIRING_UNAVAILABLE' ||
            failure.code == 'SUPPORT_RECIPIENT_CHANGED') {
          recipient = null;
          confirmed = false;
        }
      }
    });
  }

  Widget frozenField(String id, String label, String value) => InputDecorator(
      key: ValueKey(id),
      decoration: InputDecoration(
          labelText: label, helperText: '内容已固定', enabled: false),
      child: SelectionArea(child: Text(value.isEmpty ? '未填写' : value)));

  Widget form() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        supportFact(context, '授权设备', widget.deviceName),
        const Text('接收人核对', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text('让接收人在“支持协作”中生成配对码。身份信息由登录服务提供，不代表平台官方客服认证。'),
        const SizedBox(height: 12),
        if (!editable)
          frozenField('support-pairing-code', '接收人的配对码', code.text)
        else
          TextField(
              key: const ValueKey('support-pairing-code'),
              controller: code,
              enabled: editable,
              maxLength: 43,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                  labelText: '接收人的配对码', helperText: '配对码有效期为 10 分钟，仅使用一次。'),
              onChanged: (_) => setState(() {
                    recipient = null;
                    confirmed = false;
                    error = null;
                  })),
        Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
                onPressed: editable ? resolve : null,
                icon: const Icon(Icons.person_search_outlined),
                label: const Text('核对接收人'))),
        if (recipient != null)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        supportFact(context, '接收人', recipient!.recipientLabel),
                        supportFact(context, '已验证邮箱',
                            recipient!.verifiedEmail ?? '未提供已验证邮箱'),
                        supportFact(
                            context, '账号标识', recipient!.recipientActorId),
                        Text('配对截止：${supportTime(recipient!.expiresAt)}')
                      ]))),
        const SizedBox(height: 16),
        const Text('允许查看的诊断范围', style: TextStyle(fontWeight: FontWeight.w600)),
        for (final type in supportTypes)
          CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(supportTypeLabels[type]!),
              subtitle: Text(switch (type) {
                'DEVICE_STATUS' => '设备版本、管理状态及最后心跳。',
                'CAPABILITIES' => '设备自报能力和权限状态，不含应用使用内容。',
                _ => '配置指纹、下发状态和确认时间，不含规则正文。'
              }),
              value: selected.contains(type),
              onChanged: editable
                  ? (value) => setState(() {
                        if (value == true) {
                          selected.add(type);
                        } else {
                          selected.remove(type);
                        }
                        confirmed = false;
                      })
                  : null),
        const SizedBox(height: 12),
        if (!editable)
          frozenField('support-duration', '授权时长（分钟）', duration.text)
        else
          TextField(
              key: const ValueKey('support-duration'),
              controller: duration,
              enabled: editable,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4)
              ],
              decoration: const InputDecoration(
                  labelText: '授权时长（分钟）',
                  helperText: '5–1440 分钟，默认 60 分钟；提交成功后开始计时。'),
              onChanged: (_) => setState(() => confirmed = false)),
        const SizedBox(height: 16),
        const Text(
            '接收人只能查看选中的诊断信息，不能控制设备。你可以在“支持协作 → 本空间授权”随时撤销；已被接收人保存的副本无法远程收回。'),
        CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('我已核对接收人身份与授权范围'),
            value: confirmed,
            onChanged: editable && recipient != null
                ? (value) => setState(() => confirmed = value ?? false)
                : null),
      ]);
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('限时支持授权', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('明确接收人、范围与期限后，再开放诊断访问。'),
        const SizedBox(height: 12),
        if (busy) const LinearProgressIndicator(),
        const Divider(),
        Expanded(
            child: SingleChildScrollView(
                child: !usable
                    ? Text(invalidated || !scopeCurrent()
                        ? '账号或工作空间已变化，请关闭后重新打开。'
                        : '已进入后台，配对与授权内容已清除。')
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                            if (cleared)
                              const Padding(
                                  padding: EdgeInsets.only(bottom: 12),
                                  child: Text('页面恢复后，请重新核对配对信息。')),
                            if (created != null) ...[
                              const Text('授权记录已确认',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 12),
                              supportFact(context, '当前状态',
                                  supportGrantState(created!, now)),
                              supportFact(
                                  context, '接收人', created!.recipientLabel),
                              supportFact(
                                  context,
                                  '授权范围',
                                  created!.diagnosticTypes
                                      .map((t) => supportTypeLabels[t])
                                      .join('、')),
                              supportFact(context, '截止时间（本机时间）',
                                  supportTime(created!.expiresAt)),
                              const Text('可在“支持协作 → 本空间授权”查看或撤销此记录。')
                            ] else
                              form(),
                          ]))),
        if (usable && error != null) supportFailure(error!, widget.onReauth),
        if (usable && pending != null && !busy)
          const Text('提交结果尚未确认。请按原内容重试；如关闭窗口，请先到本空间授权列表确认结果，避免重复创建。'),
        const Divider(),
        Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              TextButton(onPressed: widget.onClose, child: const Text('关闭')),
              if (created == null)
                FilledButton(
                    onPressed: usable &&
                            !busy &&
                            (pending != null ||
                                (confirmed &&
                                    recipient != null &&
                                    selected.isNotEmpty))
                        ? submit
                        : null,
                    child: Text(busy && pending != null
                        ? '正在提交…'
                        : pending == null
                            ? '确认授权'
                            : '按原内容重试'))
            ])
      ]));
}
