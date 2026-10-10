import 'dart:convert';
import 'api.dart';
import 'usage_report_jobs.dart';

/// Only the pending query and its idempotency key survive a same-tab step-up.
/// Restoring this envelope always opens review; it never submits a request.
class ReportJobResume {
  final UsageReportJobDraft draft;
  final String requestKey;
  const ReportJobResume(this.draft, this.requestKey);
  String encode(
          {required String actor,
          required String root,
          required String role,
          required int now}) =>
      jsonEncode({
        'version': 1,
        'actor': actor,
        'root': root,
        'role': role,
        'createdAt': now,
        'requestKey': requestKey,
        'draft': draft.body
      });
  static ReportJobResume? decode(String? text,
      {required String actor,
      required String root,
      required String role,
      required int now}) {
    if (text == null ||
        text.length > 20000 ||
        !usageReportJobRoles.contains(role)) return null;
    try {
      final v = jsonDecode(text);
      if (v is! Json ||
          v.length != 7 ||
          v['version'] != 1 ||
          v['actor'] != actor ||
          v['root'] != root ||
          v['role'] != role ||
          v['createdAt'] is! int ||
          now < v['createdAt'] ||
          now - v['createdAt'] > 600000 ||
          v['requestKey'] is! String ||
          !RegExp(r'^[0-9a-f]{48}$').hasMatch(v['requestKey'])) return null;
      return ReportJobResume(
          UsageReportJobDraft.parse(v['draft']), v['requestKey']);
    } catch (_) {
      return null;
    }
  }
}
