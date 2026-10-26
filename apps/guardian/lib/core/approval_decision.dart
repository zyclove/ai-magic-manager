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
  final String? subjectName, deviceName, applicationName, applicationPackageName;

  const ApprovalRequestSnapshot._(
      {required this.id,
      required this.subjectId,
      required this.deviceId,
      required this.applicationId,
      required this.state,
      required this.requestedSeconds,
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
    final version = raw['version'];
    if (id != expectedId ||
        state is! String ||
        !accessRequestStates.contains(state) ||
        requested is! int ||
        requested < 1 ||
        requested > 3600 ||
        version is! int ||
        version < 0) {
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
        version: version,
        subjectName: labels?.subjectName,
        deviceName: labels?.deviceName,
        applicationName: labels?.applicationName,
        applicationPackageName: labels?.applicationPackageName);
  }
}

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
