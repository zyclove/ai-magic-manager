import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_execution.dart';
import 'package:guardian/core/managed_execution_review.dart';
import 'package:guardian/core/managed_execution_review_repository.dart';
import 'package:http/http.dart' as http;

import 'managed_execution_fixtures.dart';

const reviewOperationId = '77777777-7777-4777-8777-777777777777';
const reviewApiBase = 'http://execution.invalid/api/v1';
const reviewIssuer = 'http://identity.invalid/realms/manager';
const reviewDenials = <String>[
  'ADMINISTRATOR_REQUIRED',
  'EXECUTION_RECHECK_REQUIRES_REVIEW',
  'EXECUTION_RECHECK_CANCELLED',
  'EXECUTION_RECHECK_REQUIRES_POLICY_RECEIPT',
  'EXECUTION_RECHECK_UNAVAILABLE',
  'EXECUTION_CONTEXT_CHANGED',
  'EXECUTION_RECHECK_LEASE_ACTIVE',
  'EXECUTION_RECHECK_WINDOW_CLOSED',
  'EXECUTION_VERSION_EXHAUSTED',
];

ExecutionOperationOwner reviewOwner({String apiBase = reviewApiBase}) =>
    ExecutionOperationOwner(
        actorId: 'reviewer-a',
        tenantId: executionTenant,
        apiBaseUrl: apiBase,
        issuer: reviewIssuer);

Json reviewTaskRaw({
  int revision = 8,
  String state = 'NEEDS_REVIEW',
  String reason = 'ATTEMPTS_EXHAUSTED',
  bool cancelled = false,
  String registration = executionRegistration,
}) =>
    ExecutionFixture().record(
        state: state,
        reason: reason,
        revision: revision,
        updatedAt: 200 + revision,
        cancelled: cancelled,
        registration: registration);

ManagedExecution reviewTask() =>
    ManagedExecution.parse(reviewTaskRaw(), deviceId: executionDevice);

Json eligibilityRaw({
  ManagedExecution? selected,
  bool allowed = true,
  String reason = 'ELIGIBLE',
}) {
  final task = selected ?? reviewTask();
  return <String, dynamic>{
    'id': task.id,
    'publicationId': task.publicationId,
    'deviceId': task.deviceId,
    'registrationId': task.registrationId,
    'revision': task.revision,
    'allowed': allowed,
    'reason': reason,
  };
}

ExecutionOperationPending reviewAttempt({
  ExecutionOperationOwner? owner,
  ManagedExecution? task,
}) =>
    ExecutionOperationPending(
        intent: ExecutionOperationIntent(
            owner: owner ?? reviewOwner(),
            task: task ?? reviewTask(),
            kind: ExecutionOperationKind.recheckDevice,
            operationId: reviewOperationId,
            createdAt: 1000));

Matcher executionFailure(String code) =>
    isA<ApiFailure>().having((failure) => failure.code, 'code', code);

/// A local HTTP boundary, not a product implementation or provider simulator.
/// Record entry before finalize so scope tests cannot mistake finalize rejection
/// for rejection before physical transport.
class ReviewTransport extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  final bodies = <List<int>>[];
  final entered = Completer<void>();
  Future<http.StreamedResponse> Function(http.BaseRequest)? handler;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (!entered.isCompleted) entered.complete();
    bodies.add(await request.finalize().toBytes());
    final callback = handler;
    if (callback == null) {
      throw StateError('Each contract case must declare its HTTP response.');
    }
    return callback(request);
  }

  @override
  void close() => closed = true;
}

http.StreamedResponse reviewResponse(
  Object? data, {
  int status = 200,
  String mime = 'application/json; charset=utf-8',
  bool declaredLength = true,
  int? lengthOverride,
}) {
  final bytes = utf8.encode(jsonEncode(data));
  return http.StreamedResponse(Stream<List<int>>.value(bytes), status,
      contentLength: lengthOverride ?? (declaredLength ? bytes.length : null),
      headers: {'content-type': mime});
}

class ReviewCall<T> {
  T? value;
  Object? error;
  late final Future<void> completed;

  ReviewCall(Future<T> operation) {
    completed = operation.then<void>((result) {
      value = result;
    }, onError: (Object failure, StackTrace _) {
      error = failure;
    });
  }
}

Future<void> requirePhase(
    Completer<void> signal, ReviewCall<dynamic> call) async {
  await Future.any<void>([signal.future, call.completed]);
  expect(signal.isCompleted, isTrue,
      reason: 'The requested real boundary was not reached. An absent API or '
          'placeholder error is not evidence for this scenario.');
}

class ReviewHttpFixture {
  final transport = ReviewTransport();
  bool current = true;
  late final api = Api(() async => transport, baseUrl: reviewApiBase);
  late final repository = ManagedExecutionReviewRepository(
      api: api,
      owner: reviewOwner(),
      deviceId: executionDevice,
      registrationId: executionRegistration,
      writable: true,
      current: () => current);
}
