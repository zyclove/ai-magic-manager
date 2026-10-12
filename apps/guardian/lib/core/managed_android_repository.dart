import 'api.dart';
import 'bounded_json.dart';
import 'managed_android.dart';

/// Bound to one authenticated tenant and actor. Provider credentials never enter the browser.
class ManagedAndroidRepository {
  final Api api;
  final String tenantId;
  final bool Function() current;
  late final String _root = '/tenants/$tenantId/managed-android';

  ManagedAndroidRepository(
      {required this.api, required this.tenantId, required this.current});

  void _ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<ManagedProvisioningReadiness> readiness() async {
    _ensureCurrent();
    final raw = await boundedJson(api, 'GET', '$_root/readiness',
        maxBytes: 16 * 1024, ensureCurrent: _ensureCurrent);
    _ensureCurrent();
    return ManagedProvisioningReadiness.parse(raw, tenantId);
  }

  Future<ManagedCapacitySnapshot> capacity() async {
    _ensureCurrent();
    final raw = await boundedJson(api, 'GET', '$_root/capacity',
        maxBytes: 16 * 1024, ensureCurrent: _ensureCurrent);
    _ensureCurrent();
    return ManagedCapacitySnapshot.parse(raw, tenantId);
  }

  Future<ManagedEnterpriseBinding?> binding() async {
    _ensureCurrent();
    try {
      final raw = await boundedJson(api, 'GET', '$_root/enterprise-binding',
          maxBytes: 16 * 1024, ensureCurrent: _ensureCurrent);
      _ensureCurrent();
      return ManagedEnterpriseBinding.parse(raw, tenantId);
    } on ApiFailure catch (failure) {
      if (failure.status == 404) return null;
      rethrow;
    }
  }

  Future<ManagedEnterpriseBinding> propose(
      String enterpriseId, String contractReference) async {
    _ensureCurrent();
    final raw = await boundedJson(api, 'POST', '$_root/enterprise-binding',
        body: {
          'enterpriseId': enterpriseId,
          'contractReference': contractReference
        },
        successStatus: 201,
        maxBytes: 16 * 1024,
        ensureCurrent: _ensureCurrent);
    _ensureCurrent();
    final binding = ManagedEnterpriseBinding.parse(raw, tenantId);
    if (binding.enterpriseId != enterpriseId ||
        binding.contractReference != contractReference) {
      throw const ApiFailure(502, 'INVALID_MANAGED_ANDROID_RESPONSE');
    }
    return binding;
  }

  Future<ManagedEnrollmentPageResult> intents({String? cursor}) async {
    _ensureCurrent();
    final query = cursor == null
        ? '?limit=50'
        : '?limit=50&cursor=${Uri.encodeQueryComponent(cursor)}';
    final raw = await boundedJson(api, 'GET', '$_root/enrollment-intents$query',
        maxBytes: 256 * 1024, ensureCurrent: _ensureCurrent);
    _ensureCurrent();
    return ManagedEnrollmentPageResult.parse(raw, tenantId);
  }

  Future<ManagedEnrollmentIntent> intent(String id) async {
    _ensureCurrent();
    final raw = await boundedJson(api, 'GET', '$_root/enrollment-intents/$id',
        maxBytes: 16 * 1024, ensureCurrent: _ensureCurrent);
    _ensureCurrent();
    return ManagedEnrollmentIntent.parse(raw, tenantId, expectedId: id);
  }

  Future<ManagedProviderStatus> providerStatus(
      ManagedEnrollmentIntent intent) async {
    _ensureCurrent();
    if (intent.tenantId != tenantId || intent.state != 'VERIFIED') {
      throw const ApiFailure(400, 'MANAGED_ENROLLMENT_NOT_VERIFIED');
    }
    final raw = await boundedJson(
        api, 'GET', '$_root/enrollment-intents/${intent.id}/provider-status',
        maxBytes: 16 * 1024, ensureCurrent: _ensureCurrent);
    _ensureCurrent();
    return ManagedProviderStatus.parse(raw, intent);
  }

  /// A lost response cannot be replayed. Check the intent list, cancel, then reissue.
  Future<ManagedEnrollmentIssued> issue(String subjectId) async {
    _ensureCurrent();
    final raw = await boundedJson(api, 'POST', '$_root/enrollment-intents',
        body: {'subjectId': subjectId},
        successStatus: 201,
        maxBytes: 32 * 1024,
        ensureCurrent: _ensureCurrent);
    _ensureCurrent();
    final issued = ManagedEnrollmentIssued.parse(raw, tenantId);
    if (issued.intent.subjectId != subjectId) {
      throw const ApiFailure(502, 'INVALID_MANAGED_ANDROID_RESPONSE');
    }
    return issued;
  }

