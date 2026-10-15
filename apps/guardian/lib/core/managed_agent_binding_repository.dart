import 'package:uuid/uuid.dart';
import 'api.dart';
import 'bounded_json.dart';
import 'managed_agent_binding.dart';

/// Bound to one workspace epoch and verified enrollment. No device secrets enter this repository.
class ManagedAgentBindingRepository {
  final Api api;
  final String tenantId, enrollmentId, subjectId;
  final bool Function() current;
  late final String root = '/tenants/$tenantId/managed-android/agent-bindings';
  ManagedAgentBindingRepository(
      {required this.api,
      required this.tenantId,
      required this.enrollmentId,
      required this.subjectId,
      required this.current});
  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    if (![tenantId, enrollmentId, subjectId].every(isAgentBindingId)) {
      throw const ApiFailure(400, 'INVALID_MANAGED_BINDING_ID');
    }
  }

  String newRequestId() => const Uuid().v4();
  Future<ManagedAgentBindingContext> context({String? cursor}) async {
    ensureCurrent();
    if (cursor != null && !isAgentBindingId(cursor)) {
      throw const ApiFailure(400, 'INVALID_CURSOR');
    }
    final query = cursor == null ? '?limit=50' : '?limit=50&cursor=$cursor';
    final raw = await boundedJson(
        api, 'GET', '$root/context/$enrollmentId$query',
        ensureCurrent: ensureCurrent, maxBytes: 256 * 1024);
    ensureCurrent();
    return ManagedAgentBindingContext.parse(raw, enrollmentId, subjectId,
        after: cursor);
  }

  Future<ManagedAgentBinding> create(
      String key, String device, String registration) async {
    ensureCurrent();
    if (![key, device, registration].every(isAgentBindingId)) {
      throw const ApiFailure(400, 'INVALID_MANAGED_BINDING_ID');
    }
    final raw = await boundedJson(api, 'POST', root,
        key: key,
        body: {
          'enrollmentId': enrollmentId,
          'deviceId': device,
          'registrationId': registration
        },
        successStatus: 201,
        ensureCurrent: ensureCurrent,
        maxBytes: 16 * 1024);
    final result = ManagedAgentBinding.parse(raw, enrollmentId);
    if (result.deviceId != device || result.registrationId != registration) {
      throw const ApiFailure(502, 'INVALID_MANAGED_BINDING_RESPONSE');
    }
    return result;
  }

  Future<ManagedAgentBinding> verify(ManagedAgentBinding binding) =>
      _change(binding, 'verify');
  Future<ManagedAgentBinding> revoke(ManagedAgentBinding binding) =>
      _change(binding, 'revoke');
  Future<ManagedAgentBinding> _change(
      ManagedAgentBinding binding, String operation) async {
    ensureCurrent();
    if (binding.enrollmentId != enrollmentId || !isAgentBindingId(binding.id)) {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
    final raw = await boundedJson(api, 'POST', '$root/${binding.id}/$operation',
        version: binding.version,
        additionalSuccessStatuses:
            operation == 'verify' ? const {202} : const {},
        ensureCurrent: ensureCurrent,
        maxBytes: 16 * 1024);
    final result = ManagedAgentBinding.parse(raw, enrollmentId);
    if (result.id != binding.id ||
        result.deviceId != binding.deviceId ||
        result.registrationId != binding.registrationId ||
        result.createdAt != binding.createdAt ||
        result.expiresAt != binding.expiresAt ||
        result.version < binding.version ||
        (operation == 'revoke' && result.state != 'REVOKED') ||
        (result.state != binding.state &&
            result.version <= binding.version &&
            !(binding.state == 'PENDING' && result.state == 'EXPIRED'))) {
      throw const ApiFailure(502, 'INVALID_MANAGED_BINDING_RESPONSE');
    }
    return result;
  }
}
