import 'api.dart';
import 'family_identity_configuration.dart';

Never _invalid() =>
    throw const ApiFailure(502, 'INVALID_IDENTITY_PROVIDER_RESPONSE');
Json _object(Object? value, Set<String> keys) {
  if (value is! Json ||
      value.keys.toSet().difference(keys).isNotEmpty ||
      keys.difference(value.keys.toSet()).isNotEmpty) _invalid();
  return value;
}

String _text(Object? value, {int maximum = 80}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > maximum ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) _invalid();
  return value;
}

String _id(Object? value) {
  final result = _text(value, maximum: 36);
  if (!isIdentityProviderId(result)) _invalid();
  return result;
}

String _digest(Object? value) {
  final result = _text(value, maximum: 64);
  if (!isIdentityProviderDigest(result)) _invalid();
  return result;
}

int _number(Object? value) {
  if (value is! int || value < 0 || value > 9007199254740991) _invalid();
  return value;
}

bool _flag(Object? value) {
  if (value is! bool) _invalid();
  return value;
}

String _enum(Object? value, Set<String> values) {
  if (value is! String || !values.contains(value)) _invalid();
  return value;
}

String _runtime(Json object) {
  if (object['salesAllowed'] != false) _invalid();
  return _enum(object['runtimeStatus'], {'APPLY_REQUIRED', 'APPLIED_CLOSED'});
}

class IdentityProviderReleaseTarget {
  final String versionId, preparationId, providerJarSha256, parentApkSha256;
  final int confirmedAt;
  const IdentityProviderReleaseTarget(this.versionId, this.preparationId,
      this.providerJarSha256, this.parentApkSha256, this.confirmedAt);
  factory IdentityProviderReleaseTarget.parse(Object? value) {
    final object = _object(value, {
      'versionId',
      'preparationId',
      'providerJarSha256',
      'parentApkSha256',
      'confirmedAt'
    });
    return IdentityProviderReleaseTarget(
        _id(object['versionId']),
        _id(object['preparationId']),
        _digest(object['providerJarSha256']),
        _digest(object['parentApkSha256']),
        _number(object['confirmedAt']));
  }
}

class IdentityProviderReleaseOperation {
  final String id,
      kind,
      versionId,
      preparationId,
      providerJarSha256,
      parentApkSha256,
      state,
      reasonCode,
      runtimeStatus;
  final int baseRuntimeRevision, createdAt;
  final int? confirmedAt;
  final bool canCheckRuntime, canCancel;
  const IdentityProviderReleaseOperation(
      this.id,
      this.kind,
      this.versionId,
      this.preparationId,
      this.providerJarSha256,
      this.parentApkSha256,
      this.baseRuntimeRevision,
      this.state,
      this.reasonCode,
      this.createdAt,
      this.confirmedAt,
      this.canCheckRuntime,
      this.canCancel,
      this.runtimeStatus);
  bool get terminal => const {'APPLIED_CLOSED', 'CANCELLED'}.contains(state);
  factory IdentityProviderReleaseOperation.parse(Object? value) {
    final object = _object(value, {
      'id',
      'kind',
      'versionId',
      'preparationId',
      'providerJarSha256',
      'parentApkSha256',
      'baseRuntimeRevision',
      'state',
      'reasonCode',
      'createdAt',
      'confirmedAt',
      'canCheckRuntime',
      'canCancel',
      'runtimeStatus',
      'salesAllowed'
    });
    final state = _enum(object['state'], {
      'WAITING_EXECUTOR',
      'CLAIMED',
      'EXECUTION_UNKNOWN',
      'APPLIED_CLOSED',
      'CANCELLED'
    });
    final confirmedAt =
        object['confirmedAt'] == null ? null : _number(object['confirmedAt']);
    final runtime = _runtime(object);
    if ((state == 'APPLIED_CLOSED') != (confirmedAt != null) ||
        state == 'APPLIED_CLOSED' && runtime != 'APPLIED_CLOSED') _invalid();
    return IdentityProviderReleaseOperation(
        _id(object['id']),
        _enum(object['kind'], {'PUBLISH', 'ROLLBACK'}),
        _id(object['versionId']),
        _id(object['preparationId']),
        _digest(object['providerJarSha256']),
        _digest(object['parentApkSha256']),
        _number(object['baseRuntimeRevision']),
        state,
        _text(object['reasonCode']),
        _number(object['createdAt']),
        confirmedAt,
        _flag(object['canCheckRuntime']),
        _flag(object['canCancel']),
        runtime);
  }
}

