import 'package:sembast/sembast.dart';

Future<Database> openConfigurationDatabase({String? directoryPath}) =>
    Future.error(
        UnsupportedError('Native private configuration database required'));
