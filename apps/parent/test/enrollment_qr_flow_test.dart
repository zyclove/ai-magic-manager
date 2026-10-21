import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/ui/enrollment_flow.dart';
import 'package:parent/ui/pairing_qr.dart';
import 'package:qr_flutter/qr_flutter.dart';

class _Storage extends ParentDurableStorage {
  final values = <String, String>{};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

class _Session extends ParentSession {
  final ParentApi fixture;
  int reauths = 0;
  _Session(this.fixture) {
    profile = {'subject': 'adult'};
    tenant = {'id': 'family'};
    role = 'OWNER';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  @override
  Future<bool> reauthenticate() async {
    reauths++;
    return true;
  }
}

void main() {
  testWidgets(
      'a newly saved child remains selectable outside the first subject page',
      (tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final session = _Session(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      final body = r.method == 'POST' && r.url.path.endsWith('/subjects')
          ? {'id': 'new-child', 'nickname': '新孩子', 'ageBand': 'AGE_7_12'}
          : r.url.queryParameters['cursor'] == 'next-page'
              ? {
                  'items': [
                    {'id': 'new-child', 'nickname': '新孩子'}
                  ]
                }
              : {
                  'items': [
                    {'id': 'first-child', 'nickname': '第一页孩子'}
                  ],
                  'nextCursor': 'next-page'
                };
      return http.Response(jsonEncode(body), r.method == 'POST' ? 201 : 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    })));
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: EnrollmentFlow(session: session, storage: _Storage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加孩子'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '新孩子');
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('7–12 岁').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存儿童档案'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('新孩子'), findsOneWidget);
    await tester.tap(find.text('加载更多儿童'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('新孩子'), findsOneWidget);
  });
  testWidgets(
      'QR carries exactly the one-time ticket and confirmation uses the same authenticated session',
      (tester) async {
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    var claimed = false, confirmations = 0;
    String? enrollment;
    final storage = _Storage();
    final session = _Session(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      Json body;
      var status = 200;
      if (r.url.path.endsWith('/subjects')) {
        body = {
          'items': [
            {'id': 'child', 'nickname': '测试儿童'}
          ]
        };
      } else if (r.method == 'POST' && r.url.path.endsWith('/enrollments')) {
        enrollment = r.headers.entries
                .where((e) => e.key.toLowerCase() == 'client-request-id')
                .map((e) => e.value)
                .firstOrNull ??
            'enrollment';
        body = {
          'id': enrollment,
          'token': 'a' * 43,
          'expiresAt': DateTime.now()
              .add(const Duration(minutes: 15))
              .millisecondsSinceEpoch,
          'state': 'PENDING_CLAIM'
        };
        status = 201;
      } else if (r.url.path.endsWith('/confirm')) {
        expect(jsonDecode(r.body), {'pairingCode': 'A12B34C5'});
        confirmations++;
        body = {'id': 'device', 'state': 'ACTIVE'};
      } else {
        body = {
          'id': enrollment,
          'state': claimed ? 'AWAITING_CONFIRMATION' : 'PENDING_CLAIM',
          'deviceId': claimed ? 'device' : null
        };
      }
      return http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json; charset=utf-8'});
    })));
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => showDialog<bool>(
                        context: context,
                        builder: (_) => EnrollmentFlow(
                            session: session,
                            storage: storage,
                            confirmationScanner: (_) async => jsonEncode({
                                  'type': 'ai-manager-pairing-confirmation',
                                  'tenantId': 'family',
                                  'deviceId': 'device',
                                  'pairingCode': 'A12B34C5'
                                }))),
                    child: const Text('添加设备'))))));
    await tester.tap(find.text('添加设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成连接二维码'));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((w) => w.data)
            .join(' | '));
    final qr = tester.widget<PairingQr>(find.byType(PairingQr));
    final payload = jsonDecode(qr.data);
    expect(payload.keys.toSet(), {'tenantId', 'id', 'token', 'expiresAt'});
    expect(payload['tenantId'], 'family');
    expect(payload['id'], enrollment);
    expect(storage.values.values.any((v) => v.contains('a' * 43)), isFalse);
    claimed = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('扫描儿童端确认码'));
    await tester.tap(find.text('扫描儿童端确认码'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认连接'));
    await tester.pumpAndSettle();
    expect(confirmations, 1);
    expect(session.reauths, 0);
    expect(storage.values, isEmpty);
  });
}
