import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/main.dart';
import 'package:parent/core/family.dart';
import 'package:parent/ui/family_rules_page.dart';

class FamilySession extends ParentSession {
  final ParentApi fixture;
  FamilySession(this.fixture, {String kind = 'FAMILY'}) {
    ready = true;
    profile = {'subject': 'adult', 'name': '家长'};
    tenant = {'id': 'family', 'kind': kind, 'name': '我的家庭'};
    tenants = [tenant!];
    role = 'OWNER';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  void revoke() {
    role = 'AUDITOR';
    notifyListeners();
  }

  void leaveAndReturn() {
    role = 'AUDITOR';
    notifyListeners();
    role = 'OWNER';
    notifyListeners();
  }
}

Map<String, dynamic> familyDashboard({bool child = true}) => {
      'tenantId': 'family',
      'generatedAt': '2026-10-15T08:00:00Z',
      'systemEnforced': false,
      'pendingRequestCount': 2,
      'openHelpRequestCount': 1,
      'children': child
          ? [
              {
                'id': 'child',
                'nickname': '小明',
                'ageBand': 'AGE_7_12',
                'rules': null,
                'devices': [
                  {
                    'id': 'device',
                    'displayName': '学习手机',
                    'registrationId': 'registration',
                    'lastHeartbeatAt': null,
                    'runtime': null,
                    'ruleState': 'NOT_CONFIGURED'
                  }
                ]
              }
            ]
          : [],
    };

void main() {
  testWidgets('leaving and returning cannot revive an old family rules read',
      (tester) async {
    final reply = Completer<http.Response>();
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.url.path.endsWith('/family-rules')) return reply.future;
      return http.Response('{"items":[],"nextCursor":null}', 200);
    })));
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        home: FamilyRulesPage(
            session: session,
            child:
                FamilyDashboard.fromJson(familyDashboard()).children.single)));
    await tester.pump();
    session.leaveAndReturn();
    reply.complete(http.Response(
        jsonEncode({
          'subjectId': 'child',
          'version': 1,
          'enabled': false,
          'dailyAllowanceSeconds': 86400,
          'timeZoneId': 'Asia/Shanghai',
          'meteredPackages': [],
          'allowedWindows': [],
          'deliveryState': 'NOT_CONFIGURED'
        }),
        200));
    await tester.pumpAndSettle();
    expect(find.text('当前家庭或权限已变化，请返回重新打开。'), findsOneWidget);
    expect(find.text('选择应用'), findsNothing);
  });
  testWidgets('family reference captures use the working three primary pages',
      (tester) async {
    const capture = String.fromEnvironment('FAMILY_UI_CAPTURE');
    if (capture.isEmpty) return;
    await tester.runAsync(() async {
      final font = File('C:/Windows/Fonts/msyh.ttc');
      final bytes = await font.readAsBytes();
      await (FontLoader('Roboto')
            ..addFont(Future.value(ByteData.sublistView(bytes))))
          .load();
      final icon = File(
          'D:/softwares/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
      if (await icon.exists()) {
        await (FontLoader('MaterialIcons')
              ..addFont(
                  Future.value(ByteData.sublistView(await icon.readAsBytes()))))
            .load();
      }
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => http.Response(
            jsonEncode(r.url.path.endsWith('/family-dashboard')
                ? familyDashboard()
                : {'items': [], 'nextCursor': null}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'}))));
    addTearDown(session.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: boundary, child: Column(children: [
      const Directionality(textDirection: TextDirection.ltr, child: ColoredBox(color: Color(0xFFFFF3D6), child: SizedBox(width: double.infinity, child: Padding(padding: EdgeInsets.symmetric(vertical:4), child: Text('布局预览 · 样例数据', textAlign: TextAlign.center, style: TextStyle(fontFamily:'Roboto',fontSize:12,color:Color(0xFF6C4C14))))))),
      Expanded(child: ParentApp(session: session)),
    ])));
    await tester.pumpAndSettle();
    for (final tab in ['今日', '规则', '成长']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await precacheImage(const AssetImage('assets/family/horizon.png'),
            boundary.currentContext!);
        await precacheImage(const AssetImage('assets/family/usage-empty.png'),
            boundary.currentContext!);
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final frame = await render.toImage(pixelRatio: 1);
        final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
        await File('$capture/parent-$tab.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        frame.dispose();
      });
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('family routes show four entries and unknown use stays unknown',
      (tester) async {
    final requests = <String>[];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      requests.add(r.url.path);
      return http.Response(
          jsonEncode(r.url.path.endsWith('/family-dashboard')
              ? familyDashboard()
              : {'items': [], 'nextCursor': null}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    })));
    addTearDown(session.dispose);
    await tester.pumpWidget(ParentApp(session: session));
    await tester.pumpAndSettle();
    final navigation = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(navigation.destinations.length, 4);
    expect(find.text('规则'), findsOneWidget);
    expect(find.text('成长'), findsOneWidget);
    expect(requests, contains('/tenants/family/family-dashboard'));
    expect(find.text('尚无使用数据'), findsOneWidget);
    expect(find.text('0 分钟'), findsNothing);
    expect(find.textContaining('辅助限制'), findsWidgets);
  });

  testWidgets(
      'family onboarding offers a real device connection from empty dashboard',
      (tester) async {
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => http.Response(
            jsonEncode(familyDashboard(child: false)), 200,
            headers: {'content-type': 'application/json; charset=utf-8'}))));
    addTearDown(session.dispose);
    await tester.pumpWidget(ParentApp(session: session));
    await tester.pumpAndSettle();
    expect(find.text('连接孩子的第一台设备'), findsOneWidget);
    expect(find.text('扫码连接设备'), findsOneWidget);
    expect(find.textContaining('7 天'), findsWidgets);
  });

  testWidgets(
      'family today remains readable at double font size on narrow phone',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => http.Response(
            jsonEncode(familyDashboard()), 200,
            headers: {'content-type': 'application/json; charset=utf-8'}))));
    addTearDown(session.dispose);
    await tester.pumpWidget(ParentApp(session: session));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('小明'), findsWidgets);
    await tester.tap(find.text('规则').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('organization retains the existing five entry navigation',
      (tester) async {
    final session = FamilySession(
        ParentApi(() async => 'fixture',
            baseUrl: 'https://fixture.invalid',
            client: MockClient((r) async => http.Response(
                jsonEncode({'items': [], 'nextCursor': null}), 200))),
        kind: 'ORGANIZATION');
    addTearDown(session.dispose);
    await tester.pumpWidget(ParentApp(session: session));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<NavigationBar>(find.byType(NavigationBar))
            .destinations
            .length,
        5);
    expect(find.text('申请'), findsOneWidget);
    expect(find.text('求助'), findsOneWidget);
  });
}
