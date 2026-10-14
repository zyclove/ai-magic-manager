import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/access_decision.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/core/pending_decisions.dart';
import 'package:parent/ui/access_decision_page.dart';
import 'package:parent/ui/access_history.dart';
import 'package:parent/main.dart';

const id = '11111111-1111-4111-8111-111111111111';
const device = '22222222-2222-4222-8222-222222222222';
Json request(
        {int version = 0,
        String state = 'PENDING',
        int? grant,
        String? reason}) =>
    {
      'id': id,
      'subjectId': id,
      'deviceId': device,
      'registrationId': id,
      'policyId': id,
      'baseVersionId': id,
      'applicationId': id,
      'version': version,
      'state': state,
      'requestedWindowSeconds': 600,
      'subjectName': '小禾',
      'deviceName': '学习平板',
      'applicationName': '阅读',
      'applicationPackageName': 'org.example.reader',
      'reason': '完成阅读作业',
      if (grant != null) ...{
        'grantedWindowSeconds': grant,
        'issuedAt': 1000000,
        'absoluteNotAfter': 1000000 + grant * 1000
      },
      if (reason != null) 'reasonCode': reason
    };
http.Response reply(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status,
        headers: {'content-type': 'application/json'});
ParentApi api(Future<http.Response> Function(http.Request) action,
        {Future<String> Function()? token}) =>
    ParentApi(token ?? () async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1', client: MockClient(action));

class Storage extends ParentDurableStorage {
  final values = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
    if (fail) throw StateError('flush failed');
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

ParentAccessDecision controller(ParentApi a, Storage s,
        {bool Function()? current,
        bool Function()? foreground,
        Future<bool> Function()? reauth}) =>
    ParentAccessDecision(
        api: a,
        store: PendingDecisionStore(storage: s),
        tenant: id,
        actor: 'adult',
        requestId: id,
        isCurrent: current ?? () => true,
        foreground: foreground ?? () => true,
        reauthenticate: reauth ?? () async => true);

class Session extends ParentSession {
  final ParentApi fixture;
  Session(this.fixture) {
    tenant = {'id': id};
    profile = {'subject': 'adult'};
    role = 'GUARDIAN';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  @override
  Future<bool> reauthenticate() async => true;
  void revoke() {
    role = 'AUDITOR';
    notifyListeners();
  }
}

void main() {
  testWidgets('approval tab and detail share the same bounded decision form',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.aimanager.parent/storage'),
            (_) async => true);
    var writes = 0;
    final session = Session(api((r) async {
      if (r.method == 'POST') {
        writes++;
        expect(jsonDecode(r.body)['grantedWindowSeconds'], 300);
        return reply(request(
            version: 1, state: 'APPROVED_PENDING_DELIVERY', grant: 300));
      }
      if (r.url.path.endsWith('/access-requests/$id')) return reply(request());
      if (r.url.path.endsWith('/access-requests')) {
        return reply({
          'items': [request()],
          'nextCursor': null
        });
      }
      if (r.url.path.endsWith('/unread-count')) {
        return reply({'count': 0, 'capped': false});
      }
      return reply({'items': [], 'nextCursor': null});
    }))
      ..ready = true;
    await tester.pumpWidget(ParentApp(session: session));
    await tester.pumpAndSettle();
    await tester.tap(find.text('申请'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '批准'));
    await tester.pumpAndSettle();
    expect(find.text('处理访问申请'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 分钟').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('access-decision-submit')));
    await tester.tap(find.byKey(const Key('access-decision-submit')));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.text('审批决定已保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  for (final choice in ['APPROVE', 'DENY']) {
    test('$choice persists original choice before POST and validates receipt',
        () async {
      final s = Storage();
      var writes = 0;
      final c = controller(api((r) async {
        if (r.method == 'GET') return reply(request());
        writes++;
        final body = jsonDecode(r.body);
        final stored = await PendingDecisionStore(storage: s).load(id, 'adult');
        expect(stored.single.choice, choice);
        expect(r.headers['If-Match'], '"0"');
        expect(stored.single.idempotencyKey, r.headers['Idempotency-Key']);
        expect(stored.single.grantedWindowSeconds,
            choice == 'APPROVE' ? 300 : null);
        expect(
            body,
            choice == 'APPROVE'
                ? {'decision': 'APPROVE', 'grantedWindowSeconds': 300}
                : {'decision': 'DENY', 'reasonCode': 'NOT_ALLOWED'});
        return reply(request(
            version: 1,
            state: choice == 'APPROVE' ? 'APPROVED_PENDING_DELIVERY' : 'DENIED',
            grant: choice == 'APPROVE' ? 300 : null,
            reason: choice == 'DENY' ? 'NOT_ALLOWED' : null));
      }), s);
      await c.load();
      await c.execute(
          choice: choice,
          seconds: choice == 'APPROVE' ? 300 : null,
          reason: choice == 'DENY' ? 'NOT_ALLOWED' : null);
      expect(c.error, isNull);
      expect(c.receipt, isNotNull);
      expect(c.pending, isNull);
      expect(writes, 1);
      expect(s.values, isEmpty);
      c.dispose();
    });
  }
  test('oversized duration is blocked before MFA or write', () async {
    var auth = 0, writes = 0;
    final c = controller(
        api((r) async {
          if (r.method == 'POST') writes++;
          return reply(request());
        }),
        Storage(),
        reauth: () async {
          auth++;
          return true;
        });
    await c.load();
    await c.execute(choice: 'APPROVE', seconds: 601);
    expect(auth, 0);
    expect(writes, 0);
    expect(c.error, isA<FormatException>());
    c.dispose();
  });
  test('cancelled MFA leaves no pending marker or submission', () async {
    final s = Storage();
    var writes = 0;
    final c = controller(api((r) async {
      if (r.method == 'POST') writes++;
      return reply(request());
    }), s, reauth: () async => false);
    await c.load();
    await c.execute(choice: 'DENY', reason: 'NOT_NOW');
    expect(writes, 0);
    expect(s.values, isEmpty);
    c.dispose();
  });
  test('changed request version after MFA prevents POST', () async {
    var reads = 0, writes = 0;
    final c = controller(api((r) async {
      if (r.method == 'POST') writes++;
      return reply(request(version: reads++ == 0 ? 0 : 1));
    }), Storage());
    await c.load();
    await c.execute(choice: 'APPROVE', seconds: 300);
    expect(writes, 0);
    expect(c.error, isA<ParentApiException>());
    c.dispose();
  });
  test('unconfirmed disk flush stops POST and preserves stored reference',
      () async {
    final s = Storage()..fail = true;
    var writes = 0;
    final c = controller(api((r) async {
      if (r.method == 'POST') writes++;
      return reply(request());
    }), s);
    await c.load();
    await c.execute(choice: 'DENY', reason: 'NOT_NOW');
    expect(writes, 0);
    expect(s.values, isNotEmpty);
    c.dispose();
  });
  test('lost approval response recovers read-only across controller recreation',
      () async {
    final s = Storage();
    var writes = 0, approved = false;
    final a = api((r) async {
      if (r.method == 'POST') {
        writes++;
        approved = true;
        throw http.ClientException('lost');
      }
      return reply(approved
          ? request(version: 1, state: 'APPROVED_PENDING_DELIVERY', grant: 300)
          : request());
    });
    final c = controller(a, s);
    await c.load();
    await c.execute(choice: 'APPROVE', seconds: 300);
    expect(c.pending, isNotNull);
    c.dispose();
    final resumed = controller(a, s);
    await resumed.load();
    expect(resumed.queried, isTrue);
    expect(resumed.request!['state'], 'APPROVED_PENDING_DELIVERY');
    expect(resumed.receipt, isNull);
    await resumed.execute(choice: 'DENY', reason: 'OTHER');
    expect(writes, 1);
    expect(await resumed.acknowledge(), isTrue);
    expect(s.values, isEmpty);
    resumed.dispose();
  });
  test('malformed successful receipt retains marker without claiming saved',
      () async {
    final c = controller(
        api((r) async => reply(r.method == 'POST'
            ? request(
                version: 1, state: 'APPROVED_PENDING_DELIVERY', grant: 600)
            : request())),
        Storage());
    await c.load();
    await c.execute(choice: 'APPROVE', seconds: 300);
    expect(c.receipt, isNull);
    expect(c.pending, isNotNull);
    expect(c.error, isNotNull);
    c.dispose();
  });
  test('role change during token acquisition blocks write dispatch', () async {
    var current = true, writes = 0;
    var gets = 0;
    final gate = Completer<String>();
    final a = api((r) async {
      if (r.method == 'POST') writes++;
      return reply(request());
    }, token: () {
      gets++;
      return gets == 3 ? gate.future : Future.value('fixture');
    });
    final c = controller(a, Storage(), current: () => current);
    await c.load();
    final work = c.execute(choice: 'DENY', reason: 'OTHER');
    await Future<void>.delayed(Duration.zero);
    current = false;
    gate.complete('fixture');
    await work;
    expect(writes, 0);
    c.dispose();
  });
  test(
      'legacy markers remain readable, malformed optional decisions are rejected',
      () {
    final old = {
      'requestId': id,
      'version': 0,
      'idempotencyKey': device,
      'choice': 'APPROVE',
      'createdAt': 1
    };
    expect(PendingDecision.fromJson(old), isNotNull);
    expect(PendingDecision.fromJson({...old, 'grantedWindowSeconds': 3601}),
        isNull);
    expect(PendingDecision.fromJson({...old, 'reasonCode': 'OTHER'}), isNull);
  });
  testWidgets('current request detail offers direct adult processing',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.aimanager.parent/storage'),
            (_) async => true);
    final session =
        Session(api((r) async => reply(r.url.path.endsWith('/delivery')
            ? {
                'requestId': id,
                'approvalVersion': 0,
                'deliveryState': 'PENDING',
                'executionState': 'NOT_ENFORCED'
              }
            : request())));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () => showAccessRequestDetail(ctx, session, id),
                    child: const Text('打开详情'))))));
    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('现在处理申请'), 180,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('现在处理申请'));
    await tester.pumpAndSettle();
    expect(find.text('处理访问申请'), findsOneWidget);
    expect(find.text('安全验证并批准'), findsOneWidget);
    expect(tester.takeException(), isNull);
    session.revoke();
    await tester.pumpAndSettle();
    expect(find.text('打开详情'), findsOneWidget);
    expect(find.text('处理访问申请'), findsNothing);
    expect(find.text('申请与交付状态'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('background hides request and revoked adult loses decision route',
      (tester) async {
    final session = Session(api((r) async => reply(request())));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                        builder: (_) => AccessDecisionPage(
                            session: session,
                            requestId: id,
                            store: PendingDecisionStore(storage: Storage())))),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('小禾 · 阅读'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('小禾 · 阅读'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('重新读取申请'), findsOneWidget);
    session.revoke();
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
  });
  testWidgets('approval form supports large text on a phone', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const font = String.fromEnvironment('UI_CAPTURE_FONT'),
        icons = String.fromEnvironment('UI_CAPTURE_ICONS');
    for (final e
        in {'LocalCaptureFont': font, 'MaterialIcons': icons}.entries) {
      if (e.value.isNotEmpty) {
        await tester.runAsync(() async {
          final data = await File(e.value).readAsBytes();
          await (FontLoader(e.key)
                ..addFont(Future.value(ByteData.sublistView(data))))
              .load();
        });
      }
    }
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
                useMaterial3: true,
                colorSchemeSeed: const Color(0xFF315E86),
                fontFamily: font.isEmpty ? null : 'LocalCaptureFont'),
            builder: (ctx, child) => MediaQuery(
                data: MediaQuery.of(ctx)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!),
            home: AccessDecisionPage(
                session: Session(api((r) async => reply(request()))),
                requestId: id,
                store: PendingDecisionStore(storage: Storage())))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_DECISION_UI')) {
      await tester.runAsync(() async {
        final img = await (key.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        await File('../../.local/access-decision.png')
            .writeAsBytes(data!.buffer.asUint8List());
        img.dispose();
      });
    }
  });
}
