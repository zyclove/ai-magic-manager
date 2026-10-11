import 'dart:async';
import 'dart:convert';
import 'package:device_identity/device_identity.dart'
    show CleanupProof, validUuid, safeInteger;
import 'package:http/http.dart' as http;
import 'models.dart';
import 'verifier.dart';

/// Read-only command discovery. The proof callback must use the original
/// registration key, and the API root must be deployment-controlled. A 401
/// from another API is never interpreted as cleanup authorization.
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
    final ring = await _get('signing-keys');
    final command = await _get('command');
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

  Future<Map<String, dynamic>> _get(String suffix) async {
    if (_closed) throw const CleanupFailure('CLEANUP_CLIENT_CLOSED');
    final abort = Completer<void>();
    _active.add(abort);
    void cancel() {
      if (!abort.isCompleted) abort.complete();
    }

    Future<Map<String, dynamic>> execute() async {
      final proof = await proofFactory('READ', null);
      if (proof.keyThumbprint != scope.keyThumbprint) {
        throw const CleanupFailure('CLEANUP_IDENTITY_CHANGED');
      }
      if (_closed) throw const CleanupFailure('CLEANUP_CLIENT_CLOSED');
      final request = http.AbortableRequest('GET',
          apiRoot.replace(path: '${apiRoot.path}/device-cleanup/$suffix'),
          abortTrigger: abort.future)
        ..followRedirects = false
        ..maxRedirects = 0
        ..headers['Accept'] = 'application/json'
        ..headers['Authorization'] = 'Bearer ${proof.compact}';
      final response = await _client.send(request);
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const CleanupFailure('CLEANUP_REDIRECT_REFUSED');
      }
      final bytes = <int>[];
      await for (final part in response.stream) {
        if (bytes.length + part.length > maxResponseBytes) {
          throw const CleanupFailure('CLEANUP_RESPONSE_INVALID');
        }
        bytes.addAll(part);
      }
      if (_closed) throw const CleanupFailure('CLEANUP_CLIENT_CLOSED');
      if (response.statusCode == 401 ||
          response.statusCode == 403 ||
          response.statusCode == 404) {
        throw const CleanupFailure('CLEANUP_NOT_AVAILABLE');
      }
      if (response.statusCode != 200) {
        throw const CleanupFailure('CLEANUP_SERVICE_UNAVAILABLE');
      }
      if (response.headers['content-type']
              ?.split(';')
              .first
              .trim()
              .toLowerCase() !=
          'application/json') {
        throw const CleanupFailure('CLEANUP_RESPONSE_INVALID');
      }
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        // Do not expose server response bodies in diagnostics.
      }
      throw const CleanupFailure('CLEANUP_RESPONSE_INVALID');
    }

    try {
      return await execute().timeout(timeout, onTimeout: () {
        cancel();
        throw const CleanupFailure('CLEANUP_NETWORK_TIMEOUT');
      });
    } on CleanupFailure {
      rethrow;
    } catch (_) {
      throw CleanupFailure(
          _closed ? 'CLEANUP_CLIENT_CLOSED' : 'CLEANUP_NETWORK_UNAVAILABLE');
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
