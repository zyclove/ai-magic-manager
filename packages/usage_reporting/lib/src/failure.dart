typedef ReportJson = Map<String, dynamic>;

/// Safe schema/query failure without response payloads or credentials.
class UsageReportFailure implements Exception {
  final int status;
  final String code;
  const UsageReportFailure(this.status, this.code);
  @override
  String toString() => 'UsageReportFailure($code)';
}
