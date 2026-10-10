import 'dart:convert';
import 'dart:io';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/usage_report_jobs.dart';
import 'package:guardian/core/usage_reports.dart';
import 'verify_usage_report_fixture.dart' show FixtureClient, require;

/// Loopback acceptance only. The server supplies fixture auth; all task requests
/// and result parsing use the same repository as the management application.
Future<void> main(List<String> args) async {
  require(args.length == 1, 'Fixture path required');
  final file = File(args.single);
  require(await file.length() < 20000, 'Fixture too large');
  final v = jsonDecode(await file.readAsString()) as Json;
  final uri = Uri.parse(v['apiRoot']);
  require(
      v['testOnly'] == true &&
          uri.scheme == 'http' &&
          uri.host == '127.0.0.1' &&
          uri.hasPort &&
          uri.path == '/api/v1',
      'Loopback fixture required');
  final clients = [
    FixtureClient(v['ownerToken']),
    FixtureClient(v['weakToken']),
    FixtureClient(v['otherToken'])
  ];
  UsageReportJobRepository repository(FixtureClient client) =>
      UsageReportJobRepository(
          api: Api(() async => client, baseUrl: v['apiRoot']),
          root: '/tenants/${v['tenantId']}',
          current: () => true);
  Future<void> denied(Future<dynamic> action, int status) async {
    try {
      await action;
      throw StateError('Unexpected authorization success');
    } on ApiFailure catch (e) {
      require(e.status == status, 'Unexpected denial ${e.status}');
    }
  }

  try {
    final owner = repository(clients[0]),
        weak = repository(clients[1]),
        other = repository(clients[2]);
    final input = v['selection'] as Json;
    final draft = UsageReportJobDraft(
        deviceIds: (input['deviceIds'] as List).cast<String>(),
        from: input['from'],
        to: input['to'],
        timeZone: input['timeZone'],
        period: input['period']);
    await denied(weak.create(draft, requestId()), 401);
    final key = requestId();
    var job = await owner.create(draft, key);
    require((await owner.create(draft, key)).id == job.id,
        'Idempotent replay changed task');
    await denied(other.get(job.id), 404);
    require((await other.load()).items.isEmpty,
        'Another member saw private task metadata');
    final deadline = DateTime.now().add(const Duration(seconds: 35));
    while (job.pending && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      job = await owner.get(job.id);
    }
    require(job.ready && job.completedDevices == draft.deviceIds.length,
        'Task did not complete');
    require((await owner.load()).items.single.id == job.id,
        'Task missing from list');
    for (final part in job.parts) {
      final target = UsageReportTarget(part.deviceId, part.registrationId,
          part.subjectId, 'HTTP task device');
      await denied(weak.result(job, part, target), 401);
      final report = await owner.result(job, part, target);
      require(report.devices.single.status == 'NO_DATA',
          'Unknown usage must remain NO_DATA');
      require(report.generatedAt == part.generatedAt,
          'Stored result generation changed');
      await denied(weak.download(job, part, target), 401);
      final downloaded =
          jsonDecode(utf8.decode(await owner.download(job, part, target)))
              as Json;
      require(
          downloaded['devices'][0]['deviceId'] == part.deviceId &&
              downloaded['generatedAt'] == part.generatedAt,
          'Downloaded JSON changed result binding');
    }
    require((await owner.cancel(job.id)).state == 'CANCELLED',
        'Task not cancelled');
    require((await owner.create(draft, key)).state == 'CANCELLED',
        'Replay recreated cancelled task');
    require((await owner.load()).items.single.state == 'CANCELLED',
        'List did not reflect cancel');
    await denied(
        owner.download(
            job,
            job.parts.first,
            UsageReportTarget(
                job.parts.first.deviceId,
                job.parts.first.registrationId,
                job.parts.first.subjectId,
                'Old result')),
        409);
    stdout.writeln(
        'PASS usage report jobs HTTP: create/replay/list/poll/parts/download/MFA/isolation/cancel');
  } finally {
    for (final client in clients) {
      client.close();
    }
  }
}
