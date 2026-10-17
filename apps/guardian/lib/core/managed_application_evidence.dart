import 'api.dart';
import 'bounded_json.dart';
import 'managed_agent_binding.dart';
import 'managed_control_summary.dart';
import 'scoped_http_client.dart';

const _evidenceError = 'INVALID_MANAGED_APPLICATION_EVIDENCE_RESPONSE';
const _catalogError = 'INVALID_MANAGED_APPLICATION_CATALOG_RESPONSE';
const _controlVerified = 'MANAGED_APPLICATION_CONTROL_VERIFIED';
const _maximumInteger = 9007199254740991;
final _code = RegExp(r'^[A-Z][A-Z0-9_]{0,99}$');
final _package = RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$');
final _digest = RegExp(r'^[0-9a-f]{64}$');

bool _integer(Object? value) =>
    value is int && value >= 0 && value <= _maximumInteger;

Never _invalid(String code) => throw ApiFailure(502, code);

Json _object(Object? value, Set<String> fields, String code) {
  if (value is! Json ||
      value.length != fields.length ||
      !value.keys.every(fields.contains)) {
    _invalid(code);
  }
  return value;
}

/// A server application declaration; it is not installed-device evidence.
class ManagedEvidenceApplication {
  final String id, displayName, platform, packageName, profile, evidenceStatus;
  final List<String> signingDigests;

  const ManagedEvidenceApplication._(
      {required this.id,
      required this.displayName,
      required this.platform,
      required this.packageName,
      required this.profile,
      required this.signingDigests,
      required this.evidenceStatus});

  factory ManagedEvidenceApplication.parse(Object? value) {
    final raw = _object(
        value,
        {
          'id',
          'displayName',
          'platform',
          'packageName',
          'profile',
          'signingDigests',
          'evidenceStatus'
        },
        _catalogError);
    final name = raw['displayName'], package = raw['packageName'];
    final digests = raw['signingDigests'];
    if (!isAgentBindingId(raw['id']) ||
        name is! String ||
        name.isEmpty ||
        name.length > 100 ||
        !const {'ANDROID', 'ANDROID_TV'}.contains(raw['platform']) ||
        package is! String ||
        package.length > 255 ||
        !_package.hasMatch(package) ||
        !const {'PRIMARY', 'WORK', 'SECONDARY', 'UNKNOWN'}
            .contains(raw['profile']) ||
        digests is! List ||
        digests.length > 8 ||
        raw['evidenceStatus'] is! String) {
      _invalid(_catalogError);
    }
    final signers = <String>{};
    for (final digest in digests) {
      if (digest is! String ||
          !_digest.hasMatch(digest) ||
          !signers.add(digest)) {
        _invalid(_catalogError);
      }
    }
    return ManagedEvidenceApplication._(
        id: raw['id'],
        displayName: name,
        platform: raw['platform'],
        packageName: package,
        profile: raw['profile'],
        signingDigests: List.unmodifiable(signers),
        evidenceStatus: raw['evidenceStatus']);
  }
}

class ManagedEvidenceApplicationPage {
  final List<ManagedEvidenceApplication> items;
  final String? nextCursor;

  const ManagedEvidenceApplicationPage._(
      {required this.items, required this.nextCursor});

  factory ManagedEvidenceApplicationPage.parse(Object? value,
      {String? cursor}) {
    final raw = _object(value, {'items', 'nextCursor'}, _catalogError);
    final items = raw['items'], next = raw['nextCursor'];
    if (items is! List ||
        items.length > 50 ||
        (cursor != null && !isAgentBindingId(cursor)) ||
        (next != null && !isAgentBindingId(next))) {
      _invalid(_catalogError);
    }
    final applications = <ManagedEvidenceApplication>[];
    var previous = cursor ?? '';
    for (final item in items) {
      final application = ManagedEvidenceApplication.parse(item);
      if (application.id.compareTo(previous) <= 0) {
        _invalid(_catalogError);
      }
      applications.add(application);
      previous = application.id;
    }
    if (next != null &&
        (applications.isEmpty || next != applications.last.id)) {
      _invalid(_catalogError);
    }
    return ManagedEvidenceApplicationPage._(
        items: List.unmodifiable(applications), nextCursor: next);
  }
}

