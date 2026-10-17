import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_agent_binding.dart';
import 'package:guardian/core/managed_application_evidence.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:guardian/core/managed_control_summary.dart';
import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth;

import 'api_scope_test.dart'
    show RecordingTransport, expiredCredentials, refreshedToken;
import 'managed_agent_binding_fixtures.dart'
    show
        bindingTenant,
        bindingEnrollment,
        bindingDevice,
        bindingRegistration,
        bindingId;

const _application = '88888888-8888-4888-8888-888888888888';
const _application2 = '99999999-9999-1999-9999-999999999999';
const _application3 = 'aaaaaaaa-aaaa-1aaa-aaaa-aaaaaaaaaaaa';
const _otherBinding = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _instant = 1792209600000;
const _root = '/api/v1/tenants/$bindingTenant/managed-android/agent-bindings/'
    '$bindingId/applications/$_application/evidence';
const _invalidEvidence = 'INVALID_MANAGED_APPLICATION_EVIDENCE_RESPONSE';
const _invalidCatalog = 'INVALID_MANAGED_APPLICATION_CATALOG_RESPONSE';

ManagedAgentBinding _binding({String state = 'VERIFIED', int version = 3}) =>
    ManagedAgentBinding(
        id: bindingId,
        enrollmentId: bindingEnrollment,
        deviceId: bindingDevice,
        registrationId: bindingRegistration,
        state: state,
        version: version,
        createdAt: _instant - 60000,
        expiresAt: _instant + 540000,
        verifiedAt: state == 'VERIFIED' ? _instant - 1000 : null);

Json _operation(String kind, String effect, [String? permission]) =>
    {'kind': kind, 'effect': effect, 'permission': permission};

Json _evidence({
  String state = 'VERIFIED_IDENTITY',
  int version = 17,
  bool control = true,
}) {
  final verified = state == 'VERIFIED_IDENTITY';
  return {
    'bindingId': bindingId,
    'applicationId': _application,
    'state': state,
    'reasonCode': state == 'ABSENT'
        ? 'MANAGED_APPLICATION_EVIDENCE_REQUIRED'
        : verified && control
            ? 'MANAGED_APPLICATION_CONTROL_VERIFIED'
            : verified
                ? 'MANAGED_CONTROL_EVIDENCE_REQUIRED'
                : 'MANAGED_APPLICATION_REPORT_PENDING',
    'version': state == 'ABSENT' ? 0 : version,
    'profileScope': verified && control ? 'PRIMARY' : 'UNKNOWN',
    'systemControlAvailable': verified && control,
    'reportedAt': verified ? _instant - 2000 : null,
    'retrievedAt': verified ? _instant - 1000 : null,
    'expiresAt': verified ? _instant + 60000 : null,
    'nextRefreshAt': state == 'ABSENT' ? null : _instant + 30000,
    'controlOperations': verified && control
        ? [
            _operation('APP_LAUNCH', 'DENY'),
            _operation('APP_INSTALL', 'ALLOW'),
            _operation(
                'RUNTIME_PERMISSION', 'DEFAULT', 'android.permission.CAMERA')
          ]
        : <Json>[]
  };
}

Json _applicationRecord({String id = _application}) => {
      'id': id,
      'displayName': '机构阅读器',
      'platform': 'ANDROID',
      'packageName': 'com.example.Reader',
      'profile': 'PRIMARY',
      'signingDigests': ['a' * 64],
      'evidenceStatus': 'ADMIN_DECLARED'
    };

Json _page(List<Json> items, {String? nextCursor}) =>
    {'items': items, 'nextCursor': nextCursor};

String _pageId(int index) => '${(index + 1).toRadixString(16).padLeft(8, '0')}'
    '-0000-1000-8000-000000000000';

Matcher _failure(int status, [String? code]) {
  final result = isA<ApiFailure>()
      .having((failure) => failure.status, 'HTTP status', status);
  return code == null
      ? result
      : result.having((failure) => failure.code, 'error code', code);
}

// Converts synchronous input rejection into the same asserted Future boundary.
Future<T> _invoke<T>(Future<T> Function() action) => Future<T>.sync(action);

// Handle errors immediately while a deterministic HTTP fixture is held open.
Future<Object?> _outcome(Future<Object?> pending) async {
  try {
    return await pending;
  } catch (error) {
    return error;
  }
}

Future<T> _success<T>(Future<T> pending) async {
  try {
    return await pending;
  } catch (error) {
    fail('Expected a successful operation, got ${error.runtimeType}: $error');
  }
}

ManagedApplicationEvidence _parse(Json raw) {
  late ManagedApplicationEvidence result;
  expect(() {
    result = ManagedApplicationEvidence.parse(raw,
        bindingId: bindingId, applicationId: _application);
  }, returnsNormally);
  return result;
}

class _EvidenceTransport extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  final requests = <http.BaseRequest>[];
  final bodies = <List<int>>[];
  bool closed = false;

  _EvidenceTransport(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Count entry to the physical transport before finalization checks run.
    requests.add(request);
    bodies.add(await request.finalize().toBytes());
    return handler(request);
  }

  @override
  void close() {
    closed = true;
  }
}

class _EvidenceFixture {
  final ManagedAgentBinding binding;
  bool current = true;
  int clientLookups = 0;
  final denials = <ApiFailure>[];
  late Future<http.StreamedResponse> Function(http.BaseRequest) handler =
      (_) async => response(_evidence());
  late final client = _EvidenceTransport((request) => handler(request));
  late final api = Api(() async {
    clientLookups++;
    return client;
  }, baseUrl: 'https://evidence.invalid/api/v1');
  late final repository = ManagedApplicationEvidenceRepository(
      api: api,
      tenantId: bindingTenant,
      binding: binding,
      current: () => current,
      onDenied: denials.add);

  _EvidenceFixture({ManagedAgentBinding? binding})
      : binding = binding ?? _binding() {
    addTearDown(() => client.close());
  }

