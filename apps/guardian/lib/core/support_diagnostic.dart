import 'api.dart';
import 'device_diagnostic.dart';
import 'support.dart';

class SupportDiagnostic {
  final SupportGrant grant;
  final String correlationId;
  final int generatedAt;
  final ({
    DiagnosticVersion os,
    DiagnosticVersion agent,
    DiagnosticVersion server
  })? versions;
  final DiagnosticDeviceState? device;
  final List<DiagnosticCapability>? capabilities;
  final List<DiagnosticConfiguration>? configurations;
  final int? omittedCapabilityCount;
  SupportDiagnostic._(
      this.grant,
      this.correlationId,
      this.generatedAt,
      this.versions,
      this.device,
      List<DiagnosticCapability>? capabilities,
      List<DiagnosticConfiguration>? configurations,
      this.omittedCapabilityCount)
      : capabilities =
            capabilities == null ? null : List.unmodifiable(capabilities),
        configurations =
            configurations == null ? null : List.unmodifiable(configurations);
  static SupportDiagnostic parse(Object? input, SupportGrant grant) {
    try {
      final o = supportObject(input), scope = supportObject(o['scope']);
      final generated = supportInteger(o['generatedAt']);
      if (o['schemaVersion'] != 1 ||
          o['evidenceStatus'] != 'DEVICE_REPORTS_NOT_EXECUTION_PROOF' ||
          supportId(o['grantId']) != grant.id ||
          supportInteger(o['grantExpiresAt']) != grant.expiresAt ||
          supportId(scope['tenantId']) != grant.tenantId ||
          supportId(scope['deviceId']) != grant.deviceId ||
          supportId(scope['registrationId']) != grant.registrationId ||
          parseSupportTypes(o['diagnosticTypes']).join(',') !=
              grant.diagnosticTypes.join(',') ||
          !grant.withinTerm(generated) ||
          generated < grant.createdAt ||
          generated > 9007199254710991) invalidSupport();
      final status = grant.diagnosticTypes.contains('DEVICE_STATUS'),
          caps = grant.diagnosticTypes.contains('CAPABILITIES'),
          configs = grant.diagnosticTypes.contains('CONFIGURATION_METADATA');
      if ((!status && (o['versions'] != null || o['device'] != null)) ||
          (!caps &&
              (o['capabilities'] != null ||
                  o['omittedCapabilityCount'] != null)) ||
          (!configs && o['configurations'] != null)) invalidSupport();
      final versions = status ? supportObject(o['versions']) : null;
      final device =
          status ? parseDiagnosticDeviceState(o['device'], generated) : null;
      if (device != null && device.state != 'ACTIVE') invalidSupport();
      List<DiagnosticCapability>? capabilities;
      List<DiagnosticConfiguration>? configurations;
      int? omitted;
      if (caps) {
        final values = o['capabilities'];
        if (values is! List || values.length > 8) invalidSupport();
        capabilities =
            values.map((v) => parseDiagnosticCapability(v, generated)).toList();
        omitted = supportInteger(o['omittedCapabilityCount']);
        if (omitted > 64 ||
            capabilities.map((v) => v.key).toSet().length !=
                capabilities.length) invalidSupport();
      }
      if (configs) {
        final values = o['configurations'];
        if (values is! List || values.length > 100) invalidSupport();
        configurations = values
            .map((v) => parseDiagnosticConfiguration(v, generated))
            .toList();
        if (configurations.map((v) => v.id).toSet().length !=
                configurations.length ||
            configurations.map((v) => v.policyId).toSet().length !=
                configurations.length) invalidSupport();
      }
      return SupportDiagnostic._(
          grant,
          supportId(o['correlationId']),
          generated,
          versions == null
              ? null
              : (
                  os: parseDiagnosticVersion(versions['os']),
                  agent: parseDiagnosticVersion(versions['agent']),
                  server: parseDiagnosticVersion(versions['server'])
                ),
          device,
          capabilities,
          configurations,
          omitted);
    } on ApiFailure {
      invalidSupport();
    }
  }
}