  Future<ManagedEnrollmentIntent> verify(
      ManagedEnrollmentIntent intent, String providerDeviceId) async {
    _ensureCurrent();
    final raw = await boundedJson(
        api, 'POST', '$_root/enrollment-intents/${intent.id}/verify',
        body: {'providerDeviceId': providerDeviceId},
        version: intent.version,
        maxBytes: 16 * 1024,
        ensureCurrent: _ensureCurrent);
    _ensureCurrent();
    final result =
        ManagedEnrollmentIntent.parse(raw, tenantId, expectedId: intent.id);
    if (result.state != 'VERIFIED' ||
        result.providerDeviceId != providerDeviceId ||
        result.version <= intent.version) {
      throw const ApiFailure(502, 'INVALID_MANAGED_ANDROID_RESPONSE');
    }
    return result;
  }

  Future<ManagedEnrollmentIntent> cancel(ManagedEnrollmentIntent intent) async {
    _ensureCurrent();
    final raw = await boundedJson(
        api, 'POST', '$_root/enrollment-intents/${intent.id}/cancel',
        version: intent.version,
        maxBytes: 16 * 1024,
        ensureCurrent: _ensureCurrent);
    _ensureCurrent();
    final result =
        ManagedEnrollmentIntent.parse(raw, tenantId, expectedId: intent.id);
    if (!const {'CANCELLED', 'CANCEL_PENDING'}.contains(result.state)) {
      throw const ApiFailure(502, 'INVALID_MANAGED_ANDROID_RESPONSE');
    }
    return result;
  }
}

/// Independent reviewer API. This repository is never bound to a tenant membership.
class ManagedAndroidReviewRepository {
  final Api api;
  final bool Function() current;
  static const _root = '/platform/managed-android/enterprise-bindings';

  const ManagedAndroidReviewRepository(
      {required this.api, required this.current});

  void _ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<ManagedEnterpriseReviewPage> pending({String? cursor}) async {
    _ensureCurrent();
    if (cursor != null && !isManagedTenantId(cursor)) {
      throw const ApiFailure(400, 'INVALID_CURSOR');
    }
    final query = cursor == null ? '?limit=50' : '?limit=50&cursor=$cursor';
    final raw = await boundedJson(api, 'GET', '$_root$query',
        maxBytes: 256 * 1024, ensureCurrent: _ensureCurrent);
    _ensureCurrent();
    return ManagedEnterpriseReviewPage.parse(raw);
  }

  Future<ManagedEnterpriseReview> get(String tenantId) async {
    _ensureCurrent();
    if (!isManagedTenantId(tenantId)) {
      throw const ApiFailure(400, 'INVALID_TENANT_ID');
    }
    final raw = await boundedJson(api, 'GET', '$_root/$tenantId',
        maxBytes: 16 * 1024, ensureCurrent: _ensureCurrent);
    _ensureCurrent();
    return ManagedEnterpriseReview.parse(raw, expectedTenant: tenantId);
  }

  Future<ManagedEnterpriseReview> approve(ManagedEnterpriseReview review,
      String evidenceReference, String reason) async {
    _ensureCurrent();
    final raw = await boundedJson(
        api, 'POST', '$_root/${review.tenantId}/approve',
        body: {
          'ownershipEvidenceReference': evidenceReference,
          'reason': reason
        },
        version: review.version,
        maxBytes: 16 * 1024,
        ensureCurrent: _ensureCurrent);
    _ensureCurrent();
    final result =
        ManagedEnterpriseReview.parse(raw, expectedTenant: review.tenantId);
    if (result.state != 'ACTIVE' ||
        result.version <= review.version ||
        result.ownershipEvidenceReference != evidenceReference) {
      throw const ApiFailure(502, 'INVALID_MANAGED_ANDROID_RESPONSE');
    }
    return result;
  }

  Future<ManagedEnterpriseReview> revoke(
      ManagedEnterpriseReview review, String reason) async {
    _ensureCurrent();
    final raw = await boundedJson(
        api, 'POST', '$_root/${review.tenantId}/revoke',
        body: {'reason': reason},
        version: review.version,
        maxBytes: 16 * 1024,
        ensureCurrent: _ensureCurrent);
    _ensureCurrent();
    final result =
        ManagedEnterpriseReview.parse(raw, expectedTenant: review.tenantId);
    if (result.state != 'REVOKED' || result.version <= review.version) {
      throw const ApiFailure(502, 'INVALID_MANAGED_ANDROID_RESPONSE');
    }
    return result;
  }
}
