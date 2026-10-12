import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:device_identity/device_identity.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'environment.dart';
import 'session.dart';

abstract interface class ChildHelpStore {
  Future<String?> read(String scopeKey);
  Future<void> write(String scopeKey, String value);
}

class ChildHelpFailure implements Exception {
  final String code;
  const ChildHelpFailure(this.code);
  @override
  String toString() => 'ChildHelpFailure($code)';
}

typedef ChildHelpFactory = ChildHelpCoordinator Function(ChildSession session);

class ChildHelpRecord {
  final String clientRequestId, reasonCode, phase;
  final String? serverId, serverState;
  final int createdAt;
  final int? acknowledgedAt;
  const ChildHelpRecord(this.clientRequestId, this.reasonCode, this.phase,
      this.createdAt, this.serverId, this.serverState, this.acknowledgedAt);

  bool get confirmed => phase == 'CONFIRMED';

  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'clientRequestId': clientRequestId,
        'reasonCode': reasonCode,
        'phase': phase,
        'createdAt': createdAt,
        'serverId': serverId,
        'serverState': serverState,
        'acknowledgedAt': acknowledgedAt,
      };

  static ChildHelpRecord parse(String raw) {
    try {
      if (raw.length > 4096) throw const FormatException();
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> ||
          value['schemaVersion'] != 1 ||
          value.length != 8) throw const FormatException();
      final id = value['clientRequestId'];
      final reason = value['reasonCode'];
      final phase = value['phase'];
      final created = value['createdAt'];
      final serverId = value['serverId'];
      final state = value['serverState'];
      final acknowledged = value['acknowledgedAt'];
      if (!_uuid(id) ||
          !_reason(reason) ||
          !const {'PREPARED', 'CONFIRMED'}.contains(phase) ||
          created is! int ||
          created < 0 ||
          (serverId != null && !_uuid(serverId)) ||
          (state != null && !const {'OPEN', 'ACKNOWLEDGED'}.contains(state)) ||
          (acknowledged != null &&
              (acknowledged is! int || acknowledged < created)) ||
          (phase == 'PREPARED' &&
              (serverId != null || state != null || acknowledged != null)) ||
          (phase == 'CONFIRMED' &&
              (serverId == null ||
                  state == null ||
                  (state == 'OPEN' && acknowledged != null) ||
                  (state == 'ACKNOWLEDGED' && acknowledged == null)))) {
        throw const FormatException();
      }
      return ChildHelpRecord(id as String, reason as String, phase as String,
          created, serverId as String?, state as String?, acknowledged as int?);
    } catch (_) {
      throw const ChildHelpFailure('HELP_LOCAL_RECORD_INVALID');
    }
  }
}

/// One registration owns one encrypted pending request. Never auto-resend a mutation.
class ChildHelpCoordinator {
  final ChildSession session;
  final ChildEnvironment environment;
  final ChildHelpStore store;
  final http.Client client;
  final Uuid uuid;
  final int Function() nowMillis;
  final DeviceIdentityView identity;
  late final String scopeKey;
  bool closed = false;

  ChildHelpCoordinator(
      {required this.session,
      required this.environment,
      required this.store,
      http.Client? client,
      Uuid? uuid,
      int Function()? nowMillis})
      : client = client ?? http.Client(),
        uuid = uuid ?? const Uuid(),
        nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
        identity = session.identityView! {
    if (identity.deviceId == null ||
        identity.registrationId == null ||
        !session.credentialReady ||
        !session.identityReadSucceeded) {
      throw const ChildHelpFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
    }
    scopeKey = sha256
        .convert(utf8.encode(
            'child-help-v1|${environment.apiRoot}|${identity.tenantId}|${identity.deviceId}|${identity.registrationId}'))
        .toString();
  }

  bool get current {
    final view = session.identityView;
    return !closed &&
        session.foreground &&
        session.identityReadSucceeded &&
        session.credentialReady &&
        view != null &&
        !view.cloudAuthenticationBlocked &&
        view.tenantId == identity.tenantId &&
        view.deviceId == identity.deviceId &&
        view.registrationId == identity.registrationId;
  }

  void _check() {
    if (!current) throw const ChildHelpFailure('HELP_CONTEXT_CHANGED');
  }

  Future<ChildHelpRecord?> restore() async {
    _check();
    final raw = await store.read(scopeKey);
    _check();
    return raw == null ? null : ChildHelpRecord.parse(raw);
  }

  Future<ChildHelpRecord> submit(String reason) async {
    _check();
    if (!_reason(reason)) throw const ChildHelpFailure('HELP_REASON_INVALID');
    final previous = await restore();
    if (previous != null && !previous.confirmed) {
      throw const ChildHelpFailure('HELP_REQUEST_PENDING');
    }
    final now = nowMillis();
    if (now < 0) throw const ChildHelpFailure('CLOCK_UNTRUSTED');
    final record =
        ChildHelpRecord(uuid.v4(), reason, 'PREPARED', now, null, null, null);
    await store.write(scopeKey, jsonEncode(record.toJson()));
    _check();
    return _send(record);
  }

