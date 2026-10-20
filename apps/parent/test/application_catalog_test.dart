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
import 'package:parent/core/application_catalog.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/application_center.dart';
import 'package:parent/ui/policy_editor.dart';

import 'support/parent_operation_journal_fixture.dart';

const appId = '00000000-0000-4000-8000-000000000001';
Json definition() => {
      'displayName': '学习应用',
      'platform': 'ANDROID',
      'profile': 'PRIMARY',
      'packageName': 'org.example.Reader',
      'signingDigests': ['a' * 64]
    };
Json application() =>
    {'id': appId, ...definition(), 'evidenceStatus': 'ADMIN_DECLARED'};
Json classification(
        {int version = 0,
        String category = 'UNCLASSIFIED',
        String platform = 'ANDROID'}) =>
    {
      'identity': {
        'platform': platform,
        'profile': 'PRIMARY',
        'packageName': 'org.example.Reader'
      },
      'category': category,
      'source': version == 0 ? 'NONE' : 'ADMIN_DECLARED',
      'version': version,
      'updatedAt': version == 0 ? null : 1234,
    };
http.Response response(Json value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status);

class _Storage extends ParentDurableStorage with ParentAtomicJournalFixture {
  @override
  bool get fixtureWriteMayCommitBeforeFailure => true;
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

class _Session extends ParentSession {
  final ParentApi fixture;
  _Session(this.fixture) {
    tenant = {'id': 'tenant'};
    profile = {'subject': 'adult'};
    role = 'GUARDIAN';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  void changeScope() {
    tenant = {'id': 'other'};
    notifyListeners();
  }
}

CatalogOperationController _controller(ParentApi api, _Storage storage,
        {bool Function()? current}) =>
    CatalogOperationController(
        api: api,
        store: CatalogOperationStore(storage: storage),
        tenant: 'tenant',
        actor: 'adult',
        isCurrent: current ?? () => true);

void main() {
  testWidgets('portrait application detail remains readable with larger text',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const fontFile = String.fromEnvironment('UI_CAPTURE_FONT');
    const iconFile = String.fromEnvironment('UI_CAPTURE_ICONS');
    for (final entry
        in {'LocalCaptureFont': fontFile, 'MaterialIcons': iconFile}.entries) {
      if (entry.value.isEmpty) continue;
      await tester.runAsync(() async {
        final bytes = await File(entry.value).readAsBytes();
        final loader = FontLoader(entry.key)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      });
    }
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/applications')) {
        return response({
          'items': [application()],
          'nextCursor': null
        });
      }
      if (r.url.path.endsWith('/classification')) {
        return response(classification(version: 2, category: 'EDUCATION'));
      }
      return response(application());
    }));
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
                fontFamily: fontFile.isEmpty ? null : 'LocalCaptureFont',
                colorSchemeSeed: const Color(0xFF315E86),
                useMaterial3: true),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.3)),
                child: child!),
            home: ApplicationCenter(session: _Session(api), choosing: true))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习应用'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('CAPTURE_CATALOG_UI')) {
      await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../../.local/parent-application-portrait.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
  testWidgets(
      'classification editor preserves reviewed version and explains shared scope',
      (tester) async {
    tester.view.physicalSize = const Size(600, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = _Storage();
    http.Request? saved;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      saved = r;
      return response(classification(version: 1, category: 'EDUCATION'));
    }));
    await tester.pumpWidget(MaterialApp(
        home: CatalogOperationPage(
            session: _Session(api),
            application: application(),
            classification: classification(),
            store: CatalogOperationStore(storage: storage))));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习教育').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('核对并保存'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.textContaining('同平台、资料、包名共享分类'), findsOneWidget);
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(saved!.method, 'PUT');
    expect(saved!.headers['If-Match'], '"0"');
    expect(jsonDecode(saved!.body), {'category': 'EDUCATION'});
    expect(find.textContaining('当前修订 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'auditor can inspect application but cannot register classify or choose',
      (tester) async {
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      expect(r.method, 'GET');
      if (r.url.path.endsWith('/applications')) {
        return response({
          'items': [application()],
          'nextCursor': null
        });
      }
      if (r.url.path.endsWith('/classification')) {
        return response(classification());
      }
      return response(application());
    }));
    final session = _Session(api)..role = 'AUDITOR';
    await tester.pumpWidget(
        MaterialApp(home: ApplicationCenter(session: session, choosing: true)));
    await tester.pumpAndSettle();
    expect(find.text('登记 / 恢复'), findsNothing);
    await tester.tap(find.text('学习应用'));
    await tester.pumpAndSettle();
    expect(find.text('应用身份详情'), findsOneWidget);
    expect(find.text('修改报表分类'), findsNothing);
    expect(find.text('用于当前规则'), findsNothing);
  });
  test(
      'validates identity and digest boundaries without guessing classification',
      () {
    validateApplication(definition());
    validateApplication({...definition(), 'signingDigests': []});
    for (final bad in [
      {...definition(), 'packageName': 'https://example.com'},
      {...definition(), 'platform': 'IOS'},
      {
        ...definition(),
        'signingDigests': ['A' * 64]
      },
      {
        ...definition(),
        'signingDigests': ['a' * 64, 'a' * 64]
      },
      {...definition(), 'signingDigests': List.filled(9, 'a' * 64)}
    ]) {
      expect(() => validateApplication(bad), throwsFormatException);
    }
    expect(
        () => readClassification(
            classification(platform: 'ANDROID_TV'), application()),
        throwsA(isA<ParentApiException>()));
  });
  test(
      'durable declaration recovers exact original request after response loss',
      () async {
    final storage = _Storage();
    final calls = <http.Request>[];
    final api = ParentApi(() => Future.value('fixture'),
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      calls.add(r);
      expect(storage.values, hasLength(1));
      if (!r.url.path.endsWith('/query')) throw http.ClientException('lost');
      return response(application());
    }));
    final first = _controller(api, storage);
    await first.load();
    await first.execute({'operation': 'DECLARE', 'definition': definition()});
    final key = first.pending!['requestId'];
    first.dispose();
    final restored = _controller(api, storage);
    await restored.load();
    await restored.query();
    expect(calls, hasLength(2));
    expect(calls.last.url.path.endsWith('/$key/query'), isTrue);
    expect(jsonDecode(calls.first.body), jsonDecode(calls.last.body));
    expect(restored.result!['application']['id'], appId);
    expect(await restored.acknowledge(), isTrue);
    expect(storage.values, isEmpty);
  });
  test(
      'classification preserves original version and returns later shared category separately',
      () async {
    final storage = _Storage();
    final calls = <http.Request>[];
    final api = ParentApi(() => Future.value('fixture'),
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      calls.add(r);
      if (r.method == 'PUT') {
        expect(r.headers['If-Match'], '"0"');
        expect(jsonDecode(r.body), {'category': 'EDUCATION'});
        throw http.ClientException('lost');
      }
      expect(jsonDecode(r.body), {'version': 0, 'category': 'EDUCATION'});
      return response({
        'committed': classification(version: 1, category: 'EDUCATION'),
        'current': classification(version: 2, category: 'OTHER')
      });
    }));
    final c = _controller(api, storage);
    await c.load();
    await c.execute({
      'operation': 'CLASSIFY',
      'application': application(),
      'version': 0,
      'category': 'EDUCATION'
    });
    await c.query();
    expect(calls, hasLength(2));
    expect(c.result!['current']['category'], 'OTHER');
    expect(c.result!['committed']['category'], 'EDUCATION');
  });
  test(
      'failed persistence stops dispatch and retains possible journal for reload',
      () async {
    final storage = _Storage()..failWrite = true;
    var calls = 0;
    final api = ParentApi(() => Future.value('fixture'),
        baseUrl: 'https://fixture.invalid', client: MockClient((_) async {
      calls++;
      return response(application());
    }));
    final c = _controller(api, storage);
    await c.load();
    await c.execute({'operation': 'DECLARE', 'definition': definition()});
    expect(calls, 0);
    expect(c.loaded, isFalse);
    expect(storage.values, hasLength(1));
  });
  test(
      'unknown creation remains pending until explicit acknowledgement after lookup',
      () async {
    final storage = _Storage();
    var calls = 0;
    final api = ParentApi(() => Future.value('fixture'),
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      calls++;
      return response({
        'errorCode': r.url.path.endsWith('/query')
            ? 'APPLICATION_CREATION_RESULT_UNAVAILABLE'
            : 'UNAVAILABLE'
      }, r.url.path.endsWith('/query') ? 404 : 503);
    }));
    final c = _controller(api, storage);
    await c.load();
    await c.execute({'operation': 'DECLARE', 'definition': definition()});
    expect(await c.acknowledge(), isFalse);
    await c.query();
    expect(c.pending, isNotNull);
    await c.execute({'operation': 'DECLARE', 'definition': definition()});
    expect(calls, 2);
    expect(await c.acknowledge(), isTrue);
  });
  test(
      'mismatched signer or classification identity never clears original record',
      () async {
    for (final kind in ['DECLARE', 'CLASSIFY']) {
      final storage = _Storage();
      final api = ParentApi(() => Future.value('fixture'),
          baseUrl: 'https://fixture.invalid',
          client: MockClient((_) async => response(kind == 'DECLARE'
              ? {
                  ...application(),
                  'signingDigests': ['b' * 64]
                }
              : classification(
                  version: 1, category: 'EDUCATION', platform: 'ANDROID_TV'))));
      final c = _controller(api, storage);
      await c.load();
      await c.execute(kind == 'DECLARE'
          ? {'operation': kind, 'definition': definition()}
          : {
              'operation': kind,
              'application': application(),
              'version': 0,
              'category': 'EDUCATION'
            });
      expect(c.result, isNull);
      expect(c.pending, isNotNull);
      expect(await c.acknowledge(), isFalse);
    }
  });
  test('scope change during token retrieval stops declaration', () async {
    final token = Completer<String>();
    var current = true, calls = 0;
    final storage = _Storage();
    final api = ParentApi(() => token.future,
        baseUrl: 'https://fixture.invalid', client: MockClient((_) async {
      calls++;
      return response(application());
    }));
    final c = _controller(api, storage, current: () => current);
    await c.load();
    final pending =
        c.execute({'operation': 'DECLARE', 'definition': definition()});
    await Future<void>.delayed(Duration.zero);
    current = false;
    token.complete('new-token');
    await pending;
    expect(calls, 0);
    expect(storage.values, hasLength(1));
  });
  testWidgets(
      'registration requires review and returns declared identity only after acknowledgement',
      (tester) async {
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Json? submitted, opened;
    final storage = _Storage();
    final api = ParentApi(() => Future.value('fixture'),
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      submitted = jsonDecode(r.body);
      return response(
          {'id': appId, ...submitted!, 'evidenceStatus': 'ADMIN_DECLARED'},
          201);
    }));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      opened = await Navigator.of(ctx).push<Json>(
                          MaterialPageRoute(
                              builder: (_) => CatalogOperationPage(
                                  session: _Session(api),
                                  store: CatalogOperationStore(
                                      storage: storage))));
                    },
                    child: const Text('登记'))))));
    await tester.tap(find.text('登记'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), '学习应用');
    await tester.enterText(
        find.byType(TextFormField).at(1), 'org.example.Reader');
    await tester.enterText(
        find.byType(TextFormField).at(2), List.filled(32, 'AA').join(':'));
    await tester.ensureVisible(find.text('核对并保存'));
    await tester.tap(find.text('核对并保存'));
    await tester.pumpAndSettle();
    expect(submitted, isNull);
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(submitted!['signingDigests'], ['a' * 64]);
    expect(opened, isNull);
    await tester.ensureVisible(find.text('完成核对，打开应用'));
    await tester.tap(find.text('完成核对，打开应用'));
    await tester.pumpAndSettle();
    expect(opened!['id'], appId);
    expect(storage.values, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'new rule selects application from paged detail without fetching full catalog',
      (tester) async {
    tester.view.physicalSize = const Size(700, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Json? saved;
    var listReads = 0;
    final draft = <String, dynamic>{
      'id': 'policy',
      'name': '规则',
      'kind': 'POLICY',
      'revision': 0,
      'rules': []
    };
    final api = ParentApi(() => Future.value('fixture'),
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') {
        saved = jsonDecode(r.body);
        return response({...draft, ...saved!, 'revision': 1});
      }
      if (r.url.path.endsWith('/applications')) {
        listReads++;
        expect(r.url.queryParameters['limit'], '50');
        return response({
          'items': [application()],
          'nextCursor': null
        });
      }
      if (r.url.path.endsWith('/classification')) {
        return response(classification());
      }
      return response(application());
    }));
    await tester.pumpWidget(MaterialApp(
        home: PolicyDraftEditor(session: _Session(api), draft: draft)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用启动'));
    await tester.pumpAndSettle();
    expect(listReads, 0);
    await tester.tap(find.text('选择或登记应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用于当前规则'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('完成规则编辑'));
    await tester.tap(find.text('完成规则编辑'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    await tester.tap(find.text('保存草稿'));
    await tester.pumpAndSettle();
    expect(saved!['rules'][0]['applicationId'], appId);
    expect(listReads, 1);
  });
  testWidgets('scope change closes application directory and nested details',
      (tester) async {
    final api = ParentApi(() => Future.value('fixture'),
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/applications')) {
        return response({
          'items': [application()],
          'nextCursor': null
        });
      }
      if (r.url.path.endsWith('/classification')) {
        return response(classification());
      }
      return response(application());
    }));
    final session = _Session(api);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                        builder: (_) => ApplicationCenter(session: session))),
                    child: const Text('入口'))))));
    await tester.tap(find.text('入口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习应用'));
    await tester.pumpAndSettle();
    session.changeScope();
    await tester.pumpAndSettle();
    expect(find.text('入口'), findsOneWidget);
    expect(find.text('应用身份详情'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
