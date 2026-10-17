import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/bounded_json.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class StreamClient extends http.BaseClient {
  final http.StreamedResponse response;
  bool closed = false;
  int sends = 0;
  StreamClient(this.response);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    return response;
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  test(
      'oversized headers cancel only the response and absorb cancellation failure',
      () async {
    bool cancelled = false;
    final stream = StreamController<List<int>>(onCancel: () async {
      cancelled = true;
      throw StateError('transport cancellation failure');
    });
    final client = StreamClient(http.StreamedResponse(stream.stream, 200,
        contentLength: 100, headers: {'content-type': 'application/json'}));
    await expectLater(
        boundedJson(Api(() async => client), 'GET', '/fixture',
            ensureCurrent: () {}, maxBytes: 10),
        throwsA(isA<ApiFailure>()
            .having((failure) => failure.status, 'status', 502)
            .having((failure) => failure.code, 'code',
                'INVALID_REPORT_JOB_RESPONSE')));
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, true);
    expect(client.closed, false);
  });
  test('streamed bytes are bounded when content length is absent', () async {
    final client = StreamClient(http.StreamedResponse(
        Stream.value(List.filled(11, 32)), 200,
        headers: {'content-type': 'application/json'}));
    await expectLater(
        boundedJson(Api(() async => client), 'GET', '/fixture',
            ensureCurrent: () {}, maxBytes: 10),
        throwsA(isA<ApiFailure>()
            .having((failure) => failure.status, 'status', 502)
            .having((failure) => failure.code, 'code',
                'INVALID_REPORT_JOB_RESPONSE')));
    expect(client.closed, false);
  });
  for (final status in [401, 403]) {
    test(
        'HTTP $status oversized content length preserves authorization failure',
        () async {
      var cancelled = false;
      final stream = StreamController<List<int>>(onCancel: () {
        cancelled = true;
      });
      addTearDown(stream.close);
      final client = StreamClient(http.StreamedResponse(stream.stream, status,
          contentLength: 65537, headers: {'content-type': 'application/json'}));

      await expectLater(
          boundedJson(Api(() async => client), 'GET', '/fixture',
              ensureCurrent: () {}),
          throwsA(isA<ApiFailure>()
              .having((failure) => failure.status, 'status', status)
              .having((failure) => failure.code, 'code', 'REQUEST_FAILED')));
      await Future<void>.delayed(Duration.zero);

      expect(cancelled, isTrue,
          reason: 'An oversized error body must not remain subscribed.');
      expect(client.closed, isFalse,
          reason: 'The session still owns the authenticated client.');
      expect(client.sends, 1, reason: 'A hard denial must never retry itself.');
    });

    test('HTTP $status chunked body over limit preserves authorization failure',
        () async {
      var cancelled = false;
      late final StreamController<List<int>> stream;
      stream = StreamController<List<int>>(onListen: () {
        stream.add(List.filled(32768, 32));
        stream.add(List.filled(32769, 32));
      }, onCancel: () {
        cancelled = true;
      });
      addTearDown(stream.close);
      final client = StreamClient(http.StreamedResponse(stream.stream, status,
          headers: {'content-type': 'application/json'}));

      await expectLater(
          boundedJson(Api(() async => client), 'GET', '/fixture',
              ensureCurrent: () {}),
          throwsA(isA<ApiFailure>()
              .having((failure) => failure.status, 'status', status)
              .having((failure) => failure.code, 'code', 'REQUEST_FAILED')));
      await Future<void>.delayed(Duration.zero);

      expect(cancelled, isTrue,
          reason: 'The reader must cancel before the open error stream ends.');
      expect(client.closed, isFalse,
          reason: 'The session still owns the authenticated client.');
      expect(client.sends, 1, reason: 'A hard denial must never retry itself.');
    });
  }
  test('bounded HTTP 401 preserves explicit recent authentication recovery',
      () async {
    final payload = '{"errorCode":"REAUTH_REQUIRED"}'.codeUnits;
    final client = StreamClient(http.StreamedResponse(
        Stream.value(payload), 401,
        contentLength: payload.length,
        headers: {'content-type': 'application/json'}));

    await expectLater(
        boundedJson(Api(() async => client), 'POST', '/fixture',
            ensureCurrent: () {}),
        throwsA(isA<ApiFailure>()
            .having((failure) => failure.status, 'status', 401)
            .having((failure) => failure.code, 'code', 'REAUTH_REQUIRED')));

    expect(client.closed, isFalse);
    expect(client.sends, 1);
  });
  test('result length and content type must match the metadata contract',
      () async {
    for (final response in [
      http.Response('{}', 200, headers: {'content-type': 'text/html'}),
      http.Response('{}', 200, headers: {'content-type': 'application/json'})
    ]) {
      await expectLater(
          boundedJson(Api(() async => MockClient((r) async => response)), 'GET',
              '/fixture',
              ensureCurrent: () {}, expectedBytes: 9),
          throwsA(isA<ApiFailure>()));
    }
  });
}
