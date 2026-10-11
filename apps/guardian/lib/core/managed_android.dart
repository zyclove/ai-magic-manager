import 'api.dart';

final _id = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _providerId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
final _providerCode = RegExp(r'^[A-Z][A-Z0-9_]{2,31}$');
bool isManagedTenantId(String value) => _id.hasMatch(value);
const _maxEpoch = 9007199254740991;

Never _invalid() =>
    throw const ApiFailure(502, 'INVALID_MANAGED_ANDROID_RESPONSE');

bool _time(Object? value) => value is int && value >= 0 && value <= _maxEpoch;

/// Local configuration and contract readiness; remote policy application is separate.
class ManagedProvisioningReadiness {
  final String tenantId, provider, targetCountryCode, reasonCode;
  final bool canIssueEnrollment;

  ManagedProvisioningReadiness._(Json raw)
      : tenantId = raw['tenantId'],
        provider = raw['provider'],
        targetCountryCode = raw['targetCountryCode'],
        reasonCode = raw['reasonCode'],
        canIssueEnrollment = raw['canIssueEnrollment'];

  static ManagedProvisioningReadiness parse(Object? raw, String tenantId) {
    const reasons = {
      'REGION_PROVIDER_UNAVAILABLE',
      'PROVIDER_NOT_CONFIGURED',
      'BINDING_REQUIRED',
      'BINDING_REVIEW_PENDING',
      'BINDING_REVOKED',
      'PROVIDER_CHANGED',
      'CONTRACT_REQUIRED',
      'BOOTSTRAP_POLICY_REQUIRED',
      'PROVISIONING_CONFIGURED'
    };
    if (raw is! Json ||
        raw['tenantId'] != tenantId ||
        raw['provider'] is! String ||
        !_providerCode.hasMatch(raw['provider']) ||
        raw['targetCountryCode'] is! String ||
        !RegExp(r'^[A-Z]{2}$').hasMatch(raw['targetCountryCode']) ||
        !reasons.contains(raw['reasonCode']) ||
        raw['canIssueEnrollment'] is! bool ||
        raw['canIssueEnrollment'] !=
            (raw['reasonCode'] == 'PROVISIONING_CONFIGURED')) _invalid();
    return ManagedProvisioningReadiness._(raw);
  }
}

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
        raw['provider'] is! String ||
        !_providerCode.hasMatch(raw['provider']) ||
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

/// Platform view includes reviewer-only evidence references and actor identities.
class ManagedEnterpriseReview {
  final String tenantId, provider, enterpriseId, contractReference, state;
  final String requestedBy;
  final String? approvedBy, providerDisplayName, ownershipEvidenceReference;
  final int version, createdAt, updatedAt;

  ManagedEnterpriseReview._(Json raw)
      : tenantId = raw['tenantId'],
        provider = raw['provider'],
        enterpriseId = raw['enterpriseId'],
        contractReference = raw['contractReference'],
        state = raw['state'],
        requestedBy = raw['requestedBy'],
        approvedBy = raw['approvedBy'],
        providerDisplayName = raw['providerDisplayName'],
        ownershipEvidenceReference = raw['ownershipEvidenceReference'],
        version = raw['version'],
        createdAt = raw['createdAt'],
        updatedAt = raw['updatedAt'];

  static ManagedEnterpriseReview parse(Object? raw, {String? expectedTenant}) {
    if (raw is! Json ||
        raw['tenantId'] is! String ||
        !_id.hasMatch(raw['tenantId']) ||
        (expectedTenant != null && raw['tenantId'] != expectedTenant) ||
        raw['provider'] is! String ||
        !_providerCode.hasMatch(raw['provider']) ||
        raw['enterpriseId'] is! String ||
        !_providerId.hasMatch(raw['enterpriseId']) ||
        raw['contractReference'] is! String ||
        (raw['contractReference'] as String).isEmpty ||
        (raw['contractReference'] as String).length > 200 ||
        !const {'PENDING', 'ACTIVE', 'REVOKED'}.contains(raw['state']) ||
        raw['requestedBy'] is! String ||
        (raw['requestedBy'] as String).isEmpty ||
        (raw['approvedBy'] != null && raw['approvedBy'] is! String) ||
        (raw['providerDisplayName'] != null &&
            (raw['providerDisplayName'] is! String ||
                (raw['providerDisplayName'] as String).length > 255)) ||
        (raw['ownershipEvidenceReference'] != null &&
            (raw['ownershipEvidenceReference'] is! String ||
                (raw['ownershipEvidenceReference'] as String).length > 200)) ||
        raw['version'] is! int ||
        raw['version'] < 1 ||
        !_time(raw['createdAt']) ||
        !_time(raw['updatedAt']) ||
        raw['updatedAt'] < raw['createdAt'] ||
        (raw['state'] != 'PENDING' &&
            (raw['approvedBy'] == null ||
                raw['ownershipEvidenceReference'] == null))) _invalid();
    return ManagedEnterpriseReview._(raw);
  }
}

