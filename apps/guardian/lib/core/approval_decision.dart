import 'api.dart';

const accessRequestStates = <String>{
  'PENDING',
  'APPROVED_PENDING_DELIVERY',
  'DENIED',
  'CANCELLED',
  'EXPIRED',
  'REVOKED',
  'INVALIDATED',
};

/// Detached list labels are references, never fresh directory authorization.
class ApprovalListContext {
  final String requestId;
  final String? subjectId, deviceId, applicationId, registrationId;
  final String? subjectName, deviceName, applicationName, applicationPackageName;
  final bool _registrationProvided;

  const ApprovalListContext._(
      {required this.requestId,
      required this.subjectId,
      required this.deviceId,
      required this.applicationId,
      required this.registrationId,
      required bool registrationProvided,
      this.subjectName,
      this.deviceName,
      this.applicationName,
      this.applicationPackageName})
      : _registrationProvided = registrationProvided;

  factory ApprovalListContext.capture(Json row, {required String role}) {
    final showNames = role != 'AUDITOR';
    return ApprovalListContext._(
        requestId: _requiredIdentity(row['id']),
        subjectId: _identity(row['subjectId']),
        deviceId: _identity(row['deviceId']),
        applicationId: _identity(row['applicationId']),
        registrationId: _identity(row['registrationId']),
        registrationProvided: row.containsKey('registrationId'),
        subjectName: showNames ? _name(row['subjectName']) : null,
        deviceName: showNames ? _name(row['deviceName']) : null,
        applicationName: showNames ? _name(row['applicationName']) : null,
        applicationPackageName:
            showNames ? _name(row['applicationPackageName']) : null);
  }

  bool _matches(String id, String subject, String device, String application,
          Object? registration) =>
      requestId == id &&
      subjectId == subject &&
      deviceId == device &&
      applicationId == application &&
      (!_registrationProvided ||
          (registrationId != null && registrationId == registration));
}

/// Fresh core facts stay authoritative even when matching list labels exist.
class ApprovalRequestSnapshot {
  final String id, subjectId, deviceId, applicationId, state;
  final int requestedSeconds, version;
  final int? grantedSeconds;
  final String? subjectName, deviceName, applicationName, applicationPackageName;

  const ApprovalRequestSnapshot._(
      {required this.id,
      required this.subjectId,
      required this.deviceId,
      required this.applicationId,
      required this.state,
      required this.requestedSeconds,
      required this.grantedSeconds,
      required this.version,
      this.subjectName,
      this.deviceName,
      this.applicationName,
      this.applicationPackageName});

  factory ApprovalRequestSnapshot.read(Object? raw,
      {required String expectedId, ApprovalListContext? context}) {
    if (raw is! Json) throw const ApiFailure(502, 'INVALID_RESPONSE');
    final id = _requiredIdentity(raw['id']);
    final subject = _requiredIdentity(raw['subjectId']);
    final device = _requiredIdentity(raw['deviceId']);
    final application = _requiredIdentity(raw['applicationId']);
    final state = raw['state'];
    final requested = raw['requestedWindowSeconds'];
    final granted = raw['grantedWindowSeconds'];
    final version = raw['version'];
    // Expiry can preserve a grant; invalidation is only for a pending request.
    if (id != expectedId ||
        state is! String ||
        !accessRequestStates.contains(state) ||
        requested is! int ||
        requested < 1 ||
        requested > 3600 ||
        !_safeApprovalInteger(version) ||
        !raw.containsKey('grantedWindowSeconds') ||
        (granted != null && (!_safeApprovalInteger(granted) ||
            granted < 1 || granted > requested)) ||
        (const {'APPROVED_PENDING_DELIVERY', 'REVOKED'}.contains(state) &&
            granted == null) ||
        (const {'PENDING', 'DENIED', 'CANCELLED', 'INVALIDATED'}.contains(state) &&
            granted != null)) {
      throw const ApiFailure(502, 'INVALID_RESPONSE');
    }
    final labels = context != null &&
            context._matches(id, subject, device, application, raw['registrationId'])
        ? context
        : null;
    return ApprovalRequestSnapshot._(
        id: id,
        subjectId: subject,
        deviceId: device,
        applicationId: application,
        state: state,
        requestedSeconds: requested,
        grantedSeconds: granted as int?,
        version: version as int,
        subjectName: labels?.subjectName,
        deviceName: labels?.deviceName,
        applicationName: labels?.applicationName,
        applicationPackageName: labels?.applicationPackageName);
  }
}

/// Delivery metadata never replaces the captured request or proves execution.
class ApprovalDeliverySnapshot {
  final String requestId, approvalState, deliveryState, executionState,
      evidenceStatus, retryStatus;
  final int approvalVersion;
  final String? action, documentId, reasonCode;
  final int? receivedAt, deliveryAttempt, retryAfter;

  const ApprovalDeliverySnapshot._({
    required this.requestId,
    required this.approvalVersion,
    required this.approvalState,
    required this.action,
    required this.documentId,
    required this.deliveryState,
    required this.receivedAt,
    required this.executionState,
    required this.evidenceStatus,
    required this.deliveryAttempt,
    required this.reasonCode,
    required this.retryStatus,
    required this.retryAfter,
  });

