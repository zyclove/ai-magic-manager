import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:device_access/device_access.dart';
import 'package:device_cleanup/device_cleanup.dart';
import 'package:device_identity/device_identity.dart';
import 'package:device_observation/device_observation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/access.dart' show ChildAccessBindingStore;
import '../core/help_requests.dart' show ChildHelpStore, ChildHelpFailure;

/// One encrypted record, no readAll/reset surface. Explicit deletion is used
/// only after an acknowledged agent cleanup. Android only until each additional
/// native storage implementation is separately certified.
class AndroidIdentityStore
    implements
        DeviceSecretStore,
        DeviceSecretDeletion,
        DeviceSecretCompareAndSet {
  static const options = AndroidOptions(
      resetOnError: false,
      // v10 treats missing algorithm markers as legacy storage, including on
      // a fresh install. Use its data-preserving migration, never reset data.
      migrateOnAlgorithmChange: true,
      sharedPreferencesName: 'aimanager_identity_v1',
      preferencesKeyPrefix: 'aimanager');
  final FlutterSecureStorage storage;
  final MethodChannel channel;
  final bool Function() available;
  final bool _injectedStorage;
  static Future<void> _injectedTail = Future.value();
  AndroidIdentityStore(
      {FlutterSecureStorage? storage,
      this.channel = const MethodChannel('com.aimanager.child/runtime'),
      bool Function()? available})
      : _injectedStorage = storage != null,
        storage = storage ?? const FlutterSecureStorage(aOptions: options),
        available = available ??
            (() => !kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  void _requireAvailable() {
    if (!available()) {
      throw const DeviceIdentityFailure('SECURE_STORAGE_UNAVAILABLE');
    }
  }

  @override
  Future<String?> read() async {
    _requireAvailable();
    try {
      if (!_injectedStorage) {
        return await channel.invokeMethod<String>('identityRead');
      }
      final record = await storage.read(key: 'identity_record');
      // SDK initialization/migration can itself write wrapping keys/config.
      // A restored credential must not be used before that work is durable.
      await _flush();
      return record;
    } catch (_) {
      throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
    }
  }

  @override
  Future<void> write(String record) async {
    _requireAvailable();
    if (record.length > 65536) {
      throw const DeviceIdentityFailure('IDENTITY_STATE_INVALID');
    }
    if (!_injectedStorage) {
      final expected = await read();
      if (!await compareAndSet(expected: expected, value: record)) {
        throw const DeviceIdentityFailure('IDENTITY_STATE_CONFLICT');
      }
      return;
    }
    try {
      await storage.write(key: 'identity_record', value: record);
      // Plugin v10 uses SharedPreferences.apply(). Wait for native commit of
      // wrapping key/config/data before identity intent is allowed onto HTTP.
      await _flush();
    } catch (_) {
      throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
    }
  }

  @override
  Future<void> deleteIdentity() async {
    _requireAvailable();
    if (!_injectedStorage) {
      final expected = await read();
      if (!await compareAndSet(expected: expected, value: null)) {
        throw const DeviceIdentityFailure('IDENTITY_STATE_CONFLICT');
      }
      return;
    }
    try {
      await storage.delete(key: 'identity_record');
      await _flush();
      if (await storage.read(key: 'identity_record') != null) {
        throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
      }
      await _flush();
    } catch (_) {
      throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
    }
  }

  @override
  Future<bool> compareAndSet(
      {required String? expected, required String? value}) async {
    _requireAvailable();
    if ((expected?.length ?? 0) > 65536 || (value?.length ?? 0) > 65536) {
      throw const DeviceIdentityFailure('IDENTITY_STATE_INVALID');
    }
    if (!_injectedStorage) {
      try {
        final applied = await channel.invokeMethod<bool>(
            value == null ? 'identityDelete' : 'identityCompareAndSet',
            {'expected': expected, if (value != null) 'value': value});
        if (applied == null) {
          throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
        }
        return applied;
      } catch (_) {
        throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
      }
    }
    // Explicit SDK injection retains the host-test adapter and every flush.
    // Production identity owners use the native lock above, across engines.
    final previous = _injectedTail;
    final done = Completer<void>();
    _injectedTail = done.future;
    await previous;
    try {
      if (await read() != expected) return false;
      if (value == null) {
        await deleteIdentity();
      } else {
        await write(value);
      }
      return true;
    } finally {
      done.complete();
    }
  }

  Future<void> _flush() async {
    if (await channel.invokeMethod<bool>('flushIdentity') != true) {
      throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
    }
  }

  /// The cleanup executor uses the same native commit barrier after deleting
  /// known app-private cache keys. It cannot bypass identity storage checks.
  Future<void> flushForCleanup() async {
    _requireAvailable();
    await _flush();
  }

  /// Native fsync of this app's private support directory after cache unlink.
  /// The native side validates the canonical path under Android filesDir.
  Future<void> flushAgentFiles(String directory) async {
    _requireAvailable();
    try {
      if (await channel.invokeMethod<bool>(
              'flushAgentFiles', {'directory': directory}) !=
          true) {
        throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
      }
    } catch (_) {
      throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
    }
  }
}

/// 复用已配置的成熟加密 SDK 与持久屏障，单独固定键，不改动设备身份记录。
class AndroidObservationStore
    implements ObservationStore, ObservationCompareAndSet {
  final AndroidIdentityStore backend;
  static Future<void> _injectedTail = Future.value();
  AndroidObservationStore.fromIdentityStore(this.backend);
  AndroidObservationStore(
      {FlutterSecureStorage? storage,
      MethodChannel channel =
          const MethodChannel('com.aimanager.child/runtime'),
      bool Function()? available})
      : backend = AndroidIdentityStore(
            storage: storage, channel: channel, available: available);
  void _available() {
    if (!backend.available()) {
      throw const ObservationFailure('OBSERVATION_STORAGE_UNAVAILABLE');
    }
  }

  @override
  Future<String?> read() async {
    _available();
    try {
      final String? record;
      if (backend._injectedStorage) {
        record = await backend.storage.read(key: 'observation_record');
        await backend._flush();
      } else {
        record = await backend.channel.invokeMethod<String>('observationRead');
      }
      if (record != null && utf8.encode(record).length > 1048576) {
        throw const FormatException();
      }
      return record;
    } catch (_) {
      throw const ObservationFailure('OBSERVATION_STORAGE_FAILED');
    }
  }

  @override
  Future<void> write(String value) async {
    _available();
    if (utf8.encode(value).length > 1048576) {
      throw const ObservationFailure('OBSERVATION_STORAGE_FAILED');
    }
    final expected = await read();
    if (!await compareAndSet(expected: expected, replacement: value)) {
      throw const ObservationFailure('OBSERVATION_STATE_CONFLICT');
    }
  }

  @override
  Future<bool> compareAndSet(
      {required String? expected, required String? replacement}) async {
    _available();
    if (utf8.encode(expected ?? '').length > 1048576 ||
        utf8.encode(replacement ?? '').length > 1048576) {
      throw const ObservationFailure('OBSERVATION_STORAGE_FAILED');
    }
    if (!backend._injectedStorage) {
      try {
        final applied = await backend.channel.invokeMethod<bool>(
            'observationCompareAndSet',
            {'expected': expected, 'replacement': replacement});
        if (applied == null) throw const FormatException();
        return applied;
      } catch (_) {
        throw const ObservationFailure('OBSERVATION_STORAGE_FAILED');
      }
    }
    final previous = _injectedTail, done = Completer<void>();
    _injectedTail = done.future;
    await previous;
    try {
      if (await read() != expected) return false;
      if (replacement == null) {
        await backend.storage.delete(key: 'observation_record');
      } else {
        await backend.storage
            .write(key: 'observation_record', value: replacement);
      }
      await backend._flush();
      if (await read() != replacement) throw const FormatException();
      return true;
    } catch (_) {
      throw const ObservationFailure('OBSERVATION_STORAGE_FAILED');
    } finally {
      done.complete();
    }
  }
}

/// Stores one cleanup journal for one original registration. A distinct key
/// prevents old or replacement registrations from reading each other's record.
/// This uses the same Android encrypted SDK and native durable-write barrier as
/// identity. One isolate must own a registration; there is no cross-process lock.
class AndroidCleanupRecordStore implements CleanupRecordStore {
  final AndroidIdentityStore backend;
  final String _key;

  static String keyForScope(CleanupScope scope) =>
      'cleanup_journal_v1_${sha256.convert(utf8.encode([
        scope.tenantId,
        scope.deviceId,
        scope.registrationId,
        scope.keyThumbprint
      ].join('/')))}';

  AndroidCleanupRecordStore(CleanupScope scope,
      {FlutterSecureStorage? storage,
      MethodChannel channel =
          const MethodChannel('com.aimanager.child/runtime'),
      bool Function()? available})
      : backend = AndroidIdentityStore(
            storage: storage, channel: channel, available: available),
        _key = keyForScope(scope);

  @override
  Future<String?> read() async {
    if (!backend.available()) {
      throw const CleanupFailure('CLEANUP_JOURNAL_UNAVAILABLE');
    }
    try {
      final value = await backend.storage.read(key: _key);
      await backend._flush();
      if (value != null && utf8.encode(value).length > 4096) {
        throw const FormatException();
      }
      return value;
    } catch (_) {
      throw const CleanupFailure('CLEANUP_JOURNAL_UNAVAILABLE');
    }
  }

  @override
  Future<void> write(String record) async {
    if (!backend.available() || utf8.encode(record).length > 4096) {
      throw const CleanupFailure('CLEANUP_JOURNAL_UNAVAILABLE');
    }
    try {
      await backend.storage.write(key: _key, value: record);
      await backend._flush();
    } catch (_) {
      // A write can be durable even when its completion is lost. The journal
      // invalidates memory and rereads this exact key before another send.
      throw const CleanupFailure('CLEANUP_JOURNAL_UNAVAILABLE');
    }
  }
}

