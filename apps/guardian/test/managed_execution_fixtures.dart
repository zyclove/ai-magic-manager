import 'dart:convert';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_execution.dart';
import 'package:guardian/core/managed_execution_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const executionTenant = '11111111-1111-4111-8111-111111111111';
const executionDevice = '22222222-2222-4222-8222-222222222222';
const executionRegistration = '33333333-3333-4333-8333-333333333333';
const executionId = '44444444-4444-4444-8444-444444444444';
const executionPublication = '55555555-5555-4555-8555-555555555555';
const executionOther = '66666666-6666-4666-8666-666666666666';

/// In-memory HTTP boundary; no provider qualification or device execution is simulated as proof.
class ExecutionFixture {
  bool current = true;
  final requests = <http.Request>[];
  Future<http.Response> Function(http.Request)? handler;
  late final client = MockClient((request) async {
    requests.add(request);
    if (handler != null) return handler!(request);
    if (request.method == 'POST') {
      return response(record(
          state: 'CANCELLED',
          reason: 'CANCELLED_BEFORE_ASSIGNMENT',
          revision: 2,
          cancelled: true));
    }
    if (request.url.path.endsWith('/events')) {
      return response({
        'items': [event()],
        'nextCursor': null
      });
    }
    if (request.url.path.endsWith('/$executionId')) return response(record());
    return response({
      'items': [record()],
      'nextCursor': null
    });
  });
  late final api =
      Api(() async => client, baseUrl: 'http://execution.invalid/api/v1');
  ManagedExecutionRepository repository({bool writable = true}) =>
      ManagedExecutionRepository(
          api: api,
          tenantId: executionTenant,
          deviceId: executionDevice,
          registrationId: executionRegistration,
          writable: writable,
          current: () => current);
  Json record(
          {String id = executionId,
          String state = 'READY_TO_WRITE',
          String reason = 'QUEUED',
          int revision = 1,
          int createdAt = 100,
          int updatedAt = 100,
          bool cancelled = false,
          String registration = executionRegistration}) =>
      {
        'id': id,
        'publicationId': executionPublication,
        'deviceId': executionDevice,
        'registrationId': registration,
        'state': state,
        'reason': reason,
        'revision': revision,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'cancellationRequested': cancelled,
      };
  Json event(
          {int revision = 1,
          String state = 'READY_TO_WRITE',
          String reason = 'QUEUED'}) =>
      {
        'revision': revision,
        'state': state,
        'reason': reason,
        'occurredAt': 100,
      };
  ManagedExecution selected() =>
      ManagedExecution.parse(record(), deviceId: executionDevice);
  http.Response response(Object? data, {int status = 200}) =>
      http.Response(jsonEncode(data), status,
          headers: {'content-type': 'application/json; charset=utf-8'});
}
