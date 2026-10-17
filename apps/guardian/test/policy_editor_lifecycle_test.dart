@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/scoped_http_client.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/editors.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/owned_dialog_route.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oauth2/oauth2.dart' as oauth;

const _tenant = '11111111-1111-4111-8111-111111111111';
const _otherTenant = '22222222-2222-4222-8222-222222222222';
const _policy = '33333333-3333-4333-8333-333333333333';
const _root = '/tenants/$_tenant';
const _name = '原工作空间策略草稿';

http.Response _reply(Object value, {int status = 200}) =>
    http.Response(jsonEncode(value), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

/// Authentication and scope are explicit fixture values. Transport, Api,
/// editor state and navigation are production implementations.
class _PolicySession extends Session {
  final Api editorApi;
  int generation = 1;
  bool signedIn = true;
  final validationRequests = <bool>[];

  _PolicySession(this.editorApi) {
    profile = {'subject': 'policy-owner'};
    tenant = {'id': _tenant, 'kind': 'ORGANIZATION'};
    role = 'OWNER';
  }

  @override
  Api get api => editorApi;
  @override
  bool get authenticated => signedIn && profile != null;
  @override
  int get scopeGeneration => generation;

  // Record explicit intent without completing authentication or changing scope.
  @override
  void login({bool stepUp = false}) => validationRequests.add(stepUp);

  void change(String dimension, {bool restore = false}) {
    switch (dimension) {
      case 'actor':
        profile = {'subject': restore ? 'policy-owner' : 'replacement-owner'};
      case 'tenant':
        tenant = {
          'id': restore ? _tenant : _otherTenant,
          'kind': 'ORGANIZATION',
        };
      case 'role':
        role = restore ? 'OWNER' : 'AUDITOR';
      case 'generation':
        generation++;
      case 'authentication':
        signedIn = restore;
    }
    notifyListeners();
  }
}

class _Fixture {
  final requests = <http.Request>[];
  Future<http.Response> Function(http.Request)? handler;
  Future<http.Client> Function()? lookup;
  late final transport = MockClient((request) async {
    requests.add(request);
    if (handler != null) return handler!(request);
    if (request.method == 'GET' && request.url.path.endsWith('/$_policy')) {
      return _reply(draft());
    }
    if (request.method == 'GET') {
      return _reply({'items': [], 'nextCursor': null});
    }
    return _reply(draft(revision: 8));
  });
  late final api = Api(() => lookup?.call() ?? Future.value(transport),
      baseUrl: 'https://policy-fixture.invalid/api/v1');
  late final session = _PolicySession(api);

  List<http.Request> get writes =>
      requests.where((request) => request.method != 'GET').toList();

  Json draft({int revision = 7, List<Json> rules = const []}) => {
        'id': _policy,
        'revision': revision,
        'name': _name,
        'kind': 'POLICY',
        'rules': rules,
      };
}

Future<void> _flush(WidgetTester tester) async {
  for (var frame = 0; frame < 8; frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

class _Opened {
  final BuildContext context;
  bool completed = false;
  Object? error;
  _Opened(this.context);
}

Future<_Opened> _mount(WidgetTester tester, _Fixture f,
    {bool wrapper = false,
    bool creating = false,
    Json? initialDraft,
    List<Json> applications = const []}) async {
  late BuildContext host;
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(body: Builder(builder: (context) {
        host = context;
        return const Text('策略编辑宿主');
      }))));
  final opened = _Opened(host);
  final draft = creating ? null : initialDraft ?? f.draft();
  final operation = wrapper
      ? policyEditor(host, f.session, draft: draft)
      : presentOwnedDialog<void>(
          host,
          OwnedDialogRoute<void>(
              context: host,
              barrierDismissible: false,
              builder: (_) => PolicyEditor(
                  session: f.session,
                  root: _root,
                  applications: applications,
                  schedules: const [],
                  draft: draft)));
  unawaited(operation.then<void>((_) => opened.completed = true,
      onError: (Object error, StackTrace _) {
    opened.error = error;
    opened.completed = true;
  }));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _flush(tester);
    f.transport.close();
    f.session.dispose();
  });
  await _flush(tester);
  await tester.pumpAndSettle();
  return opened;
}

