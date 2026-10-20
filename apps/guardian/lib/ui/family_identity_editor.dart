import 'package:flutter/material.dart';
import '../core/family_identity_configuration.dart';
import 'design.dart';

class IdentityProvidersEditor extends StatefulWidget {
  final IdentityProviderVersion? currentVersion;
  final bool Function() isCurrent;
  final Future<void> Function(
      IdentityProviderSettings, Map<String, String>, bool) onSave;
  const IdentityProvidersEditor(
      {super.key,
      required this.currentVersion,
      required this.isCurrent,
      required this.onSave});
  @override
  IdentityProvidersEditorState createState() => IdentityProvidersEditorState();
}

class IdentityProvidersEditorState extends State<IdentityProvidersEditor>
    with WidgetsBindingObserver {
  final form = GlobalKey<FormState>();
  final sign = TextEditingController(),
      template = TextEditingController(),
      appId = TextEditingController(),
      package = TextEditingController(),
      certificate = TextEditingController(),
      accessId = TextEditingController(),
      accessSecret = TextEditingController(),
      token = TextEditingController(),
      wechatSecret = TextEditingController();
  bool replaceSms = false,
      replaceWechat = false,
      useToken = false,
      clearToken = false,
      busy = false,
      submitted = false;
  String? error;
  Iterable<TextEditingController> get secrets =>
      [accessId, accessSecret, token, wechatSecret];
  void clearSensitiveInput() {
    for (final controller in secrets) {
      controller.clear();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final settings = widget.currentVersion?.settings;
    sign.text = settings?.smsSignName ?? '';
    template.text = settings?.smsTemplateCode ?? '';
    appId.text = settings?.wechatAppId ?? '';
    package.text = settings?.parentPackageName ?? 'com.aimanager.parent';
    certificate.text = settings?.parentCertificateSha256 ?? '';
  }

  @override
  void didUpdateWidget(covariant IdentityProvidersEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isCurrent() ||
        oldWidget.currentVersion?.id != widget.currentVersion?.id) {
      clearSensitiveInput();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) clearSensitiveInput();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    clearSensitiveInput();
    for (final controller in [
      sign,
      template,
      appId,
      package,
      certificate,
      ...secrets
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get enabled => !busy && !submitted && widget.isCurrent();
  String? format(String? value, RegExp expression, String message,
      {bool required = false}) {
    final text = value ?? '';
    if (text.isEmpty) return required ? '请填写此项' : null;
    return expression.hasMatch(text) ? null : message;
  }

  Widget field(TextEditingController controller, String label,
          {Key? key,
          bool secret = false,
          int maximum = 128,
          String? Function(String?)? validator,
          String? hint}) =>
      Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: TextFormField(
              key: key,
              controller: controller,
              enabled: enabled,
              obscureText: secret,
              autocorrect: !secret,
              enableSuggestions: !secret,
              autofillHints: secret ? null : const [],
              maxLength: maximum,
              decoration: InputDecoration(
                  labelText: label, helperText: hint, counterText: ''),
              validator: validator));
  Future<void> save() async {
    if (!enabled || !(form.currentState?.validate() ?? false)) return;
    final replacements = <String, String>{
      if (replaceSms) 'smsAccessKeyId': accessId.text,
      if (replaceSms) 'smsAccessKeySecret': accessSecret.text,
      if (useToken) 'smsSecurityToken': token.text,
      if (replaceWechat) 'wechatAppSecret': wechatSecret.text,
    };
    final settings = IdentityProviderSettings(
        smsSignName: sign.text.trim(),
        smsTemplateCode: template.text.trim(),
        wechatAppId: appId.text.trim(),
        parentPackageName: package.text.trim(),
        parentCertificateSha256: certificate.text.trim().toLowerCase());
    setState(() {
      busy = true;
      error = null;
    });
    clearSensitiveInput();
    try {
      await widget.onSave(settings, replacements, clearToken);
      if (mounted) setState(() => submitted = true);
    } catch (_) {
      if (mounted) setState(() => error = '保存结果请回到配置页核对；密钥输入已清除，请勿重复提交。');
    } finally {
      replacements.clear();
      clearSensitiveInput();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('配置短信与微信',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w600, color: ink)),
            const SizedBox(height: 8),
            const Text('密钥只在本次提交中使用，保存后不会显示。空白配置可以稍后补齐。',
                style: TextStyle(color: muted, height: 1.6)),
            const SizedBox(height: 16),
            Flexible(
                child: SingleChildScrollView(
                    child: Form(
                        key: form,
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('短信',
                                  style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 12),
                              field(sign, '短信签名',
                                  maximum: 32,
                                  validator: (value) => value != null &&
                                          RegExp(r'[\x00-\x1f\x7f]')
                                              .hasMatch(value)
                                      ? '请使用单行签名'
                                      : null),
                              field(template, '短信模板编号',
                                  validator: (value) => format(
                                      value,
                                      RegExp(r'^SMS_[0-9]{1,32}$'),
                                      '格式示例：SMS_123456')),
                              Text(
                                  '短信密钥：${widget.currentVersion?.credentials.smsAccessKeySecret == true ? '已配置' : '未配置'}',
                                  style: const TextStyle(color: muted)),
                              SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('更换短信密钥'),
                                  value: replaceSms,
                                  onChanged: enabled
                                      ? (value) => setState(() {
                                            replaceSms = value;
                                            accessId.clear();
                                            accessSecret.clear();
                                          })
                                      : null),
                              if (replaceSms) ...[
                                field(accessId, 'AccessKey ID',
                                    key: const Key('identity-sms-access-id'),
                                    secret: true,
                                    validator: (value) => format(
                                        value,
                                        RegExp(r'^[A-Za-z0-9._-]{16,128}$'),
                                        '请核对 AccessKey ID',
                                        required: true)),
                                field(accessSecret, 'AccessKey Secret',
                                    key:
                                        const Key('identity-sms-access-secret'),
                                    secret: true,
                                    validator: (value) => format(
                                        value,
                                        RegExp(r'^[A-Za-z0-9+/=_-]{16,128}$'),
                                        '请核对 AccessKey Secret',
                                        required: true)),
                              ],
                              ExpansionTile(
                                  tilePadding: EdgeInsets.zero,
                                  title: const Text('临时安全令牌（可选）'),
                                  children: [
                                    SwitchListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: const Text('设置新的临时安全令牌'),
                                        value: useToken,
                                        onChanged: enabled
                                            ? (value) => setState(() {
                                                  useToken = value;
                                                  clearToken = false;
                                                  token.clear();
                                                })
                                            : null),
                                    if (useToken)
                                      field(token, 'STS 安全令牌',
                                          key: const Key('identity-sms-token'),
                                          secret: true,
                                          maximum: 8192,
                                          validator: (value) => format(
                                              value,
                                              RegExp(
                                                  r'^[A-Za-z0-9+/=._-]{16,8192}$'),
                                              '请核对临时安全令牌',
                                              required: true)),
                                    if (widget.currentVersion?.credentials
                                            .smsSecurityToken ==
                                        true)
                                      CheckboxListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: const Text('移除现有临时安全令牌'),
                                          value: clearToken,
                                          onChanged: enabled
                                              ? (value) => setState(() {
                                                    clearToken = value == true;
                                                    useToken = false;
                                                    token.clear();
                                                  })
                                              : null),
                                  ]),
                              const Divider(height: 32),
                              const Text('微信',
                                  style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 12),
                              field(appId, '微信移动应用 AppID',
                                  validator: (value) => format(
                                      value,
                                      RegExp(r'^wx[0-9a-fA-F]{16}$'),
                                      '请填写移动应用 AppID')),
                              field(package, '家长端包名',
                                  maximum: 200,
                                  validator: (value) => format(
                                      value,
                                      RegExp(
                                          r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$'),
                                      '请填写正式家长端包名')),
                              field(certificate, '正式签名 SHA-256',
                                  maximum: 64,
                                  validator: (value) => format(
                                      value,
                                      RegExp(r'^[0-9a-fA-F]{64}$'),
                                      '请填写 64 位十六进制摘要')),
                              Text(
                                  '微信密钥：${widget.currentVersion?.credentials.wechatAppSecret == true ? '已配置' : '未配置'}',
                                  style: const TextStyle(color: muted)),
                              SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('更换微信密钥'),
                                  value: replaceWechat,
                                  onChanged: enabled
                                      ? (value) => setState(() {
                                            replaceWechat = value;
                                            wechatSecret.clear();
                                          })
                                      : null),
                              if (replaceWechat)
                                field(wechatSecret, '微信 AppSecret',
                                    key: const Key('identity-wechat-secret'),
                                    secret: true,
                                    maximum: 32,
                                    validator: (value) => format(
                                        value,
                                        RegExp(r'^[0-9a-fA-F]{32}$'),
                                        '请填写 32 位微信密钥',
                                        required: true)),
                              if (error != null) Notice(error!, warning: true),
                              if (submitted)
                                const Notice(
                                    '本次提交已结束。请关闭窗口查看配置页结果；运行服务尚未自动更新。'),
                            ])))),
            const SizedBox(height: 16),
            Wrap(spacing: 12, runSpacing: 8, children: [
              FilledButton(
                  onPressed: enabled ? save : null,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                  child: Text(busy ? '提交中…' : '保存配置版本')),
              TextButton(
                  onPressed: busy
                      ? null
                      : () {
                          clearSensitiveInput();
                          Navigator.maybePop(context);
                        },
                  child: const Text('关闭')),
            ]),
          ]));
}
