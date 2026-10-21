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
import 'package:parent/ui/family_device_access_page.dart';
import 'package:parent/ui/enrollment_flow.dart';
import 'package:parent/ui/family_workspace.dart';
import 'family_device_access_test.dart';
import 'family_workspace_test.dart' show FamilySession, familyDashboard;

class ValidatedFamilySession extends FamilySession {
  ValidatedFamilySession(super.fixture);
  @override
  Future<bool> reauthenticate() async {
    generation++;
    notifyListeners();
    return true;
  }
}

class DelayedSelectionStorage extends SelectionMemoryStorage {
  final barrier = Completer<void>();
  @override
  Future<void> write({required String key, required String value}) async {
    await super.write(key: key, value: value);
    await barrier.future;
  }
}

Future<void> openAccess(
    WidgetTester tester, FamilySession session, SelectionMemoryStorage storage,
    {double scale = 1}) async {
  await tester.pumpWidget(MaterialApp(
      theme: familyTheme(),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: FamilyDeviceAccessPage(session: session, storage: storage)));
  await tester.pumpAndSettle();
}

Future<void> chooseTablet(WidgetTester tester) async {
  await tester.ensureVisible(find.text('学习平板').last);
  await tester.tap(find.text('学习平板').last);
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('确认保留此设备'));
  await tester.tap(find.text('确认保留此设备'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('local expiry previews use explicitly fictional data',
      (tester) async {
    const capture = String.fromEnvironment('FAMILY_ACCESS_CAPTURE');
    if (capture.isEmpty) return;
    await tester.runAsync(() async {
      await (FontLoader('Roboto')
            ..addFont(Future.value(ByteData.sublistView(
                await File('C:/Windows/Fonts/msyh.ttc').readAsBytes()))))
          .load();
      await (FontLoader('MaterialIcons')
            ..addFont(Future.value(ByteData.sublistView(await File(
                    'D:/softwares/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
                .readAsBytes()))))
          .load();
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final status in ['GRACE', 'EXPIRED', 'PAID']) {
      final session = FamilySession(ParentApi(() async => 'fixture',
          baseUrl: 'https://fixture.invalid',
          client: MockClient(
              (r) async => jsonResponse(deviceAccessView(status: status)))));
      final boundary = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
          key: boundary,
          child: MaterialApp(
              theme: familyTheme(),
              debugShowCheckedModeBanner: false,
              builder: (context, child) => Column(children: [
                    const Material(
                        color: Color(0xFFFFF3D6),
                        child: SizedBox(
                            width: double.infinity,
                            child: Padding(
                                padding: EdgeInsets.all(6),
                                child: Text('布局预览 · 样例数据',
                                    textAlign: TextAlign.center)))),
                    Expanded(child: child!),
                  ]),
              home: FamilyDeviceAccessPage(
                  key: ValueKey(status),
                  session: session,
                  storage: SelectionMemoryStorage()))));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
        final frame = await render.toImage(pixelRatio: 1);
        final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
        await File('$capture/device-access-$status.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        frame.dispose();
      });
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    }
  });

  testWidgets('grace choice requires confirmation and submits exactly once',
      (tester) async {
    var state = deviceAccessView();
    final sent = <http.Request>[];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') {
        sent.add(r);
        state = deviceAccessView(
            status: 'EXPIRED',
            version: 5,
            selected: secondDevice,
            registration: secondRegistration);
      }
      return jsonResponse(state);
    })));
    addTearDown(session.dispose);
    await openAccess(tester, session, SelectionMemoryStorage());
    expect(find.text('请选择 1 台继续基础管理'), findsOneWidget);
    await chooseTablet(tester);
    expect(sent, isEmpty);
    expect(find.text('保留这台设备？'), findsOneWidget);
    await tester.tap(find.text('确认选择'));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    expect(jsonDecode(sent.single.body),
        {'deviceId': secondDevice, 'registrationId': secondRegistration});
    expect(find.textContaining('选择已保存'), findsOneWidget);
  });

  testWidgets('unknown choice survives reopening and query never resubmits',
      (tester) async {
    var state = deviceAccessView();
    final sent = <http.Request>[];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') {
        sent.add(r);
        if (sent.length == 1) {
          return jsonResponse({'errorCode': 'UNAVAILABLE'}, status: 503);
        }
        state = deviceAccessView(
            status: 'EXPIRED',
            version: 5,
            selected: secondDevice,
            registration: secondRegistration);
      }
      return jsonResponse(state);
    })));
    addTearDown(session.dispose);
    final storage = SelectionMemoryStorage();
    await openAccess(tester, session, storage);
    await chooseTablet(tester);
    await tester.tap(find.text('确认选择'));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await openAccess(tester, session, storage);
    expect(find.text('上次选择仍待核对'), findsOneWidget);
    expect(find.text('原选择：小雨 · 学习平板'), findsOneWidget);
    expect(find.text('确认保留此设备'), findsNothing);
    await tester.ensureVisible(find.text('查询当前选择'));
    await tester.tap(find.text('查询当前选择'));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    await tester.ensureVisible(find.text('继续核对原选择'));
    await tester.tap(find.text('继续核对原选择'));
    await tester.pumpAndSettle();
    expect(sent, hasLength(2));
    expect(sent.last.body, sent.first.body);
    expect(sent.last.headers['Idempotency-Key'],
        sent.first.headers['Idempotency-Key']);
    expect(sent.last.headers['If-Match'], sent.first.headers['If-Match']);
  });

  testWidgets(
      'background invalidates old confirmation and refreshes current state',
      (tester) async {
    var puts = 0, gets = 0;
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') {
        puts++;
      } else {
        gets++;
      }
      return jsonResponse(deviceAccessView());
    })));
    addTearDown(session.dispose);
    await openAccess(tester, session, SelectionMemoryStorage());
    await chooseTablet(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('确认选择'), findsNothing);
    expect(find.text('学习平板'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(puts, 0);
    expect(gets, greaterThan(1));
    expect(find.text('确认选择'), findsNothing);
  });

  testWidgets('leaving and returning permanently hides an old family page',
      (tester) async {
    var puts = 0;
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') puts++;
      return jsonResponse(deviceAccessView());
    })));
    addTearDown(session.dispose);
    await openAccess(tester, session, SelectionMemoryStorage());
    await chooseTablet(tester);
    session.leaveAndReturn();
    await tester.pumpAndSettle();
    expect(find.text('确认选择'), findsNothing);
    expect(find.text('小雨的手机'), findsNothing);
    expect(find.text('当前家庭或权限已变化，请返回重新打开。'), findsOneWidget);
    expect(puts, 0);
  });

  testWidgets('paid family displays seats without a retention choice',
      (tester) async {
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient(
            (r) async => jsonResponse(deviceAccessView(status: 'PAID')))));
    addTearDown(session.dispose);
    await openAccess(tester, session, SelectionMemoryStorage());
    expect(find.text('已连接 2 / 3 台设备'), findsOneWidget);
    expect(find.text('确认保留此设备'), findsNothing);
    expect(find.byType(RadioListTile<String>), findsNothing);
  });

  testWidgets(
      'large type on a narrow screen remains scrollable without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => jsonResponse(deviceAccessView()))));
    addTearDown(session.dispose);
    await openAccess(tester, session, SelectionMemoryStorage(), scale: 2);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('确认保留此设备'), 240);
    await tester.tap(find.text('确认保留此设备'));
    await tester.pumpAndSettle();
    expect(find.text('确认选择'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed read is visible and retry does not send a choice',
      (tester) async {
    var reads = 0;
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      expect(r.method, 'GET');
      if (++reads == 1) {
        return jsonResponse({'errorCode': 'UNAVAILABLE'}, status: 503);
      }
      return jsonResponse(deviceAccessView());
    })));
    addTearDown(session.dispose);
    await openAccess(tester, session, SelectionMemoryStorage());
    expect(find.text('重新读取设备名额'), findsOneWidget);
    await tester.tap(find.text('重新读取设备名额'));
    await tester.pumpAndSettle();
    expect(find.text('请选择 1 台继续基础管理'), findsOneWidget);
    expect(reads, 2);
  });

  testWidgets('today uses aggregated seats without a second device access read',
      (tester) async {
    final paths = <String>[];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      paths.add(r.url.path);
      return jsonResponse(
          {...familyDashboard(), 'deviceAccess': deviceAccessView()});
    })));
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: familyTheme(),
        home: FamilyWorkspace(
            session: session,
            account: const SizedBox(),
            firstUse: const SizedBox(),
            onApprovals: () {},
            onHelp: () {},
            onDevices: () {})));
    await tester.pumpAndSettle();
    expect(find.text('请选择 1 台继续基础管理'), findsOneWidget);
    expect(paths.where((p) => p.endsWith('/family-dashboard')), hasLength(1));
    expect(paths.where((p) => p.endsWith('/family-device-access')), isEmpty);
  });

  testWidgets('enrollment seat failure offers a family device access shortcut',
      (tester) async {
    final storage = SelectionMemoryStorage();
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'POST') {
        return jsonResponse({'errorCode': 'FAMILY_DEVICE_LIMIT_REACHED'},
            status: 402);
      }
      return jsonResponse({
        'items': [
          {'id': child, 'nickname': '小雨', 'state': 'ACTIVE'}
        ],
        'nextCursor': null
      });
    })));
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: familyTheme(),
        home: Scaffold(
            body: EnrollmentFlow(session: session, storage: storage))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('生成连接二维码'));
    await tester.pumpAndSettle();
    expect(find.textContaining('设备名额已用完'), findsOneWidget);
    expect(find.text('查看设备名额'), findsOneWidget);
  });

  testWidgets(
      'recent phone validation closes the old route and preserves the original choice',
      (tester) async {
    final sent = <http.Request>[];
    final storage = SelectionMemoryStorage();
    final session = ValidatedFamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') {
        sent.add(r);
        return jsonResponse({'errorCode': 'REAUTH_REQUIRED'}, status: 401);
      }
      return jsonResponse(deviceAccessView());
    })));
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: familyTheme(),
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => FamilyDeviceAccessPage(
                                session: session, storage: storage))),
                    child: const Text('打开设备名额'))))));
    await tester.tap(find.text('打开设备名额'));
    await tester.pumpAndSettle();
    await chooseTablet(tester);
    await tester.tap(find.text('确认选择'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('完成安全验证'), -180);
    await tester.tap(find.text('完成安全验证'));
    await tester.pumpAndSettle();
    expect(find.text('打开设备名额'), findsOneWidget);
    expect(sent, hasLength(1));
    expect(storage.values, isNotEmpty);
    await tester.tap(find.text('打开设备名额'));
    await tester.pumpAndSettle();
    expect(find.text('上次选择仍待核对'), findsOneWidget);
    expect(sent, hasLength(1));
  });

  testWidgets(
      'resume waits for the old durability boundary before reading pending choice',
      (tester) async {
    var puts = 0;
    final storage = DelayedSelectionStorage();
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid', client: MockClient((r) async {
      if (r.method == 'PUT') puts++;
      return jsonResponse(deviceAccessView());
    })));
    addTearDown(session.dispose);
    await openAccess(tester, session, storage);
    await chooseTablet(tester);
    await tester.tap(find.text('确认选择'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    storage.barrier.complete();
    await tester.pumpAndSettle();
    expect(puts, 0);
    expect(find.text('上次选择仍待核对'), findsOneWidget);
    expect(storage.values, isNotEmpty);
  });

  testWidgets('free family without a connected device gives a clear next step',
      (tester) async {
    final state =
        deviceAccessView(status: 'FREE', selected: null, registration: null)
          ..['activeCount'] = 0
          ..['devices'] = [];
    final session = FamilySession(ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid',
        client: MockClient((r) async => jsonResponse(state))));
    addTearDown(session.dispose);
    await openAccess(tester, session, SelectionMemoryStorage());
    expect(find.text('还没有已连接的儿童设备。返回今日页即可扫码连接。'), findsOneWidget);
    expect(find.text('确认保留此设备'), findsNothing);
  });
}
