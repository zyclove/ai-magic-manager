import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
        timeout: const Duration(seconds: 90),
        responseDataCallback: (data) =>
            writeResponseData(data, testOutputFilename: 'cleanup_https_result'))
    .timeout(const Duration(seconds: 120));
