import 'package:integration_test/integration_test_driver.dart';

/// The outer standard Future deadline includes VM service/isolate discovery;
/// integrationDriver's request deadline begins after its connection succeeds.
Future<void> main() => integrationDriver(timeout: const Duration(seconds: 90))
    .timeout(const Duration(seconds: 120));
