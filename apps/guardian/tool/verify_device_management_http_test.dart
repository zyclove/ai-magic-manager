import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/device_management.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:http/http.dart' as http;

// Only the explicit loopback Spring fixture may supply identities to this tool.
// JWT issuance/MFA claims and activated registrations are test prerequisites;
// this does not exercise a browser, real IdP/OTP, or Android proof acceptance.
class ManagementFixture {
  final Json values;
  final Uri apiRoot;
  ManagementFixture(this.values, this.apiRoot);

  factory ManagementFixture.read() {
    final encoded =
        Platform.environment['GUARDIAN_DEVICE_MANAGEMENT_HTTP_FIXTURE'];
    if (encoded == null || encoded.length > 24000) {
      throw StateError(
          'An explicit bounded management HTTP fixture is required');
    }
    final values = jsonDecode(encoded) as Json;
    final root = Uri.parse(values['apiRoot'] as String);
    if (values['testOnly'] != true ||
        root.scheme != 'http' ||
        root.host != '127.0.0.1' ||
        !root.hasPort ||
        root.path != '/api/v1' ||
        root.hasQuery ||
        root.hasFragment ||
        root.userInfo.isNotEmpty) {
      throw StateError('Only explicit loopback Spring fixtures are permitted');
    }
    return ManagementFixture(values, root);
  }

  String text(String key) => values[key] as String;
  String get root => '/tenants/${text('tenantId')}';
}

class ResponseFact {
  final String path;
  final int status;
  final Set<String> fields;
  final List<Set<String>> itemFields, applicationFields;
  ResponseFact(this.path, this.status, this.fields, this.itemFields,
      this.applicationFields);
}

/// Actual network responses, with one optional loss after Spring returned 204.
/// Recorded observations contain route/status/field names, never bearer values.
class ManagementTransport extends http.BaseClient {
  final String bearer;
  final bool loseFirstRevokeReply;
  final delegate = http.Client();
  final bearerByPath = <String, String>{};
  final requests = <({String method, String path})>[];
  final responses = <ResponseFact>[];
  bool lost = false;

  ManagementTransport(this.bearer, {this.loseFirstRevokeReply = false});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers['Authorization'] =
        'Bearer ${bearerByPath[request.url.path] ?? bearer}';
    requests.add((method: request.method, path: request.url.path));
    final response = await delegate.send(request);
    final bytes = await response.stream.toBytes();
    final fields = <String>{};
    final itemFields = <Set<String>>[];
    final applicationFields = <Set<String>>[];
    if (bytes.isNotEmpty) {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Json) {
        fields.addAll(decoded.keys);
        for (final pair in [
          (value: decoded['items'], target: itemFields),
          (value: decoded['applications'], target: applicationFields),
        ]) {
          if (pair.value is List) {
            for (final item in pair.value as List) {
              if (item is Json) pair.target.add(item.keys.toSet());
            }
          }
        }
      }
    }
    responses.add(ResponseFact(request.url.path, response.statusCode, fields,
        itemFields, applicationFields));
    if (loseFirstRevokeReply &&
        !lost &&
        request.method == 'POST' &&
        request.url.path.endsWith('/revoke') &&
        response.statusCode == 204) {
      lost = true;
      throw http.ClientException('Synthetic lost committed revoke reply');
    }
    return http.StreamedResponse(Stream.value(bytes), response.statusCode,
        headers: response.headers,
        contentLength: bytes.length,
        request: response.request);
  }

  @override
  void close() => delegate.close();
}

class ManagementConnection {
  final ManagementTransport network;
  final DeviceManagementController controller;
  ManagementConnection(this.network, this.controller);

  factory ManagementConnection.create(ManagementFixture fixture,
      {String device = 'readDeviceId',
      String token = 'ownerToken',
      bool loseReply = false}) {
    final network = ManagementTransport(fixture.text(token),
        loseFirstRevokeReply: loseReply);
    final guarded = ScopeGuardedClient(network);
    final api = Api(() async => guarded, baseUrl: fixture.apiRoot.toString());
    final controller = DeviceManagementController(
        repository: DeviceManagementRepository(
            api: api,
            root: fixture.root,
            deviceId: fixture.text(device),
            current: () => true),
        canWrite: true,
        canReadApplications: true);
    return ManagementConnection(network, controller);
  }

  void dispose() {
    controller.dispose();
    network.close();
  }
}

