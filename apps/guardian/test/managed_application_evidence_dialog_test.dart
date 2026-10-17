import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_agent_binding.dart';
import 'package:guardian/core/managed_application_evidence.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/managed_application_evidence_controller.dart';
import 'package:guardian/ui/managed_application_evidence_dialog.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'managed_agent_binding_fixtures.dart'
    show
        bindingTenant,
        bindingEnrollment,
        bindingDevice,
        bindingRegistration,
        bindingId;

const _app = '88888888-8888-4888-8888-888888888888';
const _other = '99999999-9999-4999-8999-999999999999';
const _instant = 1792209600000;
const _privateName = '私有阅读器';
const _otherName = '私有课堂工具';
const _primary = Key('managed-evidence-primary');
const _query = Key('managed-evidence-query');
const _close = Key('managed-evidence-close');
const _reauth = Key('managed-evidence-reauth');

class _Access extends ChangeNotifier {
  bool current = true;
  void setCurrent(bool value) {
    current = value;
    notifyListeners();
  }

  void aba() {
    setCurrent(false);
    setCurrent(true);
  }
}

/// Synthetic HTTP, using the production repository and controller throughout.
/// These tests do not claim an EMM provider or Android device was exercised.
class _Fixture {
  final access = _Access();
  final requests = <http.Request>[];
  final denials = <ApiFailure>[];
  DateTime now = DateTime.fromMillisecondsSinceEpoch(_instant);
  String readState = 'ABSENT';
  bool identityOnly = false, paginated = false;
  Duration lifetime = const Duration(minutes: 1);
  Future<http.Response?> Function(http.Request)? intercept;
  late final client = MockClient((request) async {
    requests.add(request);
    final custom = await intercept?.call(request);
    if (custom != null) {
      return custom;
    }
    if (request.url.path.endsWith('/applications')) {
      final later = request.url.queryParameters.containsKey('cursor');
      return response({
        'items': later ? [application(id: _other)] : [application()],
        'nextCursor': paginated && !later ? _app : null,
      });
    }
    final parts = request.url.pathSegments;
    final id = parts[parts.indexOf('applications') + 1];
    return response(evidence(
        applicationId: id,
        state: request.method == 'POST' ? 'VERIFIED_IDENTITY' : readState));
  });
  late final repository = ManagedApplicationEvidenceRepository(
      api: Api(() async => client,
          baseUrl: 'https://application-dialog.invalid/api/v1'),
      tenantId: bindingTenant,
      binding: const ManagedAgentBinding(
          id: bindingId,
          enrollmentId: bindingEnrollment,
          deviceId: bindingDevice,
          registrationId: bindingRegistration,
          state: 'VERIFIED',
          version: 3,
          createdAt: _instant - 60000,
          expiresAt: _instant + 540000,
          verifiedAt: _instant - 1000),
      current: () => access.current,
      onDenied: denials.add);
  late final controller = ManagedApplicationEvidenceController(
      repository: repository,
      current: () => access.current,
      accessChanges: access,
      clock: () => now);
  late BuildContext host;
  late OwnedDialogRoute<void> route;
  int reauthentications = 0, parentRefreshes = 0;
  bool completed = false;
  Object? routeFailure;

  Json application({String id = _app}) => {
        'id': id,
        'displayName': id == _app ? _privateName : _otherName,
        'platform': 'ANDROID',
        'packageName': id == _app ? 'com.example.Reader' : 'com.example.Class',
        'profile': 'PRIMARY',
        'signingDigests': ['a' * 64],
        'evidenceStatus': 'ADMIN_DECLARED',
      };

