import 'dart:async';
import 'package:device_operations/device_operations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'client_test.dart' show scope;
import 'fixtures.dart';

class TestJournal implements ExitJournal {
  PendingExit? value;
  bool failWrite = false;
  bool failClear = false;
  bool failRead = false;
  @override
  Future<PendingExit?> read(ExitScope scope) async {
    if (failRead) throw StateError('storage read failed');
    return value;
  }

  @override
  Future<void> write(ExitScope scope, PendingExit pending) async {
    if (failWrite) throw StateError('disk full');
    value = pending;
  }

  @override
  Future<void> clear(ExitScope scope) async {
    if (failClear) throw StateError('storage unavailable');
    value = null;
  }
}

class TestGateway implements ExitGateway {
  int confirms = 0, previews = 0, cancels = 0;
  final keys = <String>[];
  ExitFailure? confirmFailure;
  Completer<void>? hold;
  Map<String, dynamic> previewData = previewJson();
  Map<String, dynamic> operationData = operationJson();
  int? confirmedVersion;
  String? confirmedPreview;
  @override
  Future<DeviceSnapshot> device(ExitScope scope) async =>
      DeviceSnapshot.fromJson(deviceJson());
  @override
  Future<ExitPreview> preview(ExitScope scope, int deviceVersion) async {
    previews++;
    return ExitPreview.fromJson(previewData);
  }

  @override
  Future<ExitOperation> confirm(ExitScope scope,
      {required String previewId,
      required String previewHash,
      required int deviceVersion,
      required String key}) async {
    confirms++;
    keys.add(key);
    confirmedVersion = deviceVersion;
    confirmedPreview = previewId;
    if (hold != null) await hold!.future;
    if (confirmFailure != null) throw confirmFailure!;
    return ExitOperation.fromJson(operationData);
  }

  @override
  Future<ExitOperation> operation(ExitScope scope, String operationId) async =>
      ExitOperation.fromJson(operationData);
  @override
  Future<List<ExitOperation>> operations(ExitScope scope) async => [];
  @override
  Future<ExitOperation> cancel(ExitScope scope,
      {required String operationId,
      required int version,
      required String key}) async {
    cancels++;
    keys.add(key);
    if (confirmFailure != null) throw confirmFailure!;
    operationData =
        operationJson(state: 'CLEANUP_CANCELLED', version: version + 1);
    return ExitOperation.fromJson(operationData);
  }
}

ExitController makeController(TestGateway api, TestJournal journal,
        {String role = 'OWNER', DateTime Function()? clock}) =>
    ExitController(
        scope: scope(role: role),
        gateway: api,
        journal: journal,
        clock: clock ?? () => now,
        keyFactory: () => requestKey);
Future<void> ready(ExitController c) async {
  await c.initialize();
  await c.prepare();
  c.acknowledge(true);
}

