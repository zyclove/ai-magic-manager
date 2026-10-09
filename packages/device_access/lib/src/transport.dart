import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'page.dart';
import 'receipt.dart';
import 'models.dart';
import 'submission.dart';

/// No server copy, credentials, response bodies or transport causes.
class AccessTransportFailure implements Exception {
  final String code;
  final int? status;
  final String? correlationId;
  final Duration? retryAfter;
  final bool retryable, outcomeUnknown;
  const AccessTransportFailure(this.code,
      {this.status,
      this.correlationId,
      this.retryAfter,
      this.retryable = false,
      this.outcomeUnknown = false});
  @override
  String toString() => 'AccessTransportFailure($code)';
}

/// Fresh credentials per request; no transparent retry. Injected clients stay
/// owned by the caller. Closing aborts this transport's active requests.
class DeviceAccessTransport {
  final Uri apiRoot;
  final Future<String?> Function() credential;
  final Duration timeout;
  final int maxResponseBytes;
  final DateTime Function() retryClock;
  final http.Client _client;
  final bool _ownsClient;
  final Set<Completer<void>> _active = {};
  bool _closed = false;
  DeviceAccessTransport(
      {required Uri apiRoot,
      required this.credential,
      this.timeout = const Duration(seconds: 20),
      this.maxResponseBytes = 1048576,
      this.retryClock = DateTime.now,
      bool allowLoopbackHttp = false,
      http.Client? client})
      : apiRoot =
            apiRoot.replace(path: apiRoot.path.replaceFirst(RegExp(r'/$'), '')),
        _client = client ?? http.Client(),
        _ownsClient = client == null {
    final path = this.apiRoot.path;
    if (apiRoot.host.isEmpty ||
        apiRoot.userInfo.isNotEmpty ||
        apiRoot.hasQuery ||
        apiRoot.hasFragment ||
        !path.endsWith('/api/v1') ||
        apiRoot.pathSegments.any((p) => p == '..' || p == '.') ||
        timeout <= Duration.zero ||
        timeout > const Duration(minutes: 2) ||
        maxResponseBytes < 1024 ||
        maxResponseBytes > 67108864 ||
        !(apiRoot.scheme == 'https' ||
            (allowLoopbackHttp &&
                apiRoot.scheme == 'http' &&
                const {'localhost', '127.0.0.1', '::1'}
                    .contains(apiRoot.host)))) {
      if (_ownsClient) {
        _client.close();
      }
      throw ArgumentError(
          'Provide an explicit HTTPS API root and bounded request settings');
    }
  }
  Future<T> _request<T>(
      String method, String path, T Function(Map<String, dynamic>) parse,
      {Map<String, String>? query,
      Map<String, dynamic>? body,
      Map<String, String> headers = const {}}) async {
    if (_closed) {
      throw const AccessTransportFailure('CLIENT_CLOSED');
    }
    final abort = Completer<void>();
    _active.add(abort);
    bool expired = false, sent = false;
    final mutation = method != 'GET';
    void cancel() {
      if (!abort.isCompleted) {
        abort.complete();
      }
    }

    Future<T> execute() async {
      String? token;
      try {
        token = await credential();
      } catch (_) {
        throw const AccessTransportFailure('CREDENTIAL_READ_FAILED');
      }
      if (expired) {
        throw const AccessTransportFailure('NETWORK_TIMEOUT', retryable: true);
      }
      if (_closed) {
        throw const AccessTransportFailure('CLIENT_CLOSED');
      }
      if (token == null || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
        throw const AccessTransportFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
      }
      final request = http.AbortableRequest(
          method,
          apiRoot.replace(
              path: '${apiRoot.path}/device-api/$path', queryParameters: query),
          abortTrigger: abort.future)
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers['Authorization'] = 'Bearer $token'
        ..headers['Accept'] = 'application/json';
      request.headers.addAll(headers);
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      sent = true;
      final response = await _client.send(request);
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw AccessTransportFailure('REDIRECT_REFUSED',
            status: response.statusCode, outcomeUnknown: mutation);
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > maxResponseBytes) {
          throw const FormatException('Response exceeds limit');
        }
        bytes.addAll(chunk);
      }
      if (_closed) {
        throw AccessTransportFailure('CLIENT_CLOSED',
            outcomeUnknown: mutation && sent);
      }
      Map<String, dynamic>? value;
      try {
        final json = jsonDecode(utf8.decode(bytes));
        if (json is Map<String, dynamic>) {
          value = json;
        }
      } on FormatException {/* Error handling does not trust response copy. */}
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final status = response.statusCode;
        final raw = value?['errorCode'];
        final code = _safeCodes.contains(raw) ? raw as String : 'HTTP_FAILURE';
        final correlation = value?['correlationId'];
        throw AccessTransportFailure(code,
            status: status,
            correlationId: accessId(correlation) ? correlation : null,
            retryable: status == 429 || status >= 500,
            retryAfter: _retryAfter(response.headers['retry-after']),
            outcomeUnknown: mutation && status >= 500);
      }
      final contentType = response.headers['content-type']
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (value == null || contentType != 'application/json') {
        throw const FormatException('Invalid JSON response');
      }
      return parse(value);
    }

    try {
      return await Future.any<T>([
        execute(),
        abort.future.then<T>((_) => throw AccessTransportFailure(
            _closed ? 'CLIENT_CLOSED' : 'NETWORK_TIMEOUT',
            retryable: !_closed,
            outcomeUnknown: mutation && sent))
      ]).timeout(timeout, onTimeout: () {
        expired = true;
        cancel();
        throw AccessTransportFailure('NETWORK_TIMEOUT',
            retryable: true, outcomeUnknown: mutation && sent);
      });
    } on AccessTransportFailure {
      rethrow;
    } on AccessFailure {
      throw AccessTransportFailure('RESPONSE_INVALID',
          outcomeUnknown: mutation && sent);
    } on FormatException {
      throw AccessTransportFailure('RESPONSE_INVALID',
          outcomeUnknown: mutation && sent);
    } catch (_) {
      if (_closed) {
        throw AccessTransportFailure('CLIENT_CLOSED',
            outcomeUnknown: mutation && sent);
      }
      throw AccessTransportFailure(
          expired ? 'NETWORK_TIMEOUT' : 'CONNECTION_FAILED',
          retryable: true,
          outcomeUnknown: mutation && sent);
    } finally {
      cancel();
      _active.remove(abort);
    }
  }

  /// The authenticated device binding comes from the credential, never UI/JWS.
  Future<AccessDeviceContext> context() =>
      _request('GET', 'access-context', AccessDeviceContext.fromJson);

  Future<AccessReferencePage> list({String? cursor, int limit = 10}) {
    if ((cursor != null && !accessId(cursor)) || limit < 1 || limit > 100) {
      throw ArgumentError('Invalid access page input');
    }
    return _request(
        'GET',
        'access-requests',
        (json) =>
            AccessReferencePage.fromJson(json, after: cursor, limit: limit),
        query: {'limit': '$limit', if (cursor != null) 'cursor': cursor});
  }

  Future<AccessDocument> document(String requestId) {
    if (!accessId(requestId)) throw ArgumentError('Invalid access request ID');
    return _request('GET', 'access-requests/$requestId/document', (json) {
      final value = AccessDocument.fromJson(json);
      if (value.requestId != requestId) throw const FormatException();
      return value;
    });
  }

  Future<AccessReceiptAcknowledgement> acknowledge(AccessReceipt receipt) {
    if (!accessId(receipt.requestId) ||
        !accessId(receipt.documentId) ||
        !accessInteger(receipt.approvalVersion, 1) ||
        receipt.deliveryAttempt < 1 ||
        receipt.deliveryAttempt > 10 ||
        !{'STORED', 'REJECTED'}.contains(receipt.phase) ||
        (receipt.phase == 'REJECTED'
            ? !accessRejectionReasons.contains(receipt.reasonCode)
            : receipt.reasonCode != null)) {
      throw ArgumentError('Invalid access receipt');
    }
    return _request('POST', 'access-requests/${receipt.requestId}/receipts',
        (json) {
      final value = AccessReceiptAcknowledgement.fromJson(json);
      if (!value.matches(receipt)) throw const FormatException();
      return value;
    }, body: receipt.toJson());
  }

  Future<AccessRetryResult> retry(AccessDocument document) {
    if (document.deliveryAttempt >= 10 ||
        document.deliveryState != 'REJECTED' ||
        !{'BASELINE_MISSING', 'STORAGE_FAILED'}.contains(document.reasonCode)) {
      throw ArgumentError('Access document is not retryable');
    }
    return _request(
        'POST',
        'access-requests/${document.requestId}/delivery-retries',
        (json) => AccessRetryResult.fromJson(json,
            documentId: document.documentId,
            failedAttempt: document.deliveryAttempt),
        body: {
          'documentId': document.documentId,
          'failedAttempt': document.deliveryAttempt
        });
  }

  Future<AccessSubmissionOptionsPage> submissionOptions(
      {String? cursor, int limit = 20}) {
    _submissionPageInput(cursor, limit);
    return _request(
        'GET',
        'access-submissions/options',
        (json) => AccessSubmissionOptionsPage.fromJson(json,
            after: cursor, limit: limit),
        query: {'limit': '$limit', if (cursor != null) 'cursor': cursor});
  }

  Future<AccessSubmissionPage> submissions(
      {required AccessDeviceContext context, String? cursor, int limit = 20}) {
    _submissionPageInput(cursor, limit);
    return _request('GET', 'access-submissions', (json) {
      final page =
          AccessSubmissionPage.fromJson(json, after: cursor, limit: limit);
      for (final value in page.items) {
        value.requireContext(context);
      }
      return page;
    }, query: {'limit': '$limit', if (cursor != null) 'cursor': cursor});
  }

  Future<AccessSubmission> submission(String id,
      {required AccessDeviceContext context}) {
    if (!accessId(id)) throw ArgumentError('Invalid access submission ID');
    return _request('GET', 'access-submissions/$id', (json) {
      final value = AccessSubmission.fromJson(json);
      value.requireContext(context);
      if (value.id != id) throw const AccessFailure('TRANSPORT_MISMATCH');
      return value;
    });
  }

  /// No automatic retry: retain the original input/key whenever outcomeUnknown is true.
  Future<AccessSubmission> createSubmission(AccessSubmissionInput input,
      {required AccessDeviceContext context, required String idempotencyKey}) {
    _submissionKey(idempotencyKey);
    return _request('POST', 'access-submissions', (json) {
      final value = AccessSubmission.fromJson(json);
      value.requireContext(context);
      if (!input.matches(value)) {
        throw const AccessFailure('TRANSPORT_MISMATCH');
      }
      return value;
    }, body: input.toJson(), headers: {'Idempotency-Key': idempotencyKey});
  }

  Future<AccessSubmission> cancelSubmission(String id,
      {required AccessDeviceContext context,
      required int version,
      required String idempotencyKey}) {
    if (!accessId(id) || !accessInteger(version, 0)) {
      throw ArgumentError('Invalid access submission revision');
    }
    _submissionKey(idempotencyKey);
    return _request('POST', 'access-submissions/$id/cancel', (json) {
      final value = AccessSubmission.fromJson(json);
      value.requireContext(context);
      if (value.id != id) throw const AccessFailure('TRANSPORT_MISMATCH');
      return value;
    }, headers: {'Idempotency-Key': idempotencyKey, 'If-Match': '"$version"'});
  }

  void _submissionPageInput(String? cursor, int limit) {
    if (limit < 1 || limit > 100 || cursor != null && !accessId(cursor)) {
      throw ArgumentError('Invalid access submission page input');
    }
  }

  void _submissionKey(String key) {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(key)) {
      throw ArgumentError('Invalid idempotency key');
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final request in _active) {
      if (!request.isCompleted) {
        request.complete();
      }
    }
    if (_ownsClient) {
      _client.close();
    }
  }

  Duration? _retryAfter(String? value) {
    if (value == null || value.length > 128) {
      return null;
    }
    int? seconds = int.tryParse(value);
    if (seconds == null) {
      try {
        seconds =
            parseHttpDate(value).difference(retryClock().toUtc()).inSeconds;
      } on FormatException {
        return null;
      }
    }
    if (seconds < 0) {
      return Duration.zero;
    }
    return Duration(seconds: seconds > 3600 ? 3600 : seconds);
  }
}

