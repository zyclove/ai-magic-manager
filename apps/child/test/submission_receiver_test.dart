import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:child/core/access.dart';
import 'package:child/core/environment.dart';
import 'package:child/core/submission_receiver.dart';
import 'package:child/platform/access_database_io.dart';
import 'package:device_access/device_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../../../packages/device_access/test/support/submission_fixture.dart'
    as sample;
import '../../../packages/device_access/test/fixtures.dart' as f;
import 'support/identity_fixture.dart';

class RequestBindings implements ChildAccessBindingStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  late IdentityFixture identity;
  late Directory directory;
  late RequestBindings bindings;
  late http.Client client;
  late ChildSubmissionReceiver receiver;
  final posted = <http.Request>[];
  bool offline = false, loseCreate = false;
  String subject = f.subject;
  int contextStatus = 200;
  int postStatus = 201;
  String? postCode;
  Completer<void>? responseGate, postedSignal;
  Map<String, dynamic> value() => sample.submission({
        'subjectId': f.subject,
        'deviceId': IdentityFixture.device,
        'registrationId': IdentityFixture.registration
      });
  Future<ChildSubmissionReceiver> open() async => ChildSubmissionReceiver(
      environment: ChildEnvironment(
          apiRoot: Uri.parse('https://service.example/api/v1')),
      identity: await identity.identity.view(),
      credential: identity.identity.activeCredential,
      bindingStore: bindings,
      nowMillis: () => identity.clock,
      databaseOpener: (key, {required existingDatabase}) => openAccessDatabase(
          key,
          requireExisting: existingDatabase,
          directoryPath: directory.path,
          keyProvider: (_, {required existingDatabase}) async =>
              Uint8List.fromList(List.filled(32, 7))),
      transportFactory: () => DeviceAccessTransport(
          apiRoot: Uri.parse('https://service.example/api/v1'),
          credential: identity.identity.activeCredential,
          client: client));
  setUp(() async {
    identity = IdentityFixture();
    await identity.activate();
    directory = await Directory.systemTemp.createTemp('child-request-');
    bindings = RequestBindings();
    posted.clear();
    offline = false;
    loseCreate = false;
    subject = f.subject;
    contextStatus = 200;
    postStatus = 201;
    postCode = null;
    responseGate = null;
    postedSignal = null;
    client = MockClient((request) async {
      if (offline) throw const SocketException('fixture offline');
      Object body;
      int status = 200;
      if (request.url.path.endsWith('/access-context')) {
        body = {
          'tenantId': IdentityFixture.tenant,
          'subjectId': subject,
          'deviceId': IdentityFixture.device,
          'registrationId': IdentityFixture.registration
        };
        status = contextStatus;
      } else if (request.url.path.endsWith('/options')) {
        body = {'items': [], 'nextCursor': null};
      } else if (request.method == 'POST') {
        posted.add(request);
        postedSignal?.complete();
        if (responseGate != null) await responseGate!.future;
        if (loseCreate) throw const SocketException('fixture response loss');
        body = request.url.path.endsWith('/cancel')
            ? {...value(), 'state': 'CANCELLED', 'version': 1}
            : value();
        status = request.url.path.endsWith('/cancel') ? 200 : 201;
        if (postCode != null) {
          status = postStatus;
          body = {'errorCode': postCode};
        }
      } else {
        body = {'items': [], 'nextCursor': null};
      }
      return http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'});
    });
    receiver = await open();
  });
  tearDown(() async {
    await receiver.close();
    client.close();
    identity.close();
    await directory.delete(recursive: true);
  });
  test('encrypted original operation survives response loss and close reopen',
      () async {
    await receiver.refresh();
    loseCreate = true;
    await expectLater(
        receiver.create(sample.input(),
            applicationName: '阅读', key: 'original-key'),
        throwsA(isA<AccessTransportFailure>()));
    expect((await receiver.restore()).journal!.pending!.phase,
        SubmissionOperationPhase.unknown);
    await receiver.close();
    for (final file in directory.listSync().whereType<File>()) {
      final bytes = await file.readAsBytes();
      expect(utf8.decode(bytes, allowMalformed: true), isNot(contains('继续阅读')));
      expect(utf8.decode(bytes, allowMalformed: true),
          isNot(contains('original-key')));
    }
    receiver = await open();
    offline = true;
    expect((await receiver.restore()).journal!.pending!.key, 'original-key');
    expect(posted.length, 1);
    offline = false;
    loseCreate = false;
    final recovered = await receiver.retry();
    expect(recovered.journal!.pending, isNull);
    expect(posted.length, 2);
    expect(posted[0].body, posted[1].body);
    expect(posted[1].headers['Idempotency-Key'], 'original-key');
  });
  test('a changed subject permanently blocks old cached request scope',
      () async {
    await receiver.refresh();
    loseCreate = true;
    await expectLater(
        receiver.create(sample.input(), applicationName: '阅读', key: 'key'),
        throwsA(isA<AccessTransportFailure>()));
    subject = f.document;
    await expectLater(
        receiver.refresh(),
        throwsA(isA<AccessFailure>()
            .having((e) => e.code, 'code', 'ACCESS_TARGET_CHANGED')));
    await receiver.close();
    receiver = await open();
    expect((await receiver.restore()).contextReady, isFalse);
    expect(posted.length, 1);
  });
  test(
      'authentication rejection blocks cache while transient offline keeps labelled cache',
      () async {
    await receiver.refresh();
    offline = true;
    await expectLater(
        receiver.refresh(), throwsA(isA<AccessTransportFailure>()));
    expect((await receiver.restore()).contextReady, isTrue);
    offline = false;
    contextStatus = 401;
    await expectLater(
        receiver.refresh(), throwsA(isA<AccessTransportFailure>()));
    expect((await receiver.restore()).contextReady, isFalse);
  });
  test('pause refuses work and requires an explicit foreground resume',
      () async {
    await receiver.refresh();
    receiver.pause();
    await expectLater(
        receiver.create(sample.input(), applicationName: '阅读', key: 'key'),
        throwsA(isA<AccessFailure>()));
    expect(posted, isEmpty);
    receiver.resume();
    expect((await receiver.refresh()).contextReady, isTrue);
  });
  test('missing protected database must not silently recreate an empty outbox',
      () async {
    await receiver.refresh();
    loseCreate = true;
    await expectLater(
        receiver.create(sample.input(),
            applicationName: '阅读', key: 'persisted-key'),
        throwsA(isA<AccessTransportFailure>()));
    await receiver.close();
    for (final file in directory.listSync().whereType<File>()) {
      await file.delete();
    }
    receiver = await open();
    await expectLater(receiver.restore(), throwsA(isA<AccessFailure>()));
    expect(posted.length, 1);
  });
  test('proven cooldown can be explicitly cleared but 5xx remains unknown',
      () async {
    await receiver.refresh();
    postStatus = 429;
    postCode = 'ACCESS_REQUEST_COOLDOWN';
    await expectLater(
        receiver.create(sample.input(), applicationName: '阅读', key: 'cooldown'),
        throwsA(isA<AccessTransportFailure>()));
    expect((await receiver.restore()).journal!.pending!.phase,
        SubmissionOperationPhase.rejected);
    expect((await receiver.discard()).journal!.pending, isNull);
    postStatus = 503;
    postCode = 'INTERNAL_ERROR';
    await expectLater(
        receiver.create(sample.input(), applicationName: '阅读', key: 'unknown'),
        throwsA(isA<AccessTransportFailure>()));
    expect((await receiver.restore()).journal!.pending!.phase,
        SubmissionOperationPhase.unknown);
    await expectLater(receiver.discard(), throwsA(isA<AccessFailure>()));
  });
  test(
      'background abort retains unknown operation and does not publish the response',
      () async {
    await receiver.refresh();
    responseGate = Completer<void>();
    postedSignal = Completer<void>();
    final operation = receiver.create(sample.input(),
        applicationName: '阅读', key: 'background');
    final outcome =
        expectLater(operation, throwsA(isA<AccessTransportFailure>()));
    await postedSignal!.future;
    receiver.pause();
    responseGate!.complete();
    await outcome;
    receiver.resume();
    expect((await receiver.restore()).journal!.pending!.phase,
        SubmissionOperationPhase.unknown);
    expect(posted.length, 1);
  });
}
