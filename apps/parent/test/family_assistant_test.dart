import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/family.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_durable_storage.dart';
import 'package:parent/ui/family_assistant.dart';
import 'family_workspace_test.dart' show FamilySession, familyDashboard;

class _Store extends ParentDurableStorage {
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

void main() {
  testWidgets('assistant requires consent and fallback cannot apply a rule',
      (tester) async {
    var writes = 0;
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      writes++;
      return http.Response(
          jsonEncode({
            'id': 'suggestion',
            'task': 'RULE_DRAFT',
            'status': 'FALLBACK',
            'summary': '请先手动核对设备与规则。',
            'evidence': [],
            'limitations': ['云模型尚未配置，本次未调用云端服务。'],
            'ruleDraft': null,
            'expiresAt': 1792051200000,
            'model': null,
            'remainingRequests': null
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    })));
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        home: FamilyAssistantPage(
            session: session,
            child: FamilyDashboard.fromJson(familyDashboard()).children.single,
            task: 'RULE_DRAFT',
            pendingStorage: _Store())));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '放学后安排三十分钟娱乐');
    await tester.tap(find.text('生成建议'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(find.text('生成建议'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.textContaining('本次未调用云端服务'), findsOneWidget);
    expect(find.text('核对规则草稿'), findsNothing);
  });
}
