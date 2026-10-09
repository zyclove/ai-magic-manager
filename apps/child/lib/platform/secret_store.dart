import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:device_access/device_access.dart';
import 'package:device_identity/device_identity.dart';
import 'package:device_observation/device_observation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/access.dart' show ChildAccessBindingStore;

/// One encrypted record, no readAll/delete/reset surface. Android only until
/// each additional native storage implementation is separately certified.
class AndroidIdentityStore implements DeviceSecretStore {
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
  AndroidIdentityStore(
      {FlutterSecureStorage? storage,
      this.channel = const MethodChannel('com.aimanager.child/runtime'),
      bool Function()? available})
      : storage = storage ?? const FlutterSecureStorage(aOptions: options),
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
    try {
      await storage.write(key: 'identity_record', value: record);
      // Plugin v10 uses SharedPreferences.apply(). Wait for native commit of
      // wrapping key/config/data before identity intent is allowed onto HTTP.
      await _flush();
    } catch (_) {
      throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
    }
  }

  Future<void> _flush() async {
    if (await channel.invokeMethod<bool>('flushIdentity') != true) {
      throw const DeviceIdentityFailure('SECURE_STORAGE_FAILED');
    }
  }
}

/// 复用已配置的成熟加密 SDK 与持久屏障，单独固定键，不改动设备身份记录。
class AndroidObservationStore implements ObservationStore {
  final AndroidIdentityStore backend;
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
      final record = await backend.storage.read(key: 'observation_record');
      await backend._flush();
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
    try {
      await backend.storage.write(key: 'observation_record', value: value);
      await backend._flush();
    } catch (_) {
      throw const ObservationFailure('OBSERVATION_STORAGE_FAILED');
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
