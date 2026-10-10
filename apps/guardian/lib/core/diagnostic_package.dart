import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'api.dart';
import 'device_diagnostic.dart';
import 'support.dart';
import 'support_diagnostic.dart';

const diagnosticPackageStates = {
  'QUEUED',
  'RUNNING',
  'READY',
  'CANCELLED',
  'EXPIRED',
  'REVOKED',
  'FAILED'
};
const diagnosticPackageFailures = {
  'DIAGNOSTIC_TOO_LARGE',
  'DIAGNOSTIC_SOURCE_INVALID',
  'DIAGNOSTIC_SERIALIZATION_FAILED',
  'DIAGNOSTIC_PACKAGE_TEMPORARY_FAILURE',
  'DIAGNOSTIC_PACKAGE_ATTEMPTS_EXHAUSTED'
};
Never invalidDiagnosticPackage() =>
    throw const ApiFailure(502, 'INVALID_DIAGNOSTIC_PACKAGE_RESPONSE');
Json _object(Object? input, Set<String> keys) {
  final value = supportObject(input);
  if (value.length != keys.length || !value.keys.every(keys.contains))
    invalidDiagnosticPackage();
  return value;
}

int _time(Object? value) {
  final at = supportInteger(value);
  if (at > 8640000000000000) invalidDiagnosticPackage();
  return at;
}

String _mode(Object? value) => value == 'ADMIN' || value == 'SUPPORT_GRANT'
    ? value as String
    : invalidDiagnosticPackage();
bool _typesEqual(List<String> first, List<String> second) =>
    first.join(',') == second.join(',');

class DiagnosticPackage {
  final String id,
      tenantId,
      requesterActorId,
      deviceId,
      registrationId,
      accessMode,
      state;
  final String? grantId, sha256, failureCode;
  final List<String> diagnosticTypes;
  final int version, createdAt, updatedAt, expiresAt;
  final int? generatedAt, byteCount;
  DiagnosticPackage._(
      this.id,
      this.tenantId,
      this.requesterActorId,
      this.deviceId,
      this.registrationId,
      this.accessMode,
      this.grantId,
      this.diagnosticTypes,
      this.state,
      this.version,
      this.createdAt,
      this.updatedAt,
      this.expiresAt,
      this.generatedAt,
      this.byteCount,
      this.sha256,
      this.failureCode);
  static DiagnosticPackage parse(Object? input,
      {required String actor, required String mode, String? tenant}) {
    try {
      final o = _object(input, {
        'id',
        'tenantId',
        'requesterActorId',
        'deviceId',
        'registrationId',
        'accessMode',
        'grantId',
        'diagnosticTypes',
        'state',
        'version',
        'createdAt',
        'updatedAt',
        'expiresAt',
        'generatedAt',
        'byteCount',
        'sha256',
        'failureCode'
      });
      if (!diagnosticPackageStates.contains(o['state']))
        invalidDiagnosticPackage();
      final types = parseSupportTypes(o['diagnosticTypes']),
          state = o['state'] as String,
          access = _mode(o['accessMode']);
      final value = DiagnosticPackage._(
          supportId(o['id']),
          supportId(o['tenantId']),
          supportText(o['requesterActorId'], 255),
          supportId(o['deviceId']),
          supportId(o['registrationId']),
          access,
          o['grantId'] == null ? null : supportId(o['grantId']),
          types,
          state,
          supportInteger(o['version']),
          _time(o['createdAt']),
          _time(o['updatedAt']),
          _time(o['expiresAt']),
          o['generatedAt'] == null ? null : _time(o['generatedAt']),
          o['byteCount'] == null
              ? null
              : supportInteger(o['byteCount'], minimum: 1),
          o['sha256'] is String ? o['sha256'] as String : null,
          o['failureCode'] is String ? o['failureCode'] as String : null);
      if (value.requesterActorId != actor ||
          value.accessMode != mode ||
          (tenant != null && value.tenantId != tenant) ||
          value.updatedAt < value.createdAt ||
          value.expiresAt <= value.createdAt ||
          value.expiresAt - value.createdAt > 1800000 ||
          (access == 'ADMIN'
              ? (value.grantId != null || !_typesEqual(types, supportTypes))
              : value.grantId == null)) invalidDiagnosticPackage();
      if (o['sha256'] != value.sha256 ||
          o['failureCode'] != value.failureCode ||
          (value.failureCode != null &&
              !diagnosticPackageFailures.contains(value.failureCode)) ||
          (state == 'FAILED' && value.failureCode == null))
        invalidDiagnosticPackage();
      if (state == 'READY') {
        if (value.generatedAt == null ||
            value.generatedAt! < value.createdAt ||
            value.generatedAt! >= value.expiresAt ||
            value.byteCount == null ||
            value.byteCount! > 512 * 1024 ||
            value.sha256 == null ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(value.sha256!))
          invalidDiagnosticPackage();
      } else if (value.generatedAt != null ||
          value.byteCount != null ||
          value.sha256 != null) {
        invalidDiagnosticPackage();
      }
      return value;
    } catch (_) {
      invalidDiagnosticPackage();
    }
  }

