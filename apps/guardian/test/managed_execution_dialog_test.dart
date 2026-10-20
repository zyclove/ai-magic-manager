import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_execution.dart';
import 'package:guardian/core/managed_execution_review.dart';
import 'package:guardian/core/managed_execution_review_repository.dart';
import 'package:guardian/ui/managed_execution_review_controller.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/managed_execution_controller.dart';
import 'package:guardian/ui/managed_execution_dialog.dart';
import 'package:http/http.dart' as http;

import 'managed_execution_fixtures.dart';
import 'managed_execution_review_widget_fixtures.dart';

const _deviceName = '学习平板';

/// Exercise the real dialog, controller and repository; only HTTP is in memory.
class _DialogFixture {
  _DialogFixture({this.writable = true, this.deviceName = _deviceName}) {
    data.handler = (request) async => request.method == 'POST'
        ? data.response(data.record(state: 'CANCELLED', reason: 'CANCELLED_BEFORE_ASSIGNMENT', revision: 2, cancelled: true))
        : _readResponse(data, request);
  }

  final bool writable;
  final String deviceName;
  final data = ExecutionFixture();
  final accessChanges = ValueNotifier<int>(0);
  late final controller = ManagedExecutionController(
    repository: data.repository(writable: writable),
    registrationId: executionRegistration,
  );
  final journal = ReviewMemoryJournal();
  ManagedExecutionReviewController? operation;
  int sequence = 0;
  ManagedExecutionReviewController makeReview(ManagedExecution task,
      bool Function() current, int Function() latestEventRevision) {
    return operation = ManagedExecutionReviewController(
      requests: ManagedExecutionReviewRepository(api: data.api,
        owner: ExecutionOperationOwner(actorId: 'legacy-purpose-current-controller',
          tenantId: executionTenant, apiBaseUrl: data.api.baseUrl,
          issuer: 'https://identity.invalid/realms/test'),
        deviceId: executionDevice, registrationId: executionRegistration,
        writable: writable, current: () => data.current), journal: journal,
      selected: task, viewCurrent: current, latestEventRevision: latestEventRevision,
      operationId: () => 'aaaaaaaa-aaaa-4aaa-8aaa-${(++sequence).toRadixString(16).padLeft(12, '0')}',
      now: () => 100, onProgress: (_) {});
  }
  int closeCalls = 0;
  int reauthCalls = 0;

  List<http.Request> get writes =>
      data.requests.where((request) => request.method == 'POST').toList();

  Widget host({double scale = 1}) => MaterialApp(
        theme: consoleTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: ManagedExecutionDialog(
            controller: controller,
            reviewFactory: writable ? makeReview : null,
            deviceName: deviceName,
            onClose: () => closeCalls++,
            accessChanges: accessChanges,
            onReauth: () => reauthCalls++,
          ),
        ),
      );
}

Future<void> _mount(WidgetTester tester, _DialogFixture f,
    {double scale = 1, bool settle = true}) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    f.controller.dispose();
    f.accessChanges.dispose();
    f.data.client.close();
  });
  await tester.pumpWidget(f.host(scale: scale));
  if (settle) await _settleExecutionReads(tester);
}

// The real bounded response stream completes on the native event queue.
// Flush it before pumpAndSettle advances the fake clock toward its timeout.
Future<void> _settleExecutionReads(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
}

Future<void> _press(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await _settleExecutionReads(tester);
}

Future<void> _open(WidgetTester tester) async {
  await _press(tester, 'execution-open-$executionId');
  // Timeline is now an explicit read, preserving the original coverage purpose.
  await _press(tester, 'execution-refresh-timeline');
}

http.Response _readResponse(ExecutionFixture f, http.Request request,
    {Json? task, Json? event}) {
  if (request.method != 'GET') {
    throw StateError('This response fixture only accepts reads.');
  }
  if (request.url.path.endsWith('/review-eligibility')) {
    final selected = task ?? f.record();
    return f.response({
      for (final key in ['id', 'publicationId', 'deviceId', 'registrationId', 'revision']) key: selected[key],
      'allowed': false, 'reason': 'EXECUTION_RECHECK_REQUIRES_REVIEW',
    });
  }
  if (request.url.path.endsWith('/events')) {
    return f.response({
      'items': [event ?? f.event()],
      'nextCursor': null,
    });
  }
  if (request.url.path.endsWith('/$executionId')) {
    return f.response(task ?? f.record());
  }
  return f.response({
    'items': [task ?? f.record()],
    'nextCursor': null,
  });
}

