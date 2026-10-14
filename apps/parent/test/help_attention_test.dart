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
import 'package:parent/core/help_attention.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/help_center.dart';
import 'package:parent/main.dart';
import 'package:parent/core/paged_collection.dart';

const id = '00000000-0000-4000-8000-000000000001';
const other = '00000000-0000-4000-8000-000000000002';
Json record({bool seen = false, String request = id}) => {
      'id': request,
      'subjectId': id,
      'deviceId': other,
      'clientRequestId': id,
      'subjectNickname': '小安',
      'reasonCode': 'DEVICE_PROBLEM',
      'state': seen ? 'ACKNOWLEDGED' : 'OPEN',
      'createdAt': 1791950400000,
      'acknowledgedAt': seen ? 1791950460000 : null,
      'version': seen ? 1 : 0,
    };
http.Response response(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status);
ParentApi api(Future<http.Response> Function(http.Request) send) =>
    ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1', client: MockClient(send));

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

ParentHelpDetail detail(ParentApi api, Storage storage,
        {bool Function()? current, bool Function()? foreground}) =>
    ParentHelpDetail(
        api: api,
        store: HelpAttentionStore(storage: storage),
        tenant: id,
        actor: 'adult',
        id: id,
        isCurrent: current ?? () => true,
        foreground: foreground ?? () => true);

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
  void revoke() {
    role = 'AUDITOR';
    notifyListeners();
  }
}

