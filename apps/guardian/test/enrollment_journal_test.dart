import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/enrollment_journal.dart';

const tenant = 'abcdef01-1111-4111-8111-111111111111';
const subject = '22222222-2222-1222-8222-222222222222';
const request = '33333333-3333-4333-8333-33333333333a';
const anotherRequest = '44444444-4444-4444-8444-444444444444';
const scope =
    EnrollmentScope(actorId: 'adult-1', tenantId: tenant, role: 'OWNER');

EnrollmentIntent intent({
  EnrollmentScope owner = scope,
  String requestId = request,
  String subjectId = subject,
  String platform = 'ANDROID',
  int createdAt = 1000,
}) =>
    EnrollmentIntent(
      scope: owner,
      requestId: requestId,
      subjectId: subjectId,
      platform: platform,
      createdAt: createdAt,
    );

Map<String, Object> marker({
  String actorId = 'adult-1',
  String tenantId = tenant,
  String role = 'OWNER',
  String requestId = request,
  String subjectId = subject,
  String platform = 'ANDROID',
  int createdAt = 1000,
}) =>
    {
      'version': 1,
      'actorId': actorId,
      'tenantId': tenantId,
      'role': role,
      'requestId': requestId,
      'subjectId': subjectId,
      'platform': platform,
      'requestedMode': 'BYOD',
      'createdAt': createdAt,
    };

Matcher failure(String code) => isA<ApiFailure>().having(
      (value) => value.code,
      'error code',
      code,
    );

class MemoryStrings implements EnrollmentStringStorage {
  final values = <String, String>{};
  bool dropWrites = false, dropRemoves = false;
  Object? readFailure, writeFailure, removeFailure;

  @override
  String? read(String key) {
    if (readFailure != null) throw readFailure!;
    return values[key];
  }

  @override
  void write(String key, String value) {
    if (writeFailure != null) throw writeFailure!;
    if (!dropWrites) values[key] = value;
  }

  @override
  void remove(String key) {
    if (removeFailure != null) throw removeFailure!;
    if (!dropRemoves) values.remove(key);
  }
}

