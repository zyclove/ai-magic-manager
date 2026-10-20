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
import 'package:parent/core/ownership.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/ownership_center.dart';

import 'support/parent_operation_journal_fixture.dart';

const tenant = '00000000-0000-4000-8000-000000000001',
    transfer = '00000000-0000-4000-8000-000000000002';
Json record({String state = 'PENDING', int version = 0}) => {
      'tenantId': tenant,
      'id': transfer,
      'sourceActorId': 'owner',
      'targetActorId': 'recipient',
      'sourceMemberVersion': 0,
      'targetMemberVersion': 0,
      'targetRole': 'AUDITOR',
      'formerOwnerRole': 'GUARDIAN',
      'tenantVersion': 0,
      'state': state,
      'reason': null,
      'createdAt': 1,
      'expiresAt': 4102444800000,
      'updatedAt': version + 1,
      'version': version
    };
Json queryResult(String key,
        {String who = 'owner',
        String action = 'start',
        String state = 'ACCEPTED',
        String original = 'PENDING'}) =>
    {
      'requestId': key,
      'actorId': who,
      'operation': action,
      'original':
          record(state: original, version: original == 'PENDING' ? 0 : 1),
      'current': record(state: state, version: state == 'PENDING' ? 0 : 1),
      'currentRole': who == 'owner' ? 'GUARDIAN' : 'OWNER'
    };
Json get startInput =>
    {'operation': 'start', 'version': 0, 'targetActorId': 'recipient'};
Json get member => {
      'actorId': 'recipient',
      'cursor': 'a' * 64,
      'role': 'AUDITOR',
      'version': 0,
      'subjectId': null,
      'classIds': [],
      'displayName': '林老师',
      'verifiedEmail': 'teacher@example.test',
      'subjectName': null,
      'subjectArchived': false
    };
http.Response response(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);
ParentApi api(Future<http.Response> Function(http.Request) handler) =>
    ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1', client: MockClient(handler));

