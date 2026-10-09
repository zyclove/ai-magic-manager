import 'dart:typed_data';
import 'package:device_access/device_access.dart';
import 'package:sembast/sembast.dart';

typedef AccessKeyProvider = Future<Uint8List> Function(String scopeKey,
    {required bool existingDatabase});

Future<Database> openAccessDatabase(String scopeKey,
        {String? directoryPath,
        AccessKeyProvider? keyProvider,
        bool requireExisting = false}) =>
    Future.error(const AccessFailure('ACCESS_STORAGE_FAILED'));
