import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';

enum IdentityOperation {
  claim('enrollment-claims', 201, false),
  recover('enrollment-claims/recover', 200, false),
  heartbeat('device-api/heartbeats', 200, true),
  rotate('device-api/credentials/rotate', 200, true),
  activate('device-api/credentials/activate', 204, true),
  cancel('device-api/credentials/rotation/cancel', 204, true);

  final String path;
  final int successStatus;
  final bool authenticated;
  const IdentityOperation(this.path, this.successStatus, this.authenticated);
}

/// Protocol adapter over package:http. No retry, redirect, cookie-based identity
/// or server-provided URL. Secrets are never included in transport diagnostics.
class DeviceIdentityApi {
  final Uri apiRoot;
  final Duration timeout;
  final int maxResponseBytes;
  final http.Client _client;
  final bool _ownsClient;
  final Set<Completer<void>> _active = {};
  bool _closed = false;
  DeviceIdentityApi(
      {required Uri apiRoot,
      bool allowLoopbackHttp = false,
      this.timeout = const Duration(seconds: 20),
      this.maxResponseBytes = 65536,
      http.Client? client})
      : apiRoot =
            apiRoot.replace(path: apiRoot.path.replaceFirst(RegExp(r'/$'), '')),
        _client = client ?? http.Client(),
        _ownsClient = client == null {
    if (apiRoot.host.isEmpty ||
        apiRoot.userInfo.isNotEmpty ||
        apiRoot.hasQuery ||
        apiRoot.hasFragment ||
        !this.apiRoot.path.endsWith('/api/v1') ||
        apiRoot.pathSegments.any((p) => p == '.' || p == '..') ||
        timeout <= Duration.zero ||
        timeout > const Duration(minutes: 2) ||
        maxResponseBytes < 1024 ||
        maxResponseBytes > 1048576 ||
        !(apiRoot.scheme == 'https' ||
            allowLoopbackHttp &&
                apiRoot.scheme == 'http' &&
                const {'localhost', '127.0.0.1', '::1'}
                    .contains(apiRoot.host))) {
      if (_ownsClient) _client.close();
      throw ArgumentError(
          'Provide a confirmed HTTPS API root and bounded settings');
    }
  }

  Future<Map<String, dynamic>> send(IdentityOperation operation,
      {Map<String, dynamic> body = const {}, String? credential}) async {
    if (_closed) throw const DeviceIdentityFailure('CLIENT_CLOSED');
    if (operation.authenticated && !validSecret(credential) ||
        !operation.authenticated && credential != null) {
      throw const DeviceIdentityFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
    }
    final abort = Completer<void>();
    _active.add(abort);
    bool sent = false;
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    Future<Map<String, dynamic>> execute() async {
      final request = http.AbortableRequest(
          'POST', apiRoot.replace(path: '${apiRoot.path}/${operation.path}'),
          abortTrigger: abort.future)
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers['Accept'] = 'application/json'
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body);
      if (credential != null) {
        request.headers['Authorization'] = 'Bearer $credential';
      }
      sent = true;
      final response = await _client.send(request);
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw DeviceIdentityFailure('REDIRECT_REFUSED',
            status: response.statusCode, outcomeUnknown: true);
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > maxResponseBytes) {
          throw const FormatException('Response limit');
        }
        bytes.addAll(chunk);
      }
      if (_closed) {
        throw const DeviceIdentityFailure('CLIENT_CLOSED',
            outcomeUnknown: true);
      }
      Map<String, dynamic>? value;
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map<String, dynamic>) value = decoded;
      } on FormatException {
        /* Untrusted response copy is deliberately discarded. */
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final status = response.statusCode;
        final code = value?['errorCode'];
        throw DeviceIdentityFailure(
            _codes.contains(code) ? code as String : 'HTTP_FAILURE',
            status: status,
            retryable: status == 429 || status >= 500,
            outcomeUnknown: status >= 500);
      }
      if (response.statusCode != operation.successStatus) {
        throw const FormatException('Unexpected success');
      }
      if (operation.successStatus == 204) {
        if (bytes.isNotEmpty) throw const FormatException('Unexpected content');
        return const {};
      }
      if (value == null ||
          response.headers['content-type']
                  ?.split(';')
                  .first
                  .trim()
                  .toLowerCase() !=
              'application/json') {
        throw const FormatException('Invalid JSON response');
      }
      return value;
    }

    try {
      return await execute().timeout(timeout, onTimeout: () {
        cancel();
        throw DeviceIdentityFailure('NETWORK_TIMEOUT',
            retryable: true, outcomeUnknown: sent);
      });
    } on DeviceIdentityFailure {
      rethrow;
    } on FormatException {
      throw DeviceIdentityFailure('RESPONSE_INVALID', outcomeUnknown: sent);
    } catch (_) {
      throw DeviceIdentityFailure(
          _closed ? 'CLIENT_CLOSED' : 'CONNECTION_FAILED',
          retryable: !_closed,
          outcomeUnknown: sent);
    } finally {
      cancel();
      _active.remove(abort);
    }
  }

  void close() {
    _closed = true;
    for (final request in _active) {
      if (!request.isCompleted) request.complete();
    }
    if (_ownsClient) _client.close();
  }
}

const _codes = {
  'DEVICE_UNAUTHENTICATED',
  'DEVICE_CREDENTIAL_REVOKED',
  'SCOPE_DENIED',
  'ENROLLMENT_UNAVAILABLE',
  'ENROLLMENT_RECOVERY_LIMIT_REACHED',
  'ENROLLMENT_PROOF_ALREADY_USED',
  'ROTATION_IN_PROGRESS',
  'ROTATION_UNAVAILABLE',
  'HEARTBEAT_SEQUENCE_CONFLICT',
  'HEARTBEAT_STALE_SEQUENCE',
  'DEVICE_CREDENTIAL_UNAVAILABLE',
  'INPUT_INVALID',
  'RATE_LIMITED'
};
