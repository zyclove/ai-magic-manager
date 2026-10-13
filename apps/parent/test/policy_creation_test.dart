import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/core/policy_creation.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/policy_creation_page.dart';

class _CreationSession extends ParentSession {
  final ParentApi fixture;
  _CreationSession(this.fixture) {
    tenant = {'id': 'tenant'};
    profile = {'subject': 'guardian'};
    role = 'GUARDIAN';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
}

class MemoryDurableStorage extends ParentDurableStorage {
  final values = <String, String>{};
  bool failWrite = false, failDelete = false;
  Completer<void>? writeBarrier;
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
    if (writeBarrier != null) await writeBarrier!.future;
    if (failWrite) throw StateError('flush failed');
  }

  @override
  Future<void> delete({required String key}) async {
    if (failDelete) throw StateError('delete failed');
    values.remove(key);
  }
}

const draftId = '00000000-0000-4000-8000-000000000001';
const templateId = '00000000-0000-4000-8000-000000000002';
Json draft({int revision = 0, String kind = 'POLICY'}) => {
      'id': draftId,
      'name': '学习安排',
      'kind': kind,
      'revision': revision,
      'rules': <Json>[],
    };
http.Response response(Json data, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), status);

void main() {
  late MemoryDurableStorage storage;
  late PolicyCreationStore store;
  late List<http.Request> calls;
  PolicyCreationController controller(
      Future<http.Response> Function(http.Request) handler,
      {String actor = 'guardian',
      bool Function()? isCurrent,
      Future<String> Function()? token}) {
    return PolicyCreationController(
        tenant: 'tenant',
        actor: actor,
        store: store,
        isCurrent: isCurrent ?? () => true,
        api: ParentApi(token ?? () async => 'fixture',
            baseUrl: 'https://fixture.invalid/api/v1',
            client: MockClient((request) async {
          calls.add(request);
          return handler(request);
        })));
  }

  setUp(() {
    storage = MemoryDurableStorage();
    store = PolicyCreationStore(storage: storage);
    calls = [];
  });

  for (final copy in [false, true]) {
    testWidgets(
        copy
            ? 'template-copy page opens its independent draft'
            : 'new-draft page validates name then opens the created result',
        (tester) async {
      tester.view.physicalSize = const Size(900, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final requests = <http.Request>[];
      final api = ParentApi(() async => 'fixture',
          baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
        requests.add(r);
        return response(draft(), 201);
      }));
      Json? returned;
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        returned = await Navigator.of(context).push<Json>(
                            MaterialPageRoute(
                                builder: (_) => PolicyCreationPage(
                                    session: _CreationSession(api),
                                    store: store,
                                    template: copy
                                        ? {
                                            'id': templateId,
                                            'name': '机构学习模板',
                                            'revision': 4
                                          }
                                        : null)));
                      },
                      child: const Text('开始创建'))))));
      await tester.tap(find.text('开始创建'));
      await tester.pumpAndSettle();
      final action = copy ? '创建独立副本' : '创建空草稿';
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.text('请填写便于识别的名称'), findsOneWidget);
      expect(requests, isEmpty);
      await tester.enterText(
          find.byType(TextFormField), List.filled(51, '😀').join());
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.text('名称过长，请缩短后再提交'), findsOneWidget);
      expect(requests, isEmpty);
      await tester.enterText(find.byType(TextFormField), '学习安排');
      await tester.pump();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.text('原创建已确认'), findsOneWidget);
      expect(storage.values, hasLength(1));
      await tester.tap(find.text('打开草稿'));
      await tester.pumpAndSettle();
      expect(returned!['id'], draftId);
      expect(requests, hasLength(1));
      expect(storage.values, isEmpty);
      expect(
          requests.single.url.path,
          copy
              ? '/tenants/tenant/policies/$templateId/copies'
              : '/tenants/tenant/policies');
    });
  }

  test(
      'creation waits for durable storage before POST and retains the original key',
      () async {
    storage.writeBarrier = Completer<void>();
    final c = controller((_) async => response(draft(), 201));
    await c.load();
    final creating = c.create(name: ' 学习安排 ', kind: 'POLICY');
    await Future<void>.delayed(Duration.zero);
    expect(calls, isEmpty);
    expect(storage.values, hasLength(1));
    storage.writeBarrier!.complete();
    await creating;
    expect(calls, hasLength(1));
    expect(calls.single.headers['Idempotency-Key'], c.pending!.requestId);
    expect(jsonDecode(calls.single.body),
        {'name': '学习安排', 'kind': 'POLICY', 'rules': []});
    expect(c.result!['id'], draftId);
    expect(await store.load('tenant', 'guardian'), isNotNull);
    await c.create(name: 'duplicate', kind: 'POLICY');
    expect(calls, hasLength(1));
    expect(await c.acknowledge(), isTrue);
    expect(storage.values, isEmpty);
  });

  test(
      'failed durability confirmation stops POST even when a local value exists',
      () async {
    storage.failWrite = true;
    final c = controller((_) async => response(draft(), 201));
    await c.load();
    await c.create(name: '学习安排', kind: 'POLICY');
    expect(calls, isEmpty);
    expect(c.loaded, isFalse);
    storage.failWrite = false;
    await c.load();
    expect(c.pending, isNotNull);
    await c.create(name: 'duplicate', kind: 'POLICY');
    expect(calls, isEmpty);
  });

  test(
      'lost response recovers current result after restart without repeating creation',
      () async {
    final first =
        controller((_) async => throw http.ClientException('lost response'));
    await first.load();
    await first.create(name: '学习安排', kind: 'POLICY');
    final key = first.pending!.requestId;
    first.dispose();
    final restored = controller((_) async => response(draft(revision: 3)));
    await restored.load();
    await restored.query();
    expect(calls, hasLength(2));
    expect(calls.last.url.path,
        '/api/v1/tenants/tenant/policy-draft-creation-results/$key/query');
    expect(calls.last.url.query, isEmpty);
    expect(jsonDecode(calls.last.body),
        {'operation': 'EMPTY_DRAFT', 'name': '学习安排', 'kind': 'POLICY'});
    expect(restored.result!['revision'], 3);
    expect(restored.pending!.requestId, key);
  });

  test(
      'template copy binds revision and lookup shape without mutating template',
      () async {
    final c = controller((_) async => response(draft(), 201));
    await c.load();
    await c.create(
        name: '学习安排',
        kind: 'POLICY',
        templateId: templateId,
        templateRevision: 9);
    expect(calls.single.url.path.endsWith('/$templateId/copies'), isTrue);
    expect(calls.single.headers['If-Match'], '"9"');
    expect(jsonDecode(calls.single.body), {'name': '学习安排'});
    expect(c.pending!.query, {
      'operation': 'TEMPLATE_COPY',
      'name': '学习安排',
      'kind': 'POLICY',
      'templateId': templateId,
      'templateRevision': 9
    });
  });

  test('404 is inconclusive and never silently clears the pending marker',
      () async {
    final c = controller((request) async => request.url.path.endsWith('/query')
        ? response({'errorCode': 'POLICY_CREATION_RESULT_UNAVAILABLE'}, 404)
        : response({'errorCode': 'UNAVAILABLE'}, 503));
    await c.load();
    await c.create(name: '学习安排', kind: 'POLICY');
    expect(await c.acknowledge(), isFalse);
    await c.query();
    expect(c.queried, isTrue);
    expect(c.result, isNull);
    expect(c.pending, isNotNull);
    await c.create(name: 'again', kind: 'POLICY');
    expect(calls, hasLength(2));
    expect(await c.acknowledge(), isTrue);
  });

  test(
      'malformed response and query authorization failures keep recovery locked',
      () async {
    final c = controller((request) async => request.url.path.endsWith('/query')
        ? response({'errorCode': 'SCOPE_DENIED'}, 403)
        : response(draft(kind: 'TEMPLATE'), 201));
    await c.load();
    await c.create(name: '学习安排', kind: 'POLICY');
    expect(c.result, isNull);
    expect(c.pending, isNotNull);
    await c.query();
    expect(c.queried, isFalse);
    expect(await c.acknowledge(), isFalse);
  });

  test('scope changes while waiting for token prevent creation dispatch',
      () async {
    final token = Completer<String>();
    var current = true;
    final c = controller((_) async => response(draft(), 201),
        isCurrent: () => current, token: () => token.future);
    await c.load();
    final creating = c.create(name: '学习安排', kind: 'POLICY');
    await Future<void>.delayed(Duration.zero);
    current = false;
    token.complete('another-token');
    await creating;
    expect(calls, isEmpty);
    expect(await store.load('tenant', 'guardian'), isNotNull);
  });

  test('storage deletion failure retains the recovery and allows another query',
      () async {
    final c = controller((_) async => response(draft(), 201));
    await c.load();
    await c.create(name: '学习安排', kind: 'POLICY');
    storage.failDelete = true;
    expect(await c.acknowledge(), isFalse);
    expect(c.pending, isNotNull);
    storage.failDelete = false;
    await c.query();
    expect(await c.acknowledge(), isTrue);
  });

  test(
      'corrupt records block creation and another actor cannot load the record',
      () async {
    final c = controller((_) async => response(draft(), 201));
    await c.load();
    await c.create(name: '学习安排', kind: 'POLICY');
    final other =
        controller((_) async => response(draft()), actor: 'someone-else');
    await other.load();
    expect(other.pending, isNull);
    storage.values.updateAll((_, value) =>
        value.replaceFirst('"kind":"POLICY"', '"kind":"UNKNOWN"'));
    await c.load();
    expect(c.loaded, isFalse);
    await c.create(name: 'overwrite', kind: 'POLICY');
    expect(calls, hasLength(1));
  });
}
