import 'dart:convert';
import 'dart:io';
import '../lib/core/api.dart';
import '../lib/core/support_repository.dart';
import '../lib/core/diagnostic_package.dart';
import '../lib/core/diagnostic_package_repository.dart';
import 'verify_support_http.dart' show TokenClient, check, denied;

Future<void> main(List<String> args) async {
  check(args.length == 1, 'Expected isolated fixture path');
  final file = File(args.single);
  check(await file.length() < 16384, 'Fixture too large');
  final fixture = jsonDecode(await file.readAsString()) as Json;
  final uri = Uri.parse(fixture['apiRoot'] as String);
  check(
      fixture['testOnly'] == true &&
          uri.scheme == 'http' &&
          uri.host == '127.0.0.1' &&
          uri.port > 1024 &&
          uri.path == '/api/v1',
      'Only isolated loopback server permitted');
  final clients = <TokenClient>[];
  Api api(String token) {
    final client = TokenClient(token);
    clients.add(client);
    return Api(() async => client, baseUrl: uri.toString());
  }

  DiagnosticPackageRepository packages(
          String actor, String token, bool received) =>
      DiagnosticPackageRepository(
          api: api(token),
          actor: actor,
          tenant: received ? null : fixture['tenantId'] as String,
          received: received,
          current: () => true);
  final owner = packages(fixture['owner'], fixture['ownerToken'], false),
      recipient =
          packages(fixture['recipient'], fixture['recipientToken'], true),
      weak = packages(fixture['recipient'], fixture['weakToken'], true),
      child = packages(fixture['recipient'], fixture['childToken'], true),
      customerSupport = SupportRepository(
          api: api(fixture['ownerToken']),
          actor: fixture['owner'],
          tenant: fixture['tenantId'],
          current: () => true),
      recipientSupport = SupportRepository(
          api: api(fixture['recipientToken']),
          actor: fixture['recipient'],
          current: () => true),
      outsider = SupportRepository(
          api: api(fixture['outsiderToken']),
          actor: 'package-http-outsider',
          current: () => true);
  final checks = <String>[];
  Future<DiagnosticPackage> ready(
      DiagnosticPackageRepository repo, DiagnosticPackage first) async {
    var latest = first;
    for (var count = 0; count < 150; count++) {
      final next = await repo.get(first.id);
      latest.validateUpdate(next);
      latest = next;
      if (latest.state == 'READY') return latest;
      check(latest.pendingAt(DateTime.now().millisecondsSinceEpoch),
          'Generation terminated: ${latest.state}');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('Generation deadline exceeded');
  }

  try {
    final draft = DiagnosticPackageDraft.admin(
        deviceId: fixture['deviceId'],
        registrationId: fixture['registrationId'],
        deviceVersion: 0);
    final created = await owner.create(draft),
        replay = await owner.create(draft);
    check(created.id == replay.id && created.expiresAt == replay.expiresAt,
        'Creation replay changed identity or term');
    final adminReady = await ready(owner, replay),
        adminDownload = await owner.download(adminReady);
    final adminPayload = jsonDecode(utf8.decode(adminDownload.bytes)) as Json;
    check(
        adminPayload['diagnosticTypes'].length == 3 &&
            adminPayload['accessMode'] == 'ADMIN',
        'Admin scope mismatch');
    check(!utf8.decode(adminDownload.bytes).contains('PRIVATE_'),
        'Private fixture data escaped');
    checks.add('admin real HTTP generation and exact-byte validated download');
    final grant = (await recipientSupport.grants(received: true))
        .items
        .singleWhere((g) => g.id == fixture['grantId']);
    final supportDraft = DiagnosticPackageDraft.received(grant),
        supported = await recipient.create(supportDraft),
        supportReplay = await recipient.create(supportDraft);
    check(
        supported.id == supportReplay.id &&
            supported.expiresAt == supportReplay.expiresAt,
        'Support replay changed term');
    final supportReady = await ready(recipient, supportReplay),
        supportDownload = await recipient.download(supportReady);
    final payload = jsonDecode(utf8.decode(supportDownload.bytes)) as Json,
        diagnostic = payload['diagnostic'] as Json;
    check(
        (payload['diagnosticTypes'] as List).single == 'DEVICE_STATUS' &&
            diagnostic['capabilities'] == null &&
            diagnostic['configurations'] == null,
        'Support package exceeded granted scope');
    checks.add(
        'support recipient download validates current grant and restricted fields');
    check(
        (await owner.list()).items.any((v) => v.id == created.id) &&
            (await recipient.list()).items.any((v) => v.id == supported.id),
        'Task history missing');
    await denied(() => weak.get(supported.id), 401);
    await denied(() => child.get(supported.id), 403);
    await denied(
        () => outsider.request(
            'GET', '/support/diagnostic-packages/${supported.id}/content'),
        403);
    checks.add('history MFA adult qualification and requester isolation');
    final key = requestId(),
        cancelled = await owner.cancel(adminReady, key),
        again = await owner.cancel(adminReady, key);
    check(cancelled.state == 'CANCELLED' && again.version == cancelled.version,
        'Cancel replay mismatch');
    await denied(() => owner.download(adminReady), 409);
    check((await owner.create(draft)).state == 'CANCELLED',
        'Old create revived cancelled task');
    checks.add('cancel artifact removal and non-resurrecting replay');
    await customerSupport.revoke(grant, requestId());
    await denied(() => recipient.download(supportReady), 403);
    check((await recipient.get(supported.id)).state == 'REVOKED',
        'Revoked package metadata stale');
    checks.add('grant revocation prevents later download');
    stdout.writeln(jsonEncode({
      'status': 'PASS diagnostic package HTTP lifecycle',
      'checks': checks
    }));
  } finally {
    for (final client in clients) {
      client.close();
    }
  }
}