VoidCallback _save(WidgetTester tester) => tester
    .widget<FilledButton>(find.widgetWithText(FilledButton, '保存草稿'))
    .onPressed!;

Future<void> _press(WidgetTester tester, String key) async {
  final target = find.byKey(Key(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await _flush(tester);
  await tester.pumpAndSettle();
}

Future<void> _requestTemporaryClose(WidgetTester tester) async {
  final close = find.byKey(const Key('policy-editor-close-unknown'));
  final target = close.evaluate().isNotEmpty
      ? close
      : find.widgetWithText(TextButton, '取消');
  await tester.ensureVisible(target);
  await tester.tap(target);
  await _flush(tester);
  await tester.pumpAndSettle();
}

void main() {
  for (final dimension in [
    'actor',
    'tenant',
    'role',
    'generation',
    'authentication'
  ]) {
    testWidgets('$dimension away and back permanently invalidates the editor',
        (tester) async {
      final f = _Fixture();
      await _mount(tester, f);
      final queued = _save(tester);

      f.session.change(dimension);
      f.session.change(dimension, restore: true);
      await _flush(tester);

      expect(find.byType(TextFormField), findsNothing,
          reason:
              'An old scope must redact the draft even after an ABA change.');
      expect(find.text('保存草稿'), findsNothing);
      queued();
      await _flush(tester);
      expect(f.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('wrapper rejects an actor ABA while reference lists are pending',
      (tester) async {
    final f = _Fixture();
    final pending = Completer<http.Response>();
    f.handler = (_) => pending.future;
    addTearDown(() {
      if (!pending.isCompleted) {
        pending.complete(_reply({'items': [], 'nextCursor': null}));
      }
    });
    final opened = await _mount(tester, f, wrapper: true);
    expect(f.requests.length, 2);

    f.session.change('actor');
    f.session.change('actor', restore: true);
    pending.complete(_reply({'items': [], 'nextCursor': null}));
    await _flush(tester);

    expect(find.byType(PolicyEditor), findsNothing);
    expect(opened.completed, isTrue);
    expect(f.writes, isEmpty);
  });

  testWidgets('scope loss while acquiring a client prevents the physical write',
      (tester) async {
    final f = _Fixture();
    final client = Completer<http.Client>();
    f.lookup = () => client.future;
    addTearDown(() {
      if (!client.isCompleted) client.complete(f.transport);
    });
    await _mount(tester, f);
    _save(tester)();
    await _flush(tester);
    expect(f.writes, isEmpty);

    f.session.change('generation');
    client.complete(f.transport);
    await _flush(tester);

    expect(f.writes, isEmpty);
    expect(find.byType(TextFormField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OAuth refresh retains the original scope at physical dispatch',
      (tester) async {
    final f = _Fixture();
    final refresh = Completer<http.Response>();
    final physicalWrites = <http.Request>[];
    var refreshes = 0;
    final physical = MockClient((request) async {
      if (request.url.path == '/token') {
        refreshes++;
        return refresh.future;
      }
      physicalWrites.add(request);
      return _reply(f.draft(revision: 8));
    });
    final authenticated = oauth.Client(
        oauth.Credentials('synthetic-expired-access',
            refreshToken: 'synthetic-refresh',
            tokenEndpoint: Uri.parse('https://policy-fixture.invalid/token'),
            expiration: DateTime.now().subtract(const Duration(minutes: 1))),
        identifier: 'policy-lifecycle-fixture',
        basicAuth: false,
        httpClient: ScopeGuardedClient(physical));
    f.lookup = () async => authenticated;
    addTearDown(() {
      if (!refresh.isCompleted) {
        refresh.complete(_reply({
          'access_token': 'synthetic-refreshed-access',
          'token_type': 'Bearer',
          'expires_in': 3600,
        }));
      }
      authenticated.close();
    });
    await _mount(tester, f);
    _save(tester)();
    await _flush(tester);
    expect(refreshes, 1);

    f.session.change('actor');
    f.session.change('actor', restore: true);
    refresh.complete(_reply({
      'access_token': 'synthetic-refreshed-access',
      'token_type': 'Bearer',
      'expires_in': 3600,
    }));
    await _flush(tester);

    expect(physicalWrites, isEmpty,
        reason:
            'The old write must not reach transport after credential refresh.');
    expect(tester.takeException(), isNull);
  });

  testWidgets('late success closes only its editor and completes the wrapper',
      (tester) async {
    final f = _Fixture();
    final response = Completer<http.Response>();
    f.handler = (request) async => request.method == 'GET'
        ? _reply({'items': [], 'nextCursor': null})
        : response.future;
    addTearDown(() {
      if (!response.isCompleted) {
        response.complete(_reply(f.draft(revision: 8)));
      }
    });
    final opened = await _mount(tester, f, wrapper: true);
    _save(tester)();
    await _flush(tester);
    expect(f.writes.length, 1);
    final notice = showDialog<void>(
        context: opened.context,
        builder: (context) => AlertDialog(
              title: const Text('独立通知'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭通知')),
              ],
            ));
    await _flush(tester);

    response.complete(_reply(f.draft(revision: 8)));
    await _flush(tester);

    expect(find.text('独立通知'), findsOneWidget);
    expect(find.byType(PolicyEditor, skipOffstage: false), findsNothing);
    expect(opened.completed, isTrue);
    expect(opened.error, isNull);
    await tester.tap(find.text('关闭通知'));
    await _flush(tester);
    await notice;
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending submission freezes the draft name', (tester) async {
    final f = _Fixture();
    final response = Completer<http.Response>();
    f.handler = (_) => response.future;
    await _mount(tester, f);
    try {
      _save(tester)();
      await _flush(tester);

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enabled == false || field.readOnly, isTrue,
          reason:
              'Changes typed after dispatch must not be silently discarded.');
    } finally {
      // Cancel the real Api timeout before testWidgets verifies timer cleanup.
      await tester.pumpWidget(const SizedBox.shrink());
      if (!response.isCompleted) {
        response.complete(_reply(f.draft(revision: 8)));
      }
      await _flush(tester);
      await tester.pumpAndSettle();
    }
  });

  testWidgets(
      'unknown save preserves body and key until explicit original retry',
      (tester) async {
    final f = _Fixture();
    f.handler = (request) async {
      if (f.writes.length == 1) throw http.ClientException('lost response');
      return _reply(f.draft(revision: 8));
    };
    await _mount(tester, f);
    final queued = _save(tester);
    queued();
    await _flush(tester);
    expect(f.writes.length, 1);
    final original = f.writes.single;

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled == false || field.readOnly, isTrue);
    expect(find.text('保存草稿'), findsNothing);
    queued();
    await _flush(tester);
    expect(f.writes.length, 1,
        reason:
            'A retained ordinary save callback cannot replay an unknown write.');

    await _press(tester, 'policy-editor-retry-original');

    expect(f.writes.length, 2);
    expect(f.writes.last.body, original.body);
    expect(f.writes.last.headers['Idempotency-Key'],
        original.headers['Idempotency-Key']);
    expect(f.writes.last.headers['If-Match'], original.headers['If-Match']);
    expect(find.byType(PolicyEditor), findsNothing);
  });

  testWidgets('read check keeps an old revision unknown and never resubmits',
      (tester) async {
    final f = _Fixture();
    f.handler = (request) async {
      if (request.method != 'GET') throw http.ClientException('lost response');
      return _reply(f.draft());
    };
    await _mount(tester, f);
    _save(tester)();
    await _flush(tester);

    expect(find.byKey(const Key('policy-editor-check-result')), findsOneWidget);
    await _press(tester, 'policy-editor-check-result');

    expect(f.writes.length, 1);
    expect(f.requests.last.method, 'GET');
    expect(f.requests.last.url.path, '/api/v1$_root/policies/$_policy');
    expect(
        find.byKey(const Key('policy-editor-retry-original')), findsOneWidget);
    expect(find.text('保存草稿'), findsNothing);
  });

  testWidgets('scope loss also revokes a retained original retry callback',
      (tester) async {
    final f = _Fixture();
    f.handler = (_) async => throw http.ClientException('lost response');
    await _mount(tester, f);
    _save(tester)();
    await _flush(tester);
    expect(
        find.byKey(const Key('policy-editor-retry-original')), findsOneWidget);
    final retry = tester
        .widget<OutlinedButton>(
            find.byKey(const Key('policy-editor-retry-original')))
        .onPressed!;

    f.session.change('role');
    f.session.change('role', restore: true);
    await _flush(tester);
    retry();
    await _flush(tester);

    expect(f.writes.length, 1);
    expect(find.byType(TextFormField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final status in [401, 403]) {
    testWidgets('directory $status stops another pending directory page',
        (tester) async {
      final f = _Fixture();
      final page = Completer<http.Response>();
      final denied = Completer<http.Response>();
      f.handler = (request) async {
        if (request.url.path.endsWith('/applications')) {
          return denied.future;
        }
        if (request.url.queryParameters['cursor'] == 'forbidden-next') {
          return _reply({'items': [], 'nextCursor': null});
        }
        return page.future;
      };
      addTearDown(() {
        if (!denied.isCompleted) {
          denied
              .complete(_reply({'errorCode': 'ACCESS_DENIED'}, status: status));
        }
        if (!page.isCompleted) {
          page.complete(_reply({'items': [], 'nextCursor': null}));
        }
      });
      final opened = await _mount(tester, f, wrapper: true);
      expect(f.requests.length, 2);

      denied.complete(_reply({'errorCode': 'ACCESS_DENIED'}, status: status));
      await _flush(tester);
      page.complete(_reply({'items': [], 'nextCursor': 'forbidden-next'}));
      await _flush(tester);

      expect(f.requests.length, 2,
          reason:
              'A denied directory must revoke the shared read scope at once.');
      expect(opened.completed, isTrue);
      expect(find.byType(PolicyEditor), findsNothing);
      expect(f.writes, isEmpty);
    });
  }

  testWidgets('retained delete callback is inert after a role ABA',
      (tester) async {
    final f = _Fixture();
    await _mount(tester, f,
        initialDraft: f.draft(rules: [
          {
            'id': 'domain_rule',
            'kind': 'DOMAIN_ACCESS',
            'effect': 'DENY',
            'required': true,
            'domain': 'example.com'
          },
        ]));
    final remove = tester
        .widget<IconButton>(find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == '删除规则'))
        .onPressed!;
    f.session.change('role');
    f.session.change('role', restore: true);
    await _flush(tester);

    expect(remove, returnsNormally);
    await _flush(tester);

    expect(f.writes, isEmpty);
    expect(find.byType(TextFormField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read check recognizes server nullable rule fields',
      (tester) async {
    final f = _Fixture();
    final rule = <String, dynamic>{
      'id': 'domain_rule',
      'kind': 'DOMAIN_ACCESS',
      'effect': 'DENY',
      'required': true,
      'domain': 'example.com',
    };
    f.handler = (request) async {
      if (request.method != 'GET') throw http.ClientException('lost response');
      return _reply(f.draft(revision: 8, rules: [
        {
          ...rule,
          'applicationId': null,
          'scheduleId': null,
          'seconds': null,
          'permission': null,
        }
      ]));
    };
    await _mount(tester, f, initialDraft: f.draft(rules: [rule]));
    _save(tester)();
    await _flush(tester);

    await _press(tester, 'policy-editor-check-result');

    expect(f.writes.length, 1);
    expect(find.byType(PolicyEditor), findsNothing,
        reason: 'Nullable record fields represent the same submitted rules.');
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid success projection preserves the unknown original',
      (tester) async {
    final f = _Fixture();
    f.handler = (_) async => _reply({});
    await _mount(tester, f);
    final queued = _save(tester);
    queued();
    await _flush(tester);

    expect(find.byType(PolicyEditor), findsOneWidget,
        reason:
            'A successful status without a draft cannot prove a saved result.');
    expect(
        find.byKey(const Key('policy-editor-retry-original')), findsOneWidget);
    queued();
    await _flush(tester);
    expect(f.writes.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'revision conflict after original retry still permits a read check',
      (tester) async {
    final f = _Fixture();
    f.handler = (request) async {
      if (request.method == 'GET') return _reply(f.draft(revision: 8));
      if (f.writes.length == 1) throw http.ClientException('lost response');
      return _reply({'errorCode': 'REVISION_MISMATCH'}, status: 412);
    };
    await _mount(tester, f);
    _save(tester)();
    await _flush(tester);
    final original = f.writes.single;

    await _press(tester, 'policy-editor-retry-original');

    expect(find.text('保存草稿'), findsNothing);
    expect(find.byKey(const Key('policy-editor-check-result')), findsOneWidget);
    expect(f.writes.length, 2);
    expect(f.writes.last.body, original.body);
    expect(f.writes.last.headers['If-Match'], original.headers['If-Match']);
    await _press(tester, 'policy-editor-check-result');
    expect(f.writes.length, 2);
    expect(find.byType(PolicyEditor), findsNothing);
  });

  testWidgets('unknown creation recovers only its original body and key',
      (tester) async {
    final f = _Fixture();
    f.handler = (_) async {
      if (f.writes.length == 1) throw http.ClientException('lost response');
      return _reply(f.draft(revision: 0));
    };
    await _mount(tester, f, creating: true);
    final chooseKind = tester
        .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>))
        .onChanged!;
    await tester.enterText(find.widgetWithText(TextFormField, '策略名称'), _name);
    _save(tester)();
    await _flush(tester);
    final original = f.writes.single;
    expect(jsonDecode(original.body)['kind'], 'POLICY');
    expect(find.byKey(const Key('policy-editor-check-result')), findsNothing);
    chooseKind('TEMPLATE');
    await _flush(tester);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(
                find.byType(DropdownButtonFormField<String>))
            .initialValue,
        'POLICY',
        reason: 'A retained type callback must not alter an unknown snapshot.');

    await _press(tester, 'policy-editor-retry-original');

    expect(f.writes.length, 2);
    expect(f.writes.last.body, original.body);
    expect(f.writes.last.headers['Idempotency-Key'],
        original.headers['Idempotency-Key']);
    expect(find.byType(PolicyEditor), findsNothing);
  });

  testWidgets('retained rule type callback cannot pop an independent notice',
      (tester) async {
    final f = _Fixture();
    final opened = await _mount(tester, f);
    await tester.tap(find.text('添加规则'));
    await _flush(tester);
    final select = tester
        .widget<SimpleDialogOption>(
            find.widgetWithText(SimpleDialogOption, '域名访问'))
        .onPressed!;
    f.session.change('actor');
    f.session.change('actor', restore: true);
    await _flush(tester);
    unawaited(showDialog<void>(
        context: opened.context,
        builder: (_) => const AlertDialog(title: Text('规则外独立通知'))));
    await _flush(tester);

    select();
    await _flush(tester);

    expect(find.text('规则外独立通知'), findsOneWidget);
    expect(find.byType(EditDialog, skipOffstage: false), findsNothing);
    expect(f.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late permission metadata cannot reopen a revoked rule editor',
      (tester) async {
    final f = _Fixture();
    final metadata = Completer<http.Response>();
    f.handler = (_) => metadata.future;
    const application = '44444444-4444-4444-8444-444444444444';
    addTearDown(() {
      if (!metadata.isCompleted) metadata.complete(_reply({}));
    });
    await _mount(tester, f,
        applications: const [
          {'id': application, 'displayName': '相机应用'},
        ],
        initialDraft: f.draft(rules: [
          {
            'id': 'camera_rule',
            'kind': 'RUNTIME_PERMISSION',
            'effect': 'DENY',
            'required': true,
            'applicationId': application,
            'permission': 'android.permission.CAMERA'
          },
        ]));
    final save = _save(tester);
    await tester.ensureVisible(find.byTooltip('编辑规则'));
    await tester.tap(find.byTooltip('编辑规则'));
    await _flush(tester);
    expect(f.requests.single.url.path,
        '/api/v1/policy-metadata/android-runtime-permissions');
    f.session.change('generation');
    metadata.complete(_reply({
      'schemaVersion': 2,
      'permissions': ['android.permission.CAMERA'],
      'editableEffects': ['DEFAULT', 'DENY'],
    }));
    await _flush(tester);
    save();
    await _flush(tester);

    expect(find.byType(EditDialog, skipOffstage: false), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    expect(f.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown close asks before leaving the original submission',
      (tester) async {
    final f = _Fixture();
    f.handler = (request) async {
      if (request.method == 'GET') {
        return _reply({'items': [], 'nextCursor': null});
      }
      throw http.ClientException('lost response');
    };
    final opened = await _mount(tester, f, wrapper: true);
    _save(tester)();
    await _flush(tester);

    await _requestTemporaryClose(tester);

    expect(find.byType(PolicyEditor, skipOffstage: false), findsOneWidget,
        reason: 'Leaving must first explain how to avoid a duplicate draft.');
    expect(find.textContaining('核对策略列表'), findsOneWidget);
    await _press(tester, 'policy-editor-keep-unknown');
    expect(
        find.byKey(const Key('policy-editor-retry-original')), findsOneWidget);
    expect(opened.completed, isFalse);
    await _requestTemporaryClose(tester);
    await _press(tester, 'policy-editor-confirm-close-unknown');

    expect(find.byType(PolicyEditor, skipOffstage: false), findsNothing);
    expect(opened.completed, isTrue);
    expect(f.writes.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system back asks before leaving an unknown submission',
      (tester) async {
    final f = _Fixture();
    f.handler = (_) async => throw http.ClientException('lost response');
    final opened = await _mount(tester, f);
    _save(tester)();
    await _flush(tester);

    await Navigator.of(opened.context, rootNavigator: true).maybePop();
    await _flush(tester);

    expect(find.byType(PolicyEditor, skipOffstage: false), findsOneWidget,
        reason:
            'System back must preserve the original until exit is confirmed.');
    expect(find.byKey(const Key('policy-editor-confirm-close-unknown')),
        findsOneWidget);
    await _press(tester, 'policy-editor-keep-unknown');
    expect(
        find.byKey(const Key('policy-editor-retry-original')), findsOneWidget);
    expect(f.writes.length, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scope loss invalidates a retained unknown exit confirmation',
      (tester) async {
    final f = _Fixture();
    f.handler = (_) async => throw http.ClientException('lost response');
    final opened = await _mount(tester, f);
    _save(tester)();
    await _flush(tester);
    await _requestTemporaryClose(tester);
    final confirm =
        find.byKey(const Key('policy-editor-confirm-close-unknown'));
    expect(confirm, findsOneWidget);
    final queued = tester.widget<TextButton>(confirm).onPressed!;
    f.session.change('role');
    f.session.change('role', restore: true);
    await _flush(tester);
    unawaited(showDialog<void>(
        context: opened.context,
        builder: (_) => const AlertDialog(title: Text('退出确认外独立通知'))));
    await _flush(tester);

    queued();
    await _flush(tester);

    expect(find.text('退出确认外独立通知'), findsOneWidget);
    expect(find.byKey(const Key('policy-editor-confirm-close-unknown')),
        findsNothing);
    expect(find.byType(TextFormField, skipOffstage: false), findsNothing);
    expect(f.writes.length, 1);
    expect(tester.takeException(), isNull);
  });

  for (final entry in <String, Json>{
    'non-string errorCode': {
      'errorCode': 403,
      'correlationId': 'synthetic-denied-response',
    },
    'non-string correlationId': {
      'errorCode': 'ACCESS_DENIED',
      'correlationId': {'id': 'synthetic-denied'},
    },
    'non-string errorCode and correlationId': {
      'errorCode': ['ACCESS_DENIED'],
      'correlationId': false,
    },
  }.entries) {
    testWidgets('hard 403 ${entry.key} revokes retained editor retries',
        (tester) async {
      final f = _Fixture();
      f.handler = (_) async {
        if (f.writes.length == 1) throw http.ClientException('lost response');
        return _reply(entry.value, status: 403);
      };
      await _mount(tester, f);
      final ordinarySave = _save(tester);
      ordinarySave();
      await _flush(tester);
      final retryFinder = find.byKey(const Key('policy-editor-retry-original'));
      expect(retryFinder, findsOneWidget);
      final retry = tester.widget<OutlinedButton>(retryFinder).onPressed!;
      await _press(tester, 'policy-editor-retry-original');
      expect(f.writes.length, 2);
      final redacted = find.byType(TextFormField).evaluate().isEmpty;
      final recoveryRemoved = retryFinder.evaluate().isEmpty;

      retry();
      ordinarySave();
      await _flush(tester);

      expect({
        'privateDraftRedacted': redacted,
        'recoveryRemoved': recoveryRemoved,
        'physicalWrites': f.writes.length,
      }, {
        'privateDraftRedacted': true,
        'recoveryRemoved': true,
        'physicalWrites': 2,
      },
          reason: 'An HTTP denial must remain terminal even if its JSON fields '
              'cannot be used as error text.');
      expect(f.session.validationRequests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final correlationId in <Object>['synthetic-step-up', 401]) {
    final shape = correlationId is String ? 'string' : 'non-string';
    testWidgets(
        '401 REAUTH_REQUIRED with $shape correlation keeps explicit validation',
        (tester) async {
      final f = _Fixture();
      f.handler = (_) async {
        if (f.writes.length == 1) throw http.ClientException('lost response');
        return _reply({
          'errorCode': 'REAUTH_REQUIRED',
          'correlationId': correlationId,
        }, status: 401);
      };
      await _mount(tester, f);
      _save(tester)();
      await _flush(tester);
      final original = f.writes.single;
      await _press(tester, 'policy-editor-retry-original');

      expect(f.writes.length, 2);
      expect(f.session.validationRequests, isEmpty,
          reason: 'A response must not start authentication on its own.');
      expect(find.byType(TextFormField), findsOneWidget);
      expect(find.byKey(const Key('policy-editor-retry-original')),
          findsOneWidget);
      final validate = find.widgetWithText(TextButton, '重新安全验证');
      expect(validate, findsOneWidget);
      await tester.ensureVisible(validate);
      await tester.tap(validate);
      await _flush(tester);

      expect(f.session.validationRequests, [true]);
      expect(f.writes.length, 2,
          reason: 'Explicit validation must not replay the pending write.');
      expect(f.writes.last.body, original.body);
      expect(f.writes.last.headers['Idempotency-Key'],
          original.headers['Idempotency-Key']);
      expect(f.writes.last.headers['If-Match'], original.headers['If-Match']);
      expect(tester.takeException(), isNull);
    });
  }
}
