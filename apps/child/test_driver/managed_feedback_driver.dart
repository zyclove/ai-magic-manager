import 'package:integration_test/integration_test_driver.dart';

/// Official driver; only fixed completion labels enter the structured report.
Future<void> main() => integrationDriver(
        timeout: const Duration(seconds: 120),
        responseDataCallback: (data) => writeResponseData(data,
            testOutputFilename: 'managed_feedback_native_result'))
    .timeout(const Duration(seconds: 150));
