import 'api.dart';
import 'bounded_json.dart';
import 'policy_publication.dart';
import 'scoped_http_client.dart';

/// Requests belong to one immutable policy and authorization lifetime.
abstract interface class PublicationRequests {
  bool get isCurrent;
  PublicationRequests scoped(bool Function() permitted,
      {void Function(ApiFailure)? onDenied});
  Future<PublicationReceipt> publish(PublicationPending attempt);
  Future<PublicationReceipt?> lookup(PublicationPending record);
}

/// A complete response from this POST established that authentication rejected
/// this attempt before publication. Ordinary client exceptions are insufficient.
class PublicationReauthenticationRequired implements Exception {
  final PublicationPending record;
  const PublicationReauthenticationRequired(this.record);

  @override
  String toString() => const ApiFailure(401, 'REAUTH_REQUIRED').message;
}

/// Only this repository can classify complete bounded HTTP evidence. A generic
/// client ApiFailure(410, ...) never grants a terminal storage transition.
final class PublicationResultTerminal implements Exception {
  final PublicationPending record;
  final PublicationTerminalReason reason;
  const PublicationResultTerminal._(this.record, this.reason);
}

class PolicyPublicationRepository implements PublicationRequests {
  final Api api;
  final PublicationOwner owner;
  final String policyId;
  final bool Function() current;
  final DateTime Function() clock;
  final void Function(ApiFailure)? onDenied;
  bool _active = true;
  late final Api _requests = api.scoped(_isCurrent);

  PolicyPublicationRepository(
      {required this.api,
      required this.owner,
      required this.policyId,
      required this.current,
      this.onDenied,
      DateTime Function()? clock})
      : clock = clock ?? DateTime.now {
    if (owner.apiBaseUrl != api.baseUrl || !isPublicationOpaqueId(policyId)) {
      throw const ApiFailure(400, 'INVALID_POLICY_PUBLICATION_INTENT');
    }
  }

  @override
  bool get isCurrent => _isCurrent();

  bool _isCurrent() {
    if (!_active) return false;
    if (!current()) _active = false;
    return _active;
  }

  void _ensureCurrent() {
    if (!_isCurrent()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  void _deny(ApiFailure failure) {
    if (!_active) return;
    _active = false;
    onDenied?.call(failure);
  }

  @override
  PublicationRequests scoped(bool Function() permitted,
          {void Function(ApiFailure)? onDenied}) =>
      PolicyPublicationRepository(
          api: _requests,
          owner: owner,
          policyId: policyId,
          clock: clock,
          current: () => _isCurrent() && permitted(),
          onDenied: (failure) {
            _deny(failure);
            onDenied?.call(failure);
          });

  String get _root => '/tenants/${Uri.encodeComponent(owner.tenantId)}'
      '/policies/${Uri.encodeComponent(policyId)}';

  void _checkRecord(PublicationPending record) {
    _ensureCurrent();
    if (record.intent.owner != owner || record.intent.policyId != policyId) {
      throw const ApiFailure(400, 'INVALID_POLICY_PUBLICATION_INTENT');
    }
  }

  @override
  Future<PublicationReceipt> publish(PublicationPending attempt) async {
    _checkRecord(attempt);
    if (attempt.phase != PublicationPhase.unknown) {
      throw const ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
    }
    return (await _read(attempt, write: true))!;
  }

  @override
  Future<PublicationReceipt?> lookup(PublicationPending record) async {
    _checkRecord(record);
    if (record.phase.terminal) {
      throw const ApiFailure(409, 'PUBLICATION_RESULT_TERMINAL');
    }
    return _read(record, write: false);
  }

  Future<PublicationReceipt?> _read(PublicationPending record,
      {required bool write}) async {
    final intent = record.intent;
    bool fresh() => clock().millisecondsSinceEpoch < intent.previewExpiresAt;
    void ensureRequest() {
      _ensureCurrent();
      if (write && !fresh()) throw const ApiFailure(409, 'PREVIEW_EXPIRED');
    }

    ensureRequest();
    // Only this POST view carries the original preview deadline. Expiry never
    // revokes the parent authorization or the read-only result lookup.
    final requestApi =
        write ? _requests.scoped(() => _isCurrent() && fresh()) : _requests;
    final query = Uri(queryParameters: {
      'revision': '${intent.revision}',
      'previewId': intent.previewId,
      'previewHash': intent.previewHash,
      'mode': intent.mode,
    }).query;
    BoundedHttpErrorEvidence? responseEvidence;
    try {
      final raw = await boundedJson(
          requestApi,
          write ? 'POST' : 'GET',
          write
              ? '$_root/publications'
              : '$_root/publication-results/${intent.idempotencyKey}?$query',
          ensureCurrent: ensureRequest,
          successStatus: write ? 201 : 200,
          maxBytes: 4096,
          body: write ? intent.body : null,
          key: write ? intent.idempotencyKey : null,
          version: write ? intent.revision : null,
          onHttpError: (evidence) { responseEvidence = evidence; });
      _ensureCurrent();
      return PublicationReceipt.parse(raw);
    } on ScopeChangedException {
      if (write && _isCurrent() && !fresh()) {
        throw const ApiFailure(409, 'PREVIEW_EXPIRED');
      }
      const failure = ApiFailure(409, 'WORKSPACE_CHANGED');
      _deny(failure);
      throw failure;
    } on ApiFailure catch (failure) {
      _ensureCurrent();
      if (responseEvidence != null &&
          identical(responseEvidence!.failure, failure) && failure.status == 410 &&
          responseEvidence!.problemStatus == 410) {
        final reason = switch (failure.code) {
          'IDEMPOTENCY_RESULT_EXPIRED' => PublicationTerminalReason.expired,
          'IDEMPOTENCY_RESPONSE_ERASED' => PublicationTerminalReason.erased,
          _ => null,
        };
        if (reason != null) throw PublicationResultTerminal._(record, reason);
      }
      if (write &&
          failure.code == 'WORKSPACE_CHANGED' &&
          _isCurrent() &&
          !fresh()) {
        throw const ApiFailure(409, 'PREVIEW_EXPIRED');
      }
      if (write &&
          responseEvidence != null &&
          identical(responseEvidence!.failure, failure) &&
          failure.status == 401 &&
          failure.code == 'REAUTH_REQUIRED') {
        _ensureCurrent();
        throw PublicationReauthenticationRequired(record);
      }
      if (!write &&
          failure.status == 404 &&
          failure.code == 'POLICY_PUBLICATION_RESULT_UNAVAILABLE') return null;
      if (failure.code == 'WORKSPACE_CHANGED' ||
          failure.status == 403 ||
          (failure.status == 401 && failure.code != 'REAUTH_REQUIRED')) {
        _deny(failure);
      }
      if (failure.status == 502 &&
          failure.code == 'INVALID_REPORT_JOB_RESPONSE') {
        throw const ApiFailure(502, 'INVALID_POLICY_PUBLICATION_RESPONSE');
      }
      rethrow;
    }
  }
}
