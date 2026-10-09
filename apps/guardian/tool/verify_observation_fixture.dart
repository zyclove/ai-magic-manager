// Controlled adult JWT-decoder fixture, not a real OIDC/MFA login proof.
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:guardian/core/api.dart';
import 'package:guardian/core/observation.dart';

class FixtureClient extends http.BaseClient {
  final String token;
  final http.Client delegate = http.Client();
  FixtureClient(this.token);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer $token';
    request.followRedirects = false;
    return delegate.send(request);
  }

  @override
  void close() => delegate.close();
}

void check(bool condition) {
  if (!condition) throw StateError('Fixture assertion failed');
}

Future<void> run(List<String> args) async {
  check(args.length == 2 &&
      const ['grant', 'list', 'withdraw', 'regrant'].contains(args[1]));
  final input = jsonDecode(await File(args[0]).readAsString()) as Map;
  final root = Uri.parse(input['apiRoot']);
  check(input['testOnly'] == true &&
      root.scheme == 'http' &&
      root.host == '127.0.0.1' &&
      root.path == '/api/v1');
  final client = FixtureClient(input['adultCredential']);
  final repo = ObservationRepository(
      api: Api(() async => client, baseUrl: root.toString()),
      root: '/tenants/${input['tenantId']}',
      deviceId: input['deviceId'],
      registrationId: input['registrationId'],
      current: () => true);
  try {
    final snapshot = await repo.load();
    if (args[1] == 'list') {
      check(snapshot.batches.length == 1 &&
          snapshot.batches.single.applications.length == 1);
    } else {
      final enabled = args[1] != 'withdraw';
      await repo.update(
          snapshot.settings,
          {
            'inventoryEnabled': enabled,
            'usageEnabled': enabled,
            'reason': 'Synthetic HTTP fixture\nExplicit consent check'
          },
          requestId());
      final fresh = await repo.load();
      check(fresh.settings.version == snapshot.settings.version + 1 &&
          fresh.settings.usageEnabled == enabled);
      if (!enabled) check(fresh.batches.isEmpty);
    }
    stdout.writeln('PASS observation guardian ${args[1]}');
  } finally {
    client.close();
  }
}

Future<void> main(List<String> args) async {
  try {
    await run(args);
  } catch (_) {
    stderr.writeln('FAIL isolated observation guardian fixture');
    exitCode = 1;
  }
}
