import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/bounded_json.dart';
import 'package:http/http.dart' as http;

import 'bounded_json_test.dart' show StreamClient;

Future<ApiFailure> _failure(Future<dynamic> operation) async {
  try {
    await operation;
  } on ApiFailure catch (failure) {
    return failure;
  }
  throw StateError('Expected an API failure');
}

void main() {
  test(
      'complete JSON HTTP denial emits evidence for the exact failure instance',
      () async {
    final bytes = utf8.encode(jsonEncode({'errorCode': 'REAUTH_REQUIRED'}));
    final client = StreamClient(http.StreamedResponse(Stream.value(bytes), 401,
        contentLength: bytes.length,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    final evidence = <BoundedHttpErrorEvidence>[];
    final failure = await _failure(boundedJson(
        Api(() async => client), 'POST', '/fixture',
        ensureCurrent: () {}, onHttpError: evidence.add));
    expect(evidence, hasLength(1));
    expect(identical(evidence.single.failure, failure), isTrue);
    expect(failure.status, 401);
    expect(failure.code, 'REAUTH_REQUIRED');
    expect(client.sends, 1);
    expect(client.closed, isFalse);
  });

  for (final kind in [
    'content-type',
    'length',
    'invalid-json',
    'trailing-code',
    'no-code',
    'too-large'
  ]) {
    test('$kind denial cannot establish a complete HTTP rejection', () async {
      final body = switch (kind) {
        'invalid-json' => '{',
        'trailing-code' => jsonEncode({'errorCode': 'REAUTH_REQUIRED\n'}),
        'no-code' => jsonEncode({'errorCode': 123}),
        'too-large' => ' ' * 65537,
        _ => jsonEncode({'errorCode': 'REAUTH_REQUIRED'}),
      };
      final bytes = utf8.encode(body);
      final client = StreamClient(http.StreamedResponse(
          Stream.value(bytes), 401,
          contentLength: kind == 'length' ? bytes.length + 1 : bytes.length,
          headers: {
            'content-type':
                kind == 'content-type' ? 'text/plain' : 'application/json'
          }));
      final evidence = <BoundedHttpErrorEvidence>[];
      final failure = await _failure(boundedJson(
          Api(() async => client), 'POST', '/fixture',
          ensureCurrent: () {}, onHttpError: evidence.add));
      expect(failure.status, 401);
      expect(evidence, isEmpty);
      expect(client.closed, isFalse);
    });
  }

  test('an authenticated-client exception is not HTTP response evidence',
      () async {
    final evidence = <BoundedHttpErrorEvidence>[];
    final failure = await _failure(boundedJson(Api(() async {
      throw const ApiFailure(401, 'REAUTH_REQUIRED');
    }), 'POST', '/fixture', ensureCurrent: () {}, onHttpError: evidence.add));
    expect(failure.code, 'REAUTH_REQUIRED');
    expect(evidence, isEmpty);
  });

  test('an interrupted denial stream does not emit rejection evidence',
      () async {
    var cancelled = false;
    late final StreamController<List<int>> body;
    body = StreamController<List<int>>(
        onListen: () {
          body.add(utf8.encode('{'));
          body.addError(http.ClientException('synthetic interrupted response'));
        },
        onCancel: () => cancelled = true);
    addTearDown(body.close);
    final client = StreamClient(http.StreamedResponse(body.stream, 401,
        headers: {'content-type': 'application/json'}));
    final evidence = <BoundedHttpErrorEvidence>[];
    final failure = await _failure(boundedJson(
        Api(() async => client), 'POST', '/fixture',
        ensureCurrent: () {}, onHttpError: evidence.add));
    await Future<void>.delayed(Duration.zero);
    expect(failure.status, 401);
    expect(evidence, isEmpty);
    expect(cancelled, isTrue);
    expect(client.closed, isFalse);
  });

  test('scope loss suppresses both the body and HTTP evidence', () async {
    var current = true;
    final bytes = utf8.encode(jsonEncode({'errorCode': 'REAUTH_REQUIRED'}));
    late final StreamController<List<int>> body;
    body = StreamController<List<int>>(onListen: () {
      current = false;
      body.add(bytes);
      body.close();
    });
    final client = StreamClient(http.StreamedResponse(body.stream, 401,
        headers: {'content-type': 'application/json'}));
    final evidence = <BoundedHttpErrorEvidence>[];
    final failure = await _failure(boundedJson(
        Api(() async => client), 'POST', '/fixture', ensureCurrent: () {
      if (!current) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }, onHttpError: evidence.add));
    expect(failure.code, 'WORKSPACE_CHANGED');
    expect(evidence, isEmpty);
  });

  test('an accepted response never supplies HTTP rejection evidence', () async {
    final bytes = utf8.encode('{}');
    final client = StreamClient(http.StreamedResponse(Stream.value(bytes), 201,
        contentLength: bytes.length,
        headers: {'content-type': 'application/json'}));
    final evidence = <BoundedHttpErrorEvidence>[];
    expect(
        await boundedJson(Api(() async => client), 'POST', '/fixture',
            successStatus: 201,
            ensureCurrent: () {},
            onHttpError: evidence.add),
        isEmpty);
    expect(evidence, isEmpty);
    expect(client.closed, isFalse);
  });

  test('complete ProblemDetail denial emits the exact failure evidence',
      () async {
    for (final contentType in [
      'application/problem+json',
      'Application/Problem+Json; Charset=UTF-8',
    ]) {
      final bytes = utf8.encode(jsonEncode({
        'type': 'about:blank',
        'title': 'Unauthorized',
        'status': 401,
        'detail': 'Recent authentication is required.',
        'instance': '/api/policies/policy-a/publications',
        'errorCode': 'REAUTH_REQUIRED',
        'messageKey': 'error.reauth_required',
        'correlationId': 'synthetic-correlation',
      }));
      final client = StreamClient(http.StreamedResponse(
          Stream.value(bytes), 401,
          contentLength: bytes.length, headers: {'content-type': contentType}));
      final evidence = <BoundedHttpErrorEvidence>[];
      final failure = await _failure(boundedJson(
          Api(() async => client), 'POST', '/fixture',
          ensureCurrent: () {}, onHttpError: evidence.add));
      expect(evidence, hasLength(1), reason: contentType);
      expect(identical(evidence.single.failure, failure), isTrue);
      expect(failure.status, 401);
      expect(failure.code, 'REAUTH_REQUIRED');
      expect(client.sends, 1);
      expect(client.closed, isFalse);
    }
  });

  test(
      'vendor and other +json denials cannot establish HTTP rejection evidence',
      () async {
    for (final contentType in [
      'application/vnd.aimanager+json',
      'application/vnd.problem+json; charset=utf-8',
      'text/problem+json',
      'application/problem+json-suffix',
    ]) {
      final bytes = utf8.encode(jsonEncode({
        'type': 'about:blank',
        'title': 'Unauthorized',
        'status': 401,
        'errorCode': 'REAUTH_REQUIRED',
      }));
      final client = StreamClient(http.StreamedResponse(
          Stream.value(bytes), 401,
          contentLength: bytes.length, headers: {'content-type': contentType}));
      final evidence = <BoundedHttpErrorEvidence>[];
      final failure = await _failure(boundedJson(
          Api(() async => client), 'POST', '/fixture',
          ensureCurrent: () {}, onHttpError: evidence.add));
      expect(failure.status, 401);
      expect(failure.code, 'REAUTH_REQUIRED');
      expect(evidence, isEmpty, reason: contentType);
      expect(client.sends, 1);
      expect(client.closed, isFalse);
    }
  });
}
