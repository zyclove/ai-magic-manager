import 'dart:async';
import 'dart:convert';
import 'package:device_identity/device_identity.dart'
    show CleanupProof, DeviceIdentityFailure, validUuid, safeInteger;
import 'package:http/http.dart' as http;
import 'models.dart';
import 'receipt.dart';
import 'verifier.dart';

/// Command discovery and explicit receipt submission. The proof callback must
/// use the original registration key, and the API root must be deployment-
/// controlled. A 401 from another API is never cleanup authorization.
class CleanupCommandClient {
  final CleanupScope scope;
  final Uri apiRoot;
  final Future<CleanupProof> Function(String action, String? operationId)
      proofFactory;
  final int Function() nowMillis;
  final Duration timeout;
  final int maxResponseBytes;
  final http.Client _client;
  final bool _ownsClient;
  final Set<Completer<void>> _active = {};
  bool _closed = false;

  CleanupCommandClient(
      {required this.scope,
      required Uri apiRoot,
      required this.proofFactory,
      required this.nowMillis,
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
        apiRoot.pathSegments.any((part) => part == '.' || part == '..') ||
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
      throw ArgumentError('Provide a confirmed HTTPS cleanup API root');
    }
  }

  /// Both reads are authenticated separately because a 60-second proof may
  /// expire between requests. No received command is persisted or executed.
  Future<VerifiedCleanupCommand> fetchAndVerify() async {
    final ring = await _request('GET', 'signing-keys', action: 'READ');
    final command = await _request('GET', 'command', action: 'READ');
    if (command.length != 4 ||
        !validUuid(command['operationId']) ||
        !validUuid(command['commandId']) ||
        !safeInteger(command['notAfter'], minimum: 1) ||
        command['compactJws'] is! String ||
        command['compactJws'].length > 16384 ||
        command.keys.any((key) => !const {
              'operationId',
              'commandId',
              'notAfter',
              'compactJws'
            }.contains(key))) {
      throw const CleanupFailure('CLEANUP_RESPONSE_INVALID');
    }
    final verifier = CleanupCommandVerifier(
        scope: scope, trustedKeys: ring, nowMillis: nowMillis);
    return verifier.verify(command['compactJws'],
        operationId: command['operationId'],
        commandId: command['commandId'],
        notAfter: command['notAfter']);
  }

  /// The caller owns a durable receipt record and must replay the same body
  /// after an unknown result. A 200 response is only a receipt acknowledgement,
  /// not independent proof of local deletion or current operation state.
  Future<CleanupReceiptAck> submitReceipt(CleanupReceipt receipt) async {
    final command = receipt.command;
    if (command.scope.tenantId != scope.tenantId ||
        command.scope.deviceId != scope.deviceId ||
        command.scope.registrationId != scope.registrationId ||
        command.scope.keyThumbprint != scope.keyThumbprint) {
      throw const CleanupFailure('CLEANUP_IDENTITY_CHANGED');
    }
    final now = nowMillis();
    if (!safeInteger(now, minimum: 1)) {
      throw const CleanupFailure('CLOCK_UNTRUSTED');
    }
    if (now + 300000 < command.issuedAt) {
      throw const CleanupFailure('CLOCK_UNTRUSTED');
    }
    if (now >= command.notAfter) {
      throw const CleanupFailure('CLEANUP_COMMAND_EXPIRED');
    }
    final result = await _request('POST', 'receipts',
        action: 'RECEIPT',
        operationId: command.operationId,
        body: receipt.body);
    return CleanupReceiptAck.parse(result, receipt);
  }

  Future<Map<String, dynamic>> _request(String method, String suffix,
      {required String action,
      String? operationId,
      Map<String, dynamic>? body}) async {
    if (_closed) throw const CleanupFailure('CLEANUP_CLIENT_CLOSED');
    final writing = method == 'POST';
    final abort = Completer<void>();
    _active.add(abort);
    var sent = false;
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    Future<Map<String, dynamic>> execute() async {
      final proof = await proofFactory(action, operationId);
      if (proof.keyThumbprint != scope.keyThumbprint) {
        throw const CleanupFailure('CLEANUP_IDENTITY_CHANGED');
      }
      if (_closed) throw const CleanupFailure('CLEANUP_CLIENT_CLOSED');
      final request = http.AbortableRequest(method,
          apiRoot.replace(path: '${apiRoot.path}/device-cleanup/$suffix'),
          abortTrigger: abort.future)
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers['Accept'] = 'application/json'
        ..headers['Authorization'] = 'Bearer ${proof.compact}';
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      sent = true;
      final response = await _client.send(request);
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw CleanupFailure('CLEANUP_REDIRECT_REFUSED',
            outcomeUnknown: writing);
      }
      final bytes = <int>[];
      await for (final part in response.stream) {
        if (bytes.length + part.length > maxResponseBytes) {
          throw CleanupFailure('CLEANUP_RESPONSE_INVALID',
              outcomeUnknown: writing);
        }
        bytes.addAll(part);
      }
      if (_closed) {
        throw CleanupFailure('CLEANUP_CLIENT_CLOSED', outcomeUnknown: writing);
      }
      if (response.statusCode == 401 ||
          response.statusCode == 403 ||
          response.statusCode == 404) {
        throw CleanupFailure('CLEANUP_NOT_AVAILABLE', outcomeUnknown: writing);
      }
      if (response.statusCode != 200) {
        throw CleanupFailure('CLEANUP_SERVICE_UNAVAILABLE',
            outcomeUnknown: writing);
      }
      if (response.headers['content-type']
              ?.split(';')
              .first
              .trim()
              .toLowerCase() !=
          'application/json') {
        throw CleanupFailure('CLEANUP_RESPONSE_INVALID',
            outcomeUnknown: writing);
      }
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        // Do not expose server response bodies in diagnostics.
      }
      throw CleanupFailure('CLEANUP_RESPONSE_INVALID', outcomeUnknown: writing);
    }

    try {
      return await execute().timeout(timeout, onTimeout: () {
        cancel();
        throw CleanupFailure('CLEANUP_NETWORK_TIMEOUT',
            outcomeUnknown: writing && sent);
      });
    } on CleanupFailure {
      rethrow;
    } on DeviceIdentityFailure {
      throw const CleanupFailure('CLEANUP_KEY_UNAVAILABLE');
    } catch (_) {
      throw CleanupFailure(
          _closed ? 'CLEANUP_CLIENT_CLOSED' : 'CLEANUP_NETWORK_UNAVAILABLE',
          outcomeUnknown: writing && sent);
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
