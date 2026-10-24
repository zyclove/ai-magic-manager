@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/managed_android_review_page.dart';
import 'package:guardian/ui/design.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const firstTenant = '11111111-1111-4111-8111-111111111111';
const secondTenant = '22222222-2222-4222-8222-222222222222';
const reviewRoot = '/api/v1/platform/managed-android/enterprise-bindings';

Json reviewRow(String tenant,
        {String enterprise = 'enterprise_one',
        String state = 'PENDING',
        int version = 1}) =>
    {
      'tenantId': tenant,
      'provider': 'LOCAL_EMM',
      'enterpriseId': enterprise,
      'contractReference': 'CN-001',
      'state': state,
      'version': version,
      'requestedBy': 'independent-applicant',
      'createdAt': 1000,
      'updatedAt': 2000,
      if (state != 'PENDING') ...{
        'approvedBy': 'reviewer-1',
        'ownershipEvidenceReference': 'evidence-001',
      },
    };
http.Response reply(Object value, {int status = 200}) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});
http.Response unavailable() =>
    reply({'errorCode': 'SERVICE_UNAVAILABLE'}, status: 503);
http.Response queue(List<Json> rows, {String? cursor}) =>
    reply({'items': rows, 'nextCursor': cursor});

class ReviewSession extends Session {
  ReviewSession() {
    profile = {'subject': 'reviewer-1', 'canReviewManagedAndroid': true};
    role = 'ORG_ADMIN';
  }
  bool signedIn = true;
  int epoch = 0;
  final requests = <http.Request>[];
  Future<http.Response> Function(http.Request)? respond;
  late final transport = MockClient((request) async {
    requests.add(request);
    final handler = respond;
    if (handler != null) return handler(request);
    return request.url.path == reviewRoot
        ? queue([])
        : reply(reviewRow(request.url.path.split('/').last));
  });
  late final testApi =
      Api(() async => transport, baseUrl: 'http://mock.invalid/api/v1');
  @override
  Api get api => testApi;
  @override
  bool get authenticated => signedIn;
  @override
  int get scopeGeneration => epoch;
  void changeScope(
      {String? nextActor,
      String? nextRole,
      bool? allowed,
      bool increment = true}) {
    if (increment) epoch++;
    if (nextActor != null) profile!['subject'] = nextActor;
    if (nextRole != null) role = nextRole;
    if (allowed != null) profile!['canReviewManagedAndroid'] = allowed;
    notifyListeners();
  }
}

Future<void> flush(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> mount(WidgetTester tester, ReviewSession session,
    {bool nestedRoute = false}) async {
  tester.view.physicalSize = const Size(1200, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    session.dispose();
  });
  final page = Scaffold(
      body: SingleChildScrollView(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: ManagedAndroidReviewPage(session: session))));
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: nestedRoute
          ? Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => page)),
                      child: const Text('进入审核'))))
          : page));
  await flush(tester);
  if (nestedRoute) {
    await tester.tap(find.text('进入审核'));
    await flush(tester);
    await flush(tester);
  }
}

Finder pendingPanel() =>
    find.ancestor(of: find.text('待审核队列'), matching: find.byType(Panel));
Finder lookupPanel() =>
    find.ancestor(of: find.text('按机构查询'), matching: find.byType(Panel));
Future<void> lookup(WidgetTester tester, String tenant) async {
  await tester.enterText(find.byType(TextField).first, tenant);
  await tester.tap(find.widgetWithText(OutlinedButton, '查询'));
  await flush(tester);
}

void completeOnTearDown(
    Completer<http.Response> value, http.Response fallback) {
  addTearDown(() {
    if (!value.isCompleted) value.complete(fallback);
  });
}

