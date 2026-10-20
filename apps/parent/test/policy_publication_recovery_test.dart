import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/core/pending_publications.dart';
import 'package:parent/ui/policy_center.dart';

import 'support/parent_operation_journal_fixture.dart';

class _RecoverySession extends ParentSession {
  final ParentApi transport;
  _RecoverySession(this.transport) {
    tenant = {'id': 'tenant'};
    profile = {'subject': 'adult'};
    role = 'GUARDIAN';
  }
  @override
  ParentApi get api => transport;
  @override
  bool get authenticated => true;
}

const _policy = '00000000-0000-4000-8000-000000000001';
const _preview = '00000000-0000-4000-8000-000000000002';
const _request = '00000000-0000-4000-8000-000000000003';

void main() {
  for (final available in [true, false]) {
    testWidgets(
        available
            ? 'original publication lookup sends CONFIGURE_ONLY and survives recreation without republishing'
            : 'unavailable original result stays inconclusive without republishing',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const secure =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      const durable = MethodChannel('com.aimanager.parent/storage');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var storageMutations = 0;
      final pending = jsonEncode([
        {
          'policyId': _policy,
          'revision': 7,
          'previewId': _preview,
          'previewHash': 'a' * 64,
          'idempotencyKey': _request,
          'createdAt': 1792200000000,
        }
      ]);
      final journalStorage = ParentJournalFixtureStorage(onMutation: () => storageMutations++);
      for (final row in jsonDecode(pending) as List) {
        journalStorage.values['parent.pending.publications.tenant.adult.${row['policyId']}'] = jsonEncode(row);
      }
      messenger.setMockMethodCallHandler(secure, (call) async {
        if (call.method == 'read' &&
            (call.arguments as Map)['key'] ==
                'parent.pending.publications.tenant.adult') {
          return pending;
        }
        if (call.method == 'write' || call.method == 'delete') {
          storageMutations++;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(durable, (_) async => true);
      addTearDown(() {
        messenger.setMockMethodCallHandler(secure, null);
        messenger.setMockMethodCallHandler(durable, null);
      });
      final requests = <http.Request>[];
      http.Response response(Object body, int status) =>
          http.Response.bytes(utf8.encode(jsonEncode(body)), status,
              headers: {'content-type': 'application/json; charset=utf-8'});
      final api = ParentApi(() async => 'fixture',
          baseUrl: 'https://fixture.invalid/api/v1',
          client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.contains('/publication-results/')) {
          if (request.url.queryParameters['mode'] != 'CONFIGURE_ONLY') {
            return response({'errorCode': 'INVALID_MODE'}, 400);
          }
          return available
              ? response({
                  'id': _request,
                  'versionId': '00000000-0000-4000-8000-000000000004',
                  'sequence': 8,
                  'mode': 'CONFIGURE_ONLY',
                  'state': 'CONFIGURED_NOT_ENFORCED',
                }, 200)
              : response(
                  {'errorCode': 'POLICY_PUBLICATION_RESULT_UNAVAILABLE'}, 404);
        }
        return response({'items': [], 'nextCursor': null}, 200);
      }));
      addTearDown(api.close);
      for (var incarnation = 0; incarnation < 2; incarnation++) {
        final session = _RecoverySession(api);
        await tester
            .pumpWidget(MaterialApp(home: PolicyCenter(session: session,
                publicationStore: PendingPublicationStore(storage: journalStorage))));
        await tester.pumpAndSettle();
        expect(find.text('待核对的配置发布'), findsOneWidget);
        await tester.tap(find.text('查询原发布结果'));
        await tester.pumpAndSettle();
        final lookups = requests
            .where(
                (request) => request.url.path.contains('/publication-results/'))
            .toList();
        expect(lookups, hasLength(incarnation + 1));
        expect(lookups.last.url.path,
            '/api/v1/tenants/tenant/policies/$_policy/publication-results/$_request');
        expect(lookups.last.url.queryParameters, {
          'mode': 'CONFIGURE_ONLY',
          'revision': '7',
          'previewId': _preview,
          'previewHash': 'a' * 64,
        });
        expect(find.textContaining(available ? '原提交已保存为配置版本 8' : '这不能证明配置没有保存'),
            findsOneWidget);
        expect(requests.every((request) => request.method == 'GET'), isTrue);
        expect(storageMutations, available ? 1 : 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        session.dispose();
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}
