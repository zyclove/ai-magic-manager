import 'dart:async';
import 'package:flutter/foundation.dart';
import 'api.dart';
import 'enrollment_journal.dart';

export 'enrollment_journal.dart';

const _dateLimit = 8640000000000000;
const _safeInteger = 9007199254740991;
const _states = {
  'PENDING_CLAIM',
  'AWAITING_CONFIRMATION',
  'CONFIRMED',
  'CANCELLED',
  'LOCKED',
  'EXPIRED'
};
bool _id(Object? value) =>
    value is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(value);
bool _integer(Object? value, {int min = 0, int max = _dateLimit}) =>
    value is int && value >= min && value <= max;
bool _keys(dynamic raw, Set<String> keys) =>
    raw is Json && raw.length == keys.length && keys.every(raw.containsKey);
Never _invalid() => throw const ApiFailure(502, 'INVALID_ENROLLMENT_RESPONSE');
bool _sameScope(EnrollmentScope a, EnrollmentScope b) =>
    a.actorId == b.actorId && a.tenantId == b.tenantId && a.role == b.role;
void _validateIntent(EnrollmentIntent intent) {
  // The durable codec is the single authority for scope, UUID variant and
  // creation timestamp rules. It never includes ticket or pairing secrets.
  intent.encode();
}

/// The one-time token is never included in recovery storage or diagnostics.
class EnrollmentTicket {
  final String id, token, state;
  final int expiresAt;
  const EnrollmentTicket(this.id, this.token, this.expiresAt, this.state);
  Json get json =>
      {'id': id, 'token': token, 'expiresAt': expiresAt, 'state': state};
  static EnrollmentTicket parse(dynamic raw, EnrollmentIntent intent) {
    _validateIntent(intent);
    if (!_keys(raw, {'id', 'token', 'expiresAt', 'state'}) ||
        raw['id'] != intent.requestId ||
        raw['token'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(raw['token']) ||
        !_integer(raw['expiresAt'], min: 1) ||
        raw['state'] != 'PENDING_CLAIM') {
      _invalid();
    }
    return EnrollmentTicket(
        raw['id'], raw['token'], raw['expiresAt'], raw['state']);
  }

  @override
  String toString() => 'EnrollmentTicket[id=$id, state=$state]';
}

/// A creator-bound management view contains no ticket or pairing secret.
class EnrollmentView {
  final String id, subjectId, platform, requestedMode, state;
  final String? deviceId;
  final int expiresAt, pairingFailures;
  const EnrollmentView(
      this.id,
      this.subjectId,
      this.platform,
      this.requestedMode,
      this.state,
      this.expiresAt,
      this.deviceId,
      this.pairingFailures);
  static EnrollmentView parse(dynamic raw, EnrollmentIntent intent) {
    _validateIntent(intent);
    if (!_keys(raw, {
          'id',
          'subjectId',
          'platform',
          'requestedMode',
          'state',
          'expiresAt',
          'deviceId',
          'pairingFailures'
        }) ||
        raw['id'] != intent.requestId ||
        raw['subjectId'] != intent.subjectId ||
        raw['platform'] != intent.platform ||
        raw['requestedMode'] != 'BYOD' ||
        !_states.contains(raw['state']) ||
        !_integer(raw['expiresAt'], min: 1) ||
        !_integer(raw['pairingFailures'], max: 10) ||
        (raw['deviceId'] != null && !_id(raw['deviceId']))) _invalid();
    final state = raw['state'] as String;
    if ((state == 'PENDING_CLAIM' &&
            (raw['deviceId'] != null || raw['pairingFailures'] != 0)) ||
        (const {'AWAITING_CONFIRMATION', 'CONFIRMED', 'LOCKED'}
                .contains(state) &&
            raw['deviceId'] == null) ||
        (state == 'LOCKED' && raw['pairingFailures'] == 0)) _invalid();
    return EnrollmentView(
        raw['id'],
        raw['subjectId'],
        raw['platform'],
        raw['requestedMode'],
        state,
        raw['expiresAt'],
        raw['deviceId'],
        raw['pairingFailures']);
  }
}

class EnrollmentGateway {
  final Api api;
  final bool creatorBound;
  EnrollmentGateway(this.api, {this.creatorBound = true});
  EnrollmentGateway.lookup(this.api) : creatorBound = false;
  bool get supportsCreation => creatorBound;

