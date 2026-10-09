import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'page.dart';
import 'journal.dart';
import 'models.dart';

/// No server copy, credentials, response bodies or transport causes.
class DeviceTransportFailure implements Exception {
  final String code;
  final int? status;
  final String? correlationId;
  final Duration? retryAfter;
  final bool retryable, outcomeUnknown;
  const DeviceTransportFailure(this.code,
      {this.status,
      this.correlationId,
      this.retryAfter,
      this.retryable = false,
      this.outcomeUnknown = false});
  @override
  String toString() => 'DeviceTransportFailure($code)';
}

/// Fresh credentials per request; no transparent retry. Injected clients stay
/// owned by the caller. Closing aborts this transport's active requests.
class DeviceConfigurationTransport {
  final Uri apiRoot;
  final Future<String?> Function() credential;
  final Duration timeout;
  final int maxResponseBytes;
  final DateTime Function() retryClock;
  final http.Client _client;
  final bool _ownsClient;
  final Set<Completer<void>> _active = {};
  bool _closed = false;
  DeviceConfigurationTransport(
      {required Uri apiRoot,
      required this.credential,
      this.timeout = const Duration(seconds: 20),
      this.maxResponseBytes = 8388608,
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
      {Map<String, String>? query, Map<String, dynamic>? body}) async {
    if (_closed) {
      throw const DeviceTransportFailure('CLIENT_CLOSED');
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
        throw const DeviceTransportFailure('CREDENTIAL_READ_FAILED');
      }
      if (expired) {
        throw const DeviceTransportFailure('NETWORK_TIMEOUT', retryable: true);
      }
      if (_closed) {
        throw const DeviceTransportFailure('CLIENT_CLOSED');
      }
      if (token == null || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
        throw const DeviceTransportFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
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
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      sent = true;
      final response = await _client.send(request);
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw DeviceTransportFailure('REDIRECT_REFUSED',
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
        throw DeviceTransportFailure('CLIENT_CLOSED',
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
        throw DeviceTransportFailure(code,
            status: status,
            correlationId: validId(correlation) ? correlation : null,
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
      return await execute().timeout(timeout, onTimeout: () {
        expired = true;
        cancel();
        throw DeviceTransportFailure('NETWORK_TIMEOUT',
            retryable: true, outcomeUnknown: mutation && sent);
      });
    } on DeviceTransportFailure {
      rethrow;
    } on FormatException {
      throw DeviceTransportFailure('RESPONSE_INVALID',
          outcomeUnknown: mutation && sent);
    } catch (_) {
      if (_closed) {
        throw DeviceTransportFailure('CLIENT_CLOSED',
            outcomeUnknown: mutation && sent);
      }
      throw DeviceTransportFailure(
          expired ? 'NETWORK_TIMEOUT' : 'CONNECTION_FAILED',
          retryable: true,
          outcomeUnknown: mutation && sent);
    } finally {
      cancel();
      _active.remove(abort);
    }
  }

  Future<ConfigurationPage> pull({required int after, int limit = 10}) {
    if (after < 0 || after > maxSafeInteger || limit < 1 || limit > 50) {
      throw ArgumentError('Invalid paging input');
    }
    return _request('GET', 'configurations',
        (json) => ConfigurationPage.fromJson(json, after: after, limit: limit),
        query: {'after': '$after', 'limit': '$limit'});
  }

  Future<ReceiptAcknowledgement> acknowledge(
          StoredConfigurationReceipt receipt) =>
      _request(
          'POST',
          'configuration-receipts',
          (json) => ReceiptAcknowledgement.fromJson(json,
              receiptId: receipt.receiptId),
          body: receipt.toJson());

  /// Retrieval alone does not install a trust ring. Hosts own explicit rotation.
  Future<Map<String, dynamic>> signingKeys() =>
      _request('GET', 'signing-keys', (json) {
        final keys = json['keys'];
        if (keys is! List ||
            keys.isEmpty ||
            keys.length > 32 ||
            keys.any((k) => k is! Map<String, dynamic> || k.containsKey('d'))) {
          throw const FormatException('Invalid public key response');
        }
        return freezeJson(json);
      });
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
  'DELIVERY_CURSOR_AHEAD',
  'INVALID_DELIVERY_PAGE',
  'RECEIPT_ID_CONFLICT',
  'RECEIPT_PHASE_CONFLICT',
  'DELIVERY_REJECTED_REPUBLISH_REQUIRED',
  'INPUT_INVALID',
  'RATE_LIMITED',
  'SERVER_ERROR'
};
