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
import 'package:parent/core/permission_consent.dart';
import 'package:parent/core/permission_observation.dart';
import 'package:parent/ui/permission_consent_page.dart';
import 'package:parent/ui/permission_observation_page.dart';
import 'permission_consent_test.dart' as f;

Json inventory() => {
      'deviceId': f.device,
      'registrationId': f.registration,
      'observationStatus': 'RECENT',
      'evidenceStatus': 'AGENT_REPORTED_UNVERIFIED',
      'receivedAt': 1791950400000,
      'applications': [
        {
          'packageName': 'org.example.study',
          'displayName': '学习课堂',
          'profile': 'PRIMARY'
        }
      ]
    };
Json snapshot() => {
      'deviceId': f.device,
      'registrationId': f.registration,
      'packageName': 'org.example.study',
      'observationStatus': 'RECENT',
      'evidenceStatus': 'AGENT_REPORTED_UNVERIFIED',
      'profile': 'PRIMARY',
      'versionCode': 5,
      'observedAt': 1791950400000,
      'receivedAt': 1791950400000,
      'permissions': [
        {
          'permissionName': 'android.permission.RECORD_AUDIO',
          'classification': 'DANGEROUS',
          'observedGrant': 'GRANTED'
        }
      ]
    };
Json common([bool enabled = true, int version = 1]) => {
      'deviceId': f.device,
      'registrationId': f.registration,
      'version': version,
      'inventoryEnabled': enabled,
      'usageEnabled': false,
      'updatedAt': 1791950400000
    };
Future<http.Response> normal(http.Request r) async {
  if (r.url.path.endsWith('/devices/${f.device}')) {
    return f.response(f.deviceJson());
  }
  if (r.url.path.endsWith('/permission-observation-settings')) {
    return f.response(f.settings(1, true));
  }
  if (r.url.path.endsWith('/observation-settings')) return f.response(common());
  if (r.url.path.endsWith('/application-inventory')) {
    return f.response(inventory());
  }
  if (r.url.path.endsWith('/permission-observations')) {
    return f.response(snapshot());
  }
  throw StateError('Unexpected fixture route');
}

ParentPermissionView viewer(ParentApi api,
        {bool Function()? current, bool Function()? foreground}) =>
    ParentPermissionView(
        api: api,
        tenant: 'tenant',
        target: f.target,
        isCurrent: current ?? () => true,
        foreground: foreground ?? () => true);

class Session extends ParentSession {
  final ParentApi fixture;
  int checks = 0;
  Session(this.fixture) {
    tenant = {'id': 'tenant'};
    profile = {'subject': 'adult'};
    role = 'GUARDIAN';
  }
  @override
  ParentApi get api => fixture;
  @override
  bool get authenticated => true;
  @override
  Future<bool> reauthenticate() async {
    checks++;
    return true;
  }

  void revoke() {
    role = 'AUDITOR';
    notifyListeners();
  }
}