void main() {
  late ManagementFixture fixture;
  setUpAll(() => fixture = ManagementFixture.read());

  test(
      'production DTOs decode Spring device 13 capability 8 and inventory 8 fields',
      () async {
    final connection = ManagementConnection.create(fixture);
    addTearDown(connection.dispose);
    final controller = connection.controller;
    await controller.initialize();
    expect(controller.error, isNull);
    expect(controller.device!.id, fixture.text('readDeviceId'));
    expect(controller.device!.subjectId, fixture.text('subjectId'));
    expect(
        controller.device!.registrationId, fixture.text('readRegistrationId'));
    expect(controller.device!.state, 'ACTIVE');
    expect(controller.device!.managementMode, 'BYOD');
    expect(controller.device!.controlLevel, 'LIMITED');
    expect(controller.device!.observationStatus, 'RECENT');
    expect(controller.device!.lastHeartbeatAt, isNotNull);
    expect(controller.device!.version, fixture.values['readVersion']);
    expect(connection.network.responses.single.fields, {
      'id',
      'subjectId',
      'registrationId',
      'displayName',
      'platform',
      'osVersion',
      'state',
      'managementMode',
      'controlLevel',
      'lastHeartbeatAt',
      'observationStatus',
      'keyThumbprint',
      'version',
    });

    await controller.selectSection(DeviceManagementSection.capabilities);
    expect(controller.error, isNull);
    final capabilities = controller.capabilities!;
    final usage =
        capabilities.items.singleWhere((item) => item.key == 'usage.report');
    expect(usage.reportedSupported, isTrue);
    expect(usage.grantStatus, 'GRANTED');
    expect(usage.evidenceSource, 'AGENT_REPORT');
    expect(usage.status, 'UNVERIFIED');
    expect(usage.effectiveSupported, isFalse);
    expect(usage.limitationCode, 'EVIDENCE_NOT_CERTIFIED');
    expect(capabilities.effectiveCount, 0);
    final managed = capabilities.items
        .singleWhere((item) => item.key == 'managed.app_policy');
    expect(managed.reportedSupported, isTrue);
    expect(managed.status, 'UNSUPPORTED');
    expect(managed.effectiveSupported, isFalse);
    expect(managed.limitationCode, 'MANAGED_REGISTRATION_REQUIRED');
    final capabilityFact = connection.network.responses.last;
    expect(capabilityFact.fields, {'items'});
    expect(capabilityFact.itemFields, isNotEmpty);
    for (final fields in capabilityFact.itemFields) {
      expect(fields, {
        'key',
        'reportedSupported',
        'grantStatus',
        'evidenceSource',
        'checkedAt',
        'status',
        'effectiveSupported',
        'limitationCode',
      });
    }

    await controller.selectSection(DeviceManagementSection.applications);
    expect(controller.error, isNull);
    final inventory = controller.inventory!;
    expect(inventory.deviceId, fixture.text('readDeviceId'));
    expect(inventory.registrationId, fixture.text('readRegistrationId'));
    expect(inventory.sequence, 1);
    expect(inventory.receivedAt, isNotNull);
    expect(inventory.visibility, 'VISIBLE_PACKAGES');
    expect(inventory.observationStatus, 'RECENT');
    expect(inventory.evidenceStatus, 'AGENT_REPORTED_UNVERIFIED');
    expect(inventory.applications, hasLength(1));
    final app = inventory.applications.single;
    expect(app.packageName, 'org.example.management');
    expect(app.displayName, 'Management HTTP fixture app');
    expect(app.profile, 'PRIMARY');
    expect(app.signingDigests, ['a' * 64]);
    expect(app.versionCode, 3);
    expect(app.systemApplication, isFalse);
    expect(connection.network.responses.last.fields, {
      'deviceId',
      'registrationId',
      'sequence',
      'receivedAt',
      'visibility',
      'observationStatus',
      'evidenceStatus',
      'applications',
    });
    expect(connection.network.responses.last.applicationFields.single, {
      'packageName',
      'displayName',
      'profile',
      'signingDigests',
      'versionCode',
      'systemApplication',
    });
  });

  for (final rejection in [
    (token: 'invalidToken', status: 401),
    (token: 'outsiderToken', status: 403),
  ]) {
    for (final section in DeviceManagementSection.values) {
      test(
          'real read ${rejection.status} in ${section.name} clears private facts',
          () async {
        final connection = ManagementConnection.create(fixture);
        addTearDown(connection.dispose);
        final controller = connection.controller;
        await controller.initialize();
        await controller.selectSection(DeviceManagementSection.capabilities);
        await controller.selectSection(DeviceManagementSection.applications);
        await controller.selectSection(section);
        expect(controller.device, isNotNull);
        expect(controller.capabilities, isNotNull);
        expect(controller.inventory, isNotNull);
        final suffix = switch (section) {
          DeviceManagementSection.overview => '',
          DeviceManagementSection.capabilities => '/capabilities',
          DeviceManagementSection.applications => '/application-inventory',
        };
        final path =
            '/api/v1${fixture.root}/devices/${fixture.text('readDeviceId')}$suffix';
        connection.network.bearerByPath[path] = fixture.text(rejection.token);
        await controller.refresh();
        expect(connection.network.responses.last.path, path);
        expect(connection.network.responses.last.status, rejection.status);
        expect(
            controller.error,
            isA<ApiFailure>().having(
                (failure) => failure.status, 'read status', rejection.status));
        expect(controller.device, isNull);
        expect(controller.capabilities, isNull);
        expect(controller.inventory, isNull);
        expect(controller.updatedAt, isNull);
        expect(controller.sectionUpdatedAt, isNull);
        expect(controller.hasAccess, isFalse);
        expect(controller.canRevoke, isFalse);
        expect(
            connection.network.requests
                .where((request) => request.method == 'POST'),
            isEmpty);
      });
    }
  }

  test('real weak MFA 401 preserves readable device and does not claim revoke',
      () async {
    final connection = ManagementConnection.create(fixture, token: 'weakToken');
    addTearDown(connection.dispose);
    final controller = connection.controller;
    await controller.initialize();
    expect(controller.error, isNull);
    await controller.revoke((_) async => true);
    expect(connection.network.responses.last.status, 401);
    expect(
        controller.error,
        isA<ApiFailure>().having(
            (failure) => failure.code, 'MFA rejection', 'REAUTH_REQUIRED'));
    expect(controller.device!.state, 'ACTIVE');
    expect(controller.device!.version, fixture.values['readVersion']);
    expect(controller.hasAccess, isTrue);
    expect(controller.revokeResultUnknown, isFalse);
    expect(controller.revokeAcceptedAwaitingRead, isFalse);
    await controller.refresh();
    expect(controller.error, isNull);
    expect(controller.device!.state, 'ACTIVE');
    expect(
        connection.network.requests
            .where((request) => request.method == 'POST'),
        hasLength(1));
  });

  test('cancelled confirmation makes no HTTP write', () async {
    final connection = ManagementConnection.create(fixture);
    addTearDown(connection.dispose);
    await connection.controller.initialize();
    await connection.controller.revoke((_) async => false);
    expect(
        connection.network.requests
            .where((request) => request.method == 'POST'),
        isEmpty);
    expect(connection.controller.device!.state, 'ACTIVE');
    expect(connection.controller.canRevoke, isTrue);
  });

  test('direct 204 reads revoked facts and cannot submit a second revoke',
      () async {
    final connection =
        ManagementConnection.create(fixture, device: 'directDeviceId');
    addTearDown(connection.dispose);
    final controller = connection.controller;
    await controller.initialize();
    expect(controller.device!.state, 'ACTIVE');
    await controller.revoke((_) async => true);
    expect(controller.error, isNull);
    expect(controller.device!.state, 'REVOKED');
    expect(controller.device!.observationStatus, 'REVOKED');
    expect(controller.device!.controlLevel, 'NONE');
    expect(controller.device!.version,
        (fixture.values['directVersion'] as int) + 1);
    expect(controller.canRevoke, isFalse);
    expect(controller.revokeResultUnknown, isFalse);
    expect(controller.revokeAcceptedAwaitingRead, isFalse);
    await controller.revoke((_) async => true);
    await controller.refresh();
    final writes = connection.network.requests
        .where((request) => request.method == 'POST');
    expect(writes, hasLength(1));
    expect(connection.network.responses.where((fact) => fact.status == 204),
        hasLength(1));
    expect(controller.device!.state, 'REVOKED');
  });

  test('lost committed 204 recovers with GET and never replays POST', () async {
    final connection = ManagementConnection.create(fixture,
        device: 'lostDeviceId', loseReply: true);
    addTearDown(connection.dispose);
    final controller = connection.controller;
    await controller.initialize();
    expect(controller.device!.state, 'ACTIVE');
    await controller.revoke((_) async => true);
    expect(connection.network.lost, isTrue);
    expect(connection.network.responses.last.status, 204);
    expect(
        controller.error,
        isA<ApiFailure>().having((failure) => failure.code, 'unknown result',
            'DEVICE_REVOKE_RESULT_UNKNOWN'));
    expect(controller.device!.state, 'ACTIVE');
    expect(controller.revokeResultUnknown, isTrue);
    expect(controller.canRevoke, isFalse);
    final callsBeforeRetry = connection.network.requests.length;
    await controller.revoke((_) async => true);
    expect(connection.network.requests.length, callsBeforeRetry);
    await controller.refresh();
    expect(connection.network.requests.last.method, 'GET');
    expect(controller.error, isNull);
    expect(controller.device!.state, 'REVOKED');
    expect(
        controller.device!.registrationId, fixture.text('lostRegistrationId'));
    expect(
        controller.device!.version, (fixture.values['lostVersion'] as int) + 1);
    expect(controller.revokeResultUnknown, isFalse);
    expect(controller.canRevoke, isFalse);
    expect(
        connection.network.requests
            .where((request) => request.method == 'POST'),
        hasLength(1));
  });
}
