// Isolated synthetic UI preview. No real identity session, credentials or supplier requests.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/family_identity_configuration.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/family_identity_page.dart';

void main() {
  runApp(MaterialApp(
      title: '短信与微信 · 合成预览',
      debugShowCheckedModeBanner: false,
      theme: consoleTheme(),
      home: const _Preview()));
}

class _Preview extends StatefulWidget {
  const _Preview();
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  final changes = ChangeNotifier();
  final versions = <String, Json>{},
      releases = <String, Json>{},
      runs = <String, Json>{};
  late final MockClient transport;
  late final Api api;
  bool requireMfa = false, unknownNextSave = false;
  int generation = 0, revision = 1;
  Json get settings => {
        'smsSignName': '家庭服务示例',
        'smsTemplateCode': 'SMS_123456',
        'wechatAppId': 'wx0123456789abcdef',
        'parentPackageName': 'com.aimanager.parent',
        'parentCertificateSha256': 'a' * 64
      };
  Json version(String id, int number, Json publicSettings) => {
        'id': id,
        'version': number,
        'baseVersion': number - 1,
        'createdAt': 1792200000000,
        'settings': publicSettings,
        'credentials': {
          'otpHmacKey': true,
          'smsAccessKeyId': true,
          'smsAccessKeySecret': true,
          'smsSecurityToken': false,
          'wechatAppSecret': true
        },
        'readinessStatus': 'READY'
      };
  Json check(String id, String label,
          {String stage = '配置准备', String status = 'READY'}) =>
      {
        'id': id,
        'label': label,
        'stage': stage,
        'status': status,
        'reasonCode': status == 'READY'
            ? 'LOCAL_FORMAT_READY'
            : 'REAL_EXECUTION_NOT_OBSERVED',
        'action':
            status == 'READY' ? '仅说明格式已核对，仍需受控应用和真实联调。' : '请在正式签名真机和受限环境完成真实验证。'
      };
  @override
  void initState() {
    super.initState();
    versions['11111111-1111-4111-8111-111111111111'] =
        version('11111111-1111-4111-8111-111111111111', 1, settings);
    transport = MockClient((request) async {
      Json value;
      int status = 200;
      final path = request.url.path
          .replaceFirst('/api/v1/platform/identity-providers', '');
      if (requireMfa) {
        return http.Response(jsonEncode({'errorCode': 'REAUTH_REQUIRED'}), 401,
            headers: {'content-type': 'application/json'});
      }
      final body = request.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(request.body) as Json;
      if (request.method == 'GET' && path == '/status') {
        value = {
          'environmentId': 'synthetic-cn-preview',
          'capabilities': {
            'canRead': true,
            'canManage': true,
            'canTest': true,
            'secretStorageReady': true,
            'releasePreparationReady': true
          },
          'latestVersion': revision,
          'version': versions.values.last,
          'readinessChecks': [],
          'runtimeStatus': 'APPLY_REQUIRED',
          'salesAllowed': false
        };
      } else if (request.method == 'GET' && path == '/release-status') {
        value = {
          'environmentId': 'synthetic-cn-preview',
          'runtimeRevision': 0,
          'observationReady': false,
          'executorReady': false,
          'activeOperation': null,
          'confirmedOperation': null,
          'rollbackTargets': [],
          'runtimeStatus': 'APPLY_REQUIRED',
          'salesAllowed': false,
        };
      } else if (request.method == 'POST' && path == '/versions') {
        revision++;
        value = version(
            body['id'], revision, Map<String, dynamic>.from(body['settings']));
        versions[value['id']] = value;
        if (unknownNextSave) {
          unknownNextSave = false;
          throw http.ClientException('Synthetic interrupted response');
        }
      } else if (request.method == 'GET' && path.startsWith('/versions/')) {
        value = versions[path.split('/').last] ??
            {'errorCode': 'IDENTITY_PROVIDER_NOT_FOUND'};
        if (value.containsKey('errorCode')) status = 404;
      } else if (request.method == 'POST' && path.endsWith('/validations')) {
        value = {
          'versionId': path.split('/')[2],
          'readinessStatus': 'READY',
          'checks': [
            check('SMS_FORMAT', '短信配置格式'),
            check('WECHAT_FORMAT', '微信配置格式')
          ],
          'runtimeStatus': 'APPLY_REQUIRED',
          'salesAllowed': false
        };
      } else if (request.method == 'POST' &&
          path.endsWith('/release-preparations')) {
        value = {
          'id': body['id'],
          'versionId': path.split('/')[2],
          'status': 'PREPARED',
          'reasonCode': 'CONTROLLED_APPLY_REQUIRED',
          'runtimeStatus': 'APPLY_REQUIRED',
          'salesAllowed': false
        };
        releases[value['id']] = value;
      } else if (request.method == 'GET' &&
          path.startsWith('/release-preparations/')) {
        value = releases[path.split('/').last] ??
            {'errorCode': 'IDENTITY_PROVIDER_NOT_FOUND'};
        if (value.containsKey('errorCode')) status = 404;
      } else if (request.method == 'POST' && path == '/acceptance-runs') {
        value = {
          ...body,
          'createdAt': 1792200000000,
          'status': 'BLOCKED',
          'checks': identityRequiredAcceptanceCases
              .map((id) => check(id, '待真实联调', stage: '真实联调', status: 'BLOCKED'))
              .toList(),
          'runtimeStatus': 'APPLY_REQUIRED',
          'salesAllowed': false,
          'providerRequestsPerformed': false
        };
        runs[value['id']] = value;
      } else if (request.method == 'GET' &&
          path.startsWith('/acceptance-runs/')) {
        value = runs[path.split('/').last] ??
            {'errorCode': 'IDENTITY_PROVIDER_NOT_FOUND'};
        if (value.containsKey('errorCode')) status = 404;
      } else {
        value = {'errorCode': 'IDENTITY_PROVIDER_NOT_FOUND'};
        status = 404;
      }
      return http.Response(jsonEncode(value), status,
          headers: {'content-type': 'application/json'});
    });
    api =
        Api(() async => transport, baseUrl: 'https://synthetic.invalid/api/v1');
  }

  @override
  void dispose() {
    transport.close();
    changes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      body: SafeArea(
          child: SingleChildScrollView(
              child: Center(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1260),
                      child: Padding(
                          padding: EdgeInsets.all(
                              MediaQuery.sizeOf(context).width < 600 ? 18 : 32),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Notice('仅合成界面示例：无真实供应商、密钥、登录会话或后台连接。'),
                                const SizedBox(height: 12),
                                Wrap(spacing: 16, runSpacing: 8, children: [
                                  OutlinedButton(
                                      onPressed: () => setState(() {
                                            requireMfa = true;
                                            generation++;
                                          }),
                                      child: const Text('模拟需要重新验证')),
                                  OutlinedButton(
                                      onPressed: () => setState(
                                          () => unknownNextSave = true),
                                      child: Text(unknownNextSave
                                          ? '下次保存将模拟结果未知'
                                          : '模拟下次保存结果未知')),
                                ]),
                                const SizedBox(height: 24),
                                IdentityProvidersPage(
                                    key: ValueKey(generation),
                                    api: api,
                                    actor: 'synthetic-preview-operator',
                                    canRead: true,
                                    canManage: true,
                                    canTest: true,
                                    changes: changes,
                                    isCurrent: () => mounted,
                                    reauthenticate: () => setState(() {
                                          requireMfa = false;
                                          generation++;
                                        })),
                              ])))))));
}
