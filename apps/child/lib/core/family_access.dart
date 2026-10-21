import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:device_identity/device_identity.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'environment.dart';
import 'help_requests.dart';
import 'session.dart';

class FamilyAccessFailure implements Exception {
  final String code;
  const FamilyAccessFailure(this.code);
  @override
  String toString() => 'FamilyAccessFailure($code)';
}

typedef FamilyAccessFactory = FamilyAccessCoordinator Function(ChildSession);

/// A cloud receipt describes a request, never native execution or an access lease.
class FamilyAccessRecord {
  final Map<String, dynamic> body;
  final Map<String, dynamic>? receipt;
  final String phase;
  final int createdAt;
  const FamilyAccessRecord(this.body, this.phase, this.createdAt, this.receipt);
  String get requestId => body['requestId'] as String;
  String get reason => body['reason'] as String? ?? '';
  int get requestedSeconds => body['requestedSeconds'] as int;
  bool get confirmed => phase == 'CONFIRMED';
  String? get state => receipt?['state'] as String?;
  int? get notAfter => receipt?['notAfter'] as int?;
  int? get expiresAt => receipt?['expiresAt'] as int?;
}

/// One encrypted intent per original registration. Unknown outcomes are read
/// back by UUID before explicit retry can resend the unchanged original body.
class FamilyAccessCoordinator {
  final ChildSession session;
  final ChildEnvironment environment;
  final ChildHelpStore store;
  final http.Client client;
  final Future<void> Function()? afterApproval, onCredentialRejected;
  final int Function() nowMillis;
  final DeviceIdentityView identity;
  late final String scopeKey;
  static final Set<String> _operations = {};
  bool _closed = false;
  int _epoch = 0;

  FamilyAccessCoordinator(
      {required this.session,
      required this.environment,
      required this.store,
      http.Client? client,
      this.afterApproval,
      this.onCredentialRejected,
      int Function()? nowMillis})
      : client = client ?? http.Client(),
        nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
        identity = session.identityView! {
    if (!current) {
      throw const FamilyAccessFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
    }
    scopeKey = sha256
        .convert(utf8.encode(
            'family-access-v1|${environment.apiRoot}|${identity.tenantId}|${identity.deviceId}|${identity.registrationId}'))
        .toString();
  }

  bool get current {
    final view = session.identityView;
    return !_closed &&
        session.foreground &&
        session.identityReadSucceeded &&
        session.credentialReady &&
        view != null &&
        view.phase == IdentityPhase.active &&
        !view.cloudAuthenticationBlocked &&
        view.tenantId == identity.tenantId &&
        view.deviceId == identity.deviceId &&
        view.registrationId == identity.registrationId;
  }

  void _check(int epoch) {
    if (epoch != _epoch || !current) {
      throw const FamilyAccessFailure('FAMILY_ACCESS_CONTEXT_CHANGED');
    }
  }

  Future<T> _exclusive<T>(Future<T> Function(int) action) async {
    final epoch = _epoch;
    _check(epoch);
    if (!_operations.add(scopeKey)) {
      throw const FamilyAccessFailure('FAMILY_ACCESS_BUSY');
    }
    try {
      return await action(epoch);
    } finally {
      _operations.remove(scopeKey);
    }
  }

  Future<FamilyAccessRecord?> restore() => _read(_epoch);
  Future<FamilyAccessRecord?> _read(int epoch) async {
    _check(epoch);
    String? raw;
    try {
      raw = await store.read(scopeKey);
    } catch (_) {
      throw const FamilyAccessFailure('FAMILY_ACCESS_STORAGE_UNAVAILABLE');
    }
    _check(epoch);
    if (raw == null) return null;
    try {
      if (utf8.encode(raw).length > 4096) throw const FormatException();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final body = json['body'] as Map<String, dynamic>;
      if (json['schemaVersion'] != 1 ||
          json['scopeKey'] != scopeKey ||
          json.length != 6 ||
          !validUuid(body['requestId']) ||
          body['requestedSeconds'] is! int ||
          (body['requestedSeconds'] as int) < 60 ||
          (body['requestedSeconds'] as int) > 3600 ||
          body.keys.any((k) =>
              !{'requestId', 'requestedSeconds', 'reason'}.contains(k)) ||
          (body['reason'] != null && !_validReason(body['reason'])) ||
          !{'PREPARED', 'CONFIRMED'}.contains(json['phase']) ||
          !safeInteger(json['createdAt']) ||
          (json['phase'] == 'PREPARED' && json['receipt'] != null) ||
          (json['phase'] == 'CONFIRMED' &&
              json['receipt'] is! Map<String, dynamic>)) {
        throw const FormatException();
      }
      final record = FamilyAccessRecord(
          Map.unmodifiable(body),
          json['phase'] as String,
          json['createdAt'] as int,
          json['receipt'] == null
              ? null
              : Map<String, dynamic>.unmodifiable(
                  json['receipt'] as Map<String, dynamic>));
      if (record.receipt != null) _validateReceipt(record, record.receipt!);
      return record;
    } catch (_) {
      throw const FamilyAccessFailure('FAMILY_ACCESS_LOCAL_RECORD_INVALID');
    }
  }

