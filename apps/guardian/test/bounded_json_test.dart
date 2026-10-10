import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/bounded_json.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class StreamClient extends http.BaseClient {
  final http.StreamedResponse response;
  bool closed = false;
  StreamClient(this.response);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response;
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
        throwsA(isA<ApiFailure>()));
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
        throwsA(isA<ApiFailure>()));
    expect(client.closed, false);
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
