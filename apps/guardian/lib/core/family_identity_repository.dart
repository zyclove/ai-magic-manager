import 'api.dart';
import 'bounded_json.dart';
import 'family_identity_configuration.dart';
import 'family_identity_release.dart';
import 'family_identity_acceptance.dart';
export 'family_identity_configuration.dart';
export 'family_identity_release.dart';
export 'family_identity_acceptance.dart';

const identityProvidersRoot = '/platform/identity-providers';
const _safeCodes = {
  'REAUTH_REQUIRED',
  'UNAUTHENTICATED',
  'SCOPE_DENIED',
  'WORKSPACE_CHANGED',
  'IDENTITY_PROVIDER_VERSION_CONFLICT',
  'IDENTITY_PROVIDER_ID_CONFLICT',
  'IDENTITY_PROVIDER_NOT_FOUND',
  'IDENTITY_PROVIDER_VAULT_UNAVAILABLE',
  'IDENTITY_PROVIDER_INVALID_INPUT',
  'IDENTITY_PROVIDER_RUNTIME_REVISION_CONFLICT',
  'IDENTITY_PROVIDER_RELEASE_ACTIVE',
  'IDENTITY_PROVIDER_RELEASE_NOT_READY',
  'IDENTITY_PROVIDER_ROLLBACK_NOT_ALLOWED',
  'IDENTITY_PROVIDER_RUNTIME_UNAVAILABLE',
  'IDENTITY_PROVIDER_RUNTIME_VERSION_CONFLICT',
  'IDENTITY_PROVIDER_RELEASE_IN_PROGRESS',
  'IDENTITY_PROVIDER_RELEASE_TARGET_MISMATCH',
  'IDENTITY_PROVIDER_ROLLBACK_UNAVAILABLE',
  'IDENTITY_PROVIDER_ROLLBACK_IDENTITY_MISMATCH',
  'IDENTITY_PROVIDER_RUNTIME_NOT_CONFIGURED',
  'IDENTITY_PROVIDER_RUNTIME_CHECK_NOT_AVAILABLE',
  'IDENTITY_PROVIDER_RELEASE_ALREADY_CLAIMED',
  'INVALID_IDENTITY_PROVIDER_RESPONSE'
};
ApiFailure identityProviderSafeFailure(Object failure) {
  if (failure is ApiFailure && _safeCodes.contains(failure.code)) {
    return ApiFailure(failure.status, failure.code);
  }
  if (failure is ApiFailure && failure.status == 401) {
    return const ApiFailure(401, 'REAUTH_REQUIRED');
  }
  return ApiFailure(failure is ApiFailure ? failure.status : 502,
      'IDENTITY_PROVIDER_REQUEST_FAILED');
}

/// Secrets exist only in the one outgoing request, never in Api's pending-write cache.
class FamilyIdentityRepository {
  final Api api;
  final bool Function() current;
  const FamilyIdentityRepository({required this.api, required this.current});
  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  void _id(String id) {
    if (!isIdentityProviderId(id)) {
      throw const ApiFailure(400, 'IDENTITY_PROVIDER_INVALID_INPUT');
    }
  }

  Future<dynamic> _send(String method, String path, {Json? body}) async {
    try {
      ensureCurrent();
      final result = await boundedJson(
          api, method, '$identityProvidersRoot$path',
          body: body,
          ensureCurrent: ensureCurrent,
          additionalSuccessStatuses:
              method == 'POST' ? const {201, 202} : const {},
          maxBytes: 64 * 1024);
      ensureCurrent();
      return result;
    } catch (failure) {
      throw identityProviderSafeFailure(failure);
    }
  }

  Future<IdentityProviderStatus> status() async =>
      IdentityProviderStatus.parse(await _send('GET', '/status'));
  Future<IdentityProviderVersion> version(String id) async {
    _id(id);
    final result =
        IdentityProviderVersion.parse(await _send('GET', '/versions/$id'));
    if (result.id != id) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return result;
  }

