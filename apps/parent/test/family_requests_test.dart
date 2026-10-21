import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family.dart';
import 'package:parent/core/family_requests.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';

const requestId = '00000000-0000-4000-8000-000000000001';
const childId = '00000000-0000-4000-8000-000000000002';
const deviceId = '00000000-0000-4000-8000-000000000003';
Map<String, dynamic> row({String state = 'PENDING', int version = 0}) => {
      'id': requestId,
      'subjectId': childId,
      'deviceId': deviceId,
      'state': state,
      'reason': '想完成这一局',
      'requestedSeconds': 900,
      'grantedSeconds': state == 'APPROVED' ? 600 : null,
      'expiresAt': 1800000000000,
      'notAfter': state == 'APPROVED' ? 1799999000000 : null,
      'version': version,
    };

class MemoryStore extends ParentDurableStorage {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('unknown decision survives restart with same body and operation key',
      () async {
    final store = MemoryStore(), sent = <http.Request>[];
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((request) async {
      expect(store.values, isNotEmpty,
          reason: 'durability must precede sending');
      sent.add(request);
      if (sent.length == 1) {
        return http.Response('{"errorCode":"UNAVAILABLE"}', 503);
      }
      return http.Response(jsonEncode(row(state: 'APPROVED', version: 1)), 200, headers: {'content-type':'application/json; charset=utf-8'});
    }));
    addTearDown(api.close);
    final requests = FamilyRequests(
        FamilyService(api: api, tenantId: 'family', available: () => true));
    final first = FamilyDecisionJournal(storage: store);
    final command = await first.begin(
        'family', 'adult', FamilyAccessRequest.fromJson(row()),
        approve: true, seconds: 600);
    await expectLater(
        requests.submit(command), throwsA(isA<ParentApiException>()));
    final reopened = FamilyDecisionJournal(storage: store);
    final original = await reopened.load('family', 'adult');
    expect(original, command);
    expect(await reopened.load('other-family', 'adult'), isNull);
    await expectLater(
        reopened.begin('family', 'adult', FamilyAccessRequest.fromJson(row()),
            approve: false, seconds: 0),
        throwsStateError);
    final result = await requests.submit(original!);
    expect(result.state, 'APPROVED');
    expect(sent[1].body, sent[0].body);
    expect(
        sent[1].headers['Idempotency-Key'], sent[0].headers['Idempotency-Key']);
    expect(sent[1].headers['If-Match'], '"0"');
    expect(jsonDecode(sent[1].body),
        {'decision': 'APPROVE', 'grantedSeconds': 600});
    expect(store.values.values.single, isNot(contains('想完成这一局')));
    await reopened.clear('family', 'adult');
    expect(await reopened.load('family', 'adult'), isNull);
  });
  test('stale scope cannot submit or read a family decision', () async {
    var calls = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      calls++;
      return http.Response('{}', 200);
    }));
    addTearDown(api.close);
    final requests = FamilyRequests(
        FamilyService(api: api, tenantId: 'family', available: () => false));
    await expectLater(
        requests.read(requestId), throwsA(isA<ParentApiException>()));
    await expectLater(
        requests.submit({
          'id': requestId,
          'version': 0,
          'key': 'original',
          'decision': 'DENY',
          'grantedSeconds': 0
        }),
        throwsA(isA<ParentApiException>()));
    expect(calls, 0);
  });
  test('corrupt journal and grants exceeding requested duration fail closed',
      () async {
    final store = MemoryStore(),
        journal = FamilyDecisionJournal(storage: MemoryStore());
    await expectLater(
        journal.begin('family', 'adult', FamilyAccessRequest.fromJson(row()),
            approve: true, seconds: 1800),
        throwsStateError);
    store.values['family.pending.decision.family.adult'] = '{"id":"broken"}';
    await expectLater(
        FamilyDecisionJournal(storage: store).load('family', 'adult'),
        throwsFormatException);
  });
}