  http.StreamedResponse response(Object? data, {int status = 200}) {
    final bytes = utf8.encode(jsonEncode(data));
    return http.StreamedResponse(Stream.value(bytes), status,
        contentLength: bytes.length,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }
}

Future<void> _expectPermanentlyRevoked(_EvidenceFixture fixture) async {
  final requests = fixture.client.requests.length;
  final clientLookups = fixture.clientLookups;
  expect(fixture.current, isTrue,
      reason: 'The repository must latch denial without mutating its caller.');
  for (final action in <Future<Object?> Function()>[
    () => fixture.repository.read(_application),
    () => fixture.repository.refresh(_application),
    () => fixture.repository.applicationPage()
  ]) {
    await expectLater(
        _invoke(action), throwsA(_failure(409, 'WORKSPACE_CHANGED')));
  }
  expect(fixture.client.requests, hasLength(requests));
  expect(fixture.clientLookups, clientLookups);
  expect(fixture.denials, hasLength(1));
  expect(fixture.client.closed, isFalse);
}

ApiFailure _onlyDenial(_EvidenceFixture fixture) {
  expect(fixture.denials, hasLength(1));
  return fixture.denials.single;
}

void main() {
  test('evidence header uses binding version rather than evidence version',
      () async {
    final fixture = _EvidenceFixture();
    fixture.handler = (request) async => fixture
        .response(_evidence(version: request.method == 'POST' ? 18 : 17));

    final read = await _success(fixture.repository.read(_application));
    final refreshed = await _success(fixture.repository.refresh(_application));

    expect(read.version, 17);
    expect(refreshed.version, 18);
    expect(fixture.client.requests.map((request) => request.method),
        ['GET', 'POST']);
    expect(fixture.client.requests.map((request) => request.url.path),
        [_root, '$_root/refresh']);
    for (final request in fixture.client.requests) {
      expect(request.headers['If-Match'], '"3"');
      expect(request.headers['Accept'], 'application/json');
      expect(request.url.hasQuery, isFalse);
      expect(request.followRedirects, isFalse);
    }
    expect(fixture.client.bodies, everyElement(isEmpty),
        reason: 'Refresh cannot upload device facts or signing declarations.');
    expect(fixture.denials, isEmpty);
  });

  for (final value in [
    'com.example.Reader',
    '../$_application',
    '$_application?applicationId=$_application2',
    _application.toUpperCase().replaceFirst('8888', 'ABCD'),
    ''
  ]) {
    test('catalog id is required instead of inventory package: $value',
        () async {
      final fixture = _EvidenceFixture();
      for (final action in <Future<Object?> Function()>[
        () => fixture.repository.read(value),
        () => fixture.repository.refresh(value)
      ]) {
        await expectLater(
            _invoke(action), throwsA(_failure(400, 'INVALID_APPLICATION_ID')));
      }
      expect(fixture.clientLookups, 0);
      expect(fixture.client.requests, isEmpty);
    });
  }

  test('all twelve response fields are validated', () {
    final raw = _evidence();
    expect(raw, hasLength(12));
    final evidence = _parse(raw);
    expect(evidence.bindingId, bindingId);
    expect(evidence.applicationId, _application);
    expect(evidence.state, 'VERIFIED_IDENTITY');
    expect(evidence.reasonCode, 'MANAGED_APPLICATION_CONTROL_VERIFIED');
    expect(evidence.version, 17);
    expect(evidence.profileScope, 'PRIMARY');
    expect(evidence.systemControlAvailable, isTrue);
    expect(evidence.reportedAt, _instant - 2000);
    expect(evidence.retrievedAt, _instant - 1000);
    expect(evidence.expiresAt, _instant + 60000);
    expect(evidence.nextRefreshAt, _instant + 30000);
    expect(evidence.controlOperations, hasLength(3));
    final ManagedControlSummary? summary =
        evidence.controlAt(DateTime.fromMillisecondsSinceEpoch(_instant));
    expect(summary, isA<ManagedControlSummary>());
    expect(summary!.operations.map((operation) => operation.kind),
        ['APP_INSTALL', 'APP_LAUNCH', 'RUNTIME_PERMISSION']);
    expect(summary.operations.last.permission, 'android.permission.CAMERA');
  });

  for (final field in _evidence().keys) {
    test('missing evidence field $field is not a partial success', () async {
      final fixture = _EvidenceFixture();
      fixture.handler =
          (_) async => fixture.response(_evidence()..remove(field));
      await expectLater(fixture.repository.read(_application),
          throwsA(_failure(502, _invalidEvidence)));
      expect(fixture.client.requests, hasLength(1));
      expect(fixture.denials, isEmpty);
    });
  }

  final malformedFields = <String, Object?>{
    'bindingId': _otherBinding,
    'applicationId': _application2,
    'state': 'VERIFIED',
    'reasonCode': {'rawProviderMessage': 'private'},
    'version': 1.5,
    'profileScope': 'WORK',
    'systemControlAvailable': 'true',
    'reportedAt': -1,
    'retrievedAt': '1792209599000',
    'expiresAt': 9007199254740992,
    'nextRefreshAt': 1.5,
    'controlOperations': {'kind': 'APP_LAUNCH'},
    'providerDeviceName': 'must-not-enter-this-contract'
  };
  for (final field in malformedFields.entries) {
    test('malformed evidence field ${field.key} rejects the HTTP payload',
        () async {
      final fixture = _EvidenceFixture();
      fixture.handler =
          (_) async => fixture.response(_evidence()..[field.key] = field.value);
      await expectLater(fixture.repository.read(_application),
          throwsA(_failure(502, _invalidEvidence)));
      expect(fixture.client.requests, hasLength(1));
    });
  }

  for (final value in <Object?>[null, -1, 1.5, '17', 9007199254740992]) {
    test('non integral or unsafe evidence version $value is rejected', () {
      final raw = _evidence()..['version'] = value;
      expect(
          () => ManagedApplicationEvidence.parse(raw,
              bindingId: bindingId, applicationId: _application),
          throwsA(_failure(502, _invalidEvidence)));
    });
  }

  for (final state in [
    'ABSENT',
    'PENDING',
    'WAITING_REPORT',
    'FAILED',
    'REJECTED',
    'STALE'
  ]) {
    test('$state preserves a read result without application control', () {
      final evidence = _parse(_evidence(state: state, control: false));
      expect(evidence.state, state);
      expect(evidence.version, state == 'ABSENT' ? 0 : 17);
      expect(evidence.profileScope, 'UNKNOWN');
      expect(evidence.systemControlAvailable, isFalse);
      expect(evidence.reportedAt, isNull);
      expect(evidence.retrievedAt, isNull);
      expect(evidence.expiresAt, isNull);
      expect(evidence.controlOperations, isEmpty);
      expect(evidence.controlAt(DateTime.fromMillisecondsSinceEpoch(_instant)),
          isNull);
    });
  }

  test('identity only evidence does not claim application control', () {
    final raw = _evidence(control: false)
      ..['reasonCode'] = 'MANAGED_CONTROL_PROFILE_UNSUPPORTED';
    final evidence = _parse(raw);
    expect(evidence.state, 'VERIFIED_IDENTITY');
    expect(evidence.reportedAt, isNotNull);
    expect(evidence.profileScope, 'UNKNOWN');
    expect(evidence.systemControlAvailable, isFalse);
    expect(evidence.controlOperations, isEmpty);
    expect(evidence.controlAt(DateTime.fromMillisecondsSinceEpoch(_instant)),
        isNull);
  });

  test('safe future reason codes do not become execution authorization', () {
    final raw = _evidence(control: false)
      ..['reasonCode'] = 'FUTURE_PROVIDER_REASON';
    final evidence = _parse(raw);
    expect(evidence.reasonCode, 'FUTURE_PROVIDER_REASON');
    expect(evidence.controlAt(DateTime.fromMillisecondsSinceEpoch(_instant)),
        isNull);
  });

  for (final skew in [15000, 30000]) {
    test('server reported time may lead retrieval by $skew milliseconds', () {
      final raw = _evidence()
        ..['retrievedAt'] = _instant
        ..['reportedAt'] = _instant + skew
        ..['expiresAt'] = _instant + 1000;
      final evidence = _parse(raw);
      expect(evidence.reportedAt, _instant + skew);
      expect(evidence.controlAt(DateTime.fromMillisecondsSinceEpoch(_instant)),
          isNotNull,
          reason:
              'A short reuse age can expire before the skewed report time.');
    });
  }

  test('expiry projects stale without rejecting a valid late response', () {
    final evidence = _parse(_evidence());
    final expires = DateTime.fromMillisecondsSinceEpoch(_instant + 60000);
    expect(evidence.stateAt(expires.subtract(const Duration(milliseconds: 1))),
        'VERIFIED_IDENTITY');
    expect(
        evidence.controlAt(expires.subtract(const Duration(milliseconds: 1))),
        isNotNull);
    expect(evidence.stateAt(expires), 'STALE');
    expect(evidence.controlAt(expires), isNull);
    expect(evidence.stateAt(expires.add(const Duration(seconds: 1))), 'STALE');
    expect(evidence.state, 'VERIFIED_IDENTITY',
        reason:
            'The immutable server result must not be rewritten by a clock.');
  });

  test('pending remains pending when nextRefreshAt has passed', () {
    final raw = _evidence(state: 'PENDING', control: false)
      ..['nextRefreshAt'] = _instant - 1;
    final evidence = _parse(raw);
    expect(evidence.stateAt(DateTime.fromMillisecondsSinceEpoch(_instant)),
        'PENDING');
    expect(evidence.controlAt(DateTime.fromMillisecondsSinceEpoch(_instant)),
        isNull);
  });

  final inconsistent = <String, void Function(Json)>{
    'absent record version': (raw) => raw
      ..addAll(_evidence(state: 'ABSENT', control: false))
      ..['version'] = 1,
    'absent refresh time': (raw) => raw
      ..addAll(_evidence(state: 'ABSENT', control: false))
      ..['nextRefreshAt'] = _instant,
    'record without positive version': (raw) => raw['version'] = 0,
    'verified without report': (raw) => raw['reportedAt'] = null,
    'verified without retrieval': (raw) => raw['retrievedAt'] = null,
    'verified without expiry': (raw) => raw['expiresAt'] = null,
    'verified without next refresh': (raw) => raw['nextRefreshAt'] = null,
    'expiry at retrieval': (raw) => raw['expiresAt'] = raw['retrievedAt'],
    'report beyond maximum skew': (raw) =>
        raw['reportedAt'] = (raw['retrievedAt'] as int) + 30001,
    'pending carries capability': (raw) => raw['state'] = 'PENDING',
    'pending carries report': (raw) => raw
      ..addAll(_evidence(state: 'PENDING', control: false))
      ..['reportedAt'] = _instant,
    'control reason mismatch': (raw) =>
        raw['reasonCode'] = 'MANAGED_CONTROL_EVIDENCE_REQUIRED',
    'identity only carries operations': (raw) => raw
      ..['profileScope'] = 'UNKNOWN'
      ..['systemControlAvailable'] = false,
    'control has empty operations': (raw) => raw['controlOperations'] = <Json>[]
  };
  for (final entry in inconsistent.entries) {
    test('inconsistent evidence combination ${entry.key} is rejected', () {
      final raw = _evidence();
      entry.value(raw);
      expect(
          () => ManagedApplicationEvidence.parse(raw,
              bindingId: bindingId, applicationId: _application),
          throwsA(_failure(502, _invalidEvidence)));
    });
  }

  final invalidOperations = <String, List<Object?>>{
    'unsupported kind': [_operation('APP_UNINSTALL', 'DENY')],
    'runtime grant': [
      _operation('RUNTIME_PERMISSION', 'ALLOW', 'android.permission.CAMERA')
    ],
    'wildcard permission': [
      _operation('RUNTIME_PERMISSION', 'DENY', 'android.permission.*')
    ],
    'normal permission': [
      _operation('RUNTIME_PERMISSION', 'DENY', 'android.permission.INTERNET')
    ],
    'launch with permission': [
      _operation('APP_LAUNCH', 'DENY', 'android.permission.CAMERA')
    ],
    'duplicate operation': [
      _operation('APP_INSTALL', 'ALLOW'),
      _operation('APP_INSTALL', 'ALLOW')
    ],
    'missing permission field': [
      {'kind': 'APP_LAUNCH', 'effect': 'DENY'}
    ],
    'extra provider fact': [
      {..._operation('APP_LAUNCH', 'DENY'), 'executed': true}
    ],
    'over 128 operations':
        List.generate(129, (_) => _operation('APP_LAUNCH', 'DENY'))
  };
  for (final entry in invalidOperations.entries) {
    test('invalid exact operation list ${entry.key} never exposes control',
        () async {
      final fixture = _EvidenceFixture();
      fixture.handler = (_) async =>
          fixture.response(_evidence()..['controlOperations'] = entry.value);
      await expectLater(fixture.repository.read(_application),
          throwsA(_failure(502, _invalidEvidence)));
    });
  }

  test('operation parsing takes an immutable snapshot using the shared model',
      () {
    final raw = _evidence();
    final evidence = _parse(raw);
    final operations = raw['controlOperations'] as List;
    (operations.first as Json)['effect'] = 'ALLOW';
    operations.clear();
    expect(evidence.controlOperations, hasLength(3));
    expect(
        evidence.controlOperations
            .singleWhere((operation) => operation.kind == 'APP_LAUNCH')
            .effect,
        'DENY');
    expect(() => evidence.controlOperations.clear(), throwsUnsupportedError);
    final summary =
        evidence.controlAt(DateTime.fromMillisecondsSinceEpoch(_instant));
    expect(summary, isA<ManagedControlSummary>());
    expect(() => summary!.operations.clear(), throwsUnsupportedError);
  });

  test('catalog uses exact user driven pagination and immutable declarations',
      () async {
    final fixture = _EvidenceFixture();
    fixture.handler = (request) async => fixture.response(
        request.url.queryParameters['cursor'] == null
            ? _page([_applicationRecord(id: _application2)],
                nextCursor: _application2)
            : _page([_applicationRecord(id: _application3)]));

    final first = await _success(fixture.repository.applicationPage());
    expect(fixture.client.requests, hasLength(1),
        reason: 'A next cursor must not cause an automatic directory request.');
    expect(first.items, hasLength(1));
    expect(first.items.single.id, _application2);
    expect(first.items.single.displayName, '机构阅读器');
    expect(first.items.single.packageName, 'com.example.Reader');
    expect(first.items.single.evidenceStatus, 'ADMIN_DECLARED');
    expect(first.items.single.signingDigests, ['a' * 64]);
    expect(first.nextCursor, _application2);
    final second = await _success(
        fixture.repository.applicationPage(cursor: first.nextCursor));
    expect(second.items, hasLength(1));
    expect(second.items.single.id, _application3);
    expect(second.nextCursor, isNull);
    for (final request in fixture.client.requests) {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/tenants/$bindingTenant/applications');
    }
    expect(fixture.client.requests.first.url.queryParameters, {'limit': '50'});
    expect(fixture.client.requests.last.url.queryParameters,
        {'limit': '50', 'cursor': _application2});
    expect(() => first.items.clear(), throwsUnsupportedError);
    expect(() => first.items.single.signingDigests.clear(),
        throwsUnsupportedError);
  });

  test('empty directory is a valid result rather than a failed request',
      () async {
    final fixture = _EvidenceFixture();
    fixture.handler = (_) async => fixture.response(_page([]));
    final result = await _success(fixture.repository.applicationPage());
    expect(result.items, isEmpty);
    expect(result.nextCursor, isNull);
  });

  for (final platform in ['ANDROID', 'ANDROID_TV']) {
    for (final profile in ['PRIMARY', 'WORK', 'SECONDARY', 'UNKNOWN']) {
      test('catalog accepts $platform $profile with no signing declaration',
          () async {
        final fixture = _EvidenceFixture();
        final raw = _applicationRecord()
          ..['platform'] = platform
          ..['profile'] = profile
          ..['signingDigests'] = <String>[]
          ..['evidenceStatus'] = 'INSTALLED_VERIFIED';
        fixture.handler = (_) async => fixture.response(_page([raw]));
        final page = await _success(fixture.repository.applicationPage());
        expect(page.items, hasLength(1));
        final app = page.items.single;
        expect(app.platform, platform);
        expect(app.profile, profile);
        expect(app.signingDigests, isEmpty);
        expect(app.evidenceStatus, 'INSTALLED_VERIFIED',
            reason:
                'A directory label is not current managed device evidence.');
      });
    }
  }

  final malformedApplications = <String, Object?>{
    'id': 'com.example.Reader',
    'displayName': '',
    'platform': 'IOS',
    'packageName': '../com.example.Reader',
    'profile': 'ALL',
    'signingDigests': ['a' * 64, 'a' * 64],
    'evidenceStatus': true,
    'version': 1
  };
  for (final entry in malformedApplications.entries) {
    test('catalog rejects malformed declaration field ${entry.key}', () async {
      final fixture = _EvidenceFixture();
      fixture.handler = (_) async => fixture
          .response(_page([_applicationRecord()..[entry.key] = entry.value]));
      await expectLater(fixture.repository.applicationPage(),
          throwsA(_failure(502, _invalidCatalog)));
    });
  }

  for (final field in _applicationRecord().keys) {
    test('catalog requires declaration field $field', () async {
      final fixture = _EvidenceFixture();
      fixture.handler = (_) async =>
          fixture.response(_page([_applicationRecord()..remove(field)]));
      await expectLater(fixture.repository.applicationPage(),
          throwsA(_failure(502, _invalidCatalog)));
    });
  }

  final malformedPages = <String, Object?>{
    'non object': [],
    'missing items': {'nextCursor': null},
    'missing cursor': {'items': []},
    'extra field': {..._page([]), 'total': 0},
    'non list items': _page([])..['items'] = {},
    'non object item': _page([])..['items'] = [null],
    'duplicate id': _page([_applicationRecord(), _applicationRecord()]),
    'descending ids':
        _page([_applicationRecord(id: _application2), _applicationRecord()]),
    'over page limit': _page(
        List.generate(51, (index) => _applicationRecord(id: _pageId(index)))),
    'malformed cursor': _page([_applicationRecord()], nextCursor: 'next'),
    'cursor not final id':
        _page([_applicationRecord()], nextCursor: _application2),
    'empty page with cursor': _page([], nextCursor: _application)
  };
  for (final entry in malformedPages.entries) {
    test('catalog rejects inconsistent page ${entry.key}', () async {
      final fixture = _EvidenceFixture();
      fixture.handler = (_) async => fixture.response(entry.value);
      await expectLater(fixture.repository.applicationPage(),
          throwsA(_failure(502, _invalidCatalog)));
    });
  }

  test('catalog rejects an anchor repeated by the next page', () async {
    final fixture = _EvidenceFixture();
    fixture.handler = (_) async => fixture
        .response(_page([_applicationRecord()], nextCursor: _application));
    await expectLater(fixture.repository.applicationPage(cursor: _application),
        throwsA(_failure(502, _invalidCatalog)));
    expect(fixture.client.requests, hasLength(1));
  });

  test('invalid catalog cursor cannot reach authentication or HTTP', () async {
    final fixture = _EvidenceFixture();
    await expectLater(
        _invoke(() => fixture.repository.applicationPage(cursor: '../next')),
        throwsA(_failure(400, 'INVALID_CURSOR')));
    expect(fixture.clientLookups, 0);
    expect(fixture.client.requests, isEmpty);
  });

  for (final state in ['PENDING', 'REVOKED', 'EXPIRED']) {
    test('$state parent binding cannot open application evidence', () async {
      final fixture = _EvidenceFixture(binding: _binding(state: state));
      for (final action in <Future<Object?> Function()>[
        () => fixture.repository.applicationPage(),
        () => fixture.repository.read(_application),
        () => fixture.repository.refresh(_application)
      ]) {
        await expectLater(
            _invoke(action), throwsA(_failure(409, 'WORKSPACE_CHANGED')));
      }
      expect(fixture.clientLookups, 0);
      expect(fixture.client.requests, isEmpty);
    });
  }

  test('observed parent scope loss is permanent for this repository', () async {
    final fixture = _EvidenceFixture()..current = false;
    await expectLater(_invoke(() => fixture.repository.read(_application)),
        throwsA(_failure(409, 'WORKSPACE_CHANGED')));
    fixture.current = true;
    await expectLater(_invoke(() => fixture.repository.refresh(_application)),
        throwsA(_failure(409, 'WORKSPACE_CHANGED')));
    await expectLater(_invoke(() => fixture.repository.applicationPage()),
        throwsA(_failure(409, 'WORKSPACE_CHANGED')));
    expect(fixture.clientLookups, 0);
    expect(fixture.client.requests, isEmpty);
    expect(fixture.denials, isEmpty);
  });

  test('scope lost while obtaining the client prevents physical HTTP',
      () async {
    final fixture = _EvidenceFixture();
    final clientReady = Completer<http.Client>();
    var lookups = 0;
    final api = Api(() {
      lookups++;
      return clientReady.future;
    }, baseUrl: fixture.api.baseUrl);
    final repository = ManagedApplicationEvidenceRepository(
        api: api,
        tenantId: bindingTenant,
        binding: fixture.binding,
        current: () => fixture.current,
        onDenied: fixture.denials.add);
    final pending = _outcome(_invoke(() => repository.read(_application)));
    await Future<void>.delayed(Duration.zero);
    fixture.current = false;
    clientReady.complete(fixture.client);
    expect(await pending, _failure(409, 'WORKSPACE_CHANGED'));
    expect(lookups, 1);
    expect(fixture.client.requests, isEmpty);
    fixture.current = true;
    await expectLater(_invoke(() => repository.refresh(_application)),
        throwsA(_failure(409, 'WORKSPACE_CHANGED')));
    expect(lookups, 1);
  });

  test('late evidence cannot escape after the parent scope is lost', () async {
    final fixture = _EvidenceFixture();
    final responseReady = Completer<http.StreamedResponse>();
    fixture.handler = (_) => responseReady.future;
    final pending =
        _outcome(_invoke(() => fixture.repository.read(_application)));
    await Future<void>.delayed(Duration.zero);
    fixture.current = false;
    responseReady.complete(fixture.response(_evidence()));
    expect(await pending, _failure(409, 'WORKSPACE_CHANGED'));
    expect(fixture.client.requests, hasLength(1));
    fixture.current = true;
    await expectLater(_invoke(() => fixture.repository.applicationPage()),
        throwsA(_failure(409, 'WORKSPACE_CHANGED')));
    expect(fixture.client.requests, hasLength(1));
    expect(fixture.denials, isEmpty);
  });

  test('scope lost during a private body stream discards the evidence',
      () async {
    final fixture = _EvidenceFixture();
    final bytes = utf8.encode(jsonEncode(_evidence()));
    var cancelled = false;
    final stream = StreamController<List<int>>(onCancel: () {
      cancelled = true;
    });
    addTearDown(() {
      unawaited(stream.close());
    });
    fixture.handler = (_) async => http.StreamedResponse(stream.stream, 200,
        contentLength: bytes.length,
        headers: {'content-type': 'application/json'});
    final pending =
        _outcome(_invoke(() => fixture.repository.read(_application)));
    await Future<void>.delayed(Duration.zero);
    fixture.current = false;
    stream.add(bytes);
    unawaited(stream.close());
    expect(await pending, _failure(409, 'WORKSPACE_CHANGED'));
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
    expect(fixture.client.requests, hasLength(1));
    fixture.current = true;
    await expectLater(_invoke(() => fixture.repository.refresh(_application)),
        throwsA(_failure(409, 'WORKSPACE_CHANGED')));
    expect(fixture.client.requests, hasLength(1));
    expect(fixture.client.closed, isFalse);
  });

  test('real OAuth refresh blocks stale application evidence dispatch',
      () async {
    var current = true;
    final raw = RecordingTransport();
    final client = oauth.Client(expiredCredentials(),
        identifier: 'guardian',
        basicAuth: false,
        httpClient: ScopeGuardedClient(raw));
    addTearDown(client.close);
    final repository = ManagedApplicationEvidenceRepository(
        api: Api(() async => client),
        tenantId: bindingTenant,
        binding: _binding(),
        current: () => current,
        onDenied: (_) {});
    final pending = _outcome(_invoke(() => repository.refresh(_application)));
    await Future<void>.delayed(Duration.zero);
    expect(raw.tokenStarted.isCompleted, isTrue,
        reason: 'The fixture must reach the real OAuth refresh boundary.');
    current = false;
    raw.tokenReply.complete(refreshedToken());
    expect(await pending, _failure(409, 'WORKSPACE_CHANGED'));
    expect(raw.businessRequests, isEmpty,
        reason: 'A finalize guard alone is too late for physical dispatch.');
    expect(raw.requests, hasLength(1));
  });

  for (final status in [401, 403]) {
    test('HTTP $status hard denial permanently blocks later physical reads',
        () async {
      final fixture = _EvidenceFixture();
      await _success(fixture.repository.read(_application));
      fixture.handler = (_) async =>
          fixture.response({'errorCode': 'ACCESS_DENIED'}, status: status);
      await expectLater(fixture.repository.refresh(_application),
          throwsA(_failure(status, 'ACCESS_DENIED')));
      final denial = _onlyDenial(fixture);
      expect(denial.status, status);
      expect(denial.code, 'ACCESS_DENIED');
      await _expectPermanentlyRevoked(fixture);
    });

    for (final field in ['errorCode', 'correlationId']) {
      test('non string error fields preserve hard denial: HTTP $status $field',
          () async {
        final fixture = _EvidenceFixture();
        final error = <String, dynamic>{
          'errorCode': 'ACCESS_DENIED',
          'correlationId': 'safe-correlation'
        }..[field] = {'unexpected': true};
        fixture.handler = (_) async => fixture.response(error, status: status);
        await expectLater(
            fixture.repository.read(_application),
            throwsA(_failure(status,
                field == 'errorCode' ? 'REQUEST_FAILED' : 'ACCESS_DENIED')));
        expect(_onlyDenial(fixture).status, status);
        await _expectPermanentlyRevoked(fixture);
      });
    }

    test('HTTP $status malformed JSON is still a permanent hard denial',
        () async {
      final fixture = _EvidenceFixture();
      fixture.handler = (_) async => http.StreamedResponse(
          Stream.value(utf8.encode('{broken-private-error')), status,
          headers: {'content-type': 'application/json'});
      await expectLater(fixture.repository.applicationPage(),
          throwsA(_failure(status, 'REQUEST_FAILED')));
      expect(_onlyDenial(fixture).status, status);
      await _expectPermanentlyRevoked(fixture);
    });

    test('HTTP $status interrupted denial body cannot restore access',
        () async {
      final fixture = _EvidenceFixture();
      var cancelled = false;
      late final StreamController<List<int>> stream;
      stream = StreamController<List<int>>(onListen: () {
        stream.addError(http.ClientException('fixture error body interrupted'));
      }, onCancel: () {
        cancelled = true;
      });
      addTearDown(() {
        unawaited(stream.close());
      });
      fixture.handler = (_) async => http.StreamedResponse(
          stream.stream, status,
          headers: {'content-type': 'application/json'});

      await expectLater(fixture.repository.read(_application),
          throwsA(_failure(status, 'REQUEST_FAILED')));
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, isTrue);
      expect(_onlyDenial(fixture).status, status);
      await _expectPermanentlyRevoked(fixture);
    });

    for (final declared in [true, false]) {
      test(
          'hard denial survives oversized malformed body: HTTP $status '
          '${declared ? 'declared' : 'chunked'}', () async {
        final fixture = _EvidenceFixture();
        var cancelled = false;
        late final StreamController<List<int>> stream;
        stream = StreamController<List<int>>(onListen: () {
          if (!declared) {
            stream.add(List.filled(32768, 32));
            stream.add(List.filled(32769, 32));
          }
        }, onCancel: () {
          cancelled = true;
        });
        addTearDown(() {
          unawaited(stream.close());
        });
        fixture.handler = (_) async => http.StreamedResponse(
            stream.stream, status,
            contentLength: declared ? 65537 : null,
            headers: {'content-type': 'application/json'});

        await expectLater(fixture.repository.refresh(_application),
            throwsA(_failure(status, 'REQUEST_FAILED')));
        await Future<void>.delayed(Duration.zero);
        expect(cancelled, isTrue);
        expect(_onlyDenial(fixture).status, status);
        expect(fixture.client.closed, isFalse);
        expect(fixture.client.requests, hasLength(1));
        await _expectPermanentlyRevoked(fixture);
      });
    }
  }

