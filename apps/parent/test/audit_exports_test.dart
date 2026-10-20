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
import 'package:parent/core/audit.dart';
import 'package:parent/core/audit_exports.dart';
import 'package:parent/core/audit_export_destination.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/ui/audit_exports_center.dart';
import 'audit_export_fixture.dart';

import 'support/parent_operation_journal_fixture.dart';

http.Response reply(Object v, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(v)), status,
        headers: {'content-type': 'application/json'});
ParentApi transport(FutureOr<http.Response> Function(http.Request) handler) =>
    ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((r) async => handler(r)));
ParentAuditExports repo(FutureOr<http.Response> Function(http.Request) handler,
        {bool Function()? current, Future<String> Function()? token}) =>
    ParentAuditExports(
        api: transport(handler),
        tenant: exportTenant,
        current: current ?? () => true,
        token: token ?? () async => 'fixture',
        client: MockClient((r) async => handler(r)));

class Storage extends ParentDurableStorage with ParentAtomicJournalFixture {
  final values = <String, String>{};
  bool fail = false;
  Completer<void>? delayed;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    if (fail) throw StateError('disk');
    values[key] = value;
    await delayed?.future;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

AuditExportOperation control(ParentAuditExports repository, Storage storage,
        {bool Function()? current}) =>
    AuditExportOperation(
        repository: repository,
        store: AuditExportStore(storage: storage),
        actor: 'guardian-01',
        current: current ?? () => true);

class Session extends ParentSession {
  final ParentApi httpApi;
  bool verified = true;
  int auths = 0;
  Session(this.httpApi, {String grant = 'OWNER'}) {
    profile = {'subject': 'guardian-01'};
    tenant = {'id': exportTenant, 'kind': 'ORGANIZATION', 'name': '晨光学校'};
    role = grant;
    ready = true;
  }
  @override
  ParentApi get api => httpApi;
  @override
  bool get authenticated => true;
  @override
  Future<String> token() async => 'fixture';
  @override
  Future<bool> reauthenticate() async {
    auths++;
    if (verified) {
      generation++;
      notifyListeners();
    }
    return verified;
  }

  void change() {
    tenant = {...tenant!, 'id': exportResource};
    generation++;
    notifyListeners();
  }
}

class Destination extends AuditExportDestination {
  int choices = 0, writes = 0, aborts = 0;
  Uint8List? saved;
  Future<String?> Function()? picker;
  @override
  bool get supported => true;
  @override
  Future<String?> choose(String id) async {
    choices++;
    return picker == null ? 'ticket' : await picker!();
  }

  @override
  Future<void> write(String ticket, Uint8List bytes) async {
    writes++;
    saved = Uint8List.fromList(bytes);
  }

  @override
  Future<void> abort() async {
    aborts++;
  }
}

Widget app(Session session, ParentAuditExports repository, Storage storage,
        Destination destination, {GlobalKey? capture, String? font}) =>
    MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF315E86),
            fontFamily: font),
        home: RepaintBoundary(
            key: capture,
            child: AuditExportsCenter(
                session: session,
                query: exportFilter,
                repository: repository,
                store: AuditExportStore(storage: storage),
                destination: destination)));
Future<void> tap(WidgetTester t, String text) async {
  final f = find.text(text);
  if (f.evaluate().isEmpty) {
    await t.scrollUntilVisible(f, 180,
        scrollable: find.byType(Scrollable).first);
  }
  await Scrollable.ensureVisible(t.element(f.first), alignment: 0.5);
  await t.pumpAndSettle();
  expect(f.first.hitTestable(), findsOneWidget);
  await t.tap(f.first);
  await t.pumpAndSettle();
}