void main() {
  testWidgets(
      'expired consent authentication renews read access without writing',
      (tester) async {
    var writes = 0;
    late Session session;
    session = Session(f.api((r) async {
      if (r.method != 'GET') writes++;
      if (session.checks == 0) {
        return f.response({'errorCode': 'UNAUTHENTICATED'}, 401);
      }
      return normal(r);
    }));
    await tester.pumpWidget(MaterialApp(
        home: PermissionConsentPage(
            session: session,
            target: f.target,
            store: PermissionChangeStore(storage: f.Storage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新安全验证并核对'));
    await tester.pumpAndSettle();
    expect(session.checks, 1);
    expect(writes, 0);
    expect(find.text('当前授权'), findsOneWidget);
  });
  test(
      'selected application is checked against refreshed inventory and both consents',
      () async {
    final calls = <String>[];
    final v = viewer(f.api((r) async {
      calls.add(r.url.path);
      return normal(r);
    }));
    await v.load();
    expect(v.error, isNull);
    final app = v.inventory!.applications.single;
    await v.load(app: app);
    expect(v.error, isNull);
    expect(v.result!.permissions.single.observedGrant, 'GRANTED');
    expect(
        calls.where((p) => p.endsWith('/observation-settings')), hasLength(4));
    v.dispose();
  });
  for (final which in ['inventory', 'permission']) {
    test('$which disabled never fetches application facts', () async {
      final v = viewer(f.api((r) async {
        expect(r.url.path.endsWith('/application-inventory'), isFalse);
        expect(r.url.path.endsWith('/permission-observations'), isFalse);
        if (which == 'inventory' &&
            r.url.path.endsWith('/observation-settings')) {
          return f.response(common(false));
        }
        if (which == 'permission' &&
            r.url.path.endsWith('/permission-observation-settings')) {
          return f.response(f.settings());
        }
        return normal(r);
      }));
      await v.load();
      expect(v.error, isNull);
      expect(v.inventory, isNull);
      v.dispose();
    });
  }
  for (final failure in ['profile', 'registration', 'consent', 'malformed']) {
    test('$failure cannot be presented as a permission state', () async {
      var selected = false, reads = 0;
      final v = viewer(f.api((r) async {
        if (selected &&
            r.url.path.endsWith('/permission-observation-settings') &&
            failure == 'consent') {
          reads++;
          return f.response(f.settings(reads == 1 ? 1 : 2, reads == 1));
        }
        if (selected && r.url.path.endsWith('/permission-observations')) {
          return f.response({
            ...snapshot(),
            if (failure == 'profile') 'profile': 'WORK',
            if (failure == 'registration') 'registrationId': f.subject,
            if (failure == 'malformed')
              'permissions': [
                {
                  'permissionName': 'android.permission.CAMERA',
                  'classification': 'OTHER',
                  'observedGrant': 'GRANTED'
                }
              ]
          });
        }
        return normal(r);
      }));
      await v.load();
      final app = v.inventory!.applications.single;
      selected = true;
      await v.load(app: app);
      expect(v.error, isA<ParentApiException>());
      expect(v.result, isNull);
      expect(v.inventory, isNull);
      v.dispose();
    });
  }
  test('late response after background hides data and cannot refill it',
      () async {
    final started = Completer<void>(), reply = Completer<http.Response>();
    var active = true;
    final v = viewer(f.api((r) async {
      if (r.url.path.endsWith('/application-inventory')) {
        started.complete();
        return reply.future;
      }
      return normal(r);
    }), foreground: () => active);
    final read = v.load();
    await started.future;
    active = false;
    v.hide();
    reply.complete(f.response(inventory()));
    await read;
    active = true;
    expect(v.inventory, isNull);
    expect(v.settings, isNull);
    expect(v.error, isNull);
    v.dispose();
  });
  test('token refresh cannot dispatch after scope loss', () async {
    final token = Completer<String>();
    var current = true, sends = 0;
    final api =
        ParentApi(() => token.future, baseUrl: 'https://fixture.invalid/api/v1',
            client: MockClient((r) async {
      sends++;
      return normal(r);
    }));
    final v = viewer(api, current: () => current);
    final read = v.load();
    current = false;
    token.complete('fixture');
    await read;
    expect(sends, 0);
    expect(v.settings, isNull);
    v.dispose();
    api.close();
  });
  test('unavailable backend gives an actionable state', () async {
    final v = viewer(f.api((r) async =>
        r.url.path.endsWith('/permission-observation-settings')
            ? f.response({'errorCode': 'NOT_FOUND'}, 404)
            : await normal(r)));
    await v.load();
    expect(
        (v.error as ParentApiException).code, 'PERMISSION_BACKEND_UNAVAILABLE');
    v.dispose();
  });
  testWidgets('unknown permission snapshot explains the child-side action',
      (tester) async {
    final session = Session(f.api((r) async {
      if (r.url.path.endsWith('/permission-observations')) {
        return f.response({
          ...snapshot(),
          'observationStatus': 'UNKNOWN',
          'profile': null,
          'versionCode': null,
          'observedAt': null,
          'receivedAt': null,
          'permissions': <Json>[],
        });
      }
      return normal(r);
    }));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => ParentPermissionsPage(
                                session: session, target: f.target))),
                    child: const Text('打开应用权限'))))));
    await tester.tap(find.text('打开应用权限'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习课堂'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请在儿童设备“使用情况与隐私”中加载应用'), findsOneWidget);
    expect(find.textContaining('空记录不代表没有权限'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'search, select, large text, background hiding and nested revocation',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.aimanager.parent/storage'),
            (_) async => true);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const font = String.fromEnvironment('UI_CAPTURE_FONT'),
        icons = String.fromEnvironment('UI_CAPTURE_ICONS');
    for (final e in {'CaptureFont': font, 'MaterialIcons': icons}.entries) {
      if (e.value.isNotEmpty) {
        await tester.runAsync(() async {
          await (FontLoader(e.key)
                ..addFont(Future.value(
                    ByteData.sublistView(await File(e.value).readAsBytes()))))
              .load();
        });
      }
    }
    final session = Session(f.api(normal)), boundary = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: boundary,
        child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
                useMaterial3: true,
                colorSchemeSeed: const Color(0xFF315E86),
                fontFamily: font.isEmpty ? null : 'CaptureFont'),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!),
            home: Builder(
                builder: (context) => Scaffold(
                    body: TextButton(
                        child: const Text('打开设备'),
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => ParentPermissionsPage(
                                    session: session, target: f.target)))))))));
    await tester.tap(find.text('打开设备'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的应用。可以清除搜索或稍后刷新。'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '学习');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('学习课堂'));
    await tester.tap(find.text('学习课堂'));
    await tester.pumpAndSettle();
    expect(find.text('近期上报 · 设备自报，未经核实'), findsOneWidget);
    if (const bool.fromEnvironment('CAPTURE_PERMISSION_UI')) {
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('permission-observation.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    expect(tester.takeException(), isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('学习课堂'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('刷新权限状态'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('权限观察已允许'));
    await tester.pumpAndSettle();
    expect(find.text('权限观察授权'), findsOneWidget);
    session.revoke();
    await tester.pumpAndSettle();
    expect(find.text('打开设备'), findsOneWidget);
    expect(find.text('权限观察授权'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'independent consent requires explicit confirmation and supports receipt acknowledgement',
      (tester) async {
    var writes = 0, version = 0;
    final session = Session(f.api((r) async {
      if (r.url.path.endsWith('/devices/${f.device}')) {
        return f.response(f.deviceJson());
      }
      if (r.url.path.endsWith('/changes')) {
        expect(jsonDecode(r.body)['enabled'], true);
        writes++;
        version = 1;
        return f.response(f.settings(1, true));
      }
      if (r.url.path.endsWith('/query')) {
        return f.response(
            {'committed': f.settings(1, true), 'current': f.settings(1, true)});
      }
      return f.response(f.settings(version, version > 0));
    }));
    await tester.pumpWidget(MaterialApp(
        home: PermissionConsentPage(
            session: session,
            target: f.target,
            store: PermissionChangeStore(storage: f.Storage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '核对学习应用权限');
    await tester.ensureVisible(find.text('确认并进行安全验证'));
    await tester.tap(find.text('确认并进行安全验证'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(session.checks, 0);
    await tester.ensureVisible(find.text('我已确认采集范围和变更影响'));
    await tester.tap(find.text('我已确认采集范围和变更影响'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('确认并进行安全验证'));
    await tester.tap(find.text('确认并进行安全验证'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(session.checks, 1);
    await tester.ensureVisible(find.text('我已核对当前授权与原结果'));
    await tester.tap(find.text('我已核对当前授权与原结果'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('完成核对'));
    await tester.tap(find.text('完成核对'));
    await tester.pumpAndSettle();
    expect(find.text('原提交 · 待核对'), findsNothing);
    expect(writes, 1);
    expect(tester.takeException(), isNull);
  });
}
