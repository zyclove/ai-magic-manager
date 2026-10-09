import 'package:sembast/sembast.dart';

Future<Database> openConfigurationDatabase() => Future.error(
    UnsupportedError('Native private configuration database required'));