void main() {
  testWidgets('failed initial queue is unknown until a successful empty read',
      (tester) async {
    final session = ReviewSession();
    var calls = 0;
    session.respond =
        (request) async => ++calls == 1 ? unavailable() : queue([]);
    await mount(tester, session);
    expect(find.text('暂无待审核申请'), findsNothing);
    final failure = find.byType(FailureView);
    expect(failure, findsOneWidget);
    expect(
        tester.widget<Notice>(find.descendant(
            of: failure, matching: find.byType(Notice))).text,
        (const ApiFailure(503, 'SERVICE_UNAVAILABLE')).message);
    expect(find.byType(SelectableText, skipOffstage: false), findsNothing);
    final details =
        find.descendant(of: failure, matching: find.text('错误详情'));
    await tester.ensureVisible(details);
    await tester.tap(details);
    await flush(tester);
    expect(
        find.descendant(
            of: failure,
            matching: find.byWidgetPredicate((widget) =>
                widget is SelectableText &&
                widget.data == '错误代码：SERVICE_UNAVAILABLE')),
        findsOneWidget);
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await flush(tester);
    expect(find.text('暂无待审核申请'), findsOneWidget);
    expect(failure, findsNothing);
    expect(find.text('错误详情'), findsNothing);
    expect(find.byType(SelectableText, skipOffstage: false), findsNothing);
    expect(find.text('SERVICE_UNAVAILABLE'), findsNothing);
    expect(session.requests.length, 2);
    expect(
        session.requests.every((request) => request.method == 'GET'), isTrue);
  });

  testWidgets('query retry reads original UUID and preserves edited input',
      (tester) async {
    final session = ReviewSession();
    var reads = 0;
    session.respond = (request) async {
      if (request.url.path == reviewRoot) return queue([]);
      return ++reads == 1 ? unavailable() : reply(reviewRow(firstTenant));
    };
    await mount(tester, session);
    await lookup(tester, firstTenant);
    await tester.enterText(find.byType(TextField).first, secondTenant);
    await tester.tap(find.text('重试'));
    await flush(tester);
    final details = session.requests.where((r) => r.url.path != reviewRoot);
    expect(details.map((r) => r.url.path),
        ['$reviewRoot/$firstTenant', '$reviewRoot/$firstTenant']);
    expect(find.text('企业 enterprise_one'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        secondTenant);
    expect(session.requests.where((r) => r.url.path == reviewRoot).length, 1);
  });

  testWidgets('pagination retry retains prior rows and original cursor',
      (tester) async {
    final session = ReviewSession();
    var more = 0;
    session.respond = (request) async {
      if (!request.url.queryParameters.containsKey('cursor')) {
        return queue([reviewRow(firstTenant)], cursor: firstTenant);
      }
      return ++more == 1
          ? unavailable()
          : queue([reviewRow(secondTenant, enterprise: 'enterprise_two')]);
    };
    await mount(tester, session);
    await tester.tap(find.text('加载更多'));
    await flush(tester);
    expect(find.text('enterprise_one'), findsOneWidget);
    expect(find.text('暂无待审核申请'), findsNothing);
    await tester.tap(find.text('重试'));
    await flush(tester);
    expect(session.requests.skip(1).map((r) => r.url.queryParameters['cursor']),
        [firstTenant, firstTenant]);
    expect(find.text('enterprise_one'), findsOneWidget);
    expect(find.text('enterprise_two'), findsOneWidget);
  });

  testWidgets('pending and lookup errors retain their own read retries',
      (tester) async {
    final session = ReviewSession();
    session.respond = (request) async => unavailable();
    await mount(tester, session);
    await lookup(tester, firstTenant);
    expect(find.descendant(of: pendingPanel(), matching: find.text('重试')),
        findsOneWidget);
    expect(find.descendant(of: lookupPanel(), matching: find.text('重试')),
        findsOneWidget);
    expect(find.text('暂无待审核申请'), findsNothing);
    await tester
        .tap(find.descendant(of: lookupPanel(), matching: find.text('重试')));
    await flush(tester);
    expect(session.requests.map((r) => r.url.path),
        [reviewRoot, '$reviewRoot/$firstTenant', '$reviewRoot/$firstTenant']);
  });

  testWidgets('query during initial queue load does not strand loading',
      (tester) async {
    final session = ReviewSession();
    final pending = Completer<http.Response>();
    completeOnTearDown(pending, queue([]));
    session.respond = (request) async => request.url.path == reviewRoot
        ? pending.future
        : reply(reviewRow(firstTenant));
    await mount(tester, session);
    await lookup(tester, firstTenant);
    pending.complete(queue([]));
    await flush(tester);
    expect(find.text('企业 enterprise_one'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('暂无待审核申请'), findsOneWidget);
  });

  testWidgets('duplicate taps do not issue overlapping detail requests',
      (tester) async {
    final session = ReviewSession();
    final detail = Completer<http.Response>();
    completeOnTearDown(detail, reply(reviewRow(firstTenant)));
    session.respond = (request) async =>
        request.url.path == reviewRoot ? queue([]) : detail.future;
    await mount(tester, session);
    await tester.enterText(find.byType(TextField).first, firstTenant);
    await tester.tap(find.widgetWithText(OutlinedButton, '查询'));
    await tester.tap(find.widgetWithText(OutlinedButton, '查询'));
    await flush(tester);
    expect(session.requests.where((r) => r.url.path != reviewRoot).length, 1);
    detail.complete(reply(reviewRow(firstTenant)));
    await flush(tester);
  });

  testWidgets('same actor new scope drops old query and allows fresh reads',
      (tester) async {
    final session = ReviewSession();
    final oldDetail = Completer<http.Response>();
    completeOnTearDown(
        oldDetail, reply(reviewRow(firstTenant, enterprise: 'old_enterprise')));
    var calls = 0;
    session.respond = (request) async {
      if (request.url.path == reviewRoot) return queue([]);
      if (++calls == 1) return oldDetail.future;
      return reply(reviewRow(secondTenant, enterprise: 'new_enterprise'));
    };
    await mount(tester, session);
    await lookup(tester, firstTenant);
    session.changeScope();
    await flush(tester);
    oldDetail
        .complete(reply(reviewRow(firstTenant, enterprise: 'old_enterprise')));
    await flush(tester);
    expect(find.text('企业 old_enterprise'), findsNothing);
    await lookup(tester, secondTenant);
    expect(find.text('企业 new_enterprise'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('permission loss and restoration cannot revive old detail',
      (tester) async {
    final session = ReviewSession();
    final oldDetail = Completer<http.Response>();
    completeOnTearDown(oldDetail, reply(reviewRow(firstTenant)));
    session.respond = (request) async =>
        request.url.path == reviewRoot ? queue([]) : oldDetail.future;
    await mount(tester, session);
    await lookup(tester, firstTenant);
    session.changeScope(allowed: false, increment: false);
    session.changeScope(allowed: true, increment: false);
    await flush(tester);
    oldDetail.complete(reply(reviewRow(firstTenant)));
    await flush(tester);
    expect(find.text('企业 enterprise_one'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '查询'))
            .onPressed,
        isNotNull);
  });

  testWidgets('replacing session cannot deliver previous actor detail',
      (tester) async {
    final old = ReviewSession();
    final next = ReviewSession()..changeScope(nextActor: 'reviewer-2');
    final oldDetail = Completer<http.Response>();
    completeOnTearDown(oldDetail, reply(reviewRow(firstTenant)));
    old.respond = (request) async =>
        request.url.path == reviewRoot ? queue([]) : oldDetail.future;
    await mount(tester, old);
    await lookup(tester, firstTenant);
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ManagedAndroidReviewPage(session: next))))));
    addTearDown(next.dispose);
    await flush(tester);
    oldDetail.complete(reply(reviewRow(firstTenant)));
    await flush(tester);
    expect(find.text('企业 enterprise_one'), findsNothing);
    await lookup(tester, secondTenant);
    expect(next.requests.any((r) => r.url.path == '$reviewRoot/$secondTenant'),
        isTrue);
    expect(find.text('企业 enterprise_one'), findsOneWidget);
  });

  testWidgets('dispose ignores late queue and detail completion',
      (tester) async {
    final session = ReviewSession();
    final pending = Completer<http.Response>();
    final detail = Completer<http.Response>();
    completeOnTearDown(pending, queue([]));
    completeOnTearDown(detail, reply(reviewRow(firstTenant)));
    session.respond = (request) async =>
        request.url.path == reviewRoot ? pending.future : detail.future;
    await mount(tester, session);
    await lookup(tester, firstTenant);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(queue([]));
    detail.complete(reply(reviewRow(firstTenant)));
    await flush(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('approval invalidates late queue and refreshes confirmed state',
      (tester) async {
    final session = ReviewSession();
    final oldQueue = Completer<http.Response>();
    completeOnTearDown(oldQueue, queue([reviewRow(firstTenant)]));
    var listCalls = 0;
    session.respond = (request) async {
      if (request.method == 'POST') {
        return reply(reviewRow(firstTenant, state: 'ACTIVE', version: 2));
      }
      if (request.url.path == reviewRoot) {
        return ++listCalls == 1 ? oldQueue.future : queue([]);
      }
      return reply(reviewRow(firstTenant));
    };
    await mount(tester, session);
    await lookup(tester, firstTenant);
    await tester.tap(find.text('核实并批准'));
    await flush(tester);
    final fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), 'evidence-001');
    await tester.enterText(fields.at(1), '独立核对完成');
    await tester.tap(find.text('确认批准'));
    await flush(tester);
    oldQueue.complete(queue([reviewRow(firstTenant)]));
    await flush(tester);
    expect(find.text('企业已审核'), findsOneWidget);
    expect(find.text('暂无待审核申请'), findsOneWidget);
    expect(find.text('enterprise_one'), findsNothing);
    expect(session.requests.where((r) => r.method == 'POST').length, 1);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('failed write retry only rereads the same target',
      (tester) async {
    final session = ReviewSession();
    var detailCalls = 0;
    session.respond = (request) async {
      if (request.method == 'POST') return unavailable();
      if (request.url.path == reviewRoot) return queue([]);
      detailCalls++;
      return reply(reviewRow(firstTenant));
    };
    await mount(tester, session);
    await lookup(tester, firstTenant);
    await tester.tap(find.text('核实并批准'));
    await flush(tester);
    final fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), 'evidence-001');
    await tester.enterText(fields.at(1), '独立核对完成');
    await tester.tap(find.text('确认批准'));
    await flush(tester);
    await tester.tap(find.text('重试'));
    await flush(tester);
    expect(detailCalls, 2);
    expect(session.requests.where((r) => r.method == 'POST').length, 1);
    expect(session.requests.last.url.path, '$reviewRoot/$firstTenant');
  });

  testWidgets('role-only change invalidates old detail and allows new reads',
      (tester) async {
    final session = ReviewSession();
    final oldDetail = Completer<http.Response>();
    completeOnTearDown(oldDetail,
        reply(reviewRow(firstTenant, enterprise: 'old_role_enterprise')));
    var calls = 0;
    session.respond = (request) async {
      if (request.url.path == reviewRoot) return queue([]);
      if (++calls == 1) return oldDetail.future;
      return reply(reviewRow(secondTenant, enterprise: 'new_role_enterprise'));
    };
    await mount(tester, session);
    await lookup(tester, firstTenant);
    session.changeScope(nextRole: 'PLATFORM_REVIEWER', increment: false);
    await flush(tester);
    oldDetail.complete(
        reply(reviewRow(firstTenant, enterprise: 'old_role_enterprise')));
    await flush(tester);
    expect(find.text('企业 old_role_enterprise'), findsNothing);
    await lookup(tester, secondTenant);
    expect(find.text('企业 new_role_enterprise'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('scope change clears modal input and cannot submit old review',
      (tester) async {
    final session = ReviewSession();
    await mount(tester, session);
    await lookup(tester, firstTenant);
    await tester.tap(find.text('核实并批准'));
    await flush(tester);
    final fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), 'old-evidence-001');
    await tester.enterText(fields.at(1), '旧范围核验理由');
    session.changeScope();
    await flush(tester);
    expect(find.text('old-evidence-001'), findsNothing);
    expect(find.text('旧范围核验理由'), findsNothing);
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        findsNothing);
    expect(find.text('确认批准'), findsNothing);
    expect(find.text('会话或操作范围已变化，请返回后重新查询当前记录。'), findsOneWidget);
    expect(session.requests.where((r) => r.method == 'POST'), isEmpty);
    await tester.tap(find.text('返回'));
    await flush(tester);
    await lookup(tester, secondTenant);
    expect(session.requests.last.url.path, '$reviewRoot/$secondTenant');
    expect(find.text('企业 enterprise_one'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed revocation retry reads state without repeating write',
      (tester) async {
    final session = ReviewSession();
    var detailCalls = 0;
    session.respond = (request) async {
      if (request.method == 'POST') return unavailable();
      if (request.url.path == reviewRoot) return queue([]);
      detailCalls++;
      return reply(reviewRow(firstTenant, state: 'ACTIVE', version: 2));
    };
    await mount(tester, session);
    await lookup(tester, firstTenant);
    await tester.tap(find.text('撤销绑定'));
    await flush(tester);
    final reason = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(reason, '独立核对后撤销');
    await tester.tap(find.text('确认撤销'));
    await flush(tester);
    await tester.tap(find.text('重试'));
    await flush(tester);
    expect(detailCalls, 2);
    expect(session.requests.where((r) => r.method == 'POST').length, 1);
    expect(session.requests.where((r) => r.method == 'POST').single.url.path,
        '$reviewRoot/$firstTenant/revoke');
    expect(session.requests.last.url.path, '$reviewRoot/$firstTenant');
    expect(find.text('企业已审核'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid review input remains editable until valid confirmation',
      (tester) async {
    final session = ReviewSession();
    session.respond = (request) async {
      if (request.method == 'POST') {
        return reply(reviewRow(firstTenant, state: 'ACTIVE', version: 2));
      }
      return request.url.path == reviewRoot
          ? queue([])
          : reply(reviewRow(firstTenant));
    };
    await mount(tester, session);
    await lookup(tester, firstTenant);
    await tester.tap(find.text('核实并批准'));
    await flush(tester);
    final fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), 'short');
    await tester.enterText(fields.at(1), '独立核对完成');
    await tester.tap(find.text('确认批准'));
    await flush(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    final failure = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(FailureView));
    expect(failure, findsOneWidget);
    expect(
        tester.widget<Notice>(find.descendant(
            of: failure, matching: find.byType(Notice))).text,
        (const ApiFailure(400, 'INVALID_OWNERSHIP_EVIDENCE')).message);
    expect(
        find.descendant(
            of: failure,
            matching: find.byType(SelectableText, skipOffstage: false)),
        findsNothing);
    final details =
        find.descendant(of: failure, matching: find.text('错误详情'));
    await tester.ensureVisible(details);
    await tester.tap(details);
    await flush(tester);
    expect(
        find.descendant(
            of: failure,
            matching: find.byWidgetPredicate((widget) =>
                widget is SelectableText &&
                widget.data == '错误代码：INVALID_OWNERSHIP_EVIDENCE')),
        findsOneWidget);
    expect(tester.widget<TextField>(fields.at(0)).controller!.text, 'short');
    expect(tester.widget<TextField>(fields.at(1)).controller!.text, '独立核对完成');
    expect(session.requests.where((r) => r.method == 'POST'), isEmpty);
    await tester.ensureVisible(fields.at(0));
    await tester.enterText(fields.at(0), 'evidence-001');
    await tester.tap(find.text('确认批准'));
    await flush(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('企业已审核'), findsOneWidget);
    expect(session.requests.where((r) => r.method == 'POST').length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing app and open modal releases route controllers',
      (tester) async {
    final session = ReviewSession();
    await mount(tester, session);
    await lookup(tester, firstTenant);
    await tester.tap(find.text('核实并批准'));
    await flush(tester);
    final fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), 'evidence-001');
    await tester.enterText(fields.at(1), '独立核对完成');
    await tester.pumpWidget(const SizedBox());
    await flush(tester);
    expect(session.requests.where((r) => r.method == 'POST'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page disposal invalidates its retained modal without a write',
      (tester) async {
    final session = ReviewSession();
    await mount(tester, session);
    await lookup(tester, firstTenant);
    await tester.tap(find.text('核实并批准'));
    await flush(tester);
    final fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), 'old-evidence-001');
    await tester.enterText(fields.at(1), '旧范围核验理由');
    await tester
        .pumpWidget(MaterialApp(theme: consoleTheme(), home: const SizedBox()));
    await flush(tester);
    expect(find.byType(ManagedAndroidReviewPage), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('会话或操作范围已变化，请返回后重新查询当前记录。'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        findsNothing);
    expect(find.text('确认批准'), findsNothing);
    expect(session.requests.where((r) => r.method == 'POST'), isEmpty);
    await tester.tap(find.text('返回'));
    await flush(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate confirmation cannot pop review page or repeat write',
      (tester) async {
    final session = ReviewSession();
    session.respond = (request) async {
      if (request.method == 'POST') {
        return reply(reviewRow(firstTenant, state: 'ACTIVE', version: 2));
      }
      return request.url.path == reviewRoot
          ? queue([])
          : reply(reviewRow(firstTenant));
    };
    await mount(tester, session, nestedRoute: true);
    await lookup(tester, firstTenant);
    await tester.tap(find.text('核实并批准'));
    await flush(tester);
    final fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), 'evidence-001');
    await tester.enterText(fields.at(1), '独立核对完成');
    final confirm = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '确认批准'))
        .onPressed!;
    confirm();
    confirm();
    await flush(tester);
    confirm();
    await flush(tester);
    expect(find.byType(ManagedAndroidReviewPage), findsOneWidget);
    expect(find.text('企业已审核'), findsOneWidget);
    expect(session.requests.where((r) => r.method == 'POST').length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('old return callback cannot pop page or a later dialog',
      (tester) async {
    final session = ReviewSession();
    await mount(tester, session, nestedRoute: true);
    await lookup(tester, firstTenant);
    await tester.tap(find.text('核实并批准'));
    await flush(tester);
    final firstReturn = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '返回'))
        .onPressed!;
    firstReturn();
    firstReturn();
    await flush(tester);
    await flush(tester);
    expect(find.byType(ManagedAndroidReviewPage), findsOneWidget);
    await tester.tap(find.text('核实并批准'));
    await flush(tester);
    final dismissedReturn = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '返回'))
        .onPressed!;
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    dismissedReturn();
    await flush(tester);
    await flush(tester);
    expect(find.byType(ManagedAndroidReviewPage), findsOneWidget);
    await tester.tap(find.text('核实并批准'));
    await flush(tester);
    firstReturn();
    dismissedReturn();
    await flush(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(ManagedAndroidReviewPage), findsOneWidget);
    expect(session.requests.where((r) => r.method == 'POST'), isEmpty);
    await tester.tap(find.text('返回'));
    await flush(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('old lookup retry is inert during same-frame scope replacement',
      (tester) async {
    final session = ReviewSession();
    var reads = 0;
    session.respond = (request) async {
      if (request.url.path == reviewRoot) return queue([]);
      return ++reads == 1
          ? unavailable()
          : reply(reviewRow(request.url.path.split('/').last));
    };
    await mount(tester, session);
    await lookup(tester, firstTenant);
    final retry = tester
        .widget<TextButton>(find.ancestor(
            of: find.text('重试'),
            matching: find.byWidgetPredicate((widget) => widget is TextButton)))
        .onPressed!;
    session.changeScope();
    retry();
    await flush(tester);
    expect(reads, 1);
    expect(find.text('SERVICE_UNAVAILABLE'), findsNothing);
    expect(
        find.descendant(
            of: lookupPanel(), matching: find.byType(FailureView)),
        findsNothing);
    expect(find.text('未完成的查询：$firstTenant'), findsNothing);
    expect(tester.takeException(), isNull);
    await lookup(tester, secondTenant);
    expect(reads, 2);
    expect(find.text('机构 $secondTenant'), findsOneWidget);
  });

  testWidgets('old write retry is inert during same-frame scope replacement',
      (tester) async {
    final session = ReviewSession();
    var reads = 0;
    session.respond = (request) async {
      if (request.method == 'POST') return unavailable();
      if (request.url.path == reviewRoot) return queue([]);
      reads++;
      return reply(reviewRow(request.url.path.split('/').last));
    };
    await mount(tester, session);
    await lookup(tester, firstTenant);
    await tester.tap(find.text('核实并批准'));
    await flush(tester);
    final fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), 'evidence-001');
    await tester.enterText(fields.at(1), '独立核对完成');
    await tester.tap(find.text('确认批准'));
    await flush(tester);
    final retry = tester
        .widget<TextButton>(find.ancestor(
            of: find.text('重试'),
            matching: find.byWidgetPredicate((widget) => widget is TextButton)))
        .onPressed!;
    session.changeScope();
    retry();
    await flush(tester);
    expect(reads, 1);
    expect(session.requests.where((r) => r.method == 'POST').length, 1);
    expect(tester.takeException(), isNull);
    await lookup(tester, secondTenant);
    expect(reads, 2);
    expect(find.text('机构 $secondTenant'), findsOneWidget);
  });

  testWidgets('old selected action and query callbacks cannot cross scope',
      (tester) async {
    final session = ReviewSession();
    await mount(tester, session);
    await lookup(tester, firstTenant);
    final approve = tester
        .widget<FilledButton>(find.ancestor(
            of: find.text('核实并批准'),
            matching:
                find.byWidgetPredicate((widget) => widget is FilledButton)))
        .onPressed!;
    final query = tester
        .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '查询'))
        .onPressed!;
    final detailReads =
        session.requests.where((r) => r.url.path != reviewRoot).length;
    session.changeScope();
    approve();
    query();
    await flush(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('INVALID_TENANT_ID'), findsNothing);
    expect(
        find.descendant(
            of: lookupPanel(), matching: find.byType(FailureView)),
        findsNothing);
    expect(session.requests.where((r) => r.url.path != reviewRoot).length,
        detailReads);
    expect(session.requests.where((r) => r.method == 'POST'), isEmpty);
    expect(tester.takeException(), isNull);
    await lookup(tester, secondTenant);
    expect(session.requests.last.url.path, '$reviewRoot/$secondTenant');
    expect(find.text('机构 $secondTenant'), findsOneWidget);
  });
}
