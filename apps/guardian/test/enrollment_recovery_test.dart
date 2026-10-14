import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/enrollment_recovery.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const actor = 'adult';
const tenant = '11111111-1111-4111-8111-111111111111';
const subject = '22222222-2222-4222-8222-222222222222';
const request = '33333333-3333-4333-8333-333333333333';
const device = '44444444-4444-4444-8444-444444444444';
const registration = '55555555-5555-4555-8555-555555555555';
const timestamp = 1800000000000;
const scope = EnrollmentScope(actorId: actor, tenantId: tenant, role: 'OWNER');

EnrollmentIntent intent() => const EnrollmentIntent(
    scope: scope,
    requestId: request,
    subjectId: subject,
    platform: 'ANDROID',
    createdAt: timestamp);

Json ticket() => {
      'id': request,
      'token': 'a' * 43,
      'expiresAt': timestamp + 900000,
      'state': 'PENDING_CLAIM'
    };

Json view({String state = 'PENDING_CLAIM', int failures = 0}) => {
      'id': request,
      'subjectId': subject,
      'platform': 'ANDROID',
      'requestedMode': 'BYOD',
      'state': state,
      'expiresAt': state == 'EXPIRED' ? timestamp - 1 : timestamp + 900000,
      'deviceId':
          ['AWAITING_CONFIRMATION', 'CONFIRMED', 'LOCKED'].contains(state)
              ? device
              : null,
      'pairingFailures': failures
    };

Json deviceView() => {
      'id': device,
      'subjectId': subject,
      'registrationId': registration,
      'displayName': '孩子的手机',
      'platform': 'ANDROID',
      'osVersion': '15',
      'state': 'ACTIVE',
      'managementMode': 'BYOD',
      'controlLevel': 'LIMITED',
      'lastHeartbeatAt': null,
      'observationStatus': 'UNKNOWN',
      'keyThumbprint': 'b' * 43,
      'version': 1
    };

