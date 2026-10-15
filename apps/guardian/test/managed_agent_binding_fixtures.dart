import 'dart:convert';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_agent_binding_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const bindingTenant = '11111111-1111-4111-8111-111111111111';
const bindingEnrollment = '22222222-2222-4222-8222-222222222222';
const bindingSubject = '33333333-3333-4333-8333-333333333333';
const bindingDevice = '44444444-4444-4444-8444-444444444444';
const bindingRegistration = '55555555-5555-4555-8555-555555555555';
const bindingId = '66666666-6666-4666-8666-666666666666';
const bindingKey = '77777777-7777-4777-8777-777777777777';

class AgentBindingFixture {
  DateTime instant = DateTime.now();
  bool current = true,
      ready = true,
      empty = false,
      failRead = false,
      failCreateOnce = false,
      commitBeforeFailure = false,
      proofReady = false;
  int createCount = 0, verifyCount = 0, revokeCount = 0;
  Json? binding;
  final requests = <http.Request>[];
  late final client = MockClient(handle);
  late final api =
      Api(() async => client, baseUrl: 'http://binding.invalid/api/v1');
  late final repository = ManagedAgentBindingRepository(
      api: api,
      tenantId: bindingTenant,
      enrollmentId: bindingEnrollment,
      subjectId: bindingSubject,
      current: () => current);
  Json device() => {
        'id': bindingDevice,
        'subjectId': bindingSubject,
        'registrationId': bindingRegistration,
        'displayName': '学习平板',
        'platform': 'ANDROID',
        'osVersion': '14',
        'state': 'ACTIVE',
        'managementMode': 'BYOD',
        'controlLevel': 'LIMITED',
        'observationStatus': 'RECENT',
        'keyThumbprint': 'a' * 43,
        'version': 1,
        'lastHeartbeatAt': instant.millisecondsSinceEpoch
      };
  Json record({String state = 'PENDING', int version = 1}) => {
        'id': bindingId,
        'enrollmentId': bindingEnrollment,
        'deviceId': bindingDevice,
        'registrationId': bindingRegistration,
        'state': state,
        'version': version,
        'createdAt': instant.millisecondsSinceEpoch - 1000,
        'expiresAt': instant.millisecondsSinceEpoch + 599000,
        'verifiedAt':
            state == 'VERIFIED' ? instant.millisecondsSinceEpoch : null,
        'systemControlAvailable': false
      };
  Json context() => {
        'enrollmentId': bindingEnrollment,
        'subjectId': bindingSubject,
        'ready': ready,
        'reasonCode': ready ? 'READY' : 'RELEASE_TRUST_REQUIRED',
        'currentBinding': binding,
        'candidates': <String, dynamic>{
          'items': empty ? [] : [device()],
          'nextCursor': null
        }
      };
  http.Response response(Object data, {int status = 200}) =>
      http.Response(jsonEncode(data), status,
          headers: {'content-type': 'application/json; charset=utf-8'});
  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    if (request.method == 'GET') {
      if (failRead) {
        return response({'errorCode': 'EMM_UNAVAILABLE'}, status: 503);
      }
      return response(context());
    }
    if (request.url.path.endsWith('/verify')) {
      verifyCount++;
      if (proofReady) {
        binding = {
          ...binding!,
          'state': 'VERIFIED',
          'version': 2,
          'verifiedAt': instant.millisecondsSinceEpoch
        };
      }
      return response(binding!, status: proofReady ? 200 : 202);
    }
    if (request.url.path.endsWith('/revoke')) {
      revokeCount++;
      binding = {
        ...binding!,
        'state': 'REVOKED',
        'version': (binding!['version'] as int) + 1
      };
      return response(binding!);
    }
    createCount++;
    if (failCreateOnce) {
      failCreateOnce = false;
      if (commitBeforeFailure) binding = record();
      throw http.ClientException('fixture transport interrupted');
    }
    binding ??= record();
    return response(binding!, status: 201);
  }
}
