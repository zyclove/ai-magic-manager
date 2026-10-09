import 'dart:convert';
import 'package:device_policy/device_policy.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  test('观察路由复用实时设备认证，禁止管理员路由和重定向', () async {
    var current = 'a' * 43;
    final paths = <String>[];
    final transport = DeviceConfigurationTransport(
        apiRoot: Uri.parse('https://service.example/api/v1'),
        credential: () async => current,
        client: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer $current');
          expect(request.followRedirects, isFalse);
          paths.add(request.url.path);
          return http.Response(jsonEncode({'value': true}), 200,
              headers: {'content-type': 'application/json'});
        }));
    expect(await transport.observe(DeviceObservationOperation.settings),
        {'value': true});
    current = 'b' * 43;
    await transport
        .observe(DeviceObservationOperation.inventory, body: {'sequence': 1});
    await transport
        .observe(DeviceObservationOperation.usage, body: {'sequence': 2});
    expect(paths, [
      '/api/v1/device-api/observation-settings',
      '/api/v1/device-api/application-inventory',
      '/api/v1/device-api/usage-observations'
    ]);
    transport.close();
  });
  test('授权错误保留固定诊断，服务器原始内容不进入异常', () async {
    final transport = DeviceConfigurationTransport(
        apiRoot: Uri.parse('https://service.example/api/v1'),
        credential: () async => 'a' * 43,
        client: MockClient((request) async => http.Response(
            jsonEncode({
              'errorCode': 'OBSERVATION_AUTHORIZATION_CHANGED',
              'message': 'sensitive fixture'
            }),
            409,
            headers: {'content-type': 'application/json'})));
    await expectLater(
        transport
            .observe(DeviceObservationOperation.usage, body: {'sequence': 1}),
        throwsA(isA<DeviceTransportFailure>()
            .having((e) => e.code, 'code', 'OBSERVATION_AUTHORIZATION_CHANGED')
            .having((e) => e.toString().contains('sensitive'), 'redaction',
                isFalse)));
    transport.close();
  });
}