  Future<void> _write(FamilyAccessRecord record, int epoch) async {
    _check(epoch);
    final raw = jsonEncode({
      'schemaVersion': 1,
      'scopeKey': scopeKey,
      'body': record.body,
      'phase': record.phase,
      'createdAt': record.createdAt,
      'receipt': record.receipt
    });
    try {
      await store.write(scopeKey, raw);
      _check(epoch);
      if (await store.read(scopeKey) != raw) {
        throw const FamilyAccessFailure('FAMILY_ACCESS_STORAGE_UNAVAILABLE');
      }
    } on FamilyAccessFailure {
      rethrow;
    } catch (_) {
      throw const FamilyAccessFailure('FAMILY_ACCESS_STORAGE_UNAVAILABLE');
    }
    _check(epoch);
  }

  Future<FamilyAccessRecord> submit(int seconds, {String? reason}) =>
      _exclusive((epoch) async {
        final trimmed = reason?.trim() ?? '';
        if (seconds < 60 || seconds > 3600 || !_validReason(trimmed)) {
          throw const FamilyAccessFailure('INVALID_FAMILY_ACCESS_REQUEST');
        }
        final previous = await _read(epoch);
        if (previous != null &&
            (!previous.confirmed ||
                !{'DENIED', 'EXPIRED'}.contains(previous.state))) {
          throw const FamilyAccessFailure('FAMILY_ACCESS_ALREADY_PENDING');
        }
        final body = <String, dynamic>{
          'requestId': const Uuid().v4(),
          'requestedSeconds': seconds,
          if (trimmed.isNotEmpty) 'reason': trimmed
        };
        final record = FamilyAccessRecord(
            Map.unmodifiable(body), 'PREPARED', nowMillis(), null);
        await _write(record, epoch);
        return _send(record, epoch);
      });
  Future<FamilyAccessRecord> retry() => _exclusive((epoch) async {
        final record = await _read(epoch);
        if (record == null) {
          throw const FamilyAccessFailure('FAMILY_ACCESS_NOT_PENDING');
        }
        Map<String, dynamic> receipt;
        try {
          receipt = await _request('GET', record.requestId, epoch);
        } on FamilyAccessFailure catch (failure) {
          if (failure.code != 'FAMILY_ACCESS_NOT_RECEIVED' ||
              record.confirmed) {
            rethrow;
          }
          return _send(record, epoch);
        }
        return _confirm(record, receipt, epoch);
      });
  Future<FamilyAccessRecord?> refresh() => _exclusive((epoch) async {
        final record = await _read(epoch);
        if (record == null) return null;
        return _confirm(
            record, await _request('GET', record.requestId, epoch), epoch);
      });
  Future<FamilyAccessRecord> _send(
          FamilyAccessRecord record, int epoch) async =>
      _confirm(
          record, await _request('POST', '', epoch, body: record.body), epoch);
  Future<FamilyAccessRecord> _confirm(FamilyAccessRecord original,
      Map<String, dynamic> receipt, int epoch) async {
    _check(epoch);
    _validateReceipt(original, receipt);
    final next = FamilyAccessRecord(original.body, 'CONFIRMED',
        original.createdAt, Map.unmodifiable(receipt));
    await _write(next, epoch);
    if (next.state == 'APPROVED' &&
        next.notAfter! > nowMillis() &&
        afterApproval != null) {
      _check(epoch);
      try {
        await afterApproval!();
      } catch (_) {
        throw const FamilyAccessFailure('FAMILY_ACCESS_RULE_SYNC_PENDING');
      }
      _check(epoch);
    }
    return next;
  }