/// A fixed response snapshot. Its operation list never proves execution.
class ManagedApplicationEvidence {
  final String bindingId, applicationId, state, reasonCode, profileScope;
  final int version;
  final bool systemControlAvailable;
  final int? reportedAt, retrievedAt, expiresAt, nextRefreshAt;
  final ManagedControlSummary? _control;

  List<ManagedControlOperationDisplay> get controlOperations =>
      _control?.operations ?? const <ManagedControlOperationDisplay>[];

  const ManagedApplicationEvidence._(
      {required this.bindingId,
      required this.applicationId,
      required this.state,
      required this.reasonCode,
      required this.version,
      required this.profileScope,
      required this.systemControlAvailable,
      required this.reportedAt,
      required this.retrievedAt,
      required this.expiresAt,
      required this.nextRefreshAt,
      required ManagedControlSummary? control})
      : _control = control;

  factory ManagedApplicationEvidence.parse(Object? value,
      {required String bindingId, required String applicationId}) {
    final raw = _object(
        value,
        {
          'bindingId',
          'applicationId',
          'state',
          'reasonCode',
          'version',
          'profileScope',
          'systemControlAvailable',
          'reportedAt',
          'retrievedAt',
          'expiresAt',
          'nextRefreshAt',
          'controlOperations'
        },
        _evidenceError);
    final state = raw['state'], reason = raw['reasonCode'];
    final profile = raw['profileScope'];
    final available = raw['systemControlAvailable'];
    final version = raw['version'];
    final reported = raw['reportedAt'], retrieved = raw['retrievedAt'];
    final expires = raw['expiresAt'], next = raw['nextRefreshAt'];
    final operations = raw['controlOperations'];
    if (!isAgentBindingId(bindingId) ||
        !isAgentBindingId(applicationId) ||
        raw['bindingId'] != bindingId ||
        raw['applicationId'] != applicationId ||
        state is! String ||
        !const {
          'ABSENT',
          'PENDING',
          'WAITING_REPORT',
          'FAILED',
          'REJECTED',
          'STALE',
          'VERIFIED_IDENTITY'
        }.contains(state) ||
        reason is! String ||
        !_code.hasMatch(reason) ||
        !_integer(version) ||
        (state == 'ABSENT' ? version != 0 : version == 0) ||
        profile is! String ||
        available is! bool ||
        ![reported, retrieved, expires, next]
            .every((time) => time == null || _integer(time)) ||
        operations is! List ||
        operations.length > 128 ||
        (state == 'ABSENT' ? next != null : next == null)) {
      _invalid(_evidenceError);
    }
    final control =
        operations.isEmpty ? null : ManagedControlSummary.parse(operations);
    if (operations.isNotEmpty && control == null) {
      _invalid(_evidenceError);
    }
    if (state == 'VERIFIED_IDENTITY') {
      // Server clock skew may put a report up to 30 seconds after retrieval,
      // even after expiry for a short configured reuse age. Client arrival time
      // is not the server verification time; expiry is projected by stateAt.
      if (reported == null ||
          retrieved == null ||
          expires == null ||
          retrieved >= expires ||
          reported - retrieved > 30000 ||
          (available
              ? profile != 'PRIMARY' ||
                  reason != _controlVerified ||
                  control == null
              : profile != 'UNKNOWN' ||
                  reason == _controlVerified ||
                  operations.isNotEmpty)) {
        _invalid(_evidenceError);
      }
    } else if (profile != 'UNKNOWN' ||
        available ||
        reported != null ||
        retrieved != null ||
        expires != null ||
        operations.isNotEmpty) {
      _invalid(_evidenceError);
    }
    return ManagedApplicationEvidence._(
        bindingId: bindingId,
        applicationId: applicationId,
        state: state,
        reasonCode: reason,
        version: version,
        profileScope: profile,
        systemControlAvailable: available,
        reportedAt: reported,
        retrievedAt: retrieved,
        expiresAt: expires,
        nextRefreshAt: next,
        control: control);
  }

  String stateAt(DateTime now) =>
      state == 'VERIFIED_IDENTITY' && expiresAt! <= now.millisecondsSinceEpoch
          ? 'STALE'
          : state;

  ManagedControlSummary? controlAt(DateTime now) =>
      stateAt(now) == 'VERIFIED_IDENTITY' ? _control : null;
}

