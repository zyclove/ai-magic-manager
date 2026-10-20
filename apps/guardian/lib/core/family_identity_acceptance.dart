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

int _number(Object? value) {
  if (value is! int || value < 0 || value > 9007199254740991) _invalid();
  return value;
}

String? _optionalId(Object? value) {
  if (value == null) return null;
  if (value is! String || !isIdentityProviderId(value)) _invalid();
  return value;
}

List<IdentityProviderCheck> _checks(Object? value,
    {bool requiredCases = false}) {
  if (value is! List || value.length > 64) _invalid();
  final result = value.map(IdentityProviderCheck.parse).toList(growable: false);
  final ids = result.map((item) => item.id).toSet();
  if (ids.length != result.length ||
      requiredCases &&
          (ids.length != identityRequiredAcceptanceCases.length ||
              !ids.containsAll(identityRequiredAcceptanceCases) ||
              result.any((item) => item.status != 'PENDING'))) _invalid();
  return List.unmodifiable(result);
}

/// Read-only readiness. This release cannot accept real passes or enable sales.
class IdentityProviderAcceptanceStatus {
  final String environmentId, status, nextAction;
  final String? versionId, confirmedOperationId;
  final int runtimeRevision, passedCount, requiredCount;
  final IdentityProviderAcceptanceRun? latestRun;
  final List<IdentityProviderCheck> readinessChecks, checks, salesChecks;

  const IdentityProviderAcceptanceStatus(
      this.environmentId,
      this.versionId,
      this.confirmedOperationId,
      this.runtimeRevision,
      this.status,
      this.nextAction,
      this.passedCount,
      this.requiredCount,
      this.latestRun,
      this.readinessChecks,
      this.checks,
      this.salesChecks);

  factory IdentityProviderAcceptanceStatus.parse(Object? value) {
    final object = _object(value, {
      'environmentId',
      'versionId',
      'confirmedOperationId',
      'runtimeRevision',
      'status',
      'nextAction',
      'passedCount',
      'requiredCount',
      'latestRun',
      'readinessChecks',
      'checks',
      'salesGate'
    });
    final environment = object['environmentId'];
    if (environment is! String ||
        !isIdentityProviderEnvironment(environment) ||
        !const {'BLOCKED', 'PENDING', 'STALE'}.contains(object['status']) ||
        !const {
          'CONFIGURE',
          'CHECK_CONFIGURATION',
          'PUBLISH_CONFIGURATION',
          'CHECK_RUNTIME',
          'REGISTER_RUN',
          'PREPARE_PILOT'
        }.contains(object['nextAction']) ||
        object['passedCount'] != 0 ||
        object['requiredCount'] != identityRequiredAcceptanceCases.length) {
      _invalid();
    }
    final gate = _object(object['salesGate'], {'allowed', 'status', 'checks'});
    if (gate['allowed'] != false || gate['status'] != 'CLOSED') _invalid();
    final salesChecks = _checks(gate['checks']);
    if (salesChecks.isEmpty ||
        salesChecks.every((check) => check.status == 'READY')) _invalid();
    final run = object['latestRun'] == null
        ? null
        : IdentityProviderAcceptanceRun.parse(object['latestRun']);
    if (run != null && run.environmentId != environment) _invalid();
    return IdentityProviderAcceptanceStatus(
        environment,
        _optionalId(object['versionId']),
        _optionalId(object['confirmedOperationId']),
        _number(object['runtimeRevision']),
        object['status'] as String,
        object['nextAction'] as String,
        0,
        identityRequiredAcceptanceCases.length,
        run,
        _checks(object['readinessChecks']),
        _checks(object['checks'], requiredCases: true),
        salesChecks);
  }
}
