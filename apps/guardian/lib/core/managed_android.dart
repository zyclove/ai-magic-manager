import 'api.dart';

final _id = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _providerId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
const _maxEpoch = 9007199254740991;

Never _invalid() =>
    throw const ApiFailure(502, 'INVALID_MANAGED_ANDROID_RESPONSE');

bool _time(Object? value) => value is int && value >= 0 && value <= _maxEpoch;

/// A reviewed enterprise is permission to start provisioning, not device enforcement.
class ManagedEnterpriseBinding {
  final String tenantId, provider, enterpriseId, contractReference, state;
  final String? providerDisplayName;
  final int version, createdAt, updatedAt;

  ManagedEnterpriseBinding._(Json raw)
      : tenantId = raw['tenantId'],
        provider = raw['provider'],
        enterpriseId = raw['enterpriseId'],
        contractReference = raw['contractReference'],
        state = raw['state'],
        providerDisplayName = raw['providerDisplayName'],
        version = raw['version'],
        createdAt = raw['createdAt'],
        updatedAt = raw['updatedAt'];

  static ManagedEnterpriseBinding parse(Object? raw, String tenantId) {
    if (raw is! Json ||
        raw['tenantId'] != tenantId ||
        raw['provider'] != 'GOOGLE_AMAPI' ||
        raw['enterpriseId'] is! String ||
        !_providerId.hasMatch(raw['enterpriseId']) ||
        raw['contractReference'] is! String ||
        (raw['contractReference'] as String).isEmpty ||
        (raw['contractReference'] as String).length > 200 ||
        !const {'PENDING', 'ACTIVE', 'REVOKED'}.contains(raw['state']) ||
        (raw['providerDisplayName'] != null &&
            (raw['providerDisplayName'] is! String ||
                (raw['providerDisplayName'] as String).length > 255)) ||
        raw['version'] is! int ||
        raw['version'] < 1 ||
        !_time(raw['createdAt']) ||
        !_time(raw['updatedAt']) ||
        raw['updatedAt'] < raw['createdAt']) _invalid();
    return ManagedEnterpriseBinding._(raw);
  }
}

class ManagedEnrollmentIntent {
  final String id, tenantId, subjectId, provider, enterpriseId, state;
  final String? providerDeviceId, managementMode;
  final int version, createdAt, expiresAt;
  final int? issuedAt, verifiedAt;

  ManagedEnrollmentIntent._(Json raw)
      : id = raw['id'],
        tenantId = raw['tenantId'],
        subjectId = raw['subjectId'],
        provider = raw['provider'],
        enterpriseId = raw['enterpriseId'],
        state = raw['state'],
        providerDeviceId = raw['providerDeviceId'],
        managementMode = raw['managementMode'],
        version = raw['version'],
        createdAt = raw['createdAt'],
        expiresAt = raw['expiresAt'],
        issuedAt = raw['issuedAt'],
        verifiedAt = raw['verifiedAt'];

  bool get canCancel => state == 'PREPARING' || state == 'ISSUED';
  bool get canVerify => state == 'ISSUED';

  static ManagedEnrollmentIntent parse(Object? raw, String tenantId,
      {String? expectedId}) {
    if (raw is! Json ||
        raw['id'] is! String ||
        !_id.hasMatch(raw['id']) ||
        (expectedId != null && raw['id'] != expectedId) ||
        raw['tenantId'] != tenantId ||
        raw['subjectId'] is! String ||
        !_id.hasMatch(raw['subjectId']) ||
        raw['provider'] != 'GOOGLE_AMAPI' ||
        raw['enterpriseId'] is! String ||
        !_providerId.hasMatch(raw['enterpriseId']) ||
        !const {
          'PREPARING',
          'ISSUED',
          'FAILED',
          'VERIFIED',
          'CANCEL_PENDING',
          'CANCELLED'
        }.contains(raw['state']) ||
        (raw['providerDeviceId'] != null &&
            (raw['providerDeviceId'] is! String ||
                !_providerId.hasMatch(raw['providerDeviceId']))) ||
        (raw['managementMode'] != null &&
            raw['managementMode'] != 'DEVICE_OWNER') ||
        raw['version'] is! int ||
        raw['version'] < 1 ||
        !_time(raw['createdAt']) ||
        !_time(raw['expiresAt']) ||
        raw['expiresAt'] < raw['createdAt'] ||
        (raw['issuedAt'] != null && !_time(raw['issuedAt'])) ||
        (raw['verifiedAt'] != null && !_time(raw['verifiedAt'])) ||
        (raw['state'] == 'VERIFIED' &&
            (raw['providerDeviceId'] == null ||
                raw['managementMode'] != 'DEVICE_OWNER' ||
                raw['verifiedAt'] == null))) _invalid();
    return ManagedEnrollmentIntent._(raw);
  }
}

class ManagedEnrollmentPageResult {
  final List<ManagedEnrollmentIntent> items;
  final String? nextCursor;
  const ManagedEnrollmentPageResult(this.items, this.nextCursor);

  static ManagedEnrollmentPageResult parse(Object? raw, String tenantId) {
    if (raw is! Json ||
        raw['items'] is! List ||
        (raw['items'] as List).length > 50 ||
        (raw['nextCursor'] != null &&
            (raw['nextCursor'] is! String || !_id.hasMatch(raw['nextCursor'])))) {
      _invalid();
    }
    final items = (raw['items'] as List)
        .map((item) => ManagedEnrollmentIntent.parse(item, tenantId))
        .toList();
    if (items.map((item) => item.id).toSet().length != items.length) _invalid();
    return ManagedEnrollmentPageResult(
        List.unmodifiable(items), raw['nextCursor']);
  }
}

/// The token and QR only exist in this one response. Never serialize or log this object.
class ManagedEnrollmentIssued {
  final ManagedEnrollmentIntent intent;
  final String tokenValue, qrCode;
  ManagedEnrollmentIssued._(this.intent, this.tokenValue, this.qrCode);

  static ManagedEnrollmentIssued parse(Object? raw, String tenantId) {
    if (raw is! Json ||
        raw['tokenValue'] is! String ||
        (raw['tokenValue'] as String).isEmpty ||
        (raw['tokenValue'] as String).length > 4096 ||
        raw['qrCode'] is! String ||
        (raw['qrCode'] as String).isEmpty ||
        (raw['qrCode'] as String).length > 16384) _invalid();
    final intent = ManagedEnrollmentIntent.parse(raw['intent'], tenantId);
    if (intent.state != 'ISSUED') _invalid();
    return ManagedEnrollmentIssued._(intent, raw['tokenValue'], raw['qrCode']);
  }

  @override
  String toString() => 'ManagedEnrollmentIssued[REDACTED]';
}