class Storage extends ParentDurableStorage with ParentAtomicJournalFixture {
  final values = <String, String>{};
  bool fail = false;
  Completer<void>? barrier;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    if (fail) throw StateError('disk');
    values[key] = value;
    await barrier?.future;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

OwnershipOperation operation(ParentApi api, Storage storage,
        {String who = 'owner', bool Function()? active}) =>
    OwnershipOperation(
        api: api,
        tenant: tenant,
        actor: who,
        store: OwnershipStore(storage: storage),
        isCurrent: active ?? () => true);

class Session extends ParentSession {
  final ParentApi fixture;
  int refreshes = 0;
  Session(this.fixture, {String who = 'owner', String grant = 'OWNER'}) {
    profile = {'subject': who, 'name': '陈家长'};
    this.tenant = {
      'id': tenantId,
      'kind': 'FAMILY',
      'name': '晨光家庭',
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
  @override
  Future<void> initialize() async {
    refreshes++;
  }

  void changed() {
    generation++;
    notifyListeners();
  }
}

void main() {
  test(
      'strict transfer and operation contracts reject unknown scopes and extra fields',
      () {
    expect(readOwnership(record(), tenant)['id'], transfer);
    for (final bad in [
      <String, dynamic>{...record(), 'state': 'UNKNOWN'},
      {...record(), 'tenantId': 'other'},
      {...record(), 'sourceActorId': 'recipient'},
      {...record(), 'version': -1},
      {...record(), 'targetRole': 'CHILD'},
      {...record(), 'reason': 'TIME_EXPIRED'}
    ]) {
      expect(
          () => readOwnership(bad, tenant), throwsA(isA<ParentApiException>()));
    }
    validateOwnershipInput(startInput);
    expect(() => validateOwnershipInput({...startInput, 'token': 'secret'}),
        throwsFormatException);
    expect(
        () => validateOwnershipInput(
            {'operation': 'accept', 'version': 0, 'transferId': 'wrong'}),
        throwsFormatException);
  });
  test(
      'lost start reply persists original request and recovers after ownership changed',
      () async {
    final storage = Storage();
    int writes = 0;
    String? key;
    final client = api((r) async {
      if (r.url.path.endsWith('/query')) return response(queryResult(key!));
      writes++;
      key = r.headers['Idempotency-Key'];
      expect(storage.values.values.single, contains(key!));
      expect(r.headers['If-Match'], '"0"');
      expect(jsonDecode(r.body), {'targetActorId': 'recipient'});
      throw http.ClientException('lost');
    });
    final first = operation(client, storage);
    await first.load();
    await first.submit(startInput);
    expect(first.committed, false);
    first.dispose();
    final restored = operation(client, storage);
    await restored.load();
    expect(writes, 1);
    expect(restored.original, isNull);
    await restored.recover();
    expect(restored.original!['state'], 'PENDING');
    expect(restored.current!['state'], 'ACCEPTED');
    expect(restored.currentRole, 'GUARDIAN');
    expect(writes, 1);
    expect(await restored.acknowledge(), true);
    expect(storage.values, isEmpty);
    restored.dispose();
  });
  test('retry uses exactly the stored version key and target', () async {
    final storage = Storage(), requests = <http.Request>[];
    final op = operation(api((r) async {
      if (r.url.path.endsWith('/query')) {
        return response(queryResult(requests.first.headers['Idempotency-Key']!,
            state: 'PENDING'));
      }
      requests.add(r);
      if (requests.length == 1) throw http.ClientException('lost');
      return response(record());
    }), storage);
    await op.load();
    await op.submit(startInput);
    await op.recover(retry: true);
    expect(requests.length, 2);
    expect(requests.first.body, requests.last.body);
    expect(requests.first.headers['Idempotency-Key'],
        requests.last.headers['Idempotency-Key']);
    expect(
        requests.first.headers['If-Match'], requests.last.headers['If-Match']);
    expect(op.queried, true);
    op.dispose();
  });
  for (final action in ['accept', 'decline', 'cancel']) {
    test(
        '$action sends exact transition and distinguishes original from latest',
        () async {
      final storage = Storage(),
          state = action == 'accept'
              ? 'ACCEPTED'
              : action == 'decline'
                  ? 'DECLINED'
                  : 'CANCELLED',
          who = action == 'cancel' ? 'owner' : 'recipient';
      String? key;
      final op = operation(api((r) async {
        if (r.url.path.endsWith('/query')) {
          return response(queryResult(key!,
              who: who, action: action, state: state, original: state));
        }
        key = r.headers['Idempotency-Key'];
        expect(r.url.path.endsWith('/$transfer/$action'), true);
        expect(r.body, isEmpty);
        return response(record(state: state, version: 1));
      }), storage, who: who);
      await op.load();
      await op
          .submit({'operation': action, 'version': 0, 'transferId': transfer});
      expect(op.error, isNull);
      expect(op.current!['state'], state);
      op.dispose();
    });
  }
  for (final code in [
    'OWNERSHIP_RESULT_UNAVAILABLE',
    'IDEMPOTENCY_RESPONSE_ERASED'
  ]) {
    test('$code does not fabricate a successful transfer', () async {
      final storage = Storage();
      final op = operation(
          api((r) async {
            if (!r.url.path.endsWith('/query')) {
              return response({'errorCode': 'REAUTH_REQUIRED'}, 401);
            }
            return code == 'OWNERSHIP_RESULT_UNAVAILABLE'
                ? response({'errorCode': code}, 404)
                : parentJournalTerminalProblem(code);
          }),
          storage);
      await op.load();
      await op.submit(startInput);
      await op.recover();
      expect(op.queried, code == 'OWNERSHIP_RESULT_UNAVAILABLE');
      expect(op.committed, false);
      expect(op.current, isNull);
      expect(await (code == 'OWNERSHIP_RESULT_UNAVAILABLE'
          ? op.acknowledge() : op.endLocalCheck()), true);
      op.dispose();
    });
  }
  test(
      'storage failure blocks writes and background during save blocks dispatch',
      () async {
    final storage = Storage()..fail = true;
    int writes = 0;
    final op = operation(api((r) async {
      writes++;
      return response(record());
    }), storage);
    await op.load();
    await op.submit(startInput);
    expect(writes, 0);
    storage.fail = false;
    await op.load();
    storage.barrier = Completer<void>();
    final future = op.submit(startInput);
    await Future<void>.delayed(Duration.zero);
    op.suspend();
    storage.barrier!.complete();
    await future;
    expect(writes, 0);
    expect(op.loaded, false);
    expect(storage.values.length, 1);
    op.dispose();
  });
  test('foreground loss during token refresh cannot submit later', () async {
    final storage = Storage(), token = Completer<String>();
    int writes = 0;
    final client =
        ParentApi(() => token.future, baseUrl: 'https://fixture.invalid/api/v1',
            client: MockClient((r) async {
      writes++;
      return response(record());
    }));
    final op = operation(client, storage);
    await op.load();
    final submit = op.submit(startInput);
    await Future<void>.delayed(Duration.zero);
    op.suspend();
    token.complete('fixture');
    await submit;
    expect(writes, 0);
    expect(op.pending, isNotNull);
    op.dispose();
  });
  test('query rejects wrong recipient or changed immutable references',
      () async {
    for (final corrupt in ['actor', 'id']) {
      final storage = Storage();
      String? key;
      final op = operation(api((r) async {
        if (!r.url.path.endsWith('/query')) {
          key = r.headers['Idempotency-Key'];
          throw http.ClientException('lost');
        }
        final result = queryResult(key!);
        if (corrupt == 'actor') {
          result['actorId'] = 'other';
        } else {
          result['current']['id'] = '00000000-0000-4000-8000-000000000009';
        }
        return response(result);
      }), storage);
      await op.load();
      await op.submit(startInput);
      await op.recover();
      expect(op.error, isA<ParentApiException>());
      expect(op.current, isNull);
      expect(op.committed, false);
      op.dispose();
    }
  });
  test('stores are scoped and reject extra identity data', () async {
    final storage = Storage(), store = OwnershipStore(storage: Storage());
    final target = OwnershipStore(storage: storage);
    final row = {
      'requestId': '00000000-0000-4000-8000-000000000008',
      'input': startInput
    };
    await target.save(tenant, 'owner', row);
    expect(await target.load(tenant, 'recipient'), isNull);
    expect(await store.load(tenant, 'owner'), isNull);
    storage.values[target.key(tenant, 'owner')] =
        jsonEncode({...row, 'email': 'private@example.test'});
    expect(() => target.load(tenant, 'owner'), throwsFormatException);
  });
  for (final scale in [1.0, 2.0]) {
    testWidgets(
        'owner chooses named member and confirms consequences at font scale $scale',
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
      String? key;
      int writes = 0;
      final storage = Storage();
      final session = Session(api((r) async {
        if (r.url.path.endsWith('/members')) {
          return response({
            'items': [member],
            'nextCursor': null
          });
        }
        if (r.method == 'GET') {
          return response({'items': [], 'nextCursor': null});
        }
        if (r.url.path.endsWith('/query')) {
          return response(queryResult(key!, state: 'PENDING'));
        }
        writes++;
        key = r.headers['Idempotency-Key'];
        return response(record());
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
              home: OwnershipCenter(
                  session: session, store: OwnershipStore(storage: storage)))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择接收成员'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('林老师'));
      await tester.pumpAndSettle();
      expect(find.text('接收账号：recipient'), findsOneWidget);
      expect(writes, 0);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('CAPTURE_OWNERSHIP_UI') && scale == 1) {
        await tester.runAsync(() async {
          final image = await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('../../.local/parent-ownership-portrait.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('确认发起交接'));
      await tester.pumpAndSettle();
      expect(writes, 0);
      expect(find.textContaining('接收账号：recipient'), findsWidgets);
      await tester.ensureVisible(find.text('发起，等待对方确认'));
      await tester.tap(find.text('发起，等待对方确认'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(find.text('原操作结果：等待接收人确认'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('完成核对，刷新权限'));
      await tester.tap(find.text('完成核对，刷新权限'));
      await tester.pumpAndSettle();
      expect(session.refreshes, 1);
      expect(storage.values, isEmpty);
    });
  }
  testWidgets(
      'recipient can accept from account entry without member administration',
      (tester) async {
    String? key;
    int writes = 0;
    final session = Session(api((r) async {
      if (r.method == 'GET') {
        return response(r.url.path.endsWith('/$transfer')
            ? record()
            : {
                'items': [record()],
                'nextCursor': null
              });
      }
      if (r.url.path.endsWith('/query')) {
        return response(queryResult(key!,
            who: 'recipient', action: 'accept', original: 'ACCEPTED'));
      }
      writes++;
      key = r.headers['Idempotency-Key'];
      return response(record(state: 'ACCEPTED', version: 1));
    }), who: 'recipient', grant: 'AUDITOR');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                            builder: (_) => OwnershipCenter(
                                session: session,
                                store: OwnershipStore(storage: Storage())))),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('选择接收成员'), findsNothing);
    await tester.tap(find.text('等待接收人确认'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('接受并成为所有者'));
    await tester.tap(find.text('接受并成为所有者'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '接受并成为所有者').last);
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.text('原操作结果：交接已完成'), findsOneWidget);
  });
  testWidgets(
      'background hides sensitive details and closes confirmation; identity change closes page',
      (tester) async {
    int writes = 0;
    final session = Session(api((r) async {
      if (r.method != 'GET') writes++;
      return response(r.url.path.endsWith('/$transfer')
          ? record()
          : {
              'items': [record()],
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
                            builder: (_) => OwnershipCenter(
                                session: session,
                                store: OwnershipStore(storage: Storage())))),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('等待接收人确认'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('撤销本次交接'));
    await tester.tap(find.text('撤销本次交接'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('交接内容已隐藏。'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    session.changed();
    await tester.pumpAndSettle();
    expect(find.byType(OwnershipCenter), findsNothing);
    expect(writes, 0);
  });
  testWidgets('child and teacher do not get ownership entry', (tester) async {
    for (final role in ['CHILD', 'TEACHER']) {
      final session = Session(api((_) async => response({})), grant: role);
      await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: OwnershipEntry(session: session))));
      expect(find.text('所有者交接'), findsNothing);
    }
  });
}
