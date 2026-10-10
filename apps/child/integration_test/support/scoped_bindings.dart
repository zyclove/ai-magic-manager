import 'dart:convert';
import 'dart:typed_data';
import 'package:child/core/access.dart' show ChildAccessBindingStore;
import 'package:child/platform/secret_store.dart';
import 'package:pointycastle/digests/sha256.dart';

/// Test installation namespace for binding records whose encrypted databases
/// live in the run directory. Production keys remain untouched. PointyCastle
/// provides the digest; the product's encrypted SDK still owns storage.
String scopedBindingKey(String runId, String key) {
  if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(runId) ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) {
    throw const FormatException('Invalid owned binding scope');
  }
  final bytes = SHA256Digest().process(
      Uint8List.fromList(utf8.encode('production-joint-v1/$runId/$key')));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class ScopedBindings implements ChildAccessBindingStore {
  final AndroidAccessBindingStore backend;
  final String runId;
  ScopedBindings(this.backend, this.runId);
  @override
  Future<String?> read(String key) =>
      backend.read(scopedBindingKey(runId, key));
  @override
  Future<void> write(String key, String value) =>
      backend.write(scopedBindingKey(runId, key), value);
}