  test('catalog hard denial also locks evidence and refresh on this context',
      () async {
    final fixture = _EvidenceFixture();
    fixture.handler = (_) async =>
        fixture.response({'errorCode': 'ACCESS_DENIED'}, status: 403);
    await expectLater(fixture.repository.applicationPage(),
        throwsA(_failure(403, 'ACCESS_DENIED')));
    await _expectPermanentlyRevoked(fixture);
  });

  test('explicit HTTP 401 REAUTH_REQUIRED retains user initiated recovery',
      () async {
    final fixture = _EvidenceFixture();
    fixture.handler = (_) async =>
        fixture.response({'errorCode': 'REAUTH_REQUIRED'}, status: 401);
    await expectLater(fixture.repository.refresh(_application),
        throwsA(_failure(401, 'REAUTH_REQUIRED')));
    expect(fixture.denials, isEmpty);
    expect(fixture.client.requests, hasLength(1),
        reason: 'The repository must not automatically repeat the POST.');
    fixture.handler = (_) async => fixture.response(_evidence(version: 18));
    final result = await _success(fixture.repository.read(_application));
    expect(result.version, 18);
    await _success(fixture.repository.refresh(_application));
    expect(fixture.client.requests.map((request) => request.method),
        ['POST', 'GET', 'POST']);
    expect(fixture.client.requests.last.headers['If-Match'], '"3"');
  });

