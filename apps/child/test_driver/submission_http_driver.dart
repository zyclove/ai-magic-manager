import 'package:integration_test/integration_test_driver.dart';

/// Official VM service handshake; no credential or pairing code in reportData.
Future<void> main() => integrationDriver(
        timeout: const Duration(seconds: 120),
        responseDataCallback: (data) =>
            writeResponseData(data, testOutputFilename: 'android_http_result'))
    .timeout(const Duration(seconds: 150));
