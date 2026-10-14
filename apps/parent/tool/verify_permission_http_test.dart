import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parent/core/permission_consent.dart';
import 'package:parent/core/permission_observation.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:usage_reporting/usage_reporting.dart';
import 'package:uuid/uuid.dart';

/// 仅用于由隔离后端测试创建的回环 HTTP 夹具，不接受生产地址。
/// 实际传输/业务控制器，内存存储和认证回调为显式替身。
class _Storage extends ParentDurableStorage {
  final values = <String, String>{};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

/// 完整消费真实成功响应后模拟连接丢失，确认恢复流程不会再写入。
class _LostResponseClient extends http.BaseClient {
  final http.Client delegate = http.Client();
  bool loseNextChange = true;
  int changes = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final value = await delegate.send(request);
    if (request.url.path.endsWith('/changes')) {
      changes++;
      if (loseNextChange && value.statusCode == 200) {
        loseNextChange = false;
        await value.stream.drain<void>();
        throw http.ClientException('Synthetic lost acknowledgement');
      }
    }
    return value;
  }

  @override
  void close() => delegate.close();
}

void main() {
  test(
      'production parent consent controller interoperates with isolated Spring HTTP',
      () async {
    final raw = Platform.environment['PARENT_PERMISSION_HTTP_FIXTURE'];
    if (raw == null) throw StateError('An isolated HTTP fixture is required');
    final fixture = jsonDecode(raw) as Map<String, dynamic>;
    final root = Uri.parse(fixture['apiRoot'] as String);
    if (fixture['testOnly'] != true ||
        root.scheme != 'http' ||
        root.host != '127.0.0.1' ||
        root.path != '/api/v1' ||
        root.hasQuery ||
        root.hasFragment ||
        root.userInfo.isNotEmpty) {
      throw StateError('Only explicit loopback fixtures are permitted');
    }
    final target = UsageReportTarget(fixture['deviceId'],
        fixture['registrationId'], fixture['subjectId'], 'Fixture device',
        platform: 'ANDROID');
    final transport = _LostResponseClient();
    final api = ParentApi(() async => fixture['token'] as String,
        baseUrl: root.toString(), client: transport);
    final store = PermissionChangeStore(storage: _Storage());
    ParentPermissionConsent create() => ParentPermissionConsent(
        api: api,
        store: store,
        tenant: fixture['tenantId'],
        actor: fixture['actorId'],
        target: target,
        isCurrent: () => true,
        foreground: () => true,
        reauthenticate: () async => true);
    final first = create();
    await first.load();
    expect(first.error, isNull);
    expect(first.settings!.enabled, isFalse);
    await first.submit(enabled: true, reason: 'HTTP fixture consent');
    expect(first.error, isA<ParentApiException>());
    expect(first.pending, isNotNull);
    final requestId = first.pending!['requestId'];
    first.dispose();
    final recovered = create();
    try {
      await recovered.load();
      expect(recovered.error, isNull);
      expect(recovered.pending!['requestId'], requestId);
      expect(recovered.settings!.version, 1);
      expect(recovered.settings!.enabled, isTrue);
      await recovered.query();
      expect(recovered.error, isNull);
      expect(recovered.committed!.version, 1);
      // Explicit fixture device uses the real credential filter and reporting endpoints.
      // These supplied facts are not evidence of a physical Android permission grant.
      await api.send('PUT',
          '/tenants/${fixture['tenantId']}/devices/${target.deviceId}/observation-settings',
          version: 0,
          idempotencyKey: const Uuid().v4(),
          body: {
            'inventoryEnabled': true,
            'usageEnabled': false,
            'reason': 'HTTP fixture inventory consent'
          });
      final deviceApi = ParentApi(() async => fixture['deviceToken'],
          baseUrl: root.toString());
      final viewer = ParentPermissionView(
          api: api,
          tenant: fixture['tenantId'],
          target: target,
          isCurrent: () => true,
          foreground: () => true);
      try {
        final digest = List.filled(64, 'a').join();
        await deviceApi
            .send('POST', '/device-api/application-inventory', body: {
          'sequence': 1,
          'authorizationVersion': 1,
          'visibility': 'VISIBLE_PACKAGES',
          'applications': [
            {
              'packageName': 'org.example.study',
              'displayName': 'Fixture study',
              'profile': 'PRIMARY',
              'signingDigests': [digest],
              'versionCode': 5,
              'systemApplication': false
            }
          ]
        });
        await deviceApi
            .send('POST', '/device-api/permission-observations', body: {
          'reportId': const Uuid().v4(),
          'sequence': 1,
          'authorizationVersion': 1,
          'packageName': 'org.example.study',
          'profile': 'PRIMARY',
          'signingDigests': [digest],
          'versionCode': 5,
          'observedAt': DateTime.now().millisecondsSinceEpoch,
          'source': 'ANDROID_PACKAGE_MANAGER',
          'permissions': [
            {
              'permissionName': 'android.permission.RECORD_AUDIO',
              'classification': 'DANGEROUS',
              'observedGrant': 'GRANTED'
            }
          ]
        });
        await viewer.load();
        expect(viewer.error, isNull);
        await viewer.load(app: viewer.inventory!.applications.single);
        expect(viewer.error, isNull);
        expect(viewer.result!.status, 'RECENT');
        expect(viewer.result!.permissions.single.observedGrant, 'GRANTED');
        // Updating the observed app identity invalidates the older permission view.
        await deviceApi.send('POST', '/device-api/application-inventory', body: {
          'sequence': 2, 'authorizationVersion': 1, 'visibility': 'VISIBLE_PACKAGES',
          'applications': [{'packageName': 'org.example.study', 'displayName': 'Fixture study',
            'profile': 'PRIMARY', 'signingDigests': [digest], 'versionCode': 6, 'systemApplication': false}]
        });
        await viewer.load(app: viewer.inventory!.applications.single);
        expect(viewer.error, isNull); expect(viewer.result!.status, 'UNKNOWN');
        expect(viewer.result!.permissions, isEmpty);
      } finally {
        viewer.dispose();
        deviceApi.close();
      }
      // A second administrator workflow withdraws the grant through the legacy endpoint.
      await api.send('PUT',
          '/tenants/${fixture['tenantId']}/devices/${target.deviceId}/permission-observation-settings',
          version: 1,
          idempotencyKey: const Uuid().v4(),
          body: {'enabled': false, 'reason': 'HTTP fixture withdrawal'});
      await recovered.query();
      expect(recovered.error, isNull);
      expect(recovered.committed!.enabled, isTrue);
      expect(recovered.settings!.enabled, isFalse);
      expect(recovered.settings!.version, 2);
      expect(transport.changes, 1);
      await recovered.acknowledge();
      expect(recovered.pending, isNull);
      await recovered.load();
      expect(recovered.settings!.version, 2);
      expect(transport.changes, 1);
    } finally {
      recovered.dispose();
      api.close();
    }
  });
}
