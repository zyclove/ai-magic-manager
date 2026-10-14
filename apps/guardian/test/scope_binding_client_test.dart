import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth;

import 'api_scope_test.dart'
    show RecordingTransport, expiredCredentials, refreshedToken;

class _ProbeClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  final requests = <http.BaseRequest>[];
  var closed = false;

  _ProbeClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (closed) throw StateError('Shared client was closed.');
    requests.add(request);
    return handler(request);
  }

  @override
  void close() => closed = true;
}

class _StreamRequest extends http.BaseRequest {
  final Stream<List<int>> body;
  _StreamRequest(super.method, super.url, this.body);

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(body);
  }
}

http.StreamedResponse _response({http.BaseRequest? request}) =>
    http.StreamedResponse(Stream.value(utf8.encode('{"id":"current"}')), 200,
        request: request);

void main() {
  test('stale raw GET is blocked before physical delegate entry', () async {
    final raw = _ProbeClient((request) async => _response(request: request));
    final bound = ScopeBindingClient(raw, isCurrent: () => false);
    await expectLater(bound.get(Uri.parse('https://business.example/private')),
        throwsA(isA<ScopeChangedException>()));
    expect(raw.requests, isEmpty);
  });

  test('current raw GET preserves headers and response metadata', () async {
    final raw = _ProbeClient((request) async {
      expect(request.method, 'GET');
      expect(request.url, Uri.parse('https://business.example/private?x=1'));
      expect(request.headers['x-selection'], 'original');
      request.finalize();
      return http.StreamedResponse(Stream.value(utf8.encode('current')), 206,
          headers: {'content-type': 'text/plain', 'x-result': 'original'},
          reasonPhrase: 'Partial Content',
          contentLength: 7,
          isRedirect: false,
          persistentConnection: false,
          request: request);
    });
    final bound = ScopeBindingClient(raw, isCurrent: () => true);
    final response = await bound.send(
        http.Request('GET', Uri.parse('https://business.example/private?x=1'))
          ..headers['x-selection'] = 'original');
    expect(response.statusCode, 206);
    expect(response.reasonPhrase, 'Partial Content');
    expect(response.contentLength, 7);
    expect(response.isRedirect, isFalse);
    expect(response.persistentConnection, isFalse);
    expect(response.headers['x-result'], 'original');
    expect(await response.stream.bytesToString(), 'current');
  });

  test('raw JSON POST keeps its original bytes and content type', () async {
    final payload = jsonEncode({'name': 'original', 'count': 2});
    final raw = _ProbeClient((request) async {
      expect(request.method, 'POST');
      expect(request.headers['content-type'], 'application/json');
      expect(await request.finalize().bytesToString(), payload);
      return _response(request: request);
    });
    final bound = ScopeBindingClient(raw, isCurrent: () => true);
    expect(
        (await bound.post(Uri.parse('https://business.example/private'),
                body: payload, headers: {'content-type': 'application/json'}))
            .statusCode,
        200);
    expect(raw.requests, hasLength(1));
  });

  test('body streams reach the delegate without being fully buffered first',
      () async {
    var bodyListens = 0;
    final source = StreamController<List<int>>(onListen: () => bodyListens++);
    final entered = Completer<void>();
    final received = <int>[];
    final consumed = Completer<void>();
    final raw = _ProbeClient((request) async {
      expect(bodyListens, 0,
          reason: 'The body must not be subscribed before physical dispatch.');
      expect(request.contentLength, 4);
      expect(request.followRedirects, isFalse);
      expect(request.maxRedirects, 2);
      expect(request.persistentConnection, isFalse);
      expect(request.headers['x-stream'], 'original');
      entered.complete();
      request.finalize().listen(received.addAll, onDone: consumed.complete);
      return _response(request: request);
    });
    final bound = ScopeBindingClient(raw, isCurrent: () => true);
    final request = _StreamRequest(
        'POST', Uri.parse('https://business.example/stream'), source.stream)
      ..contentLength = 4
      ..followRedirects = false
      ..maxRedirects = 2
      ..persistentConnection = false
      ..headers['x-stream'] = 'original';
    final sending = bound.send(request);
    await Future<void>.delayed(Duration.zero);
    final dispatchedBeforeBody = entered.isCompleted;
    source.add([1, 2]);
    source.add([3, 4]);
    await source.close();
    await sending;
    await consumed.future;
    expect(dispatchedBeforeBody, isTrue,
        reason:
            'An open arbitrary request body must not delay delegate entry.');
    expect(bodyListens, 1);
    expect(received, [1, 2, 3, 4]);
  });

  test('closing a bound client never closes its borrowed session client',
      () async {
    final raw = _ProbeClient((request) async {
      request.finalize();
      return _response(request: request);
    });
    final bound = ScopeBindingClient(raw, isCurrent: () => true);
    bound.close();
    bound.close();
    expect(raw.closed, isFalse);
    expect((await raw.get(Uri.parse('https://business.example/me'))).statusCode,
        200);
  });

  test('nested raw client bindings cannot override an outer stale guard',
      () async {
    final raw = _ProbeClient((request) async => _response(request: request));
    final outer = ScopeBindingClient(raw, isCurrent: () => false);
    final inner = ScopeBindingClient(outer, isCurrent: () => true);
    await expectLater(inner.get(Uri.parse('https://business.example/private')),
        throwsA(isA<ScopeChangedException>()));
    expect(raw.requests, isEmpty);
  });

  for (final loseOriginal in [false, true]) {
    test('OAuth dispatch retains ${loseOriginal ? 'request' : 'bound'} guard',
        () async {
      var boundCurrent = true, originalCurrent = true;
      final raw = RecordingTransport();
      final authenticated = oauth.Client(expiredCredentials(),
          identifier: 'guardian',
          basicAuth: false,
          httpClient: ScopeGuardedClient(raw));
      addTearDown(authenticated.close);
      final bound =
          ScopeBindingClient(authenticated, isCurrent: () => boundCurrent);
      final request = ScopeGuardedRequest(
          'POST', Uri.parse('https://business.example/private'),
          isCurrent: () => originalCurrent)
        ..body = '{"name":"original"}';
      final result = bound.send(request);
      final rejected =
          expectLater(result, throwsA(isA<ScopeChangedException>()));
      await raw.tokenStarted.future;
      if (loseOriginal) {
        originalCurrent = false;
      } else {
        boundCurrent = false;
      }
      raw.tokenReply.complete(refreshedToken());
      await rejected;
      expect(raw.businessRequests, isEmpty,
          reason: 'Physical transport must check both guards after refresh.');
    });
  }

  test('a raw GET remains bound while real OAuth waits for refresh', () async {
    var current = true;
    final raw = RecordingTransport();
    final authenticated = oauth.Client(expiredCredentials(),
        identifier: 'guardian',
        basicAuth: false,
        httpClient: ScopeGuardedClient(raw));
    addTearDown(authenticated.close);
    final bound = ScopeBindingClient(authenticated, isCurrent: () => current);
    final result = bound.get(Uri.parse('https://business.example/private'));
    final rejected = expectLater(result, throwsA(isA<ScopeChangedException>()));
    await raw.tokenStarted.future;
    current = false;
    raw.tokenReply.complete(refreshedToken());
    await rejected;
    expect(raw.businessRequests, isEmpty);
  });

  test('current OAuth raw POST retains bearer and original streamed body',
      () async {
    final tokenEndpoint = Uri.parse('https://identity.example/token');
    final tokenStarted = Completer<void>();
    final tokenReply = Completer<http.StreamedResponse>();
    String? businessBody;
    final raw = _ProbeClient((request) async {
      if (request.url == tokenEndpoint) {
        request.finalize();
        tokenStarted.complete();
        return tokenReply.future;
      }
      expect(request.headers['authorization'], 'Bearer fresh-access');
      expect(request.headers['x-original'], 'selection');
      businessBody = await request.finalize().bytesToString();
      return _response(request: request);
    });
    final authenticated = oauth.Client(expiredCredentials(),
        identifier: 'guardian',
        basicAuth: false,
        httpClient: ScopeGuardedClient(raw));
    addTearDown(authenticated.close);
    final bound = ScopeBindingClient(authenticated, isCurrent: () => true);
    final request = http.StreamedRequest(
        'POST', Uri.parse('https://business.example/private'))
      ..headers['x-original'] = 'selection';
    request.sink.add(utf8.encode('{"name":"original"}'));
    unawaited(request.sink.close());
    final result = bound.send(request);
    await tokenStarted.future;
    tokenReply.complete(refreshedToken());
    expect((await result).statusCode, 200);
    expect(businessBody, '{"name":"original"}');
    expect(raw.requests, hasLength(2));
  });

  test('scope loss before response headers cancels unread delegate stream',
      () async {
    var current = true, cancelled = false;
    final started = Completer<void>();
    final reply = Completer<http.StreamedResponse>();
    final body =
        StreamController<List<int>>.broadcast(onCancel: () => cancelled = true);
    addTearDown(body.close);
    final raw = _ProbeClient((request) {
      request.finalize();
      started.complete();
      return reply.future;
    });
    final bound = ScopeBindingClient(raw, isCurrent: () => current);
    final result = bound.send(
        http.Request('GET', Uri.parse('https://business.example/private')));
    final rejected = expectLater(result, throwsA(isA<ScopeChangedException>()));
    await started.future;
    current = false;
    reply.complete(http.StreamedResponse(body.stream, 200));
    await rejected;
    expect(cancelled, isTrue);
  });

  test('scope loss after headers blocks body consumption and cancels stream',
      () async {
    var current = true, cancelled = false;
    final body = StreamController<List<int>>(onCancel: () => cancelled = true);
    final raw = _ProbeClient((request) async {
      request.finalize();
      return http.StreamedResponse(body.stream, 200);
    });
    final bound = ScopeBindingClient(raw, isCurrent: () => current);
    final response = await bound.send(
        http.Request('GET', Uri.parse('https://business.example/private')));
    current = false;
    body.add(utf8.encode('old-private'));
    unawaited(body.close());
    await expectLater(http.Response.fromStream(response),
        throwsA(isA<ScopeChangedException>()));
    expect(cancelled, isTrue);
  });

  test('scope loss during response body stops later chunks and cancels source',
      () async {
    var current = true, cancelled = false;
    final body = StreamController<List<int>>(onCancel: () => cancelled = true);
    final raw = _ProbeClient((request) async {
      request.finalize();
      return http.StreamedResponse(body.stream, 200);
    });
    final bound = ScopeBindingClient(raw, isCurrent: () => current);
    final response = await bound.send(
        http.Request('GET', Uri.parse('https://business.example/private')));
    final iterator = StreamIterator<List<int>>(response.stream);
    addTearDown(iterator.cancel);
    body.add([1]);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, [1]);
    current = false;
    final next = iterator.moveNext();
    final rejected = expectLater(next, throwsA(isA<ScopeChangedException>()));
    body.add(utf8.encode('old-private'));
    unawaited(body.close());
    await rejected;
    expect(cancelled, isTrue);
  });

  test('downstream cancellation cancels an idle response without another chunk',
      () async {
    final listening = Completer<void>();
    final cancelled = Completer<void>();
    final body = StreamController<List<int>>(
      onListen: () => listening.complete(),
      onCancel: () {
        if (!cancelled.isCompleted) cancelled.complete();
      },
    );
    final raw = _ProbeClient((request) async {
      request.finalize();
      return http.StreamedResponse(body.stream, 200);
    });
    final bound = ScopeBindingClient(raw, isCurrent: () => true);
    final response = await bound.send(
        http.Request('GET', Uri.parse('https://business.example/private')));
    final received = <List<int>>[];
    final subscription = response.stream.listen(received.add);
    try {
      await listening.future.timeout(const Duration(milliseconds: 500),
          onTimeout: () => fail('The response source was never subscribed.'));
      final downstreamCancelled = subscription.cancel();
      // Do not add a chunk or close the source before either assertion: an
      // idle network response must be cancellable by its consumer alone.
      await cancelled.future.timeout(const Duration(milliseconds: 500),
          onTimeout: () => fail(
              'Cancelling the downstream subscription did not cancel the idle source.'));
      await downstreamCancelled.timeout(const Duration(milliseconds: 500),
          onTimeout: () => fail(
              'Downstream cancellation waited for another response event.'));
      expect(received, isEmpty);
      expect(raw.closed, isFalse,
          reason: 'Response cleanup must not close the shared session client.');
    } finally {
      // Closing is only fixture cleanup. It also releases an old async* wrapper
      // stuck in moveNext so the expected RED cannot hang the whole gate.
      try {
        await Future.wait([body.close(), subscription.cancel()])
            .timeout(const Duration(seconds: 1));
      } on TimeoutException {
        // Both cleanup operations were requested; preserve the bounded,
        // actionable cancellation assertion instead of hanging teardown.
      }
    }
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('a queued synchronous chunk is not delivered after scope loss',
      () async {
    var current = true;
    final listening = Completer<void>();
    final body = StreamController<List<int>>(
        sync: true, onListen: () => listening.complete());
    final raw = _ProbeClient((request) async {
      request.finalize();
      return http.StreamedResponse(body.stream, 200);
    });
    final response = await ScopeBindingClient(raw, isCurrent: () => current)
        .send(
            http.Request('GET', Uri.parse('https://business.example/private')));
    final afterLoss = <List<int>>[], errors = <Object>[];
    final done = Completer<void>();
    final subscription = response.stream.listen((chunk) {
      if (!current) afterLoss.add(chunk);
    },
        onError: (Object error, StackTrace _) => errors.add(error),
        onDone: done.complete);
    try {
      await listening.future.timeout(const Duration(milliseconds: 500));
      // A legal synchronous source: listen has returned before add is called.
      body.add([17, 18]);
      current = false;
      unawaited(body.close());
      await done.future.timeout(const Duration(milliseconds: 500));
      expect(afterLoss, isEmpty,
          reason: 'Scope must hold when the actual consumer receives bytes.');
      expect(errors, everyElement(isA<ScopeChangedException>()));
      expect(raw.closed, isFalse);
    } finally {
      await _closeResponseFixture(body, subscription);
    }
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('paused queued bytes are checked again when the consumer resumes',
      () async {
    var current = true;
    final listening = Completer<void>();
    final body = StreamController<List<int>>(
        sync: true, onListen: () => listening.complete());
    final raw = _ProbeClient((request) async {
      request.finalize();
      return http.StreamedResponse(body.stream, 200);
    });
    final response = await ScopeBindingClient(raw, isCurrent: () => current)
        .send(
            http.Request('GET', Uri.parse('https://business.example/private')));
    final afterLoss = <List<int>>[], errors = <Object>[];
    final done = Completer<void>();
    final subscription = response.stream.listen((chunk) {
      if (!current) afterLoss.add(chunk);
    },
        onError: (Object error, StackTrace _) => errors.add(error),
        onDone: done.complete);
    try {
      await listening.future.timeout(const Duration(milliseconds: 500));
      body.add([21, 22]);
      // Pause after the source produced its chunk, before an asynchronous
      // wrapper can deliver the queued event to this consumer.
      subscription.pause();
      current = false;
      subscription.resume();
      unawaited(body.close());
      await done.future.timeout(const Duration(milliseconds: 500));
      expect(afterLoss, isEmpty,
          reason: 'Resuming a paused consumer must not release stale bytes.');
      expect(errors, everyElement(isA<ScopeChangedException>()));
      expect(raw.closed, isFalse);
    } finally {
      subscription.resume();
      await _closeResponseFixture(body, subscription);
    }
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('queued natural completion cannot succeed after scope loss', () async {
    var current = true, staleSuccess = false;
    final listening = Completer<void>();
    final body = StreamController<List<int>>(
        sync: true, onListen: () => listening.complete());
    final raw = _ProbeClient((request) async {
      request.finalize();
      return http.StreamedResponse(body.stream, 200);
    });
    final response = await ScopeBindingClient(raw, isCurrent: () => current)
        .send(
            http.Request('GET', Uri.parse('https://business.example/private')));
    final errors = <Object>[];
    final done = Completer<void>();
    final subscription = response.stream.listen((_) {},
        onError: (Object error, StackTrace _) => errors.add(error),
        onDone: () {
          staleSuccess = !current && errors.isEmpty;
          done.complete();
        });
    try {
      await listening.future.timeout(const Duration(milliseconds: 500));
      // Let the synchronous source end, then invalidate before a queued done
      // event can report success to the actual consumer.
      unawaited(body.close());
      current = false;
      await done.future.timeout(const Duration(milliseconds: 500));
      expect(staleSuccess, isFalse,
          reason: 'A stale empty response must not complete successfully.');
      expect(errors, everyElement(isA<ScopeChangedException>()));
      expect(raw.closed, isFalse);
    } finally {
      await _closeResponseFixture(body, subscription);
    }
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('source cancel failure preserves scope error without an unhandled error',
      () async {
    final unhandled = <Object>[];
    final finished = Completer<void>();
    Object? observedFailure;
    Object? setupFailure;
    StackTrace? setupTrace;
    var cancelCalls = 0;
    runZonedGuarded(() async {
      var current = true;
      final listening = Completer<void>();
      final body = StreamController<List<int>>(
          sync: true,
          onListen: () => listening.complete(),
          onCancel: () {
            cancelCalls++;
            throw StateError('Synthetic response cancellation failure');
          });
      try {
        final raw = _ProbeClient((request) async {
          request.finalize();
          return http.StreamedResponse(body.stream, 200);
        });
        final response = await ScopeBindingClient(raw, isCurrent: () => current)
            .send(http.Request(
                'GET', Uri.parse('https://business.example/private')));
        final result = response.stream.toList();
        await listening.future.timeout(const Duration(milliseconds: 500));
        current = false;
        body.add([31]);
        try {
          await result.timeout(const Duration(milliseconds: 500));
        } catch (error) {
          observedFailure = error;
        }
        // Allow cleanup Future errors to reach this explicit error zone.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        if (raw.closed) {
          throw StateError('Response cleanup closed the borrowed client.');
        }
      } catch (error, trace) {
        setupFailure = error;
        setupTrace = trace;
      } finally {
        try {
          await body.close().timeout(const Duration(milliseconds: 500));
        } on TimeoutException {
          // The source is closed; do not let a failed cancellation hang RED.
        } catch (error) {
          unhandled.add(error);
        }
        await Future<void>.delayed(Duration.zero);
        if (setupFailure != null) {
          finished.completeError(setupFailure!, setupTrace);
        } else {
          finished.complete();
        }
      }
    }, (Object error, StackTrace _) => unhandled.add(error));
    await finished.future.timeout(const Duration(seconds: 2));
    expect(observedFailure, isA<ScopeChangedException>(),
        reason: 'Cleanup failure must not replace the original scope error.');
    expect(cancelCalls, 1);
    expect(unhandled, isEmpty,
        reason: 'Source cancellation failure must be handled by the adapter.');
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('current pause and resume preserve every response byte in order',
      () async {
    final listening = Completer<void>();
    final body = StreamController<List<int>>(
        sync: true, onListen: () => listening.complete());
    final raw = _ProbeClient((request) async {
      request.finalize();
      return http.StreamedResponse(body.stream, 200);
    });
    final response = await ScopeBindingClient(raw, isCurrent: () => true).send(
        http.Request('GET', Uri.parse('https://business.example/private')));
    final received = <int>[], errors = <Object>[];
    final done = Completer<void>();
    final subscription = response.stream.listen(received.addAll,
        onError: (Object error, StackTrace _) => errors.add(error),
        onDone: done.complete);
    try {
      await listening.future.timeout(const Duration(milliseconds: 500));
      body.add([1, 2]);
      await Future<void>.delayed(Duration.zero);
      expect(received, [1, 2]);
      subscription.pause();
      body.add([3, 4]);
      await Future<void>.delayed(Duration.zero);
      expect(received, [1, 2],
          reason: 'A paused consumer must not receive the buffered bytes.');
      subscription.resume();
      body.add([5, 6]);
      unawaited(body.close());
      await done.future.timeout(const Duration(milliseconds: 500));
      expect(received, [1, 2, 3, 4, 5, 6]);
      expect(errors, isEmpty);
      expect(raw.closed, isFalse);
    } finally {
      subscription.resume();
      await _closeResponseFixture(body, subscription);
    }
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('a queued source error becomes one scope error at actual delivery',
      () async {
    var current = true;
    final listening = Completer<void>();
    final body = StreamController<List<int>>(
        sync: true, onListen: () => listening.complete());
    final raw = _ProbeClient((request) async {
      request.finalize();
      return http.StreamedResponse(body.stream, 200);
    });
    final response = await ScopeBindingClient(raw, isCurrent: () => current)
        .send(
            http.Request('GET', Uri.parse('https://business.example/private')));
    final bytes = <int>[], errors = <Object>[];
    final done = Completer<void>();
    final subscription = response.stream.listen(bytes.addAll,
        onError: (Object error, StackTrace _) => errors.add(error),
        onDone: done.complete);
    try {
      await listening.future.timeout(const Duration(milliseconds: 500));
      final privateError = StateError('Old private source failure');
      // The source emits only after listen returned. Its error waits in the
      // response adapter while the originating scope changes in this same turn.
      body.addError(privateError, StackTrace.current);
      current = false;
      await done.future.timeout(const Duration(milliseconds: 500));
      expect(bytes, isEmpty);
      expect(errors, hasLength(1));
      expect(errors.single, isA<ScopeChangedException>(),
          reason: 'An invalid scope must conceal the original queued error.');
      expect(errors.any((error) => identical(error, privateError)), isFalse);
      expect(raw.closed, isFalse);
    } finally {
      await _closeResponseFixture(body, subscription);
    }
  }, timeout: const Timeout(Duration(seconds: 5)));

  test('queued chunk and source error produce one scope failure without bytes',
      () async {
    var current = true;
    final listening = Completer<void>();
    final body = StreamController<List<int>>(
        sync: true, onListen: () => listening.complete());
    final raw = _ProbeClient((request) async {
      request.finalize();
      return http.StreamedResponse(body.stream, 200);
    });
    final response = await ScopeBindingClient(raw, isCurrent: () => current)
        .send(
            http.Request('GET', Uri.parse('https://business.example/private')));
    final bytesAfterLoss = <int>[], errors = <Object>[];
    final done = Completer<void>();
    final subscription = response.stream.listen((chunk) {
      if (!current) bytesAfterLoss.addAll(chunk);
    },
        onError: (Object error, StackTrace _) => errors.add(error),
        onDone: done.complete);
    try {
      await listening.future.timeout(const Duration(milliseconds: 500));
      final privateError = StateError('Old private error after queued bytes');
      body.add([41, 42]);
      body.addError(privateError, StackTrace.current);
      current = false;
      await done.future.timeout(const Duration(milliseconds: 500));
      expect(bytesAfterLoss, isEmpty);
      expect(errors, hasLength(1),
          reason: 'A queued source error must not append a second failure.');
      expect(errors.single, isA<ScopeChangedException>());
      expect(errors.any((error) => identical(error, privateError)), isFalse);
      expect(raw.closed, isFalse);
    } finally {
      await _closeResponseFixture(body, subscription);
    }
  }, timeout: const Timeout(Duration(seconds: 5)));
}

Future<void> _closeResponseFixture(StreamController<List<int>> source,
    StreamSubscription<List<int>> subscription) async {
  try {
    await Future.wait([source.close(), subscription.cancel()])
        .timeout(const Duration(seconds: 1));
  } on TimeoutException {
    // Both cleanup operations have been requested. The actionable assertion
    // remains bounded even if the implementation under test cannot finish.
  }
}