class IdentityProviderReleaseStatus {
  final String environmentId, runtimeStatus;
  final int runtimeRevision;
  final bool observationReady, executorReady;
  final IdentityProviderReleaseOperation? activeOperation, confirmedOperation;
  final List<IdentityProviderReleaseTarget> rollbackTargets;
  const IdentityProviderReleaseStatus(
      this.environmentId,
      this.runtimeRevision,
      this.observationReady,
      this.executorReady,
      this.activeOperation,
      this.confirmedOperation,
      this.rollbackTargets,
      this.runtimeStatus);
  factory IdentityProviderReleaseStatus.parse(Object? value) {
    final object = _object(value, {
      'environmentId',
      'runtimeRevision',
      'observationReady',
      'executorReady',
      'activeOperation',
      'confirmedOperation',
      'rollbackTargets',
      'runtimeStatus',
      'salesAllowed'
    });
    final environment = _text(object['environmentId'], maximum: 64);
    if (!isIdentityProviderEnvironment(environment)) _invalid();
    final rawTargets = object['rollbackTargets'];
    if (rawTargets is! List || rawTargets.length > 100) _invalid();
    final targets = rawTargets
        .map(IdentityProviderReleaseTarget.parse)
        .toList(growable: false);
    if (targets.map((item) => item.versionId).toSet().length !=
        targets.length) {
      _invalid();
    }
    final active = object['activeOperation'] == null
        ? null
        : IdentityProviderReleaseOperation.parse(object['activeOperation']);
    final confirmed = object['confirmedOperation'] == null
        ? null
        : IdentityProviderReleaseOperation.parse(object['confirmedOperation']);
    if (active?.terminal == true ||
        confirmed != null && confirmed.state != 'APPLIED_CLOSED') _invalid();
    return IdentityProviderReleaseStatus(
        environment,
        _number(object['runtimeRevision']),
        _flag(object['observationReady']),
        _flag(object['executorReady']),
        active,
        confirmed,
        List.unmodifiable(targets),
        _runtime(object));
  }
}

class IdentityProviderRuntimeInstance {
  final String instanceId, state, reasonCode;
  final int? observedAt;
  const IdentityProviderRuntimeInstance(
      this.instanceId, this.state, this.reasonCode, this.observedAt);
  factory IdentityProviderRuntimeInstance.parse(Object? value) {
    final object =
        _object(value, {'instanceId', 'state', 'reasonCode', 'observedAt'});
    return IdentityProviderRuntimeInstance(
        _text(object['instanceId'], maximum: 64),
        _enum(object['state'], {'CONFIRMED', 'UNAVAILABLE', 'MISMATCH'}),
        _text(object['reasonCode']),
        object['observedAt'] == null ? null : _number(object['observedAt']));
  }
}

class IdentityProviderRuntimeCheck {
  final String id, operationId, versionId, state, reasonCode, runtimeStatus;
  final int createdAt;
  final int? completedAt;
  final List<IdentityProviderRuntimeInstance> instances;
  const IdentityProviderRuntimeCheck(
      this.id,
      this.operationId,
      this.versionId,
      this.state,
      this.reasonCode,
      this.createdAt,
      this.completedAt,
      this.instances,
      this.runtimeStatus);
  factory IdentityProviderRuntimeCheck.parse(Object? value) {
    final object = _object(value, {
      'id',
      'operationId',
      'versionId',
      'state',
      'reasonCode',
      'createdAt',
      'completedAt',
      'instances',
      'runtimeStatus',
      'salesAllowed'
    });
    final raw = object['instances'];
    if (raw is! List || raw.length > 32) _invalid();
    final instances =
        raw.map(IdentityProviderRuntimeInstance.parse).toList(growable: false);
    final state = _enum(
        object['state'], {'CHECKING', 'CONFIRMED', 'UNAVAILABLE', 'MISMATCH'});
    if (instances.map((item) => item.instanceId).toSet().length !=
            instances.length ||
        state == 'CONFIRMED' &&
            (instances.isEmpty ||
                instances.any((item) => item.state != 'CONFIRMED'))) _invalid();
    final runtime = _runtime(object);
    if (state == 'CONFIRMED' && runtime != 'APPLIED_CLOSED') _invalid();
    return IdentityProviderRuntimeCheck(
        _id(object['id']),
        _id(object['operationId']),
        _id(object['versionId']),
        state,
        _text(object['reasonCode']),
        _number(object['createdAt']),
        object['completedAt'] == null ? null : _number(object['completedAt']),
        List.unmodifiable(instances),
        runtime);
  }
}