class ManagedEnterpriseReviewPage {
  final List<ManagedEnterpriseReview> items;
  final String? nextCursor;
  const ManagedEnterpriseReviewPage(this.items, this.nextCursor);

  static ManagedEnterpriseReviewPage parse(Object? raw) {
    if (raw is! Json ||
        raw['items'] is! List ||
        (raw['items'] as List).length > 50 ||
        (raw['nextCursor'] != null &&
            (raw['nextCursor'] is! String ||
                !_id.hasMatch(raw['nextCursor'])))) {
      _invalid();
    }
    final items = (raw['items'] as List)
        .map((item) => ManagedEnterpriseReview.parse(item))
        .toList();
    if (items.any((item) => item.state != 'PENDING') ||
        items.map((item) => item.tenantId).toSet().length != items.length) {
      _invalid();
    }
    return ManagedEnterpriseReviewPage(
        List.unmodifiable(items), raw['nextCursor']);
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
        raw['provider'] is! String ||
        !_providerCode.hasMatch(raw['provider']) ||
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

/// Fresh provider evidence for the enrollment baseline only, never local enforcement.
class ManagedProviderStatus {
  final String intentId, tenantId, providerDeviceId, state;
  final String? limitationCode;
  final int expectedPolicyVersion, checkedAt;
  final int? appliedPolicyVersion, lastPolicySyncAt;

  ManagedProviderStatus._(Json raw)
      : intentId = raw['intentId'],
        tenantId = raw['tenantId'],
        providerDeviceId = raw['providerDeviceId'],
        state = raw['state'],
        limitationCode = raw['limitationCode'],
        expectedPolicyVersion = raw['expectedPolicyVersion'],
        appliedPolicyVersion = raw['appliedPolicyVersion'],
        checkedAt = raw['checkedAt'],
        lastPolicySyncAt = raw['lastPolicySyncAt'];

  static ManagedProviderStatus parse(
      Object? raw, ManagedEnrollmentIntent intent) {
    const limitations = {
      'PENDING': 'PROVIDER_APPLICATION_UNCONFIRMED',
      'NON_COMPLIANT': 'PROVIDER_REPORTED_NON_COMPLIANCE',
      'DRIFT': 'PROVIDER_POLICY_CHANGED',
      'STALE': 'PROVIDER_REPORT_STALE'
    };
    if (raw is! Json ||
        intent.state != 'VERIFIED' ||
        raw['intentId'] != intent.id ||
        raw['tenantId'] != intent.tenantId ||
        raw['providerDeviceId'] != intent.providerDeviceId ||
        !const {'PENDING', 'APPLIED', 'NON_COMPLIANT', 'DRIFT', 'STALE'}
            .contains(raw['state']) ||
        raw['expectedPolicyVersion'] is! int ||
        raw['expectedPolicyVersion'] < 1 ||
        (raw['appliedPolicyVersion'] != null &&
            (raw['appliedPolicyVersion'] is! int ||
                raw['appliedPolicyVersion'] < 1)) ||
        !_time(raw['checkedAt']) ||
        (raw['lastPolicySyncAt'] != null && !_time(raw['lastPolicySyncAt'])) ||
        raw['localAgentBound'] != false ||
        (raw['state'] == 'APPLIED' &&
            (raw['limitationCode'] != null ||
                raw['appliedPolicyVersion'] != raw['expectedPolicyVersion'])) ||
        (raw['state'] != 'APPLIED' &&
            raw['limitationCode'] != limitations[raw['state']])) _invalid();
    return ManagedProviderStatus._(raw);
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
            (raw['nextCursor'] is! String ||
                !_id.hasMatch(raw['nextCursor'])))) {
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
