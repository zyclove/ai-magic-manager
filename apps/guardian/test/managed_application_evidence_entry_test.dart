@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/managed_agent_binding.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/managed_application_evidence_entry.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/managed_application_evidence_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'managed_agent_binding_fixtures.dart'
    show
        bindingTenant,
        bindingEnrollment,
        bindingDevice,
        bindingRegistration,
        bindingId;

const _application = '88888888-8888-4888-8888-888888888888';
const _privateName = '原工作空间私有应用';

class _BorrowedClient extends http.BaseClient {
  final MockClient _delegate;
  bool closed = false;
  _BorrowedClient(Future<http.Response> Function(http.Request) respond)
      : _delegate = MockClient(respond);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _delegate.send(request);

  @override
  void close() {
    closed = true;
    _delegate.close();
  }
}

class _EntrySession extends Session {
  bool authenticatedValue = true;
  int generationValue = 0;
  final requests = <http.Request>[];
  final loginSteps = <bool>[];
  Future<http.Response?> Function(http.Request)? intercept;
  late final client = _BorrowedClient((request) async {
    requests.add(request);
    final custom = await intercept?.call(request);
    if (custom != null) {
      return custom;
    }
    if (request.url.path.endsWith('/applications')) {
      return response({
        'items': [
          {
            'id': _application,
            'displayName': _privateName,
            'platform': 'ANDROID',
            'packageName': 'com.example.PrivateReader',
            'profile': 'PRIMARY',
            'signingDigests': ['a' * 64],
            'evidenceStatus': 'ADMIN_DECLARED',
          }
        ],
        'nextCursor': null,
      });
    }
    return response(evidence());
  });
  late final fixtureApi = Api(() async => client,
      baseUrl: 'https://application-entry.invalid/api/v1');

  _EntrySession() {
    ready = true;
    tenant = {'id': bindingTenant, 'kind': 'ORGANIZATION'};
    profile = {'subject': 'original-admin'};
    role = 'OWNER';
  }

  @override
  bool get authenticated => authenticatedValue;
  @override
  int get scopeGeneration => generationValue;
  @override
  Api get api => fixtureApi;
  @override
  void login({bool stepUp = false}) => loginSteps.add(stepUp);

  http.Response response(Object? value, {int status = 200}) =>
      http.Response(jsonEncode(value), status,
          headers: {'content-type': 'application/json; charset=utf-8'});

  Json evidence() => {
        'bindingId': bindingId,
        'applicationId': _application,
        'state': 'ABSENT',
        'reasonCode': 'MANAGED_APPLICATION_EVIDENCE_REQUIRED',
        'version': 0,
        'profileScope': 'UNKNOWN',
        'systemControlAvailable': false,
        'reportedAt': null,
        'retrievedAt': null,
        'expiresAt': null,
        'nextRefreshAt': null,
        'controlOperations': [],
      };

  void aba(String dimension) {
    if (dimension == 'actor') {
      profile = {'subject': 'replacement-admin'};
      notifyListeners();
      profile = {'subject': 'original-admin'};
    } else if (dimension == 'tenant') {
      tenant = {
        'id': '99999999-9999-4999-8999-999999999999',
        'kind': 'ORGANIZATION'
      };
      notifyListeners();
      tenant = {'id': bindingTenant, 'kind': 'ORGANIZATION'};
    } else if (dimension == 'role') {
      role = 'AUDITOR';
      notifyListeners();
      role = 'OWNER';
    } else {
      generationValue++;
      notifyListeners();
    }
    notifyListeners();
  }

  List<http.Request> get posts =>
      requests.where((r) => r.method == 'POST').toList();
}

class _Parent extends ChangeNotifier {
  bool current = true;
  int refreshes = 0;
  bool? childActiveAtRefresh;
  void aba() {
    current = false;
    notifyListeners();
    current = true;
    notifyListeners();
  }
}

class _Invocation {
  bool completed = false;
  Object? failure;
  _Invocation(Future<void> operation) {
    unawaited(operation.then<void>((_) {
      completed = true;
    }, onError: (Object error, StackTrace _) {
      failure = error;
      completed = true;
    }));
  }
}

class _Host {
  final _EntrySession session;
  final parent = _Parent();
  late BuildContext context;
  late _Invocation invocation;
  _Host(this.session);

  ManagedAgentBinding binding(
      {String state = 'VERIFIED', bool verifiedAt = true, int version = 3}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return ManagedAgentBinding(
        id: bindingId,
        enrollmentId: bindingEnrollment,
        deviceId: bindingDevice,
        registrationId: bindingRegistration,
        state: state,
        version: version,
        createdAt: now - 60000,
        expiresAt: now + 540000,
        verifiedAt: verifiedAt ? now - 1000 : null);
  }