  test('HTTP 403 cannot use REAUTH_REQUIRED to retain revoked access',
      () async {
    final fixture = _EvidenceFixture();
    fixture.handler = (_) async =>
        fixture.response({'errorCode': 'REAUTH_REQUIRED'}, status: 403);
    await expectLater(fixture.repository.read(_application),
        throwsA(_failure(403, 'REAUTH_REQUIRED')));
    await _expectPermanentlyRevoked(fixture);
  });

  for (final status in [412, 429]) {
    test('HTTP $status is returned without retry or replacing binding version',
        () async {
      final fixture = _EvidenceFixture();
      final code = status == 412
          ? 'RESOURCE_VERSION_CONFLICT'
          : 'MANAGED_APPLICATION_REFRESH_THROTTLED';
      fixture.handler =
          (_) async => fixture.response({'errorCode': code}, status: status);
      await expectLater(fixture.repository.refresh(_application),
          throwsA(_failure(status, code)));
      expect(fixture.client.requests, hasLength(1));
      expect(fixture.client.requests.single.headers['If-Match'], '"3"');
      expect(fixture.denials, isEmpty);
      expect(fixture.client.closed, isFalse);
    });
  }

  test('uncertain refresh is not replayed and allows an explicit passive GET',
      () async {
    final fixture = _EvidenceFixture();
    fixture.handler = (_) async =>
        throw http.ClientException('fixture connection interrupted');
    await expectLater(fixture.repository.refresh(_application),
        throwsA(_failure(0, 'NETWORK_ERROR')));
    expect(fixture.client.requests, hasLength(1));
    expect(fixture.denials, isEmpty);
    fixture.handler = (_) async =>
        fixture.response(_evidence(state: 'PENDING', control: false));
    final result = await _success(fixture.repository.read(_application));
    expect(result.state, 'PENDING');
    expect(fixture.client.requests.map((request) => request.method),
        ['POST', 'GET']);
    expect(fixture.client.requests.last.headers['If-Match'], '"3"');
  });