  Json evidence(
      {String applicationId = _app,
      String state = 'ABSENT',
      int? nextRefreshAt}) {
    final verified = state == 'VERIFIED_IDENTITY';
    final time = now.millisecondsSinceEpoch;
    return {
      'bindingId': bindingId,
      'applicationId': applicationId,
      'state': state,
      'reasonCode': state == 'ABSENT'
          ? 'MANAGED_APPLICATION_EVIDENCE_REQUIRED'
          : verified
              ? identityOnly
                  ? 'MANAGED_APPLICATION_CONTROL_UNVERIFIED'
                  : 'MANAGED_APPLICATION_CONTROL_VERIFIED'
              : 'MANAGED_APPLICATION_REPORT_PENDING',
      'version': state == 'ABSENT' ? 0 : 2,
      'profileScope': verified && !identityOnly ? 'PRIMARY' : 'UNKNOWN',
      'systemControlAvailable': verified && !identityOnly,
      'reportedAt': verified ? time - 2000 : null,
      'retrievedAt': verified ? time - 1000 : null,
      'expiresAt': verified ? time + lifetime.inMilliseconds : null,
      'nextRefreshAt': state == 'ABSENT' ? null : nextRefreshAt ?? time - 1,
      'controlOperations': verified && !identityOnly
          ? [
              {'kind': 'APP_LAUNCH', 'effect': 'DENY', 'permission': null},
              {
                'kind': 'RUNTIME_PERMISSION',
                'effect': 'DENY',
                'permission': 'android.permission.CAMERA'
              },
            ]
          : [],
    };
  }

  http.Response response(Object? value, {int status = 200}) =>
      http.Response(jsonEncode(value), status,
          headers: {'content-type': 'application/json; charset=utf-8'});

  List<http.Request> get posts =>
      requests.where((r) => r.method == 'POST').toList();
  List<http.Request> get reads => requests
      .where((r) => r.method == 'GET' && r.url.path.endsWith('/evidence'))
      .toList();
}

// HTTP futures run outside Flutter's fake-clock queue; the bounded pump helper
// drains both queues without waiting forever on the controller's expiry timer.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _mount(WidgetTester tester, _Fixture f,
    {double width = 1100, double scale = 1}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  // This host owns the controller, matching the production entry contract.
  // Dispose during widget unmount, before the binding verifies pending timers.
  await tester.pumpWidget(
      ChangeNotifierProvider<ManagedApplicationEvidenceController>(
          lazy: false,
          create: (_) => f.controller,
          child: MaterialApp(
              theme: consoleTheme(),
              builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!),
              home: Scaffold(body: Builder(builder: (context) {
                f.host = context;
                return const Text('关联详情宿主');
              })))));
  f.route = OwnedDialogRoute<void>(
      context: f.host,
      barrierDismissible: false,
      builder: (_) => ManagedApplicationEvidenceDialog(
          controller: f.controller,
          onClose: () => f.route.finish(),
          reauthenticate: () => f.reauthentications++,
          onParentRefresh: () => f.parentRefreshes++));
  unawaited(presentOwnedDialog(f.host, f.route).then<void>((_) {
    f.completed = true;
  }, onError: (Object error, StackTrace _) {
    f.routeFailure = error;
  }));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
    f.access.dispose();
    f.client.close();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await _settle(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _settle(tester);
}

Future<void> _select(WidgetTester tester, [String id = _app]) =>
    _tap(tester, find.byKey(ValueKey('managed-evidence-application-$id')));

VoidCallback _callback(WidgetTester tester, Key key) {
  final finder = find.byKey(key);
  expect(finder, findsOneWidget);
  final callback = tester.widget<ButtonStyleButton>(finder).onPressed;
  expect(callback, isNotNull);
  return callback!;
}

Future<void> _cover(WidgetTester tester, _Fixture f) async {
  unawaited(showDialog<void>(
      context: f.host,
      builder: (context) => AlertDialog(title: const Text('独立通知'), actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('保留通知后关闭'))
          ])));
  await _settle(tester);
}

