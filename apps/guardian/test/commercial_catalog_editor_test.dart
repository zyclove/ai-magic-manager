import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/commercial_catalog_repository.dart';
import 'package:guardian/pages/commercial_catalog_editor.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
      'new draft defaults to mainland institution contract and previews',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
          jsonEncode({
            'id': body['id'],
            'revision': 1,
            'state': 'DRAFT',
            'offer': body['offer'],
            'createdBy': 'operator',
            'lastEditor': 'operator',
            'approvedBy': null,
            'createdAt': 100,
            'updatedAt': 100,
            'purchaseAvailable': false
          }),
          201,
          headers: {'content-type': 'application/json'});
    });
    final repository = CommercialCatalogRepository(
        api: Api(() async => client, baseUrl: 'https://example.test/api/v1'),
        current: () => true);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showDialog(
                        context: context,
                        builder: (_) =>
                            CommercialCatalogEditor(repository: repository)),
                    child: const Text('打开目录编辑器'))))));
    await tester.tap(find.text('打开目录编辑器'));
    await tester.pumpAndSettle();
    expect(find.text('机构'), findsOneWidget);
    expect(find.text('合同'), findsOneWidget);
    expect(find.text('人工报价'), findsOneWidget);
    expect(find.text('CNY'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, 'ORG_PILOT');
    await tester.tap(find.text('创建草稿'));
    await tester.pumpAndSettle();
    expect(find.text('核对新草稿'), findsOneWidget);
    expect(find.text('新值：ORG_PILOT'), findsOneWidget);
    expect(requests, 0);
    await tester.tap(find.text('返回修改'));
    await tester.pumpAndSettle();
    expect(requests, 0);
    await tester.tap(find.text('创建草稿'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.text('创建报价草稿'), findsNothing);
  });
}