/// Scope-specific database keys protected by the existing Android storage SDK.
/// This serializes callers in the app isolate; no multi-isolate writer support.
/// A missing key must never silently replace an existing database's key.
class AndroidAccessKeyStore {
  static Future<void> _tail = Future.value();
  final AndroidIdentityStore backend;
  AndroidAccessKeyStore(
      {FlutterSecureStorage? storage,
      MethodChannel channel =
          const MethodChannel('com.aimanager.child/runtime'),
      bool Function()? available})
      : backend = AndroidIdentityStore(
            storage: storage, channel: channel, available: available);

  Future<Uint8List> keyFor(String scopeKey,
      {required bool existingDatabase}) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(scopeKey)) {
      throw const AccessFailure('ACCESS_KEY_UNAVAILABLE');
    }
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      if (!backend.available()) {
        throw const AccessFailure('ACCESS_KEY_UNAVAILABLE');
      }
      final name = 'access_key_v1_$scopeKey';
      var value = await backend.storage.read(key: name);
      await backend._flush();
      if (value == null) {
        if (existingDatabase) {
          throw const AccessFailure('ACCESS_KEY_UNAVAILABLE');
        }
        final random = Random.secure();
        final generated =
            base64Encode(List.generate(32, (_) => random.nextInt(256)));
        await backend.storage.write(key: name, value: generated);
        await backend._flush();
        value = await backend.storage.read(key: name);
        await backend._flush();
        if (value != generated) {
          throw const AccessFailure('ACCESS_KEY_UNAVAILABLE');
        }
      }
      // Bound input before decoding and reject noncanonical or truncated keys.
      if (value == null || !RegExp(r'^[A-Za-z0-9+/]{43}=$').hasMatch(value)) {
        throw const AccessFailure('ACCESS_KEY_UNAVAILABLE');
      }
      final bytes = base64Decode(value);
      if (bytes.length != 32 || base64Encode(bytes) != value) {
        throw const AccessFailure('ACCESS_KEY_UNAVAILABLE');
      }
      return bytes;
    } catch (_) {
      throw const AccessFailure('ACCESS_KEY_UNAVAILABLE');
    } finally {
      done.complete();
    }
  }
}

