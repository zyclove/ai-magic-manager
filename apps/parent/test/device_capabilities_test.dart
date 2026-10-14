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
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';
import 'package:parent/ui/device_capabilities.dart';

Json capability(String key, {bool available = false, String? status}) => {
      'key': key,
      'status': status ?? (available ? 'SUPPORTED' : 'UNSUPPORTED'),
      'effectiveSupported': available,
      'reportedSupported': true,
      'grantStatus': 'GRANTED',
      'evidenceSource': 'AGENT_REPORT',
      'limitationCode': available ? '' : 'MANAGED_REGISTRATION_REQUIRED',
      'checkedAt': 1791950400000,
    };
Json device({String observation = 'RECENT', String state = 'ACTIVE'}) => {
      'id': 'device',
      'displayName': '小安的学习平板',
      'managementMode': 'BYOD',
      'observationStatus': observation,
      'state': state,
      'platform': 'ANDROID',
      'lastHeartbeatAt': 1791950400000,
    };
http.Response response(Object data, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(data)), status);

class Session extends ParentSession {
  final ParentApi fixture;
  Session(Future<http.Response> Function(http.Request) handler)
      : fixture = ParentApi(() async => 'fixture',
            baseUrl: 'https://fixture.invalid/api/v1',
            client: MockClient(handler)) {
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

final capture = GlobalKey();
Future<void> open(WidgetTester tester, Session session,
    {double scale = 1}) async {
  await tester.pumpWidget(RepaintBoundary(
      key: capture,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF315E86),
            fontFamily: const String.fromEnvironment('UI_CAPTURE_FONT').isEmpty
                ? null
                : 'CaptureFont'),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () =>
                        showDeviceCapabilities(context, session, 'device'),
                    child: const Text('打开设备')))),
      )));
  await tester.tap(find.text('打开设备'));
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(target, 160,
        scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('late response after account change cannot reopen sensitive data',
      (tester) async {
    final pending = Completer<http.Response>();
    final session = Session((r) async => r.url.path.endsWith('/capabilities')
        ? pending.future
        : response(device()));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () =>
                        showDeviceCapabilities(context, session, 'device'),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    session.changeScope();
    await tester.pump();
    pending.complete(response({
      'items': [capability('usage.report')]
    }));
    await tester.pumpAndSettle();
    expect(find.text('小安的学习平板'), findsNothing);
    expect(find.text('设备能力'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'summary filters locally and evidence stays folded until requested',
      (tester) async {
    final requests = <http.Request>[];
    final session = Session((r) async {
      requests.add(r);
      return response(r.url.path.endsWith('/capabilities')
          ? {
              'items': [
                capability('usage.report', available: true),
                capability('app.launch_block'),
              ]
            }
          : device());
    });
    await open(tester, session);
    expect(find.text('当前可确认 1 项能力'), findsOneWidget);
    expect(find.text('能力标识：app.launch_block'), findsNothing);
    await tapVisible(tester, find.text('可用 1'));
    expect(find.text('阻止应用启动'), findsNothing);
    expect(find.text('使用情况报告'), findsOneWidget);
    await tapVisible(tester, find.text('待确认 1'));
    expect(find.text('使用情况报告'), findsNothing);
    await tapVisible(tester, find.text('查看依据'));
    expect(find.text('能力标识：app.launch_block'), findsOneWidget);
    expect(requests, hasLength(2));
    expect(requests.every((r) => r.method == 'GET'), isTrue);
    await tester.tap(find.text('刷新状态'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(4));
    expect(find.text('待确认 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('device claim and status alone never become available',
      (tester) async {
    await open(
        tester,
        Session((r) async => response(r.url.path.endsWith('/capabilities')
            ? {
                'items': [capability('usage.report', status: 'SUPPORTED')]
              }
            : device())));
    expect(find.text('当前可确认 0 项能力'), findsOneWidget);
    await tapVisible(tester, find.text('可用 0'));
    expect(find.text('暂无可用能力。切换“待确认”查看原因。'), findsOneWidget);
    await tapVisible(tester, find.text('待确认 1'));
    expect(find.text('尚未确认可用'), findsOneWidget);
    expect(find.text('服务端确认可用'), findsNothing);
  });

  for (final malformed in [
    'duplicate',
    'contradiction',
    'timestamp',
    'tooMany'
  ]) {
    testWidgets('rejects malformed $malformed evidence without partial display',
        (tester) async {
      final item = capability('usage.report');
      final rows = switch (malformed) {
        'duplicate' => [item, item],
        'contradiction' => [
            {...item, 'effectiveSupported': true}
          ],
        'timestamp' => [
            {...item, 'checkedAt': 'yesterday'}
          ],
        _ => List.generate(129, (i) => capability('custom.capability_$i')),
      };
      await open(
          tester,
          Session((r) async => response(r.url.path.endsWith('/capabilities')
              ? {'items': rows}
              : device())));
      expect(find.text('暂时无法读取设备能力'), findsOneWidget);
      expect(find.text('当前可确认 0 项能力'), findsNothing);
      expect(find.text('重新加载'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('network failure is understandable and recovery does not write',
      (tester) async {
    var fail = true;
    final session = Session((r) async {
      expect(r.method, 'GET');
      if (fail) throw http.ClientException('private transport detail');
      return response(
          r.url.path.endsWith('/capabilities') ? {'items': []} : device());
    });
    await open(tester, session);
    expect(find.textContaining('请检查网络'), findsOneWidget);
    expect(find.textContaining('private transport'), findsNothing);
    fail = false;
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(find.text('尚无能力记录。请检查设备注册和最近连接。'), findsOneWidget);
  });

  testWidgets('revoked and stale devices get different next steps',
      (tester) async {
    var current = device(observation: 'STALE');
    await open(
        tester,
        Session((r) async => response(
            r.url.path.endsWith('/capabilities') ? {'items': []} : current)));
    expect(find.text('请先让儿童设备联网并打开智能管家，再刷新状态。'), findsOneWidget);
    current = device(state: 'REVOKED');
    await tester.tap(find.text('刷新状态'));
    await tester.pumpAndSettle();
    expect(find.text('设备已停用或撤销，请返回设备列表核对注册状态。'), findsOneWidget);
  });

  testWidgets('background hides records and changing account removes own route',
      (tester) async {
    var reads = 0;
    final session = Session((r) async {
      reads++;
      return response(
          r.url.path.endsWith('/capabilities') ? {'items': []} : device());
    });
    await open(tester, session);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('小安的学习平板'), findsNothing);
    expect(find.text('设备信息已隐藏。'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(reads, 4);
    session.changeScope();
    await tester.pumpAndSettle();
    expect(find.text('设备能力'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow screen with large text keeps close and refresh reachable',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(
        tester,
        Session((r) async => response(r.url.path.endsWith('/capabilities')
            ? {
                'items': [
                  capability('app.launch_block'),
                  capability('permission.runtime'),
                  capability('usage.report'),
                ]
              }
            : device())),
        scale: 2);
    expect(find.byTooltip('关闭').hitTestable(), findsOneWidget);
    expect(find.text('刷新状态').hitTestable(), findsOneWidget);
    await tapVisible(tester, find.text('可用 0'));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('设备能力'), findsNothing);
  });

  testWidgets('phone summary render uses real widgets', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final entry in {
      'CaptureFont': const String.fromEnvironment('UI_CAPTURE_FONT'),
      'MaterialIcons': const String.fromEnvironment('UI_CAPTURE_ICONS')
    }.entries) {
      if (entry.value.isNotEmpty) {
        await tester.runAsync(() async {
          await (FontLoader(entry.key)
                ..addFont(Future.value(ByteData.sublistView(
                    await File(entry.value).readAsBytes()))))
              .load();
        });
      }
    }
    await open(
        tester,
        Session((r) async => response(r.url.path.endsWith('/capabilities')
            ? {
                'items': [
                  capability('app.launch_block'),
                  capability('usage.report', status: 'UNVERIFIED'),
                ]
              }
            : device())),
        scale: 1.2);
    if (const bool.fromEnvironment('CAPTURE_CAPABILITY_UI')) {
      await tester.runAsync(() async {
        final image = await (capture.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('device-capabilities.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    expect(tester.takeException(), isNull);
  });
}