  test('invalid successful refresh is not replayed or treated as evidence',
      () async {
    final fixture = _EvidenceFixture();
    fixture.handler = (_) async => fixture.response({'state': 'VERIFIED'});
    await expectLater(fixture.repository.refresh(_application),
        throwsA(_failure(502, _invalidEvidence)));
    expect(fixture.client.requests, hasLength(1));
    expect(fixture.denials, isEmpty);
    fixture.handler = (_) async => fixture.response(_evidence());
    await _success(fixture.repository.read(_application));
    expect(fixture.client.requests.map((request) => request.method),
        ['POST', 'GET']);
  });

  test(
      'oversized successful response stays invalid and cancels only its stream',
      () async {
    final fixture = _EvidenceFixture();
    var cancelled = false;
    final stream = StreamController<List<int>>(onCancel: () {
      cancelled = true;
    });
    addTearDown(() {
      unawaited(stream.close());
    });
    fixture.handler = (_) async => http.StreamedResponse(stream.stream, 200,
        contentLength: 2 * 1024 * 1024 + 1,
        headers: {'content-type': 'application/json'});
    await expectLater(fixture.repository.read(_application),
        throwsA(_failure(502, _invalidEvidence)));
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
    expect(fixture.client.closed, isFalse);
    expect(fixture.denials, isEmpty);
    expect(fixture.client.requests, hasLength(1));
  });