void main() {
  test('invalid restored registration cannot enable replay', () async {
    final journal = TestJournal()
      ..value = PendingExit(
          kind: PendingKind.confirm,
          key: requestKey,
          registrationId: tenantId,
          version: 7,
          createdAt: now,
          previewId: previewId,
          previewHash: previewHash);
    final api = TestGateway();
    final c = makeController(api, journal);
    await c.initialize();
    expect(c.error?.code, 'JOURNAL_INVALID');
    expect(c.canRetry, false);
    await c.retryPending();
    expect(api.confirms, 0);
  });
  test('failed reinitialization cannot retain old confirmation authority',
      () async {
    final journal = TestJournal();
    final api = TestGateway();
    final c = makeController(api, journal);
    await ready(c);
    expect(c.canConfirm, true);
    journal.failRead = true;
    await c.initialize();
    expect(c.canConfirm, false);
    await c.confirm();
    expect(api.confirms, 0);
  });
  test('explicit acknowledgement is required', () async {
    final api = TestGateway();
    final c = makeController(api, TestJournal());
    await c.initialize();
    await c.prepare();
    await c.confirm();
    expect(api.confirms, 0);
    expect(c.canConfirm, false);
    c.acknowledge(true);
    expect(c.canConfirm, true);
  });
  test('unknown consequence or missing limitation blocks confirmation',
      () async {
    final api = TestGateway()
      ..previewData = {
        ...previewJson(),
        'limitations': ['NO_DEVICE_WIPE']
      };
    final c = makeController(api, TestJournal());
    await ready(c);
    expect(c.canConfirm, false);
    await c.confirm();
    expect(api.confirms, 0);
  });
  test('preview expires without extending approval', () async {
    var current = now;
    final api = TestGateway();
    final c = makeController(api, TestJournal(), clock: () => current);
    await ready(c);
    current = now.add(const Duration(minutes: 5));
    expect(c.canConfirm, false);
    await c.confirm();
    expect(api.confirms, 0);
  });
  test('journal failure prevents mutation', () async {
    final api = TestGateway();
    final journal = TestJournal()..failWrite = true;
    final c = makeController(api, journal);
    await ready(c);
    await c.confirm();
    expect(api.confirms, 0);
    expect(c.error?.code, 'JOURNAL_UNAVAILABLE');
  });
  test('unknown outcome preserves exact request and cannot create new preview',
      () async {
    final api = TestGateway()
      ..confirmFailure =
          const ExitFailure('NETWORK_TIMEOUT', 'timeout', outcomeUnknown: true);
    final journal = TestJournal();
    final c = makeController(api, journal);
    await ready(c);
    await c.confirm();
    expect(c.pending?.key, requestKey);
    expect(journal.value?.previewId, previewId);
    await c.prepare();
    expect(api.previews, 1);
    api.confirmFailure = null;
    await c.retryPending();
    expect(api.keys, [requestKey, requestKey]);
    expect(api.confirmedVersion, 7);
    expect(api.confirmedPreview, previewId);
    expect(c.operation?.remoteAccess, 'REVOKED');
    expect(c.pending, null);
    expect(journal.value, null);
  });
  test('reload restores pending metadata without posting automatically',
      () async {
    final api = TestGateway()
      ..confirmFailure =
          const ExitFailure('NETWORK_TIMEOUT', 'timeout', outcomeUnknown: true);
    final journal = TestJournal();
    final first = makeController(api, journal);
    await ready(first);
    await first.confirm();
    first.dispose();
    final second = makeController(api, journal);
    await second.initialize();
    expect(api.confirms, 1);
    expect(second.pending?.key, requestKey);
  });
  test('authenticated auditor and child cannot mutate', () async {
    for (final role in ['AUDITOR', 'CHILD', 'TEACHER']) {
      final api = TestGateway();
      final c = makeController(api, TestJournal(), role: role);
      await c.initialize();
      await c.prepare();
      c.acknowledge(true);
      await c.confirm();
      expect(api.confirms, 0);
      expect(api.previews, 0);
    }
  });
  test('version conflict clears preview and explicit acknowledgement',
      () async {
    final api = TestGateway()
      ..confirmFailure = const ExitFailure(
          'RESOURCE_VERSION_CONFLICT', 'changed',
          status: 412);
    final c = makeController(api, TestJournal());
    await ready(c);
    await c.confirm();
    expect(c.pending, null);
    expect(c.preview, null);
    expect(c.acknowledged, false);
    await c.prepare();
    expect(c.canConfirm, false);
  });
  test('reauthentication preserves original key and never resubmits by itself',
      () async {
    final api = TestGateway()
      ..confirmFailure =
          const ExitFailure('REAUTH_REQUIRED', 'reauth', status: 401);
    final c = makeController(api, TestJournal());
    await ready(c);
    await c.confirm();
    expect(c.pending?.key, requestKey);
    expect(api.confirms, 1);
    api.confirmFailure = null;
    await c.retryPending();
    expect(api.keys, [requestKey, requestKey]);
  });
  test('duplicate clicks while mutation is running issue one request',
      () async {
    final api = TestGateway()..hold = Completer<void>();
    final c = makeController(api, TestJournal());
    await ready(c);
    final first = c.confirm();
    await Future<void>.delayed(Duration.zero);
    await c.confirm();
    expect(api.confirms, 1);
    api.hold!.complete();
    await first;
  });
  test('cancel requires warning acceptance and retains key on timeout',
      () async {
    final api = TestGateway();
    final c = makeController(api, TestJournal());
    await ready(c);
    await c.confirm();
    await c.cancel(acceptedWarning: false);
    expect(api.cancels, 0);
    api.confirmFailure =
        const ExitFailure('NETWORK_TIMEOUT', 'timeout', outcomeUnknown: true);
    await c.cancel(acceptedWarning: true);
    expect(c.pending?.kind, PendingKind.cancel);
    api.confirmFailure = null;
    await c.retryPending();
    expect(c.operation?.state, 'CLEANUP_CANCELLED');
    expect(c.error, null);
    expect(api.keys, [requestKey, requestKey, requestKey]);
  });
  test('clear journal failure keeps recovery metadata after accepted response',
      () async {
    final api = TestGateway();
    final journal = TestJournal()..failClear = true;
    final c = makeController(api, journal);
    await ready(c);
    await c.confirm();
    expect(c.pending?.key, requestKey);
    expect(c.operation?.id, operationId);
    journal.failClear = false;
    await c.retryPending();
    expect(api.keys, [requestKey, requestKey]);
  });
  test('disposed controller does not send a new request', () async {
    final api = TestGateway();
    final c = makeController(api, TestJournal());
    await ready(c);
    c.dispose();
    await c.confirm();
    expect(api.confirms, 0);
  });
}
