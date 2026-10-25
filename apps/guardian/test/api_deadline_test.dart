import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart' as fake;
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:http/http.dart' as http;

Matcher get _networkFailure => isA<ApiFailure>()
    .having((error) => error.status, 'status', 0)
    .having((error) => error.code, 'code', 'NETWORK_ERROR');

Matcher get _changedPending => isA<ApiFailure>()
    .having((error) => error.code, 'code', 'PENDING_OPERATION_UNCHANGED');

http.StreamedResponse _success(http.BaseRequest request) =>
    http.StreamedResponse(
        Stream.value(utf8.encode('{"id":"original-result"}')), 200,
        request: request,
        headers: {'content-type': 'application/json; charset=utf-8'});

class _ImmediateTransport extends http.BaseClient {
  int sends = 0, abortSignals = 0;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    await request.finalize().drain<void>();
    expectSync(request, isA<http.Abortable>());
    final trigger = (request as http.Abortable).abortTrigger;
    expectSync(trigger, isNotNull);
    unawaited(trigger!.then((_) {
      abortSignals++;
    }));
    return _success(request);
  }

  @override
  void close() {
    closed = true;
  }
}

class _StreamingTransport extends http.BaseClient {
  int sends = 0, abortSignals = 0, cancellations = 0;
  Future<void>? trigger;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    await request.finalize().drain<void>();
    expectSync(request, isA<http.Abortable>());
    trigger = (request as http.Abortable).abortTrigger;
    expectSync(trigger, isNotNull);
    if (sends != 1) return _success(request);
    final body = StreamController<List<int>>(onCancel: () {
      cancellations++;
    });
    unawaited(trigger!.then((_) {
      abortSignals++;
      body.addError(http.ClientException('Request aborted', request.url));
      unawaited(body.close());
    }));
    body.add(utf8.encode('{"id":'));
    return http.StreamedResponse(body.stream, 200, request: request);
  }

  @override
  void close() {
    closed = true;
  }
}

// Observe the trigger before one real binding wrapper and at the final
// transport, in addition to the two scoped API views used by the test.
class _ObservedBindingClient extends ScopeBindingClient {
  Future<void>? trigger;
  _ObservedBindingClient(super.inner) : super(isCurrent: _alwaysCurrent);

  static bool _alwaysCurrent() => true;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    expectSync(request, isA<http.Abortable>());
    trigger = (request as http.Abortable).abortTrigger;
    return super.send(request);
  }
}

class _LateHeadersTransport extends http.BaseClient {
  final headers = Completer<http.StreamedResponse>();
  int sends = 0;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    await request.finalize().drain<void>();
    // Deliberately ignores Abortable, like a custom unsupported transport.
    return headers.future;
  }

  @override
  void close() {
    closed = true;
  }
}

// OAuth may already be the authenticated client while its refresh is pending.
// Forward the original request only after that internal wait, as OAuth does.
class _DelayedRefreshClient extends http.BaseClient {
  final http.Client inner;
  final refresh = Completer<void>();
  int waits = 0;
  bool closed = false;

  _DelayedRefreshClient(this.inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    waits++;
    await refresh.future;
    return inner.send(request);
  }

  @override
  void close() {
    closed = true;
    inner.close();
  }
}

// Observe completion without awaiting a Future that could be broken or stuck.
class _Outcome {
  bool completed = false;
  dynamic value;
  Object? error;

  _Outcome(Future<dynamic> future) {
    unawaited(future.then<void>((result) {
      value = result;
      completed = true;
    }, onError: (Object failure, StackTrace trace) {
      error = failure;
      completed = true;
    }));
  }
}

void _expectFailure(_Outcome outcome, Matcher matcher) {
  expect(outcome.completed, isTrue, reason: 'The request must have completed.');
  expect(outcome.error, matcher);
}

dynamic _value(_Outcome outcome) {
  expect(outcome.completed, isTrue,
      reason: 'The response must have completed.');
  expect(outcome.error, isNull);
  return outcome.value;
}

void _expectChangedPending(fake.FakeAsync clock, Api api, String key) {
  final changed = _Outcome(
      api.send('POST', '/copies', body: {'name': 'changed'}, key: key));
  clock.flushMicrotasks();
  _expectFailure(changed, _changedPending);
}

