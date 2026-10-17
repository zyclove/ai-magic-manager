import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_agent_binding.dart';
import 'package:guardian/core/managed_application_evidence.dart';
import 'package:guardian/ui/managed_application_evidence_controller.dart';
import 'package:http/http.dart' as http;

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
const _instant = 1792209600000;
const _evidencePath = '/api/v1/tenants/$bindingTenant/managed-android/'
    'agent-bindings/$bindingId/applications/$_application/evidence';

Matcher _failure(int status, [String? code]) {
  final matcher =
      isA<ApiFailure>().having((failure) => failure.status, 'status', status);
  return code == null
      ? matcher
      : matcher.having((failure) => failure.code, 'code', code);
}

Future<void> _done(Future<void> pending) async {
  try {
    await pending;
  } catch (error) {
    fail('Controller operations must settle in state, got '
        '${error.runtimeType}: $error');
  }
}

Future<Object?> _outcome(Future<void> pending) async {
  try {
    await pending;
    return null;
  } catch (error) {
    return error;
  }
}

// Start the operation in the widget test zone so its timers use the fake clock.
// Flush the native response queue before advancing that clock toward a timeout.
Future<void> _widgetDone(
    WidgetTester tester, Future<void> Function() operation) async {
  var completed = false;
  Object? failure;
  unawaited(Future<void>.sync(operation).then<void>((_) {
    completed = true;
  }, onError: (Object error, StackTrace trace) {
    failure = error;
    completed = true;
  }));
  for (var frame = 0; frame < 8; frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(completed, isTrue,
      reason: 'The synthetic HTTP operation must settle.');
  expect(failure, isNull,
      reason: 'Controller failures belong in error state, not widget futures.');
}

class _AccessScope extends ChangeNotifier {
  bool current = true;
  bool get observed => hasListeners;

  void setCurrent(bool value) {
    current = value;
    notifyListeners();
  }

  void roleAba() {
    setCurrent(false);
    setCurrent(true);
  }
}

/// Synthetic HTTP only: neither an EMM provider nor an Android device is used.
class _RecordingHttp extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  final requests = <http.BaseRequest>[];
  final bodies = <List<int>>[];
  bool closed = false;

  _RecordingHttp(this.respond);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Count physical dispatch before finalization, retaining the real guards.
    requests.add(request);
    bodies.add(await request.finalize().toBytes());
    return respond(request);
  }

  @override
  void close() {
    closed = true;
  }
}

class _Fixture {
  final scope = _AccessScope();
  final denials = <ApiFailure>[];
  DateTime now = DateTime.fromMillisecondsSinceEpoch(_instant);
  Duration evidenceLifetime = const Duration(minutes: 1);
  String readState = 'ABSENT';
  int clientLookups = 0;
  Future<http.Client>? clientReady;
  bool controllerDisposed = false;
  Future<http.StreamedResponse> Function(http.BaseRequest)? handler;
  late final client = _RecordingHttp((request) =>
      handler == null ? defaultResponse(request) : handler!(request));
  late final repository = ManagedApplicationEvidenceRepository(
      api: Api(() async {
        clientLookups++;
        final pendingClient = clientReady;
        return pendingClient == null ? client : await pendingClient;
      }, baseUrl: 'https://application-controller.invalid/api/v1'),
      tenantId: bindingTenant,
      binding: const ManagedAgentBinding(
          id: bindingId,
          enrollmentId: bindingEnrollment,
          deviceId: bindingDevice,
          registrationId: bindingRegistration,
          state: 'VERIFIED',
          version: 3,
          createdAt: _instant - 60000,
          expiresAt: _instant + 540000,
          verifiedAt: _instant - 1000),
      current: () => scope.current,
      onDenied: denials.add);
  late final ManagedApplicationEvidenceController controller;

