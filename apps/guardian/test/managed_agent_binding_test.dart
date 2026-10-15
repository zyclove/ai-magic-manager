import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_agent_binding.dart';
import 'package:guardian/core/managed_agent_binding_repository.dart';
import 'package:http/testing.dart';
import 'managed_agent_binding_fixtures.dart';

void main() {
  test('context retains exact enrollment and active subject device', () async {
    final f = AgentBindingFixture();
    final result = await f.repository.context();
    expect(result.candidates.single.displayName, '学习平板');
    expect(result.ready, isTrue);
    expect(f.requests.single.url.path.endsWith('/context/$bindingEnrollment'),
        isTrue);
  });
  for (final field in [
    'id',
    'enrollmentId',
    'deviceId',
    'registrationId',
    'state',
    'version',
    'expiresAt',
    'systemControlAvailable',
    'verifiedAt',
    'nonce'
  ]) {
    test('rejects malformed binding field $field', () {
      final f = AgentBindingFixture(), data = AgentBindingFixture().record();
      switch (field) {
        case 'id':
        case 'deviceId':
        case 'registrationId':
          data[field] = 'not-an-id';
        case 'enrollmentId':
          data[field] = bindingTenant;
        case 'state':
          data[field] = 'APPLIED';
        case 'version':
          data[field] = 0;
        case 'expiresAt':
          data[field] = (data['createdAt'] as int) + 600001;
        case 'systemControlAvailable':
          data[field] = true;
        case 'verifiedAt':
          data[field] = f.instant.millisecondsSinceEpoch;
        case 'nonce':
          data[field] = 'must-not-be-returned';
      }
      expect(() => ManagedAgentBinding.parse(data, bindingEnrollment),
          throwsA(isA<ApiFailure>()));
    });
  }
  for (final field in [
    'subject',
    'scope',
    'duplicate',
    'cursor',
    'inactive',
    'ready'
  ]) {
    test('rejects inconsistent selection context $field', () {
      final f = AgentBindingFixture();
      final data = f.context();
      switch (field) {
        case 'subject':
          data['subjectId'] = bindingTenant;
        case 'scope':
          (data['candidates']['items'][0] as Json)['subjectId'] = bindingTenant;
        case 'duplicate':
          data['candidates']['items'] = [f.device(), f.device()];
        case 'cursor':
          data['candidates']['nextCursor'] = bindingId;
        case 'inactive':
          (data['candidates']['items'][0] as Json)['state'] = 'REVOKED';
        case 'ready':
          data['ready'] = false;
      }
      expect(
          () => ManagedAgentBindingContext.parse(
              data, bindingEnrollment, bindingSubject),
          throwsA(isA<ApiFailure>()));
    });
  }
  test('create uses fixed idempotency key and explicit registration', () async {
    final f = AgentBindingFixture();
    await f.repository.create(bindingKey, bindingDevice, bindingRegistration);
    final request = f.requests.single;
    expect(request.headers['Idempotency-Key'], bindingKey);
    expect(jsonDecode(request.body), {
      'enrollmentId': bindingEnrollment,
      'deviceId': bindingDevice,
      'registrationId': bindingRegistration
    });
  });
  test('pending 202 response is valid and carries If-Match', () async {
    final f = AgentBindingFixture()..binding = AgentBindingFixture().record();
    final initial = ManagedAgentBinding.parse(f.binding, bindingEnrollment);
    final result = await f.repository.verify(initial);
    expect(result.state, 'PENDING');
    expect(f.requests.single.headers['If-Match'], '"1"');
  });
  test('workspace invalidation prevents both request and returned private data',
      () async {
    final f = AgentBindingFixture()..current = false;
    await expectLater(
        f.repository.context(),
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'WORKSPACE_CHANGED')));
    expect(f.requests, isEmpty);
    var current = true;
    final api = Api(
        () async => MockClient((r) async {
              current = false;
              return f.response(f.context());
            }),
        baseUrl: 'http://fixture/api/v1');
    final repository = ManagedAgentBindingRepository(
        api: api,
        tenantId: bindingTenant,
        enrollmentId: bindingEnrollment,
        subjectId: bindingSubject,
        current: () => current);
    await expectLater(
        repository.context(),
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'WORKSPACE_CHANGED')));
  });
  test('verification cannot extend deadline or change selected registration',
      () async {
    final f = AgentBindingFixture();
    final original = ManagedAgentBinding.parse(f.record(), bindingEnrollment);
    final api = Api(
        () async => MockClient((r) async => f.response(
            {...f.record(), 'expiresAt': f.record()['expiresAt'] + 1})),
        baseUrl: 'http://fixture/api/v1');
    final repository = ManagedAgentBindingRepository(
        api: api,
        tenantId: bindingTenant,
        enrollmentId: bindingEnrollment,
        subjectId: bindingSubject,
        current: () => true);
    await expectLater(repository.verify(original), throwsA(isA<ApiFailure>()));
  });
  test('expired projection may keep the underlying resource version', () async {
    final f = AgentBindingFixture();
    final original = ManagedAgentBinding.parse(f.record(), bindingEnrollment);
    final api = Api(
        () async => MockClient(
            (r) async => f.response({...f.record(), 'state': 'EXPIRED'})),
        baseUrl: 'http://fixture/api/v1');
    final repository = ManagedAgentBindingRepository(
        api: api,
        tenantId: bindingTenant,
        enrollmentId: bindingEnrollment,
        subjectId: bindingSubject,
        current: () => true);
    expect((await repository.verify(original)).state, 'EXPIRED');
  });
}
