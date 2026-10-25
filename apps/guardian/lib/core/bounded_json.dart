import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'api.dart';
import 'scoped_http_client.dart';

/// A complete rejected HTTP response, tied to the actual thrown failure.
/// Only the bounded reader can construct this evidence.
final class BoundedHttpErrorEvidence {
  final ApiFailure failure;
  final int? problemStatus;
  const BoundedHttpErrorEvidence._(this.failure, this.problemStatus);
}

/// A bounded response reader for private task metadata and report results.
/// The authenticated client belongs to Session; only this response is cancelled.
Future<dynamic> boundedJson(Api api, String method, String path,
    {Json? body,
    String? key,
    int? version,
    required void Function() ensureCurrent,
    int successStatus = 200,
    Set<int> additionalSuccessStatuses = const {},
    void Function(BoundedHttpErrorEvidence)? onHttpError,
    int maxBytes = 2 * 1024 * 1024,
    int? expectedBytes}) async {
  StreamSubscription<List<int>>? subscription;
  bool ended = false, aborted = false;
  final abort = Completer<void>();
  void abortRequest() {
    if (!abort.isCompleted) abort.complete();
  }

  int? failedResponseStatus;
  ensureCurrent();
  try {
    return await (() async {
      final request =
          ScopeGuardedRequest(method, Uri.parse('${api.baseUrl}$path'),
              isCurrent: () {
                ensureCurrent();
                return true;
              },
              abortTrigger: abort.future,
              isAborted: () => aborted)
            ..followRedirects = false
            ..headers['Accept'] = 'application/json';
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      if (key != null) request.headers['Idempotency-Key'] = key;
      if (version != null) request.headers['If-Match'] = '"$version"';
      final client = await api.client();
      ensureCurrent();
      if (aborted) throw const ApiFailure(0, 'NETWORK_ERROR');
      final response = await client.send(request);
      if (aborted) {
        _discardResponse(response);
        throw const ApiFailure(0, 'NETWORK_ERROR');
      }
      try {
        ensureCurrent();
      } catch (_) {
        _discardResponse(response);
        rethrow;
      }
      final accepted = response.statusCode == successStatus ||
          additionalSuccessStatuses.contains(response.statusCode);
      if (!accepted) failedResponseStatus = response.statusCode;
      final limit = accepted ? maxBytes : 65536;
      if (response.contentLength != null && response.contentLength! > limit) {
        _discardResponse(response);
        throw accepted
            ? const ApiFailure(502, 'INVALID_REPORT_JOB_RESPONSE')
            : ApiFailure(response.statusCode, 'REQUEST_FAILED');
      }
      final received = Completer<Uint8List>(),
          bytes = BytesBuilder(copy: false);
      subscription = response.stream.listen((chunk) {
        if (received.isCompleted) return;
        if (bytes.length + chunk.length > limit) {
          received.completeError(accepted
              ? const ApiFailure(502, 'INVALID_REPORT_JOB_RESPONSE')
              : ApiFailure(response.statusCode, 'REQUEST_FAILED'));
          return;
        }
        bytes.add(chunk);
      }, onError: (Object error, StackTrace trace) {
        ended = true;
        if (!received.isCompleted) {
          try {
            ensureCurrent();
          } catch (scopeFailure, scopeTrace) {
            received.completeError(scopeFailure, scopeTrace);
            return;
          }
          received.completeError(
              accepted || error is ScopeChangedException
                  ? error
                  : ApiFailure(response.statusCode, 'REQUEST_FAILED'),
              trace);
        }
      }, onDone: () {
        ended = true;
        if (!received.isCompleted) received.complete(bytes.takeBytes());
      }, cancelOnError: true);
      final payload = await received.future;
      ensureCurrent();
      dynamic result;
      try {
        result = jsonDecode(utf8.decode(payload));
      } on FormatException {
        result = null;
      }
      if (!accepted) {
        final candidate = result is Json ? result['errorCode'] : null;
        final codeMatch = candidate is String
            ? RegExp(r'^[A-Z][A-Z0-9_]{0,99}$').firstMatch(candidate)
            : null;
        final validCode = candidate is String &&
            codeMatch != null &&
            codeMatch.end == candidate.length;
        final failure = ApiFailure(
            response.statusCode, validCode ? candidate : 'REQUEST_FAILED');
        if (onHttpError != null &&
            response.statusCode >= 400 &&
            response.statusCode < 600 &&
            validCode &&
            const {'application/json', 'application/problem+json'}.contains(
                response.headers['content-type']
                    ?.split(';')
                    .first
                    .trim()
                    .toLowerCase()) &&
            (response.contentLength == null ||
                response.contentLength == payload.length)) {
          ensureCurrent();
          onHttpError(BoundedHttpErrorEvidence._(
              failure,
              result is Json && result['status'] is int
                  ? result['status']
                  : null));
        }
        throw failure;
      }
      if (response.headers['content-type']
                  ?.split(';')
                  .first
                  .trim()
                  .toLowerCase() !=
              'application/json' ||
          (response.contentLength != null &&
              response.contentLength != payload.length) ||
          (expectedBytes != null && expectedBytes != payload.length)) {
        throw const ApiFailure(502, 'INVALID_REPORT_JOB_RESPONSE');
      }
      return result;
    })()
        .timeout(const Duration(seconds: 25), onTimeout: () {
      aborted = true;
      abortRequest();
      throw TimeoutException('Response deadline elapsed');
    });
  } on TimeoutException {
    ensureCurrent();
    throw failedResponseStatus == null
        ? const ApiFailure(0, 'NETWORK_ERROR')
        : ApiFailure(failedResponseStatus!, 'REQUEST_FAILED');
  } on http.ClientException {
    ensureCurrent();
    throw failedResponseStatus == null
        ? const ApiFailure(0, 'NETWORK_ERROR')
        : ApiFailure(failedResponseStatus!, 'REQUEST_FAILED');
  } finally {
    aborted = true;
    if (!ended) abortRequest();
    if (!ended && subscription != null) {
      unawaited(subscription!.cancel().catchError((Object _) {}));
    }
  }
}

void _discardResponse(http.StreamedResponse response) {
  unawaited(Future<void>.sync(() async {
    try {
      await response.stream
          .listen(null, onError: (Object _, StackTrace __) {})
          .cancel();
    } catch (_) {
      // Cleanup must preserve the original deadline, scope or protocol error.
    }
  }));
}
