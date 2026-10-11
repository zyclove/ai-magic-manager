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