  _Fixture({bool listen = true}) {
    controller = ManagedApplicationEvidenceController(
        repository: repository,
        current: () => scope.current,
        accessChanges: listen ? scope : null,
        clock: () => now);
    addTearDown(() {
      closeController();
      scope.dispose();
      client.close();
    });
  }

  Json application({String id = _application}) => {
        'id': id,
        'displayName': id == _application ? '私有阅读器' : '私有课堂工具',
        'platform': 'ANDROID',
        'packageName':
            id == _application ? 'com.example.Reader' : 'com.example.Class',
        'profile': 'PRIMARY',
        'signingDigests': ['a' * 64],
        'evidenceStatus': 'ADMIN_DECLARED'
      };

  Json page({bool more = false, bool second = false}) => {
        'items': second
            ? [application(id: _application2)]
            : more
                ? [application()]
                : [application(), application(id: _application2)],
        'nextCursor': more ? _application : null
      };

  Json evidence({
    String applicationId = _application,
    String state = 'ABSENT',
    int version = 2,
    int? nextRefreshAt,
  }) {
    final verified = state == 'VERIFIED_IDENTITY';
    final time = now.millisecondsSinceEpoch;
    return {
      'bindingId': bindingId,
      'applicationId': applicationId,
      'state': state,
      'reasonCode': state == 'ABSENT'
          ? 'MANAGED_APPLICATION_EVIDENCE_REQUIRED'
          : verified
              ? 'MANAGED_APPLICATION_CONTROL_VERIFIED'
              : 'MANAGED_APPLICATION_REPORT_PENDING',
      'version': state == 'ABSENT' ? 0 : version,
      'profileScope': verified ? 'PRIMARY' : 'UNKNOWN',
      'systemControlAvailable': verified,
      'reportedAt': verified ? time - 2000 : null,
      'retrievedAt': verified ? time - 1000 : null,
      'expiresAt': verified ? time + evidenceLifetime.inMilliseconds : null,
      'nextRefreshAt': state == 'ABSENT' ? null : nextRefreshAt ?? time - 1,
      'controlOperations': verified
          ? [
              {'kind': 'APP_LAUNCH', 'effect': 'DENY', 'permission': null}
            ]
          : []
    };
  }