  factory ApprovalDeliverySnapshot.read(Object? raw,
      {required ApprovalRequestSnapshot request}) {
    if (raw is! Json || !const {
      'requestId', 'approvalVersion', 'approvalState', 'action', 'documentId',
      'deliveryState', 'receivedAt', 'executionState', 'evidenceStatus',
      'deliveryAttempt', 'reasonCode', 'retryStatus', 'retryAfter',
    }.every(raw.containsKey)) {
      throw const ApiFailure(502, 'INVALID_RESPONSE');
    }
    final id = _requiredIdentity(raw['requestId']);
    final version = raw['approvalVersion'], state = raw['approvalState'];
    final action = raw['action'], document = raw['documentId'];
    final delivery = raw['deliveryState'], received = raw['receivedAt'];
    final execution = raw['executionState'], evidence = raw['evidenceStatus'];
    final attempt = raw['deliveryAttempt'], reason = raw['reasonCode'];
    final retry = raw['retryStatus'], after = raw['retryAfter'];
    if (id != request.id ||
        !_safeApprovalInteger(version) || version < request.version ||
        state is! String || !accessRequestStates.contains(state) ||
        (version == request.version && state != request.state) ||
        (action != null && action is! String) ||
        (document != null && _identity(document) == null) ||
        delivery is! String ||
        (received != null && !_safeApprovalInteger(received)) ||
        execution != 'NOT_ENFORCED' || evidence != 'DEVICE_REPORT_UNVERIFIED' ||
        (attempt != null && (!_safeApprovalInteger(attempt) ||
            attempt < 1 || attempt > 10)) ||
        (reason != null && reason is! String) ||
        retry is! String || !const {
          'NOT_NEEDED', 'WAITING', 'AVAILABLE', 'NOT_ALLOWED',
          'WINDOW_ENDING', 'EXHAUSTED',
        }.contains(retry) ||
        (after != null && !_safeApprovalInteger(after))) {
      throw const ApiFailure(502, 'INVALID_RESPONSE');
    }
    if (action == null
        ? state == 'APPROVED_PENDING_DELIVERY' || state == 'REVOKED'
        : !const {'APPROVED_PENDING_DELIVERY', 'REVOKED', 'EXPIRED'}
                .contains(state) ||
            action != (state == 'APPROVED_PENDING_DELIVERY'
                ? 'UPSERT_ACCESS_WINDOW' : 'REMOVE_ACCESS_WINDOW')) {
      throw const ApiFailure(502, 'INVALID_RESPONSE');
    }
    if (document == null) {
      if (delivery != (action == null ? 'NOT_GRANTED' : 'NOT_FETCHED') ||
          received != null || attempt != null || reason != null ||
          retry != 'NOT_NEEDED' || after != null) {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
    } else {
      if (action == null || attempt == null ||
          !const {'SIGNED', 'RECEIVED', 'STORED', 'REJECTED'}
              .contains(delivery) ||
          (delivery == 'SIGNED') != (received == null)) {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
      if (delivery == 'REJECTED') {
        if (!const {
          'SIGNATURE_INVALID', 'BASELINE_MISSING', 'EXPIRED',
          'UNSUPPORTED_SCHEMA', 'STORAGE_FAILED', 'WRONG_DEVICE', 'OTHER',
        }.contains(reason)) {
          throw const ApiFailure(502, 'INVALID_RESPONSE');
        }
        final retryable = const {'BASELINE_MISSING', 'STORAGE_FAILED'}
            .contains(reason);
        if ((!retryable && retry != 'NOT_ALLOWED') ||
            (retryable && (attempt == 10
                ? retry != 'EXHAUSTED'
                : !const {'WAITING', 'AVAILABLE', 'WINDOW_ENDING'}
                    .contains(retry))) ||
            (retry == 'WINDOW_ENDING' && action != 'UPSERT_ACCESS_WINDOW')) {
          throw const ApiFailure(502, 'INVALID_RESPONSE');
        }
      } else if (reason != null || retry != 'NOT_NEEDED') {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
      if (const {'WAITING', 'AVAILABLE'}.contains(retry) != (after != null) ||
          (after != null && after <= received)) {
        throw const ApiFailure(502, 'INVALID_RESPONSE');
      }
    }
    return ApprovalDeliverySnapshot._(
        requestId: id,
        approvalVersion: version as int,
        approvalState: state,
        action: action as String?,
        documentId: document as String?,
        deliveryState: delivery,
        receivedAt: received as int?,
        executionState: execution as String,
        evidenceStatus: evidence as String,
        deliveryAttempt: attempt as int?,
        reasonCode: reason as String?,
        retryStatus: retry,
        retryAfter: after as int?);
  }
}

bool _safeApprovalInteger(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991;

String? _identity(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

String _requiredIdentity(Object? value) {
  final identity = _identity(value);
  if (identity == null) throw const ApiFailure(502, 'INVALID_RESPONSE');
  return identity;
}

String? _name(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

/// Preserve sub-minute requests and every remainder second in the summary.
String approvalDuration(int seconds) {
  if (seconds < 0) throw const ApiFailure(400, 'INVALID_APPROVAL_DURATION');
  final minutes = seconds ~/ 60, remainder = seconds % 60;
  if (minutes == 0) return '$seconds 秒';
  if (remainder == 0) return '$minutes 分钟';
  return '$minutes 分钟 $remainder 秒';
}

/// Build only the canonical approval fields; never forward form extras.
Json approvalGrantBody(Json values, {required int requestedSeconds}) {
  final minutes = values['minutes'], seconds = values['seconds'];
  if (requestedSeconds < 1 ||
      requestedSeconds > 3600 ||
      minutes is! int ||
      minutes < 0 ||
      minutes > 60 ||
      seconds is! int ||
      seconds < 0 ||
      seconds > 59) {
    throw const ApiFailure(400, 'INVALID_APPROVAL_DURATION');
  }
  final granted = minutes * 60 + seconds;
  if (granted == 0) throw const ApiFailure(400, 'INVALID_APPROVAL_DURATION');
  if (granted > requestedSeconds) {
    throw const ApiFailure(400, 'GRANT_EXCEEDS_REQUEST');
  }
  return Map<String, dynamic>.unmodifiable(
      {'decision': 'APPROVE', 'grantedWindowSeconds': granted});
}