void main() {
  test('late authentication cannot dispatch an expired request', () {
    fake.fakeAsync((clock) {
      final authenticated = Completer<http.Client>();
      final transport = _ImmediateTransport();
      final api = Api(() => authenticated.future);
      final outcome = _Outcome(api.send('POST', '/copies',
          body: {'name': 'original'}, key: 'late-auth'));
      clock.flushMicrotasks();
      expect(outcome.completed, isFalse);
      clock.elapse(const Duration(seconds: 25));
      clock.flushMicrotasks();
      _expectFailure(outcome, _networkFailure);
      authenticated.complete(transport);
      clock.flushMicrotasks();
      expect(transport.sends, 0);
      expect(transport.closed, isFalse);
      _expectChangedPending(clock, api, 'late-auth');
      expect(transport.sends, 0);
    });
  });

  test('nested scopes preserve abort through a streaming deadline', () async {
    late final _StreamingTransport transport;
    late final Api api;
    fake.fakeAsync((clock) {
      transport = _StreamingTransport();
      final binding = _ObservedBindingClient(transport);
      api = Api(() async => binding).scoped(() => true).scoped(() => true);
      final outcome = _Outcome(api.send('POST', '/copies',
          body: {'name': 'original'}, key: 'stream-key'));
      clock.flushMicrotasks();
      expect(transport.sends, 1);
      expect(transport.trigger, same(binding.trigger));
      expect(transport.abortSignals, 0);
      expect(outcome.completed, isFalse);
      clock.elapse(const Duration(seconds: 25));
      clock.flushMicrotasks();
      _expectFailure(outcome, _networkFailure);
      expect(transport.abortSignals, 1);
      expect(transport.cancellations, 1);
      expect(transport.closed, isFalse);
      _expectChangedPending(clock, api, 'stream-key');
      expect(transport.sends, 1);
    });
    // Normal stream completion may await an SDK shared cancellation Future
    // outside FakeAsync's queue. Keep this completion check real and bounded.
    final retry = await api
        .send('POST', '/copies', body: {'name': 'original'}, key: 'stream-key')
        .timeout(const Duration(seconds: 2));
    expect(retry['id'], 'original-result');
    expect(transport.sends, 2);
  });

  test('completed responses do not abort after the old deadline', () {
    fake.fakeAsync((clock) {
      final transport = _ImmediateTransport();
      final api = Api(() async => transport);
      final response = _Outcome(api.send('POST', '/copies',
          body: {'name': 'original'}, key: 'complete-key'));
      clock.flushMicrotasks();
      expect(_value(response)['id'], 'original-result');
      clock.elapse(const Duration(seconds: 26));
      clock.flushMicrotasks();
      expect(transport.abortSignals, 0);
      expect(transport.closed, isFalse);
      final next = _Outcome(api.send('POST', '/copies',
          body: {'name': 'changed'}, key: 'complete-key'));
      clock.flushMicrotasks();
      expect(_value(next)['id'], 'original-result');
      expect(transport.sends, 2);
    });
  });

  test('late headers are discarded without releasing the pending write', () {
    fake.fakeAsync((clock) {
      final transport = _LateHeadersTransport();
      final api = Api(() async => transport);
      final outcome = _Outcome(api.send('POST', '/copies',
          body: {'name': 'original'}, key: 'late-headers'));
      clock.flushMicrotasks();
      expect(transport.sends, 1);
      clock.elapse(const Duration(seconds: 25));
      clock.flushMicrotasks();
      _expectFailure(outcome, _networkFailure);
      var listens = 0, cancellations = 0;
      final body = StreamController<List<int>>(onListen: () {
        listens++;
      }, onCancel: () {
        cancellations++;
      });
      transport.headers.complete(http.StreamedResponse(body.stream, 200));
      clock.flushMicrotasks();
      expect(listens, 1);
      expect(cancellations, 1);
      expect(transport.closed, isFalse);
      _expectChangedPending(clock, api, 'late-headers');
      expect(transport.sends, 1);
      unawaited(body.close());
      clock.flushMicrotasks();
    });
  });

  test('late OAuth refresh cannot forward an expired unscoped request', () {
    fake.fakeAsync((clock) {
      final transport = _ImmediateTransport();
      final authenticated =
          _DelayedRefreshClient(ScopeGuardedClient(transport));
      final api = Api(() async => authenticated);
      final outcome = _Outcome(api.send('POST', '/copies',
          body: {'name': 'original'}, key: 'late-oauth-refresh'));
      clock.flushMicrotasks();
      expect(authenticated.waits, 1);
      expect(transport.sends, 0);
      clock.elapse(const Duration(seconds: 25));
      clock.flushMicrotasks();
      _expectFailure(outcome, _networkFailure);
      authenticated.refresh.complete();
      clock.flushMicrotasks();
      expect(transport.sends, 0);
      expect(authenticated.closed, isFalse);
      expect(transport.closed, isFalse);
      _expectChangedPending(clock, api, 'late-oauth-refresh');
      expect(authenticated.waits, 1);
      expect(transport.sends, 0);
    });
  });
}