  Future<IdentityProviderVersion> saveVersion(
      String id, int baseVersion, IdentityProviderSettings settings,
      {Map<String, String> replacements = const {},
      bool clearSmsSecurityToken = false}) async {
    _id(id);
    if (baseVersion < 0 ||
        baseVersion > 9007199254740990 ||
        replacements.keys.any((key) => !const {
              'smsAccessKeyId',
              'smsAccessKeySecret',
              'smsSecurityToken',
              'wechatAppSecret'
            }.contains(key)) ||
        replacements.values.any((value) =>
            value.isEmpty ||
            value.length > 8192 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) ||
        clearSmsSecurityToken && replacements.containsKey('smsSecurityToken')) {
      throw const ApiFailure(400, 'IDENTITY_PROVIDER_INVALID_INPUT');
    }
    final publicSettings =
        IdentityProviderSettings.parse(settings.toJson()).toJson();
    final result =
        IdentityProviderVersion.parse(await _send('POST', '/versions', body: {
      'id': id,
      'baseVersion': baseVersion,
      'settings': publicSettings,
      'replacements': Map<String, String>.of(replacements),
      'clearSmsSecurityToken': clearSmsSecurityToken,
    }));
    if (result.id != id || result.baseVersion != baseVersion) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return result;
  }

  Future<IdentityProviderValidation> validate(String versionId) async {
    _id(versionId);
    final result = IdentityProviderValidation.parse(
        await _send('POST', '/versions/$versionId/validations', body: {}));
    if (result.versionId != versionId) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return result;
  }

  Future<IdentityProviderReleasePreparation> prepareRelease(
      String id, String versionId) async {
    _id(id);
    _id(versionId);
    final result = IdentityProviderReleasePreparation.parse(await _send(
        'POST', '/versions/$versionId/release-preparations',
        body: {'id': id}));
    if (result.id != id || result.versionId != versionId) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return result;
  }

  Future<IdentityProviderReleasePreparation> releasePreparation(
      String id) async {
    _id(id);
    final result = IdentityProviderReleasePreparation.parse(
        await _send('GET', '/release-preparations/$id'));
    if (result.id != id) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return result;
  }

  Future<List<IdentityProviderReleasePreparation>> releasePreparations(
      String versionId) async {
    _id(versionId);
    final raw = await _send('GET', '/versions/$versionId/release-preparations');
    if (raw is! Json ||
        raw.length != 1 ||
        raw['items'] is! List ||
        (raw['items'] as List).length > 5) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    final results = (raw['items'] as List)
        .map(IdentityProviderReleasePreparation.parse)
        .toList(growable: false);
    if (results.any((item) => item.versionId != versionId) ||
        results.map((item) => item.id).toSet().length != results.length) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return List.unmodifiable(results);
  }

  Future<IdentityProviderAcceptanceRun> startAcceptance(
      String id,
      String versionId,
      String environmentId,
      String providerJarSha256,
      String parentApkSha256,
      {String? releaseOperationId,
      int? expectedRuntimeRevision}) async {
    _id(id);
    _id(versionId);
    if (!isIdentityProviderEnvironment(environmentId) ||
        !isIdentityProviderDigest(providerJarSha256) ||
        !isIdentityProviderDigest(parentApkSha256) ||
        (releaseOperationId == null) != (expectedRuntimeRevision == null) ||
        releaseOperationId != null &&
            !isIdentityProviderId(releaseOperationId) ||
        expectedRuntimeRevision != null &&
            (expectedRuntimeRevision < 0 ||
                expectedRuntimeRevision > 9007199254740991)) {
      throw const ApiFailure(400, 'IDENTITY_PROVIDER_INVALID_INPUT');
    }
    final result = IdentityProviderAcceptanceRun.parse(
        await _send('POST', '/acceptance-runs', body: {
      'id': id,
      'versionId': versionId,
      'environmentId': environmentId,
      'providerJarSha256': providerJarSha256,
      'parentApkSha256': parentApkSha256,
      if (releaseOperationId != null) 'releaseOperationId': releaseOperationId,
      if (expectedRuntimeRevision != null)
        'expectedRuntimeRevision': expectedRuntimeRevision,
    }));
    if (result.id != id ||
        result.versionId != versionId ||
        result.environmentId != environmentId ||
        result.providerJarSha256 != providerJarSha256 ||
        result.parentApkSha256 != parentApkSha256 ||
        result.releaseOperationId != releaseOperationId ||
        result.runtimeRevision != expectedRuntimeRevision) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return result;
  }

  Future<IdentityProviderAcceptanceRun> acceptanceRun(String id) async {
    _id(id);
    final result = IdentityProviderAcceptanceRun.parse(
        await _send('GET', '/acceptance-runs/$id'));
    if (result.id != id) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return result;
  }

