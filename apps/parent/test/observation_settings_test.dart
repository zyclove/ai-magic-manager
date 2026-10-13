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
import 'package:parent/core/observation_settings.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/observation_settings_page.dart';
import 'package:usage_reporting/usage_reporting.dart';

const device = '00000000-0000-4000-8000-000000000001';
const registration = '00000000-0000-4000-8000-000000000002';
const subject = '00000000-0000-4000-8000-000000000003';
const target = UsageReportTarget(device, registration, subject, '学习平板',
    platform: 'ANDROID');
Json settings([int version = 0, bool enabled = false]) => {
      'deviceId': device,
      'registrationId': registration,
      'version': version,
      'inventoryEnabled': enabled,
      'usageEnabled': enabled,
      'updatedAt': version == 0 ? null : 1700000000000,
    };
Json deviceJson() => {
      'id': device,
      'registrationId': registration,
      'subjectId': subject,
      'platform': 'ANDROID',
      'state': 'ACTIVE'
    };
http.Response response(Json value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status);

class Storage extends ParentDurableStorage {
  final values = <String, String>{};
  bool failWrite = false;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
    if (failWrite) throw StateError('flush failed');
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

ParentApi api(Future<http.Response> Function(http.Request) handle) =>
    ParentApi(() async => 'fixture',
        client: MockClient(handle), baseUrl: 'https://fixture.invalid/api/v1');
ParentObservationController controller(ParentApi api, Storage storage,
        {Future<bool> Function()? auth,
        bool Function()? current,
        bool Function()? foreground}) =>
    ParentObservationController(
        api: api,
        store: ObservationChangeStore(storage: storage),
        tenant: 'tenant',
        actor: 'adult',
        target: target,
        isCurrent: current ?? () => true,
        foreground: foreground ?? () => true,
        reauthenticate: auth ?? () async => true);
Future<void> submit(ParentObservationController c) =>
    c.submit(inventory: true, usage: true, reason: '查看学习时间');

class Session extends ParentSession {
  final ParentApi fixture;
  int checks = 0;
  Session(this.fixture) {
    tenant = {'id': 'tenant'};
    profile = {'subject': 'adult'};
    role = 'GUARDIAN';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  @override
  Future<bool> reauthenticate() async {
    checks++;
    return true;
  }

  void revoke() {
    role = 'AUDITOR';
    notifyListeners();
  }
}

void main() {
  testWidgets(
      'expired authentication can be renewed without an authorization write',
      (tester) async {
    var writes = 0;
    late Session session;
    session = Session(api((r) async {
      if (r.method != 'GET') writes++;
      if (session.checks == 0) {
        return response({'errorCode': 'UNAUTHENTICATED'}, 401);
      }
      return response(
          r.url.path.endsWith('/devices/$device') ? deviceJson() : settings());
    }));
    await tester.pumpWidget(MaterialApp(
        home: ParentObservationPage(
            session: session,
            target: target,
            store: ObservationChangeStore(storage: Storage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新安全验证并核对'));
    await tester.pumpAndSettle();
    expect(session.checks, 1);
    expect(writes, 0);
    expect(find.text('本次核对的当前授权'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'large text consent workflow supports save and explicit acknowledgement',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const font = String.fromEnvironment('UI_CAPTURE_FONT'),
        icons = String.fromEnvironment('UI_CAPTURE_ICONS');
    for (final entry
        in {'LocalCaptureFont': font, 'MaterialIcons': icons}.entries) {
      if (entry.value.isNotEmpty) {
        await tester.runAsync(() async {
          final data = await File(entry.value).readAsBytes();
          await (FontLoader(entry.key)
                ..addFont(Future.value(ByteData.sublistView(data))))
              .load();
        });
      }
    }
    var version = 0, writes = 0;
    final session = Session(api((r) async {
      if (r.url.path.endsWith('/devices/$device')) {
        return response(deviceJson());
      }
      if (r.url.path.endsWith('/changes')) {
        version = 1;
        writes++;
        return response(settings(1, true));
      }
      if (r.url.path.endsWith('/query')) {
        return response(
            {'committed': settings(1, true), 'current': settings(1, true)});
      }
      return response(settings(version, version > 0));
    }));
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: boundary,
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
            home: ParentObservationPage(
                session: session,
                target: target,
                store: ObservationChangeStore(storage: Storage())))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_OBSERVATION_UI')) {
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../../.local/parent-observation-portrait.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    for (final key in ['parent-observe-inventory', 'parent-observe-usage']) {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(find.byKey(const Key('parent-observe-reason')));
    await tester.enterText(
        find.byKey(const Key('parent-observe-reason')), '学习时间规划');
    await tester.ensureVisible(find.byKey(const Key('parent-observe-confirm')));
    await tester.tap(find.byKey(const Key('parent-observe-confirm')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('确认并进行安全验证'));
    await tester.tap(find.text('确认并进行安全验证'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(session.checks, 1);
    await tester.ensureVisible(find.text('原操作已提交（历史结果）'));
    expect(find.text('原操作已提交（历史结果）'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_OBSERVATION_UI')) {
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../../.local/parent-observation-result.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.ensureVisible(find.text('我已核对，清除本机记录并重新读取'));
    await tester.tap(find.text('我已核对，清除本机记录并重新读取'));
    await tester.pumpAndSettle();
    expect(find.text('原操作已提交（历史结果）'), findsNothing);
    expect(writes, 1);
    expect(tester.takeException(), isNull);
  });
  test(
      'writes only after MFA and durable save then separates committed and current',
      () async {
    final storage = Storage();
    var authenticated = false, mutations = 0;
    final c = controller(
        api((r) async {
          if (r.url.path.endsWith('/devices/$device')) {
            return response(deviceJson());
          }
          if (r.url.path.endsWith('/changes')) {
            expect(authenticated, isTrue);
            expect(storage.values, hasLength(1));
            expect(r.headers['Idempotency-Key'], isNotEmpty);
            final body = jsonDecode(r.body);
            expect(body['registrationId'], registration);
            expect(body['version'], 0);
            mutations++;
            return response(settings(1, true));
          }
          if (r.url.path.endsWith('/query')) {
            return response({
              'committed': settings(1, true),
              'current': settings(2, false)
            });
          }
          return response(settings());
        }),
        storage,
        auth: () async {
          authenticated = true;
          return true;
        });
    await c.load();
    await submit(c);
    expect(c.error, isNull);
    expect(c.committed!.usageEnabled, isTrue);
    expect(c.settings!.usageEnabled, isFalse);
    expect(c.pending, isNotNull);
    expect(mutations, 1);
    await c.query();
    expect(mutations, 1);
    await c.acknowledge();
    expect(storage.values, isEmpty);
    expect(c.settings, isNull);
    c.dispose();
  });
  test('lost response reopens with same marker and queries without mutation',
      () async {
    final storage = Storage();
    var writes = 0;
    final transport = api((r) async {
      if (r.url.path.endsWith('/devices/$device')) {
        return response(deviceJson());
      }
      if (r.url.path.endsWith('/changes')) {
        writes++;
        throw http.ClientException('fixture');
      }
      if (r.url.path.endsWith('/query')) {
        return response(
            {'committed': settings(1, true), 'current': settings(1, true)});
      }
      return response(settings());
    });
    final first = controller(transport, storage);
    await first.load();
    await submit(first);
    final key = first.pending!['requestId'];
    first.dispose();
    final next = controller(transport, storage);
    await next.load();
    expect(next.pending!['requestId'], key);
    await submit(next);
    expect(writes, 1);
    await next.query();
    expect(next.queried, isTrue);
    expect(writes, 1);
    next.dispose();
  });
  for (final outcome in [
    'cancelled',
    'scope-changed',
    'registration-changed',
    'version-changed',
    'storage-failed'
  ]) {
    test('$outcome never submits authorization', () async {
      final storage = Storage()..failWrite = outcome == 'storage-failed';
      var current = true, authDone = false, writes = 0;
      final c = controller(
          api((r) async {
            if (r.method == 'POST') writes++;
            if (r.url.path.endsWith('/devices/$device')) {
              return response({
                ...deviceJson(),
                if (authDone && outcome == 'registration-changed')
                  'registrationId': subject
              });
            }
            return response(
                settings(authDone && outcome == 'version-changed' ? 1 : 0));
          }),
          storage,
          current: () => current,
          auth: () async {
            authDone = true;
            if (outcome == 'scope-changed') current = false;
            return outcome != 'cancelled';
          });
      await c.load();
      await submit(c);
      expect(writes, 0);
      if (outcome == 'storage-failed') {
        await c.load();
        expect(c.pending, isNotNull);
      }
      c.dispose();
    });
  }
  for (final terminal in [
    (404, 'OBSERVATION_RESULT_UNAVAILABLE'),
    (410, 'IDEMPOTENCY_RESPONSE_ERASED')
  ]) {
    test('${terminal.$2} keeps original marker until explicit acknowledgement',
        () async {
      final storage = Storage();
      var writes = 0;
      final c = controller(api((r) async {
        if (r.url.path.endsWith('/devices/$device')) {
          return response(deviceJson());
        }
        if (r.url.path.endsWith('/changes')) {
          writes++;
          throw http.ClientException('fixture');
        }
        if (r.url.path.endsWith('/query')) {
          return response({'errorCode': terminal.$2}, terminal.$1);
        }
        return response(settings());
      }), storage);
      await c.load();
      await submit(c);
      final key = c.pending!['requestId'];
      await c.query();
      expect(c.queried, isTrue);
      expect(c.pending!['requestId'], key);
      expect(c.committed, isNull);
      expect(c.settings, isNull);
      await submit(c);
      expect(writes, 1);
      await c.acknowledge();
      expect(c.pending, isNull);
      expect(writes, 1);
      c.dispose();
    });
  }
  test(
      'late result after background cannot reveal consent or trigger another write',
      () async {
    final storage = Storage(),
        received = Completer<void>(),
        result = Completer<http.Response>();
    var foreground = true, queries = 0;
    final c = controller(api((r) async {
      if (r.url.path.endsWith('/devices/$device')) {
        return response(deviceJson());
      }
      if (r.url.path.endsWith('/changes')) {
        received.complete();
        return result.future;
      }
      if (r.url.path.endsWith('/query')) queries++;
      return response(settings());
    }), storage, foreground: () => foreground);
    await c.load();
    final future = submit(c);
    await received.future;
    foreground = false;
    c.hide();
    result.complete(response(settings(1, true)));
    await future;
    foreground = true;
    expect(c.settings, isNull);
    expect(c.committed, isNull);
    expect(c.pending, isNotNull);
    expect(queries, 0);
    c.dispose();
  });
  test(
      'forged success is retained as unresolved rather than presented as authorization',
      () async {
    final c = controller(api((r) async {
      if (r.url.path.endsWith('/devices/$device')) {
        return response(deviceJson());
      }
      if (r.url.path.endsWith('/changes')) return response(settings(1, false));
      return response(settings());
    }), Storage());
    await c.load();
    await submit(c);
    expect(c.error, isA<ParentApiException>());
    expect(c.queried, isFalse);
    expect(c.committed, isNull);
    expect(c.pending, isNotNull);
    c.dispose();
  });
  testWidgets(
      'portrait form requires acknowledgement and disappears on role revocation',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var writes = 0;
    final session = Session(api((r) async {
      if (r.method == 'POST') writes++;
      return response(
          r.url.path.endsWith('/devices/$device') ? deviceJson() : settings());
    }));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    child: const Text('打开'),
                    onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                        builder: (_) => ParentObservationPage(
                            session: session,
                            target: target,
                            store: ObservationChangeStore(
                                storage: Storage())))))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('parent-observe-reason')));
    await tester.enterText(
        find.byKey(const Key('parent-observe-reason')), '学习使用');
    await tester.ensureVisible(find.text('确认并进行安全验证'));
    await tester.tap(find.text('确认并进行安全验证'));
    await tester.pumpAndSettle();
    expect(find.text('请确认采集范围和撤回影响。'), findsOneWidget);
    expect(writes, 0);
    expect(session.checks, 0);
    expect(tester.takeException(), isNull);
    session.revoke();
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
    expect(find.text('观察授权'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
