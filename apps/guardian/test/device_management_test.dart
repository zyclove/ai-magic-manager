import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/device_management.dart';

const deviceId = '11111111-1111-4111-8111-111111111111';
const subjectId = '22222222-2222-4222-8222-222222222222';
const registrationId = '33333333-3333-4333-8333-333333333333';
const root = '/tenants/44444444-4444-4444-8444-444444444444';
Json record({String state = 'ACTIVE'}) => {
      'id': deviceId,
      'subjectId': subjectId,
      'registrationId': registrationId,
      'displayName': '学习平板',
      'platform': 'ANDROID',
      'osVersion': '14',
      'state': state,
      'managementMode':
          state == 'AWAITING_CONFIRMATION' ? 'UNVERIFIED' : 'BYOD',
      'controlLevel': state == 'ACTIVE' ? 'LIMITED' : 'NONE',
      'lastHeartbeatAt': 1700000000000,
      'observationStatus': state == 'REVOKED' ? 'REVOKED' : 'RECENT',
      'keyThumbprint': 'a' * 43,
      'version': 0
    };
Json inventory() => {
      'deviceId': deviceId,
      'registrationId': registrationId,
      'sequence': 1,
      'receivedAt': 1700000000000,
      'visibility': 'VISIBLE_PACKAGES',
      'observationStatus': 'RECENT',
      'evidenceStatus': 'AGENT_REPORTED_UNVERIFIED',
      'applications': [
        {
          'packageName': 'com.example.study',
          'displayName': '学习应用',
          'profile': 'PRIMARY',
          'signingDigests': ['b' * 64],
          'versionCode': 3,
          'systemApplication': false
        }
      ]
    };
Json capability() => {
      'items': [
        {
          'key': 'usage.report',
          'reportedSupported': true,
          'grantStatus': 'GRANTED',
          'evidenceSource': 'AGENT_REPORT',
          'checkedAt': 1700000000000,
          'status': 'UNVERIFIED',
          'effectiveSupported': false,
          'limitationCode': 'EVIDENCE_NOT_CERTIFIED'
        }
      ]
    };
final invalid =
    throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 502));

