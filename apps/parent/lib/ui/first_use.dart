import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../core/parent_api.dart';
import '../core/parent_session.dart';
import '../core/parent_durable_storage.dart';

Future<(String, Json)?> _pending(ParentDurableStorage store, String key,
    {required bool family}) async {
  final raw = await store.read(key: key);
  if (raw == null) return null;
  final value = jsonDecode(raw);
  if (value is! Json ||
      value['key'] is! String ||
      value['body'] is! Json ||
      !RegExp(r'^[a-f0-9-]{36}$').hasMatch(value['key'] as String)) {
    throw const FormatException('Invalid saved request');
  }
  final body = value['body'] as Json;
  if (family &&
      body.length == 2 &&
      body['adultGuardian'] == true &&
      body['declarationVersion'] == 'family-guardian-v1') {
    return (value['key'] as String, body);
  }
  final name = body[family ? 'name' : 'nickname'];
  if (name is! String ||
      name.trim().isEmpty ||
      name.length > (family ? 100 : 60) ||
      (family
          ? body.length != 3 ||
              body['kind'] != 'FAMILY' ||
              body['timeZone'] != 'Asia/Shanghai'
          : body.length != 2 ||
              !const {'UNDER_7', 'AGE_7_12', 'AGE_13_17'}
                  .contains(body['ageBand']))) {
    throw const FormatException('Invalid saved request');
  }
  return (value['key'] as String, body);
}

class FamilySetup extends StatefulWidget {
  final ParentSession session;
  final ParentDurableStorage? storage;
  const FamilySetup({super.key, required this.session, this.storage});
  @override
  State<FamilySetup> createState() => _FamilySetupState();
}

class _FamilySetupState extends State<FamilySetup> {
  final name = TextEditingController(text: '我的家庭');
  String requestKey = const Uuid().v4();
  late final store = widget.storage ?? ParentDurableStorage();
  late final actor = widget.session.profile?['subject'];
  Json? submitted;
  bool busy = true, ready = false;
  bool guardianDeclaration = false;
  bool get consumer => widget.session.profile?['canCreateTenant'] != true;
  bool get allowed => consumer
      ? (widget.session.profile?['canCreateFamily'] == true)
      : (widget.session.profile?['canCreateTenant'] == true);
  String get savedKey => 'parent.first-use.family.$actor';
  String? error;
  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.profile?['subject'] == actor;
  @override
  void initState() {
    super.initState();
    unawaited(restore());
  }

  Future<void> restore() async {
    try {
      final saved = await _pending(store, savedKey, family: true);
      if (!current) return;
      if (saved != null) {
        requestKey = saved.$1;
        submitted = saved.$2;
        if (submitted!['name'] is String) name.text = submitted!['name'];
        guardianDeclaration = submitted!['adultGuardian'] == true;
      }
      ready = true;
      error = null;
    } catch (_) {
      if (current) error = '无法读取上次创建进度，请重新读取后再继续。';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> create() async {
    if (!current ||
        !ready ||
        busy ||
        !allowed ||
        consumer && !guardianDeclaration) {
      return;
    }
    final title = name.text.trim();
    if (title.isEmpty) {
      setState(() => error = '请输入家庭名称。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      // Reuse the same key and body after a lost response; never duplicate a family on retry.
      submitted ??= consumer
          ? {'adultGuardian': true, 'declarationVersion': 'family-guardian-v1'}
          : {'name': title, 'kind': 'FAMILY', 'timeZone': 'Asia/Shanghai'};
      await store.write(
          key: savedKey,
          value: jsonEncode({'key': requestKey, 'body': submitted}));
      if (!current) return;
      final result = await widget.session.api.send(
          'POST',
          submitted!['adultGuardian'] == true
              ? '/family-onboarding'
              : '/tenants',
          body: submitted,
          idempotencyKey: requestKey,
          isCurrent: () => current);
      if (result is! Json || result['id'] is! String) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (!current) return;
      await widget.session.refreshWorkspaces();
      await store.delete(key: savedKey);
    } catch (failure) {
      if (current) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Center(
      child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.home_outlined, size: 52),
                    const SizedBox(height: 20),
                    Text('欢迎，先创建你的家庭',
                        style: Theme.of(context).textTheme.headlineSmall,
                        textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    const Text('创建后就能添加孩子、连接设备。', textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    if (allowed) ...[
                      if (!consumer)
                        TextField(
                            controller: name,
                            maxLength: 100,
                            enabled: ready && !busy && submitted == null,
                            decoration:
                                const InputDecoration(labelText: '家庭名称')),
                      const SizedBox(height: 16),
                      if (consumer)
                        CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: guardianDeclaration,
                            onChanged: busy || submitted != null
                                ? null
                                : (v) => setState(
                                    () => guardianDeclaration = v == true),
                            title: const Text('我是年满 18 周岁的合法监护人'),
                            subtitle:
                                const Text('确认有权为孩子连接设备和管理授权。声明不等于身份核验。')),
                      FilledButton.icon(
                          onPressed:
                              busy || !ready || consumer && !guardianDeclaration
                                  ? null
                                  : create,
                          icon: busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.add),
                          label: Text(busy
                              ? '正在准备…'
                              : submitted != null
                                  ? '继续创建家庭'
                                  : '创建我的家庭')),
                      if (!ready && !busy)
                        TextButton(
                            onPressed: restore, child: const Text('重新读取进度')),
                    ] else
                      Column(children: [
                        const Text(
                            '创建家庭需要服务端确认的已验证手机号。请通过手机号登录完成验证；服务尚未配置时不能创建。'),
                        const SizedBox(height: 12),
                        OutlinedButton(
                            onPressed: widget.session.busy
                                ? null
                                : () =>
                                    widget.session.signInWithProvider('phone'),
                            child: const Text('前往手机号验证'))
                      ]),
                    if (error != null)
                      Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(error!,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error))),
                  ]))));
}