const _safeCodes = {
  'DEVICE_UNAUTHENTICATED',
  'SCOPE_DENIED',
  'SIGNING_KEY_NOT_CONFIGURED',
  'SIGNING_TEMPORARILY_UNAVAILABLE',
  'ACCESS_DOCUMENT_SUPERSEDED',
  'ACCESS_DOCUMENT_NOT_GRANTED',
  'ACCESS_RETRY_TOO_EARLY',
  'ACCESS_RETRY_LIMIT',
  'ACCESS_RETRY_NOT_ALLOWED',
  'ACCESS_RECEIPT_CONFLICT',
  'ACCESS_TARGET_CHANGED',
  'INVALID_ACCESS_RECEIPT',
  'INVALID_DELIVERY_PAGE',
  'RECEIPT_ID_CONFLICT',
  'RECEIPT_PHASE_CONFLICT',
  'DELIVERY_REJECTED_REPUBLISH_REQUIRED',
  'INPUT_INVALID',
  'RATE_LIMITED',
  'SERVER_ERROR',
  'DEVICE_CREDENTIAL_REVOKED',
  'DEVICE_CREDENTIAL_UNAVAILABLE',
  'ACCESS_REQUEST_PENDING',
  'ACCESS_EXCEPTION_EXISTS',
  'ACCESS_REQUEST_COOLDOWN',
  'ACCESS_REQUEST_NOT_PENDING',
  'BASELINE_CHANGED',
  'EXCEPTION_RULE_INVALID',
  'EXCEPTION_KIND_UNSUPPORTED',
  'SAFETY_BASELINE_PROTECTED',
  'IDEMPOTENCY_KEY_REQUIRED',
  'IDEMPOTENCY_KEY_CONFLICT',
  'IDEMPOTENCY_KEY_EXPIRED',
  'REQUEST_IN_PROGRESS',
  'VERSION_REQUIRED',
  'RESOURCE_VERSION_CONFLICT',
  'VALIDATION_FAILED',
  'MALFORMED_REQUEST',
  'INVALID_PAGE_SIZE',
  'INVALID_CURSOR'
};
