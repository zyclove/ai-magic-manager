import 'dart:io';
import 'dart:typed_data';
import 'package:device_access/device_access.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'access_codec.dart';
import 'secret_store.dart';

typedef AccessKeyProvider = Future<Uint8List> Function(String scopeKey,
    {required bool existingDatabase});

/// Call only after the authenticated context has matched the active identity.
/// The database remains opaque on corruption or missing/wrong key; no reset.
Future<Database> openAccessDatabase(String scopeKey,
    {String? directoryPath,
    AccessKeyProvider? keyProvider,
    bool requireExisting = false}) async {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(scopeKey)) {
    throw const AccessFailure('ACCESS_STORAGE_FAILED');
  }
  try {
    final directory =
        directoryPath ?? (await getApplicationSupportDirectory()).path;
    final file = File(path.join(directory, 'access-v1-$scopeKey.db'));
    final exists = await file.exists();
    if (requireExisting && !exists) {
      throw const AccessFailure('ACCESS_STORAGE_FAILED');
    }
    final provider = keyProvider ?? AndroidAccessKeyStore().keyFor;
    final key = await provider(scopeKey, existingDatabase: exists);
    return await databaseFactoryIo.openDatabase(file.path,
        mode: DatabaseMode.create,
        codec: AccessDatabaseCodec(key, scopeKey).sembastCodec);
  } on AccessFailure {
    rethrow;
  } catch (_) {
    throw const AccessFailure('ACCESS_STORAGE_FAILED');
  }
}