void _serveAcceptedCancellation(_DialogFixture f) {
  var cancelled = false;
  f.data.handler = (request) async {
    if (request.method == 'POST') cancelled = true;
    final state = cancelled ? 'CANCELLED' : 'READY_TO_WRITE';
    final reason = cancelled ? 'CANCELLED_BEFORE_ASSIGNMENT' : 'QUEUED';
    final revision = cancelled ? 2 : 1;
    final task = f.data.record(
      state: state,
      reason: reason,
      revision: revision,
      cancelled: cancelled,
    );
    if (request.method == 'POST') return f.data.response(task);
    return _readResponse(f.data, request,
        task: task,
        event: f.data.event(state: state, reason: reason, revision: revision));
  };
}

void main() {
  testWidgets('initial load exposes progress before showing the device records',
      (tester) async {
    final f = _DialogFixture();
    final waiting = Completer<http.Response>();
    f.data.handler = (_) => waiting.future;
    addTearDown(() {
      if (!waiting.isCompleted) {
        waiting.complete(f.data.response({'items': [], 'nextCursor': null}));
      }
    });

    await _mount(tester, f, settle: false);
    await tester.pump();
    expect(find.byWidgetPredicate((widget) => widget is ProgressIndicator),
        findsWidgets);
    expect(find.byKey(const Key('execution-open-$executionId')), findsNothing);
    expect(f.data.requests.length, 1);
    expect(f.data.requests.single.method, 'GET');
    expect(f.data.requests.single.url.queryParameters['deviceId'],
        executionDevice);

    waiting.complete(f.data.response({
      'items': [f.data.record()],
      'nextCursor': null,
    }));
    await _settleExecutionReads(tester);
    expect(find.text('执行记录'), findsOneWidget);
    expect(find.textContaining(_deviceName), findsWidgets);
    expect(
        find.byKey(const Key('execution-open-$executionId')), findsOneWidget);
    expect(f.writes, isEmpty);
  });

  testWidgets('empty records expose no detail or cancellation action',
      (tester) async {
    final f = _DialogFixture();
    f.data.handler =
        (_) async => f.data.response({'items': [], 'nextCursor': null});

    await _mount(tester, f);

    expect(find.textContaining('暂无执行记录'), findsWidgets);
    expect(find.byKey(const Key('execution-open-$executionId')), findsNothing);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
    expect(f.writes, isEmpty);
  });

  testWidgets('list failure offers a read retry that restores records',
      (tester) async {
    final f = _DialogFixture();
    var reads = 0;
    f.data.handler = (request) async {
      reads++;
      if (reads == 1) {
        return f.data.response({'errorCode': 'REQUEST_FAILED'}, status: 503);
      }
      return _readResponse(f.data, request);
    };

    await _mount(tester, f);
    expect(find.byKey(const Key('execution-open-$executionId')), findsNothing);
    await _press(tester, 'execution-refresh-list');

    expect(
        find.byKey(const Key('execution-open-$executionId')), findsOneWidget);
    expect(f.data.requests.length, 2);
    expect(f.data.requests.every((request) => request.method == 'GET'), isTrue);
    expect(f.data.requests.last.url.queryParameters.containsKey('cursor'),
        isFalse);
  });

  testWidgets('opening a record reads its detail and timeline before returning',
      (tester) async {
    final f = _DialogFixture();
    await _mount(tester, f);

    await _open(tester);

    expect(find.byKey(const Key('execution-back')), findsOneWidget);
    expect(find.byKey(const Key('execution-cancel')), findsOneWidget);
    expect(
        f.data.requests.any((request) =>
            request.method == 'GET' &&
            request.url.path.endsWith('/$executionId')),
        isTrue);
    expect(
        f.data.requests.any((request) =>
            request.method == 'GET' &&
            request.url.path.endsWith('/$executionId/events')),
        isTrue);
    expect(f.controller.events.single.revision, 1);

    await _press(tester, 'execution-back');

    expect(
        find.byKey(const Key('execution-open-$executionId')), findsOneWidget);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
    expect(f.closeCalls, 0);
    expect(f.writes, isEmpty);
  });

  testWidgets('state filter sends the selected state without an old cursor',
      (tester) async {
    final f = _DialogFixture();
    f.data.handler = (_) async => f.data.response({
          'items': [f.data.record()],
          'nextCursor': executionId,
        });
    await _mount(tester, f);
    expect(find.byKey(const Key('execution-more')), findsOneWidget);
    f.data.handler =
        (_) async => f.data.response({'items': [], 'nextCursor': null});
    final filter = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const Key('execution-filter')));

    filter.onChanged!('APPLIED');
    await _settleExecutionReads(tester);

    expect(f.data.requests.last.url.queryParameters['state'], 'APPLIED');
    expect(f.data.requests.last.url.queryParameters.containsKey('cursor'),
        isFalse);
    expect(find.byKey(const Key('execution-open-$executionId')), findsNothing);
    expect(f.writes, isEmpty);
  });

  testWidgets('declining cancellation keeps the record open without a write',
      (tester) async {
    final f = _DialogFixture();
    await _mount(tester, f);
    await _open(tester);

    await _press(tester, 'execution-cancel');
    expect(find.byKey(const Key('execution-confirm-cancel')), findsOneWidget);
    await _press(tester, 'execution-dismiss-cancel');

    expect(find.byKey(const Key('execution-confirm-cancel')), findsNothing);
    expect(find.byKey(const Key('execution-cancel')), findsOneWidget);
    expect(f.writes, isEmpty);
    expect(f.closeCalls, 0);
  });

  testWidgets('confirmed cancellation sends the selected version only once',
      (tester) async {
    final f = _DialogFixture();
    _serveAcceptedCancellation(f);
    await _mount(tester, f);
    await _open(tester);

    await _press(tester, 'execution-cancel');
    await _press(tester, 'execution-confirm-cancel');

    expect(f.writes.length, 1);
    expect(f.writes.single.url.path.endsWith('/$executionId/cancel'), isTrue);
    expect(f.writes.single.headers['If-Match'], '"1"');
    expect(f.operation?.selected?.state, 'CANCELLED');
    expect(f.journal.record, isNull);
    expect(f.journal.receipts, 1);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
    expect(find.byKey(const Key('execution-check-result')), findsNothing);
    expect(find.byKey(const Key('execution-back')), findsOneWidget);
    expect(f.closeCalls, 0);
  });

  testWidgets(
      'queued confirmation callbacks cannot submit a second cancellation',
      (tester) async {
    final f = _DialogFixture();
    _serveAcceptedCancellation(f);
    await _mount(tester, f);
    await _open(tester);
    await _press(tester, 'execution-cancel');
    final confirm = tester
        .widget<FilledButton>(find.byKey(const Key('execution-confirm-cancel')))
        .onPressed!;

    confirm();
    confirm();
    await _settleExecutionReads(tester);

    expect(f.writes.length, 1);
    expect(find.byType(ManagedExecutionDialog), findsOneWidget);
    expect(find.byKey(const Key('execution-back')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'unknown cancellation offers only read checks even after old READY',
      (tester) async {
    final f = _DialogFixture();
    f.data.handler = (request) async {
      if (request.method == 'POST') {
        throw http.ClientException('simulated interruption after dispatch');
      }
      return _readResponse(f.data, request);
    };
    await _mount(tester, f);
    await _open(tester);
    await _press(tester, 'execution-cancel');
    await _press(tester, 'execution-confirm-cancel');

    expect(find.textContaining('暂不能确认是否已受理'), findsWidgets);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
    expect(find.byKey(const Key('execution-check-result')), findsOneWidget);
    final beforeCheck = f.data.requests.length;

    await _press(tester, 'execution-check-result');

    expect(f.data.requests.length, greaterThan(beforeCheck));
    expect(
        f.data.requests
            .skip(beforeCheck)
            .every((request) => request.method == 'GET'),
        isTrue);
    expect(f.writes.length, 1);
    expect(f.controller.selected?.state, 'READY_TO_WRITE');
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
    expect(find.byKey(const Key('execution-check-result')), findsOneWidget);
  });

  testWidgets(
      'read-only access retains detail and timeline without cancellation',
      (tester) async {
    final f = _DialogFixture(writable: false);
    await _mount(tester, f);

    await _open(tester);

    expect(find.byKey(const Key('execution-back')), findsOneWidget);
    expect(f.controller.events.single.revision, 1);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
    expect(find.byKey(const Key('execution-confirm-cancel')), findsNothing);
    expect(f.writes, isEmpty);
  });

  testWidgets(
      'historical registration remains readable with cancellation hidden',
      (tester) async {
    final f = _DialogFixture();
    f.data.handler = (request) async => _readResponse(f.data, request,
        task: f.data.record(registration: executionOther));
    await _mount(tester, f);

    await _open(tester);

    expect(find.textContaining('历史注册记录'), findsWidgets);
    expect(find.byKey(const Key('execution-back')), findsOneWidget);
    expect(f.controller.events.single.revision, 1);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
    expect(f.writes, isEmpty);
  });

  testWidgets(
      'scope loss conceals an open confirmation and rejects queued acceptance',
      (tester) async {
    final f = _DialogFixture();
    await _mount(tester, f);
    await _open(tester);
    await _press(tester, 'execution-cancel');
    final confirm = tester
        .widget<FilledButton>(find.byKey(const Key('execution-confirm-cancel')))
        .onPressed!;

    f.data.current = false;
    f.accessChanges.value++;
    await _settleExecutionReads(tester);

    expect(find.textContaining(_deviceName), findsNothing);
    expect(find.byKey(const Key('execution-confirm-cancel')), findsNothing);
    expect(find.byKey(const Key('execution-cancel')), findsNothing);
    expect(find.byKey(const Key('execution-open-$executionId')), findsNothing);
    expect(f.controller.selected, isNull);

    confirm();
    await _settleExecutionReads(tester);
    expect(f.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recent authentication is requested only by the user action',
      (tester) async {
    final f = _DialogFixture();
    f.data.handler = (request) async => request.method == 'POST'
        ? f.data.response({'errorCode': 'REAUTH_REQUIRED'}, status: 401)
        : _readResponse(f.data, request);
    await _mount(tester, f);
    await _open(tester);
    await _press(tester, 'execution-cancel');
    await _press(tester, 'execution-confirm-cancel');

    expect(f.reauthCalls, 0);
    expect(find.byKey(const Key('execution-confirm-cancel')), findsNothing);
    expect(find.byKey(const Key('execution-reauth')), findsOneWidget);
    expect(f.writes.length, 1);

    await _press(tester, 'execution-reauth');

    expect(f.reauthCalls, 1);
    expect(f.writes.length, 1);
    expect(find.byKey(const Key('execution-confirm-cancel')), findsNothing);
  });

  testWidgets('close delegates to the host without submitting a cancellation',
      (tester) async {
    final f = _DialogFixture();
    await _mount(tester, f);

    await _press(tester, 'execution-close');

    expect(f.closeCalls, 1);
    expect(f.writes, isEmpty);
  });

  testWidgets(
      'keyboard inset keeps narrow enlarged content and close reachable',
      (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final f = _DialogFixture();
    await _mount(tester, f, scale: 2);
    tester.view.viewInsets = const FakeViewPadding(bottom: 420);
    await _settleExecutionReads(tester);
    expect(
        find.byKey(const Key('execution-close')).hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(find.byKey(const Key('execution-close'))).dy,
        lessThan(340));

    await _open(tester);
    await _press(tester, 'execution-cancel');
    expect(find.byTooltip('关闭取消确认').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('关闭取消确认'));
    await _settleExecutionReads(tester);
    await _press(tester, 'execution-close');

    expect(f.closeCalls, 1);
    expect(f.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '320 wide doubled text keeps detail confirmation and close reachable',
      (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final f = _DialogFixture(deviceName: '学习平板' * 25);
    await _mount(tester, f, scale: 2);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.byKey(const Key('execution-filter')));
    await _open(tester);
    expect(tester.takeException(), isNull);
    await _press(tester, 'execution-cancel');
    expect(tester.takeException(), isNull);
    await tester
        .ensureVisible(find.byKey(const Key('execution-confirm-cancel')));
    await _press(tester, 'execution-dismiss-cancel');
    await _press(tester, 'execution-back');
    await _press(tester, 'execution-close');

    expect(f.closeCalls, 1);
    expect(f.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
