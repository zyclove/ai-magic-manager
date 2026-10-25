import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_rule_directories.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _root = '/tenants/workspace';

http.Response _page(List<Json> items, [String? cursor]) =>
    http.Response(jsonEncode({'items': items, 'nextCursor': cursor}), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});

Api _api(FutureOr<http.Response> Function(http.Request) handler) {
  final client = MockClient((request) async => handler(request));
  return Api(() async => client);
}

Matcher get _lost => isA<ApiFailure>()
    .having((error) => error.code, 'code', 'WORKSPACE_CHANGED');

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('empty references and domain rules make no directory requests',
      () async {
    var calls = 0;
    final directories = PolicyRuleDirectories(
        api: _api((_) {
          calls++;
          return _page([]);
        }),
        root: _root,
        current: () => true);
    await directories.forReferences([]);
    await directories.forRule('DOMAIN_ACCESS');
    await directories.reloadRequested();
    expect(calls, 0);
    expect(directories.hasRequested, isFalse);
    expect(directories.applications, isEmpty);
    expect(directories.schedules, isEmpty);
  });

  test('application pagination caches only immutable option fields', () async {
    final requests = <http.Request>[];
    final directories = PolicyRuleDirectories(
        api: _api((request) {
          requests.add(request);
          return request.url.queryParameters['cursor'] == null
              ? _page([
                  {'id': 'a', 'displayName': '应用甲', 'private': 'discard'}
                ], 'next')
              : _page([
                  {
                    'id': 'b',
                    'displayName': '应用乙',
                    'rules': [1, 2]
                  }
                ]);
        }),
        root: _root,
        current: () => true);
    await directories.forRule('APP_LAUNCH');
    await directories.forRule('APP_INSTALL');
    expect(requests.map((request) => request.url.path),
        everyElement('/api/v1$_root/applications'));
    expect(requests.map((request) => request.url.queryParameters['cursor']),
        [null, 'next']);
    expect(directories.applications, [
      {'id': 'a', 'displayName': '应用甲'},
      {'id': 'b', 'displayName': '应用乙'}
    ]);
    expect(() => directories.applications.add({'id': 'c'}),
        throwsUnsupportedError);
    expect(() => directories.applications.first['id'] = 'changed',
        throwsUnsupportedError);
    expect(directories.hasRequested, isTrue);
    expect(directories.schedules, isEmpty);
  });

  test('references load only referenced directories and time rules reuse them',
      () async {
    final paths = <String>[];
    final directories = PolicyRuleDirectories(
        api: _api((request) {
          paths.add(request.url.path);
          return request.url.path.endsWith('/schedules')
              ? _page([
                  {'id': 's', 'name': '学习时段'}
                ])
              : _page([
                  {'id': 'a', 'displayName': '应用'}
                ]);
        }),
        root: _root,
        current: () => true);
    await directories.forReferences([
      {'scheduleId': 's'},
      {'applicationId': null}
    ]);
    expect(paths, ['/api/v1$_root/schedules']);
    await directories.forRule('TIME_WINDOW');
    await directories.forReferences([
      {'applicationId': 'a', 'scheduleId': 's'}
    ]);
    expect(paths, ['/api/v1$_root/schedules', '/api/v1$_root/applications']);
    expect(directories.schedules.single, {'id': 's', 'name': '学习时段'});
  });

  test('explicit seeds and successful empty lists are authoritative caches',
      () async {
    var calls = 0;
    final seed = <Json>[
      {'id': 'a', 'displayName': '原名称', 'extra': true}
    ];
    final api = _api((_) {
      calls++;
      return _page([]);
    });
    final seeded = PolicyRuleDirectories(
        api: api,
        root: _root,
        current: () => true,
        applications: seed,
        schedules: const []);
    seed.first['displayName'] = '后来变更';
    seed.clear();
    await seeded.forRule('TIME_WINDOW');
    expect(calls, 0);
    expect(seeded.applications.single, {'id': 'a', 'displayName': '原名称'});
    expect(seeded.schedules, isEmpty);
    seeded.revoke();
    seeded.revoke();
    expect(seeded.applications, isEmpty);
    expect(seeded.schedules, isEmpty);
    await expectLater(seeded.forRule('APP_LAUNCH'), throwsA(_lost));
    final empty =
        PolicyRuleDirectories(api: api, root: _root, current: () => true);
    await empty.forRule('DAILY_QUOTA');
    await empty.forRule('USAGE_REMINDER');
    await empty.forRule('APP_LAUNCH');
    expect(calls, 1);
    expect(empty.applications, isEmpty);
  });

  test('concurrent rules share each in-flight directory', () async {
    final applications = Completer<http.Response>();
    final schedules = Completer<http.Response>();
    addTearDown(() {
      if (!applications.isCompleted) applications.complete(_page([]));
      if (!schedules.isCompleted) schedules.complete(_page([]));
    });
    final paths = <String>[];
    final directories = PolicyRuleDirectories(
        api: _api((request) {
          paths.add(request.url.path);
          return request.url.path.endsWith('/applications')
              ? applications.future
              : schedules.future;
        }),
        root: _root,
        current: () => true);
    final app = directories.forRule('APP_UNINSTALL');
    final time = directories.forRule('TIME_WINDOW');
    await _settle();
    expect(
        paths, containsAllInOrder(['/api/v1$_root/applications', '/api/v1$_root/schedules']));
    expect(paths, hasLength(2));
    applications.complete(_page([
      {'id': 'a', 'displayName': '应用'}
    ]));
    schedules.complete(_page([
      {'id': 's', 'name': '时段'}
    ]));
    await Future.wait([app, time]);
    await directories.forRule('RUNTIME_PERMISSION');
    expect(paths, hasLength(2));
  });

  test('ordinary failure and reauthentication remain explicit and retryable',
      () async {
    for (final failure in [
      (503, 'SERVICE_UNAVAILABLE'),
      (401, 'REAUTH_REQUIRED')
    ]) {
      var calls = 0;
      final directories = PolicyRuleDirectories(
          api: _api((_) => ++calls == 1
              ? http.Response(jsonEncode({'errorCode': failure.$2}), failure.$1)
              : _page([
                  {'id': 'a', 'displayName': '应用'}
                ])),
          root: _root,
          current: () => true);
      await expectLater(
          directories.forRule('SPECIAL_ACCESS'),
          throwsA(isA<ApiFailure>()
              .having((error) => error.status, 'status', failure.$1)));
      expect(directories.hasRequested, isTrue);
      await directories.forRule('SPECIAL_ACCESS');
      expect(directories.applications.single['displayName'], '应用');
      expect(calls, 2);
    }
  });

  test('malformed options are rejected and do not become empty successes',
      () async {
    for (final rows in <List<Json>>[
      [
        {'id': 7, 'displayName': '应用'}
      ],
      [
        {'id': 'a', 'displayName': '   '}
      ],
      [
        {'id': 'a', 'displayName': '甲'},
        {'id': 'a', 'displayName': '乙'}
      ],
      [
        {'id': 'a' * 101, 'displayName': '应用'}
      ],
      [
        {'id': 'a', 'displayName': '名' * 101}
      ],
    ]) {
      var calls = 0;
      final directories = PolicyRuleDirectories(
          api: _api((_) => _page(++calls == 1
              ? rows
              : [
                  {'id': 'ok', 'displayName': '有效'}
                ])),
          root: _root,
          current: () => true);
      await expectLater(
          directories.forRule('APP_LAUNCH'),
          throwsA(isA<ApiFailure>().having((error) => error.code, 'code',
              'INVALID_POLICY_DIRECTORY_RESPONSE')));
      await directories.forRule('APP_LAUNCH');
      expect(directories.applications.single['id'], 'ok');
      expect(calls, 2);
    }
  });

  test('refresh only reads requested directories and keeps old data on failure',
      () async {
    final paths = <String>[];
    final directories = PolicyRuleDirectories(
        api: _api((request) {
          paths.add(request.url.path);
          return paths.length == 2
              ? http.Response('{"errorCode":"SERVICE_UNAVAILABLE"}', 503)
              : _page([
                  {'id': 'a', 'displayName': paths.length == 1 ? '旧名称' : '新名称'}
                ]);
        }),
        root: _root,
        current: () => true,
        schedules: const [
          {'id': 's', 'name': '种子时段'}
        ]);
    await directories.forRule('APP_LAUNCH');
    await expectLater(
        directories.reloadRequested(), throwsA(isA<ApiFailure>()));
    expect(directories.applications.single['displayName'], '旧名称');
    expect(directories.schedules.single['name'], '种子时段');
    await directories.reloadRequested();
    expect(directories.applications.single['displayName'], '新名称');
    expect(paths,
        ['/api/v1$_root/applications', '/api/v1$_root/applications', '/api/v1$_root/applications']);
  });

  test('observed parent loss is sticky and blocks late authentication dispatch',
      () async {
    var allowed = true;
    var calls = 0;
    final client = Completer<http.Client>();
    addTearDown(() {
      if (!client.isCompleted) {
        client.complete(MockClient((_) async => _page([])));
      }
    });
    final directories = PolicyRuleDirectories(
        api: Api(() => client.future),
        root: _root,
        current: () => allowed,
        schedules: const [
          {'id': 's', 'name': '私有时段'}
        ]);
    final failure =
        expectLater(directories.forRule('APP_LAUNCH'), throwsA(_lost));
    await _settle();
    allowed = false;
    expect(directories.schedules, isEmpty);
    allowed = true;
    client.complete(MockClient((_) async {
      calls++;
      return _page([]);
    }));
    await failure;
    expect(calls, 0);
    expect(directories.applications, isEmpty);
    expect(directories.hasRequested, isFalse);
    await expectLater(directories.reloadRequested(), throwsA(_lost));
    expect(calls, 0);
  });

  test('private refresh failures clear both caches and stop another page',
      () async {
    for (final failure in [
      (401, 'UNAUTHENTICATED'),
      (403, 'SCOPE_DENIED'),
      (409, 'WORKSPACE_CHANGED')
    ]) {
      final pending = Completer<http.Response>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(_page([]));
      });
      var refreshing = false;
      final requests = <http.Request>[];
      final directories = PolicyRuleDirectories(
          api: _api((request) {
            requests.add(request);
            if (!refreshing) {
              return request.url.path.endsWith('/applications')
                  ? _page([
                      {'id': 'a', 'displayName': '私有应用'}
                    ])
                  : _page([
                      {'id': 's', 'name': '私有时段'}
                    ]);
            }
            return request.url.path.endsWith('/applications')
                ? pending.future
                : http.Response(
                    jsonEncode({'errorCode': failure.$2}), failure.$1);
          }),
          root: _root,
          current: () => true);
      await directories.forRule('TIME_WINDOW');
      refreshing = true;
      await expectLater(
          directories.reloadRequested(),
          throwsA(isA<ApiFailure>()
              .having((error) => error.code, 'code', failure.$2)));
      expect(directories.applications, isEmpty);
      expect(directories.schedules, isEmpty);
      pending.complete(_page([
        {'id': 'late', 'displayName': '迟到'}
      ], 'forbidden-next'));
      await _settle();
      expect(requests, hasLength(4));
      expect(
          requests.where(
              (request) => request.url.queryParameters['cursor'] != null),
          isEmpty);
      await expectLater(directories.forRule('DOMAIN_ACCESS'), throwsA(_lost));
      expect(requests, hasLength(4));
    }
  });
}
