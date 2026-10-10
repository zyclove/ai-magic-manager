import 'package:integration_test/integration_test_driver.dart';

/// Official driver retains the install; the host proves process death and reads
/// safe reportData independently of application log formatting.
Future<void> main() => integrationDriver(
        timeout: const Duration(seconds: 90),
        responseDataCallback: (data) => writeResponseData(data,
            testOutputFilename: 'submission_storage_result'))
    .timeout(const Duration(seconds: 120));