  test('chunked successful response is bounded without a content length',
      () async {
    final fixture = _EvidenceFixture();
    var cancelled = false;
    late final StreamController<List<int>> stream;
    stream = StreamController<List<int>>(onListen: () {
      stream.add(List.filled(1024 * 1024, 32));
      stream.add(List.filled(1024 * 1024 + 1, 32));
    }, onCancel: () {
      cancelled = true;
    });
    addTearDown(() {
      unawaited(stream.close());
    });
    fixture.handler = (_) async => http.StreamedResponse(stream.stream, 200,
        headers: {'content-type': 'application/json'});
    await expectLater(fixture.repository.read(_application),
        throwsA(_failure(502, _invalidEvidence)));
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
    expect(fixture.client.closed, isFalse);
    expect(fixture.denials, isEmpty);
    expect(fixture.client.requests, hasLength(1));
  });
  test('scoped view inherits a previously denied repository permanently',
      () async {
    final fixture = _EvidenceFixture();
    fixture.handler = (_) async =>
        fixture.response({'errorCode': 'ACCESS_DENIED'}, status: 403);
    await expectLater(fixture.repository.read(_application),
        throwsA(_failure(403, 'ACCESS_DENIED')));
    expect(fixture.denials, hasLength(1));
    expect(fixture.current, isTrue,
        reason:
            'The permanent repository lock is independent of caller state.');

    final viewDenials = <ApiFailure>[];
    final view =
        fixture.repository.scoped(() => true, onDenied: viewDenials.add);
    fixture.handler = (request) async => fixture.response(
        request.url.path.endsWith('/applications')
            ? _page([_applicationRecord()])
            : _evidence());
    final results = <Object?>[];
    for (final action in <Future<Object?> Function()>[
      () => view.read(_application),
      () => view.refresh(_application),
      () => view.applicationPage()
    ]) {
      results.add(await _outcome(_invoke(action)));
    }

    expect(fixture.client.requests, hasLength(1),
        reason: 'A new scoped view cannot reopen a denied repository.');
    expect(fixture.clientLookups, 1,
        reason: 'Known denial must stop before client acquisition.');
    expect(results, everyElement(_failure(409, 'WORKSPACE_CHANGED')));
    expect(fixture.denials, hasLength(1));
    expect(viewDenials, isEmpty);
    expect(fixture.client.closed, isFalse);
  });