  http.StreamedResponse response(Object? value, {int status = 200}) {
    final bytes = utf8.encode(jsonEncode(value));
    return http.StreamedResponse(Stream.value(bytes), status,
        contentLength: bytes.length,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }

  Future<http.StreamedResponse> defaultResponse(
      http.BaseRequest request) async {
    if (request.url.path.endsWith('/applications')) return response(page());
    final segments = request.url.pathSegments;
    final applicationId = segments[segments.indexOf('applications') + 1];
    return response(evidence(
        applicationId: applicationId,
        state: request.method == 'POST' ? 'VERIFIED_IDENTITY' : readState,
        version: request.method == 'POST' ? 3 : 2,
        nextRefreshAt: request.method == 'POST'
            ? now.millisecondsSinceEpoch + 30000
            : null));
  }

  Future<void> open({String state = 'ABSENT'}) async {
    readState = state;
    await _done(controller.loadApplications());
    expect(controller.items, hasLength(2));
    await _done(controller.selectApplication(controller.items.first));
    expect(controller.selected?.id, _application);
    expect(controller.evidence?.state, state);
  }

  void closeController() {
    if (!controllerDisposed) {
      controllerDisposed = true;
      controller.dispose();
    }
  }

  Future<void> expectNoFurtherRequests(ManagedEvidenceApplication old) async {
    final count = client.requests.length, lookups = clientLookups;
    await _done(controller.loadApplications());
    await _done(controller.loadMore());
    await _done(controller.selectApplication(old));
    await _done(controller.refresh());
    await _done(controller.check());
    expect(client.requests, hasLength(count));
    expect(clientLookups, lookups);
    expect(client.closed, isFalse);
  }
}

void main() {
  test('loads a declaration and passively reads the selected application',
      () async {
    final fixture = _Fixture();
    final controller = fixture.controller;
    expect(controller.items, isEmpty);
    expect(controller.hasAccess, isTrue);
    expect(controller.canRefresh, isFalse);
    expect(controller.canCheck, isFalse);
    expect(fixture.client.requests, isEmpty);

    await fixture.open();

    expect(controller.busy, isFalse);
    expect(controller.unknownOutcome, isFalse);
    expect(controller.error, isNull);
    expect(controller.canRefresh, isTrue);
    expect(controller.canCheck, isTrue);
    expect(fixture.client.requests.map((request) => request.method),
        ['GET', 'GET']);
    expect(fixture.client.requests.first.url.path,
        '/api/v1/tenants/$bindingTenant/applications');
    expect(fixture.client.requests.last.url.path, _evidencePath);
    expect(fixture.client.requests.last.headers['If-Match'], '"3"');
  });

  test('only loaded declaration objects can be selected and pages are explicit',
      () async {
    final fixture = _Fixture();
    final controller = fixture.controller;
    fixture.handler = (request) async => fixture.response(fixture.page(
        more: !request.url.queryParameters.containsKey('cursor'),
        second: request.url.queryParameters.containsKey('cursor')));
    await _done(controller.loadApplications());
    expect(controller.items, hasLength(1));
    expect(controller.nextCursor, _application);
    expect(fixture.client.requests, hasLength(1));
    final foreign = ManagedEvidenceApplication.parse(
        fixture.application(id: _application3));
    final copied = ManagedEvidenceApplication.parse(fixture.application());
    await _done(controller.selectApplication(foreign));
    await _done(controller.selectApplication(copied));
    expect(controller.selected, isNull);
    expect(fixture.client.requests, hasLength(1));
    await _done(controller.loadMore());
    await _done(controller.loadMore());
    expect(
        controller.items.map((item) => item.id), [_application, _application2]);
    expect(controller.nextCursor, isNull);
    expect(fixture.client.requests, hasLength(2));
    expect(fixture.client.requests.last.url.queryParameters,
        {'limit': '50', 'cursor': _application});
    expect(() => controller.items.clear(), throwsUnsupportedError);
  });

  test('switching application clears old evidence and serializes reads',
      () async {
    final fixture = _Fixture();
    await fixture.open(state: 'VERIFIED_IDENTITY');
    final controller = fixture.controller;
    final first = controller.items.first, second = controller.items.last;
    final reply = Completer<http.StreamedResponse>();
    fixture.handler = (_) => reply.future;
    final pending = _outcome(controller.selectApplication(second));
    await Future<void>.delayed(Duration.zero);
    expect(controller.selected, same(second));
    expect(controller.evidence, isNull);
    expect(controller.busy, isTrue);
    final count = fixture.client.requests.length;
    await _done(controller.selectApplication(first));
    await _done(controller.loadApplications());
    await _done(controller.loadMore());
    await _done(controller.refresh());
    await _done(controller.check());
    expect(fixture.client.requests, hasLength(count));
    reply.complete(fixture.response(
        fixture.evidence(applicationId: _application2, state: 'FAILED')));
    expect(await pending, isNull);
    expect(controller.evidence?.applicationId, _application2);
    expect(controller.evidence?.controlAt(fixture.now), isNull);
    expect(controller.busy, isFalse);
  });

  test('one explicit refresh sends one fact free POST while busy', () async {
    final fixture = _Fixture();
    await fixture.open();
    final controller = fixture.controller;
    final reply = Completer<http.StreamedResponse>();
    fixture.handler = (_) => reply.future;
    final pending = _outcome(controller.refresh());
    await Future<void>.delayed(Duration.zero);
    expect(controller.busy, isTrue);
    expect(controller.canRefresh, isFalse);
    await _done(controller.refresh());
    await _done(controller.check());
    expect(fixture.client.requests, hasLength(3));
    final request = fixture.client.requests.last;
    expect(request.method, 'POST');
    expect(request.url.path, '$_evidencePath/refresh');
    expect(request.headers['If-Match'], '"3"');
    expect(fixture.client.bodies.last, isEmpty);
    reply.complete(fixture.response(fixture.evidence(
        state: 'VERIFIED_IDENTITY',
        version: 9,
        nextRefreshAt: fixture.now.millisecondsSinceEpoch + 30000)));
    expect(await pending, isNull);
    expect(controller.evidence?.version, 9);
    expect(controller.evidence?.controlAt(fixture.now), isNotNull);
    expect(controller.unknownOutcome, isFalse);
    expect(controller.busy, isFalse);
    expect(controller.canRefresh, isFalse);
    expect(controller.canCheck, isTrue);
  });

  test('post timeout permits only read reconciliation', () async {
    final fixture = _Fixture();
    await fixture.open(state: 'VERIFIED_IDENTITY');
    final controller = fixture.controller;
    final oldSelection = controller.items.last;
    fixture.handler =
        (_) async => throw TimeoutException('synthetic POST timeout');
    await _done(controller.refresh());
    expect(controller.error, _failure(0, 'NETWORK_ERROR'));
    expect(controller.unknownOutcome, isTrue);
    expect(controller.evidence, isNull);
    expect(controller.canRefresh, isFalse);
    expect(controller.canCheck, isTrue);
    fixture.now = fixture.now.add(const Duration(minutes: 10));
    final count = fixture.client.requests.length;
    await _done(controller.refresh());
    await _done(controller.selectApplication(oldSelection));
    await _done(controller.loadApplications());
    await _done(controller.loadMore());
    expect(fixture.client.requests, hasLength(count));
    expect(controller.selected?.id, _application);
    fixture.handler =
        (_) async => throw http.ClientException('synthetic GET failure');
    await _done(controller.check());
    expect(controller.unknownOutcome, isTrue);
    expect(controller.canRefresh, isFalse);
    fixture.handler =
        (_) async => fixture.response(fixture.evidence(state: 'FAILED'));
    await _done(controller.check());
    expect(controller.unknownOutcome, isFalse);
    expect(controller.canRefresh, isTrue);
    expect(controller.error, isNull);
    expect(fixture.client.requests.where((request) => request.method == 'POST'),
        hasLength(1));
    expect(fixture.client.requests.last.method, 'GET');
  });

  test('invalid successful POST hides old control until a valid passive read',
      () async {
    final fixture = _Fixture();
    await fixture.open(state: 'VERIFIED_IDENTITY');
    final controller = fixture.controller;
    fixture.handler = (_) async => fixture.response({'state': 'VERIFIED'});
    await _done(controller.refresh());
    expect(controller.error,
        _failure(502, 'INVALID_MANAGED_APPLICATION_EVIDENCE_RESPONSE'));
    expect(controller.unknownOutcome, isTrue);
    expect(controller.evidence, isNull);
    await _done(controller.refresh());
    expect(fixture.client.requests.where((request) => request.method == 'POST'),
        hasLength(1));
    fixture.handler = (_) async => fixture
        .response(fixture.evidence(state: 'VERIFIED_IDENTITY', version: 20));
    await _done(controller.check());
    expect(controller.unknownOutcome, isFalse);
    expect(controller.evidence?.version, 20);
    expect(controller.evidence?.controlAt(fixture.now), isNotNull);
    expect(fixture.client.requests.last.method, 'GET');
    expect(fixture.client.requests.last.headers['If-Match'], '"3"');
  });

  test('pending remains locked after cooldown', () async {
    final fixture = _Fixture();
    await fixture.open();
    final controller = fixture.controller;
    fixture.handler = (_) async => fixture.response(fixture.evidence(
        state: 'PENDING',
        nextRefreshAt: fixture.now.millisecondsSinceEpoch + 30000));
    await _done(controller.refresh());
    expect(controller.evidence?.state, 'PENDING');
    fixture.now = fixture.now.add(const Duration(seconds: 31));
    expect(controller.canRefresh, isFalse);
    expect(controller.canCheck, isTrue);
    final count = fixture.client.requests.length;
    await _done(controller.refresh());
    expect(fixture.client.requests, hasLength(count));
    await _done(controller.check());
    expect(controller.evidence?.state, 'PENDING');
    expect(controller.canRefresh, isFalse);
    expect(fixture.client.requests.last.method, 'GET');
    expect(fixture.client.requests.where((request) => request.method == 'POST'),
        hasLength(1));
  });

  test('429 requires an explicit GET before any later refresh', () async {
    final fixture = _Fixture();
    await fixture.open();
    final controller = fixture.controller;
    fixture.handler = (_) async => fixture.response(
        {'errorCode': 'MANAGED_APPLICATION_REFRESH_THROTTLED'},
        status: 429);
    await _done(controller.refresh());
    expect(controller.error,
        _failure(429, 'MANAGED_APPLICATION_REFRESH_THROTTLED'));
    expect(controller.canRefresh, isFalse);
    expect(controller.canCheck, isTrue);
    fixture.now = fixture.now.add(const Duration(minutes: 5));
    final count = fixture.client.requests.length;
    await _done(controller.refresh());
    expect(fixture.client.requests, hasLength(count));
    fixture.handler = (_) async => fixture.response(fixture.evidence(
        state: 'FAILED',
        nextRefreshAt: fixture.now.millisecondsSinceEpoch + 30000));
    await _done(controller.check());
    expect(controller.canRefresh, isFalse);
    fixture.now = fixture.now.add(const Duration(seconds: 30));
    expect(controller.canRefresh, isTrue);
    expect(fixture.client.requests.where((request) => request.method == 'POST'),
        hasLength(1));
    expect(fixture.client.requests.last.method, 'GET');
  });

  test('version conflict never retries with replacement binding', () async {
    final fixture = _Fixture();
    await fixture.open(state: 'VERIFIED_IDENTITY');
    final controller = fixture.controller;
    final old = controller.items.first;
    fixture.handler = (_) async => fixture
        .response({'errorCode': 'RESOURCE_VERSION_CONFLICT'}, status: 412);
    await _done(controller.refresh());
    expect(controller.needsParentRefresh, isTrue);
    expect(controller.items, isEmpty);
    expect(controller.selected, isNull);
    expect(controller.evidence, isNull);
    expect(controller.canRefresh, isFalse);
    expect(controller.canCheck, isFalse);
    expect(controller.error, _failure(412, 'RESOURCE_VERSION_CONFLICT'));
    expect(fixture.client.requests.last.headers['If-Match'], '"3"');
    fixture.scope.roleAba();
    await fixture.expectNoFurtherRequests(old);
    expect(controller.needsParentRefresh, isTrue);
  });

  test('explicit recent authentication recovery never becomes hard revocation',
      () async {
    final fixture = _Fixture();
    await fixture.open();
    final controller = fixture.controller;
    fixture.handler = (_) async =>
        fixture.response({'errorCode': 'REAUTH_REQUIRED'}, status: 401);
    await _done(controller.refresh());
    expect(controller.needsReauth, isTrue);
    expect(controller.hasAccess, isTrue);
    expect(controller.unknownOutcome, isFalse);
    expect(controller.canRefresh, isFalse);
    expect(fixture.denials, isEmpty);
    final count = fixture.client.requests.length;
    await _done(controller.refresh());
    expect(fixture.client.requests, hasLength(count));
    // The caller performs safety verification; this synthetic transport now
    // accepts its explicit reconciliation read. It never fakes device proof.
    fixture.handler = fixture.defaultResponse;
    await _done(controller.check());
    expect(controller.needsReauth, isFalse);
    expect(controller.canRefresh, isTrue);
    await _done(controller.refresh());
    expect(controller.evidence?.state, 'VERIFIED_IDENTITY');
    expect(fixture.client.requests.map((request) => request.method),
        ['GET', 'GET', 'POST', 'GET', 'POST']);
  });

  test(
      'hard denial clears private state and blocks every later physical request',
      () async {
    for (final status in [401, 403]) {
      final fixture = _Fixture();
      await fixture.open(state: 'VERIFIED_IDENTITY');
      final controller = fixture.controller;
      final old = controller.items.first;
      fixture.handler = (_) async =>
          fixture.response({'errorCode': 'ACCESS_DENIED'}, status: status);
      await _done(controller.check());
      expect(controller.hasAccess, isFalse);
      expect(controller.items, isEmpty);
      expect(controller.nextCursor, isNull);
      expect(controller.selected, isNull);
      expect(controller.evidence, isNull);
      expect(controller.busy, isFalse);
      expect(controller.error, _failure(status, 'ACCESS_DENIED'));
      expect(fixture.denials, hasLength(1));
      expect(fixture.scope.current, isTrue);
      await fixture.expectNoFurtherRequests(old);
    }
  });

  test('role ABA remains revoked after returning to the same role', () async {
    final fixture = _Fixture();
    await fixture.open(state: 'VERIFIED_IDENTITY');
    final controller = fixture.controller;
    final old = controller.items.first;
    fixture.scope.roleAba();
    expect(fixture.scope.current, isTrue);
    expect(controller.hasAccess, isFalse);
    expect(controller.items, isEmpty);
    expect(controller.selected, isNull);
    expect(controller.evidence, isNull);
    await fixture.expectNoFurtherRequests(old);
    expect(fixture.denials, isEmpty);
  });

  test('late catalog response cannot revive a lost parent without a notifier',
      () async {
    final fixture = _Fixture(listen: false);
    final controller = fixture.controller;
    final reply = Completer<http.StreamedResponse>();
    fixture.handler = (_) => reply.future;
    final pending = _outcome(controller.loadApplications());
    await Future<void>.delayed(Duration.zero);
    expect(fixture.client.requests, hasLength(1));
    fixture.scope.setCurrent(false);
    reply.complete(fixture.response(fixture.page()));
    expect(await pending, isNull);
    expect(controller.hasAccess, isFalse);
    expect(controller.items, isEmpty);
    fixture.scope.setCurrent(true);
    final old = ManagedEvidenceApplication.parse(fixture.application());
    await fixture.expectNoFurtherRequests(old);
    expect(controller.hasAccess, isFalse);
  });

  test('manual invalidation discards a late application read permanently',
      () async {
    final fixture = _Fixture();
    await fixture.open(state: 'VERIFIED_IDENTITY');
    final controller = fixture.controller;
    final old = controller.items.last;
    final reply = Completer<http.StreamedResponse>();
    fixture.handler = (_) => reply.future;
    final pending = _outcome(controller.selectApplication(old));
    await Future<void>.delayed(Duration.zero);
    expect(controller.busy, isTrue);
    expect(controller.invalidate, returnsNormally);
    expect(controller.hasAccess, isFalse);
    expect(controller.items, isEmpty);
    expect(controller.selected, isNull);
    expect(controller.evidence, isNull);
    reply.complete(fixture.response(fixture.evidence(
        applicationId: _application2, state: 'VERIFIED_IDENTITY')));
    expect(await pending, isNull);
    expect(controller.evidence, isNull);
    await fixture.expectNoFurtherRequests(old);
  });

  for (final disposing in [false, true]) {
    test(
        'late authenticated client cannot send after '
        '${disposing ? 'disposal' : 'invalidation'}', () async {
      final fixture = _Fixture();
      await fixture.open(state: 'VERIFIED_IDENTITY');
      final controller = fixture.controller;
      final old = controller.items.first;
      final gate = Completer<http.Client>();
      fixture.clientReady = gate.future;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete(fixture.client);
      });
      final requests = fixture.client.requests.length;
      final lookups = fixture.clientLookups;
      final pending = _outcome(controller.refresh());
      await Future<void>.delayed(Duration.zero);
      expect(controller.busy, isTrue);
      expect(fixture.clientLookups, lookups + 1);
      expect(fixture.client.requests, hasLength(requests));
      if (disposing) {
        fixture.closeController();
      } else {
        controller.invalidate();
      }
      gate.complete(fixture.client);
      expect(await pending, isNull);
      expect(controller.hasAccess, isFalse);
      expect(controller.items, isEmpty);
      expect(controller.selected, isNull);
      expect(controller.evidence, isNull);
      expect(controller.busy, isFalse);
      expect(fixture.client.requests, hasLength(requests));
      expect(fixture.client.closed, isFalse);
      await fixture.expectNoFurtherRequests(old);
    });
  }

  testWidgets('expiry hides operations immediately and actively notifies',
      (tester) async {
    final fixture = _Fixture()
      ..readState = 'VERIFIED_IDENTITY'
      ..evidenceLifetime = const Duration(seconds: 5);
    final controller = fixture.controller;
    var notifications = 0;
    controller.addListener(() => notifications++);
    await _widgetDone(tester, controller.loadApplications);
    expect(controller.items, hasLength(2));
    await _widgetDone(
        tester, () => controller.selectApplication(controller.items.first));
    expect(controller.evidence, isNotNull);
    final snapshot = controller.evidence!;
    expect(snapshot.controlAt(fixture.now), isNotNull);
    final count = notifications, requests = fixture.client.requests.length;
    fixture.now = fixture.now.add(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(notifications, greaterThan(count),
        reason:
            'An already expanded operation view must be rebuilt at expiry.');
    expect(controller.evidence, same(snapshot));
    expect(snapshot.state, 'VERIFIED_IDENTITY');
    expect(snapshot.stateAt(fixture.now), 'STALE');
    expect(controller.evidence?.controlAt(fixture.now), isNull);
    expect(controller.hasAccess, isTrue);
    expect(fixture.client.requests, hasLength(requests),
        reason: 'Expiry cannot silently refresh provider evidence.');
    fixture.closeController();
    expect(tester.takeException(), isNull);
  });

  testWidgets('dispose ignores late POST and releases listeners and timers',
      (tester) async {
    final fixture = _Fixture()..readState = 'VERIFIED_IDENTITY';
    final controller = fixture.controller;
    await _widgetDone(tester, controller.loadApplications);
    expect(controller.items, hasLength(2));
    final old = controller.items.first;
    await _widgetDone(tester, () => controller.selectApplication(old));
    final reply = Completer<http.StreamedResponse>();
    fixture.handler = (_) => reply.future;
    var notifications = 0;
    controller.addListener(() => notifications++);
    final pending = _outcome(controller.refresh());
    for (var frame = 0; frame < 4; frame++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(controller.busy, isTrue);
    expect(fixture.client.requests, hasLength(3));
    expect(fixture.scope.observed, isTrue);
    fixture.closeController();
    expect(fixture.scope.observed, isFalse);
    final before = notifications;
    expect(fixture.scope.roleAba, returnsNormally);
    reply.complete(fixture
        .response(fixture.evidence(state: 'VERIFIED_IDENTITY', version: 30)));
    await _widgetDone(tester, () async {
      expect(await pending, isNull);
    });
    // Leave the original expiry in the future. The widget-test binding then
    // detects an uncancelled timer instead of this test consuming its deadline.
    await tester.pump(const Duration(milliseconds: 1));
    expect(notifications, before);
    expect(controller.hasAccess, isFalse);
    expect(controller.items, isEmpty);
    expect(controller.selected, isNull);
    expect(controller.evidence, isNull);
    expect(controller.busy, isFalse);
    await _widgetDone(tester, () => fixture.expectNoFurtherRequests(old));
    expect(tester.takeException(), isNull);
  });
}