  Future<EnrollmentIntent> lookupIntent(EnrollmentScope scope, String id,
      {required int now, required bool Function() isCurrent}) async {
    // Lookup has no subject until the GET succeeds. Its known request UUID is
    // used only to validate the envelope; it is never sent as a subject.
    _validateIntent(EnrollmentIntent(
        scope: scope,
        requestId: id,
        subjectId: id,
        platform: 'ANDROID',
        createdAt: now));
    if (!isCurrent()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    dynamic raw;
    try {
      raw = await api.send('GET', '/tenants/${scope.tenantId}/enrollments/$id',
          isCurrent: isCurrent);
      if (!isCurrent()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    } catch (_) {
      if (!isCurrent()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
      rethrow;
    }
    if (!_keys(raw, {
          'id',
          'subjectId',
          'platform',
          'requestedMode',
          'state',
          'expiresAt',
          'deviceId',
          'pairingFailures'
        }) ||
        !_id(raw['subjectId']) ||
        !const {'ANDROID', 'ANDROID_TV'}.contains(raw['platform'])) _invalid();
    final intent = EnrollmentIntent(
        scope: scope,
        requestId: id,
        subjectId: raw['subjectId'],
        platform: raw['platform'],
        createdAt: now);
    EnrollmentView.parse(raw, intent);
    return intent;
  }

  void _guard(EnrollmentIntent intent, bool Function() isCurrent) {
    _validateIntent(intent);
    if (!isCurrent()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<dynamic> _send(String method, EnrollmentIntent intent, String suffix,
      {Json? body,
      String? clientRequestId,
      required bool Function() isCurrent}) async {
    _guard(intent, isCurrent);
    try {
      final result = await api.send(
          method, '/tenants/${intent.scope.tenantId}/$suffix',
          body: body, clientRequestId: clientRequestId, isCurrent: isCurrent);
      _guard(intent, isCurrent);
      return result;
    } catch (_) {
      _guard(intent, isCurrent);
      rethrow;
    }
  }

  Future<EnrollmentTicket> create(EnrollmentIntent intent,
      {required bool Function() isCurrent}) async {
    if (!supportsCreation) {
      throw const ApiFailure(409, 'ENROLLMENT_LOOKUP_ONLY');
    }
    return EnrollmentTicket.parse(
        await _send('POST', intent, 'enrollments',
            clientRequestId: intent.requestId,
            isCurrent: isCurrent,
            body: {
              'subjectId': intent.subjectId,
              'platform': intent.platform,
              'requestedMode': 'BYOD'
            }),
        intent);
  }

  Future<EnrollmentView> read(EnrollmentIntent intent,
          {required bool Function() isCurrent}) async =>
      EnrollmentView.parse(
          await _send('GET', intent,
              '${creatorBound ? 'enrollment-creation-results' : 'enrollments'}/${intent.requestId}',
              isCurrent: isCurrent),
          intent);
  Future<void> confirm(EnrollmentIntent intent, String pairingCode,
      {required String expectedDeviceId,
      required bool Function() isCurrent}) async {
    final code = pairingCode.trim().toUpperCase();
    if (!RegExp(r'^[0-9A-F]{8}$').hasMatch(code) || !_id(expectedDeviceId)) {
      throw const ApiFailure(400, 'INVALID_PAIRING_CODE');
    }
    final raw = await _send(
        'POST', intent, 'enrollments/${intent.requestId}/confirm',
        body: {'pairingCode': code}, isCurrent: isCurrent);
    if (!_keys(raw, {
          'id',
          'subjectId',
          'registrationId',
          'displayName',
          'platform',
          'osVersion',
          'state',
          'managementMode',
          'controlLevel',
          'lastHeartbeatAt',
          'observationStatus',
          'keyThumbprint',
          'version'
        }) ||
        raw['id'] != expectedDeviceId ||
        raw['subjectId'] != intent.subjectId ||
        raw['platform'] != intent.platform ||
        !_id(raw['registrationId']) ||
        raw['state'] != 'ACTIVE' ||
        raw['managementMode'] != 'BYOD' ||
        raw['controlLevel'] != 'LIMITED' ||
        raw['displayName'] is! String ||
        raw['displayName'].trim().isEmpty ||
        raw['displayName'].length > 100 ||
        raw['osVersion'] is! String ||
        raw['osVersion'].trim().isEmpty ||
        raw['osVersion'].length > 100 ||
        (raw['lastHeartbeatAt'] != null && !_integer(raw['lastHeartbeatAt'])) ||
        !const {'UNKNOWN', 'RECENT', 'STALE'}
            .contains(raw['observationStatus']) ||
        raw['keyThumbprint'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(raw['keyThumbprint']) ||
        !_integer(raw['version'], max: _safeInteger)) _invalid();
  }

  Future<void> cancel(EnrollmentIntent intent,
      {required bool Function() isCurrent}) async {
    final raw = await _send('DELETE', intent, 'enrollments/${intent.requestId}',
        isCurrent: isCurrent);
    if (raw != null) _invalid();
  }
}

/// A manual lookup must never replace or consume the durable creation journal.
class EnrollmentLookupJournal implements EnrollmentJournal {
  final EnrollmentIntent intent;
  const EnrollmentLookupJournal(this.intent);
  @override
  Future<EnrollmentIntent?> read(EnrollmentScope scope) async {
    _validateIntent(intent);
    if (!_sameScope(intent.scope, scope)) {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
    return intent;
  }

  @override
  Future<void> write(EnrollmentIntent value) async =>
      throw const ApiFailure(409, 'ENROLLMENT_LOOKUP_ONLY');
  @override
  Future<void> remove(EnrollmentIntent value) async =>
      throw const ApiFailure(409, 'ENROLLMENT_LOOKUP_ONLY');
}

/// Owns one recovery pointer. An unknown mutation is never replayed by a read,
/// restoration, lifecycle event, or an authentication redirect.
class EnrollmentController extends ChangeNotifier {
  final EnrollmentScope scope;
  final EnrollmentJournal journal;
  final EnrollmentGateway gateway;
  final bool Function() isCurrent;
  final String Function() newId;
  final int Function() now;
  EnrollmentController(
      {required this.scope,
      required this.journal,
      required this.gateway,
      required this.isCurrent,
      required this.newId,
      required this.now});
  EnrollmentIntent? _pending;
  EnrollmentView? _progress;
  EnrollmentTicket? _ticket;
  Object? error;
  bool loading = true, busy = false;
  bool _initialized = false, _disposed = false;
  Completer<void>? _initializationDone;
  bool _invalidated = false, _concealed = false, _retryAllowed = false;
  bool _needsPersistence = false, _mutationUncertain = false;
  int _generation = 0;
  EnrollmentIntent? get pending => _pending;
  bool get _live {
    if (_disposed || _invalidated) return false;
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool get initialized => _initialized;
  bool get current => _live;
  bool get hidden => !current || _concealed;
  EnrollmentView? get progress => !hidden ? _progress : null;
  EnrollmentTicket? get ticket =>
      !hidden && _ticket != null && _ticket!.expiresAt > now() ? _ticket : null;
  bool get hasSecret => ticket != null;
  bool get _available => _initialized && !hidden && !loading && !busy;
  bool get canCreate =>
      gateway.supportsCreation && _available && _pending == null;
  bool get canRetryCreation =>
      gateway.supportsCreation &&
      _available &&
      _pending != null &&
      _retryAllowed;
  bool get canConfirm =>
      _available &&
      !_mutationUncertain &&
      _progress?.state == 'AWAITING_CONFIRMATION' &&
      _progress!.expiresAt > now();
  bool get canCancel =>
      _available &&
      !_mutationUncertain &&
      const {'PENDING_CLAIM', 'AWAITING_CONFIRMATION', 'EXPIRED'}
          .contains(_progress?.state);
  bool get canStartAgain =>
      gateway.supportsCreation &&
      _available &&
      _pending != null &&
      const {'CANCELLED', 'LOCKED', 'CONFIRMED'}.contains(_progress?.state);
  bool _valid(int epoch) => !hidden && _generation == epoch;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  int _begin() {
    busy = true;
    error = null;
    final epoch = ++_generation;
    _emit();
    return epoch;
  }

  void _end(int epoch) {
    if (_disposed || epoch != _generation) return;
    if (!_live) {
      conceal();
      return;
    }
    busy = false;
    _emit();
  }

  ApiFailure _storageFailure() =>
      const ApiFailure(0, 'ENROLLMENT_STORAGE_UNAVAILABLE');
  Object _failure(Object failure) =>
      failure is ApiFailure ? failure : const ApiFailure(0, 'NETWORK_ERROR');
  bool _definiteCreateFailure(Object failure) =>
      failure is ApiFailure &&
      switch ((failure.status, failure.code)) {
        (
          400,
          'VALIDATION_FAILED' ||
              'MALFORMED_REQUEST' ||
              'INVALID_CLIENT_REQUEST_ID'
        ) =>
          true,
        (401, 'REAUTH_REQUIRED' || 'UNAUTHENTICATED') => true,
        (403, 'SCOPE_DENIED') => true,
        (422, 'CAPABILITY_UNSUPPORTED') => true,
        _ => false
      };

  Future<void> initialize() async {
    if (_disposed || _invalidated || _initialized) {
      return;
    }
    final outstanding = _initializationDone;
    if (outstanding != null) {
      final resumeGeneration = _generation;
      await outstanding.future;
      if (_disposed ||
          _invalidated ||
          _initialized ||
          busy ||
          !_live ||
          resumeGeneration != _generation) {
        return;
      }
      // Conceal may have invalidated the original storage read. Join that read
      // before starting one fresh initialization; restoration is always GET-only.
      await initialize();
      return;
    }
    if (busy) return;
    if (!_live) {
      conceal();
      return;
    }
    final done = Completer<void>();
    _initializationDone = done;
    _concealed = false;
    loading = true;
    final epoch = _begin();
    try {
      final saved = await journal.read(scope);
      if (!_valid(epoch)) return;
      if (saved != null) {
        _validateIntent(saved);
        if (!_sameScope(saved.scope, scope)) {
          throw const ApiFailure(409, 'WORKSPACE_CHANGED');
        }
        _pending = saved;
        _needsPersistence = false;
        _retryAllowed = false;
        await _read(epoch);
      }
      if (_valid(epoch)) _initialized = true;
    } catch (failure) {
      if (_valid(epoch)) {
        error = failure is ApiFailure ? failure : _storageFailure();
      }
    } finally {
      if (identical(_initializationDone, done)) _initializationDone = null;
      if (epoch == _generation) loading = false;
      _end(epoch);
      done.complete();
    }
  }

  Future<void> _read(int epoch, {Object? operationError}) async {
    final intent = _pending;
    if (intent == null || !_valid(epoch)) return;
    try {
      final found = await gateway.read(intent, isCurrent: () => _valid(epoch));
      if (!_valid(epoch)) return;
      _progress = found;
      _retryAllowed = false;
      _mutationUncertain = false;
      if (found.state != 'PENDING_CLAIM' ||
          _ticket?.id != found.id ||
          _ticket!.expiresAt <= now()) _ticket = null;
      error = const {'CONFIRMED', 'CANCELLED', 'LOCKED'}.contains(found.state)
          ? null
          : operationError;
    } catch (failure) {
      if (!_valid(epoch)) return;
      error = _failure(failure);
      _retryAllowed = gateway.supportsCreation &&
          failure is ApiFailure &&
          failure.status == 404 &&
          failure.code == 'ENROLLMENT_CREATION_UNAVAILABLE';
      if (failure is ApiFailure &&
          (failure.status == 401 ||
              failure.status == 403 ||
              failure.status == 404 ||
              failure.code == 'INVALID_ENROLLMENT_RESPONSE')) {
        _ticket = null;
        _progress = null;
      }
    }
  }

  Future<void> create(
      {required String subjectId, required String platform}) async {
    if (!canCreate) return;
    final epoch = _begin();
    try {
      final intent = EnrollmentIntent(
          scope: scope,
          requestId: newId(),
          subjectId: subjectId,
          platform: platform,
          createdAt: now());
      _validateIntent(intent);
      _pending = intent;
      _needsPersistence = true;
      _retryAllowed = false;
      await _persistAndCreate(epoch, intent);
    } catch (failure) {
      if (_valid(epoch)) error = _failure(failure);
    } finally {
      _end(epoch);
    }
  }

  Future<void> _persistAndCreate(int epoch, EnrollmentIntent intent) async {
    if (_needsPersistence) {
      try {
        await journal.write(intent);
      } catch (_) {
        if (_valid(epoch)) {
          error = _storageFailure();
          // No HTTP was attempted. An explicit retry must save this same intent.
          _retryAllowed = true;
        }
        return;
      }
      if (!_valid(epoch)) return;
      _needsPersistence = false;
    }
    if (!_valid(epoch)) return;
    try {
      final issued =
          await gateway.create(intent, isCurrent: () => _valid(epoch));
      if (!_valid(epoch)) return;
      _ticket = issued;
      _progress = EnrollmentView(intent.requestId, intent.subjectId,
          intent.platform, 'BYOD', 'PENDING_CLAIM', issued.expiresAt, null, 0);
      _retryAllowed = false;
      _mutationUncertain = false;
      error = null;
    } catch (failure) {
      if (!_valid(epoch)) return;
      _ticket = null;
      _progress = null;
      error = _failure(failure);
      _retryAllowed = _definiteCreateFailure(failure);
      if (failure is ApiFailure &&
          failure.status == 409 &&
          failure.code == 'ENROLLMENT_REQUEST_ALREADY_USED') await _read(epoch);
    }
  }

  Future<void> check() async {
    if (_disposed || _invalidated || busy) return;
    if (!_live) {
      conceal();
      return;
    }
    if (!_initialized) {
      await initialize();
      return;
    }
    _concealed = false;
    if (_pending == null) {
      _emit();
      return;
    }
    final epoch = _begin();
    try {
      await _read(epoch);
    } finally {
      _end(epoch);
    }
  }

  Future<void> retryCreation() async {
    if (!canRetryCreation) return;
    final intent = _pending!;
    final epoch = _begin();
    _retryAllowed = false;
    try {
      await _persistAndCreate(epoch, intent);
    } finally {
      _end(epoch);
    }
  }

  Future<void> confirm(String code) async {
    if (!canConfirm) return;
    final normalized = code.trim().toUpperCase();
    if (!RegExp(r'^[0-9A-F]{8}$').hasMatch(normalized)) {
      error = const ApiFailure(400, 'INVALID_PAIRING_CODE');
      _emit();
      return;
    }
    final intent = _pending!, deviceId = _progress!.deviceId!;
    final epoch = _begin();
    _mutationUncertain = true;
    _ticket = null;
    Object? operationError;
    try {
      await gateway.confirm(intent, normalized,
          expectedDeviceId: deviceId, isCurrent: () => _valid(epoch));
    } catch (failure) {
      operationError = _failure(failure);
    }
    if (_valid(epoch)) await _read(epoch, operationError: operationError);
    _end(epoch);
  }

  Future<void> cancel() async {
    if (!canCancel) return;
    final intent = _pending!;
    final epoch = _begin();
    _mutationUncertain = true;
    _ticket = null;
    Object? operationError;
    try {
      await gateway.cancel(intent, isCurrent: () => _valid(epoch));
    } catch (failure) {
      operationError = _failure(failure);
    }
    if (_valid(epoch)) await _read(epoch, operationError: operationError);
    _end(epoch);
  }

  Future<void> startAgain() async {
    if (!canStartAgain) return;
    final intent = _pending!;
    final epoch = _begin();
    try {
      await journal.remove(intent);
      if (!_valid(epoch)) return;
      _pending = null;
      _progress = null;
      _ticket = null;
      _retryAllowed = false;
      _needsPersistence = false;
      _mutationUncertain = false;
    } catch (_) {
      if (_valid(epoch)) error = _storageFailure();
    } finally {
      _end(epoch);
    }
  }

  void conceal() {
    if (_disposed) return;
    _generation++;
    _concealed = true;
    _ticket = null;
    _progress = null;
    _retryAllowed = false;
    error = null;
    loading = false;
    busy = false;
    _emit();
  }

  void invalidate() {
    if (_disposed) return;
    _invalidated = true;
    conceal();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _ticket = null;
    _progress = null;
    super.dispose();
  }
}