  test('scoped hard denial revokes original and sibling contexts only once',
      () async {
    final fixture = _EvidenceFixture();
    final localDenials = <ApiFailure>[];
    final view =
        fixture.repository.scoped(() => true, onDenied: localDenials.add);
    final sibling = fixture.repository.scoped(() => true);
    fixture.handler = (_) async =>
        fixture.response({'errorCode': 'ACCESS_DENIED'}, status: 403);

    await expectLater(
        view.refresh(_application), throwsA(_failure(403, 'ACCESS_DENIED')));
    expect(localDenials, hasLength(1));
    expect(fixture.denials, hasLength(1));
    expect(fixture.current, isTrue,
        reason: 'The view must revoke its parent without mutating the caller.');
    final results = <Object?>[];
    for (final action in <Future<Object?> Function()>[
      () => fixture.repository.read(_application),
      () => view.read(_application),
      () => sibling.applicationPage(),
      () => fixture.repository.scoped(() => true).refresh(_application)
    ]) {
      results.add(await _outcome(_invoke(action)));
    }

    expect(fixture.denials, hasLength(1),
        reason: 'The original context reports one denial across all views.');
    expect(localDenials, hasLength(1));
    expect(fixture.client.requests, hasLength(1));
    expect(fixture.clientLookups, 1);
    expect(results, everyElement(_failure(409, 'WORKSPACE_CHANGED')));
    expect(fixture.client.closed, isFalse);
  });

  test('parent hard denial blocks a scoped POST awaiting authenticated client',
      () async {
    final fixture = _EvidenceFixture();
    final clientReady = Completer<http.Client>();
    var lookups = 0;
    final parent = ManagedApplicationEvidenceRepository(
        api: Api(() {
          lookups++;
          return lookups == 1
              ? clientReady.future
              : Future<http.Client>.value(fixture.client);
        }, baseUrl: fixture.api.baseUrl),
        tenantId: bindingTenant,
        binding: fixture.binding,
        current: () => fixture.current,
        onDenied: fixture.denials.add);
    final viewDenials = <ApiFailure>[];
    final view = parent.scoped(() => true, onDenied: viewDenials.add);
    addTearDown(() {
      if (!clientReady.isCompleted) {
        clientReady.complete(fixture.client);
      }
    });

    final pending = _outcome(_invoke(() => view.refresh(_application)));
    await Future<void>.delayed(Duration.zero);
    expect(lookups, 1,
        reason: 'The fixture must reach the pending client boundary.');
    expect(fixture.client.requests, isEmpty);
    fixture.handler = (_) async =>
        fixture.response({'errorCode': 'ACCESS_DENIED'}, status: 403);
    await expectLater(
        parent.read(_application), throwsA(_failure(403, 'ACCESS_DENIED')));
    expect(fixture.denials, hasLength(1));
    fixture.handler = (_) async => fixture.response(_evidence());
    clientReady.complete(fixture.client);
    final result = await pending;

    expect(fixture.client.requests, hasLength(1),
        reason: 'Parent revocation must stop before physical POST dispatch.');
    expect(fixture.client.requests.single.method, 'GET');
    expect(result, _failure(409, 'WORKSPACE_CHANGED'));
    expect(lookups, 2);
    expect(fixture.denials, hasLength(1));
    expect(viewDenials, isEmpty);
    expect(fixture.current, isTrue);
    expect(fixture.client.closed, isFalse);
  });

  test('scoped successful requests preserve the fixed binding contract',
      () async {
    final fixture = _EvidenceFixture();
    final viewDenials = <ApiFailure>[];
    final view =
        fixture.repository.scoped(() => true, onDenied: viewDenials.add);
    fixture.handler = (request) async => fixture.response(
        request.url.path.endsWith('/applications')
            ? _page([_applicationRecord()])
            : _evidence());

    expect(fixture.repository.isCurrent, isTrue);
    expect(view.isCurrent, isTrue);
    expect(fixture.clientLookups, 0,
        reason: 'Observing the guard cannot acquire authentication.');
    expect(view.binding, same(fixture.binding));
    expect(view.tenantId, bindingTenant);
    expect((await _success(view.read(_application))).version, 17);
    expect((await _success(view.refresh(_application))).version, 17);
    expect(
        (await _success(view.applicationPage())).items.single.id, _application);
    expect(fixture.client.requests.map((request) => request.method),
        ['GET', 'POST', 'GET']);
    for (final request in fixture.client.requests.take(2)) {
      expect(request.headers['If-Match'], '"3"');
    }
    expect(fixture.client.bodies, everyElement(isEmpty));
    expect(fixture.denials, isEmpty);
    expect(viewDenials, isEmpty);
    expect(fixture.client.closed, isFalse);
  });