/// One parent binding version and one caller scope. There is no automatic POST.
class ManagedApplicationEvidenceRepository {
  final Api api;
  final String tenantId;
  final ManagedAgentBinding binding;
  final bool Function() current;
  final void Function(ApiFailure) onDenied;
  bool _active = true;
  late final Api _scopedApi = api.scoped(_isCurrent);

  ManagedApplicationEvidenceRepository(
      {required this.api,
      required this.tenantId,
      required this.binding,
      required this.current,
      required this.onDenied}) {
    if (![
          tenantId,
          binding.id,
          binding.enrollmentId,
          binding.deviceId,
          binding.registrationId
        ].every(isAgentBindingId) ||
        !_integer(binding.version) ||
        binding.version == 0) {
      throw const ApiFailure(400, 'INVALID_MANAGED_BINDING_ID');
    }
  }

  /// Observes this context's permanent guard without acquiring a client.
  bool get isCurrent => _isCurrent();

  /// Borrows the same fixed context and its permanent denial lock. A local
  /// permission loss closes this view; a hard HTTP denial closes its ancestors.
  ManagedApplicationEvidenceRepository scoped(bool Function() permitted,
      {void Function(ApiFailure)? onDenied}) {
    return ManagedApplicationEvidenceRepository(
        api: _scopedApi,
        tenantId: tenantId,
        binding: binding,
        current: () => _isCurrent() && permitted(),
        onDenied: (failure) {
          _deny(failure);
          onDenied?.call(failure);
        });
  }

  bool _isCurrent() {
    if (!_active) {
      return false;
    }
    if (binding.state != 'VERIFIED' ||
        binding.verifiedAt == null ||
        !current()) {
      _active = false;
    }
    return _active;
  }

  void _deny(ApiFailure failure) {
    if (!_active) {
      return;
    }
    _active = false;
    onDenied(failure);
  }

  void _ensureCurrent() {
    if (!_isCurrent()) {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
  }

  Future<Object?> _request(String method, String path,
      {required String invalidCode,
      required int maxBytes,
      int? version}) async {
    _ensureCurrent();
    try {
      final raw = await boundedJson(_scopedApi, method, path,
          ensureCurrent: _ensureCurrent, version: version, maxBytes: maxBytes);
      _ensureCurrent();
      return raw;
    } on ScopeChangedException {
      _active = false;
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    } on ApiFailure catch (error) {
      if (error.status == 409 && error.code == 'WORKSPACE_CHANGED') {
        _active = false;
      }
      if ((error.status == 401 && error.code != 'REAUTH_REQUIRED') ||
          error.status == 403) {
        _deny(error);
      }
      if (error.status == 502 && error.code == 'INVALID_REPORT_JOB_RESPONSE') {
        throw ApiFailure(502, invalidCode);
      }
      rethrow;
    }
  }

  Future<ManagedEvidenceApplicationPage> applicationPage(
      {String? cursor}) async {
    _ensureCurrent();
    if (cursor != null && !isAgentBindingId(cursor)) {
      throw const ApiFailure(400, 'INVALID_CURSOR');
    }
    final query = Uri(queryParameters: {
      'limit': '50',
      if (cursor != null) 'cursor': cursor
    }).query;
    final raw = await _request('GET', '/tenants/$tenantId/applications?$query',
        invalidCode: _catalogError, maxBytes: 256 * 1024);
    return ManagedEvidenceApplicationPage.parse(raw, cursor: cursor);
  }

  Future<ManagedApplicationEvidence> _evidenceRequest(
      String method, String applicationId) async {
    _ensureCurrent();
    if (!isAgentBindingId(applicationId)) {
      throw const ApiFailure(400, 'INVALID_APPLICATION_ID');
    }
    final root =
        '/tenants/$tenantId/managed-android/agent-bindings/${binding.id}'
        '/applications/$applicationId/evidence';
    final raw = await _request(
        method, method == 'POST' ? '$root/refresh' : root,
        invalidCode: _evidenceError,
        maxBytes: 16 * 1024,
        version: binding.version);
    return ManagedApplicationEvidence.parse(raw,
        bindingId: binding.id, applicationId: applicationId);
  }

  Future<ManagedApplicationEvidence> read(String applicationId) =>
      _evidenceRequest('GET', applicationId);

  Future<ManagedApplicationEvidence> refresh(String applicationId) =>
      _evidenceRequest('POST', applicationId);
}
