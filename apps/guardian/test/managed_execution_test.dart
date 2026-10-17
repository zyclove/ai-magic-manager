import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_execution.dart';
import 'package:guardian/core/managed_execution_repository.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oauth2/oauth2.dart' as oauth;
import 'api_scope_test.dart'
    show RecordingTransport, expiredCredentials, refreshedToken;
import 'managed_execution_fixtures.dart';

Matcher failure(String code) =>
    isA<ApiFailure>().having((e) => e.code, 'code', code);

void main() {
  test('parses a real-shaped execution and exposes readable labels', () {
    final f = ExecutionFixture();
    expect(() => f.selected(), returnsNormally);
    final task = f.selected();
    expect(task.id, executionId);
    expect(task.publicationId, executionPublication);
    expect(task.registrationId, executionRegistration);
    expect(task.stateLabel, '等待处理');
    expect(task.reasonLabel, isNotEmpty);
    expect(task.revision, 1);
    expect(task.cancellationRequested, isFalse);
  });

  for (final role in [
    'OWNER',
    'ORG_ADMIN',
    'AUDITOR',
    'GUARDIAN',
    'TEACHER',
    'CHILD',
    'unknown'
  ]) {
    test('execution access uses the backend role boundary for $role', () {
      expect(canReadManagedExecutions(role),
          ['OWNER', 'ORG_ADMIN', 'AUDITOR'].contains(role));
      expect(canManageManagedExecutions(role),
          ['OWNER', 'ORG_ADMIN'].contains(role));
    });
  }

  final malformed = <String, Object?>{
    'id': 'not-an-id',
    'publicationId': '123',
    'deviceId': executionOther,
    'registrationId': 'invalid',
    'state': 'SUCCESS',
    'reason': 'RAW_PROVIDER_ERROR',
    'revision': 0,
    'createdAt': -1,
    'updatedAt': 99,
    'cancellationRequested': 'true',
    'leaseToken': 'internal-must-not-enter-the-ui',
  };
  for (final entry in malformed.entries) {
    test('rejects invalid execution field ${entry.key}', () {
      final data = ExecutionFixture().record()..[entry.key] = entry.value;
      expect(() => ManagedExecution.parse(data, deviceId: executionDevice),
          throwsA(failure('INVALID_MANAGED_EXECUTION_RESPONSE')));
    });
  }
  for (final revision in [1.5, 9007199254740991, null]) {
    test('rejects unsafe or non-integral revision $revision', () {
      final raw = ExecutionFixture().record()..['revision'] = revision;
      expect(() => ManagedExecution.parse(raw, deviceId: executionDevice),
          throwsA(failure('INVALID_MANAGED_EXECUTION_RESPONSE')));
    });
  }
  test('timestamp must be representable by Flutter date formatting', () {
    final data = ExecutionFixture().record()..['updatedAt'] = 8640000000000001;
    expect(() => ManagedExecution.parse(data, deviceId: executionDevice),
        throwsA(failure('INVALID_MANAGED_EXECUTION_RESPONSE')));
  });

  for (final parameter in ['cursor', 'state', 'publication']) {
    test('invalid $parameter filter is rejected before authentication or HTTP',
        () async {
      final f = ExecutionFixture();
      await expectLater(
          f.repository().list(
              cursor: parameter == 'cursor' ? '../other' : null,
              state: parameter == 'state' ? 'UNKNOWN' : null,
              publicationId: parameter == 'publication' ? 'bad-id' : null),
          throwsA(isA<ApiFailure>()));
      expect(f.requests, isEmpty);
    });
  }
  for (final cursor in ['0', '-1', '01', '1.0', '9007199254740991', 'bad']) {
    test('invalid event cursor $cursor never sends a request', () async {
      final f = ExecutionFixture();
      await expectLater(f.repository().events(f.selected(), cursor: cursor),
          throwsA(isA<ApiFailure>()));
      expect(f.requests, isEmpty);
    });
  }

  test('lists only the fixed device and encodes selected filters', () async {
    final f = ExecutionFixture();
    final pending = f
        .repository()
        .list(state: 'READY_TO_WRITE', publicationId: executionPublication);
    await expectLater(pending, completes);
    final page = await pending;
    expect(page.items.single.id, executionId);
    expect(page.nextCursor, isNull);
    expect(f.requests.single.method, 'GET');
    expect(f.requests.single.url.path,
        '/api/v1/tenants/$executionTenant/managed-android/executions');
    expect(f.requests.single.url.queryParameters, {
      'deviceId': executionDevice,
      'limit': '50',
      'state': 'READY_TO_WRITE',
      'publicationId': executionPublication,
    });
    expect(() => page.items.clear(), throwsUnsupportedError);
  });

  test(
      'history remains readable while cancellation is limited to current registration',
      () async {
    final f = ExecutionFixture();
    final old = f.record(registration: executionOther);
    f.handler = (_) async => f.response({
          'items': [old],
          'nextCursor': null
        });
    final page = await f.repository().list();
    final task = page.items.single;
    expect(task.registrationId, executionOther);
    expect(f.repository().canCancel(task), isFalse);
    f.requests.clear();
    await expectLater(f.repository().cancel(task), throwsA(isA<ApiFailure>()));
    expect(f.requests, isEmpty);
  });

  for (final variant in [
    'duplicate',
    'time-order',
    'id-order',
    'cursor',
    'empty-cursor',
    'over-limit',
    'other-device',
    'repeat-anchor'
  ]) {
    test('rejects inconsistent execution page $variant', () async {
      final f = ExecutionFixture();
      Json page = {
        'items': [f.record()],
        'nextCursor': null
      };
      switch (variant) {
        case 'duplicate':
          page['items'] = [f.record(), f.record()];
        case 'time-order':
          page['items'] = [
            f.record(),
            f.record(id: executionOther, createdAt: 101, updatedAt: 101)
          ];
        case 'id-order':
          page['items'] = [f.record(), f.record(id: executionOther)];
        case 'cursor':
          page['nextCursor'] = executionOther;
        case 'empty-cursor':
          page = {'items': [], 'nextCursor': executionId};
        case 'over-limit':
          page['items'] = List.generate(51, (_) => f.record());
        case 'other-device':
          (page['items'][0] as Json)['deviceId'] = executionOther;
        case 'repeat-anchor':
          break;
      }
      f.handler = (_) async => f.response(page);
      await expectLater(
          f
              .repository()
              .list(cursor: variant == 'repeat-anchor' ? executionId : null),
          throwsA(failure('INVALID_MANAGED_EXECUTION_RESPONSE')));
    });
  }

  test('valid next page carries its cursor without changing device scope',
      () async {
    final f = ExecutionFixture();
    f.handler = (_) async => f.response({
          'items': [f.record()],
          'nextCursor': executionId
        });
    final page = await f.repository().list(cursor: executionOther);
    expect(page.nextCursor, executionId);
    expect(f.requests.single.url.queryParameters['cursor'], executionOther);
    expect(f.requests.single.url.queryParameters['deviceId'], executionDevice);
  });

  for (final filter in ['state', 'publication']) {
    test('response must match requested $filter filter', () async {
      final f = ExecutionFixture();
      await expectLater(
          f.repository().list(
              state: filter == 'state' ? 'APPLIED' : null,
              publicationId: filter == 'publication' ? executionOther : null),
          throwsA(failure('INVALID_MANAGED_EXECUTION_RESPONSE')));
    });
  }

  for (final key in [
    'id',
    'publicationId',
    'deviceId',
    'registrationId',
    'createdAt',
    'revision'
  ]) {
    test('detail cannot replace selected identity or regress $key', () async {
      final f = ExecutionFixture(), selected = ExecutionFixture().selected();
      final changed = f.record(revision: 2);
      changed[key] = key == 'createdAt'
          ? 99
          : key == 'revision'
              ? 0
              : executionOther;
      f.handler = (_) async => f.response(changed);
      await expectLater(f.repository().detail(selected),
          throwsA(failure('INVALID_MANAGED_EXECUTION_RESPONSE')));
    });
  }
  test('detail reads the selected task and accepts new progress', () async {
    final f = ExecutionFixture();
    f.handler =
        (_) async => f.response(f.record(revision: 2, reason: 'CLAIMED'));
    final result = await f.repository().detail(f.selected());
    expect(result.revision, 2);
    expect(f.requests.single.url.path.endsWith('/$executionId'), isTrue);
  });

  for (final key in ['state', 'reason', 'updatedAt', 'cancellationRequested']) {
    test('the same revision cannot rewrite $key', () async {
      final f = ExecutionFixture();
      final changed = f.record();
      changed[key] = switch (key) {
        'state' => 'NEEDS_REVIEW',
        'reason' => 'CLAIMED',
        'updatedAt' => 101,
        _ => true,
      };
      f.handler = (_) async => f.response(changed);
      await expectLater(f.repository().detail(f.selected()),
          throwsA(failure('INVALID_MANAGED_EXECUTION_RESPONSE')));
    });
  }

  for (final operation in ['detail', 'events', 'cancel']) {
    test('$operation rejects a selection from a different device before HTTP',
        () async {
      final f = ExecutionFixture();
      final raw = f.record()..['deviceId'] = executionOther;
      final other = ManagedExecution.parse(raw, deviceId: executionOther);
      final repository = f.repository();
      final request = switch (operation) {
        'detail' => repository.detail(other),
        'events' => repository.events(other),
        _ => repository.cancel(other),
      };
      await expectLater(request, throwsA(isA<ApiFailure>()));
      expect(f.requests, isEmpty);
    });
  }

  test('event page permits progress newer than the previously read detail',
      () async {
    final f = ExecutionFixture();
    f.handler = (_) async => f.response({
          'items': [f.event(revision: 2), f.event(revision: 3)],
          'nextCursor': '3'
        });
    final page = await f.repository().events(f.selected(), cursor: '1');
    expect(page.items.map((e) => e.revision), [2, 3]);
    expect(page.items.first.reasonLabel, isNotEmpty);
    expect(page.nextCursor, '3');
    expect(f.requests.single.url.path.endsWith('/$executionId/events'), isTrue);
    expect(
        f.requests.single.url.queryParameters, {'limit': '50', 'cursor': '1'});
  });
  for (final variant in [
    'duplicate',
    'reversed',
    'before-cursor',
    'cursor',
    'empty-cursor',
    'internal',
    'over-limit'
  ]) {
    test('rejects invalid event history $variant', () async {
      final f = ExecutionFixture();
      Json page = {
        'items': [f.event(revision: 2)],
        'nextCursor': null
      };
      switch (variant) {
        case 'duplicate':
          page['items'] = [f.event(revision: 2), f.event(revision: 2)];
        case 'reversed':
          page['items'] = [f.event(revision: 3), f.event(revision: 2)];
        case 'before-cursor':
          page['items'] = [f.event()];
        case 'cursor':
          page['nextCursor'] = '3';
        case 'empty-cursor':
          page = {'items': [], 'nextCursor': '2'};
        case 'internal':
          (page['items'][0] as Json)['leaseToken'] = 'secret';
        case 'over-limit':
          page['items'] = List.generate(51, (i) => f.event(revision: i + 2));
      }
      f.handler = (_) async => f.response(page);
      await expectLater(f.repository().events(f.selected(), cursor: '1'),
          throwsA(failure('INVALID_MANAGED_EXECUTION_RESPONSE')));
    });
  }

  test(
      'cancellation sends one versioned request and checks the returned result',
      () async {
    final f = ExecutionFixture();
    final result = await f.repository().cancel(f.selected());
    expect(result.cancellationRequested, isTrue);
    expect(result.state, 'CANCELLED');
    expect(result.revision, 2);
    expect(f.requests.single.method, 'POST');
    expect(f.requests.single.url.path.endsWith('/$executionId/cancel'), isTrue);
    expect(f.requests.single.headers['If-Match'], '"1"');
    expect(f.requests.single.body, isEmpty);
  });
  for (final variant in [
    'read-only',
    'applied',
    'cancelled',
    'already-requested'
  ]) {
    test('non-cancellable selection $variant never sends HTTP', () async {
      final f = ExecutionFixture();
      final data = f.record(
          state: variant == 'applied'
              ? 'APPLIED'
              : variant == 'cancelled'
                  ? 'CANCELLED'
                  : 'READY_TO_WRITE',
          cancelled: variant == 'already-requested');
      final task = ManagedExecution.parse(data, deviceId: executionDevice);
      final repository = f.repository(writable: variant != 'read-only');
      expect(repository.canCancel(task), isFalse);
      await expectLater(repository.cancel(task), throwsA(isA<ApiFailure>()));
      expect(f.requests, isEmpty);
    });
  }
  for (final variant in [
    'same-revision',
    'no-cancel-flag',
    'applied',
    'other-id'
  ]) {
    test(
        'a successful HTTP status cannot disguise invalid cancel result $variant',
        () async {
      final f = ExecutionFixture();
      final data = f.record(state: 'CANCELLED', revision: 2, cancelled: true);
      switch (variant) {
        case 'same-revision':
          data['revision'] = 1;
        case 'no-cancel-flag':
          data['cancellationRequested'] = false;
        case 'applied':
          data['state'] = 'APPLIED';
        case 'other-id':
          data['id'] = executionOther;
      }
      f.handler = (_) async => f.response(data);
      await expectLater(f.repository().cancel(f.selected()),
          throwsA(failure('INVALID_MANAGED_EXECUTION_RESPONSE')));
      expect(f.requests.length, 1);
    });
  }
  for (final status in [401, 403, 412, 503]) {
    test('cancel preserves HTTP $status without retry', () async {
      final f = ExecutionFixture();
      f.handler = (_) async =>
          f.response({'errorCode': 'REQUEST_FAILED'}, status: status);
      await expectLater(f.repository().cancel(f.selected()),
          throwsA(isA<ApiFailure>().having((e) => e.status, 'status', status)));
      expect(f.requests.length, 1);
    });
  }
  test('network failure during cancellation never automatically resends',
      () async {
    final f = ExecutionFixture();
    f.handler = (_) async =>
        throw http.ClientException('local simulated connection loss');
    await expectLater(
        f.repository().cancel(f.selected()), throwsA(failure('NETWORK_ERROR')));
    expect(f.requests.length, 1);
  });
  test('scope invalidation blocks both dispatch and late private response',
      () async {
    final f = ExecutionFixture()..current = false;
    await expectLater(
        f.repository().list(), throwsA(failure('WORKSPACE_CHANGED')));
    expect(f.requests, isEmpty);
    f.current = true;
    f.handler = (_) async {
      f.current = false;
      return f.response({
        'items': [f.record()],
        'nextCursor': null
      });
    };
    await expectLater(
        f.repository().list(), throwsA(failure('WORKSPACE_CHANGED')));
  });
  test('scope change while acquiring authenticated transport prevents send',
      () async {
    var current = true, sends = 0;
    final api = Api(() async {
      current = false;
      return MockClient((_) async {
        sends++;
        return http.Response('{}', 200);
      });
    }, baseUrl: 'http://execution.invalid/api/v1');
    final repository = ManagedExecutionRepository(
        api: api,
        tenantId: executionTenant,
        deviceId: executionDevice,
        registrationId: executionRegistration,
        writable: true,
        current: () => current);
    await expectLater(repository.list(), throwsA(failure('WORKSPACE_CHANGED')));
    expect(sends, 0);
  });

  for (final operation in ['list', 'cancel']) {
    test(
        '$operation cannot reach physical transport after scope loss during OAuth refresh',
        () async {
      var current = true;
      final raw = RecordingTransport();
      final client = oauth.Client(expiredCredentials(),
          identifier: 'guardian',
          basicAuth: false,
          httpClient: ScopeGuardedClient(raw));
      addTearDown(client.close);
      final repository = ManagedExecutionRepository(
          api: Api(() async => client, baseUrl: 'https://app.example/api/v1'),
          tenantId: executionTenant,
          deviceId: executionDevice,
          registrationId: executionRegistration,
          writable: true,
          current: () => current);
      final request = operation == 'list'
          ? repository.list()
          : repository.cancel(ExecutionFixture().selected());
      final rejected =
          expectLater(request, throwsA(failure('WORKSPACE_CHANGED')));
      await raw.tokenStarted.future.timeout(const Duration(seconds: 2));
      current = false;
      raw.tokenReply.complete(refreshedToken());
      await rejected;
      expect(raw.businessRequests, isEmpty,
          reason:
              'Reject before physical dispatch, not only before displaying the response.');
      expect(raw.requests.length, 1);
      expect(raw.closed, isFalse,
          reason: 'The session owns the authenticated transport.');
    });
  }
  test('oversized response is rejected before decoding task data', () async {
    final f = ExecutionFixture();
    f.handler = (_) async => http.Response(
        jsonEncode({'padding': 'x' * (256 * 1024)}), 200,
        headers: {'content-type': 'application/json'});
    await expectLater(f.repository().list(), throwsA(isA<ApiFailure>()));
  });
}