void main() {
  test('verified successful writes clear recovery reminder automatically',
      () async {
    final storage = Storage();
    final op = control(
        repo((r) => reply(exportJob(
            state: r.url.path.endsWith('/cancel') ? 'CANCELLED' : 'QUEUED'))),
        storage);
    await op.load();
    await op.create(exportFilter);
    expect(op.result?.state, 'QUEUED');
    expect(op.pending, isNull);
    expect(storage.values, isEmpty);
    await op.cancel(exportId);
    expect(op.result?.state, 'CANCELLED');
    expect(op.pending, isNull);
    expect(storage.values, isEmpty);
  });
  testWidgets(
      'poll permission failure removes old task and allows explicit retry',
      (t) async {
    int reads = 0;
    final repository = repo((r) {
      if (r.url.path.endsWith(exportId)) {
        reads++;
        return reads == 1
            ? reply(exportJob(state: 'QUEUED'))
            : reply({'errorCode': 'FORBIDDEN'}, 403);
      }
      return reply({
        'items': [exportJob(state: 'QUEUED')],
        'nextCursor': null
      });
    });
    await t.pumpWidget(
        app(Session(repository.api), repository, Storage(), Destination()));
    await t.pumpAndSettle();
    await tap(t, '等待生成');
    await t.pump(const Duration(seconds: 5));
    await t.pumpAndSettle();
    expect(find.text('等待生成'), findsNothing);
    expect(find.text('重试此次读取'), findsOneWidget);
  });
  test(
      'shared export projection validates metadata and exact artifact identity',
      () {
    for (final raw in [
      {...exportJob(), 'expiresAt': 9007199254740991},
      {...exportJob(), 'byteCount': null},
      {...exportJob(), 'attempts': 4}
    ]) {
      expect(() => AuditExportJob.parse(raw),
          throwsA(isA<AuditProtocolException>()));
    }
    final job = AuditExportJob.parse(exportJob());
    for (final body in [
      {...exportBody(), 'tenantId': exportResource},
      {...exportBody(), 'jobId': exportResource},
      {...exportBody(), 'extra': 'secret'},
      {...exportBody(), 'events': []}
    ]) {
      expect(() => validateAuditExportContent(body, job, exportTenant),
          throwsA(isA<AuditProtocolException>()));
    }
    validateAuditExportContent(exportBody(), job, exportTenant);
  });
  test(
      'lost creation reply is recovered from durable original key without creation replay',
      () async {
    int creates = 0, queries = 0;
    String? key;
    final storage = Storage();
    final repository = repo((r) {
      if (r.url.path.endsWith('/query')) {
        queries++;
        expect(r.url.path, contains(key!));
        return reply(exportJob());
      }
      creates++;
      key = r.headers['Idempotency-Key'];
      throw http.ClientException('lost');
    });
    final first = control(repository, storage);
    await first.load();
    await first.create(exportFilter);
    expect(creates, 1);
    expect(first.pending, isNotNull);
    first.dispose();
    final restored = control(repository, storage);
    await restored.load();
    expect(queries, 0);
    await restored.recover();
    expect(restored.result?.id, exportId);
    expect(queries, 1);
    expect(creates, 1);
    expect(await restored.clear(), true);
    expect(storage.values, isEmpty);
  });
  test('durability failure or suspension before dispatch stops creation',
      () async {
    int writes = 0;
    final repository = repo((r) {
      writes++;
      return reply(exportJob(state: 'QUEUED'));
    });
    final disk = Storage()..fail = true;
    final a = control(repository, disk);
    await a.load();
    await a.create(exportFilter);
    expect(writes, 0);
    final waiting = Storage()..delayed = Completer<void>();
    final b = control(repository, waiting);
    await b.load();
    final pending = b.create(exportFilter);
    await Future<void>.delayed(Duration.zero);
    b.suspend();
    waiting.delayed!.complete();
    await pending;
    expect(writes, 0);
    expect(b.loaded, false);
    expect(waiting.values.length, 1);
  });
  test('storage validates exact descriptors and separates identities',
      () async {
    final storage = Storage(), store = AuditExportStore(storage: Storage());
    final scoped = AuditExportStore(storage: storage);
    final row = {
      'kind': 'create',
      'requestId': exportId,
      'query': exportSelection(exportFilter)
    };
    await scoped.save(exportTenant, 'guardian-01', row);
    expect(await scoped.load(exportTenant, 'other'), null);
    expect(() => store.validate({...row, 'token': 'forbidden'}),
        throwsFormatException);
    expect(() => store.validate({'kind': 'cancel', 'jobId': 'invalid'}),
        throwsFormatException);
    expect(storage.values.values.single, isNot(contains('Authorization')));
  });
  test('cancel response loss reads current state without repeating the cancel',
      () async {
    int cancels = 0;
    final storage = Storage();
    final repository = repo((r) {
      if (r.url.path.endsWith('/cancel')) {
        cancels++;
        throw http.ClientException('lost');
      }
      return reply(exportJob(state: 'CANCELLED'));
    });
    final op = control(repository, storage);
    await op.load();
    await op.cancel(exportId);
    await op.recover();
    expect(op.result?.state, 'CANCELLED');
    expect(cancels, 1);
  });
  test(
      'download checks content type byte size scope and unchanged job identity',
      () async {
    final good = AuditExportJob.parse(exportJob());
    expect(
        await repo((r) {
          expect(r.followRedirects, false);
          expect(r.headers['Authorization'], 'Bearer fixture');
          return reply(exportBody());
        }).download(good, operation: () => true),
        utf8.encode(jsonEncode(exportBody())));
    for (final response in [
      http.Response('redirect', 302),
      http.Response('{}', 200),
      reply({...exportBody(), 'jobId': exportResource}),
      reply(exportBody(), 403)
    ]) {
      await expectLater(
          repo((r) => response).download(good, operation: () => true),
          throwsA(isA<ParentApiException>()));
    }
    int calls = 0;
    bool active = true;
    final token = Completer<String>();
    final pending = repo((r) {
      calls++;
      return reply(exportBody());
    }, current: () => active, token: () => token.future)
        .download(good, operation: () => true);
    active = false;
    token.complete('fixture');
    await expectLater(pending, throwsA(isA<ParentApiException>()));
    expect(calls, 0);
  });
  test(
      'wrong job or original filters cannot be presented as a recovered result',
      () async {
    final repository = repo((r) => reply({...exportJob(), 'resourceId': null}));
    await expectLater(repository.recover(exportFilter, exportId),
        throwsA(isA<ParentApiException>()));
    await expectLater(
        repo((r) => reply({...exportJob(), 'id': exportResource}))
            .get(exportId),
        throwsA(isA<ParentApiException>()));
  });

  testWidgets('cancelled security verification creates no task', (t) async {
    int creates = 0;
    final repository = repo((r) {
      if (r.method == 'POST') creates++;
      return reply({'items': [], 'nextCursor': null});
    });
    final s = Session(repository.api)..verified = false;
    await t.pumpWidget(app(s, repository, Storage(), Destination()));
    await t.pumpAndSettle();
    await tap(t, '生成导出');
    await tap(t, '验证并生成');
    expect(creates, 0);
    expect(s.auths, 1);
  });
  testWidgets(
      'reauthentication generation can finish the intended creation once',
      (t) async {
    int creates = 0;
    final repository = repo((r) {
      if (r.method == 'POST') {
        creates++;
        return reply(exportJob(state: 'QUEUED'), 202);
      }
      return reply({'items': [], 'nextCursor': null});
    });
    final s = Session(repository.api);
    await t.pumpWidget(app(s, repository, Storage(), Destination()));
    await t.pumpAndSettle();
    await tap(t, '生成导出');
    await tap(t, '验证并生成');
    expect(creates, 1);
    expect(s.auths, 1);
    expect(find.text('等待生成'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'picker cancel downloads nothing and scope change prevents saving',
      (t) async {
    int downloads = 0;
    final repository = repo((r) {
      if (r.url.path.endsWith('/content')) {
        downloads++;
        return reply(exportBody());
      }
      return reply(r.url.path.endsWith(exportId)
          ? exportJob()
          : {
              'items': [exportJob()],
              'nextCursor': null
            });
    });
    final s = Session(repository.api),
        dest = Destination()..picker = () async => null;
    await t.pumpWidget(app(s, repository, Storage(), dest));
    await t.pumpAndSettle();
    await tap(t, '可下载');
    await tap(t, '选择位置并保存');
    await tap(t, '验证并选择位置');
    expect(downloads, 0);
    expect(dest.writes, 0);
    dest.picker = () async {
      s.change();
      return 'ticket';
    };
    await tap(t, '选择位置并保存');
    await tap(t, '验证并选择位置');
    expect(dest.writes, 0);
    expect(downloads, 0);
  });
  testWidgets('background closes confirmation and hides task details',
      (t) async {
    final repository = repo((r) => reply(r.url.path.endsWith(exportId)
        ? exportJob()
        : {
            'items': [exportJob()],
            'nextCursor': null
          }));
    await t.pumpWidget(
        app(Session(repository.api), repository, Storage(), Destination()));
    await t.pumpAndSettle();
    await tap(t, '可下载');
    await tap(t, '选择位置并保存');
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pumpAndSettle();
    expect(find.text('保存操作记录文件？'), findsNothing);
    expect(find.textContaining('任务编号：'), findsNothing);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(find.text('可下载'), findsOneWidget);
  });
  for (final scale in [1.0, 2.0]) {
    testWidgets(
        'save verified bytes through selected destination at $scale text',
        (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(() {
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
        t.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final repository = repo((r) => reply(r.url.path.endsWith('/content')
          ? exportBody()
          : r.url.path.endsWith(exportId)
              ? exportJob()
              : {
                  'items': [exportJob()],
                  'nextCursor': null
                }));
      final s = Session(repository.api), dest = Destination();
      const font = String.fromEnvironment('UI_CAPTURE_FONT');
      if (font.isNotEmpty) {
        await t.runAsync(() async {
          for (final e in {
            'Capture': font,
            'MaterialIcons': const String.fromEnvironment('UI_CAPTURE_ICONS')
          }.entries) {
            if (e.value.isEmpty) continue;
            await (FontLoader(e.key)
                  ..addFont(Future.value(
                      ByteData.sublistView(await File(e.value).readAsBytes()))))
                .load();
          }
        });
      }
      final key = GlobalKey();
      await t.pumpWidget(app(s, repository, Storage(), dest,
          capture: key, font: font.isEmpty ? null : 'Capture'));
      await t.pumpAndSettle();
      await tap(t, '可下载');
      if (const bool.fromEnvironment('CAPTURE_EXPORT_UI') && scale == 1) {
        await t.runAsync(() async {
          final picture = await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
          final data = await picture.toByteData(format: ui.ImageByteFormat.png);
          final out = File(const String.fromEnvironment('UI_CAPTURE_PATH'));
          await out.parent.create(recursive: true);
          await out.writeAsBytes(data!.buffer.asUint8List());
          picture.dispose();
        });
      }
      await tap(t, '选择位置并保存');
      await tap(t, '验证并选择位置');
      expect(dest.writes, 1);
      expect(dest.saved, utf8.encode(jsonEncode(exportBody())));
      expect(s.auths, 1);
      expect(t.takeException(), null);
    });
  }
}
