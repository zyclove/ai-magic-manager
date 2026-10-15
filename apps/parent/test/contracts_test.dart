import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/contracts.dart';
import 'package:parent/core/commercial_entitlements.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/contracts_center.dart';
import 'package:parent/ui/commercial_account.dart';
import 'contract_fixture.dart';

http.Response response(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status);
ParentApi api(Future<http.Response> Function(http.Request) handler) =>
    ParentApi(() => Future.value('fixture'),
        baseUrl: 'https://fixture.invalid/api/v1', client: MockClient(handler));
Json rights(String id, {int capacity = 25}) => {
      'tenantId': id,
      'technicalCapabilityIndependent': true,
      'version': 1,
      'evaluatedAt': 100,
      'activeSourceCount': 1,
      'baseDeviceCapacity': capacity,
      'addOnDeviceCapacity': 0,
      'paidDeviceCapacity': capacity,
      'features': ['ORG_BULK']
    };

class Storage extends ParentDurableStorage {
  final values = <String, String>{};
  bool fail = false;
  Completer<void>? wait;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    if (fail) throw StateError('disk');
    values[key] = value;
    await wait?.future;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

ContractAcceptance operation(ParentApi api, Storage store,
        {bool Function()? active}) =>
    ContractAcceptance(
        repository: ParentContractsRepository(
            api: api, tenant: tenant, current: active ?? () => true),
        store: ContractAcceptanceStore(storage: store),
        actor: 'owner',
        isCurrent: active ?? () => true);

class Session extends ParentSession {
  final ParentApi fixture;
  Session(this.fixture, {String grant = 'OWNER'}) {
    profile = {'subject': 'owner', 'name': '陈老师'};
    this.tenant = {
      'id': tenantId,
      'kind': 'ORGANIZATION',
      'name': '晨光学校',
      'version': 0
    };
    role = grant;
    ready = true;
  }
  static const tenantId = tenant;
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  void switchTenant(String id) {
    this.tenant = {...this.tenant!, 'id': id};
    generation++;
    notifyListeners();
  }
}

void main() {
  test(
      'shared protocol rejects platform identities impossible dates and unknown features',
      () {
    expect(
        () => ParentCommercialEntitlements.parse(
            {...rights(tenant), 'evaluatedAt': 9007199254740991}, tenant),
        throwsA(isA<ParentApiException>()));
    for (final raw in [
      review(platform: true),
      {...review(), 'expiresAt': 9007199254740991},
      {...review(), 'version': 9007199254740992},
      {
        ...review(),
        'features': ['UNKNOWN']
      }
    ]) {
      expect(() => ContractReview.parse(raw, platform: false),
          throwsA(isA<ContractProtocolException>()));
    }
    expect(
        () => ContractHistoryPage.parse({
              'items': [
                {
                  'version': 1,
                  'action': 'APPROVED',
                  'occurredAt': 1,
                  'actorId': 'private'
                }
              ],
              'nextBeforeVersion': null
            }, platform: false),
        throwsA(isA<ContractProtocolException>()));
  });
  test('repository binds detail comparison and history to selected contract',
      () async {
    final repo = ParentContractsRepository(
        api: api((r) async {
          if (r.url.path.endsWith('/comparison')) {
            return response({...comparison(), 'reviewVersion': 2});
          }
          if (r.url.path.endsWith('/history')) {
            return response({
              'items': [
                {'version': 5, 'action': 'APPROVED', 'occurredAt': 2}
              ],
              'nextBeforeVersion': null
            });
          }
          return response({...review(), 'tenantId': offerId});
        }),
        tenant: tenant,
        current: () => true);
    await expectLater(repo.get(reviewId), throwsA(isA<ParentApiException>()));
    await expectLater(
        repo.comparison(ContractReview.parse(review(), platform: false)),
        throwsA(isA<ParentApiException>()));
    await expectLater(
        repo.history(reviewId, before: 5), throwsA(isA<ParentApiException>()));
  });
  test(
      'lost acceptance response recovers current state without repeating write',
      () async {
    final store = Storage();
    int writes = 0;
    final client = api((r) async {
      if (r.method == 'POST') {
        writes++;
        expect(r.headers['If-Match'], '"1"');
        expect(store.values.values.single, contains(reviewId));
        throw http.ClientException('lost');
      }
      return response(review(state: 'APPLIED', version: 2));
    });
    var op = operation(client, store);
    await op.load();
    await op.submit(ContractReview.parse(review(), platform: false),
        ContractComparison.parse(comparison()));
    expect(op.pending, isNotNull);
    expect(op.queried, false);
    expect(store.values.values.single, isNot(contains('CN-2026')));
    op.dispose();
    op = operation(client, store);
    await op.load();
    expect(writes, 1);
    await op.recover();
    expect(op.latest!.state, 'APPLIED');
    expect(writes, 1);
    expect(await op.clear(), true);
    expect(store.values, isEmpty);
    op.dispose();
  });
  test(
      'pending current state requires clearing and fresh preview before another confirmation',
      () async {
    final store = Storage();
    int writes = 0;
    final op = operation(api((r) async {
      if (r.method == 'POST') {
        writes++;
        return response({'errorCode': 'REAUTH_REQUIRED'}, 401);
      }
      return response(review());
    }), store);
    await op.load();
    await op.submit(ContractReview.parse(review(), platform: false),
        ContractComparison.parse(comparison()));
    await op.recover();
    expect(op.latest!.state, 'AWAITING_CUSTOMER');
    await op.submit(ContractReview.parse(review(), platform: false),
        ContractComparison.parse(comparison()));
    expect(writes, 1);
    expect(await op.clear(), true);
    expect(op.pending, isNull);
    op.dispose();
  });
  test('invalid comparison or revoked contract never sends acceptance',
      () async {
    final store = Storage();
    int writes = 0;
    final op = operation(api((r) async {
      writes++;
      return response({});
    }), store);
    await op.load();
    await op.submit(ContractReview.parse(review(), platform: false),
        ContractComparison.parse(comparison(match: false)));
    expect(writes, 0);
    expect(store.values, isEmpty);
    await op.load();
    await op.submit(
        ContractReview.parse(review(state: 'APPLIED', sourceState: 'REVOKED'),
            platform: false),
        ContractComparison.parse(comparison()));
    expect(writes, 0);
    op.dispose();
  });
  test('storage failure and foreground loss during save block confirmation',
      () async {
    final store = Storage()..fail = true;
    int writes = 0;
    final op = operation(api((r) async {
      writes++;
      return response(review(state: 'APPLIED', version: 2));
    }), store);
    await op.load();
    await op.submit(ContractReview.parse(review(), platform: false),
        ContractComparison.parse(comparison()));
    expect(writes, 0);
    store.fail = false;
    store.wait = Completer<void>();
    await op.load();
    final work = op.submit(ContractReview.parse(review(), platform: false),
        ContractComparison.parse(comparison()));
    await Future<void>.delayed(Duration.zero);
    op.suspend();
    store.wait!.complete();
    await work;
    expect(writes, 0);
    expect(op.loaded, false);
    op.dispose();
  });
  test('foreground loss during token refresh blocks delayed write', () async {
    final token = Completer<String>();
    int writes = 0;
    final client =
        ParentApi(() => token.future, baseUrl: 'https://fixture.invalid/api/v1',
            client: MockClient((r) async {
      writes++;
      return response(review(state: 'APPLIED', version: 2));
    }));
    final op = operation(client, Storage());
    await op.load();
    final future = op.submit(ContractReview.parse(review(), platform: false),
        ContractComparison.parse(comparison()));
    await Future<void>.delayed(Duration.zero);
    op.suspend();
    token.complete('fixture');
    await future;
    expect(writes, 0);
    expect(op.pending, isNotNull);
    op.dispose();
  });
  test('recovery store rejects secret fields and isolates actors', () async {
    final memory = Storage(),
        store = ContractAcceptanceStore(storage: Storage());
    final durable = ContractAcceptanceStore(storage: memory);
    await durable.save(tenant, 'owner', {'reviewId': reviewId, 'version': 1});
    expect(await durable.load(tenant, 'other'), isNull);
    expect(await store.load(tenant, 'owner'), isNull);
    memory.values[durable.key(tenant, 'owner')] =
        jsonEncode({'reviewId': reviewId, 'version': 1, 'evidence': 'secret'});
    await expectLater(durable.load(tenant, 'owner'), throwsFormatException);
  });
  for (final scale in [1.0, 2.0]) {
    testWidgets(
        'institution reviews facts and explicitly confirms at scale $scale',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      const font = String.fromEnvironment('UI_CAPTURE_FONT');
      if (font.isNotEmpty) {
        await tester.runAsync(() async {
          for (final entry in {
            'LocalCaptureFont': font,
            'MaterialIcons': const String.fromEnvironment('UI_CAPTURE_ICONS')
          }.entries) {
            if (entry.value.isEmpty) continue;
            final loader = FontLoader(entry.key)
              ..addFont(Future.value(
                  ByteData.sublistView(await File(entry.value).readAsBytes())));
            await loader.load();
          }
        });
      }
      int writes = 0;
      var applied = false;
      final store = Storage();
      final session = Session(api((r) async {
        if (r.method == 'POST') {
          writes++;
          applied = true;
          return response(review(state: 'APPLIED', version: 2));
        }
        if (r.url.path.endsWith('/comparison')) {
          return response(comparison(version: applied ? 2 : 1));
        }
        if (r.url.path.endsWith('/history')) {
          return response({
            'items': [
              {'version': 1, 'action': 'APPROVED', 'occurredAt': 1791619200000}
            ],
            'nextBeforeVersion': null
          });
        }
        if (r.url.path.endsWith('/commercial-entitlements')) {
          return response(rights(tenant));
        }
        if (r.url.path.endsWith('/$reviewId')) {
          return response(review(
              state: applied ? 'APPLIED' : 'AWAITING_CUSTOMER',
              version: applied ? 2 : 1));
        }
        return response({
          'items': [review()],
          'nextCursor': null
        });
      }));
      final boundary = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: boundary,
          child: MaterialApp(
              debugShowCheckedModeBanner: false,
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: ThemeData(
                  useMaterial3: true,
                  colorSchemeSeed: const Color(0xFF315E86),
                  fontFamily: font.isEmpty ? null : 'LocalCaptureFont'),
              home: ContractsCenter(
                  session: session,
                  store: ContractAcceptanceStore(storage: store)))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CN-2026-01'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('合同事实与当前报价一致'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('合同事实与当前报价一致'), findsOneWidget);
      expect(writes, 0);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_CONTRACT_UI') && scale == 1) {
        await tester.runAsync(() async {
          final img = await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
          final data = await img.toByteData(format: ui.ImageByteFormat.png);
          await File('../../.local/parent-contract-portrait.png')
              .writeAsBytes(data!.buffer.asUint8List());
          img.dispose();
        });
      }
      await tester.tap(find.text('核对并确认合同'));
      await tester.pumpAndSettle();
      expect(writes, 0);
      await tester.ensureVisible(find.text('确认合同权益'));
      await tester.tap(find.text('确认合同权益'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      await tester.drag(find.byType(ListView).first, const Offset(0, 2000));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('完成核对并刷新'), 200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      final finish = find.widgetWithText(FilledButton, '完成核对并刷新');
      await Scrollable.ensureVisible(tester.element(finish), alignment: 0.5);
      await tester.pumpAndSettle();
      expect(finish.hitTestable(), findsOneWidget);
      await tester.tap(finish);
      await tester.pumpAndSettle();
      expect(store.values, isEmpty);
      expect(find.text('核对并确认合同'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'auditor cannot accept and mismatched offer disables administrator confirmation',
      (tester) async {
    for (final grant in ['AUDITOR', 'OWNER']) {
      final session = Session(api((r) async {
        if (r.url.path.endsWith('/comparison')) {
          return response(comparison(match: false));
        }
        if (r.url.path.endsWith('/history')) {
          return response({'items': [], 'nextBeforeVersion': null});
        }
        if (r.url.path.endsWith('/commercial-entitlements')) {
          return response(rights(tenant));
        }
        if (r.url.path.endsWith('/$reviewId')) return response(review());
        return response({
          'items': [review()],
          'nextCursor': null
        });
      }), grant: grant);
      await tester.pumpWidget(MaterialApp(
          key: ValueKey(grant),
          home: ContractsCenter(
              session: session,
              store: ContractAcceptanceStore(storage: Storage()))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CN-2026-01'));
      await tester.pumpAndSettle();
      if (grant == 'AUDITOR') {
        expect(find.text('核对并确认合同'), findsNothing);
      } else {
        expect(
            tester
                .widget<FilledButton>(
                    find.widgetWithText(FilledButton, '核对并确认合同'))
                .onPressed,
            isNull);
      }
    }
  });
  testWidgets(
      'background closes confirmation and tenant switch closes old contract page',
      (tester) async {
    int writes = 0;
    final session = Session(api((r) async {
      if (r.method == 'POST') writes++;
      if (r.url.path.endsWith('/comparison')) return response(comparison());
      if (r.url.path.endsWith('/history')) {
        return response({'items': [], 'nextBeforeVersion': null});
      }
      if (r.url.path.endsWith('/commercial-entitlements')) {
        return response(rights(tenant));
      }
      if (r.url.path.endsWith('/$reviewId')) return response(review());
      return response({
        'items': [review()],
        'nextCursor': null
      });
    }));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                            builder: (_) => ContractsCenter(
                                session: session,
                                store: ContractAcceptanceStore(
                                    storage: Storage())))),
                    child: const Text('打开合同'))))));
    await tester.tap(find.text('打开合同'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CN-2026-01'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对并确认合同'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('合同信息已隐藏。'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    session.switchTenant(offerId);
    await tester.pumpAndSettle();
    expect(find.byType(ContractsCenter), findsNothing);
    expect(writes, 0);
  });
  testWidgets('commercial account never shows late data from previous tenant',
      (tester) async {
    final old = Completer<http.Response>();
    final session = Session(api((r) async => r.url.path.contains('/$tenant/')
        ? old.future
        : response(rights(offerId, capacity: 50))));
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: CommercialAccount(session: session))));
    await tester.pump();
    session.switchTenant(offerId);
    await tester.pumpAndSettle();
    expect(find.text('50'), findsOneWidget);
    old.complete(response(rights(tenant, capacity: 25)));
    await tester.pumpAndSettle();
    expect(find.text('25'), findsNothing);
    expect(find.text('50'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('50'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('50'), findsOneWidget);
  });
}
