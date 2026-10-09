import 'dart:io';
import 'package:child/platform/configuration_database_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';

void main() {
  test('configuration corruption fails and preserves the original file',
      () async {
    final dir = await Directory.systemTemp.createTemp('child-configuration-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/configuration-v1.db');
    await file.writeAsString('not-a-valid-sembast-header\n', flush: true);
    final original = await file.readAsBytes();
    Database? opened;
    addTearDown(() async => opened?.close());
    await expectLater(() async {
      opened = await openConfigurationDatabase(directoryPath: dir.path);
    }(), throwsA(anything));
    expect(await file.readAsBytes(), original);
  });
  test('missing configuration database can be created and reopened', () async {
    final dir = await Directory.systemTemp.createTemp('child-configuration-');
    addTearDown(() => dir.delete(recursive: true));
    var db = await openConfigurationDatabase(directoryPath: dir.path);
    final store = stringMapStoreFactory.store('fixture');
    await store.record('key').put(db, {'value': 1});
    await db.close();
    db = await openConfigurationDatabase(directoryPath: dir.path);
    expect((await store.record('key').get(db))?['value'], 1);
    await db.close();
  });
}