/// Durable authenticated context/check intent; separate from identity and DB key.
class AndroidAccessBindingStore implements ChildAccessBindingStore {
  final AndroidIdentityStore backend;
  AndroidAccessBindingStore(
      {FlutterSecureStorage? storage,
      MethodChannel channel =
          const MethodChannel('com.aimanager.child/runtime'),
      bool Function()? available})
      : backend = AndroidIdentityStore(
            storage: storage, channel: channel, available: available);
  void _check(String key) {
    if (!backend.available() || !RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
      throw const AccessFailure('ACCESS_STORAGE_FAILED');
    }
  }

  @override
  Future<String?> read(String key) async {
    _check(key);
    try {
      final value = await backend.storage.read(key: 'access_context_v1_$key');
      await backend._flush();
      if (value != null && utf8.encode(value).length > 65536) {
        throw const FormatException();
      }
      return value;
    } catch (_) {
      throw const AccessFailure('ACCESS_STORAGE_FAILED');
    }
  }

  @override
  Future<void> write(String key, String value) async {
    _check(key);
    if (utf8.encode(value).length > 65536) {
      throw const AccessFailure('ACCESS_STORAGE_FAILED');
    }
    try {
      await backend.storage.write(key: 'access_context_v1_$key', value: value);
      await backend._flush();
    } catch (_) {
      throw const AccessFailure('ACCESS_STORAGE_FAILED');
    }
  }
}

/// One encrypted help intent per registration; commit and read-back precede HTTP.
class AndroidHelpRequestStore implements ChildHelpStore {
  final AndroidIdentityStore backend;
  AndroidHelpRequestStore({AndroidIdentityStore? backend})
      : backend = backend ?? AndroidIdentityStore();

  String _name(String scopeKey) {
    if (!backend.available() || !RegExp(r'^[a-f0-9]{64}$').hasMatch(scopeKey)) {
      throw const ChildHelpFailure('HELP_STORAGE_UNAVAILABLE');
    }
    return 'help_request_v1_$scopeKey';
  }

  @override
  Future<String?> read(String scopeKey) async {
    final name = _name(scopeKey);
    try {
      final value = await backend.storage.read(key: name);
      await backend.flushForCleanup();
      if (value != null && utf8.encode(value).length > 4096) {
        throw const FormatException();
      }
      return value;
    } catch (_) {
      throw const ChildHelpFailure('HELP_STORAGE_UNAVAILABLE');
    }
  }

  @override
  Future<void> write(String scopeKey, String value) async {
    final name = _name(scopeKey);
    if (utf8.encode(value).length > 4096) {
      throw const ChildHelpFailure('HELP_STORAGE_UNAVAILABLE');
    }
    try {
      await backend.storage.write(key: name, value: value);
      await backend.flushForCleanup();
      final confirmed = await backend.storage.read(key: name);
      await backend.flushForCleanup();
      if (confirmed != value) throw const FormatException();
    } catch (_) {
      throw const ChildHelpFailure('HELP_STORAGE_UNAVAILABLE');
    }
  }
}