void _buildPhaseSiblingRevocationCase() {
  testWidgets(
      'parent revocation during rebuild clears immediately across sibling routes',
      (tester) async {
    final f = _Fixture()..readState = 'VERIFIED_IDENTITY';
    StateSetter? rebuildParent;
    VoidCallback? oldPost;
    OwnedDialogRoute<void>? ownedRoute;
    Future<void>? routeCompletion;
    ModalRoute<dynamic>? lowerParentRoute;
    var revokeOnBuild = false, revokedInBuild = false;
    var clearedSynchronously = false, oldPostBlockedSynchronously = false;
    var parentBuilds = 0, requestCount = 0;
    var hostClosing = false;
    void closeHost() {
      if (hostClosing) return;
      hostClosing = true;
      f.controller.invalidate();
      ownedRoute?.finish();
    }

    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      f.access.dispose();
      f.client.close();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    try {
      // Provider owns a non-Listenable record holding the real controller,
      // so it neither subscribes to it nor disables type checks. Dialog is
      // its only UI notifier listener, matching the production entry. The
      // StatefulBuilder belongs to the lower home route, not to an ancestor of
      // the independent dialog overlay entry that will receive notifications.
      await tester.pumpWidget(
          Provider<({ManagedApplicationEvidenceController controller})>(
              lazy: false,
              create: (_) => (controller: f.controller),
              dispose: (_, owner) => owner.controller.dispose(),
              child: MaterialApp(
                  theme: consoleTheme(),
                  home: Scaffold(
                      body: StatefulBuilder(
                          key: const Key('lower-binding-revocation-builder'),
                          builder: (context, setParentState) {
                            f.host = context;
                            rebuildParent = setParentState;
                            lowerParentRoute = ModalRoute.of(context);
                            parentBuilds++;
                            if (revokeOnBuild && !revokedInBuild) {
                              revokedInBuild = true;
                              f.controller.invalidate();
                              clearedSynchronously = !f.controller.hasAccess &&
                                  f.controller.items.isEmpty &&
                                  f.controller.selected == null &&
                                  f.controller.evidence == null;
                              oldPost?.call();
                              oldPostBlockedSynchronously = f.posts.isEmpty &&
                                  f.requests.length == requestCount;
                            }
                            return const Text('下层父关联路由');
                          })))));
      f.route = OwnedDialogRoute<void>(
          context: f.host,
          barrierDismissible: false,
          builder: (_) => ManagedApplicationEvidenceDialog(
              controller: f.controller,
              onClose: closeHost,
              reauthenticate: () => f.reauthentications++,
              onParentRefresh: () => f.parentRefreshes++));
      ownedRoute = f.route;
      routeCompletion = presentOwnedDialog(f.host, f.route).then<void>((_) {
        f.completed = true;
      }, onError: (Object error, StackTrace _) {
        f.routeFailure = error;
      });
      await _settle(tester);
      await _select(tester);
      await tester.enterText(
          find.byKey(const Key('managed-evidence-search')), _privateName);
      await _settle(tester);
      expect(f.controller.selected?.id, _app);
      expect(f.controller.evidence?.state, 'VERIFIED_IDENTITY');
      expect(f.controller.items, hasLength(1));
      expect(f.posts, isEmpty);
      expect(f.route.isCurrent, isTrue);
      expect(lowerParentRoute, isNotNull);
      expect(lowerParentRoute, isNot(same(f.route)));
      expect(lowerParentRoute!.isCurrent, isFalse);
      expect(lowerParentRoute!.isActive, isTrue);
      expect(
          find.ancestor(
              of: find.byType(ManagedApplicationEvidenceDialog),
              matching: find.byKey(
                  const Key('lower-binding-revocation-builder'),
                  skipOffstage: false)),
          findsNothing,
          reason:
              'The rebuilding parent is on the sibling route, not a dialog ancestor.');
      expect(rebuildParent, isNotNull);
      final capturedPost = _callback(tester, _primary);
      oldPost = capturedPost;
      requestCount = f.requests.length;
      final buildsBefore = parentBuilds;

      rebuildParent!(() => revokeOnBuild = true);
      await tester.pump();

      expect(parentBuilds, greaterThan(buildsBefore));
      expect(revokedInBuild, isTrue);
      expect(clearedSynchronously, isTrue,
          reason:
              'Revocation clears real core state inside the lower route build.');
      expect(oldPostBlockedSynchronously, isTrue);
      expect(f.controller.hasAccess, isFalse);
      expect(f.controller.items, isEmpty);
      expect(f.controller.selected, isNull);
      expect(f.controller.evidence, isNull);
      expect(f.requests, hasLength(requestCount));
      expect(f.posts, isEmpty);
      expect(tester.takeException(), isNull,
          reason:
              'A sibling route notification cannot mark the dialog or its text field dirty during build.');

      // A frame-safe UI notification may schedule this next frame. It must not
      // defer core revocation or keep showing private data after that frame.
      await tester.pump();
      expect(find.text(_privateName), findsNothing);
      expect(find.byKey(const Key('managed-evidence-search')), findsNothing);
      expect(find.textContaining('权限已变化'), findsOneWidget);
      expect(f.route.isCurrent, isTrue);
      expect(f.completed, isFalse);
      capturedPost();
      await _settle(tester);
      expect(f.requests, hasLength(requestCount));
      expect(f.posts, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      final route = ownedRoute;
      if (route != null) {
        closeHost();
        await _settle(tester);
        if (!f.completed &&
            route.isActive &&
            route.navigator?.mounted == true) {
          // Remove only this fixture's known route if ordinary finish was
          // refused. No top-route pop or unresolved completion await is used.
          route.navigator!.removeRoute(route);
          await _settle(tester);
        }
        if (!f.completed || route.isActive || f.routeFailure != null) {
          throw StateError('Sibling revocation fixture route did not finish.');
        }
        if (routeCompletion != null) {
          await routeCompletion;
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
    }
  });
}

void main() {
  _buildPhaseSiblingRevocationCase();
  testWidgets(
      'opening loads only server declarations without an automatic refresh',
      (tester) async {
    final f = _Fixture();
    await _mount(tester, f);
    expect(find.text(_privateName), findsOneWidget);
    expect(find.textContaining('目录登记不代表设备已安装'), findsOneWidget);
    expect(f.requests, hasLength(1));
    expect(f.requests.single.method, 'GET');
    expect(f.requests.single.url.queryParameters, {'limit': '50'});
    expect(f.reads, isEmpty);
    expect(f.posts, isEmpty);
    expect(f.routeFailure, isNull);
  });

  testWidgets(
      'selection passively reads evidence and keeps the binding version',
      (tester) async {
    final f = _Fixture();
    await _mount(tester, f);
    await _select(tester);
    expect(find.text('尚未核验'), findsOneWidget);
    expect(find.text('开始核验'), findsOneWidget);
    expect(f.reads, hasLength(1));
    expect(f.reads.single.headers['If-Match'], '"3"');
    expect(
        f.reads.single.url.path,
        '/api/v1/tenants/$bindingTenant/managed-android/agent-bindings/'
        '$bindingId/applications/$_app/evidence');
    expect(f.posts, isEmpty);
  });

  testWidgets(
      'only the explicit primary action posts once without device facts',
      (tester) async {
    final f = _Fixture();
    await _mount(tester, f);
    await _select(tester);
    final submit = _callback(tester, _primary);
    submit();
    submit();
    await _settle(tester);
    expect(f.posts, hasLength(1));
    expect(f.posts.single.url.path, '${f.reads.single.url.path}/refresh');
    expect(f.posts.single.headers['If-Match'], '"3"');
    expect(f.posts.single.body, isEmpty);
    expect(find.text('应用身份已核验'), findsOneWidget);
    expect(find.textContaining('不代表限制已生效'), findsOneWidget);
    expect(find.text('重新核验'), findsOneWidget);
  });

  testWidgets('local search explicitly searches loaded declarations only',
      (tester) async {
    final f = _Fixture()..paginated = true;
    await _mount(tester, f);
    final search = find.byKey(const Key('managed-evidence-search'));
    expect(search, findsOneWidget);
    expect(find.text('搜索已加载的应用'), findsOneWidget);
    await tester.enterText(search, '没有这个应用');
    await _settle(tester);
    expect(find.textContaining('已加载目录中没有匹配应用'), findsOneWidget);
    expect(f.requests, hasLength(1));
    expect(f.posts, isEmpty);
  });

  testWidgets(
      'catalog pagination is explicit and retains the selected application',
      (tester) async {
    final f = _Fixture()..paginated = true;
    await _mount(tester, f);
    await _select(tester);
    await _tap(tester, find.byKey(const Key('managed-evidence-load-more')));
    expect(find.text(_otherName), findsOneWidget);
    expect(f.controller.selected?.id, _app);
    expect(f.requests.where((r) => r.url.queryParameters['cursor'] == _app),
        hasLength(1));
    expect(f.posts, isEmpty);
  });

  testWidgets(
      'changing selection immediately hides the previous private evidence',
      (tester) async {
    final f = _Fixture()
      ..paginated = true
      ..readState = 'VERIFIED_IDENTITY';
    await _mount(tester, f);
    await _select(tester);
    await _tap(tester, find.byKey(const Key('managed-evidence-operations')));
    expect(find.text('应用启动 · 禁止'), findsOneWidget);
    await _tap(tester, find.byKey(const Key('managed-evidence-load-more')));
    final held = Completer<http.Response>();
    addTearDown(() {
      if (!held.isCompleted) {
        held.complete(f.response(f.evidence(applicationId: _other)));
      }
    });
    f.intercept = (request) async =>
        request.url.path.contains('/$_other/') ? held.future : null;
    await _select(tester, _other);
    expect(find.text('应用启动 · 禁止'), findsNothing);
    expect(f.controller.selected?.id, _other);
    expect(f.posts, isEmpty);
    held.complete(f.response(f.evidence(applicationId: _other)));
    await _settle(tester);
    expect(find.text('尚未核验'), findsOneWidget);
  });

  for (final malformed in [false, true]) {
    testWidgets(
        'uncertain refresh malformed=$malformed exposes GET reconciliation only',
        (tester) async {
      final f = _Fixture();
      await _mount(tester, f);
      await _select(tester);
      f.intercept = (request) async {
        if (request.method != 'POST') {
          return null;
        }
        if (malformed) {
          return f.response({});
        }
        throw http.ClientException('Synthetic response loss');
      };
      await _tap(tester, find.byKey(_primary));
      expect(f.controller.unknownOutcome, isTrue);
      expect(find.text('查询核验结果'), findsOneWidget);
      final posts = f.posts.length;
      f.now = f.now.add(const Duration(minutes: 3));
      await tester.pump(const Duration(seconds: 2));
      expect(f.posts, hasLength(posts));
      expect(find.text('重新核验'), findsNothing);
      await _tap(tester, find.byKey(_primary));
      expect(f.posts, hasLength(1));
      expect(f.reads, hasLength(2));
      expect(f.controller.unknownOutcome, isFalse);
      expect(find.text('开始核验'), findsOneWidget);
    });
  }

  testWidgets('pending remains query only even after the refresh cooldown',
      (tester) async {
    final f = _Fixture()..readState = 'PENDING';
    await _mount(tester, f);
    await _select(tester);
    expect(find.text('正在核验'), findsOneWidget);
    expect(find.text('查询核验结果'), findsOneWidget);
    f.now = f.now.add(const Duration(minutes: 3));
    await tester.pump(const Duration(seconds: 2));
    await _tap(tester, find.byKey(_primary));
    expect(f.posts, isEmpty);
    expect(f.reads, hasLength(2));
    expect(f.controller.canRefresh, isFalse);
  });

  testWidgets(
      'rate limit first queries the server before enabling another refresh',
      (tester) async {
    final f = _Fixture();
    await _mount(tester, f);
    await _select(tester);
    f.intercept = (request) async => request.method == 'POST'
        ? f.response({'errorCode': 'MANAGED_APPLICATION_REFRESH_THROTTLED'},
            status: 429)
        : null;
    await _tap(tester, find.byKey(_primary));
    expect(find.text('查询核验结果'), findsOneWidget);
    f.now = f.now.add(const Duration(minutes: 3));
    await tester.pump(const Duration(seconds: 2));
    await _tap(tester, find.byKey(_primary));
    expect(f.posts, hasLength(1));
    expect(f.reads, hasLength(2));
    expect(find.text('开始核验'), findsOneWidget);
  });

  testWidgets(
      'binding conflict hides evidence and offers explicit parent refresh',
      (tester) async {
    final f = _Fixture()..readState = 'VERIFIED_IDENTITY';
    await _mount(tester, f);
    await _select(tester);
    f.intercept = (request) async => request.method == 'POST'
        ? f.response({'errorCode': 'RESOURCE_VERSION_CONFLICT'}, status: 412)
        : null;
    await _tap(tester, find.byKey(_primary));
    expect(find.text('应用身份已核验'), findsNothing);
    expect(find.textContaining('关联已变化'), findsOneWidget);
    expect(find.byKey(const Key('managed-evidence-operations')), findsNothing);
    expect(f.parentRefreshes, 0);
    final count = f.requests.length;
    await _tap(
        tester, find.byKey(const Key('managed-evidence-parent-refresh')));
    expect(f.parentRefreshes, 1);
    expect(f.requests, hasLength(count));
    expect(f.posts.single.headers['If-Match'], '"3"');
  });

  testWidgets('step up is explicit and never automatically replays a refresh',
      (tester) async {
    final f = _Fixture();
    await _mount(tester, f);
    await _select(tester);
    f.intercept = (request) async => request.method == 'POST'
        ? f.response({'errorCode': 'REAUTH_REQUIRED'}, status: 401)
        : null;
    await _tap(tester, find.byKey(_primary));
    expect(find.text('重新安全验证'), findsOneWidget);
    expect(f.reauthentications, 0);
    await _tap(tester, find.byKey(_reauth));
    expect(f.reauthentications, 1);
    expect(f.posts, hasLength(1));
  });

  for (final covered in [false, true]) {
    testWidgets(
        'captured step up is inert after ${covered ? 'coverage' : 'scope ABA'}',
        (tester) async {
      final f = _Fixture();
      await _mount(tester, f);
      await _select(tester);
      f.intercept = (request) async => request.method == 'POST'
          ? f.response({'errorCode': 'REAUTH_REQUIRED'}, status: 401)
          : null;
      await _tap(tester, find.byKey(_primary));
      final callback = _callback(tester, _reauth);
      if (covered) {
        await _cover(tester, f);
      } else {
        f.access.aba();
      }
      callback();
      await _settle(tester);
      expect(f.reauthentications, 0);
      expect(f.posts, hasLength(1));
      if (covered) {
        expect(find.text('独立通知'), findsOneWidget);
      }
    });
  }

  testWidgets(
      'hard denial permanently hides private data and disables old callbacks',
      (tester) async {
    final f = _Fixture()..readState = 'VERIFIED_IDENTITY';
    await _mount(tester, f);
    await _select(tester);
    final query = _callback(tester, _query);
    f.intercept = (request) async =>
        f.response({'errorCode': 'ACCESS_DENIED'}, status: 403);
    query();
    await _settle(tester);
    final count = f.requests.length;
    query();
    f.access.aba();
    await _settle(tester);
    expect(find.text(_privateName), findsNothing);
    expect(find.text('应用身份已核验'), findsNothing);
    expect(find.byKey(const Key('managed-evidence-operations')), findsNothing);
    expect(find.textContaining('权限已变化'), findsOneWidget);
    expect(f.requests, hasLength(count));
    expect(f.denials, hasLength(1));
    expect(f.posts, isEmpty);
  });

  testWidgets(
      'scope ABA prevents a captured primary action from physical dispatch',
      (tester) async {
    final f = _Fixture();
    await _mount(tester, f);
    await _select(tester);
    final callback = _callback(tester, _primary);
    final count = f.requests.length;
    f.access.aba();
    callback();
    await _settle(tester);
    expect(f.requests, hasLength(count));
    expect(find.text(_privateName), findsNothing);
    expect(find.textContaining('权限已变化'), findsOneWidget);
  });

  testWidgets(
      'a covered primary callback cannot dispatch behind another dialog',
      (tester) async {
    final f = _Fixture();
    await _mount(tester, f);
    await _select(tester);
    final callback = _callback(tester, _primary);
    final count = f.requests.length;
    await _cover(tester, f);
    callback();
    await _settle(tester);
    expect(f.requests, hasLength(count));
    expect(find.text('独立通知'), findsOneWidget);
  });

  testWidgets('covered close removes only its own route and retains the notice',
      (tester) async {
    final f = _Fixture();
    await _mount(tester, f);
    final close = _callback(tester, _close);
    await _cover(tester, f);
    close();
    await _settle(tester);
    expect(f.completed, isTrue);
    expect(f.routeFailure, isNull);
    expect(f.route.isActive, isFalse);
    expect(find.text('独立通知'), findsOneWidget);
    expect(find.byType(ManagedApplicationEvidenceDialog, skipOffstage: false),
        findsNothing);
    expect(f.posts, isEmpty);
  });

  testWidgets(
      'uncertain result can be closed safely without retry or hidden post',
      (tester) async {
    final f = _Fixture();
    await _mount(tester, f);
    await _select(tester);
    f.intercept = (request) async {
      if (request.method == 'POST') {
        throw http.ClientException('Synthetic response loss');
      }
      return null;
    };
    await _tap(tester, find.byKey(_primary));
    expect(f.controller.unknownOutcome, isTrue);
    final staleQuery = _callback(tester, _primary);
    final count = f.requests.length;
    await _tap(tester, find.byKey(_close));
    staleQuery();
    await _settle(tester);
    expect(f.completed, isTrue);
    expect(find.text('关联详情宿主'), findsOneWidget);
    expect(f.requests, hasLength(count));
    expect(f.posts, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'open expiry immediately hides expanded operations without changing the snapshot',
      (tester) async {
    final f = _Fixture()
      ..readState = 'VERIFIED_IDENTITY'
      ..lifetime = const Duration(seconds: 2);
    await _mount(tester, f);
    await _select(tester);
    final snapshot = f.controller.evidence!;
    await _tap(tester, find.byKey(const Key('managed-evidence-operations')));
    expect(find.text('应用启动 · 禁止'), findsOneWidget);
    f.now = f.now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('应用启动 · 禁止'), findsNothing);
    expect(find.text('核验已过期'), findsOneWidget);
    expect(find.byKey(const Key('managed-evidence-operations')), findsNothing);
    expect(snapshot.state, 'VERIFIED_IDENTITY');
    expect(snapshot.controlOperations, hasLength(2));
    expect(f.posts, isEmpty);
  });

  for (final state in ['WAITING_REPORT', 'FAILED', 'REJECTED', 'STALE']) {
    testWidgets(
        '$state describes missing or unusable evidence without claiming absence',
        (tester) async {
      final f = _Fixture()..readState = state;
      await _mount(tester, f);
      await _select(tester);
      expect(find.byKey(const Key('managed-evidence-status')), findsOneWidget);
      expect(find.text('应用未安装'), findsNothing);
      expect(
          find.byKey(const Key('managed-evidence-operations')), findsNothing);
      expect(find.text('重新核验'), findsOneWidget);
      expect(f.posts, isEmpty);
    });
  }

  testWidgets('identity alone never displays verified system operation scope',
      (tester) async {
    final f = _Fixture()
      ..readState = 'VERIFIED_IDENTITY'
      ..identityOnly = true;
    await _mount(tester, f);
    await _select(tester);
    expect(find.text('应用身份已核验'), findsOneWidget);
    expect(find.textContaining('控制能力待确认'), findsOneWidget);
    expect(find.byKey(const Key('managed-evidence-operations')), findsNothing);
    expect(find.text('应用启动 · 禁止'), findsNothing);
  });

  testWidgets(
      '320px with double text keeps selection operations and close reachable',
      (tester) async {
    final f = _Fixture()..readState = 'VERIFIED_IDENTITY';
    await _mount(tester, f, width: 320, scale: 2);
    await _select(tester);
    await _tap(tester, find.byKey(const Key('managed-evidence-operations')));
    final camera = find.textContaining('CAMERA');
    expect(camera, findsOneWidget);
    await tester.ensureVisible(camera);
    await tester.pump();
    expect(camera.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _tap(tester, find.byKey(_close));
    expect(f.completed, isTrue);
    expect(f.posts, isEmpty);
  });
}