class Fixture {
  bool current = true;
  bool unknownWrite = false;
  String state = 'ACTIVE';
  final requests = <http.Request>[];
  Future<http.Response> Function(http.Request)? intercept;
  late final api = Api(
      () async => MockClient((request) async {
            requests.add(request);
            if (intercept != null) return intercept!(request);
            if (request.method == 'POST') {
              if (unknownWrite) {
                throw http.ClientException('fixture connection lost');
              }
              state = 'REVOKED';
              return http.Response('', 204);
            }
            final value = request.url.path.endsWith('/capabilities')
                ? capability()
                : request.url.path.endsWith('/application-inventory')
                    ? inventory()
                    : record(state: state);
            return http.Response(jsonEncode(value), 200,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }),
      baseUrl: 'http://mock.invalid/api/v1');
  late final repository = DeviceManagementRepository(
      api: api, root: root, deviceId: deviceId, current: () => current);
  late final controller = DeviceManagementController(
      repository: repository, canWrite: true, canReadApplications: true);
}

void main() {
  test('device DTO keeps registration, state and observation as separate facts',
      () {
    final value = DeviceManagementRecord.fromJson(record(), deviceId: deviceId);
    expect(value.id, deviceId);
    expect(value.registrationId, registrationId);
    expect(value.state, 'ACTIVE');
    expect(value.observationStatus, 'RECENT');
    expect(value.toJson(), record());
  });
  for (final field in [
    'id',
    'subjectId',
    'registrationId',
    'displayName',
    'platform',
    'osVersion',
    'state',
    'managementMode',
    'controlLevel',
    'observationStatus',
    'keyThumbprint',
    'version'
  ]) {
    test('device DTO rejects missing $field', () {
      final value = record()..remove(field);
      expect(() => DeviceManagementRecord.fromJson(value, deviceId: deviceId),
          invalid);
    });
  }
  test('device DTO rejects another device and invalid numeric values', () {
    expect(
        () => DeviceManagementRecord.fromJson(record()..['id'] = subjectId,
            deviceId: deviceId),
        invalid);
    for (final value in [-1, 9007199254740992, 1.5, '1']) {
      expect(
          () => DeviceManagementRecord.fromJson(record()..['version'] = value,
              deviceId: deviceId),
          invalid);
    }
  });
  test('device DTO permits absent heartbeat evidence without claiming zero',
      () {
    final value = DeviceManagementRecord.fromJson(
        record()..['lastHeartbeatAt'] = null,
        deviceId: deviceId);
    expect(value.lastHeartbeatAt, isNull);
  });
  test('capabilities do not promote an agent grant to effective support', () {
    final value = DeviceManagementCapabilities.fromJson(capability());
    expect(value.items.single.reportedSupported, isTrue);
    expect(value.items.single.effectiveSupported, isFalse);
    expect(value.effectiveCount, 0);
    expect(() => value.items.clear(), throwsUnsupportedError);
  });
  test(
      'capabilities reject duplicate identities and malformed support booleans',
      () {
    final value = capability();
    (value['items'] as List).add((value['items'] as List).single);
    expect(() => DeviceManagementCapabilities.fromJson(value), invalid);
    final malformed = capability();
    (malformed['items'] as List).single['effectiveSupported'] = 'true';
    expect(() => DeviceManagementCapabilities.fromJson(malformed), invalid);
  });
  test('inventory is device and registration bound and immutable', () {
    final value = DeviceManagementInventory.fromJson(inventory(),
        deviceId: deviceId, registrationId: registrationId);
    expect(value.applications.single.packageName, 'com.example.study');
    expect(() => value.applications.clear(), throwsUnsupportedError);
    expect(() => value.applications.single.signingDigests.clear(),
        throwsUnsupportedError);
    expect(
        () => DeviceManagementInventory.fromJson(
            inventory()..['registrationId'] = subjectId,
            deviceId: deviceId,
            registrationId: registrationId),
        invalid);
  });
  test('initial overview reads only the device and sections load in place',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    expect(f.requests.length, 1);
    expect(f.controller.device?.displayName, '学习平板');
    final overviewAt = f.controller.updatedAt;
    await f.controller.selectSection(DeviceManagementSection.overview);
    expect(f.requests.length, 1);
    expect(f.controller.updatedAt, same(overviewAt));
    await f.controller.selectSection(DeviceManagementSection.capabilities);
    expect(f.controller.section, DeviceManagementSection.capabilities);
    expect(f.requests.last.url.path, endsWith('/capabilities'));
    expect(f.controller.device, isNotNull);
    final capabilityReads = f.requests.length;
    final capabilitiesAt = f.controller.sectionUpdatedAt;
    await f.controller.selectSection(DeviceManagementSection.capabilities);
    expect(f.requests.length, capabilityReads);
    expect(f.controller.sectionUpdatedAt, same(capabilitiesAt));
    await f.controller.refresh();
    expect(f.requests.length, capabilityReads + 2);
    expect(f.requests.last.url.path, endsWith('/capabilities'));
    await f.controller.selectSection(DeviceManagementSection.applications);
    expect(f.requests.last.url.path, endsWith('/application-inventory'));
    expect(f.controller.inventory, isNotNull);
  });
  test(
      'read 403 hides all previously read private data and action availability',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    await f.controller.selectSection(DeviceManagementSection.capabilities);
    f.intercept = (_) async =>
        http.Response(jsonEncode({'errorCode': 'SCOPE_DENIED'}), 403);
    await f.controller.refresh();
    expect(f.controller.device, isNull);
    expect(f.controller.capabilities, isNull);
    expect(f.controller.inventory, isNull);
    expect(f.controller.canRevoke, isFalse);
  });
  test('transient reads retain previous facts without advancing last read time',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    final last = f.controller.updatedAt;
    f.intercept =
        (_) async => throw http.ClientException('fixture read failure');
    await f.controller.refresh();
    expect(f.controller.device?.id, deviceId);
    expect(f.controller.error, isNotNull);
    expect(f.controller.updatedAt, last);
  });
  test(
      'scope loss is sticky across A B A and a late read cannot resurrect data',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    final pending = Completer<http.Response>();
    f.intercept = (_) => pending.future;
    final refresh = f.controller.refresh();
    await Future<void>.delayed(Duration.zero);
    f.current = false;
    f.controller.checkScope();
    f.current = true;
    f.controller.checkScope();
    pending.complete(http.Response(jsonEncode(record()), 200,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    await refresh;
    expect(f.controller.hasAccess, isFalse);
    expect(f.controller.device, isNull);
    expect(f.controller.canRevoke, isFalse);
  });
  test('cancelling cloud revoke confirmation sends no write', () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    await f.controller.revoke((_) async => false);
    expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
    expect(f.controller.canRevoke, isTrue);
  });
  test('scope change while confirming cloud revoke prevents the write',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    await f.controller.revoke((_) async {
      f.current = false;
      f.controller.checkScope();
      return true;
    });
    expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
    expect(f.controller.device, isNull);
  });
  test('cloud revoke success reads facts without closing the detail', () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    await f.controller.revoke((_) async => true);
    expect(f.requests.where((r) => r.method == 'POST').length, 1);
    expect(f.controller.device?.state, 'REVOKED');
    expect(f.controller.canRevoke, isFalse);
    expect(f.controller.error, isNull);
    expect(f.controller.revokeResultUnknown, isFalse);
  });
  test('unknown revoke never replays POST and ACTIVE does not prove failure',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    f.unknownWrite = true;
    await f.controller.revoke((_) async => true);
    expect(f.controller.revokeResultUnknown, isTrue);
    await f.controller.refresh();
    expect(f.controller.device?.state, 'ACTIVE');
    expect(f.controller.revokeResultUnknown, isTrue);
    await f.controller.revoke((_) async => true);
    expect(f.requests.where((r) => r.method == 'POST').length, 1);
    f.state = 'REVOKED';
    await f.controller.refresh();
    expect(f.controller.revokeResultUnknown, isFalse);
    expect(f.controller.device?.state, 'REVOKED');
  });
  test('write MFA rejection leaves valid readable device facts available',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    f.intercept = (request) async => request.method == 'POST'
        ? http.Response(jsonEncode({'errorCode': 'REAUTH_REQUIRED'}), 401)
        : http.Response(jsonEncode(record()), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
    await f.controller.revoke((_) async => true);
    expect(f.controller.device?.id, deviceId);
    expect(f.controller.error, isA<ApiFailure>());
    expect(f.controller.revokeResultUnknown, isFalse);
  });
  test('returning from a nested action keeps details open and re-reads facts',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    var opened = 0;
    await f.controller.runAction((value) async {
      expect(value.id, deviceId);
      opened++;
    });
    expect(opened, 1);
    expect(f.requests.length, 2);
    expect(f.controller.device, isNotNull);
  });
  test('read-only nested actions retain section facts and last read times',
      () async {
    for (final section in [
      DeviceManagementSection.capabilities,
      DeviceManagementSection.applications
    ]) {
      final f = Fixture();
      addTearDown(f.controller.dispose);
      await f.controller.initialize();
      await f.controller.selectSection(section);
      final device = f.controller.device;
      final capabilities = f.controller.capabilities;
      final inventory = f.controller.inventory;
      final updatedAt = f.controller.updatedAt;
      final sectionUpdatedAt = f.controller.sectionUpdatedAt;
      final readCount = f.requests.length;
      var opened = 0;
      expect(sectionUpdatedAt, isNotNull);
      expect(
          section == DeviceManagementSection.capabilities
              ? capabilities
              : inventory,
          isNotNull);

      await f.controller.runAction((value) async {
        expect(value, same(device));
        opened++;
      }, refreshAfter: false);

      expect(opened, 1);
      expect(f.controller.device, same(device));
      expect(f.controller.section, section);
      expect(f.controller.capabilities, same(capabilities));
      expect(f.controller.inventory, same(inventory));
      expect(f.controller.updatedAt, same(updatedAt));
      expect(f.controller.sectionUpdatedAt, same(sectionUpdatedAt));
      expect(f.requests.length, readCount);
      expect(f.controller.busy, isFalse);
      expect(f.controller.error, isNull);
    }
  });
  test('read-only action locks pending work and ignores late scope return',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    final readCount = f.requests.length;
    final pending = Completer<void>();
    var opened = 0, confirmations = 0;
    final action = f.controller.runAction((value) {
      expect(value.id, deviceId);
      opened++;
      return pending.future;
    }, refreshAfter: false);
    try {
      expect(f.controller.busy, isTrue);
      expect(f.controller.canRevoke, isFalse);
      await f.controller.runAction((_) async {
        opened++;
      }, refreshAfter: false);
      await f.controller.refresh();
      await f.controller.selectSection(DeviceManagementSection.capabilities);
      await f.controller.revoke((_) async {
        confirmations++;
        return true;
      });
      expect(opened, 1);
      expect(confirmations, 0);
      expect(f.controller.section, DeviceManagementSection.overview);
      expect(f.requests.length, readCount);

      f.current = false;
      f.controller.checkScope();
      f.current = true;
      f.controller.checkScope();
      expect(f.controller.hasAccess, isFalse);
      expect(f.controller.busy, isFalse);
    } finally {
      if (!pending.isCompleted) pending.complete();
      await action.timeout(const Duration(seconds: 1));
    }

    expect(f.controller.hasAccess, isFalse);
    expect(f.controller.device, isNull);
    expect(f.controller.capabilities, isNull);
    expect(f.controller.inventory, isNull);
    expect(f.controller.updatedAt, isNull);
    expect(f.controller.sectionUpdatedAt, isNull);
    expect(f.controller.canRevoke, isFalse);
    expect(
        f.controller.error,
        isA<ApiFailure>().having(
            (failure) => failure.code, 'code', 'WORKSPACE_CHANGED'));
    await f.controller.runAction((_) async {
      opened++;
    }, refreshAfter: false);
    expect(opened, 1);
    expect(f.requests.length, readCount);
  });
  test('read 401 removes private facts and stays denied after token changes',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    f.intercept = (_) async => http.Response('', 401);
    await f.controller.refresh();
    final count = f.requests.length;
    f.intercept = null;
    await f.controller.refresh();
    expect(f.controller.hasAccess, isFalse);
    expect(f.controller.device, isNull);
    expect(f.requests.length, count);
  });
  for (final section in [
    DeviceManagementSection.capabilities,
    DeviceManagementSection.applications
  ]) {
    test('denied $section read also hides successful device GET', () async {
      final f = Fixture();
      addTearDown(f.controller.dispose);
      await f.controller.initialize();
      f.intercept = (request) async => request.url.path.endsWith('/$deviceId')
          ? http.Response(jsonEncode(record()), 200,
              headers: {'content-type': 'application/json; charset=utf-8'})
          : http.Response('', 403);
      await f.controller.selectSection(section);
      expect(f.controller.device, isNull);
      expect(f.controller.capabilities, isNull);
      expect(f.controller.inventory, isNull);
      expect(f.controller.hasAccess, isFalse);
    });
  }
  test('accepted revoke with failed read stays blocked until REVOKED is read',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    f.intercept = (request) async => request.method == 'POST'
        ? http.Response('', 204)
        : http.Response('', 503);
    await f.controller.revoke((_) async => true);
    expect(f.controller.revokeAcceptedAwaitingRead, isTrue);
    expect(f.controller.revokeResultUnknown, isFalse);
    expect(f.controller.canRevoke, isFalse);
    expect(f.controller.device?.state, 'ACTIVE');
    await f.controller.revoke((_) async => true);
    expect(f.requests.where((r) => r.method == 'POST').length, 1);
    f.intercept = null;
    f.state = 'REVOKED';
    await f.controller.refresh();
    expect(f.controller.revokeAcceptedAwaitingRead, isFalse);
    expect(f.controller.device?.state, 'REVOKED');
  });
  test('concurrent revoke gestures open one confirmation and send one POST',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    final confirm = Completer<bool>();
    var confirmations = 0;
    final first = f.controller.revoke((_) {
      confirmations++;
      return confirm.future;
    });
    await f.controller.revoke((_) async {
      confirmations++;
      return true;
    });
    expect(confirmations, 1);
    expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
    confirm.complete(true);
    await first;
    expect(f.requests.where((r) => r.method == 'POST').length, 1);
  });
  test('disposing while a GET is pending ignores its late response', () async {
    final f = Fixture();
    final pending = Completer<http.Response>();
    f.intercept = (_) => pending.future;
    final initialized = f.controller.initialize();
    await Future<void>.delayed(Duration.zero);
    f.controller.dispose();
    pending.complete(http.Response(jsonEncode(record()), 200,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    await initialized;
    expect(f.controller.device, isNull);
    expect(f.controller.hasAccess, isFalse);
  });
  test('read-only controller cannot POST or read a forbidden inventory',
      () async {
    final f = Fixture();
    final controller = DeviceManagementController(
        repository: f.repository, canWrite: false, canReadApplications: false);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.revoke((_) async => true);
    await controller.selectSection(DeviceManagementSection.applications);
    expect(f.requests.length, 1);
    expect(controller.section, DeviceManagementSection.overview);
  });
  test('changed immutable device registration hides all existing data',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    f.intercept = (_) async => http.Response(
        jsonEncode(record()..['registrationId'] = subjectId), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    await f.controller.refresh();
    expect(f.controller.device, isNull);
    expect(
        f.controller.error,
        isA<ApiFailure>().having((failure) => failure.code, 'code',
            'INVALID_DEVICE_MANAGEMENT_RESPONSE'));
  });
  test('unverified capability cannot claim effective OS support', () {
    final value = capability();
    (value['items'] as List).single['effectiveSupported'] = true;
    expect(() => DeviceManagementCapabilities.fromJson(value), invalid);
  });
  test(
      'retry after invalid identity never binds the window to another registration',
      () async {
    final f = Fixture();
    addTearDown(f.controller.dispose);
    await f.controller.initialize();
    f.intercept = (_) async => http.Response(
        jsonEncode(record()..['registrationId'] = subjectId), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    await f.controller.refresh();
    expect(f.controller.device, isNull);
    await f.controller.refresh();
    expect(f.controller.device, isNull);
    f.intercept = null;
    await f.controller.refresh();
    expect(f.controller.device?.registrationId, registrationId);
  });
}
