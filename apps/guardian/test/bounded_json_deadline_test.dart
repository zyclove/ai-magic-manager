import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart' as fake;
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/bounded_json.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:http/http.dart' as http;

void _current() {}

http.StreamedResponse _success(http.BaseRequest request) =>
    http.StreamedResponse(
        Stream.value(utf8.encode('{"id":"bounded-result"}')), 200,
        request: request, headers: {'content-type': 'application/json'});

class _Transport extends http.BaseClient {
  final headers = Completer<http.StreamedResponse>();
  final bodies = <String>[];
  final requests = <http.BaseRequest>[];
  final bool observeAbort;
  int sends = 0, aborts = 0;
  bool closed = false;
  Future<void>? trigger;
  _Transport({this.observeAbort = true});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    requests.add(request);
    if (observeAbort && request is http.Abortable) {
      trigger = request.abortTrigger;
      unawaited(trigger?.then<void>((_) {
        aborts++;
      }));
    }
    bodies.add(utf8.decode(await request.finalize().toBytes()));
    // The first request is controlled; a later explicit retry uses the same
    // borrowed transport but receives a fresh, complete response.
    return sends == 1 ? headers.future : _success(request);
  }

  @override
  void close() => closed = true;
}

class _RefreshClient extends http.BaseClient {
  final http.Client inner;
  final refresh = Completer<void>();
  int waits = 0;
  bool closed = false;
  _RefreshClient(this.inner);

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

class _ObservedBinding extends ScopeBindingClient {
  Future<void>? trigger;
  _ObservedBinding(super.inner) : super(isCurrent: _allowed);
  static bool _allowed() => true;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.Abortable) trigger = request.abortTrigger;
    return super.send(request);
  }
}

class _Outcome {
  bool completed = false;
  dynamic value;
  Object? error;
  _Outcome(Future<dynamic> future) {
    unawaited(future.then<void>((value) {
      this.value = value;
      completed = true;
    }, onError: (Object failure, StackTrace _) {
      error = failure;
      completed = true;
    }));
  }
}

void _expectFailure(_Outcome outcome, int status, String code) {
  expect(outcome.completed, isTrue);
  expect(outcome.value, isNull);
  expect(
      outcome.error,
      isA<ApiFailure>()
          .having((value) => value.status, 'status', status)
          .having((value) => value.code, 'code', code));
}

Future<dynamic> _post(Api api,
        {void Function() ensureCurrent = _current,
        void Function(BoundedHttpErrorEvidence)? onHttpError}) =>
    boundedJson(api, 'POST', '/copies',
        body: {'name': 'original'},
        key: 'original-bounded-key',
        version: 7,
        ensureCurrent: ensureCurrent,
        onHttpError: onHttpError);

