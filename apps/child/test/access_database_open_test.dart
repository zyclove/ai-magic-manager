import 'dart:io';
import 'dart:typed_data';
import 'package:child/platform/access_database_io.dart';
import 'package:device_access/device_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';

void main() {
  const scope =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  test('private database opener binds file/key and reopens encrypted state',
      () async {
    final dir = await Directory.systemTemp.createTemp('child-access-open-');
    addTearDown(() => dir.delete(recursive: true));
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final calls = <bool>[];
    Future<Uint8List> provider(String value,
        {required bool existingDatabase}) async {
      expect(value, scope);
      calls.add(existingDatabase);
      return key;
    }

    final store = stringMapStoreFactory.store('fixture');
    var db = await openAccessDatabase(scope,
        directoryPath: dir.path, keyProvider: provider);
    await store.record('request').put(db, {'marker': 'synthetic-open-marker'});
    await db.close();
    final file = File('${dir.path}/access-v1-$scope.db');
    expect(
        (await file.readAsString()).contains('synthetic-open-marker'), isFalse);
    db = await openAccessDatabase(scope,
        directoryPath: dir.path, keyProvider: provider);
    expect((await store.record('request').get(db))?['marker'],
        'synthetic-open-marker');
    await db.close();
    expect(calls, [false, true]);
    final original = await file.readAsBytes();
    await expectLater(
        openAccessDatabase(scope,
            directoryPath: dir.path,
            keyProvider: (_, {required existingDatabase}) async =>
                Uint8List(32)),
        throwsA(isA<AccessFailure>()));
    expect(await file.readAsBytes(), original);
    await expectLater(
        openAccessDatabase(scope,
            directoryPath: dir.path,
            keyProvider: (_, {required existingDatabase}) async =>
                throw const AccessFailure('ACCESS_KEY_UNAVAILABLE')),
        throwsA(isA<AccessFailure>()));
    expect(await file.readAsBytes(), original);
  });
  test('invalid scope is rejected without storage or path provider access',
      () async {
    var called = false;
    await expectLater(
        openAccessDatabase('../outside',
            keyProvider: (_, {required existingDatabase}) async {
          called = true;
          return Uint8List(32);
        }),
        throwsA(isA<AccessFailure>()));
    expect(called, isFalse);
  });
}