void main() {
  test('typed pagination rejects malformed next page without mixing records',
      () async {
    final requests = <http.Request>[];
    final p = PagedCollection(api((r) async {
      requests.add(r);
      return response(r.url.queryParameters.containsKey('cursor')
          ? {
              'items': [
                {...record(request: other), 'state': 'RESOLVED'}
              ],
              'nextCursor': null
            }
          : {
              'items': [record()],
              'nextCursor': id
            });
    }), '/tenants/$id/help-requests?state=OPEN',
        pageSize: 20, validateItem: parseHelp);
    while (p.loading) {
      await Future<void>.delayed(Duration.zero);
    }
    await p.loadMore();
    expect(p.error, isA<ParentApiException>());
    expect(p.items, hasLength(1));
    expect(requests.last.url.queryParameters,
        {'state': 'OPEN', 'limit': '20', 'cursor': id});
    p.dispose();
  });
  testWidgets('actual parent help tab opens the new details and confirms once',
      (tester) async {
    final values = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (call) async {
      final args = call.arguments as Map;
      final key = args['key'] as String;
      if (call.method == 'read') return values[key];
      if (call.method == 'write') values[key] = args['value'] as String;
      if (call.method == 'delete') values.remove(key);
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.aimanager.parent/storage'),
            (_) async => true);
    var posts = 0;
    final session = Session(api((r) async {
      if (r.method == 'POST') {
        posts++;
        return response(record(seen: true));
      }
      if (r.url.path.endsWith('/help-requests/$id')) return response(record());
      if (r.url.path.endsWith('/help-requests')) {
        return response({
          'items': [record()],
          'nextCursor': null
        });
      }
      if (r.url.path.endsWith('/unread-count')) {
        return response({'count': 0, 'capped': false});
      }
      return response({'items': [], 'nextCursor': null});
    }))
      ..ready = true;
    await tester.pumpWidget(ParentApp(session: session));
    await tester.pumpAndSettle();
    await tester.tap(find.text('求助'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小安'));
    await tester.pumpAndSettle();
    expect(find.text('求助详情'), findsOneWidget);
    await tester.ensureVisible(find.text('我已看到这条求助，会尽快联系孩子'));
    await tester.tap(find.text('我已看到这条求助，会尽快联系孩子'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('确认已看到'));
    await tester.tap(find.text('确认已看到'));
    await tester.pumpAndSettle();
    expect(posts, 1);
    expect(find.text('已有成人确认看到'), findsOneWidget);
    expect(values, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  test('valid receipt clears durable marker without another confirmation',
      () async {
    var posts = 0;
    final store = Storage();
    final c = detail(api((r) async {
      if (r.method == 'POST') {
        posts++;
        expect(r.headers['If-Match'], '"0"');
        expect(store.values, hasLength(1));
        expect(store.values.values.single, isNot(contains('小安')));
        return response(record(seen: true));
      }
      return response(record());
    }), store);
    await c.load();
    await c.acknowledge();
    expect(c.error, isNull);
    expect(c.request!.state, 'ACKNOWLEDGED');
    expect(c.pending, isNull);
    expect(store.values, isEmpty);
    await c.acknowledge();
    expect(posts, 1);
    c.dispose();
  });
  test(
      'lost response survives recreation and query never repeats acknowledgement',
      () async {
    var posts = 0;
    final storage = Storage();
    final transport = api((r) async {
      if (r.method == 'POST') {
        posts++;
        throw http.ClientException('lost');
      }
      return response(record(seen: posts > 0));
    });
    final first = detail(transport, storage);
    await first.load();
    await first.acknowledge();
    expect(first.pending, isNotNull);
    first.dispose();
    final c = detail(transport, storage);
    await c.load();
    expect(c.queried, isTrue);
    expect(c.request!.state, 'ACKNOWLEDGED');
    await c.acknowledge();
    expect(posts, 1);
    await c.clearPending();
    expect(storage.values, isEmpty);
    expect(posts, 1);
    c.dispose();
  });
  for (final failure in ['storage', 'changed', 'malformed', 'rebound']) {
    test('$failure cannot appear as successful acknowledgement', () async {
      var reads = 0, posts = 0;
      final storage = Storage()..fail = failure == 'storage';
      final c = detail(api((r) async {
        if (r.method == 'POST') {
          posts++;
          return response(failure == 'rebound'
              ? {...record(seen: true), 'deviceId': id}
              : record());
        }
        reads++;
        return response(record(seen: failure == 'changed' && reads > 1));
      }), storage);
      await c.load();
      await c.acknowledge();
      expect(c.error, isNotNull);
      expect(c.loaded, isFalse);
      expect(posts, failure == 'storage' || failure == 'changed' ? 0 : 1);
      await c.acknowledge();
      expect(posts, failure == 'storage' || failure == 'changed' ? 0 : 1);
      c.dispose();
    });
  }
  test('token wait after durable save cannot send under another role',
      () async {
    var current = true, reads = 0, sends = 0;
    final waiting = Completer<void>(), token = Completer<String>();
    final transport = ParentApi(
        () async {
          reads++;
          if (reads == 3) {
            waiting.complete();
            return token.future;
          }
          return 'fixture';
        },
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((r) async {
          sends++;
          return response(record());
        }));
    final c = detail(transport, Storage(), current: () => current);
    await c.load();
    final pending = c.acknowledge();
    await waiting.future;
    current = false;
    c.hide();
    token.complete('fixture');
    await pending;
    expect(sends, 2);
    expect(c.request, isNull);
    expect(c.pending, isNotNull);
    c.dispose();
    transport.close();
  });
  test('late receipt after background does not refill the screen', () async {
    var foreground = true;
    final waiting = Completer<void>(), receipt = Completer<http.Response>();
    final c = detail(api((r) async {
      if (r.method == 'POST') {
        waiting.complete();
        return receipt.future;
      }
      return response(record());
    }), Storage(), foreground: () => foreground);
    await c.load();
    final future = c.acknowledge();
    await waiting.future;
    foreground = false;
    c.hide();
    receipt.complete(response(record(seen: true)));
    await future;
    expect(c.request, isNull);
    expect(c.pending, isNotNull);
    c.dispose();
  });
  test('unavailable original remains explicit until local acknowledgement',
      () async {
    final storage = Storage();
    await HelpAttentionStore(storage: storage)
        .save(id, 'adult', parseHelp(record()));
    final c = detail(
        api((r) async =>
            response({'errorCode': 'HELP_REQUEST_UNAVAILABLE'}, 404)),
        storage);
    await c.load();
    expect(c.queried, isTrue);
    expect(c.request, isNull);
    expect(c.pending, isNotNull);
    await c.clearPending();
    expect(storage.values, isEmpty);
    c.dispose();
  });
  test('another pending request blocks a new acknowledgement', () async {
    final storage = Storage();
    await HelpAttentionStore(storage: storage)
        .save(id, 'adult', parseHelp(record(request: other)));
    var posts = 0;
    final c = detail(api((r) async {
      if (r.method == 'POST') posts++;
      return response(record());
    }), storage);
    await c.load();
    await c.acknowledge();
    expect(posts, 0);
    expect(c.queried, isFalse);
    c.dispose();
  });
  test('contradictory or unbounded projections are rejected', () {
    for (final bad in [
      {...record(), 'acknowledgedAt': 1791950460000},
      {...record(), 'createdAt': 9007199254740991},
      {...record(), 'state': 'RESOLVED'},
      {...record(), 'subjectNickname': '孩子\u202e'}
    ]) {
      expect(() => parseHelp(bad), throwsA(isA<ParentApiException>()));
    }
  });
  testWidgets(
      'filters, detail, acknowledgement, large font and background privacy',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const font = String.fromEnvironment('UI_CAPTURE_FONT'),
        icons = String.fromEnvironment('UI_CAPTURE_ICONS');
    for (final entry in {'CaptureFont': font, 'MaterialIcons': icons}.entries) {
      if (entry.value.isNotEmpty) {
        await tester.runAsync(() async {
          await (FontLoader(entry.key)
                ..addFont(Future.value(ByteData.sublistView(
                    await File(entry.value).readAsBytes()))))
              .load();
        });
      }
    }
    var seen = false, posts = 0;
    final filters = <String?>[];
    final session = Session(api((r) async {
      if (r.method == 'POST') {
        seen = true;
        posts++;
        return response(record(seen: true));
      }
      if (r.url.path.endsWith('/help-requests')) {
        final filter = r.url.queryParameters['state'];
        filters.add(filter);
        return response({
          'items': [
            if (filter == null || filter == (seen ? 'ACKNOWLEDGED' : 'OPEN'))
              record(seen: seen)
          ],
          'nextCursor': null
        });
      }
      return response(record(seen: seen));
    }));
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: boundary,
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
                useMaterial3: true,
                colorSchemeSeed: const Color(0xFF315E86),
                fontFamily: font.isEmpty ? null : 'CaptureFont'),
            builder: (ctx, child) => MediaQuery(
                data: MediaQuery.of(ctx)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!),
            home: Scaffold(
                body: ParentHelpCenter(
                    session: session,
                    store: HelpAttentionStore(storage: Storage()))))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已查看'));
    await tester.pumpAndSettle();
    expect(filters.last, 'ACKNOWLEDGED');
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(filters.last, isNull);
    await tester.tap(find.text('小安'));
    await tester.pumpAndSettle();
    if (const bool.fromEnvironment('CAPTURE_HELP_UI')) {
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('help-detail.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.ensureVisible(find.text('确认已看到'));
    await tester.tap(find.text('确认已看到'));
    await tester.pumpAndSettle();
    expect(posts, 0);
    await tester.ensureVisible(find.text('我已看到这条求助，会尽快联系孩子'));
    await tester.tap(find.text('我已看到这条求助，会尽快联系孩子'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('确认已看到'));
    await tester.tap(find.text('确认已看到'));
    await tester.pumpAndSettle();
    expect(posts, 1);
    expect(find.text('已有成人确认看到'), findsOneWidget);
    expect(find.text('完成核对'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('小安'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    session.revoke();
    await tester.pumpAndSettle();
    expect(find.text('求助详情'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('durable pending marker is reachable even outside OPEN list',
      (tester) async {
    final storage = Storage();
    await HelpAttentionStore(storage: storage)
        .save(id, 'adult', parseHelp(record()));
    final session = Session(api((r) async => response(
        r.url.path.endsWith('/help-requests')
            ? {'items': [], 'nextCursor': null}
            : record(seen: true))));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ParentHelpCenter(
                session: session,
                store: HelpAttentionStore(storage: storage)))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('有一条确认结果待核对'));
    await tester.pumpAndSettle();
    expect(find.text('已有成人确认看到'), findsOneWidget);
    await tester.ensureVisible(find.text('我已核对原记录和当前状态'));
    await tester.tap(find.text('我已核对原记录和当前状态'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('完成核对'));
    await tester.tap(find.text('完成核对'));
    await tester.pumpAndSettle();
    expect(storage.values, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