  bool readyAt(int now) => state == 'READY' && expiresAt > now;
  bool pendingAt(int now) =>
      {'QUEUED', 'RUNNING'}.contains(state) && expiresAt > now;
  bool activeAt(int now) =>
      {'QUEUED', 'RUNNING', 'READY'}.contains(state) && expiresAt > now;
  String stateAt(int now) =>
      {'QUEUED', 'RUNNING', 'READY'}.contains(state) && expiresAt <= now
          ? 'EXPIRED'
          : state;
  void validateUpdate(DiagnosticPackage next) {
    if (next.id != id ||
        next.tenantId != tenantId ||
        next.requesterActorId != requesterActorId ||
        next.deviceId != deviceId ||
        next.registrationId != registrationId ||
        next.accessMode != accessMode ||
        next.grantId != grantId ||
        !_typesEqual(next.diagnosticTypes, diagnosticTypes) ||
        next.createdAt != createdAt ||
        next.expiresAt != expiresAt ||
        next.version < version ||
        next.updatedAt < updatedAt) invalidDiagnosticPackage();
    if (!{'QUEUED', 'RUNNING', 'READY'}.contains(state) && next.state != state)
      invalidDiagnosticPackage();
    if (state == 'READY' &&
        ({'QUEUED', 'RUNNING'}.contains(next.state) ||
            (next.state == 'READY' &&
                (next.generatedAt != generatedAt ||
                    next.byteCount != byteCount ||
                    next.sha256 != sha256)))) invalidDiagnosticPackage();
  }
}

class DiagnosticPackageDraft {
  final String deviceId, registrationId, key;
  final int? deviceVersion;
  final SupportGrant? grant;
  DiagnosticPackageDraft.admin(
      {required this.deviceId,
      required this.registrationId,
      required int deviceVersion,
      String? key})
      : deviceVersion = supportInteger(deviceVersion),
        grant = null,
        key = key ?? requestId() {
    supportId(deviceId);
    supportId(registrationId);
    supportText(this.key, 128);
  }
  DiagnosticPackageDraft.received(SupportGrant value, {String? key})
      : deviceId = value.deviceId,
        registrationId = value.registrationId,
        deviceVersion = null,
        grant = value,
        key = key ?? requestId() {
    supportText(this.key, 128);
  }
  String get mode => grant == null ? 'ADMIN' : 'SUPPORT_GRANT';
  String? get grantId => grant?.id;
  List<String> get diagnosticTypes =>
      List.unmodifiable(grant?.diagnosticTypes ?? supportTypes);
  Json? get body => grant == null ? {'registrationId': registrationId} : null;
  void validateResult(DiagnosticPackage job) {
    if (job.accessMode != mode ||
        job.deviceId != deviceId ||
        job.registrationId != registrationId ||
        job.grantId != grantId ||
        !_typesEqual(job.diagnosticTypes, diagnosticTypes) ||
        (grant != null &&
            (job.tenantId != grant!.tenantId ||
                job.expiresAt > grant!.expiresAt))) invalidDiagnosticPackage();
  }
}

/// Validate the exact bytes that will be handed to the browser, including all nested keys.
Uint8List validateDiagnosticPackageDownload(
    Uint8List bytes, DiagnosticPackage job,
    {SupportGrant? grant, required int now}) {
  try {
    if (!job.readyAt(now) ||
        bytes.isEmpty ||
        bytes.length > 512 * 1024 ||
        bytes.length != job.byteCount ||
        sha256.convert(bytes).toString() != job.sha256)
      invalidDiagnosticPackage();
    final o = _object(jsonDecode(utf8.decode(bytes)), {
      'schemaVersion',
      'type',
      'jobId',
      'accessMode',
      'diagnosticTypes',
      'generatedAt',
      'expiresAt',
      'diagnostic'
    });
    if (o['schemaVersion'] != 1 ||
        o['type'] != 'DEVICE_DIAGNOSTIC' ||
        o['jobId'] != job.id ||
        o['accessMode'] != job.accessMode ||
        o['generatedAt'] != job.generatedAt ||
        o['expiresAt'] != job.expiresAt ||
        !_typesEqual(
            parseSupportTypes(o['diagnosticTypes']), job.diagnosticTypes))
      invalidDiagnosticPackage();
    final received = job.accessMode == 'SUPPORT_GRANT',
        inner = _object(o['diagnostic'], {
          'schemaVersion',
          'generatedAt',
          'correlationId',
          'scope',
          'versions',
          'device',
          'capabilities',
          'omittedCapabilityCount',
          'configurations',
          'evidenceStatus',
          if (received) ...['grantId', 'grantExpiresAt', 'diagnosticTypes']
        });
    _diagnosticKeys(inner);
    final generated = _time(inner['generatedAt']);
    if (generated < job.generatedAt! || generated >= job.expiresAt)
      invalidDiagnosticPackage();
    if (received) {
      if (grant == null) invalidDiagnosticPackage();
      validateDiagnosticPackageGrant(job, grant, now);
      SupportDiagnostic.parse(inner, grant);
    } else {
      if (grant != null) invalidDiagnosticPackage();
      final diagnostic = DeviceDiagnostic.parse(inner,
          tenantId: job.tenantId,
          deviceId: job.deviceId,
          registrationId: job.registrationId);
      if (diagnostic.state != 'ACTIVE') invalidDiagnosticPackage();
    }
    return Uint8List.fromList(bytes);
  } catch (_) {
    invalidDiagnosticPackage();
  }
}