  void open({ManagedAgentBinding? target}) {
    invocation = _Invocation(
        showManagedApplicationEvidence(context, session, target ?? binding(),
            parentCurrent: () => parent.current,
            parentChanges: parent,
            onParentRefresh: () {
              parent.refreshes++;
              final dialog = find.byType(ManagedApplicationEvidenceDialog,
                  skipOffstage: false);
              parent.childActiveAtRefresh = dialog.evaluate().isNotEmpty;
            }));
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<_Host> _mount(WidgetTester tester, [_EntrySession? session]) async {
  final host = _Host(session ?? _EntrySession());
  tester.view.physicalSize = const Size(1100, 1000);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(body: Builder(builder: (context) {
        host.context = context;
        return const Text('关联详情宿主');
      }))));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
    host.session.client.close();
    host.session.dispose();
    host.parent.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  return host;
}

Future<void> _tap(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _settle(tester);
}

VoidCallback _callback(WidgetTester tester, Key key) {
  final finder = find.byKey(key);
  expect(finder, findsOneWidget);
  final callback = tester.widget<ButtonStyleButton>(finder).onPressed;
  expect(callback, isNotNull);
  return callback!;
}

void _denied(_Host host, int status) {
  expect(host.invocation.completed, isTrue);
  expect(host.invocation.failure,
      isA<ApiFailure>().having((error) => error.status, 'status', status));
  expect(host.session.requests, isEmpty);
  expect(find.byType(ManagedApplicationEvidenceDialog), findsNothing);
}

Future<void> _opened(WidgetTester tester, _Host host) async {
  host.open();
  await _settle(tester);
  expect(host.invocation.failure, isNull);
  expect(host.invocation.completed, isFalse);
  expect(find.byType(ManagedApplicationEvidenceDialog), findsOneWidget);
  expect(find.text(_privateName), findsOneWidget);
}

