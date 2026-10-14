import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/enrollment_recovery.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:http/http.dart' as http;

class MemoryStrings implements EnrollmentStringStorage {
  final values = <String, String>{};
  @override
  String? read(String key) => values[key];
  @override
  void write(String key, String value) => values[key] = value;
  @override
  void remove(String key) => values.remove(key);
}

/// Actual network traffic with one deliberate loss after Spring committed 201.
/// Observations retain only protocol fields and status codes, never token values.
class FixtureTransport extends http.BaseClient {
  final String bearer;
  final bool loseFirstCreation;
  final delegate = http.Client();
  final requests = <({String method, String path, String? creationId})>[];
  final responses = <({String path, int status, Set<String> keys})>[];
  bool lost = false;
  FixtureTransport(this.bearer, {this.loseFirstCreation = false});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.headers['Authorization'] = 'Bearer $bearer';
    requests.add((
      method: request.method,
      path: request.url.path,
      creationId: request.headers['client-request-id'],
    ));
    final response = await delegate.send(request);
    final bytes = await response.stream.toBytes();
    final keys = <String>{};
    if (bytes.isNotEmpty) {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) keys.addAll(decoded.keys);
    }
    responses
        .add((path: request.url.path, status: response.statusCode, keys: keys));
    if (loseFirstCreation &&
        !lost &&
        request.method == 'POST' &&
        request.url.path.endsWith('/enrollments') &&
        response.statusCode == 201) {
      lost = true;
      throw http.ClientException('Synthetic lost committed creation reply');
    }
    return http.StreamedResponse(Stream.value(bytes), response.statusCode,
        headers: response.headers,
        contentLength: bytes.length,
        request: response.request);
  }

  @override
  void close() => delegate.close();
}

