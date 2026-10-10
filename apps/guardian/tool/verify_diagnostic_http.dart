import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:guardian/core/api.dart';
import 'package:guardian/core/diagnostic_repository.dart';

/// Uses only an isolated loopback Spring test server and test-only identities.
/// Exercises the production repository; this does not prove an IdP MFA login.
class FixtureClient extends http.BaseClient {
  final http.Client delegate = http.Client();
  final String token;
  int requests = 0;
  FixtureClient(this.token);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    require(request.method == 'GET' && !request.followRedirects,
        'Read-only request without redirects required');
    request.headers['Authorization'] = 'Bearer $token';
    requests++;
    final response = await delegate.send(request);
    require(response.headers['cache-control']?.contains('no-store') == true,
        'Diagnostic response must not be cached');
    if (response.statusCode == 200) {
      require(
          response.headers['vary']?.toLowerCase().contains('authorization') ==
              true,
          'Diagnostic response must vary by authorization');
    }
    return response;
  }

  @override
  void close() => delegate.close();
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> denied(
    DiagnosticRepository repository, String code, int status) async {
  try {
    await repository.load();
  } on ApiFailure catch (failure) {
    require(failure.code == code && failure.status == status,
        'Unexpected diagnostic error: ${failure.code}/${failure.status}');
    return;
  }
  throw StateError('Expected diagnostic access failure');
}

Future<void> main(List<String> arguments) async {
  require(arguments.length == 1, 'Fixture path required');
  final file = File(arguments.single);
  require(await file.length() < 16384, 'Fixture too large');
  final fixture = jsonDecode(await file.readAsString()) as Json;
  final uri = Uri.parse(fixture['apiRoot']);
  require(
      fixture['testOnly'] == true &&
          uri.scheme == 'http' &&
          uri.host == '127.0.0.1' &&
          uri.hasPort &&
          uri.path == '/api/v1',
      'Isolated loopback test fixture required');
  final owner = FixtureClient(fixture['strongToken']),
      weak = FixtureClient(fixture['weakToken']),
      outsider = FixtureClient(fixture['outsiderToken']);
  DiagnosticRepository repository(FixtureClient client,
          {String? registration}) =>
      DiagnosticRepository(
          api: Api(() async => client, baseUrl: fixture['apiRoot']),
          tenantId: fixture['tenantId'],
          deviceId: fixture['deviceId'],
          registrationId: registration ?? fixture['registrationId'],
          current: () => true);
  final phase = fixture['phase'];
  try {
    switch (phase) {
      case 'initial':
        final result = await repository(owner).load();
        require(result.agent.value == '1.2.3' && result.os.value == '14',
            'Versions differ');
        require(result.capabilities.any((value) => value.key == 'usage.report'),
            'Capability missing');
        require(
            result.configurations.length == 1 &&
                result.configurations.single.policyHash ==
                    List.filled(64, 'a').join() &&
                result.configurations.single.deliveryState ==
                    'DEVICE_REPORTED_STORED',
            'Configuration metadata differs');
        await denied(repository(weak), 'REAUTH_REQUIRED', 401);
        await denied(repository(outsider), 'SCOPE_DENIED', 403);
        await denied(
            repository(owner,
                registration: '00000000-0000-0000-0000-000000000000'),
            'INVALID_DIAGNOSTIC_RESPONSE',
            502);
        require(
            owner.requests == 2 && weak.requests == 1 && outsider.requests == 1,
            'Unexpected initial request count');
      case 'revoked-device':
        final result = await repository(owner).load();
        require(result.state == 'REVOKED' && result.configurations.length == 1,
            'Revoked device metadata differs');
      case 'changed-registration':
        await denied(repository(owner), 'INVALID_DIAGNOSTIC_RESPONSE', 502);
      case 'new-registration':
        final result = await repository(owner).load();
        require(result.configurations.isEmpty,
            'Old registration configuration leaked');
      case 'archived-subject':
      case 'revoked-member':
        await denied(repository(owner), 'SCOPE_DENIED', 403);
      default:
        throw StateError('Unknown diagnostic fixture phase');
    }
    stdout.writeln('PASS diagnostic HTTP $phase');
  } finally {
    owner.close();
    weak.close();
    outsider.close();
  }
}