  test('scoped local permission loss is permanent only for that view',
      () async {
    final fixture = _EvidenceFixture();
    var permitted = false;
    final viewDenials = <ApiFailure>[];
    final view =
        fixture.repository.scoped(() => permitted, onDenied: viewDenials.add);
    final sibling = fixture.repository.scoped(() => true);
    expect(view.isCurrent, isFalse);
    expect(fixture.repository.isCurrent, isTrue);
    expect(sibling.isCurrent, isTrue);
    expect(fixture.clientLookups, 0);

    permitted = true;
    for (final action in <Future<Object?> Function()>[
      () => view.read(_application),
      () => view.refresh(_application),
      () => view.applicationPage()
    ]) {
      await expectLater(
          _invoke(action), throwsA(_failure(409, 'WORKSPACE_CHANGED')));
    }
    expect(view.isCurrent, isFalse);
    await _success(sibling.read(_application));
    await _success(fixture.repository.refresh(_application));
    expect(fixture.client.requests.map((request) => request.method),
        ['GET', 'POST']);
    expect(fixture.clientLookups, 2);
    expect(fixture.denials, isEmpty);
    expect(viewDenials, isEmpty);
    expect(fixture.client.closed, isFalse);
  });

  for (final status in [401, 403]) {
    test(
        'scoped nested HTTP $status denial revokes every ancestor exactly once',
        () async {
      final fixture = _EvidenceFixture();
      final childDenials = <ApiFailure>[];
      final leafDenials = <ApiFailure>[];
      final child =
          fixture.repository.scoped(() => true, onDenied: childDenials.add);
      final leaf = child.scoped(() => true, onDenied: leafDenials.add);
      final sibling = fixture.repository.scoped(() => true);
      fixture.handler = (_) async =>
          fixture.response({'errorCode': 'ACCESS_DENIED'}, status: status);

      await expectLater(leaf.refresh(_application),
          throwsA(_failure(status, 'ACCESS_DENIED')));
      expect(fixture.repository.isCurrent, isFalse);
      expect(child.isCurrent, isFalse);
      expect(leaf.isCurrent, isFalse);
      expect(sibling.isCurrent, isFalse);
      expect(fixture.current, isTrue);
      for (final action in <Future<Object?> Function()>[
        () => fixture.repository.read(_application),
        () => child.read(_application),
        () => leaf.read(_application),
        () => sibling.read(_application),
        () => fixture.repository.scoped(() => true).refresh(_application)
      ]) {
        await expectLater(
            _invoke(action), throwsA(_failure(409, 'WORKSPACE_CHANGED')));
      }
      expect(fixture.denials, hasLength(1));
      expect(childDenials, hasLength(1));
      expect(leafDenials, hasLength(1));
      expect(childDenials.single, same(fixture.denials.single));
      expect(leafDenials.single, same(fixture.denials.single));
      expect(fixture.client.requests, hasLength(1));
      expect(fixture.clientLookups, 1);
      expect(fixture.client.closed, isFalse);
    });
  }

  test('scoped local parent loss closes descendants but preserves root access',
      () async {
    final fixture = _EvidenceFixture();
    var permitted = true;
    final child = fixture.repository.scoped(() => permitted);
    final leaf = child.scoped(() => true);
    final sibling = fixture.repository.scoped(() => true);
    expect(leaf.isCurrent, isTrue);
    permitted = false;
    expect(leaf.isCurrent, isFalse);
    permitted = true;
    expect(child.isCurrent, isFalse);
    expect(fixture.repository.isCurrent, isTrue);
    for (final action in <Future<Object?> Function()>[
      () => child.read(_application),
      () => leaf.refresh(_application),
      () => child.scoped(() => true).read(_application)
    ]) {
      await expectLater(
          _invoke(action), throwsA(_failure(409, 'WORKSPACE_CHANGED')));
    }
    await _success(fixture.repository.read(_application));
    await _success(sibling.read(_application));
    expect(fixture.client.requests, hasLength(2));
    expect(fixture.clientLookups, 2);
    expect(fixture.denials, isEmpty);
  });

  test('scoped nested recent authentication retains explicit recovery',
      () async {
    final fixture = _EvidenceFixture();
    final localDenials = <ApiFailure>[];
    final view = fixture.repository
        .scoped(() => true)
        .scoped(() => true, onDenied: localDenials.add);
    fixture.handler = (_) async =>
        fixture.response({'errorCode': 'REAUTH_REQUIRED'}, status: 401);
    await expectLater(
        view.refresh(_application), throwsA(_failure(401, 'REAUTH_REQUIRED')));
    expect(fixture.repository.isCurrent, isTrue);
    expect(view.isCurrent, isTrue);
    expect(fixture.client.requests, hasLength(1),
        reason: 'Authentication recovery cannot automatically replay POST.');
    fixture.handler = (_) async => fixture.response(_evidence());
    await _success(view.read(_application));
    await _success(fixture.repository.read(_application));
    await _success(view.refresh(_application));
    expect(fixture.client.requests.map((request) => request.method),
        ['POST', 'GET', 'GET', 'POST']);
    expect(fixture.denials, isEmpty);
    expect(localDenials, isEmpty);
    expect(fixture.client.closed, isFalse);
  });

  for (final status in [412, 429]) {
    test('scoped HTTP $status preserves context without retry or version swap',
        () async {
      final fixture = _EvidenceFixture();
      final view = fixture.repository.scoped(() => true);
      final code = status == 412
          ? 'RESOURCE_VERSION_CONFLICT'
          : 'MANAGED_APPLICATION_REFRESH_THROTTLED';
      fixture.handler =
          (_) async => fixture.response({'errorCode': code}, status: status);
      await expectLater(
          view.refresh(_application), throwsA(_failure(status, code)));
      expect(fixture.client.requests, hasLength(1));
      expect(fixture.repository.isCurrent, isTrue);
      expect(view.isCurrent, isTrue);
      fixture.handler = (_) async => fixture.response(_evidence());
      await _success(view.read(_application));
      await _success(fixture.repository.read(_application));
      expect(fixture.client.requests.map((request) => request.method),
          ['POST', 'GET', 'GET']);
      for (final request in fixture.client.requests) {
        expect(request.headers['If-Match'], '"3"');
      }
      expect(fixture.denials, isEmpty);
      expect(fixture.client.closed, isFalse);
    });
  }
}
