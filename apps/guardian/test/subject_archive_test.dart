import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/subject_archive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _root = '/api/v1/tenants/b1111111-1111-4111-8111-111111111111';
const _id = 'a1111111-1111-4111-8111-111111111111';
const _key = 'c1111111-1111-4111-8111-111111111111';
Json _subject() => {'id': _id, 'nickname': '小星', 'ageBand': 'AGE_7_12',
  'version': 7, 'state': 'ACTIVE'};
Json _committed() => {..._subject(), 'version': 8, 'state': 'ARCHIVED'};
Json _queryResult() => {'operation': 'ARCHIVE', 'committed': _committed(),
  'current': {..._committed(), 'version': 9, 'nickname': '当前昵称'}};
http.Response _reply(Object? value, {int status = 200}) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
String? _requestKey(http.Request request) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == 'idempotency-key') return entry.value;
  }
  return null;
}
Matcher get _invalid => isA<ApiFailure>()
    .having((error) => error.status, 'status', 502)
    .having((error) => error.code, 'code', 'INVALID_RESPONSE');

void main() {
  test('uncertain archive only queries its frozen original operation until matched', () async {
    final requests = <http.Request>[];
    final responses = [
      _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503),
      _reply({'errorCode': 'SUBJECT_RESULT_UNAVAILABLE'}, status: 404),
      _reply({'errorCode': 'REAUTH_REQUIRED'}, status: 401),
      _reply({'errorCode': 'ACCESS_DENIED'}, status: 403),
      _reply({..._queryResult(), 'committed': {..._committed(), 'version': 9}}),
      _reply({..._queryResult(), 'current': {..._committed(), 'state': 'ACTIVE'}}),
      _reply(_queryResult()),
    ];
    final client = MockClient((request) async {
      requests.add(request);
      return responses.removeAt(0);
    });
    addTearDown(client.close);
    final source = {..._subject(), 'private': {'unrelated': 'discarded'}};
    var attempts = 0;
    final operation = SubjectArchiveOperation(api: Api(() async => client,
        baseUrl: 'http://fixture.test'), root: _root, requestKey: _key,
        subject: source, isCurrent: () => true, onSubmitAttempt: () => attempts++);
    addTearDown(operation.dispose);
    source.clear();
    expect(operation.subject.keys, unorderedEquals(['id', 'nickname', 'ageBand', 'version', 'state']));
    expect(() => operation.subject['nickname'] = '变更', throwsUnsupportedError);
    expect(() => operation.body['version'] = 99, throwsUnsupportedError);
    await operation.submit();
    expect(operation.attempted, isTrue);
    expect(operation.uncertain, isTrue);
    expect(operation.canSubmit, isFalse);
    expect(operation.canQuery, isTrue);
    for (final status in [404, 401, 403]) {
      await operation.submit();
      await operation.query();
      expect((operation.error as ApiFailure).status, status);
      expect(operation.uncertain, isTrue);
      expect(operation.stopped, isFalse);
      expect(operation.result, isNull);
      expect(operation.canSubmit, isFalse);
      expect(operation.canQuery, isTrue);
    }
    for (var index = 0; index < 2; index++) {
      await operation.query();
      expect(operation.error, _invalid);
      expect(operation.result, isNull);
      expect(operation.currentSnapshot, isNull);
      expect(operation.uncertain, isTrue);
      expect(operation.canQuery, isTrue);
    }
    await operation.query();
    expect(operation.result, _committed());
    expect(operation.currentSnapshot, _queryResult()['current']);
    expect(operation.error, isNull);
    expect(operation.uncertain, isTrue);
    expect(operation.canSubmit, isFalse);
    expect(operation.canQuery, isFalse);
    await operation.submit();
    await operation.query();
    expect(attempts, 1);
    expect(requests, hasLength(7));
    expect(requests.first.url.path, '$_root/subjects/changes');
    expect(_requestKey(requests.first), _key);
    for (final request in requests) {
      expect(request.method, 'POST');
      expect(jsonDecode(request.body), {'operation': 'ARCHIVE', 'subjectId': _id, 'version': 7});
    }
    for (final request in requests.skip(1)) {
      expect(request.url.path, '$_root/subjects/operation-results/$_key/query');
      expect(_requestKey(request), isNull);
    }
    expect(() => operation.result!['version'] = 99, throwsUnsupportedError);
    expect(() => operation.currentSnapshot!['version'] = 99, throwsUnsupportedError);
  });

  test('validation, definite authentication failure and terminal failures keep exact boundaries', () async {
    final client = MockClient((_) async => _reply(_committed()));
    addTearDown(client.close);
    final api = Api(() async => client, baseUrl: 'http://fixture.test');
    for (final invalid in <Json>[
      {..._subject(), 'id': _id.toUpperCase()},
      {..._subject(), 'id': 'bad'},
      {..._subject(), 'nickname': ' '},
      {..._subject(), 'ageBand': 'UNKNOWN'},
      {..._subject(), 'version': -1},
      {..._subject(), 'version': 7.0},
      {..._subject(), 'version': 9007199254740991},
      {..._subject(), 'state': 'ARCHIVED'},
    ]) {
      expect(() => SubjectArchiveOperation(api: api, root: _root, requestKey: _key,
          subject: invalid, isCurrent: () => true), throwsA(_invalid));
    }
    expect(() => SubjectArchiveOperation(api: api, root: _root,
        requestKey: 'c1111111-1111-1111-8111-111111111111',
        subject: _subject(), isCurrent: () => true), throwsA(_invalid));

    for (final invalid in <Object?>[
      null, [], {..._committed(), 'id': 'a2222222-2222-4222-8222-222222222222'},
      {..._committed(), 'state': 'ACTIVE'}, {..._committed(), 'version': 7},
      {..._committed(), 'nickname': '其他昵称'}, {..._committed(), 'ageBand': 'UNDER_7'},
    ]) {
      final transport = MockClient((_) async => _reply(invalid));
      final operation = SubjectArchiveOperation(api: Api(() async => transport,
          baseUrl: 'http://fixture.test'), root: _root, requestKey: _key,
          subject: _subject(), isCurrent: () => true);
      try {
        await operation.submit();
        expect(operation.error, _invalid);
        expect(operation.result, isNull);
        expect(operation.uncertain, isTrue);
        expect(operation.canSubmit, isFalse);
        expect(operation.canQuery, isTrue);
      } finally {
        operation.dispose();
        transport.close();
      }
    }

    final retries = <http.Request>[];
    final retryClient = MockClient((request) async {
      retries.add(request);
      return retries.length == 1
          ? _reply({'errorCode': 'REAUTH_REQUIRED'}, status: 401)
          : _reply(_committed());
    });
    addTearDown(retryClient.close);
    final retry = SubjectArchiveOperation(api: Api(() async => retryClient,
        baseUrl: 'http://fixture.test'), root: _root, requestKey: _key,
        subject: _subject(), isCurrent: () => true);
    addTearDown(retry.dispose);
    await retry.submit();
    expect(retry.canSubmit, isTrue);
    expect(retry.uncertain, isFalse);
    await retry.submit();
    expect(retry.result, _committed());
    expect(retries, hasLength(2));
    expect(retries.last.body, retries.first.body);
    expect(_requestKey(retries.last), _requestKey(retries.first));

    for (final failure in [(412, 'VERSION_CONFLICT'), (410, 'IDEMPOTENCY_RESPONSE_ERASED')]) {
      for (final terminalOnQuery in [false, true]) {
        var calls = 0;
        final transport = MockClient((_) async {
          calls++;
          return terminalOnQuery && calls == 1
              ? _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503)
              : _reply({'errorCode': failure.$2}, status: failure.$1);
        });
        final operation = SubjectArchiveOperation(api: Api(() async => transport,
            baseUrl: 'http://fixture.test'), root: _root, requestKey: _key,
            subject: _subject(), isCurrent: () => true);
        try {
          await operation.submit();
          if (terminalOnQuery) await operation.query();
          expect(operation.stopped, isTrue);
          expect(operation.result, isNull);
          expect(operation.canSubmit, isFalse);
          expect(operation.canQuery, isFalse);
          await operation.submit();
          await operation.query();
          expect(calls, terminalOnQuery ? 2 : 1);
        } finally {
          operation.dispose();
          transport.close();
        }
      }
    }
  });

  test('scope retirement and disposal discard late write and query responses', () async {
    for (final phase in ['submit', 'query', 'dispose']) {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      var permitted = true, notices = 0, calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (phase == 'query' && calls == 1) {
          return _reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503);
        }
        started.complete();
        return response.future;
      });
      final operation = SubjectArchiveOperation(api: Api(() async => client,
          baseUrl: 'http://fixture.test'), root: _root, requestKey: _key,
          subject: _subject(), isCurrent: () => permitted);
      operation.addListener(() => notices++);
      try {
        if (phase == 'query') await operation.submit();
        final running = phase == 'query' ? operation.query() : operation.submit();
        await started.future;
        final beforeRetirement = notices;
        if (phase == 'dispose') {
          operation.dispose();
        } else {
          permitted = false;
          expect(operation.current, isFalse);
          permitted = true;
        }
        response.complete(_reply(phase == 'query' ? _queryResult() : _committed()));
        await running;
        expect(operation.current, isFalse);
        expect(operation.result, isNull);
        expect(operation.currentSnapshot, isNull);
        expect(operation.busy, isFalse);
        expect(notices, beforeRetirement);
        await operation.submit();
        await operation.query();
        expect(calls, phase == 'query' ? 2 : 1);
      } finally {
        operation.dispose();
        client.close();
      }
    }
  });
}
