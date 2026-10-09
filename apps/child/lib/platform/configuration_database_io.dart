import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';

Future<Database> openConfigurationDatabase({String? directoryPath}) async {
  final directory =
      directoryPath ?? (await getApplicationSupportDirectory()).path;
  return databaseFactoryIo
      // neverFails (the SDK default) may erase corruption and resurrect state.
      .openDatabase(path.join(directory, 'configuration-v1.db'),
          mode: DatabaseMode.create);
}
