import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/report_job_resume.dart';
import 'usage_report_jobs_test.dart' show draft;

void main() {
  test('resume is bound to account workspace role and a ten minute lifetime',
      () {
    final resume = ReportJobResume(draft(), 'a' * 48);
    final encoded = resume.encode(
        actor: 'actor', root: '/tenants/one', role: 'OWNER', now: 1000);
    ReportJobResume? read(
            {String actor = 'actor',
            String root = '/tenants/one',
            String role = 'OWNER',
            int now = 2000}) =>
        ReportJobResume.decode(encoded,
            actor: actor, root: root, role: role, now: now);
    expect(read()!.requestKey, resume.requestKey);
    expect(read()!.draft.body, resume.draft.body);
    expect(read(actor: 'other'), isNull);
    expect(read(root: '/tenants/two'), isNull);
    expect(read(role: 'CHILD'), isNull);
    expect(read(now: 601001), isNull);
    expect(read(now: 999), isNull);
    final value = jsonDecode(encoded);
    value['draft']['deviceIds'] = ['bad'];
    expect(
        ReportJobResume.decode(jsonEncode(value),
            actor: 'actor', root: '/tenants/one', role: 'OWNER', now: 2000),
        isNull);
    expect(encoded.contains('access_token'), false);
  });
}
