import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/permission_consent.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:usage_reporting/usage_reporting.dart';

import 'support/parent_operation_journal_fixture.dart';

const device = '00000000-0000-4000-8000-000000000001';
const registration = '00000000-0000-4000-8000-000000000002';
const subject = '00000000-0000-4000-8000-000000000003';
const target = UsageReportTarget(device, registration, subject, '学习平板',
    platform: 'ANDROID');
Json settings([int version = 0, bool enabled = false]) => {
      'deviceId': device,
      'registrationId': registration,
      'version': version,
      'enabled': enabled,
      'updatedAt': version == 0 ? null : 1700000000000,
    };
Json deviceJson() => {
      'id': device,
      'registrationId': registration,
      'subjectId': subject,
      'platform': 'ANDROID',
      'state': 'ACTIVE'
    };
http.Response response(Json value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status);

class Storage extends ParentDurableStorage with ParentAtomicJournalFixture {
  @override
  bool get fixtureWriteMayCommitBeforeFailure => true;
  final values = <String, String>{};
  bool failWrite = false;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
    if (failWrite) throw StateError('flush failed');
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

ParentApi api(Future<http.Response> Function(http.Request) handle) =>
    ParentApi(() async => 'fixture',
        client: MockClient(handle), baseUrl: 'https://fixture.invalid/api/v1');
ParentPermissionConsent controller(ParentApi api, Storage storage,
        {Future<bool> Function()? auth,
        bool Function()? current,
        bool Function()? foreground}) =>
    ParentPermissionConsent(
        api: api,
        store: PermissionChangeStore(storage: storage),
        tenant: 'tenant',
        actor: 'adult',
        target: target,
        isCurrent: current ?? () => true,
        foreground: foreground ?? () => true,
        reauthenticate: auth ?? () async => true);
Future<void> submit(ParentPermissionConsent c) =>
    c.submit(enabled: true, reason: '查看学习时间');

void main() {
  test(
      'writes only after MFA and durable save then separates committed and current',
      () async {
    final storage = Storage();
    var authenticated = false, mutations = 0;
    final c = controller(
        api((r) async {
          if (r.url.path.endsWith('/devices/$device')) {
            return response(deviceJson());
          }
          if (r.url.path.endsWith('/changes')) {
            expect(authenticated, isTrue);
            expect(storage.values, hasLength(1));
            expect(r.headers['Idempotency-Key'], isNotEmpty);
            final body = jsonDecode(r.body);
            expect(body['registrationId'], registration);
            expect(body['version'], 0);
            mutations++;
            return response(settings(1, true));
          }
          if (r.url.path.endsWith('/query')) {
            return response({
              'committed': settings(1, true),
              'current': settings(2, false)
            });
          }
          return response(settings());
        }),
        storage,
        auth: () async {
          authenticated = true;
          return true;
        });
    await c.load();
    await submit(c);
    expect(c.error, isNull);
    expect(c.committed!.enabled, isTrue);
    expect(c.settings!.enabled, isFalse);
    expect(c.pending, isNotNull);
    expect(mutations, 1);
    await c.query();
    expect(mutations, 1);
    await c.acknowledge();
    expect(storage.values, isEmpty);
    expect(c.settings, isNull);
    c.dispose();
  });
  test('lost response reopens with same marker and queries without mutation',
      () async {
    final storage = Storage();
    var writes = 0;
    final transport = api((r) async {
      if (r.url.path.endsWith('/devices/$device')) {
        return response(deviceJson());
      }
      if (r.url.path.endsWith('/changes')) {
        writes++;
        throw http.ClientException('fixture');
      }
      if (r.url.path.endsWith('/query')) {
        return response(
            {'committed': settings(1, true), 'current': settings(1, true)});
      }
      return response(settings());
    });
    final first = controller(transport, storage);
    await first.load();
    await submit(first);
    final key = first.pending!['requestId'];
    first.dispose();
    final next = controller(transport, storage);
    await next.load();
    expect(next.pending!['requestId'], key);
    await submit(next);
    expect(writes, 1);
    await next.query();
    expect(next.queried, isTrue);
    expect(writes, 1);
    next.dispose();
  });
  for (final outcome in [
    'cancelled',
    'scope-changed',
    'registration-changed',
    'version-changed',
    'storage-failed'
  ]) {
    test('$outcome never submits authorization', () async {
      final storage = Storage()..failWrite = outcome == 'storage-failed';
      var current = true, authDone = false, writes = 0;
      final c = controller(
          api((r) async {
            if (r.method == 'POST') writes++;
            if (r.url.path.endsWith('/devices/$device')) {
              return response({
                ...deviceJson(),
                if (authDone && outcome == 'registration-changed')
                  'registrationId': subject
              });
            }
            return response(
                settings(authDone && outcome == 'version-changed' ? 1 : 0));
          }),
          storage,
          current: () => current,
          auth: () async {
            authDone = true;
            if (outcome == 'scope-changed') current = false;
            return outcome != 'cancelled';
          });
      await c.load();
      await submit(c);
      expect(writes, 0);
      if (outcome == 'storage-failed') {
        await c.load();
        expect(c.pending, isNotNull);
      }
      c.dispose();
    });
  }
  for (final terminal in [
    (404, 'OBSERVATION_RESULT_UNAVAILABLE'),
    (410, 'IDEMPOTENCY_RESPONSE_ERASED')
  ]) {
    test('${terminal.$2} keeps original marker until explicit acknowledgement',
        () async {
      final storage = Storage();
      var writes = 0;
      final c = controller(api((r) async {
        if (r.url.path.endsWith('/devices/$device')) {
          return response(deviceJson());
        }
        if (r.url.path.endsWith('/changes')) {
          writes++;
          throw http.ClientException('fixture');
        }
        if (r.url.path.endsWith('/query')) {
          return terminal.$1 == 410
              ? parentJournalTerminalProblem(terminal.$2)
              : response({'errorCode': terminal.$2}, terminal.$1);
        }
        return response(settings());
      }), storage);
      await c.load();
      await submit(c);
      final key = c.pending!['requestId'];
      await c.query();
      expect(c.queried, terminal.$1 == 404 ? isTrue : isFalse);
      expect(c.pending!['requestId'], key);
      expect(c.committed, isNull);
      expect(c.settings, isNull);
      await submit(c);
      expect(writes, 1);
      if (terminal.$1 == 410) {
        await c.endLocalCheck();
      } else {
        await c.acknowledge();
      }
      expect(c.pending, isNull);
      expect(writes, 1);
      c.dispose();
    });
  }
  test(
      'late result after background cannot reveal consent or trigger another write',
      () async {
    final storage = Storage(),
        received = Completer<void>(),
        result = Completer<http.Response>();
    var foreground = true, queries = 0;
    final c = controller(api((r) async {
      if (r.url.path.endsWith('/devices/$device')) {
        return response(deviceJson());
      }
      if (r.url.path.endsWith('/changes')) {
        received.complete();
        return result.future;
      }
      if (r.url.path.endsWith('/query')) queries++;
      return response(settings());
    }), storage, foreground: () => foreground);
    await c.load();
    final future = submit(c);
    await received.future;
    foreground = false;
    c.hide();
    result.complete(response(settings(1, true)));
    await future;
    foreground = true;
    expect(c.settings, isNull);
    expect(c.committed, isNull);
    expect(c.pending, isNotNull);
    expect(queries, 0);
    c.dispose();
  });
  test(
      'forged success is retained as unresolved rather than presented as authorization',
      () async {
    final c = controller(api((r) async {
      if (r.url.path.endsWith('/devices/$device')) {
        return response(deviceJson());
      }
      if (r.url.path.endsWith('/changes')) return response(settings(1, false));
      return response(settings());
    }), Storage());
    await c.load();
    await submit(c);
    expect(c.error, isA<ParentApiException>());
    expect(c.queried, isFalse);
    expect(c.committed, isNull);
    expect(c.pending, isNotNull);
    c.dispose();
  });
}
