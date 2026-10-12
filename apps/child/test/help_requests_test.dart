import 'dart:async';
import 'dart:convert';
import 'package:child/core/environment.dart';
import 'package:child/core/help_requests.dart';
import 'package:child/core/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'support/identity_fixture.dart';

class _Store implements ChildHelpStore {
  final values = <String, String>{};
  bool failRead = false, failWrite = false;
  Completer<void>? writeGate;
  Completer<void>? writeEntered;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('private storage unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('private storage unavailable');
    if (writeEntered != null && !writeEntered!.isCompleted) {
      writeEntered!.complete();
    }
    await writeGate?.future;
    values[key] = value;
  }
}

void main() {
  const serverId = '99999999-9999-9999-9999-999999999999';
  late IdentityFixture identity;
  late ChildSession session;
  late _Store store;
  late ChildHelpCoordinator coordinator;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;
  Map<String, dynamic> response(http.Request request,
      [Map<String, dynamic> changes = const {}]) {
    final record = ChildHelpRecord.parse(store.values.values.single);
    return {
      'id': serverId,
      'deviceId': IdentityFixture.device,
      'clientRequestId': record.clientRequestId,
      'reasonCode': record.reasonCode,
      'state': 'OPEN',
      'createdAt': IdentityFixture.now,
      'acknowledgedAt': null,
      ...changes,
    };
  }

  ChildHelpCoordinator create() => ChildHelpCoordinator(
      session: session,
      environment: ChildEnvironment(
          apiRoot: Uri.parse('https://service.example/api/v1')),
      store: store,
      nowMillis: () => IdentityFixture.now,
      client: MockClient((request) async {
        requests.add(request);
        return handler(request);
      }));
  Matcher failure(String code) => throwsA(
      isA<ChildHelpFailure>().having((error) => error.code, 'code', code));

  setUp(() async {
    identity = IdentityFixture();
    await identity.activate();
    session = identity.session();
    await session.initialize();
    store = _Store();
    requests = [];
    handler =
        (request) async => http.Response(jsonEncode(response(request)), 200);
    coordinator = create();
  });
  tearDown(() {
    coordinator.close();
    session.dispose();
    identity.close();
  });

  test('durably prepares before HTTP and confirms the original request',
      () async {
    handler = (request) async {
      final local = ChildHelpRecord.parse(store.values.values.single);
      expect(local.phase, 'PREPARED');
      expect(
          jsonDecode(request.body)['clientRequestId'], local.clientRequestId);
      expect(request.headers['Authorization'], 'Bearer ${'b' * 43}');
      expect(request.url.path, '/api/v1/device-api/help-requests');
      expect(request.followRedirects, isFalse);
      return http.Response(jsonEncode(response(request)), 201);
    };
    final result = await coordinator.submit('NEED_HELP');
    expect(result.confirmed, isTrue);
    expect((await coordinator.restore())!.serverId, serverId);
    expect(requests, hasLength(1));
  });

  test('failed preparation never sends and exposes a recoverable storage error',
      () async {
    store.failWrite = true;
    await expectLater(
        coordinator.submit('NEED_HELP'), failure('HELP_STORAGE_UNAVAILABLE'));
    expect(requests, isEmpty);
  });

  test('failed read is a typed storage error', () async {
    store.failRead = true;
    await expectLater(
        coordinator.restore(), failure('HELP_STORAGE_UNAVAILABLE'));
    expect(requests, isEmpty);
  });

  test('corrupt local record blocks a new request without HTTP', () async {
    store.values[coordinator.scopeKey] = '{broken';
    await expectLater(
        coordinator.submit('NEED_HELP'), failure('HELP_LOCAL_RECORD_INVALID'));
    expect(requests, isEmpty);
  });

  test('lost response survives recreation without automatic retransmission',
      () async {
    handler = (_) async => throw http.ClientException('offline');
    await expectLater(
        coordinator.submit('DEVICE_PROBLEM'), failure('HELP_NETWORK_UNKNOWN'));
    final original = await coordinator.restore();
    coordinator.close();
    coordinator = create();
    expect((await coordinator.restore())!.clientRequestId,
        original!.clientRequestId);
    expect(requests, hasLength(1));
    await expectLater(
        coordinator.submit('NEED_HELP'), failure('HELP_REQUEST_PENDING'));
    expect(requests, hasLength(1));
  });

  Future<void> pending() async {
    handler = (_) async => http.Response('{}', 503);
    await expectLater(
        coordinator.submit('NEED_HELP'), failure('HELP_SERVER_UNAVAILABLE'));
    requests.clear();
  }

  test(
      'retry first queries and returns an already received request without POST',
      () async {
    await pending();
    handler = (r) async => http.Response(jsonEncode(response(r)), 200);
    expect((await coordinator.retry()).confirmed, isTrue);
    expect(requests.map((r) => r.method), ['GET']);
  });

  test('retry uses original UUID and reason only after server reports absent',
      () async {
    await pending();
    final original = await coordinator.restore();
    handler = (r) async => r.method == 'GET'
        ? http.Response('{}', 404)
        : http.Response(jsonEncode(response(r)), 201);
    final result = await coordinator.retry();
    expect(requests.map((r) => r.method), ['GET', 'POST']);
    expect(result.clientRequestId, original!.clientRequestId);
    expect(jsonDecode(requests.last.body)['reasonCode'], original.reasonCode);
  });

  test('failed retry lookup keeps the original pending request and never POSTs',
      () async {
    await pending();
    final original = store.values.values.single;
    handler = (_) async => http.Response('{}', 503);
    await expectLater(coordinator.retry(), failure('HELP_SERVER_UNAVAILABLE'));
    expect(requests.map((r) => r.method), ['GET']);
    expect(store.values.values.single, original);
  });

  for (final entry in {
    301: 'HELP_REDIRECT_REFUSED',
    401: 'DEVICE_CREDENTIAL_UNAVAILABLE',
    403: 'DEVICE_CREDENTIAL_UNAVAILABLE',
    429: 'HELP_REQUEST_RATE_LIMITED',
  }.entries) {
    test('HTTP ${entry.key} preserves prepared state', () async {
      handler = (_) async => http.Response('{}', entry.key);
      await expectLater(coordinator.submit('NEED_HELP'), failure(entry.value));
      expect((await coordinator.restore())!.phase, 'PREPARED');
    });
  }

  for (final changes in <Map<String, dynamic>>[
    {'deviceId': serverId},
    {'clientRequestId': serverId},
    {'reasonCode': 'DEVICE_PROBLEM'},
    {'id': 'invalid'},
    {'state': 'RESOLVED'},
    {'createdAt': -1},
    {'acknowledgedAt': IdentityFixture.now},
    {'state': 'ACKNOWLEDGED'},
  ]) {
    test('invalid response $changes does not confirm', () async {
      handler =
          (r) async => http.Response(jsonEncode(response(r, changes)), 200);
      await expectLater(
          coordinator.submit('NEED_HELP'), failure('HELP_RESPONSE_INVALID'));
      expect((await coordinator.restore())!.confirmed, isFalse);
    });
  }

  test('acknowledged status cannot regress on a later lookup', () async {
    handler = (r) async => http.Response(
        jsonEncode(response(r, {
          'state': 'ACKNOWLEDGED',
          'acknowledgedAt': IdentityFixture.now + 1
        })),
        200);
    await coordinator.submit('NEED_HELP');
    final prior = store.values.values.single;
    handler = (r) async => http.Response(jsonEncode(response(r)), 200);
    await expectLater(coordinator.refresh(), failure('HELP_RESPONSE_INVALID'));
    expect(store.values.values.single, prior);
  });

  test('overlapping submit during preparation cannot replace the original UUID',
      () async {
    store.writeEntered = Completer<void>();
    store.writeGate = Completer<void>();
    final first = coordinator.submit('NEED_HELP');
    await store.writeEntered!.future;
    final second = coordinator.submit('DEVICE_PROBLEM');
    try {
      await expectLater(second.timeout(const Duration(milliseconds: 200)),
          failure('HELP_REQUEST_BUSY'));
    } finally {
      store.writeGate!.complete();
      await Future.wait([
        first.catchError(
            (_) => const ChildHelpRecord('', '', '', 0, null, null, null)),
        second.catchError(
            (_) => const ChildHelpRecord('', '', '', 0, null, null, null))
      ]);
    }
    expect(requests, hasLength(1));
    expect((await coordinator.restore())!.reasonCode, 'NEED_HELP');
  });

  test('overlapping refresh and retry cannot race durable confirmation',
      () async {
    await pending();
    final entered = Completer<void>(), release = Completer<void>();
    handler = (r) async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      return http.Response(jsonEncode(response(r)), 200);
    };
    final first = coordinator.refresh();
    await entered.future;
    final second = coordinator.retry();
    try {
      await expectLater(second.timeout(const Duration(milliseconds: 200)),
          failure('HELP_REQUEST_BUSY'));
    } finally {
      release.complete();
      await first;
      await second.catchError(
          (_) => const ChildHelpRecord('', '', '', 0, null, null, null));
    }
    expect(requests, hasLength(1));
  });

  test('resume can read the durable pending snapshot while HTTP is in flight',
      () async {
    final entered = Completer<void>(), release = Completer<void>();
    handler = (r) async {
      entered.complete();
      await release.future;
      return http.Response(jsonEncode(response(r)), 201);
    };
    final sending = coordinator.submit('NEED_HELP');
    await entered.future;
    try {
      final snapshot = await coordinator.restore();
      expect(snapshot!.phase, 'PREPARED');
      expect(requests, hasLength(1));
    } finally {
      release.complete();
      await sending;
    }
  });

  test(
      'recreated coordinator cannot overwrite an earlier pending storage write',
      () async {
    store.writeEntered = Completer<void>();
    store.writeGate = Completer<void>();
    final sending = coordinator.submit('NEED_HELP');
    final sendingResult = expectLater(sending, failure('HELP_CONTEXT_CHANGED'));
    await store.writeEntered!.future;
    coordinator.close();
    coordinator = create();
    final second = coordinator.submit('DEVICE_PROBLEM');
    try {
      await expectLater(second.timeout(const Duration(milliseconds: 200)),
          failure('HELP_REQUEST_BUSY'));
    } finally {
      store.writeGate!.complete();
      await sendingResult;
      await second.catchError(
          (_) => const ChildHelpRecord('', '', '', 0, null, null, null));
    }
    expect(requests, isEmpty);
    expect((await coordinator.restore())!.reasonCode, 'NEED_HELP');
  });

  test('readiness lost during HTTP cannot persist confirmation', () async {
    handler = (r) async {
      session.credentialReady = false;
      return http.Response(jsonEncode(response(r)), 200);
    };
    await expectLater(
        coordinator.submit('NEED_HELP'), failure('HELP_CONTEXT_CHANGED'));
    expect(
        ChildHelpRecord.parse(store.values.values.single).confirmed, isFalse);
  });

  test('closing during HTTP cannot persist confirmation', () async {
    handler = (r) async {
      coordinator.close();
      return http.Response(jsonEncode(response(r)), 200);
    };
    await expectLater(
        coordinator.submit('NEED_HELP'), failure('HELP_CONTEXT_CHANGED'));
    expect(
        ChildHelpRecord.parse(store.values.values.single).confirmed, isFalse);
  });

  test('storage failure after HTTP retains the durable prepared record',
      () async {
    handler = (r) async {
      store.failWrite = true;
      return http.Response(jsonEncode(response(r)), 201);
    };
    await expectLater(
        coordinator.submit('NEED_HELP'), failure('HELP_STORAGE_UNAVAILABLE'));
    expect(
        ChildHelpRecord.parse(store.values.values.single).confirmed, isFalse);
  });
}