void validateDiagnosticPackageGrant(
    DiagnosticPackage job, SupportGrant grant, int now) {
  if (!grant.withinTerm(now) ||
      grant.id != job.grantId ||
      grant.tenantId != job.tenantId ||
      grant.deviceId != job.deviceId ||
      grant.registrationId != job.registrationId ||
      grant.recipientActorId != job.requesterActorId ||
      grant.createdAt > job.createdAt ||
      grant.expiresAt < job.expiresAt ||
      !_typesEqual(grant.diagnosticTypes, job.diagnosticTypes))
    invalidDiagnosticPackage();
}

void _diagnosticKeys(Json o) {
  _object(o['scope'], {'tenantId', 'deviceId', 'registrationId'});
  if (o['versions'] != null) {
    final versions = _object(o['versions'], {'os', 'agent', 'server'});
    for (final value in versions.values) {
      _object(value, {'value', 'status'});
    }
  }
  if (o['device'] != null)
    _object(o['device'], {
      'platform',
      'state',
      'managementMode',
      'controlLevel',
      'observationStatus',
      'lastHeartbeatAt'
    });
  if (o['capabilities'] != null) {
    final list = o['capabilities'];
    if (list is! List || list.length > 8) invalidDiagnosticPackage();
    for (final value in list) {
      _object(value, {
        'key',
        'reportedSupported',
        'grantStatus',
        'evidenceSource',
        'checkedAt',
        'status',
        'limitationCode'
      });
    }
  }
  if (o['configurations'] != null) {
    final list = o['configurations'];
    if (list is! List || list.length > 100) invalidDiagnosticPackage();
    for (final value in list) {
      _object(value, {
        'id',
        'policyId',
        'versionId',
        'sourceSequence',
        'action',
        'deliveryState',
        'policyHash',
        'configurationHash',
        'issuedAt',
        'deliveryExpiresAt',
        'receivedReportedAt',
        'storedReportedAt',
        'rejectionCode'
      });
    }
  }
}

String diagnosticPackageState(String value) =>
    const {
      'QUEUED': '等待生成',
      'RUNNING': '正在生成',
      'READY': '可以下载',
      'CANCELLED': '已取消并清除',
      'EXPIRED': '已到期',
      'REVOKED': '权限已失效',
      'FAILED': '生成失败'
    }[value] ??
    '状态无法识别';
String diagnosticPackageError(ApiFailure failure) => switch (failure.code) {
      'DIAGNOSTIC_PACKAGE_UNAVAILABLE' => '诊断包暂不可用，请联系管理员检查服务配置，或稍后重试。',
      'DIAGNOSTIC_PACKAGE_NOT_READY' => '诊断包尚未准备好，请刷新任务状态。',
      'DIAGNOSTIC_PACKAGE_EXPIRED' => '诊断包已到期，无法继续下载。需要时请重新创建。',
      'DIAGNOSTIC_PACKAGE_CAPACITY_REACHED' => '未结束的诊断包较多，请先取消不再需要的任务。',
      'INVALID_DIAGNOSTIC_PACKAGE_RESPONSE' => '诊断包与当前账号或范围不一致，已阻止保存。请刷新后重试。',
      'DIAGNOSTIC_PACKAGE_TEMPORARY_FAILURE' => '生成暂时遇到问题，服务会按原任务重试。',
      'DIAGNOSTIC_PACKAGE_ATTEMPTS_EXHAUSTED' => '多次生成未成功，请稍后重新创建诊断包。',
      _ => supportErrorMessage(failure)
    };