  Future<ChildHelpRecord> retry() async {
    final record = await restore();
    if (record == null || record.confirmed) {
      throw const ChildHelpFailure('HELP_REQUEST_NOT_PENDING');
    }
    return _send(record);
  }

  Future<ChildHelpRecord?> refresh() async {
    final record = await restore();
    if (record == null) return null;
    final status = await _request('GET', record.clientRequestId);
    return _confirm(record, status);
  }

  Future<ChildHelpRecord> _send(ChildHelpRecord record) async {
    // Local PREPARED stays durable on timeout, process death or malformed reply.
    final status = await _request('POST', '', body: {
      'clientRequestId': record.clientRequestId,
      'reasonCode': record.reasonCode,
    });
    return _confirm(record, status);
  }

  Future<ChildHelpRecord> _confirm(
      ChildHelpRecord original, Map<String, dynamic> status) async {
    _check();
    if (status['clientRequestId'] != original.clientRequestId ||
        status['reasonCode'] != original.reasonCode ||
        status['deviceId'] != identity.deviceId ||
        (original.confirmed &&
            (status['id'] != original.serverId ||
                status['createdAt'] != original.createdAt ||
                (original.serverState == 'ACKNOWLEDGED' &&
                    status['state'] != 'ACKNOWLEDGED'))) ||
        !_uuid(status['id']) ||
        !const {'OPEN', 'ACKNOWLEDGED'}.contains(status['state']) ||
        status['createdAt'] is! int ||
        status['createdAt'] < 0 ||
        (status['acknowledgedAt'] != null &&
            (status['acknowledgedAt'] is! int ||
                status['acknowledgedAt'] < status['createdAt'])) ||
        (status['state'] == 'OPEN' && status['acknowledgedAt'] != null) ||
        (status['state'] == 'ACKNOWLEDGED' &&
            status['acknowledgedAt'] == null)) {
      throw const ChildHelpFailure('HELP_RESPONSE_INVALID');
    }
    final next = ChildHelpRecord(
        original.clientRequestId,
        original.reasonCode,
        'CONFIRMED',
        status['createdAt'] as int,
        status['id'] as String,
        status['state'] as String,
        status['acknowledgedAt'] as int?);
    await store.write(scopeKey, jsonEncode(next.toJson()));
    _check();
    return next;
  }

  Future<Map<String, dynamic>> _request(String method, String suffix,
      {Map<String, String>? body}) async {
    _check();
    String? credential;
    try {
      credential = await session.identity.activeCredential();
    } catch (_) {
      throw const ChildHelpFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
    }
    _check();
    if (credential == null ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(credential)) {
      throw const ChildHelpFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
    }
    final path = '${environment.apiRoot.path}/device-api/help-requests'
        '${suffix.isEmpty ? '' : '/$suffix'}';
    final uri = environment.apiRoot.replace(path: path);
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers['Authorization'] = 'Bearer $credential'
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final streamed =
          await client.send(request).timeout(const Duration(seconds: 20));
      if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
        throw const ChildHelpFailure('HELP_REDIRECT_REFUSED');
      }
      final bytes = <int>[];
      await for (final chunk
          in streamed.stream.timeout(const Duration(seconds: 20))) {
        if (bytes.length + chunk.length > 16384) {
          throw const ChildHelpFailure('HELP_RESPONSE_INVALID');
        }
        bytes.addAll(chunk);
      }
      _check();
      if (streamed.statusCode == 401 || streamed.statusCode == 403) {
        throw const ChildHelpFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
      }
      if (streamed.statusCode == 404 && method == 'GET') {
        throw const ChildHelpFailure('HELP_NOT_RECEIVED');
      }
      if (streamed.statusCode == 429) {
        throw const ChildHelpFailure('HELP_REQUEST_RATE_LIMITED');
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        final code =
            decoded is Map<String, dynamic> ? decoded['errorCode'] : null;
        throw ChildHelpFailure(code is String &&
                const {
                  'HELP_REQUEST_RATE_LIMITED',
                  'HELP_REQUEST_ID_REUSED',
                  'HELP_REQUEST_UNAVAILABLE',
                  'SCOPE_DENIED',
                  'DEVICE_CREDENTIAL_UNAVAILABLE'
                }.contains(code)
            ? code
            : 'HELP_SERVER_UNAVAILABLE');
      }
      if (decoded is! Map<String, dynamic>) {
        throw const ChildHelpFailure('HELP_RESPONSE_INVALID');
      }
      return decoded;
    } on ChildHelpFailure {
      rethrow;
    } catch (_) {
      throw const ChildHelpFailure('HELP_NETWORK_UNKNOWN');
    }
  }

  void close() {
    closed = true;
    client.close();
  }
}

bool _uuid(Object? value) =>
    value is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(value);
bool _reason(Object? value) => const {
      'NEED_HELP',
      'UNCOMFORTABLE_CONTENT',
      'DEVICE_PROBLEM'
    }.contains(value);