void main() {
  test(
      'production guardian recovers committed creation and pairing failure facts',
      () async {
    final encoded = Platform.environment['GUARDIAN_ENROLLMENT_HTTP_FIXTURE'];
    if (encoded == null || encoded.length > 16000) {
      throw StateError('Explicit bounded HTTP fixture is required');
    }
    final fixture = jsonDecode(encoded) as Json;
    final root = Uri.parse(fixture['apiRoot'] as String);
    if (fixture['testOnly'] != true ||
        root.scheme != 'http' ||
        root.host != '127.0.0.1' ||
        !root.hasPort ||
        root.path != '/api/v1' ||
        root.hasQuery ||
        root.hasFragment ||
        root.userInfo.isNotEmpty) {
      throw StateError('Only explicit loopback Spring fixtures are permitted');
    }
    final scope = EnrollmentScope(
        actorId: fixture['actorId'],
        tenantId: fixture['tenantId'],
        role: 'OWNER');
    final originalId = fixture['creationId'] as String;
    final strings = MemoryStrings();
    final journal = StoredEnrollmentJournal(strings);
    final network = FixtureTransport(fixture['token'], loseFirstCreation: true);
    final otherNetwork = FixtureTransport(fixture['otherToken']);
    final transport = ScopeGuardedClient(network);
    final otherTransport = ScopeGuardedClient(otherNetwork);
    final api = Api(() async => transport, baseUrl: root.toString());
    final otherApi = Api(() async => otherTransport, baseUrl: root.toString());
    final gateway = EnrollmentGateway(api);
    EnrollmentController controller() => EnrollmentController(
        scope: scope,
        journal: journal,
        gateway: gateway,
        isCurrent: () => true,
        newId: () => originalId,
        now: () => DateTime.now().millisecondsSinceEpoch);
    final controllers = <EnrollmentController>[];
    try {
      final first = controller();
      controllers.add(first);
      await first.initialize();
      expect(first.canCreate, isTrue);
      expect(network.requests, isEmpty);
      await first.create(subjectId: fixture['subjectId'], platform: 'ANDROID');
      expect(network.lost, isTrue);
      expect(
          first.error,
          isA<ApiFailure>().having(
              (failure) => failure.code, 'lost reply code', 'NETWORK_ERROR'));
      expect(first.pending!.requestId, originalId);
      expect(first.ticket, isNull);
      expect(first.canRetryCreation, isFalse);
      expect(network.requests.where((request) => request.method == 'POST'),
          hasLength(1));
      final saved = (await journal.read(scope))!;
      expect(saved.requestId, originalId);
      final savedFields = jsonDecode(strings.values[scope.key]!) as Json;
      expect(savedFields.keys, isNot(contains('token')));
      expect(savedFields.keys, isNot(contains('pairingCode')));
      first.dispose();
      controllers.remove(first);

      final recovered = controller();
      controllers.add(recovered);
      await recovered.initialize();
      expect(recovered.error, isNull);
      expect(recovered.progress!.id, originalId);
      expect(recovered.progress!.state, 'PENDING_CLAIM');
      expect(recovered.ticket, isNull);
      expect(recovered.canRetryCreation, isFalse);
      expect(network.requests.where((request) => request.method == 'POST'),
          hasLength(1));
      expect(
          network.responses
              .where((response) =>
                  response.path.contains('/enrollment-creation-results/') &&
                  response.status == 200)
              .every((response) => !response.keys.contains('token')),
          isTrue);

      final otherIntent = EnrollmentIntent(
          scope: EnrollmentScope(
              actorId: fixture['otherActorId'],
              tenantId: scope.tenantId,
              role: 'GUARDIAN'),
          requestId: saved.requestId,
          subjectId: saved.subjectId,
          platform: saved.platform,
          createdAt: saved.createdAt);
      await expectLater(
          EnrollmentGateway(otherApi).read(otherIntent, isCurrent: () => true),
          throwsA(isA<ApiFailure>()
              .having((failure) => failure.status, 'creator-bound status', 404)
              .having((failure) => failure.code, 'creator-bound code',
                  'ENROLLMENT_CREATION_UNAVAILABLE')));

      await expectLater(
          gateway.create(saved, isCurrent: () => true),
          throwsA(isA<ApiFailure>()
              .having(
                  (failure) => failure.status, 'repeated creation status', 409)
              .having((failure) => failure.code, 'repeated creation code',
                  'ENROLLMENT_REQUEST_ALREADY_USED')));
      final conflict =
          network.responses.singleWhere((response) => response.status == 409);
      expect(conflict.keys, isNot(contains('token')));
      expect(
          network.requests
              .where((request) => request.method == 'POST')
              .map((request) => request.creationId),
          [originalId, originalId]);
      await recovered.check();
      expect(recovered.progress!.state, 'PENDING_CLAIM');
      expect(recovered.ticket, isNull);
      expect(network.requests.where((request) => request.method == 'POST'),
          hasLength(2));
      await recovered.cancel();
      expect(recovered.error, isNull);
      expect(recovered.progress!.state, 'CANCELLED');
      expect(network.requests.where((request) => request.method == 'DELETE'),
          hasLength(1));
      expect(network.requests.where((request) => request.method == 'POST'),
          hasLength(2));
      expect((await journal.read(scope))!.requestId, originalId);
      await recovered.startAgain();
      expect(await journal.read(scope), isNull);
      recovered.dispose();
      controllers.remove(recovered);

      await journal.write(EnrollmentIntent(
          scope: scope,
          requestId: fixture['claimedId'],
          subjectId: fixture['subjectId'],
          platform: 'ANDROID',
          createdAt: fixture['createdAt']));
      final failedConfirmation = controller();
      controllers.add(failedConfirmation);
      await failedConfirmation.initialize();
      expect(failedConfirmation.progress!.state, 'AWAITING_CONFIRMATION');
      expect(failedConfirmation.progress!.deviceId, fixture['deviceId']);
      expect(failedConfirmation.progress!.pairingFailures, 0);
      expect(failedConfirmation.canConfirm, isTrue);
      await failedConfirmation.confirm('00000000');
      expect(
          failedConfirmation.error,
          isA<ApiFailure>()
              .having((failure) => failure.status, 'wrong-code status', 403)
              .having((failure) => failure.code, 'wrong-code fact',
                  'PAIRING_VERIFICATION_FAILED'));
      expect(failedConfirmation.progress!.state, 'AWAITING_CONFIRMATION');
      expect(failedConfirmation.progress!.pairingFailures, 1);
      expect(failedConfirmation.ticket, isNull);
      await failedConfirmation.check();
      expect(failedConfirmation.progress!.pairingFailures, 1);
      expect(
          network.requests
              .where((request) => request.path.endsWith('/confirm')),
          hasLength(1));
    } finally {
      for (final controller in controllers) {
        controller.dispose();
      }
      transport.close();
      otherTransport.close();
    }
  });
}