void main() {
  testWidgets('system back closes once without reentering navigator dispatch',
      (tester) async {
    final host = await _mount(tester);
    await _opened(tester, host);
    final oldClose = _callback(tester, const Key('managed-evidence-close'));
    final requestsBefore = host.session.requests.length;
    Object? navigationFailure;
    try {
      Navigator.of(host.context).pop<void>();
    } catch (failure) {
      navigationFailure = failure;
    }
    expect(navigationFailure, isNull,
        reason: 'A successful system pop must not request another pop.');
    await _settle(tester);
    expect(host.invocation.completed, isTrue);
    expect(host.invocation.failure, isNull);
    expect(find.byType(ManagedApplicationEvidenceDialog), findsNothing);
    expect(host.parent.refreshes, 0);
    expect(host.session.client.closed, isFalse);
    oldClose();
    await _settle(tester);
    expect(host.session.requests, hasLength(requestsBefore));
    expect(host.session.posts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final role in ['OWNER', 'ORG_ADMIN']) {
    testWidgets(
        '$role opens the verified association in its existing workspace',
        (tester) async {
      final host = await _mount(tester, _EntrySession()..role = role);
      await _opened(tester, host);
      expect(host.session.requests, hasLength(1));
      expect(host.session.requests.single.method, 'GET');
      expect(host.session.requests.single.url.path,
          '/api/v1/tenants/$bindingTenant/applications');
      await _tap(tester, const Key('managed-evidence-close'));
      expect(host.invocation.completed, isTrue);
      expect(host.invocation.failure, isNull);
      expect(host.session.client.closed, isFalse);
      expect(find.text('关联详情宿主'), findsOneWidget);
    });
  }

  for (final role in ['AUDITOR', 'GUARDIAN', 'TEACHER', 'CHILD']) {
    testWidgets('$role cannot read the application evidence directory',
        (tester) async {
      final host = await _mount(tester, _EntrySession()..role = role);
      host.open();
      await _settle(tester);
      _denied(host, 403);
    });
  }

  testWidgets(
      'unauthenticated caller is rejected before opening or HTTP lookup',
      (tester) async {
    final host =
        await _mount(tester, _EntrySession()..authenticatedValue = false);
    host.open();
    await _settle(tester);
    _denied(host, 401);
  });

  testWidgets(
      'family workspace does not expose institution application evidence',
      (tester) async {
    final session = _EntrySession()
      ..tenant = {'id': bindingTenant, 'kind': 'FAMILY'};
    final host = await _mount(tester, session);
    host.open();
    await _settle(tester);
    _denied(host, 403);
  });

  for (final state in ['PENDING', 'REVOKED', 'EXPIRED']) {
    testWidgets(
        '$state binding cannot establish an application evidence context',
        (tester) async {
      final host = await _mount(tester);
      host.open(target: host.binding(state: state, verifiedAt: false));
      await _settle(tester);
      _denied(host, 409);
    });
  }

  testWidgets('VERIFIED without a proof timestamp is rejected', (tester) async {
    final host = await _mount(tester);
    host.open(target: host.binding(verifiedAt: false));
    await _settle(tester);
    _denied(host, 409);
  });

  testWidgets('a stale parent never starts the directory request',
      (tester) async {
    final host = await _mount(tester);
    host.parent.current = false;
    host.open();
    await _settle(tester);
    _denied(host, 409);
  });

  testWidgets('an unmounted origin cannot open on the replacement navigator',
      (tester) async {
    final host = await _mount(tester);
    await tester.pumpWidget(const MaterialApp(home: Text('替代页面')));
    await _settle(tester);
    expect(host.context.mounted, isFalse);
    host.open();
    await _settle(tester);
    _denied(host, 409);
    expect(find.text('替代页面'), findsOneWidget);
  });

  for (final dimension in ['actor', 'tenant', 'role', 'generation']) {
    testWidgets(
        '$dimension scope change permanently disables an existing child',
        (tester) async {
      final host = await _mount(tester);
      await _opened(tester, host);
      await _tap(
          tester, const ValueKey('managed-evidence-application-$_application'));
      final primary = _callback(tester, const Key('managed-evidence-primary'));
      final count = host.session.requests.length;
      host.session.aba(dimension);
      primary();
      await _settle(tester);
      expect(find.text(_privateName), findsNothing);
      expect(find.textContaining('权限已变化'), findsOneWidget);
      expect(host.session.requests, hasLength(count));
      expect(host.session.posts, isEmpty);
      await _tap(tester, const Key('managed-evidence-close'));
      expect(host.invocation.completed, isTrue);
      expect(host.session.client.closed, isFalse);
    });
  }

  testWidgets('parent association ABA is observed before another frame',
      (tester) async {
    final host = await _mount(tester);
    await _opened(tester, host);
    await _tap(
        tester, const ValueKey('managed-evidence-application-$_application'));
    final primary = _callback(tester, const Key('managed-evidence-primary'));
    final count = host.session.requests.length;
    host.parent.aba();
    primary();
    await _settle(tester);
    expect(find.text(_privateName), findsNothing);
    expect(find.textContaining('权限已变化'), findsOneWidget);
    expect(host.session.requests, hasLength(count));
  });

  testWidgets(
      '412 closes the child before the explicit parent refresh callback',
      (tester) async {
    final host = await _mount(tester);
    await _opened(tester, host);
    await _tap(
        tester, const ValueKey('managed-evidence-application-$_application'));
    host.session.intercept = (request) async => request.method == 'POST'
        ? host.session
            .response({'errorCode': 'RESOURCE_VERSION_CONFLICT'}, status: 412)
        : null;
    await _tap(tester, const Key('managed-evidence-primary'));
    expect(host.parent.refreshes, 0);
    expect(find.textContaining('关联已变化'), findsOneWidget);
    final count = host.session.requests.length;
    await _tap(tester, const Key('managed-evidence-parent-refresh'));
    expect(host.parent.refreshes, 1);
    expect(host.parent.childActiveAtRefresh, isFalse);
    expect(host.invocation.completed, isTrue);
    expect(host.session.requests, hasLength(count));
    expect(host.session.posts.single.headers['If-Match'], '"3"');
  });

  testWidgets(
      'recent authentication is explicit without replaying the old POST',
      (tester) async {
    final host = await _mount(tester);
    await _opened(tester, host);
    await _tap(
        tester, const ValueKey('managed-evidence-application-$_application'));
    host.session.intercept = (request) async => request.method == 'POST'
        ? host.session.response({'errorCode': 'REAUTH_REQUIRED'}, status: 401)
        : null;
    await _tap(tester, const Key('managed-evidence-primary'));
    expect(host.session.loginSteps, isEmpty);
    await _tap(tester, const Key('managed-evidence-reauth'));
    expect(host.session.loginSteps, [true]);
    expect(host.session.posts, hasLength(1));
    expect(host.invocation.completed, isTrue);
    expect(host.session.client.closed, isFalse);
  });

  testWidgets(
      'covered reauthentication cannot take ownership of the visible notice',
      (tester) async {
    final host = await _mount(tester);
    await _opened(tester, host);
    await _tap(
        tester, const ValueKey('managed-evidence-application-$_application'));
    host.session.intercept = (request) async => request.method == 'POST'
        ? host.session.response({'errorCode': 'REAUTH_REQUIRED'}, status: 401)
        : null;
    await _tap(tester, const Key('managed-evidence-primary'));
    final callback = _callback(tester, const Key('managed-evidence-reauth'));
    unawaited(showDialog<void>(
        context: host.context,
        builder: (_) => const AlertDialog(title: Text('独立通知'))));
    await _settle(tester);
    final count = host.session.requests.length;
    callback();
    await _settle(tester);
    expect(host.session.loginSteps, isEmpty);
    expect(host.session.requests, hasLength(count));
    expect(find.text('独立通知'), findsOneWidget);
    expect(host.invocation.completed, isFalse);
  });

  testWidgets(
      'late evidence after scope loss is discarded and never resurrects data',
      (tester) async {
    final host = await _mount(tester);
    await _opened(tester, host);
    final response = Completer<http.Response>();
    addTearDown(() {
      if (!response.isCompleted) {
        response.complete(host.session.response(host.session.evidence()));
      }
    });
    host.session.intercept = (request) async =>
        request.url.path.endsWith('/evidence') ? response.future : null;
    await _tap(
        tester, const ValueKey('managed-evidence-application-$_application'));
    host.session.aba('actor');
    response.complete(host.session.response(host.session.evidence()));
    await _settle(tester);
    expect(find.text(_privateName), findsNothing);
    expect(find.text('尚未核验'), findsNothing);
    expect(find.textContaining('权限已变化'), findsOneWidget);
    expect(host.session.posts, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
