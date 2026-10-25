import 'dart:async';

import 'package:fake_async/fake_async.dart' as fake;
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/audit_exports.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:http/http.dart' as http;

import 'audit_exports_test.dart' as fixtures;

class _Transport extends http.BaseClient {
  final headers = Completer<http.StreamedResponse>();
  int sends = 0, aborts = 0;
  bool closed = false;
  Future<void>? trigger;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sends++;
    request.finalize();
    if (request is http.Abortable) {
      trigger = request.abortTrigger;
      unawaited(trigger?.then<void>((_) {
        aborts++;
      }));
    }
    // Also exercises the late-response fallback for a transport that ignores
    // the abort signal. The caller must still cancel an eventual private body.
    return headers.future;
  }

  @override
  void close() => closed = true;
}

class _RefreshClient extends http.BaseClient {
  final http.Client inner;
  final refreshed = Completer<void>();
  _RefreshClient(this.inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await refreshed.future;
    return inner.send(request);
  }
}

class _Outcome {
  bool completed = false;
  Object? error;
  _Outcome(Future<dynamic> future) {
    unawaited(future.then<void>((_) => completed = true,
        onError: (Object failure, StackTrace _) {
      completed = true;
      error = failure;
    }));
  }
}

AuditExportRepository _repository(Api api, {bool Function()? current}) =>
    AuditExportRepository(
        api: api,
        root: '/tenants/${fixtures.id}',
        current: current ?? () => true);

AuditExportJob get _job => AuditExportJob.parse(fixtures.job(state: 'READY'));

void _expectFailure(_Outcome outcome, int status, String code) {
  expect(outcome.completed, isTrue);
  expect(
      outcome.error,
      isA<ApiFailure>()
          .having((e) => e.status, 'status', status)
          .having((e) => e.code, 'code', code));
}

void main() {
  test('download deadline includes initial authentication', () {
    fake.fakeAsync((clock) {
      final authenticated = Completer<http.Client>();
      final transport = _Transport();
      final result =
          _Outcome(_repository(Api(() => authenticated.future)).download(_job));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 25));
      clock.flushMicrotasks();
      _expectFailure(result, 0, 'NETWORK_ERROR');
      authenticated.complete(transport);
      clock.flushMicrotasks();
      expect(transport.sends, 0);
      expect(transport.closed, isFalse);
    });
  });

  test('download deadline aborts headers and discards a late private body', () {
    fake.fakeAsync((clock) {
      final transport = _Transport();
      final result =
          _Outcome(_repository(Api(() async => transport)).download(_job));
      clock.flushMicrotasks();
      expect(transport.sends, 1);
      clock.elapse(const Duration(seconds: 25));
      clock.flushMicrotasks();
      _expectFailure(result, 0, 'NETWORK_ERROR');
      expect(transport.trigger, isNotNull);
      expect(transport.aborts, 1);
      var cancellations = 0;
      final body = StreamController<List<int>>(onCancel: () {
        cancellations++;
      });
      transport.headers.complete(http.StreamedResponse(body.stream, 200));
      clock.flushMicrotasks();
      expect(cancellations, 1);
      expect(transport.closed, isFalse);
      unawaited(body.close());
      clock.flushMicrotasks();
    });
  });

  test('streaming download aborts and cancels at the same total deadline', () {
    fake.fakeAsync((clock) {
      final transport = _Transport();
      var cancellations = 0;
      final body = StreamController<List<int>>(onCancel: () {
        cancellations++;
      });
      final result =
          _Outcome(_repository(Api(() async => transport)).download(_job));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 20));
      transport.headers.complete(http.StreamedResponse(body.stream, 200));
      body.add([123]);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 5));
      clock.flushMicrotasks();
      _expectFailure(result, 0, 'NETWORK_ERROR');
      expect(transport.aborts, 1);
      expect(cancellations, 1);
      expect(transport.closed, isFalse);
      unawaited(body.close());
      clock.flushMicrotasks();
    });
  });

  test('late OAuth refresh cannot dispatch an expired nested-scope download',
      () {
    fake.fakeAsync((clock) {
      final transport = _Transport();
      final refresh = _RefreshClient(ScopeGuardedClient(transport));
      final api =
          Api(() async => refresh).scoped(() => true).scoped(() => true);
      final result = _Outcome(_repository(api).download(_job));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 25));
      clock.flushMicrotasks();
      _expectFailure(result, 0, 'NETWORK_ERROR');
      refresh.refreshed.complete();
      clock.flushMicrotasks();
      expect(transport.sends, 0);
      expect(transport.closed, isFalse);
    });
  });

  test('scope loss during OAuth refresh keeps the download error contract', () {
    fake.fakeAsync((clock) {
      var allowed = true;
      final transport = _Transport();
      final refresh = _RefreshClient(ScopeGuardedClient(transport));
      final api = Api(() async => refresh).scoped(() => allowed);
      final result = _Outcome(_repository(api).download(_job));
      clock.flushMicrotasks();
      allowed = false;
      refresh.refreshed.complete();
      clock.flushMicrotasks();
      _expectFailure(result, 409, 'WORKSPACE_CHANGED');
      expect(transport.sends, 0);
      expect(transport.closed, isFalse);
    });
  });
}