class ChildProfileForm extends StatefulWidget {
  final ParentSession session;
  final ValueChanged<Json>? onSaved;
  final ValueChanged<bool>? onBusyChanged;
  final ParentDurableStorage? storage;
  final String? expectedActor, expectedTenant;
  const ChildProfileForm(
      {super.key,
      required this.session,
      this.onSaved,
      this.onBusyChanged,
      this.storage,
      this.expectedActor,
      this.expectedTenant});
  @override
  State<ChildProfileForm> createState() => _ChildProfileFormState();
}

class _ChildProfileFormState extends State<ChildProfileForm> {
  final form = GlobalKey<FormState>();
  final nickname = TextEditingController();
  String requestKey = const Uuid().v4();
  late final store = widget.storage ?? ParentDurableStorage();
  late final actor = widget.expectedActor ?? widget.session.profile?['subject'];
  late final tenant = widget.expectedTenant ?? widget.session.tenant?['id'];
  String? ageBand, error;
  Json? submitted;
  bool busy = true, saved = false, ready = false;
  String get savedKey => 'parent.first-use.child.$tenant.$actor';
  bool get current =>
      mounted &&
      widget.session.authenticated &&
      widget.session.canDecide &&
      widget.session.profile?['subject'] == actor &&
      widget.session.tenant?['id'] == tenant;
  @override
  void initState() {
    super.initState();
    widget.session.addListener(scopeChanged);
    scopeChanged();
    unawaited(restore());
  }

  void scopeChanged() {
    if (current || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> restore() async {
    try {
      final pending = await _pending(store, savedKey, family: false);
      if (!current) return;
      if (pending != null) {
        requestKey = pending.$1;
        submitted = pending.$2;
        nickname.text = submitted!['nickname'] as String;
        ageBand = submitted!['ageBand'] as String;
      }
      ready = true;
      error = null;
    } catch (_) {
      if (current) error = '无法读取上次保存进度，请重新读取后再继续。';
    } finally {
      if (mounted) {
        setState(() => busy = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(scopeChanged);
    nickname.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!current || !ready || busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    widget.onBusyChanged?.call(true);
    try {
      submitted ??= {'nickname': nickname.text.trim(), 'ageBand': ageBand};
      await store.write(
          key: savedKey,
          value: jsonEncode({'key': requestKey, 'body': submitted}));
      if (!current) return;
      final result = await widget.session.api.send(
          'POST', '/tenants/$tenant/subjects',
          body: submitted,
          idempotencyKey: requestKey,
          isCurrent: () => current);
      if (result is! Json || result['id'] is! String) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      if (!current) return;
      await store.delete(key: savedKey);
      if (!current) return;
      if (widget.onSaved != null) {
        widget.onSaved!(result);
      } else {
        setState(() => saved = true);
      }
    } catch (failure) {
      if (current) setState(() => error = '$failure');
    } finally {
      if (mounted) {
        setState(() => busy = false);
        widget.onBusyChanged?.call(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: Form(
          key: form,
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('只需昵称和年龄段，之后可以在档案中修改。'),
                const SizedBox(height: 16),
                TextFormField(
                    controller: nickname,
                    maxLength: 60,
                    enabled: ready && !busy && submitted == null,
                    decoration: const InputDecoration(labelText: '孩子昵称'),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? '请输入孩子昵称'
                        : null),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                    value: ageBand,
                    decoration: const InputDecoration(labelText: '年龄段'),
                    items: const [
                      DropdownMenuItem(value: 'UNDER_7', child: Text('7 岁以下')),
                      DropdownMenuItem(
                          value: 'AGE_7_12', child: Text('7–12 岁')),
                      DropdownMenuItem(
                          value: 'AGE_13_17', child: Text('13–17 岁'))
                    ],
                    onChanged: !ready || busy || submitted != null
                        ? null
                        : (value) => setState(() => ageBand = value),
                    validator: (value) => value == null ? '请选择年龄段' : null),
                if (error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
                const SizedBox(height: 20),
                FilledButton(
                    onPressed: !ready || busy || saved ? null : save,
                    child: Text(saved
                        ? '档案已保存'
                        : busy
                            ? '正在保存…'
                            : submitted != null
                                ? '继续保存'
                                : '保存儿童档案')),
                if (!ready && !busy)
                  TextButton(onPressed: restore, child: const Text('重新读取进度')),
                if (submitted != null && !saved && !busy)
                  const Text('上次保存尚未完成核对。继续保存会核对原请求，不会重新创建。'),
              ])));
}
