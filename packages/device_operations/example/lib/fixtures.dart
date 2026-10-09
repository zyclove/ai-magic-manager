import 'package:device_operations/device_operations.dart';

// Explicit component fixtures. This gateway never performs HTTP or device I/O.
const scenarioLabels = {
  'preview': '后果预览与确认',
  'timeout': '首次提交超时与原键核对',
  'reported': '设备自报清理（未独立验证）'
};
const _tenant = '00000000-0000-4000-8000-000000000101';
const _device = '00000000-0000-4000-8000-000000000102';
const _registration = '00000000-0000-4000-8000-000000000103';
const _preview = '00000000-0000-4000-8000-000000000104';
const _operation = '00000000-0000-4000-8000-000000000105';
const _command = '00000000-0000-4000-8000-000000000106';
ExitScope fixtureScope() => ExitScope(
    actorId: 'fixture-actor',
    tenantId: _tenant,
    deviceId: _device,
    registrationId: _registration,
    role: 'OWNER');

class FixtureJournal implements ExitJournal {
  PendingExit? value;
  @override
  Future<PendingExit?> read(ExitScope scope) async => value;
  @override
  Future<void> write(ExitScope scope, PendingExit pending) async {
    value = pending;
  }

  @override
  Future<void> clear(ExitScope scope) async {
    value = null;
  }
}

class FixtureGateway implements ExitGateway {
  final String scenario;
  final DateTime issued = DateTime.now().toUtc();
  String state = 'WAITING_FOR_AGENT';
  int version = 1;
  bool submitted = false;
  FixtureGateway(this.scenario) {
    if (scenario == 'reported') {
      state = 'CLEANUP_REPORTED';
      submitted = true;
    }
  }
  ExitOperation _result() => ExitOperation.fromJson({
        'id': _operation,
        'deviceId': _device,
        'registrationId': _registration,
        'commandId': _command,
        'action': 'AGENT_UNENROLL',
        'state': state,
        'remoteAccess': 'REVOKED',
        'localEvidence':
            state == 'CLEANUP_REPORTED' ? 'DEVICE_REPORT_UNVERIFIED' : 'NONE',
        'reasonCode': null,
        'issuedAt': issued.millisecondsSinceEpoch,
        'notAfter': issued.add(const Duration(days: 1)).millisecondsSinceEpoch,
        'version': version,
      });
  @override
  Future<DeviceSnapshot> device(ExitScope scope) async =>
      DeviceSnapshot.fromJson({
        'id': _device,
        'registrationId': _registration,
        'displayName': '测试学习平板',
        'managementMode': 'BYOD',
        'state': submitted ? 'REVOKED' : 'ACTIVE',
        'version': 7,
      });
  @override
  Future<ExitPreview> preview(ExitScope scope, int deviceVersion) async =>
      ExitPreview.fromJson({
        'id': _preview,
        'deviceId': _device,
        'registrationId': _registration,
        'deviceVersion': 7,
        'action': 'AGENT_UNENROLL',
        'hash':
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
        'consequences': consequenceLabels.keys.toList(),
        'limitations': limitationLabels.keys.toList(),
      });
  @override
  Future<ExitOperation> confirm(ExitScope scope,
      {required String previewId,
      required String previewHash,
      required int deviceVersion,
      required String key}) async {
    final wasSubmitted = submitted;
    submitted = true;
    if (scenario == 'timeout' && !wasSubmitted) {
      throw const ExitFailure('NETWORK_TIMEOUT', '测试连接超时，服务端结果待核对。',
          outcomeUnknown: true);
    }
    return _result();
  }

  @override
  Future<ExitOperation> operation(ExitScope scope, String operationId) async =>
      _result();
  @override
  Future<List<ExitOperation>> operations(ExitScope scope) async =>
      submitted ? [_result()] : [];
  @override
  Future<ExitOperation> cancel(ExitScope scope,
      {required String operationId,
      required int version,
      required String key}) async {
    state = 'CLEANUP_CANCELLED';
    this.version++;
    return _result();
  }
}
