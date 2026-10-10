import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../lib/core/api.dart';
import '../lib/core/support.dart';
import '../lib/core/support_repository.dart';

class TokenClient extends http.BaseClient {
  final http.Client delegate = http.Client();
  final String token;
  TokenClient(this.token);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer $token';
    return delegate.send(request);
  }

  @override
  void close() => delegate.close();
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> denied(Future<Object?> Function() action, int status) async {
  try {
    await action();
    throw StateError('Expected denied support operation');
  } on ApiFailure catch (failure) {
    check(failure.status == status, 'Unexpected support denial status');
  }
}

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
  SupportRepository repo(String who, String token, {bool customer = false}) {
    final client = TokenClient(token);
    clients.add(client);
    return SupportRepository(
        api: Api(() async => client, baseUrl: uri.toString()),
        actor: who,
        tenant: customer ? fixture['tenantId'] as String : null,
        current: () => true);
  }

  final owner = repo(
          fixture['owner'] as String, fixture['ownerToken'] as String,
          customer: true),
      recipient = repo(
          fixture['recipient'] as String, fixture['recipientToken'] as String),
      weak =
          repo(fixture['recipient'] as String, fixture['weakToken'] as String),
      child =
          repo(fixture['recipient'] as String, fixture['childToken'] as String),
      outsider =
          repo('support-http-outsider', fixture['outsiderToken'] as String);
  final checks = <String>[];
  try {
    final pairKey = requestId(), first = await recipient.createPairing(pairKey);
    check(first.code != null && first.request.state == 'PENDING',
        'Pairing code missing');
    final retry = await recipient.createPairing(pairKey);
    check(retry.request.id == first.request.id && retry.code == null,
        'Pairing replay leaked or changed code');
    checks.add('single-use pairing and safe replay');
    final confirmed = await owner.resolve(first.code!);
    check(
        confirmed.recipientActorId == fixture['recipient'] &&
            confirmed.id == first.request.id,
        'Resolved identity mismatch');
    final draft = SupportGrantDraft(
        tenantId: fixture['tenantId'] as String,
        deviceId: fixture['deviceId'] as String,
        registrationId: fixture['registrationId'] as String,
        recipientActorId: confirmed.recipientActorId,
        pairingCode: first.code!,
        deviceVersion: 0,
        durationMinutes: 60,
        diagnosticTypes: supportTypes);
    final grant = await owner.createGrant(draft),
        same = await owner.createGrant(draft);
    check(grant.id == same.id && grant.expiresAt == same.expiresAt,
        'Grant retry changed authority');
    checks.add('confirmed scope and idempotent grant');
    final received = await recipient.grants(received: true),
        customer = await owner.grants(received: false);
    check(
        received.items.any((v) => v.id == grant.id) &&
            customer.items.any((v) => v.id == grant.id),
        'Grant missing from history');
    final diagnostic = await recipient.diagnostic(grant);
    check(
        diagnostic.device?.state == 'ACTIVE' &&
            diagnostic.versions?.agent.value == '1.2.3' &&
            diagnostic.capabilities!.isNotEmpty &&
            diagnostic.configurations!.single.policyHash == 'a' * 64,
        'Production diagnostic projection mismatch');
    checks.add('real HTTP typed diagnostic with all selected sections');
    await denied(() => weak.diagnostic(grant), 401);
    await denied(() => child.diagnostic(grant), 403);
    // The production client rejects another recipient locally; the server route is checked independently.
    await denied(
        () => outsider.request(
            'GET', '/support/grants/${grant.id}/diagnostic-preview'),
        403);
    checks.add('current MFA adult qualification and recipient isolation');
    final key = requestId(),
        revoked = await owner.revoke(grant, key),
        again = await owner.revoke(grant, key);
    check(
        revoked.state == 'REVOKED' &&
            again.id == grant.id &&
            again.version == revoked.version,
        'Revoke replay mismatch');
    final oldCreate = await owner.createGrant(draft);
    check(oldCreate.state == 'REVOKED', 'Old create resurrected grant');
    await denied(() => recipient.diagnostic(grant), 403);
    check(
        (await recipient.grants(received: true)).items.single.state ==
            'REVOKED',
        'Revoked history stale');
    checks.add('revocation and old-retry non-resurrection');
    final consumed = (await recipient.pairings())
        .items
        .firstWhere((v) => v.id == first.request.id);
    check(consumed.state == 'CONSUMED', 'Pairing not consumed');
    await denied(() => recipient.cancelPairing(consumed, requestId()), 409);
    checks.add('consumed pairing cannot be cancelled or reused');
    stdout.writeln(jsonEncode(
        {'status': 'PASS support HTTP grant-lifecycle', 'checks': checks}));
  } finally {
    for (final client in clients) {
      client.close();
    }
  }
}