void main() {
  test('late-refresh cannot dispatch a timed-out bounded POST', () {
    fake.fakeAsync((clock) {
      final physical = _Transport();
      final refresh = _RefreshClient(ScopeGuardedClient(physical));
      final api = Api(() async => refresh).scoped(() => true);
      final result = _Outcome(_post(api));
      clock.flushMicrotasks();
      expect(refresh.waits, 1);
      expect(physical.sends, 0);
      clock.elapse(const Duration(seconds: 25));
      clock.flushMicrotasks();
      _expectFailure(result, 0, 'NETWORK_ERROR');
      refresh.refresh.complete();
      clock.flushMicrotasks();
      expect(physical.sends, 0,
          reason:
              'An internal OAuth refresh must not release an expired write.');
      expect(refresh.closed, isFalse);
      expect(physical.closed, isFalse);
    });
  });

  test('nested scopes share abort and use one total streaming deadline',
      () async {
    late _Transport transport;
    late Api api;
    fake.fakeAsync((clock) {
      transport = _Transport();
      final binding = _ObservedBinding(transport);
      api = Api(() async => binding).scoped(() => true).scoped(() => true);
      var cancellations = 0;
      final body = StreamController<List<int>>(onCancel: () {
        cancellations++;
        return Future<void>.value();
      });
      final result = _Outcome(_post(api));
      clock.flushMicrotasks();
      expect(transport.sends, 1);
      expect(transport.trigger, isNotNull);
      expect(transport.trigger, same(binding.trigger));
      clock.elapse(const Duration(seconds: 20));
      transport.headers.complete(http.StreamedResponse(body.stream, 200,
          headers: {'content-type': 'application/json'}));
      body.add(utf8.encode('{"id":'));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 4));
      clock.flushMicrotasks();
      expect(result.completed, isFalse);
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      _expectFailure(result, 0, 'NETWORK_ERROR');
      expect(transport.aborts, 1);
      expect(cancellations, 1);
      expect(transport.closed, isFalse);
      unawaited(body.close());
      clock.flushMicrotasks();
    });
    // Normal completion can await an SDK shared cancellation Future outside
    // FakeAsync's queue. Verify a fresh explicit retry with bounded real async.
    final retry = await _post(api).timeout(const Duration(seconds: 2));
    expect(retry, {'id': 'bounded-result'});
    expect(transport.sends, 2);
    expect(transport.bodies, ['{"name":"original"}', '{"name":"original"}']);
    expect(transport.requests.last.headers['Idempotency-Key'],
        'original-bounded-key');
    expect(transport.requests.last.headers['If-Match'], '"7"');
    expect(transport.closed, isFalse);
  });

  test(
      'unsupported late headers and a failing body only clean up after timeout',
      () {
    fake.fakeAsync((clock) {
      final transport = _Transport(observeAbort: false);
      final evidence = <BoundedHttpErrorEvidence>[];
      final result = _Outcome(
          _post(Api(() async => transport), onHttpError: evidence.add));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 25));
      clock.flushMicrotasks();
      _expectFailure(result, 0, 'NETWORK_ERROR');
      var cancellations = 0;
      final body = StreamController<List<int>>(onCancel: () {
        cancellations++;
        return Future<void>.error(StateError('synthetic cancellation failure'));
      });
      body.addError(StateError('late private body failure'));
      transport.headers.complete(http.StreamedResponse(body.stream, 410,
          headers: {'content-type': 'application/problem+json'}));
      clock.flushMicrotasks();
      expect(cancellations, 1);
      expect(evidence, isEmpty);
      expect(transport.closed, isFalse);
      _expectFailure(result, 0, 'NETWORK_ERROR');
      unawaited(body.close());
      clock.flushMicrotasks();
    });
  });

  test('an incomplete HTTP 410 times out as untrusted request failure', () {
    fake.fakeAsync((clock) {
      final transport = _Transport();
      final evidence = <BoundedHttpErrorEvidence>[];
      var cancellations = 0;
      final body = StreamController<List<int>>(onCancel: () {
        cancellations++;
        return Future<void>.value();
      });
      final result = _Outcome(
          _post(Api(() async => transport), onHttpError: evidence.add));
      clock.flushMicrotasks();
      transport.headers.complete(http.StreamedResponse(body.stream, 410,
          headers: {'content-type': 'application/problem+json'}));
      body.add(utf8.encode('{"errorCode":"PUBLICATION_RESULT_TERMINAL"'));
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 25));
      clock.flushMicrotasks();
      _expectFailure(result, 410, 'REQUEST_FAILED');
      expect(evidence, isEmpty,
          reason:
              'Headers and partial JSON cannot prove a terminal business response.');
      expect(transport.aborts, 1);
      expect(cancellations, 1);
      expect(transport.closed, isFalse);
      unawaited(body.close());
      clock.flushMicrotasks();
    });
  });

  test('scope interruptions preserve original errors without HTTP evidence',
      () {
    for (final parentScope in [true, false]) {
      fake.fakeAsync((clock) {
        final transport = _Transport();
        var allowed = true;
        const denied = ApiFailure(409, 'EXPLICIT_SCOPE_FAILURE');
        var api = Api(() async => transport);
        if (parentScope) api = api.scoped(() => allowed);
        final evidence = <BoundedHttpErrorEvidence>[];
        final body =
            StreamController<List<int>>(onCancel: () => Future<void>.value());
        final result = _Outcome(_post(api, ensureCurrent: () {
          if (!parentScope && !allowed) throw denied;
        }, onHttpError: evidence.add));
        clock.flushMicrotasks();
        transport.headers.complete(http.StreamedResponse(body.stream, 410,
            headers: {'content-type': 'application/problem+json'}));
        clock.flushMicrotasks();
        allowed = false;
        body.addError(http.ClientException('synthetic broken response'));
        clock.flushMicrotasks();
        expect(result.completed, isTrue);
        expect(result.error,
            parentScope ? isA<ScopeChangedException>() : same(denied));
        expect(evidence, isEmpty);
        expect(transport.closed, isFalse);
        unawaited(body.close());
        clock.flushMicrotasks();
      });
    }
  });

  test(
      'completed bounded reads cancel their deadline and keep the client reusable',
      () async {
    final transport = _Transport();
    final api = Api(() async => transport);
    final deadlines = <Timer>[];
    Future<dynamic> perform({bool other = false}) => runZoned(
            () => other
                ? boundedJson(api, 'GET', '/other', ensureCurrent: _current)
                : _post(api),
            zoneSpecification: ZoneSpecification(
                createTimer: (self, parent, zone, duration, callback) {
          final timer = parent.createTimer(zone, duration, callback);
          if (duration == const Duration(seconds: 25)) deadlines.add(timer);
          return timer;
        }));
    try {
      final first = perform();
      transport.headers.complete(http.StreamedResponse(
          Stream.value(utf8.encode('{"id":"bounded-result"}')), 200,
          headers: {'content-type': 'application/json'}));
      expect(await first.timeout(const Duration(seconds: 2)),
          {'id': 'bounded-result'});
      expect(await perform().timeout(const Duration(seconds: 2)),
          {'id': 'bounded-result'});
      expect(await perform(other: true).timeout(const Duration(seconds: 2)),
          {'id': 'bounded-result'});
      expect(deadlines, hasLength(3));
      expect(deadlines.every((timer) => !timer.isActive), isTrue,
          reason:
              'A completed request must not retain a live 25-second abort timer.');
      expect(transport.aborts, 0);
      expect(transport.closed, isFalse);
      expect(transport.bodies.take(2),
          ['{"name":"original"}', '{"name":"original"}']);
    } finally {
      for (final timer in deadlines) {
        timer.cancel();
      }
    }
  });
}
