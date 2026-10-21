import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family.dart';
import 'package:parent/core/family_collaboration.dart';
import 'package:parent/core/parent_api.dart';
import 'family_device_access_test.dart' show SelectionMemoryStorage;

const familyId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const invitationId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
final secret = base64UrlEncode(List<int>.filled(32, 7)).replaceAll('=', '');
Json summary(String id, {String state = 'PENDING'}) => {
      'id': id,
      'role': 'GUARDIAN',
      'targetPhoneMasked': '139****0000',
      'expiresAt': 1800000000000,
      'state': state
    };
http.Response response(Json value, [int status = 200]) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  test(
      'REQUEST_IN_PROGRESS preserves the original invitation for same-key recovery',
      () async {
    final store = SelectionMemoryStorage(), sent = <http.Request>[];
    var inProgress = true;
    final service = FamilyService(
        api: ParentApi(() async => 'fixture',
            baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
        if (r.method == 'GET') {
          return response({'tenantId': familyId, 'items': []});
        }
          sent.add(r);
          return inProgress
              ? response({'errorCode': 'REQUEST_IN_PROGRESS'}, 409)
              : response(
                  summary((jsonDecode(r.body) as Json)['invitationId']), 201);
        })),
        tenantId: familyId,
        available: () => true);
    final original = FamilyInviteCoordinator(
        service: service, actor: 'adult', storage: store);
    await original.load();
    await expectLater(
        original.create('13900000000'), throwsA(isA<ParentApiException>()));
    expect(store.values, isNotEmpty);
    expect(original.pending, isNotNull);
    inProgress = false;
    final restored = FamilyInviteCoordinator(
        service: service, actor: 'adult', storage: store);
    await restored.load();
    await restored.retry();
    expect(sent, hasLength(2));
    expect(sent.last.body, sent.first.body);
    expect(sent.last.headers['Idempotency-Key'],
        sent.first.headers['Idempotency-Key']);
  });
  test('two pages cannot overwrite the same original invitation journal',
      () async {
    final store = SelectionMemoryStorage(), sent = <http.Request>[];
    final service = FamilyService(
        api: ParentApi(() async => 'fixture',
            baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
          if (r.method == 'GET') {
            return response({'tenantId': familyId, 'items': []});
          }
          sent.add(r);
          return response(
              summary((jsonDecode(r.body) as Json)['invitationId']), 201);
        })),
        tenantId: familyId,
        available: () => true);
    final a = FamilyInviteCoordinator(
            service: service, actor: 'adult', storage: store),
        b = FamilyInviteCoordinator(
            service: service, actor: 'adult', storage: store);
    await Future.wait([a.load(), b.load()]);
    final results = await Future.wait([
      a.create('13900000000').then<Object>((v) => v, onError: (Object e) => e),
      b.create('13800000000').then<Object>((v) => v, onError: (Object e) => e)
    ]);
    expect(sent, hasLength(1));
    expect(results.whereType<FamilyInvitationSummary>(), hasLength(1));
    expect(results.whereType<StateError>(), hasLength(1));
  });
  test(
      'unknown member removal retains original target, version and key until an explicit retry',
      () async {
    final store = SelectionMemoryStorage(), calls = <http.Request>[];
    var lose = true;
    final service = FamilyService(
        api: ParentApi(() async => 'fixture',
            baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
          calls.add(r);
          expect(store.values, isNotEmpty);
          return lose
              ? response({'errorCode': 'UNAVAILABLE'}, 503)
              : http.Response('', 204);
        })),
        tenantId: familyId,
        available: () => true);
    final first = FamilyCollaborationChange(
        service: service, actor: 'adult', storage: store);
    await first.load();
    await expectLater(
        first.start(kind: 'REMOVE_MEMBER', target: 'a' * 64, version: 3),
        throwsA(isA<ParentApiException>()));
    lose = false;
    final next = FamilyCollaborationChange(
        service: service, actor: 'adult', storage: store);
    await next.load();
    expect(calls, hasLength(1));
    await next.retry();
    expect(calls[1].url, calls[0].url);
    expect(calls[1].headers['If-Match'], '"3"');
    expect(calls[1].headers['Idempotency-Key'],
        calls[0].headers['Idempotency-Key']);
    expect(store.values, isEmpty);
  });
  test(
      'family invitation links contain only a random reference and secret and reject ambiguous input',
      () {
    final intent = FamilyInvitationIntent(invitationId, secret);
    expect(FamilyInvitationIntent.parse(intent.link).token, secret);
    expect(intent.link, isNot(contains('139')));
    for (final value in [
      '${intent.link}&phone=13900000000',
      '${intent.link}&id=$invitationId',
      '${intent.link}#hidden',
      intent.link.replaceFirst('aimanager', 'https'),
      intent.link.replaceFirst('family-invitation', 'notifications'),
      intent.link.replaceFirst('token=$secret', 'token=short')
    ]) {
      expect(() => FamilyInvitationIntent.parse(value),
          throwsA(isA<FormatException>()));
    }
  });
  test(
      'create saves the original command before HTTP and resumes the same request after a lost response',
      () async {
    final store = SelectionMemoryStorage(), sent = <http.Request>[];
    var lose = true;
    final service = FamilyService(
        api: ParentApi(() async => 'fixture',
            baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
          if (r.method == 'GET') {
            return response({'tenantId': familyId, 'items': []});
          }
          sent.add(r);
          expect(store.values, isNotEmpty);
          if (lose) return response({'errorCode': 'UNAVAILABLE'}, 503);
          return response(
              summary((jsonDecode(r.body) as Json)['invitationId']), 201);
        })),
        tenantId: familyId,
        available: () => true);
    final first = FamilyInviteCoordinator(
        service: service, actor: 'adult', storage: store);
    await first.load();
    await expectLater(
        first.create('13900000000'), throwsA(isA<ParentApiException>()));
    lose = false;
    final restored = FamilyInviteCoordinator(
        service: service, actor: 'adult', storage: store);
    await restored.load();
    expect(restored.pending, isNotNull);
    await restored.retry();
    expect(sent, hasLength(2));
    expect(sent[1].body, sent[0].body);
    expect(
        sent[1].headers['Idempotency-Key'], sent[0].headers['Idempotency-Key']);
    expect(restored.shareIntent!.id,
        (jsonDecode(sent[0].body) as Json)['invitationId']);
    expect(store.values.values.single, isNot(contains('13900000000')));
    final ready = FamilyInviteCoordinator(
        service: service, actor: 'adult', storage: store);
    await ready.load();
    expect(ready.shareIntent!.link, restored.shareIntent!.link);
    expect(ready.pending, isNull);
  });
  test('uncertain encrypted persistence never sends an unjournaled invitation',
      () async {
    final store = SelectionMemoryStorage()..failWrite = true;
    var writes = 0;
    final service = FamilyService(
        api: ParentApi(() async => 'fixture',
            baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
          if (r.method != 'GET') writes++;
          return response({'tenantId': familyId, 'items': []});
        })),
        tenantId: familyId,
        available: () => true);
    final operation = FamilyInviteCoordinator(
        service: service, actor: 'adult', storage: store);
    await operation.load();
    await expectLater(operation.create('13900000000'), throwsA(anything));
    expect(writes, 0);
    expect(operation.loaded, isFalse);
    store.failWrite = false;
    await operation.load();
    expect(operation.pending, isNotNull);
  });
  test(
      'acceptance requires explicit adult confirmation and recovers the same original intent',
      () async {
    final store = SelectionMemoryStorage(), sent = <http.Request>[];
    var lose = true;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/preview')) {
        return response({
          'invitationId': invitationId,
          'tenantId': familyId,
          'tenantName': '家人的家庭',
          'role': 'GUARDIAN',
          'expiresAt': 1800000000000,
          'state': 'PENDING'
        });
      }
      sent.add(r);
      expect(store.values, isNotEmpty);
      if (lose) return response({'errorCode': 'UNAVAILABLE'}, 503);
      return response({
        'invitationId': invitationId,
        'tenantId': familyId,
        'role': 'GUARDIAN',
        'memberVersion': 1,
        'currentState': 'ACTIVE'
      });
    }));
    final first = FamilyInviteAcceptance(
        api: api, actor: 'recipient', available: () => true, storage: store);
    await first.load();
    await first.preview(FamilyInvitationIntent(invitationId, secret));
    await expectLater(first.accept(adultGuardian: false), throwsA(anything));
    expect(sent, isEmpty);
    await expectLater(
        first.accept(adultGuardian: true), throwsA(isA<ParentApiException>()));
    lose = false;
    final next = FamilyInviteAcceptance(
        api: api, actor: 'recipient', available: () => true, storage: store);
    await next.load();
    expect(next.pending, isNotNull);
    await next.retry();
    expect(sent[1].body, sent[0].body);
    expect(
        sent[1].headers['Idempotency-Key'], sent[0].headers['Idempotency-Key']);
    expect(next.acceptedTenant, familyId);
    expect(store.values, isEmpty);
  });
}