  Future<IdentityProviderAcceptanceStatus> acceptanceStatus() async =>
      IdentityProviderAcceptanceStatus.parse(
          await _send('GET', '/acceptance-status'));

  Future<List<IdentityProviderAcceptanceRun>> acceptanceRuns() async {
    final raw = await _send('GET', '/acceptance-runs');
    if (raw is! Json ||
        raw.length != 1 ||
        raw['items'] is! List ||
        (raw['items'] as List).length > 5) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    final runs = (raw['items'] as List)
        .map(IdentityProviderAcceptanceRun.parse)
        .toList(growable: false);
    if (runs.map((run) => run.id).toSet().length != runs.length) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return List.unmodifiable(runs);
  }

  Future<IdentityProviderReleaseStatus> releaseStatus() async =>
      IdentityProviderReleaseStatus.parse(
          await _send('GET', '/release-status'));

  Future<IdentityProviderReleaseOperation> requestRelease(
      String id,
      String kind,
      String versionId,
      String preparationId,
      int expectedRuntimeRevision,
      String providerJarSha256,
      String parentApkSha256) async {
    _id(id);
    _id(versionId);
    _id(preparationId);
    if (!const {'PUBLISH', 'ROLLBACK'}.contains(kind) ||
        expectedRuntimeRevision < 0 ||
        expectedRuntimeRevision > 9007199254740991 ||
        !isIdentityProviderDigest(providerJarSha256) ||
        !isIdentityProviderDigest(parentApkSha256)) {
      throw const ApiFailure(400, 'IDENTITY_PROVIDER_INVALID_INPUT');
    }
    final result = IdentityProviderReleaseOperation.parse(
        await _send('POST', '/release-operations', body: {
      'id': id,
      'kind': kind,
      'versionId': versionId,
      'preparationId': preparationId,
      'expectedRuntimeRevision': expectedRuntimeRevision,
      'providerJarSha256': providerJarSha256,
      'parentApkSha256': parentApkSha256,
    }));
    if (result.id != id ||
        result.kind != kind ||
        result.versionId != versionId ||
        result.preparationId != preparationId ||
        result.baseRuntimeRevision != expectedRuntimeRevision ||
        result.providerJarSha256 != providerJarSha256 ||
        result.parentApkSha256 != parentApkSha256) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return result;
  }

  Future<IdentityProviderReleaseOperation> releaseOperation(String id) async {
    _id(id);
    final result = IdentityProviderReleaseOperation.parse(
        await _send('GET', '/release-operations/$id'));
    if (result.id != id) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return result;
  }

  Future<IdentityProviderRuntimeCheck> checkRuntime(
      String id, String operationId) async {
    _id(id);
    _id(operationId);
    final result = IdentityProviderRuntimeCheck.parse(await _send(
        'POST', '/release-operations/$operationId/runtime-checks',
        body: {'id': id}));
    if (result.id != id || result.operationId != operationId) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return result;
  }

  Future<IdentityProviderRuntimeCheck> runtimeCheck(String id) async {
    _id(id);
    final result = IdentityProviderRuntimeCheck.parse(
        await _send('GET', '/runtime-checks/$id'));
    if (result.id != id) {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return result;
  }

  Future<IdentityProviderReleaseOperation> cancelRelease(
      String id, String operationId, int expectedRuntimeRevision) async {
    _id(id);
    _id(operationId);
    if (expectedRuntimeRevision < 0 ||
        expectedRuntimeRevision > 9007199254740991) {
      throw const ApiFailure(400, 'IDENTITY_PROVIDER_INVALID_INPUT');
    }
    final result = IdentityProviderReleaseOperation.parse(await _send(
        'POST', '/release-operations/$operationId/cancellations',
        body: {
          'id': id,
          'expectedRuntimeRevision': expectedRuntimeRevision,
        }));
    if (result.id != operationId || result.state != 'CANCELLED') {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return result;
  }

  Future<IdentityProviderReleaseOperation> cancellation(String id) async {
    _id(id);
    final result = IdentityProviderReleaseOperation.parse(
        await _send('GET', '/cancellations/$id'));
    if (result.state != 'CANCELLED') {
      throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
    }
    return result;
  }
}
