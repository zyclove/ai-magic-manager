@TestOn('browser')
library;

// DRAFT ONLY: copy beside the existing Guardian test helpers in a new frozen
// source tree. No new product type/skeleton is needed for this initial RED.
// This file has not been formatted, compiled, or run.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart' hide Flow;
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/policy_preview_results.dart';
import 'package:http/http.dart' as http;

import 'policy_preview_flow_test.dart'
    show PreviewSession, Flow, startFlow, selectGroup, previewFor;
import 'policy_target_picker_test.dart' show reply;

class _RecoverySession extends PreviewSession {
  _RecoverySession() : super(groups: true);

  void awayAndBack() {
    role = 'AUDITOR';
    notifyListeners();
    role = 'OWNER';
    notifyListeners();
  }
}

class _RecoveryFixture {
  final session = _RecoverySession();
  final lookups = <http.Request>[];
  Future<http.Response> Function(http.Request)? publish;
  Future<http.Response> Function(http.Request)? lookup;

  _RecoveryFixture() {
    // Keep the shared fixture unchanged; this recovery fixture obeys the real
    // GET contract requiring a canonical UUID previewId.
    session.respond = (request) async => reply({
          ...previewFor(request),
          'id': '11111111-1111-4111-8111-111111111111',
        });
    session.intercept = (request) async {
      if (request.method == 'POST' &&
          request.url.path.endsWith('/publications')) {
        // The interceptor consumes this request before PreviewSession's
        // ordinary POST recorder, so record it exactly once here.
        session.publications.add(request);
        final handler = publish;
        if (handler == null) throw StateError('Unexpected publication POST');
        return handler(request);
      }
      if (request.method == 'GET' &&
          request.url.path.contains('/publication-results/')) {
        lookups.add(request);
        final handler = lookup;
        if (handler == null) throw StateError('Unexpected result lookup');
        return handler(request);
      }
      return null;
    };
  }

  List<http.Request> get posts => session.publications;
}

Json _publication({
  String mode = 'CONFIGURE_ONLY',
  String state = 'CONFIGURED_NOT_ENFORCED',
}) =>
    {
      'id': '22222222-2222-4222-8222-222222222222',
      'versionId': '33333333-3333-4333-8333-333333333333',
      'sequence': 1,
      'mode': mode,
      'state': state,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    };

