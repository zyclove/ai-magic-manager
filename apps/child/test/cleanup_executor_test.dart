import 'dart:io';
import 'package:child/platform/cleanup_executor_io.dart';
import 'package:child/platform/secret_store.dart';
import 'package:device_cleanup/device_cleanup.dart';
import 'package:device_identity/device_identity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import '../../../packages/device_cleanup/test/fixtures.dart' as signatures;
import 'support/identity_fixture.dart';

/// Real SDK identity, signed command and host filesystem. Plugin encryption,
/// native commit/fsync and cloud enrollment are explicit boundary substitutes.
class _Host {
  static const plugin =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  static const runtime = MethodChannel('com.aimanager.child/runtime');
  final records = <String, String>{};
  final calls = <String>[];
  final store = AndroidIdentityStore(
      storage:
          const FlutterSecureStorage(aOptions: AndroidIdentityStore.options),
      available: () => true);
  late final identity = IdentityFixture(nativeSecrets: store);
  late final Directory directory;
  late final VerifiedCleanupCommand command;
  late final AndroidAgentCleanupExecutor executor;
  bool closed = true,
      fileFlush = true,
      secretFlush = true,
      assistanceClear = true;
  String? keepOnDelete, failOnDelete;

  Future<void> initialize() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      final key = (call.arguments as Map)['key'] as String?;
      calls.add('${call.method}:${key ?? "all"}');
      switch (call.method) {
        case 'read':
          return records[key];
        case 'write':
          records[key!] = (call.arguments as Map)['value'] as String;
          return null;
        case 'delete':
          if (key == failOnDelete) throw StateError('private native failure');
          if (key != keepOnDelete) records.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.of(records);
        default:
          throw StateError('Unexpected storage operation');
      }
    });
    messenger.setMockMethodCallHandler(runtime, (call) async {
      calls.add(call.method);
      if (call.method == 'flushAgentFiles') {
        expect((call.arguments as Map)['directory'], directory.path);
        return fileFlush;
      }
      if (call.method == 'clearAssistance') return assistanceClear;
      expect(call.method, 'flushIdentity');
      return secretFlush;
    });
    directory = await Directory.systemTemp.createTemp('child-cleanup-test-');
    await identity.activate();
    final proof = await identity.identity.cleanupProof(action: 'READ');
    final scope = CleanupScope(IdentityFixture.tenant, IdentityFixture.device,
        IdentityFixture.registration, proof.keyThumbprint);
    command = await signatures.Fixture(scope).verified();
    records[AndroidCleanupRecordStore.keyForScope(scope)] = 'test-journal';
    executor = AndroidAgentCleanupExecutor(
        identity: identity.identity,
        secureStore: store,
        ownersClosed: () => closed,
        supportDirectory: () async => directory);
    calls.clear();
  }

  Future<File> database(String name) async {
    final file = File('${directory.path}/$name');
    final db = await databaseFactoryIo.openDatabase(file.path);
    await stringMapStoreFactory.store('private').record('item').put(db, {
      'name': 'synthetic-private-policy',
      'version': 1,
    });
    await db.close();
    return file;
  }

  Future<void> close() async {
    identity.close();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(plugin, null);
    messenger.setMockMethodCallHandler(runtime, null);
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Host host;
  setUp(() async {
    host = _Host();
    await host.initialize();
  });
  tearDown(() => host.close());

  final unsupported = throwsA(isA<AgentCleanupFailure>()
      .having((failure) => failure.reasonCode, 'reason', 'UNSUPPORTED_AGENT'));
  final storageFailure = throwsA(isA<AgentCleanupFailure>()
      .having((failure) => failure.reasonCode, 'reason', 'STORAGE_FAILURE'));

  test('cleanup must stop native assistance before deleting signed caches',
      () async {
    final file = await host.database('configuration-v1.db');
    host.assistanceClear = false;
    await expectLater(host.executor.clearOwnData(host.command), storageFailure);
    expect(host.calls, contains('clearAssistance'));
    expect(await file.exists(), isTrue);
  });

  test('cleanup removes Sembast recovery copy that can resurrect deleted data',
      () async {
    final original = await host.database('configuration-v1.db');
    final recovery =
        await original.copy('${host.directory.path}/~configuration-v1.db');
    // Simulate interruption after compaction output exists. Prove the file is
    // recoverable by the installed database implementation, not just a label.
    final bytes = await recovery.readAsBytes();
    await original.delete();
    final restored = await databaseFactoryIo.openDatabase(original.path);
    expect(
        await stringMapStoreFactory
            .store('private')
            .record('item')
            .get(restored),
        {'name': 'synthetic-private-policy', 'version': 1});
    await restored.close();
    await recovery.writeAsBytes(bytes, flush: true);

    await host.executor.clearOwnData(host.command);

    expect(await original.exists(), isFalse);
    expect(await recovery.exists(), isFalse,
        reason: 'A successful cleanup must not retain recoverable policy data');
    expect(await host.identity.identity.activeCredential(), isNull);
    expect((await host.identity.identity.view()).phase,
        IdentityPhase.cleanupPending);
    expect(host.records.containsKey('identity_record'), isTrue);
  });

  for (final name in ['configuration-v1.db', 'access-v1-${'a' * 64}.db']) {
    test('orphan recovery file is removed without opening $name', () async {
      final file = await host.database(name);
      final recovery = await file.rename('${host.directory.path}/~$name');
      await host.executor.clearOwnData(host.command);
      expect(await recovery.exists(), isFalse);
      expect(await File('${host.directory.path}/$name').exists(), isFalse);
    });
  }

  test('all known caches clear durably while identity and journals remain',
      () async {
    final files = <File>[];
    for (final name in [
      'configuration-v1.db',
      '~configuration-v1.db',
      'access-v1-${'a' * 64}.db',
      '~access-v1-${'b' * 64}.db',
    ]) {
      files.add(
          await File('${host.directory.path}/$name').writeAsString('cache'));
    }
    final unrelated = await File('${host.directory.path}/other.txt')
        .writeAsString('keep-other-data');
    for (final key in [
      'observation_record',
      'access_key_v1_${'a' * 64}',
      'access_context_v1_${'b' * 64}',
      'help_request_v1_${'c' * 64}',
    ]) {
      host.records[key] = 'private-cache';
    }
    final originalJournal =
        AndroidCleanupRecordStore.keyForScope(host.command.scope);
    final otherJournal = 'cleanup_journal_v1_${'d' * 64}';
    host.records[otherJournal] = 'keep-unresolved-journal';
    await host.executor.clearOwnData(host.command);
    expect(await Future.wait(files.map((file) => file.exists())),
        everyElement(isFalse));
    expect(await unrelated.readAsString(), 'keep-other-data');
    expect(host.records.keys.toSet(),
        {'identity_record', originalJournal, otherJournal});
    expect(host.calls.indexOf('write:identity_record'),
        lessThan(host.calls.indexOf('readAll:all')));
    expect(host.calls.indexOf('flushAgentFiles'),
        lessThan(host.calls.indexOf('delete:observation_record')));
    expect(host.calls.last, 'flushIdentity');
    await host.executor.clearOwnData(host.command);
    expect(await host.identity.identity.activeCredential(), isNull);
    expect(
        (await host.identity.identity.cleanupProof(action: 'READ'))
            .keyThumbprint,
        host.command.scope.keyThumbprint);
  });

  for (final name in [
    '~configuration-v1.db.backup',
    '~~configuration-v1.db',
    '~access-v1-invalid.db',
    'access-v1-${'a' * 64}.db.extra',
  ]) {
    test('unknown related file $name fails without deleting caches', () async {
      final main = await host.database('configuration-v1.db');
      final unknown =
          await File('${host.directory.path}/$name').writeAsString('unknown');
      await expectLater(host.executor.clearOwnData(host.command), unsupported);
      expect(await main.exists(), isTrue);
      expect(await unknown.exists(), isTrue);
      expect(host.calls, isNot(contains('flushAgentFiles')));
    });
  }

  test('database-named directory is refused, including recovery names',
      () async {
    final directory =
        await Directory('${host.directory.path}/~configuration-v1.db').create();
    final marker =
        await File('${directory.path}/private').writeAsString('preserve');
    await expectLater(host.executor.clearOwnData(host.command), unsupported);
    expect(await marker.exists(), isTrue);
  });

  test('database-named symbolic link is refused without touching its target',
      () async {
    final target = await File('${host.directory.path}/other-private-data')
        .writeAsString('must-stay');
    final link = await Link('${host.directory.path}/~configuration-v1.db')
        .create(target.path);
    await expectLater(host.executor.clearOwnData(host.command), unsupported);
    expect(await link.exists(), isTrue);
    expect(await target.readAsString(), 'must-stay');
  });

  test('open cache owners block cleanup before identity or filesystem access',
      () async {
    host.closed = false;
    final before = host.records['identity_record'];
    await expectLater(
        host.executor.clearOwnData(host.command),
        throwsA(isA<AgentCleanupFailure>().having(
            (failure) => failure.reasonCode,
            'reason',
            'USER_ACTION_REQUIRED')));
    expect(host.calls, isEmpty);
    expect(host.records['identity_record'], before);
  });

  test('unknown encrypted key prevents any file/cache deletion', () async {
    final file = await host.database('configuration-v1.db');
    host.records['new-private-cache'] = 'unrecognized';
    await expectLater(host.executor.clearOwnData(host.command), unsupported);
    expect(await file.exists(), isTrue);
    expect(host.records['new-private-cache'], 'unrecognized');
    expect(host.records.containsKey('identity_record'), isTrue);
  });

  test('missing current journal refuses local file deletion', () async {
    final file = await host.database('configuration-v1.db');
    host.records
        .remove(AndroidCleanupRecordStore.keyForScope(host.command.scope));
    await expectLater(host.executor.clearOwnData(host.command), storageFailure);
    expect(await file.exists(), isTrue);
    expect(host.records.containsKey('identity_record'), isTrue);
  });

  test('failed file persistence barrier preserves key and cache secrets',
      () async {
    await host.database('configuration-v1.db');
    host.records['observation_record'] = 'cache';
    host.fileFlush = false;
    await expectLater(host.executor.clearOwnData(host.command), storageFailure);
    expect(host.records['observation_record'], 'cache');
    expect(host.records.containsKey('identity_record'), isTrue);
    expect(host.calls, isNot(contains('delete:identity_record')));
    host.fileFlush = true;
    await host.executor.clearOwnData(host.command);
    expect(host.records.containsKey('observation_record'), isFalse);
  });

  test('failed secure storage barrier prevents filesystem deletion', () async {
    final file = await host.database('configuration-v1.db');
    host.secretFlush = false;
    await expectLater(host.executor.clearOwnData(host.command), storageFailure);
    expect(await file.exists(), isTrue);
    expect(host.records.containsKey('identity_record'), isTrue);
  });

  for (final fail in [false, true]) {
    test(
        'secret deletion ${fail ? 'exception' : 'silent failure'} cannot report clear',
        () async {
      host.records['observation_record'] = 'cache';
      if (fail) {
        host.failOnDelete = 'observation_record';
      } else {
        host.keepOnDelete = 'observation_record';
      }
      await expectLater(
          host.executor.clearOwnData(host.command), storageFailure);
      expect(host.records['observation_record'], 'cache');
      expect(host.records.containsKey('identity_record'), isTrue);
    });
  }

  test('wrong verified registration cannot modify local identity or files',
      () async {
    final file = await host.database('configuration-v1.db');
    final command = await signatures.Fixture().verified();
    final before = host.records['identity_record'];
    await expectLater(host.executor.clearOwnData(command), storageFailure);
    expect(host.records['identity_record'], before);
    expect(await file.exists(), isTrue);
  });
}
