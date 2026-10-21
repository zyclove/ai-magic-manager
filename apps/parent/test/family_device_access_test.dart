import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family.dart';
import 'package:parent/core/family_device_access.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';

const firstDevice = '00000000-0000-4000-8000-000000000001';
const firstRegistration = '00000000-0000-4000-8000-000000000002';
const secondDevice = '00000000-0000-4000-8000-000000000003';
const secondRegistration = '00000000-0000-4000-8000-000000000004';
const child = '00000000-0000-4000-8000-000000000005';
Json deviceAccessView(
        {String status = 'GRACE',
        int version = 4,
        String? selected = firstDevice,
        String? registration = firstRegistration}) =>
    {
      'tenantId': 'family',
      'version': version,
      'status': status,
      'effectiveDeviceLimit': status == 'PAID' ? 3 : 1,
      'activeCount': 2,
      'graceEndsAt': status == 'GRACE' ? 1800000000000 : null,
      'selectedDeviceId': selected,
      'selectedRegistrationId': registration,
      'devices': [
        for (final value in [
          [firstDevice, firstRegistration, '小雨的手机'],
          [secondDevice, secondRegistration, '学习平板']
        ])
          {
            'id': value[0],
            'registrationId': value[1],
            'displayName': value[2],
            'subjectId': child,
            'subjectName': '小雨',
            'state': 'ACTIVE',
            'createdAt': 1790000000000,
            'access': status == 'PAID'
                ? 'MEMBER'
                : status == 'GRACE'
                    ? 'GRACE'
                    : selected == value[0]
                        ? 'BASIC'
                        : 'RECOVERY_ONLY',
            'selected': selected == value[0],
            'canSelect': status != 'PAID'
          }
      ]
    };

class SelectionMemoryStorage extends ParentDurableStorage {
  final values = <String, String>{};
  bool failWrite = false;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
    if (failWrite) throw StateError('disk outcome unknown');
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

http.Response jsonResponse(Object value, {int status = 200}) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
FamilyDeviceSelectionCoordinator coordinator(
        ParentApi api, SelectionMemoryStorage storage,
        {bool Function()? available, String actor = 'adult'}) =>
    FamilyDeviceSelectionCoordinator(
        service: FamilyService(
            api: api, tenantId: 'family', available: available ?? () => true),
        actor: actor,
        storage: storage);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'selection is durable before PUT and unknown result resumes exact key body version after restart',
      () async {
    final storage = SelectionMemoryStorage(), sent = <http.Request>[];
    var attempts = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'GET') return jsonResponse(deviceAccessView());
      sent.add(r);
      expect(storage.values, isNotEmpty);
      attempts++;
      if (attempts == 1) {
        return jsonResponse({'errorCode': 'UNAVAILABLE'}, status: 503);
      }
      return jsonResponse(deviceAccessView(
          status: 'EXPIRED',
          version: 5,
          selected: secondDevice,
          registration: secondRegistration));
    }));
    addTearDown(api.close);
    final first = coordinator(api, storage);
    await first.load();
    await expectLater(first.select(secondDevice, secondRegistration),
        throwsA(isA<ParentApiException>()));
    expect(first.pending, isNotNull);
    expect(storage.values.values.single, isNot(contains('小雨')));
    final restarted = coordinator(api, storage);
    await restarted.load();
    await restarted.retry();
    expect(sent.length, 2);
    expect(sent[1].body, sent[0].body);
    expect(
        sent[1].headers['Idempotency-Key'], sent[0].headers['Idempotency-Key']);
    expect(sent[1].headers['If-Match'], '"4"');
    expect(jsonDecode(sent[1].body),
        {'deviceId': secondDevice, 'registrationId': secondRegistration});
    expect(restarted.pending, isNull);
    expect(storage.values, isEmpty);
  });
  test('uncertain durable write blocks HTTP until original journal is reloaded',
      () async {
    final storage = SelectionMemoryStorage()..failWrite = true;
    var puts = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') puts++;
      return jsonResponse(deviceAccessView());
    }));
    addTearDown(api.close);
    final c = coordinator(api, storage);
    await c.load();
    await expectLater(
        c.select(secondDevice, secondRegistration), throwsStateError);
    expect(puts, 0);
    expect(c.loaded, false);
    storage.failWrite = false;
    await c.load();
    expect(c.pending, isNotNull);
  });
  test(
      'definite version conflict clears original intent but requires a fresh read',
      () async {
    final storage = SelectionMemoryStorage();
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => r.method == 'GET'
            ? jsonResponse(deviceAccessView())
            : jsonResponse({'errorCode': 'RESOURCE_VERSION_CONFLICT'},
                status: 409)));
    addTearDown(api.close);
    final c = coordinator(api, storage);
    await c.load();
    await expectLater(c.select(secondDevice, secondRegistration),
        throwsA(isA<ParentApiException>()));
    expect(c.pending, isNull);
    expect(c.loaded, false);
    expect(storage.values, isEmpty);
  });
  test(
      'recent-auth rejection retains the original command and account-scoped recovery',
      () async {
    final storage = SelectionMemoryStorage();
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => r.method == 'GET'
            ? jsonResponse(deviceAccessView())
            : jsonResponse({'errorCode': 'REAUTH_REQUIRED'}, status: 401)));
    addTearDown(api.close);
    final c = coordinator(api, storage);
    await c.load();
    await expectLater(c.select(secondDevice, secondRegistration),
        throwsA(isA<ParentApiException>()));
    expect(c.pending, isNotNull);
    final other = coordinator(api, storage, actor: 'other-adult');
    await other.load();
    expect(other.pending, isNull);
  });
  test(
      'scope change during GET discards private response and cannot send a selection',
      () async {
    var active = true, puts = 0;
    final reply = Completer<http.Response>();
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') puts++;
      return reply.future;
    }));
    addTearDown(api.close);
    final c =
        coordinator(api, SelectionMemoryStorage(), available: () => active);
    final load = c.load();
    await Future<void>.delayed(Duration.zero);
    active = false;
    reply.complete(jsonResponse(deviceAccessView()));
    await expectLater(load, throwsA(isA<ParentApiException>()));
    expect(c.snapshot, isNull);
    expect(puts, 0);
  });
  test(
      'paid status, changed registration and duplicate devices cannot be chosen',
      () async {
    var view = deviceAccessView(status: 'PAID');
    var puts = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') puts++;
      return jsonResponse(view);
    }));
    addTearDown(api.close);
    final c = coordinator(api, SelectionMemoryStorage());
    await c.load();
    await expectLater(
        c.select(secondDevice, secondRegistration), throwsStateError);
    view = deviceAccessView();
    await c.load();
    await expectLater(
        c.select(secondDevice, firstRegistration), throwsStateError);
    view['devices'] = [view['devices'][0], view['devices'][0]];
    await expectLater(c.load(), throwsA(isA<ParentApiException>()));
    expect(puts, 0);
  });
}
