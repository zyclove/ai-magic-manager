import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:child/platform/access_codec.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i));
  const scope =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  AccessDatabaseCodec codec([Uint8List? secret, String binding = scope]) =>
      AccessDatabaseCodec(secret ?? key, binding);
  test('AEAD round trip supports unicode and uses fresh nonces', () {
    final c = codec();
    final value = {
      'child': '合成测试，不是真实儿童数据',
      'number': 42,
      'flags': [true, null]
    };
    final a = c.encode(value), b = c.encode(value);
    expect(a == b, isFalse);
    expect(c.decode(a), value);
    expect(a.contains('合成'), isFalse);
    expect(() => codec(Uint8List(31)), throwsArgumentError);
    expect(() => codec(key, '../invalid'), throwsArgumentError);
  });
  test('wrong key, scope and modified ciphertext fail without exposing payload',
      () {
    final encoded = codec().encode({'secretMarker': 'synthetic-only'});
    final bytes = base64Decode(encoded);
    bytes[bytes.length - 1] ^= 1;
    for (final read in [
      () => codec(Uint8List(32)).decode(encoded),
      () => codec(key, 'b' * 64).decode(encoded),
      () => codec().decode(base64Encode(bytes)),
      () => codec().decode('broken')
    ]) {
      expect(
          read,
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'safe code', 'ACCESS_DATABASE_INVALID')));
    }
  });
  test('caller key mutation and oversized payload cannot change codec trust',
      () {
    final input = Uint8List.fromList(key);
    final original = codec(input);
    final value = original.encode({'marker': 'synthetic-key-copy'});
    input.fillRange(0, input.length, 0);
    expect(original.decode(value), {'marker': 'synthetic-key-copy'});
    expect(() => original.encode('x' * 1048577), throwsFormatException);
    expect(() => original.decode('A' * 1500000), throwsFormatException);
  });
  test(
      'actual encrypted file transactions reopen and retain rollback semantics',
      () async {
    final dir = await Directory.systemTemp.createTemp('child-access-db-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/access.db');
    final store = stringMapStoreFactory.store('requests');
    final secret = codec();
    Future<Database> open() => databaseFactoryIo.openDatabase(file.path,
        mode: DatabaseMode.create, codec: secret.sembastCodec);
    var db = await open();
    await store
        .record('request')
        .put(db, {'marker': 'synthetic-sensitive-marker', 'version': 1});
    await expectLater(db.transaction((txn) async {
      await store.record('request').put(txn, {'version': 2});
      throw StateError('rollback fixture');
    }), throwsStateError);
    await db.close();
    expect((await file.readAsString()).contains('synthetic-sensitive-marker'),
        isFalse);
    db = await open();
    expect((await store.record('request').get(db))?['version'], 1);
    await db.close();
    final original = await file.readAsBytes();
    await expectLater(
        databaseFactoryIo.openDatabase(file.path,
            mode: DatabaseMode.create,
            codec: codec(Uint8List(32)).sembastCodec),
        throwsA(anything));
    expect(await file.readAsBytes(), original,
        reason: 'Wrong key must not reset or repair user data');
  });
}
