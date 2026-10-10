library device_reports;

import 'package:device_policy/device_policy.dart';
import 'package:usage_reporting/usage_reporting.dart';
export 'package:usage_reporting/usage_reporting.dart';

/// Bind to one host session and its current registration, never to server
/// supplied selectors. The caller owns the transport and invalidates [current]
/// whenever identity, foreground access or observation authorization changes.
/// Reports are memory-only; this reader never persists or automatically retries.
class DeviceUsageReportClient {
  final DeviceConfigurationTransport transport;
  final UsageReportTarget target;
  final bool Function() current;
  bool _disposed = false;

  DeviceUsageReportClient(
      {required this.transport, required this.target, required this.current}) {
    if (!target.valid) {
      throw const UsageReportFailure(400, 'INVALID_USAGE_REPORT_QUERY');
    }
  }

  void _ensureCurrent() {
    if (_disposed || !current()) {
      throw const UsageReportFailure(409, 'DEVICE_CONTEXT_CHANGED');
    }
  }

  Future<UsageReport> load(
      {required int from,
      required int to,
      required String timeZone,
      String period = 'DAY'}) async {
    _ensureCurrent();
    final query = UsageReportQuery(
        targets: [target],
        from: from,
        to: to,
        timeZone: timeZone,
        period: period);
    usageLocation(timeZone);
    try {
      final value = await transport.usageReport(
          from: from, to: to, timeZone: timeZone, period: period);
      _ensureCurrent();
      final report = UsageReport.parse(value, query);
      _ensureCurrent();
      return report;
    } catch (_) {
      _ensureCurrent();
      rethrow;
    }
  }

  /// Invalidates in-flight results without closing a shared host transport.
  void dispose() {
    _disposed = true;
  }
}
