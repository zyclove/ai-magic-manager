import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/core/policy_group_selection.dart';
import 'package:parent/ui/policy_group_picker.dart';
import 'package:parent/ui/policy_center.dart';

const groupId = '00000000-0000-4000-8000-000000000001';
const deviceId = '00000000-0000-4000-8000-000000000002';
const registrationId = '00000000-0000-4000-8000-000000000003';
Json group({int version = 4, String state = 'ACTIVE'}) => {
      'id': groupId,
      'name': '一年级设备',
      'version': version,
      'state': state,
      'deviceCount': 2,
    };
Json member({String registration = registrationId}) => {
      'deviceId': deviceId,
      'registrationId': registration,
      'displayName': '学习平板',
      'membershipStatus': 'CURRENT',
      'state': 'ACTIVE',
    };
http.Response response(Json data) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), 200);
Matcher code(String code) =>
    isA<ParentApiException>().having((e) => e.code, 'error code', code);

class _Session extends ParentSession {
  final ParentApi fixture;
  _Session(this.fixture) {
    tenant = {'id': 'tenant', 'kind': 'ORGANIZATION'};
    profile = {'subject': 'admin'};
    role = 'ORG_ADMIN';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
}

void main() {
  ParentApi api(Json Function(http.Request) result) =>
      ParentApi(() async => 'fixture',
          baseUrl: 'https://fixture.invalid',
          client: MockClient((r) async => response(result(r))));

  test(
      'complete selection binds group version and immutable registration facts',
      () async {
    final requests = <http.Request>[];
    final transport = api((r) {
      requests.add(r);
      return r.url.path.endsWith('/devices')
          ? {
              'items': [member()],
              'nextCursor': null
            }
          : group();
    });
    final selected = await PolicyGroupSelection.load(
        transport, 'tenant', groupId, () => true);
    expect(selected.reference, {'groupId': groupId, 'groupVersion': 4});
    expect(selected.registrations, {deviceId: registrationId});
    expect(selected.excludedCount, 1);
    expect(
        requests[1].url.queryParameters, {'status': 'CURRENT', 'limit': '50'});
    expect(() => selected.registrations.clear(), throwsUnsupportedError);
    expect(selected.matchesReference({'groupId': groupId, 'groupVersion': 5}),
        isFalse);
  });

  test('oversized group is rejected rather than truncating its first page',
      () async {
    final transport = api((r) => r.url.path.endsWith('/devices')
        ? {
            'items': [member()],
            'nextCursor': deviceId
          }
        : group());
    await expectLater(
        PolicyGroupSelection.load(transport, 'tenant', groupId, () => true),
        throwsA(code('POLICY_GROUP_TOO_LARGE')));
  });

  test('empty active membership cannot become an empty policy target',
      () async {
    final transport = api((r) => r.url.path.endsWith('/devices')
        ? {'items': [], 'nextCursor': null}
        : group());
    await expectLater(
        PolicyGroupSelection.load(transport, 'tenant', groupId, () => true),
        throwsA(code('POLICY_GROUP_EMPTY')));
  });

  for (final malformed in ['duplicate', 'stale', 'inactive']) {
    test('rejects $malformed member responses', () async {
      final row = member();
      if (malformed == 'stale') row['membershipStatus'] = 'STALE_REGISTRATION';
      if (malformed == 'inactive') row['state'] = 'REVOKED';
      final transport = api((r) => r.url.path.endsWith('/devices')
          ? {
              'items': [row, if (malformed == 'duplicate') row],
              'nextCursor': null
            }
          : group());
      await expectLater(
          PolicyGroupSelection.load(transport, 'tenant', groupId, () => true),
          throwsA(code('INVALID_RESPONSE')));
    });
  }

  test('version drift during loading prevents confirmation', () async {
    var reads = 0;
    final transport = api((r) => r.url.path.endsWith('/devices')
        ? {
            'items': [member()],
            'nextCursor': null
          }
        : group(version: ++reads));
    await expectLater(
        PolicyGroupSelection.load(transport, 'tenant', groupId, () => true),
        throwsA(code('POLICY_GROUP_CHANGED')));
  });

  test(
      'registration changes invalidate snapshot even with unchanged group version',
      () async {
    var registration = registrationId;
    final transport = api((r) => r.url.path.endsWith('/devices')
        ? {
            'items': [member(registration: registration)],
            'nextCursor': null
          }
        : group());
    final selected = await PolicyGroupSelection.load(
        transport, 'tenant', groupId, () => true);
    registration = '00000000-0000-4000-8000-000000000004';
    await expectLater(selected.recheck(transport, 'tenant', () => true),
        throwsA(code('POLICY_GROUP_CHANGED')));
  });

  test('scope change stops further reads', () async {
    var current = true, reads = 0;
    final transport = api((r) {
      reads++;
      current = false;
      return group();
    });
    await expectLater(
        PolicyGroupSelection.load(transport, 'tenant', groupId, () => current),
        throwsA(code('SCOPE_DENIED')));
    expect(reads, 1);
  });

  testWidgets('policy preview sends and validates the selected group source',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const policyId = '00000000-0000-4000-8000-000000000005';
    final policy = {
      'id': policyId,
      'name': '工作日学习',
      'revision': 0,
      'kind': 'POLICY',
      'rules': []
    };
    Json? previewInput;
    final transport = api((r) {
      if (r.url.path.endsWith('/policies')) {
        return {
          'items': [policy],
          'nextCursor': null
        };
      }
      if (r.url.path.endsWith('/policies/$policyId')) return policy;
      if (r.url.path.endsWith('/device-groups')) {
        return {
          'items': [group()],
          'nextCursor': null
        };
      }
      if (r.url.path.endsWith('/device-groups/$groupId/devices')) {
        return {
          'items': [member()],
          'nextCursor': null
        };
      }
      if (r.url.path.endsWith('/device-groups/$groupId')) return group();
      if (r.url.path.endsWith('/devices')) {
        return {'items': [], 'nextCursor': null};
      }
      if (r.url.path.endsWith('/previews')) {
        previewInput = jsonDecode(r.body) as Json;
        return {
          'id': '00000000-0000-4000-8000-000000000006',
          'policyId': policyId,
          'draftRevision': 0,
          'phase': 'PREVIEW',
          'hash': 'a' * 64,
          'enforceable': false,
          'expiresAt': DateTime.now().millisecondsSinceEpoch + 300000,
          'snapshot': {
            'groupSelection': {'groupId': groupId, 'groupVersion': 4}
          },
          'targets': [
            {
              'deviceId': deviceId,
              'registrationId': registrationId,
              'rules': []
            }
          ]
        };
      }
      throw StateError('Unexpected route: ${r.url.path}');
    });
    await tester.pumpWidget(
        MaterialApp(home: PolicyCenter(session: _Session(transport))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作日学习'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从设备组选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一年级设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用此组快照'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览所选设备'));
    await tester.pumpAndSettle();
    expect(previewInput, {
      'deviceIds': [deviceId],
      'groupId': groupId,
      'groupVersion': 4
    });
    expect(find.text('设备检查结果'), findsOneWidget);
    await tester.tap(find.text('清空分组选择，改为逐台选择'));
    await tester.pumpAndSettle();
    expect(find.text('设备检查结果'), findsNothing);
    expect(find.text('选择目标设备 · 0/50'), findsOneWidget);
  });

  testWidgets(
      'picker requires explicit snapshot confirmation and returns no partial group',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <http.Request>[];
    final transport = api((r) {
      requests.add(r);
      if (r.url.path.endsWith('/device-groups')) {
        return {
          'items': [group()],
          'nextCursor': null
        };
      }
      if (r.url.path.endsWith('/devices')) {
        return {
          'items': [member()],
          'nextCursor': null
        };
      }
      return group();
    });
    PolicyGroupSelection? selected;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      selected = await Navigator.of(context)
                          .push<PolicyGroupSelection>(MaterialPageRoute(
                              builder: (_) => PolicyGroupPicker(
                                  session: _Session(transport))));
                    },
                    child: const Text('选择设备'))))));
    await tester.tap(find.text('选择设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一年级设备'));
    await tester.pumpAndSettle();
    expect(find.text('使用此组快照'), findsOneWidget);
    expect(selected, isNull);
    await tester.tap(find.text('使用此组快照'));
    await tester.pumpAndSettle();
    expect(selected!.registrations, {deviceId: registrationId});
    expect(selected!.excludedCount, 1);
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    expect(tester.takeException(), isNull);
  });
}
