import 'models.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PendingKind { confirm, cancel }

/// Contains only replay metadata, never credentials or a cleanup command.
class PendingExit {
  final PendingKind kind;
  final String key, registrationId;
  final String? previewId, previewHash, operationId;
  final int version;
  final DateTime createdAt;
  const PendingExit(
      {required this.kind,
      required this.key,
      required this.registrationId,
      required this.version,
      required this.createdAt,
      this.previewId,
      this.previewHash,
      this.operationId});
}

abstract interface class ExitJournal {
  Future<PendingExit?> read(ExitScope scope);
  Future<void> write(ExitScope scope, PendingExit pending);
  Future<void> clear(ExitScope scope);
}

/// Advisory recovery metadata. The server's idempotency journal is authoritative.
class PreferencesExitJournal implements ExitJournal {
  final SharedPreferencesAsync preferences;
  PreferencesExitJournal({SharedPreferencesAsync? preferences})
      : preferences = preferences ?? SharedPreferencesAsync();
  String _digest(ExitScope scope) =>
      sha256.convert(utf8.encode(scope.storageIdentity)).toString();
  String keyFor(ExitScope scope) =>
      'ai_manager.device_exit.v1.${_digest(scope)}';

  PendingExit _decode(ExitScope scope, String raw) {
    if (raw.length > 4096) {
      throw const FormatException('Oversized recovery record');
    }
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> ||
        value['schema'] != 1 ||
        value['scopeHash'] != _digest(scope) ||
        value['registrationId'] != scope.registrationId ||
        value['version'] is! int ||
        value['version'] < 0 ||
        value['version'] > 9007199254740991 ||
        value['createdAt'] is! int ||
        value['createdAt'] < 0 ||
        value['createdAt'] > 8640000000000000 ||
        value['key'] is! String) {
      throw const FormatException('Invalid recovery record');
    }
    final kind = switch (value['kind']) {
      'confirm' => PendingKind.confirm,
      'cancel' => PendingKind.cancel,
      _ => throw const FormatException('Unsupported recovery kind'),
    };
    String? id, hash, operation;
    if (kind == PendingKind.confirm) {
      if (value['previewId'] is! String ||
          value['previewHash'] is! String ||
          value['operationId'] != null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['previewHash'])) {
        throw const FormatException('Invalid recovery preview');
      }
      id = canonicalId(value['previewId']);
      hash = value['previewHash'];
    } else {
      if (value['operationId'] is! String ||
          value['previewId'] != null ||
          value['previewHash'] != null) {
        throw const FormatException('Invalid recovery operation');
      }
      operation = canonicalId(value['operationId']);
    }
    return PendingExit(
        kind: kind,
        key: canonicalId(value['key']),
        registrationId: scope.registrationId,
        version: value['version'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(value['createdAt'],
            isUtc: true),
        previewId: id,
        previewHash: hash,
        operationId: operation);
  }

  Map<String, dynamic> _encode(ExitScope scope, PendingExit value) => {
        'schema': 1,
        'scopeHash': _digest(scope),
        'registrationId': value.registrationId,
        'kind': value.kind.name,
        'key': value.key,
        'version': value.version,
        'createdAt': value.createdAt.millisecondsSinceEpoch,
        'previewId': value.previewId,
        'previewHash': value.previewHash,
        'operationId': value.operationId,
      };
  @override
  Future<PendingExit?> read(ExitScope scope) async {
    final raw = await preferences.getString(keyFor(scope));
    return raw == null ? null : _decode(scope, raw);
  }

  @override
  Future<void> write(ExitScope scope, PendingExit pending) async {
    final encoded = jsonEncode(_encode(scope, pending));
    _decode(scope, encoded);
    final previous = await read(scope);
    if (previous != null && jsonEncode(_encode(scope, previous)) != encoded) {
      throw StateError('Another write requires reconciliation first');
    }
    await preferences.setString(keyFor(scope), encoded);
  }

  @override
  Future<void> clear(ExitScope scope) => preferences.remove(keyFor(scope));
}