// Avoid pumpAndSettle while a real in-flight operation shows an indeterminate
// progress animation. These bounded frames neither sleep ten minutes nor
// advance the preview to expiry.
Future<void> _frames(WidgetTester tester, [int count = 12]) async {
  for (var i = 0; i < count; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _unmount(WidgetTester tester, {VoidCallback? afterUnmount}) async {
  // Execute inside each test body's finally, before Flutter's timer invariant.
  // Never await an unresolved route/Flow completion during late teardown.
  await tester.pumpWidget(const SizedBox.shrink());
  afterUnmount?.call();
  await _frames(tester, 4);
}

Future<Flow> _open(WidgetTester tester, _RecoveryFixture fixture) async {
  final flow = await startFlow(tester, fixture.session);
  await selectGroup(tester);
  await tester.tap(find.text('预览这些设备'));
  await _frames(tester);
  expect(find.text('发布前预览'), findsOneWidget);
  expect(find.byType(PolicyPreviewResults), findsOneWidget);
  expect(fixture.posts, isEmpty);
  expect(fixture.lookups, isEmpty);
  return flow;
}

Future<void> _submit(WidgetTester tester, _RecoveryFixture fixture) async {
  await tester.tap(find.text('仅保存配置'));
  await _frames(tester);
  await tester.tap(find.widgetWithText(FilledButton, '发布配置'));
  // Confirm completion includes the owned route's reverse animation and the
  // subsequent physical HTTP turn. Bounded frames cover both.
  await _frames(tester);
  expect(fixture.posts, hasLength(1));
  expect(fixture.lookups, isEmpty,
      reason: 'An unknown write must not start an automatic lookup or POST.');
}

Finder _query() => find.ancestor(
    of: find.text('查询发布结果'),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

VoidCallback _queryCallback(WidgetTester tester) {
  expect(_query(), findsOneWidget);
  final callback = tester.widget<ButtonStyleButton>(_query()).onPressed;
  expect(callback, isNotNull);
  return callback!;
}

void _expectExactLookup(_RecoveryFixture fixture, http.Request request,
    {required String body, required String key, required String version}) {
  final posted = jsonDecode(body) as Json;
  expect(request.method, 'GET');
  expect(request.url.path,
      '/api/v1/tenants/tenant-a/policies/policy-a/publication-results/$key');
  expect(request.url.queryParameters, {
    'mode': 'CONFIGURE_ONLY',
    'revision': version.replaceAll('"', ''),
    'previewId': posted['previewId'],
    'previewHash': posted['previewHash'],
  });
  expect(request.body, isEmpty);
  expect(fixture.posts, hasLength(1));
  expect(fixture.posts.single.body, body);
  expect(fixture.posts.single.headers['idempotency-key'], key);
  expect(fixture.posts.single.headers['if-match'], version);
  expect(fixture.session.previews, hasLength(1),
      reason: 'Recovery must not mint another preview or extend its deadline.');
}

void main() {
  testWidgets('201 empty publication is unknown, never an empty success sheet',
      (tester) async {
    final fixture = _RecoveryFixture()
      ..publish = (_) async => reply(<String, dynamic>{}, 201);
    try {
      final flow = await _open(tester, fixture);
      await _submit(tester, fixture);
      // First failure on old production is the real empty "发布结果" dialog,
      // not a missing future class or a generic fixture exception.
      expect(find.text('发布结果'), findsNothing);
      expect(flow.completed, isFalse);
      _queryCallback(tester);
      expect(fixture.lookups, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester);
    }
  });

  testWidgets(
      'network unknown uses one explicit GET for the exact original intent',
      (tester) async {
    final fixture = _RecoveryFixture();
    fixture.publish = (_) async {
      throw http.ClientException('synthetic disconnect');
    };
    fixture.lookup = (_) async => reply(_publication());
    try {
      final flow = await _open(tester, fixture);
      await _submit(tester, fixture);
      final original = fixture.posts.single;
      final body = original.body;
      final key = original.headers['idempotency-key']!;
      final version = original.headers['if-match']!;
      // Do not assert UUID here: isolate missing explicit recovery behavior.
      final query = _queryCallback(tester);
      query();
      await _frames(tester);
      expect(fixture.lookups, hasLength(1));
      _expectExactLookup(fixture, fixture.lookups.single,
          body: body, key: key, version: version);
      expect(find.text('配置已保存 · 未执行'), findsOneWidget);
      expect(flow.failure, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester);
    }
  });

  testWidgets(
      '503 then 404 remains unknown; repeated checks never replay or rekey',
      (tester) async {
    final fixture = _RecoveryFixture();
    fixture.publish =
        (_) async => reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503);
    fixture.lookup = (_) async =>
        reply({'errorCode': 'POLICY_PUBLICATION_RESULT_UNAVAILABLE'}, 404);
    try {
      final flow = await _open(tester, fixture);
      await _submit(tester, fixture);
      final original = fixture.posts.single;
      final body = original.body;
      final key = original.headers['idempotency-key']!;
      final version = original.headers['if-match']!;
      _queryCallback(tester)();
      await _frames(tester);
      expect(fixture.lookups, hasLength(1));
      expect(find.text('发布结果'), findsNothing);
      expect(flow.completed, isFalse);
      _queryCallback(tester)();
      await _frames(tester);
      expect(fixture.lookups, hasLength(2));
      for (final lookup in fixture.lookups) {
        _expectExactLookup(fixture, lookup,
            body: body, key: key, version: version);
      }
      expect(find.text('发布结果'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester);
    }
  });

  testWidgets(
      'lookup cannot accept an ENFORCE receipt for a CONFIGURE_ONLY intent',
      (tester) async {
    final fixture = _RecoveryFixture();
    fixture.publish =
        (_) async => reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503);
    fixture.lookup = (_) async =>
        reply(_publication(mode: 'ENFORCE', state: 'PENDING_EXECUTION'));
    try {
      final flow = await _open(tester, fixture);
      await _submit(tester, fixture);
      _queryCallback(tester)();
      await _frames(tester);
      expect(fixture.lookups, hasLength(1));
      expect(fixture.posts, hasLength(1));
      expect(find.text('发布结果'), findsNothing);
      expect(flow.completed, isFalse);
      _queryCallback(tester);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester);
    }
  });

  testWidgets(
      'late lookup and captured callbacks cannot escape revoked or covered scope',
      (tester) async {
    final pending = Completer<http.Response>();
    final fixture = _RecoveryFixture();
    fixture.publish =
        (_) async => reply({'errorCode': 'SERVICE_UNAVAILABLE'}, 503);
    fixture.lookup = (_) => pending.future;
    try {
      final flow = await _open(tester, fixture);
      await _submit(tester, fixture);
      final query = _queryCallback(tester);
      query();
      await _frames(tester);
      expect(fixture.lookups, hasLength(1));
      // A callback already queued while busy must not create a second GET.
      query();
      await _frames(tester, 2);
      expect(fixture.lookups, hasLength(1));
      final context = flow.context;
      unawaited(showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('独立通知'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭独立通知')),
                ],
              )));
      await _frames(tester);
      fixture.session.awayAndBack();
      pending.complete(reply(_publication()));
      await _frames(tester);
      expect(find.text('独立通知'), findsOneWidget);
      expect(find.text('发布结果'), findsNothing);
      expect(find.byType(PolicyPreviewResults), findsNothing);
      expect(fixture.posts, hasLength(1));
      expect(fixture.lookups, hasLength(1));
      await tester.tap(find.text('关闭独立通知'));
      await _frames(tester);
      query();
      await _frames(tester);
      expect(fixture.lookups, hasLength(1),
          reason:
              'Away-and-back must not restore a captured recovery callback.');
      expect(fixture.posts, hasLength(1));
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester, afterUnmount: () {
        if (!pending.isCompleted) pending.complete(reply(_publication()));
      });
    }
  });

  testWidgets(
      'the initial publication key is a frozen canonical UUID for recovery',
      (tester) async {
    final fixture = _RecoveryFixture()
      ..publish = (_) async => reply(_publication(), 201);
    try {
      await _open(tester, fixture);
      await _submit(tester, fixture);
      final posted = fixture.posts.single;
      expect(
          posted.headers['idempotency-key'],
          matches(RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(posted.headers['if-match'], '"7"');
      expect(jsonDecode(posted.body), {
        'previewId': '11111111-1111-4111-8111-111111111111',
        'previewHash': 'a' * 64,
        'mode': 'CONFIGURE_ONLY',
      });
      expect(fixture.session.previews, hasLength(1));
      expect(fixture.lookups, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester);
    }
  });
}
