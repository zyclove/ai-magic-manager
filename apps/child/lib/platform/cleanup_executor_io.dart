import 'dart:io';
import 'package:device_cleanup/device_cleanup.dart';
import 'package:device_identity/device_identity.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'secret_store.dart';

/// Android-only implementation of the three fixed AGENT_CLEANUP actions.
/// Construct it only after all configuration/access/observation database
/// owners have been closed. It never touches other apps, system accounts,
/// third-party storage or device management state.
class AndroidAgentCleanupExecutor implements AgentCleanupExecutor {
  static final _accessFile = RegExp(r'^access-v1-[0-9a-f]{64}\.db$');
  static final _journalKey = RegExp(r'^cleanup_journal_v1_[0-9a-f]{64}$');
  static final _accessSecret =
      RegExp(r'^(access_key_v1_|access_context_v1_)[0-9a-f]{64}$');

  final DeviceIdentityManager identity;
  final AndroidIdentityStore secureStore;
  final Future<Directory> Function() supportDirectory;
  final bool Function() ownersClosed;

  AndroidAgentCleanupExecutor(
      {required this.identity,
      required this.secureStore,
      required this.ownersClosed,
      Future<Directory> Function()? supportDirectory})
      : supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  void _requireQuiescent() {
    if (!secureStore.available() || !ownersClosed()) {
      throw AgentCleanupFailure('USER_ACTION_REQUIRED');
    }
  }

  @override
  Future<void> clearOwnData(VerifiedCleanupCommand command) async {
    _requireQuiescent();
    final scope = command.scope;
    try {
      // Make ordinary API use impossible before touching local caches. The
      // original key and journal remain available for failure/clear receipts.
      await identity.beginAgentCleanup(
          tenantId: scope.tenantId,
          deviceId: scope.deviceId,
          registrationId: scope.registrationId,
          keyThumbprint: scope.keyThumbprint,
          commandHash: command.commandHash);
    } on DeviceIdentityFailure catch (failure) {
      throw AgentCleanupFailure(failure.code == 'DEVICE_KEY_UNAVAILABLE'
          ? 'KEY_UNAVAILABLE'
          : 'STORAGE_FAILURE');
    }

    try {
      final directory = await supportDirectory();
      if (!await directory.exists()) throw const FileSystemException();
      final files = <File>[];
      await for (final entity in directory.list(followLinks: false)) {
        final name = path.basename(entity.path);
        if (name.startsWith('configuration-v1.db') ||
            name.startsWith('access-v1-')) {
          if (entity is! File ||
              name != 'configuration-v1.db' && !_accessFile.hasMatch(name)) {
            throw AgentCleanupFailure('UNSUPPORTED_AGENT');
          }
          files.add(entity);
        }
      }

      // The plugin returns a logical-key map. Never log or persist its values.
      // Unknown entries may contain data a newer module introduced; refuse to
      // claim the fixed cleanup scope while they remain unaccounted for.
      final records = await secureStore.storage.readAll();
      await secureStore.flushForCleanup();
      final keys = records.keys.toList(growable: false);
      if (!keys.contains('identity_record') ||
          !keys.contains(AndroidCleanupRecordStore.keyForScope(scope))) {
        throw AgentCleanupFailure('STORAGE_FAILURE');
      }
      if (keys.any((key) =>
          key != 'identity_record' &&
          key != 'observation_record' &&
          !_journalKey.hasMatch(key) &&
          !_accessSecret.hasMatch(key))) {
        throw AgentCleanupFailure('UNSUPPORTED_AGENT');
      }

      for (final file in files) {
        if (await file.exists()) await file.delete();
      }
      await secureStore.flushAgentFiles(directory.path);
      for (final key in keys) {
        if (key == 'observation_record' || _accessSecret.hasMatch(key)) {
          await secureStore.storage.delete(key: key);
        }
      }
      await secureStore.flushForCleanup();
      for (final file in files) {
        if (await file.exists()) throw const FileSystemException();
      }
      for (final key in keys) {
        if ((key == 'observation_record' || _accessSecret.hasMatch(key)) &&
            await secureStore.storage.read(key: key) != null) {
          throw const FileSystemException();
        }
      }
      await secureStore.flushForCleanup();
    } on AgentCleanupFailure {
      rethrow;
    } catch (_) {
      throw AgentCleanupFailure('STORAGE_FAILURE');
    }
  }

  @override
  Future<void> removeOriginalKey(VerifiedCleanupCommand command) async {
    _requireQuiescent();
    final scope = command.scope;
    try {
      await identity.finishAgentCleanup(
          tenantId: scope.tenantId,
          deviceId: scope.deviceId,
          registrationId: scope.registrationId,
          keyThumbprint: scope.keyThumbprint,
          commandHash: command.commandHash);
    } on DeviceIdentityFailure catch (failure) {
      throw AgentCleanupFailure(failure.code == 'DEVICE_KEY_UNAVAILABLE'
          ? 'KEY_UNAVAILABLE'
          : 'STORAGE_FAILURE');
    }
  }
}