http.Response response(Object? value, [int status = 200]) =>
    http.Response(value == null ? '' : jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

http.Response failure(int status, String code) =>
    response({'errorCode': code}, status);

class MemoryJournal implements EnrollmentJournal {
  EnrollmentIntent? value;
  Object? readError, writeError, removeError;
  Completer<void>? readWait;
  Completer<void>? writeWait;
  int writes = 0, removes = 0;
  final events = <String>[];
  @override
  Future<EnrollmentIntent?> read(EnrollmentScope scope) async {
    if (readWait != null) await readWait!.future;
    if (readError != null) throw readError!;
    return value;
  }

  @override
  Future<void> write(EnrollmentIntent intent) async {
    writes++;
    events.add('write');
    if (writeWait != null) await writeWait!.future;
    if (writeError != null) throw writeError!;
    value = intent;
    events.add('saved');
  }

  @override
  Future<void> remove(EnrollmentIntent intent) async {
    removes++;
    if (removeError != null) throw removeError!;
    value = null;
  }
}

class Fixture {
  final MemoryJournal journal;
  final requests = <http.Request>[];
  bool current = true;
  int clock = timestamp, ids = 0;
  late final EnrollmentGateway gateway;
  late final EnrollmentController controller;
  Fixture(
      {MemoryJournal? journal,
      FutureOr<http.Response> Function(http.Request)? handler})
      : journal = journal ?? MemoryJournal() {
    final client = MockClient((req) async {
      requests.add(req);
      this.journal.events.add(req.method);
      return handler == null
          ? req.method == 'POST'
              ? response(ticket(), 201)
              : response(view())
          : handler(req);
    });
    gateway = EnrollmentGateway(Api(() async => client));
    controller = EnrollmentController(
        scope: scope,
        journal: this.journal,
        gateway: gateway,
        isCurrent: () => current,
        newId: () {
          ids++;
          return request;
        },
        now: () => clock);
  }
}

void main() {
  test('ticket and management view parse the exact bound DTOs', () {
    final parsed = EnrollmentTicket.parse(ticket(), intent());
    expect(parsed.id, request);
    expect(parsed.token, 'a' * 43);
    expect(parsed.json.keys.toSet(), {'id', 'token', 'expiresAt', 'state'});
    final progress = EnrollmentView.parse(view(), intent());
    expect(progress.subjectId, subject);
    expect(progress.deviceId, isNull);
  });

  final badTickets = <String, void Function(Json)>{
    'extra field': (v) => v['secretExtra'] = 'excluded',
    'other ID': (v) => v['id'] = device,
    'short token': (v) => v['token'] = 'a' * 42,
    'non-url token': (v) => v['token'] = '+' * 43,
    'fractional expiry': (v) => v['expiresAt'] = timestamp + 0.5,
    'unsafe expiry': (v) => v['expiresAt'] = 9007199254740992,
    'other state': (v) => v['state'] = 'CONFIRMED',
  };
  for (final entry in badTickets.entries) {
    test('ticket rejects ${entry.key}', () {
      final raw = ticket();
      entry.value(raw);
      expect(() => EnrollmentTicket.parse(raw, intent()),
          throwsA(isA<ApiFailure>()));
    });
  }

  final badViews = <String, void Function(Json)>{
    'extra secret': (v) => v['token'] = 'a' * 43,
    'other request': (v) => v['id'] = device,
    'other subject': (v) => v['subjectId'] = device,
    'other platform': (v) => v['platform'] = 'ANDROID_TV',
    'other mode': (v) => v['requestedMode'] = 'FULLY_MANAGED',
    'unknown state': (v) => v['state'] = 'INACTIVE',
    'fractional count': (v) => v['pairingFailures'] = 0.5,
    'negative count': (v) => v['pairingFailures'] = -1,
    'unbounded count': (v) => v['pairingFailures'] = 11,
    'unbound pending device': (v) => v['deviceId'] = device,
    'missing claimed device': (v) => v['state'] = 'AWAITING_CONFIRMATION',
  };
  for (final entry in badViews.entries) {
    test('management view rejects ${entry.key}', () {
      final raw = view();
      entry.value(raw);
      expect(() => EnrollmentView.parse(raw, intent()),
          throwsA(isA<ApiFailure>()));
    });
  }

  test('gateway creates with Client-Request-Id and the frozen BYOD body',
      () async {
    final f = Fixture();
    final result = await f.gateway.create(intent(), isCurrent: () => true);
    expect(result.id, request);
    final sent = f.requests.single;
    expect(sent.headers['client-request-id'], request);
    expect(sent.headers.containsKey('idempotency-key'), isFalse);
    expect(sent.url.path, '/api/v1/tenants/$tenant/enrollments');
    expect(jsonDecode(sent.body),
        {'subjectId': subject, 'platform': 'ANDROID', 'requestedMode': 'BYOD'});
  });

  test('gateway checks scope before sending and after an awaited client',
      () async {
    var current = false, sends = 0;
    final waiting = Completer<http.Client>();
    final client = MockClient((_) async {
      sends++;
      return response(ticket(), 201);
    });
    final gateway = EnrollmentGateway(Api(() => waiting.future));
    await expectLater(gateway.create(intent(), isCurrent: () => current),
        throwsA(isA<ApiFailure>()));
    current = true;
    final pending = gateway.create(intent(), isCurrent: () => current);
    final assertion = expectLater(pending, throwsA(isA<ApiFailure>()));
    current = false;
    waiting.complete(client);
    await assertion;
    expect(sends, 0);
  });

  test('initialize restores the original pointer using GET only', () async {
    final journal = MemoryJournal()..value = intent();
    final f = Fixture(journal: journal);
    await f.controller.initialize();
    expect(f.controller.loading, isFalse);
    expect(f.controller.pending?.requestId, request);
    expect(f.controller.progress?.state, 'PENDING_CLAIM');
    expect(f.controller.ticket, isNull);
    expect(f.requests.single.method, 'GET');
    expect(f.requests.single.url.path,
        '/api/v1/tenants/$tenant/enrollment-creation-results/$request');
    expect(journal.writes, 0);
    expect(f.ids, 0);
  });

  test('create persists before HTTP and holds the token only in memory',
      () async {
    final f = Fixture();
    await f.controller.initialize();
    await f.controller.create(subjectId: subject, platform: 'ANDROID');
    expect(f.journal.events, ['write', 'saved', 'POST']);
    expect(f.controller.ticket?.token, 'a' * 43);
    expect(f.journal.value?.requestId, request);
    expect(f.controller.canCreate, isFalse);
    f.clock = timestamp + 900000;
    expect(f.controller.ticket, isNull,
        reason: 'Expired QR must not be exposed.');
    expect(f.journal.value, isNotNull);
  });

  test('storage write failure sends zero HTTP requests', () async {
    final journal = MemoryJournal()..writeError = StateError('private-storage');
    final f = Fixture(journal: journal);
    await f.controller.initialize();
    await f.controller.create(subjectId: subject, platform: 'ANDROID');
    expect(f.requests, isEmpty);
    expect(f.controller.error, isNotNull);
    expect(f.controller.ticket, isNull);
  });

  test('explicit storage retry saves the same intent before its only POST',
      () async {
    final journal = MemoryJournal()..writeError = StateError('unavailable');
    final f = Fixture(journal: journal);
    await f.controller.initialize();
    await f.controller.create(subjectId: subject, platform: 'ANDROID');
    final original = f.controller.pending;
    expect(original, isNotNull);
    expect(f.requests, isEmpty);
    expect(f.ids, 1);
    expect(f.controller.canRetryCreation, isTrue);
    journal.writeError = null;
    await f.controller.retryCreation();
    expect(journal.writes, 2);
    expect(journal.value, same(original));
    expect(f.controller.pending, same(original));
    expect(f.ids, 1);
    expect(f.requests.single.method, 'POST');
    expect(f.requests.single.headers['client-request-id'], request);
    expect(jsonDecode(f.requests.single.body),
        {'subjectId': subject, 'platform': 'ANDROID', 'requestedMode': 'BYOD'});
    expect(journal.events, ['write', 'write', 'saved', 'POST']);
    expect(f.controller.ticket?.id, request);
  });

  test('storage read failure cannot enable a fresh create', () async {
    final journal = MemoryJournal()..readError = StateError('unavailable');
    final f = Fixture(journal: journal);
    await f.controller.initialize();
    await f.controller.create(subjectId: subject, platform: 'ANDROID');
    expect(f.controller.canCreate, isFalse);
    expect(f.requests, isEmpty);
    expect(journal.writes, 0);
  });

  test('a scope change while saving stops HTTP without losing the pointer',
      () async {
    final journal = MemoryJournal()..writeWait = Completer<void>();
    final f = Fixture(journal: journal);
    await f.controller.initialize();
    final creating =
        f.controller.create(subjectId: subject, platform: 'ANDROID');
    await Future<void>.delayed(Duration.zero);
    f.current = false;
    journal.writeWait!.complete();
    await creating;
    expect(f.requests, isEmpty);
    expect(journal.value?.requestId, request);
    expect(f.controller.ticket, isNull);
  });

  test('unknown creation permits explicit same-ID retry only after GET404',
      () async {
    var posts = 0;
    final f = Fixture(handler: (req) {
      if (req.method == 'GET') {
        return failure(404, 'ENROLLMENT_CREATION_UNAVAILABLE');
      }
      if (++posts == 1) throw http.ClientException('response lost');
      return response(ticket(), 201);
    });
    await f.controller.initialize();
    await f.controller.create(subjectId: subject, platform: 'ANDROID');
    expect(f.controller.pending?.requestId, request);
    expect(f.controller.canRetryCreation, isFalse);
    await f.controller.retryCreation();
    expect(posts, 1);
    await f.controller.check();
    expect(f.controller.canRetryCreation, isTrue);
    await f.controller.startAgain();
    expect(f.controller.pending?.requestId, request);
    await f.controller.retryCreation();
    expect(posts, 2);
    expect(f.ids, 1);
    final writes = f.requests.where((req) => req.method == 'POST').toList();
    expect(writes[0].headers['client-request-id'], request);
    expect(writes[1].headers['client-request-id'], request);
    expect(writes[1].body, writes[0].body);
    expect(f.controller.ticket?.id, request);
  });

  test('duplicate-ID response checks the creator-bound result without a POST',
      () async {
    final f = Fixture(
        handler: (req) => req.method == 'POST'
            ? failure(409, 'ENROLLMENT_REQUEST_ALREADY_USED')
            : response(view()));
    await f.controller.initialize();
    await f.controller.create(subjectId: subject, platform: 'ANDROID');
    expect(f.requests.map((req) => req.method), ['POST', 'GET']);
    expect(f.controller.progress?.state, 'PENDING_CLAIM');
    expect(f.controller.ticket, isNull);
    expect(f.controller.canRetryCreation, isFalse);
  });

  test('definite pre-insert MFA rejection allows the same original request',
      () async {
    var posts = 0;
    final f = Fixture(
        handler: (_) => ++posts == 1
            ? failure(401, 'REAUTH_REQUIRED')
            : response(ticket(), 201));
    await f.controller.initialize();
    await f.controller.create(subjectId: subject, platform: 'ANDROID');
    expect(f.controller.canRetryCreation, isTrue);
    await f.controller.retryCreation();
    expect(f.ids, 1);
    expect(f.requests.length, 2);
    expect(f.requests.last.body, f.requests.first.body);
    expect(f.controller.ticket, isNotNull);
  });

  test('a 5xx does not permit a new ID or an automatic creation replay',
      () async {
    final f = Fixture(handler: (_) => failure(503, 'REQUEST_FAILED'));
    await f.controller.initialize();
    await f.controller.create(subjectId: subject, platform: 'ANDROID');
    await f.controller.retryCreation();
    await f.controller.startAgain();
    expect(f.requests.length, 1);
    expect(f.controller.pending?.requestId, request);
    expect(f.controller.canCreate, isFalse);
  });

  for (final status in [401, 403]) {
    test('GET$status hides a previously issued token and progress', () async {
      final f = Fixture(
          handler: (req) => req.method == 'POST'
              ? response(ticket(), 201)
              : failure(
                  status, status == 401 ? 'UNAUTHENTICATED' : 'SCOPE_DENIED'));
      await f.controller.initialize();
      await f.controller.create(subjectId: subject, platform: 'ANDROID');
      expect(f.controller.ticket, isNotNull);
      await f.controller.check();
      expect(f.controller.ticket, isNull);
      expect(f.controller.progress, isNull);
      expect(f.controller.pending?.requestId, request);
      expect(f.controller.canRetryCreation, isFalse);
    });
  }

  test('conceal discards a late creation result and resumes with GET only',
      () async {
    final waiting = Completer<http.Response>();
    final f = Fixture(
        handler: (req) =>
            req.method == 'POST' ? waiting.future : response(view()));
    await f.controller.initialize();
    final creating =
        f.controller.create(subjectId: subject, platform: 'ANDROID');
    await Future<void>.delayed(Duration.zero);
    f.controller.conceal();
    waiting.complete(response(ticket(), 201));
    await creating;
    expect(f.controller.ticket, isNull);
    expect(f.controller.progress, isNull);
    expect(f.journal.value?.requestId, request);
    await f.controller.check();
    expect(f.controller.progress?.state, 'PENDING_CLAIM');
    expect(f.controller.ticket, isNull);
    expect(f.requests.map((req) => req.method), ['POST', 'GET']);
  });

  test('duplicate create cannot allocate or dispatch a second request',
      () async {
    final waiting = Completer<http.Response>();
    final f = Fixture(handler: (_) => waiting.future);
    await f.controller.initialize();
    final creating =
        f.controller.create(subjectId: subject, platform: 'ANDROID');
    await Future<void>.delayed(Duration.zero);
    await f.controller.create(subjectId: subject, platform: 'ANDROID_TV');
    expect(f.ids, 1);
    expect(f.journal.writes, 1);
    expect(f.requests.length, 1);
    waiting.complete(response(ticket(), 201));
    await creating;
  });

  test('expired recovery must cancel and read CANCELLED before starting again',
      () async {
    var state = 'EXPIRED';
    final f = Fixture(
        journal: MemoryJournal()..value = intent(),
        handler: (req) {
          if (req.method == 'DELETE') {
            state = 'CANCELLED';
            return response(null, 204);
          }
          return response(view(state: state));
        });
    await f.controller.initialize();
    expect(f.controller.canCancel, isTrue);
    expect(f.controller.canStartAgain, isFalse);
    await f.controller.startAgain();
    expect(f.journal.value, isNotNull);
    await f.controller.cancel();
    expect(f.requests.map((req) => req.method), ['GET', 'DELETE', 'GET']);
    expect(f.controller.progress?.state, 'CANCELLED');
    expect(f.controller.canStartAgain, isTrue);
    await f.controller.startAgain();
    expect(f.journal.value, isNull);
    expect(f.controller.pending, isNull);
    expect(f.controller.canCreate, isTrue);
  });

  test('unknown cancellation is resolved by GET without repeating DELETE',
      () async {
    var cancelled = false;
    final f = Fixture(
        journal: MemoryJournal()..value = intent(),
        handler: (req) {
          if (req.method == 'DELETE') {
            cancelled = true;
            throw http.ClientException('lost cancellation response');
          }
          return response(
              view(state: cancelled ? 'CANCELLED' : 'PENDING_CLAIM'));
        });
    await f.controller.initialize();
    await f.controller.cancel();
    expect(f.controller.progress?.state, 'CANCELLED');
    expect(f.requests.where((req) => req.method == 'DELETE').length, 1);
    expect(f.controller.pending, isNotNull);
  });

  for (final terminal in ['CANCELLED', 'LOCKED', 'CONFIRMED']) {
    test('only verified $terminal can explicitly release the original pointer',
        () async {
      final f = Fixture(
          journal: MemoryJournal()..value = intent(),
          handler: (_) => response(
              view(state: terminal, failures: terminal == 'LOCKED' ? 5 : 0)));
      await f.controller.initialize();
      expect(f.controller.canCancel, isFalse);
      expect(f.controller.canStartAgain, isTrue);
      await f.controller.startAgain();
      expect(f.controller.pending, isNull);
      expect(f.journal.removes, 1);
      expect(f.requests.length, 1);
    });
  }

  test(
      'journal removal failure preserves the terminal pointer and blocks create',
      () async {
    final journal = MemoryJournal()
      ..value = intent()
      ..removeError = StateError('unavailable');
    final f = Fixture(
        journal: journal, handler: (_) => response(view(state: 'CANCELLED')));
    await f.controller.initialize();
    await f.controller.startAgain();
    expect(f.controller.pending?.requestId, request);
    expect(f.controller.canCreate, isFalse);
    expect(f.controller.error, isNotNull);
  });

  test('wrong code is a committed attempt and is followed by GET only',
      () async {
    var failures = 0;
    final f = Fixture(
        journal: MemoryJournal()..value = intent(),
        handler: (req) {
          if (req.method == 'POST') {
            expect(jsonDecode(req.body), {'pairingCode': 'AB12CD34'});
            failures++;
            return failure(403, 'PAIRING_VERIFICATION_FAILED');
          }
          return response(
              view(state: 'AWAITING_CONFIRMATION', failures: failures));
        });
    await f.controller.initialize();
    await f.controller.confirm(' ab12cd34 ');
    expect(f.controller.progress?.pairingFailures, 1);
    expect(f.requests.map((req) => req.method), ['GET', 'POST', 'GET']);
    expect(f.journal.value?.requestId, request);
    expect(f.controller.ticket, isNull);
  });

  test('unknown confirmation checks the fact without replaying the code',
      () async {
    var confirmed = false;
    final f = Fixture(
        journal: MemoryJournal()..value = intent(),
        handler: (req) {
          if (req.method == 'POST') {
            confirmed = true;
            throw http.ClientException('lost confirmation');
          }
          return response(
              view(state: confirmed ? 'CONFIRMED' : 'AWAITING_CONFIRMATION'));
        });
    await f.controller.initialize();
    await f.controller.confirm('AB12CD34');
    expect(f.controller.progress?.state, 'CONFIRMED');
    await f.controller.confirm('AB12CD34');
    expect(f.requests.where((req) => req.method == 'POST').length, 1);
  });

  test('confirmation response alone cannot declare the registration confirmed',
      () async {
    final f = Fixture(
        journal: MemoryJournal()..value = intent(),
        handler: (req) => req.method == 'POST'
            ? response(deviceView())
            : response(view(state: 'AWAITING_CONFIRMATION')));
    await f.controller.initialize();
    await f.controller.confirm('AB12CD34');
    expect(f.controller.progress?.state, 'AWAITING_CONFIRMATION');
    expect(f.requests.map((req) => req.method), ['GET', 'POST', 'GET']);
  });

  test('a confirm device with the wrong binding is rejected', () async {
    final f = Fixture(
        handler: (_) => response({...deviceView(), 'id': registration}));
    await expectLater(
        f.gateway.confirm(intent(), 'AB12CD34',
            expectedDeviceId: device, isCurrent: () => true),
        throwsA(isA<ApiFailure>()));
  });

  test('scope invalidation and disposal hide data and forbid later work',
      () async {
    final f = Fixture();
    await f.controller.initialize();
    await f.controller.create(subjectId: subject, platform: 'ANDROID');
    f.current = false;
    f.controller.invalidate();
    expect(f.controller.ticket, isNull);
    expect(f.controller.progress, isNull);
    await f.controller.check();
    await f.controller.retryCreation();
    expect(f.requests.length, 1);
    expect(f.journal.value?.requestId, request);
    f.controller.dispose();
    await f.controller.create(subjectId: subject, platform: 'ANDROID');
    expect(f.requests.length, 1);
  });

  test('conceal retains the current scope and resumes pending work with GET',
      () async {
    final f = Fixture();
    await f.controller.initialize();
    await f.controller.create(subjectId: subject, platform: 'ANDROID');
    f.controller.conceal();
    expect(f.controller.current, isTrue);
    expect(f.controller.hidden, isTrue);
    expect(f.controller.progress, isNull);
    expect(f.controller.hasSecret, isFalse);
    expect(f.controller.pending?.requestId, request);
    await f.controller.check();
    expect(f.controller.current, isTrue);
    expect(f.controller.hidden, isFalse);
    expect(f.controller.progress?.state, 'PENDING_CLAIM');
    expect(f.controller.hasSecret, isFalse);
    expect(f.requests.map((req) => req.method), ['POST', 'GET']);
  });

  test('an empty form resumes after conceal without any HTTP or new ID',
      () async {
    final f = Fixture();
    await f.controller.initialize();
    expect(f.controller.canCreate, isTrue);
    f.controller.conceal();
    expect(f.controller.current, isTrue);
    expect(f.controller.hidden, isTrue);
    expect(f.controller.canCreate, isFalse);
    await f.controller.check();
    expect(f.controller.hidden, isFalse);
    expect(f.controller.canCreate, isTrue);
    expect(f.requests, isEmpty);
    expect(f.ids, 0);
  });

  test('manual lookup binds the safe DTO using the normal enrollment GET',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((req) async {
      requests.add(req);
      return response(view(state: 'AWAITING_CONFIRMATION'));
    });
    final gateway = EnrollmentGateway.lookup(Api(() async => client));
    final found = await gateway.lookupIntent(scope, request,
        now: timestamp, isCurrent: () => true);
    expect(found.requestId, request);
    expect(found.subjectId, subject);
    expect(found.platform, 'ANDROID');
    expect(found.scope.actorId, actor);
    expect(found.createdAt, timestamp);
    expect(gateway.supportsCreation, isFalse);
    expect(requests.single.method, 'GET');
    expect(requests.single.url.path,
        '/api/v1/tenants/$tenant/enrollments/$request');
  });

  test('manual lookup rejects a response containing an unexpected secret',
      () async {
    final client =
        MockClient((_) async => response({...view(), 'token': 'a' * 43}));
    final gateway = EnrollmentGateway.lookup(Api(() async => client));
    await expectLater(
        gateway.lookupIntent(scope, request,
            now: timestamp, isCurrent: () => true),
        throwsA(isA<ApiFailure>()));
  });

  test('manual lookup gateway can never issue a ticket', () async {
    final requests = <http.Request>[];
    final client = MockClient((req) async {
      requests.add(req);
      return response(ticket(), 201);
    });
    final gateway = EnrollmentGateway.lookup(Api(() async => client));
    await expectLater(gateway.create(intent(), isCurrent: () => true),
        throwsA(isA<ApiFailure>()));
    expect(requests, isEmpty);
  });

  test('manual lookup journal only reads its original scope and cannot mutate',
      () async {
    final original = intent();
    final journal = EnrollmentLookupJournal(original);
    expect(await journal.read(scope), same(original));
    await expectLater(journal.write(original), throwsA(isA<ApiFailure>()));
    await expectLater(journal.remove(original), throwsA(isA<ApiFailure>()));
    await expectLater(
        journal.read(const EnrollmentScope(
            actorId: 'other-adult', tenantId: tenant, role: 'OWNER')),
        throwsA(isA<ApiFailure>()));
    expect(await journal.read(scope), same(original));
  });

  test('manual lookup can cancel the old ID but cannot reset or create',
      () async {
    final requests = <http.Request>[];
    var state = 'PENDING_CLAIM';
    final client = MockClient((req) async {
      requests.add(req);
      if (req.method == 'DELETE') {
        state = 'CANCELLED';
        return response(null, 204);
      }
      return response(view(state: state));
    });
    final journal = EnrollmentLookupJournal(intent());
    final controller = EnrollmentController(
        scope: scope,
        journal: journal,
        gateway: EnrollmentGateway.lookup(Api(() async => client)),
        isCurrent: () => true,
        newId: () => throw StateError('Manual lookup cannot allocate an ID'),
        now: () => timestamp);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.progress?.state, 'PENDING_CLAIM');
    expect(controller.canCreate, isFalse);
    expect(controller.canRetryCreation, isFalse);
    await controller.cancel();
    expect(controller.progress?.state, 'CANCELLED');
    expect(controller.canStartAgain, isFalse);
    await controller.startAgain();
    await controller.retryCreation();
    await controller.create(subjectId: subject, platform: 'ANDROID');
    expect(controller.pending?.requestId, request);
    expect(await journal.read(scope), isNotNull);
    expect(requests.map((req) => req.method), ['GET', 'DELETE', 'GET']);
    expect(
        requests.every((req) =>
            req.url.path == '/api/v1/tenants/$tenant/enrollments/$request'),
        isTrue);
  });

  test('manual lookup confirms once and reads the old registration fact',
      () async {
    var state = 'AWAITING_CONFIRMATION';
    final requests = <http.Request>[];
    final client = MockClient((req) async {
      requests.add(req);
      if (req.method == 'POST') {
        expect(req.url.path,
            '/api/v1/tenants/$tenant/enrollments/$request/confirm');
        state = 'CONFIRMED';
        return response(deviceView());
      }
      return response(view(state: state));
    });
    final controller = EnrollmentController(
        scope: scope,
        journal: EnrollmentLookupJournal(intent()),
        gateway: EnrollmentGateway.lookup(Api(() async => client)),
        isCurrent: () => true,
        newId: () => throw StateError('Manual lookup cannot allocate an ID'),
        now: () => timestamp);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.canConfirm, isTrue);
    await controller.confirm('AB12CD34');
    expect(controller.progress?.state, 'CONFIRMED');
    expect(controller.canStartAgain, isFalse);
    expect(controller.ticket, isNull);
    expect(requests.map((req) => req.method), ['GET', 'POST', 'GET']);
  });

  test('boundary lookup rejects a non-RFC UUID variant before HTTP', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return response(view());
    });
    final gateway = EnrollmentGateway.lookup(Api(() async => client));
    await expectLater(
        gateway.lookupIntent(scope, '33333333-3333-4333-3333-333333333333',
            now: timestamp, isCurrent: () => true),
        throwsA(isA<ApiFailure>()));
    expect(requests, 0);
  });

  for (final entry in {
    'blank actor': '   ',
    'oversized actor': 'a' * 201,
    'control actor': 'adult\nactor'
  }.entries) {
    test('boundary lookup rejects ${entry.key} before HTTP', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return response(view());
      });
      final gateway = EnrollmentGateway.lookup(Api(() async => client));
      final invalidScope = EnrollmentScope(
          actorId: entry.value, tenantId: tenant, role: 'OWNER');
      await expectLater(
          gateway.lookupIntent(invalidScope, request,
              now: timestamp, isCurrent: () => true),
          throwsA(isA<ApiFailure>()));
      expect(requests, 0);
    });
  }

  test('boundary creation timestamp accepts the journal safe integer limit',
      () async {
    final client = MockClient((_) async => response(view()));
    final gateway = EnrollmentGateway.lookup(Api(() async => client));
    final found = await gateway.lookupIntent(scope, request,
        now: 9007199254740991, isCurrent: () => true);
    expect(found.createdAt, 9007199254740991);
    expect(EnrollmentIntent.decode(found.encode(), scope: scope).createdAt,
        found.createdAt);
  });

  for (final hasPending in [false, true]) {
    test(
        'boundary pending initialization resumes after conceal: '
        'saved=$hasPending', () async {
      final waiting = Completer<void>();
      final journal = MemoryJournal()
        ..readWait = waiting
        ..value = hasPending ? intent() : null;
      final f = Fixture(journal: journal);
      final initializing = f.controller.initialize();
      await Future<void>.delayed(Duration.zero);
      f.controller.conceal();
      final resuming = f.controller.check();
      await Future<void>.delayed(Duration.zero);
      waiting.complete();
      await initializing;
      await resuming;
      expect(f.controller.initialized, isTrue);
      expect(f.controller.hidden, isFalse);
      expect(f.controller.canCreate, !hasPending);
      expect(f.controller.progress?.state, hasPending ? 'PENDING_CLAIM' : null);
      expect(f.requests.map((req) => req.method), hasPending ? ['GET'] : []);
      expect(journal.writes, 0);
      expect(f.ids, 0);
      expect(f.controller.ticket, isNull);
    });
  }

  for (final disposing in [false, true]) {
    test(
        'boundary resumed initialization cannot resurrect after '
        '${disposing ? 'dispose' : 'scope invalidation'}', () async {
      final waiting = Completer<void>();
      final journal = MemoryJournal()
        ..readWait = waiting
        ..value = intent();
      final f = Fixture(journal: journal);
      final initializing = f.controller.initialize();
      await Future<void>.delayed(Duration.zero);
      f.controller.conceal();
      final resuming = f.controller.check();
      await Future<void>.delayed(Duration.zero);
      if (disposing) {
        f.controller.dispose();
      } else {
        f.current = false;
        f.controller.invalidate();
      }
      waiting.complete();
      await initializing;
      await resuming;
      expect(f.controller.current, isFalse);
      expect(f.controller.hasSecret, isFalse);
      expect(f.controller.progress, isNull);
      expect(f.controller.canCreate, isFalse);
      expect(f.requests, isEmpty);
      expect(journal.writes, 0);
      expect(f.ids, 0);
    });
  }
}