  void _validateReceipt(
      FamilyAccessRecord original, Map<String, dynamic> value) {
    final state = value['state'],
        grant = value['grantedSeconds'],
        end = value['notAfter'];
    final previous = original.receipt;
    if (value['id'] != original.requestId ||
        !validUuid(value['subjectId']) ||
        value['deviceId'] != identity.deviceId ||
        value['requestedSeconds'] != original.requestedSeconds ||
        value['reason'] != original.reason ||
        !{'PENDING', 'APPROVED', 'DENIED', 'EXPIRED'}.contains(state) ||
        !safeInteger(value['expiresAt'], minimum: 1) ||
        !safeInteger(value['version']) ||
        (grant != null &&
            (grant is! int ||
                grant < 60 ||
                grant > original.requestedSeconds)) ||
        (end != null &&
            (!safeInteger(end, minimum: 1) ||
                end >
                    (value['expiresAt'] as int) +
                        original.requestedSeconds * 1000)) ||
        (state == 'APPROVED' && (grant == null || end == null)) ||
        ({'PENDING', 'DENIED'}.contains(state) &&
            (grant != null || end != null)) ||
        ((grant == null) != (end == null)) ||
        (previous != null &&
            (value['subjectId'] != previous['subjectId'] ||
                value['expiresAt'] != previous['expiresAt'] ||
                value['version'] < previous['version'] ||
                (previous['state'] == 'APPROVED' &&
                    (!{'APPROVED', 'EXPIRED'}.contains(state) ||
                        grant != previous['grantedSeconds'] ||
                        end != previous['notAfter'])) ||
                (previous['state'] == 'DENIED' && state != 'DENIED') ||
                (previous['state'] == 'EXPIRED' && state != 'EXPIRED')))) {
      throw const FamilyAccessFailure('FAMILY_ACCESS_RESPONSE_INVALID');
    }
  }

  Future<Map<String, dynamic>> _request(String method, String suffix, int epoch,
      {Map<String, dynamic>? body}) async {
    _check(epoch);
    final credential = await session.identity.activeCredential();
    _check(epoch);
    final actual = await session.identity.view();
    _check(epoch);
    if (credential == null ||
        actual.cloudAuthenticationBlocked ||
        actual.tenantId != identity.tenantId ||
        actual.deviceId != identity.deviceId ||
        actual.registrationId != identity.registrationId) {
      throw const FamilyAccessFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
    }
    final uri = environment.apiRoot.replace(
        path:
            '${environment.apiRoot.path}/device-api/family/access-requests${suffix.isEmpty ? '' : '/$suffix'}');
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers.addAll({
        'Authorization': 'Bearer $credential',
        'Accept': 'application/json'
      });
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final response =
          await client.send(request).timeout(const Duration(seconds: 15));
      _check(epoch);
      if (response.statusCode == 401) {
        final rejected = await session.identity.recordCredentialRejection(
            scope: actual, rejectedCredential: credential);
        if (rejected) await onCredentialRejected?.call();
        throw const FamilyAccessFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
      }
      if (response.statusCode == 403) {
        throw const FamilyAccessFailure('FAMILY_ACCESS_UNAVAILABLE');
      }
      if (response.statusCode == 404 && method == 'GET') {
        throw const FamilyAccessFailure('FAMILY_ACCESS_NOT_RECEIVED');
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw const FamilyAccessFailure('FAMILY_ACCESS_REDIRECT_REFUSED');
      }
      final bytes = <int>[];
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > 16384) {
          throw const FamilyAccessFailure('FAMILY_ACCESS_RESPONSE_INVALID');
        }
        bytes.addAll(chunk);
      }
      _check(epoch);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw FamilyAccessFailure(response.statusCode == 429
            ? 'FAMILY_ACCESS_RATE_LIMITED'
            : 'FAMILY_ACCESS_SERVER_UNAVAILABLE');
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) {
        throw const FamilyAccessFailure('FAMILY_ACCESS_RESPONSE_INVALID');
      }
      return value;
    } on FamilyAccessFailure {
      rethrow;
    } on Exception {
      throw const FamilyAccessFailure('FAMILY_ACCESS_NETWORK_UNKNOWN');
    }
  }

  static bool _validReason(Object? value) =>
      value is String &&
      value.length <= 300 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
  void pause() {
    _epoch++;
  }

  void close() {
    _closed = true;
    pause();
    client.close();
  }
}
