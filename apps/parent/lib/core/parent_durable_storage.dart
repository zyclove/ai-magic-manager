import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Android-only durability barrier for operation references saved before POST.
/// Encryption remains owned by flutter_secure_storage; this class never reads
/// or exposes the native keystore or other SharedPreferences values.
class ParentDurableStorage {
  final FlutterSecureStorage storage;
  final MethodChannel channel;
  final bool Function() available;

  ParentDurableStorage({
    FlutterSecureStorage? storage,
    this.channel = const MethodChannel('com.aimanager.parent/storage'),
    bool Function()? available,
  })  : storage = storage ?? const FlutterSecureStorage(),
        available = available ??
            (() => !kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  Future<String?> read({required String key}) async {
    _requireAvailable();
    final value = await storage.read(key: key);
    await _flush();
    return value;
  }

  Future<void> write({required String key, required String value}) async {
    _requireAvailable();
    await storage.write(key: key, value: value);
    await _flush();
  }

  Future<void> delete({required String key}) async {
    _requireAvailable();
    await storage.delete(key: key);
    await _flush();
  }

  void _requireAvailable() {
    if (!available()) throw StateError('安全存储在此平台不可用。');
  }

  Future<void> _flush() async {
    if (await channel.invokeMethod<bool>('flushSecureStorage') != true) {
      throw StateError('安全存储尚未确认落盘，操作已停止。');
    }
  }
}