void main() {
  const invalid = 'ENROLLMENT_RECOVERY_STORAGE_INVALID';
  const unavailable = 'ENROLLMENT_RECOVERY_STORAGE_FAILED';
  const pending = 'ENROLLMENT_RECOVERY_PENDING';

  test('encoded marker contains only frozen non-secret request metadata', () {
    final value = jsonDecode(intent().encode()) as Map<String, dynamic>;
    expect(value, marker());
    expect(value.keys.toSet(), {
      'version',
      'actorId',
      'tenantId',
      'role',
      'requestId',
      'subjectId',
      'platform',
      'requestedMode',
      'createdAt',
    });
    expect(value.containsKey('token'), isFalse);
    expect(value.containsKey('name'), isFalse);
    expect(value.containsKey('pairingCode'), isFalse);
  });

  test('decode preserves original request and body in the matching scope', () {
    final value = EnrollmentIntent.decode(jsonEncode(marker()), scope: scope);
    expect(value.requestId, request);
    expect(value.subjectId, subject);
    expect(value.platform, 'ANDROID');
    expect(value.requestedMode, 'BYOD');
    expect(value.createdAt, 1000);
    expect(value.scope.actorId, 'adult-1');
    expect(value.scope.tenantId, tenant);
    expect(value.scope.role, 'OWNER');
  });

  test('codec rejects missing extra or secret fields without exposing values',
      () {
    final missing = marker()..remove('createdAt');
    for (final value in [
      missing,
      {...marker(), 'token': 'one-time-secret'},
      {...marker(), 'pairingCode': 'A12B34C5'},
      {...marker(), 'version': 2},
      {...marker(), 'createdAt': '1000'},
      {...marker(), 'requestedMode': 'DEVICE_OWNER'},
    ]) {
      expect(() => EnrollmentIntent.decode(jsonEncode(value), scope: scope),
          throwsA(failure(invalid)));
    }
  });

  test('codec rejects malformed JSON and non-object records', () {
    for (final raw in ['not-json', 'null', '[]', '1', '"marker"']) {
      expect(() => EnrollmentIntent.decode(raw, scope: scope),
          throwsA(failure(invalid)),
          reason: raw);
    }
  });

  test('a stored marker cannot cross account tenant or role scope', () {
    for (final value in [
      marker(actorId: 'adult-2'),
      marker(tenantId: '55555555-5555-4555-8555-555555555555'),
      marker(role: 'GUARDIAN'),
    ]) {
      expect(() => EnrollmentIntent.decode(jsonEncode(value), scope: scope),
          throwsA(failure(invalid)));
    }
  });

  test('request IDs require canonical lowercase UUID version four', () {
    for (final id in [
      'a' * 48,
      request.toUpperCase(),
      '33333333-3333-1333-8333-333333333333',
      '33333333-3333-4333-7333-333333333333',
      '../subjects',
      ' $request',
      '$request\n',
      '',
    ]) {
      expect(
          () => EnrollmentIntent.decode(jsonEncode(marker(requestId: id)),
              scope: scope),
          throwsA(failure(invalid)),
          reason: id);
      expect(() => intent(requestId: id).encode(), throwsA(failure(invalid)),
          reason: id);
    }
  });

  test('tenant and subject IDs reject noncanonical or path-like values', () {
    for (final id in [
      'BAD-ID',
      tenant.toUpperCase(),
      '../other',
      '$tenant/extra',
      '$tenant\n'
    ]) {
      expect(
          () => EnrollmentIntent.decode(jsonEncode(marker(subjectId: id)),
              scope: scope),
          throwsA(failure(invalid)));
      final owner =
          EnrollmentScope(actorId: 'adult-1', tenantId: id, role: 'OWNER');
      expect(() => intent(owner: owner).encode(), throwsA(failure(invalid)));
    }
  });

  test('only adult write roles and supported BYOD platforms are accepted', () {
    for (final role in ['AUDITOR', 'TEACHER', 'CHILD', 'owner', '']) {
      final owner =
          EnrollmentScope(actorId: 'adult-1', tenantId: tenant, role: role);
      expect(() => intent(owner: owner).encode(), throwsA(failure(invalid)));
    }
    for (final role in ['OWNER', 'GUARDIAN', 'ORG_ADMIN']) {
      final owner =
          EnrollmentScope(actorId: 'adult-1', tenantId: tenant, role: role);
      final raw = jsonEncode(marker(role: role, platform: 'ANDROID_TV'));
      expect(EnrollmentIntent.decode(raw, scope: owner).platform, 'ANDROID_TV');
    }
    for (final platform in ['IOS', 'android', '']) {
      expect(
          () => intent(platform: platform).encode(), throwsA(failure(invalid)));
    }
  });

  test('actors and timestamps reject unsafe metadata bounds', () {
    for (final actor in [
      '',
      'a' * 201,
      'adult\nother',
      'adult\u0000',
      'adult\u0085'
    ]) {
      final owner =
          EnrollmentScope(actorId: actor, tenantId: tenant, role: 'OWNER');
      expect(() => intent(owner: owner).encode(), throwsA(failure(invalid)));
    }
    for (final timestamp in [-1, 9007199254740992]) {
      expect(() => intent(createdAt: timestamp).encode(),
          throwsA(failure(invalid)));
      expect(
          () => EnrollmentIntent.decode(
              jsonEncode(marker(createdAt: timestamp)),
              scope: scope),
          throwsA(failure(invalid)));
    }
  });

  test('read is a non-consuming peek and keeps arbitrarily old valid markers',
      () async {
    final storage = MemoryStrings();
    final raw = jsonEncode(marker(createdAt: 0));
    storage.values[scope.key] = raw;
    final journal = StoredEnrollmentJournal(storage);
    expect((await journal.read(scope))!.requestId, request);
    expect((await journal.read(scope))!.createdAt, 0);
    expect(storage.values[scope.key], raw);
  });

  test('an absent marker returns null without creating recovery state',
      () async {
    final storage = MemoryStrings();
    expect(await StoredEnrollmentJournal(storage).read(scope), isNull);
    expect(storage.values, isEmpty);
  });

  test('scope keys isolate account tenant and role records', () async {
    final storage = MemoryStrings();
    final journal = StoredEnrollmentJournal(storage);
    await journal.write(intent());
    for (final other in [
      const EnrollmentScope(
          actorId: 'adult-2', tenantId: tenant, role: 'OWNER'),
      const EnrollmentScope(
          actorId: 'adult-1',
          tenantId: '55555555-5555-4555-8555-555555555555',
          role: 'OWNER'),
      const EnrollmentScope(
          actorId: 'adult-1', tenantId: tenant, role: 'GUARDIAN'),
    ]) {
      expect(other.key, isNot(scope.key));
      expect(await journal.read(other), isNull);
    }
    expect((await journal.read(scope))!.requestId, request);
  });

  test('successful writes read back the exact frozen request', () async {
    final storage = MemoryStrings();
    final journal = StoredEnrollmentJournal(storage);
    await journal.write(intent());
    expect(jsonDecode(storage.values[scope.key]!), marker());
    expect((await journal.read(scope))!.requestId, request);
    await journal.write(intent());
    expect(jsonDecode(storage.values[scope.key]!), marker());
  });

  test('a different pending request cannot be overwritten', () async {
    final storage = MemoryStrings();
    final original = jsonEncode(marker());
    storage.values[scope.key] = original;
    final journal = StoredEnrollmentJournal(storage);
    await expectLater(journal.write(intent(requestId: anotherRequest)),
        throwsA(failure(pending)));
    expect(storage.values[scope.key], original);
  });

  test('the original body cannot change while reusing a pending request UUID',
      () async {
    final storage = MemoryStrings();
    final original = jsonEncode(marker());
    storage.values[scope.key] = original;
    final journal = StoredEnrollmentJournal(storage);
    for (final changed in [
      intent(platform: 'ANDROID_TV'),
      intent(subjectId: '66666666-6666-4666-8666-666666666666'),
      intent(createdAt: 1001),
    ]) {
      await expectLater(journal.write(changed), throwsA(failure(pending)));
    }
    expect(storage.values[scope.key], original);
  });

  test('a dropped write never reports successful durable recovery metadata',
      () async {
    final storage = MemoryStrings()..dropWrites = true;
    await expectLater(StoredEnrollmentJournal(storage).write(intent()),
        throwsA(failure(unavailable)));
    expect(storage.values, isEmpty);
  });

  test('unavailable storage prevents reads writes and removals from succeeding',
      () async {
    final storage = MemoryStrings()
      ..readFailure = StateError('private raw value');
    final journal = StoredEnrollmentJournal(storage);
    await expectLater(journal.read(scope), throwsA(failure(unavailable)));
    await expectLater(journal.write(intent()), throwsA(failure(unavailable)));
    await expectLater(journal.remove(intent()), throwsA(failure(unavailable)));
  });

  test('storage write and removal exceptions remain failed operations',
      () async {
    final storage = MemoryStrings()..writeFailure = StateError('write refused');
    final journal = StoredEnrollmentJournal(storage);
    await expectLater(journal.write(intent()), throwsA(failure(unavailable)));
    expect(storage.values, isEmpty);
    storage.values[scope.key] = jsonEncode(marker());
    storage.removeFailure = StateError('remove refused');
    await expectLater(journal.remove(intent()), throwsA(failure(unavailable)));
    expect(storage.values.containsKey(scope.key), isTrue);
  });

  test('corrupt nonempty storage is not consumed overwritten or removed',
      () async {
    final storage = MemoryStrings();
    const raw = '{"token":"private-secret"}';
    storage.values[scope.key] = raw;
    final journal = StoredEnrollmentJournal(storage);
    await expectLater(journal.read(scope), throwsA(failure(invalid)));
    await expectLater(journal.write(intent()), throwsA(failure(invalid)));
    await expectLater(journal.remove(intent()), throwsA(failure(invalid)));
    expect(storage.values[scope.key], raw);
  });

  test('an empty stored string is invalid rather than an absent request',
      () async {
    final storage = MemoryStrings();
    storage.values[scope.key] = '';
    await expectLater(StoredEnrollmentJournal(storage).read(scope),
        throwsA(failure(invalid)));
    expect(storage.values.containsKey(scope.key), isTrue);
  });

  test('conditional removal cannot delete a newer pending request', () async {
    final storage = MemoryStrings();
    final replacement = jsonEncode(marker(requestId: anotherRequest));
    storage.values[scope.key] = replacement;
    await StoredEnrollmentJournal(storage).remove(intent());
    expect(storage.values[scope.key], replacement);
  });

  test('conditional removal requires the original body and timestamp too',
      () async {
    final storage = MemoryStrings();
    final original = jsonEncode(marker());
    storage.values[scope.key] = original;
    final journal = StoredEnrollmentJournal(storage);
    for (final changed in [
      intent(platform: 'ANDROID_TV'),
      intent(subjectId: '66666666-6666-4666-8666-666666666666'),
      intent(createdAt: 1001),
    ]) {
      await journal.remove(changed);
      expect(storage.values[scope.key], original);
    }
  });

  test('matching removal succeeds only after absence is read back', () async {
    final storage = MemoryStrings();
    storage.values[scope.key] = jsonEncode(marker());
    final journal = StoredEnrollmentJournal(storage);
    await journal.remove(intent());
    expect(await journal.read(scope), isNull);
    expect(storage.values.containsKey(scope.key), isFalse);
    await journal.remove(intent());
  });

  test('a dropped removal keeps its marker and reports storage failure',
      () async {
    final storage = MemoryStrings()..dropRemoves = true;
    final original = jsonEncode(marker());
    storage.values[scope.key] = original;
    await expectLater(StoredEnrollmentJournal(storage).remove(intent()),
        throwsA(failure(unavailable)));
    expect(storage.values[scope.key], original);
  });
}
