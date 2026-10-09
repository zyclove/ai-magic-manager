import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:sembast/sembast.dart';

/// Sembast codec adapter using the mature PointyCastle AES-256-GCM primitive.
/// Each record uses a fresh 96-bit nonce and 128-bit authentication tag; the
/// provisioned scope hash is authenticated as AAD. This is not anti-rollback.
class AccessDatabaseCodec extends Codec<Object?, String> {
  static const _maxBytes = 1048576;
  final Uint8List _key, _aad;
  final Random _random = Random.secure();
  AccessDatabaseCodec(Uint8List key, String scopeKey)
      : _key = Uint8List.fromList(key),
        _aad = Uint8List.fromList(
            utf8.encode('aimanager.access.db.v1:$scopeKey')) {
    if (key.length != 32 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(scopeKey)) {
      throw ArgumentError('Invalid access database key or scope');
    }
  }
  SembastCodec get sembastCodec =>
      SembastCodec(signature: 'aimanager-access-aes256gcm-v1', codec: this);
  @override
  Converter<Object?, String> get encoder => _AccessEncoder(this);
  @override
  Converter<String, Object?> get decoder => _AccessDecoder(this);

  String _encode(Object? value) {
    try {
      final plain = Uint8List.fromList(utf8.encode(jsonEncode(value)));
      if (plain.length > _maxBytes) throw const FormatException();
      final nonce =
          Uint8List.fromList(List.generate(12, (_) => _random.nextInt(256)));
      final cipher = GCMBlockCipher(AESEngine())
        ..init(true, AEADParameters(KeyParameter(_key), 128, nonce, _aad));
      return base64Encode([...nonce, ...cipher.process(plain)]);
    } catch (_) {
      throw const FormatException('ACCESS_DATABASE_INVALID');
    }
  }

  Object? _decode(String value) {
    try {
      if (value.length > ((_maxBytes + 28 + 2) ~/ 3) * 4) {
        throw const FormatException();
      }
      final bytes = base64Decode(value);
      if (bytes.length < 28 || bytes.length > _maxBytes + 28) {
        throw const FormatException();
      }
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
            false,
            AEADParameters(KeyParameter(_key), 128,
                Uint8List.sublistView(bytes, 0, 12), _aad));
      return jsonDecode(
          utf8.decode(cipher.process(Uint8List.sublistView(bytes, 12))));
    } catch (_) {
      // Never include plaintext, key material or crypto exception messages.
      throw const FormatException('ACCESS_DATABASE_INVALID');
    }
  }
}

class _AccessEncoder extends Converter<Object?, String> {
  final AccessDatabaseCodec owner;
  _AccessEncoder(this.owner);
  @override
  String convert(Object? input) => owner._encode(input);
}

class _AccessDecoder extends Converter<String, Object?> {
  final AccessDatabaseCodec owner;
  _AccessDecoder(this.owner);
  @override
  Object? convert(String input) => owner._decode(input);
}
