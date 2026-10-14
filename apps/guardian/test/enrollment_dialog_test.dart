import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/enrollment_recovery.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/enrollment_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qr_flutter/qr_flutter.dart';

const tenant = '11111111-1111-4111-8111-111111111111';
const child = '22222222-2222-4222-8222-222222222222';
const request = '33333333-3333-4333-8333-333333333333';
const device = '44444444-4444-4444-8444-444444444444';
const scope =
    EnrollmentScope(actorId: 'adult', tenantId: tenant, role: 'OWNER');
const moment = 1800000000000;
EnrollmentIntent intent() => const EnrollmentIntent(
    scope: scope,
    requestId: request,
    subjectId: child,
    platform: 'ANDROID',
    createdAt: moment);
Json issued() => {
      'id': request,
      'token': 'a' * 43,
      'expiresAt': moment + 900000,
      'state': 'PENDING_CLAIM'
    };
Json status(String state) => {
      'id': request,
      'subjectId': child,
      'platform': 'ANDROID',
      'requestedMode': 'BYOD',
      'state': state,
      'expiresAt': moment + 900000,
      'deviceId':
          ['AWAITING_CONFIRMATION', 'CONFIRMED', 'LOCKED'].contains(state)
              ? device
              : null,
      'pairingFailures': 0
    };
Json confirmedDevice() => {
      'id': device,
      'subjectId': child,
      'registrationId': '55555555-5555-4555-8555-555555555555',
      'displayName': '孩子的手机',
      'platform': 'ANDROID',
      'osVersion': '15',
      'state': 'ACTIVE',
      'managementMode': 'BYOD',
      'controlLevel': 'LIMITED',
      'lastHeartbeatAt': null,
      'observationStatus': 'UNKNOWN',
      'keyThumbprint': 'b' * 43,
      'version': 1
    };
http.Response response(Object? data, [int code = 200]) =>
    http.Response(data == null ? '' : jsonEncode(data), code,
        headers: {'content-type': 'application/json; charset=utf-8'});

class Journal implements EnrollmentJournal {
  EnrollmentIntent? value;
  Object? failure;
  @override
  Future<EnrollmentIntent?> read(EnrollmentScope scope) async {
    if (failure != null) throw failure!;
    return value;
  }

  @override
  Future<void> write(EnrollmentIntent intent) async {
    value = intent;
  }

  @override
  Future<void> remove(EnrollmentIntent intent) async {
    value = null;
  }
}

class Fixture {
  final Journal journal = Journal();
  final requests = <http.Request>[];
  late final EnrollmentController controller;
  int clock = moment;
  Fixture(
      {EnrollmentIntent? saved,
      bool lookup = false,
      Future<http.Response> Function(http.Request)? handler}) {
    journal.value = saved;
    final api = Api(() async => MockClient((req) async {
          requests.add(req);
          return handler == null
              ? response(
                  req.method == 'POST' ? issued() : status('PENDING_CLAIM'),
                  req.method == 'POST' ? 201 : 200)
              : handler(req);
        }));
    controller = EnrollmentController(
        scope: scope,
        journal: journal,
        gateway:
            lookup ? EnrollmentGateway.lookup(api) : EnrollmentGateway(api),
        isCurrent: () => true,
        newId: () => request,
        now: () => clock);
  }
}

Widget host(Fixture f,
        {Future<void> Function(String)? copy,
        VoidCallback? reauth,
        ValueChanged<String>? open,
        double scale = 1}) =>
    MaterialApp(
        theme: consoleTheme(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: Scaffold(
            body: EnrollmentDialog(
                controller: f.controller,
                subjects: const [
                  {'id': child, 'nickname': '小明'}
                ],
                copy: copy,
                onReauthenticate: reauth ?? () {},
                onViewDevice: open)));
Future<void> mount(WidgetTester tester, Fixture f,
    {Future<void> Function(String)? copy,
    VoidCallback? reauth,
    ValueChanged<String>? open,
    double scale = 1}) async {
  await f.controller.initialize();
  await tester.pumpWidget(
      host(f, copy: copy, reauth: reauth, open: open, scale: scale));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    f.controller.dispose();
  });
}

Future<void> press(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'manual lookup shows progress without issuing or resetting tickets',
      (tester) async {
    final f = Fixture(saved: intent(), lookup: true);
    await mount(tester, f);
    expect(find.text('注册进度'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('生成配对凭证'), findsNothing);
    expect(find.text('继续原操作'), findsNothing);
    await press(tester, '刷新进度');
    expect(f.requests.every((request) => request.method == 'GET'), isTrue);
    expect(
        f.requests.every((r) => r.url.path.endsWith('/enrollments/$request')),
        isTrue);
  });

  testWidgets('manual lookup terminal state never resets the creation journal',
      (tester) async {
    final f = Fixture(
        saved: intent(),
        lookup: true,
        handler: (_) async => response(status('CANCELLED')));
    await mount(tester, f);
    expect(find.text('配对已取消'), findsOneWidget);
    expect(find.text('重新开始'), findsNothing);
    expect(f.journal.value!.requestId, request);
  });

  testWidgets(
      'expiry deadline hides the QR without waiting for automatic polling',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    await press(tester, '生成配对凭证');
    expect(find.byType(QrImageView), findsOneWidget);
    f.clock = moment + 900001;
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('复制配对凭证'), findsNothing);
  });

  testWidgets(
      'inline cancellation stays available while its explanation is read',
      (tester) async {
    final f = Fixture(saved: intent());
    await mount(tester, f);
    await press(tester, '取消这次配对');
    expect(find.text('确认取消'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('确认取消'), findsOneWidget);
    expect(f.requests.length, 1,
        reason: 'Pause automatic reads during confirmation.');
  });

  testWidgets(
      'typing the field code pauses automatic reads without losing focus',
      (tester) async {
    final f = Fixture(
        saved: intent(),
        handler: (_) async => response(status('AWAITING_CONFIRMATION')));
    await mount(tester, f);
    await tester.tap(find.byKey(const ValueKey('enrollment-code')));
    await tester.enterText(
        find.byKey(const ValueKey('enrollment-code')), 'AB12');
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(f.requests.length, 1,
        reason: 'Typing must not be interrupted by polling.');
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('enrollment-code')))
            .controller!
            .text,
        'AB12');
  });

  testWidgets(
      'first screen explains the flow and creates only on an explicit click',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    expect(find.text('连接设备'), findsOneWidget);
    expect(find.text('选择设备'), findsOneWidget);
    expect(find.text('小明'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(f.requests, isEmpty);
    await press(tester, '生成配对凭证');
    expect(f.requests.single.headers['client-request-id'], request);
    expect(jsonDecode(f.requests.single.body),
        {'subjectId': child, 'platform': 'ANDROID', 'requestedMode': 'BYOD'});
    expect(find.byType(QrImageView), findsOneWidget);
  });
  testWidgets(
      'copy contains only the device import ticket and no service or adult credentials',
      (tester) async {
    final f = Fixture();
    String? copied;
    await mount(tester, f, copy: (value) async {
      copied = value;
    });
    await press(tester, '生成配对凭证');
    await press(tester, '复制配对凭证');
    expect(jsonDecode(copied!), {
      'tenantId': tenant,
      'id': request,
      'token': 'a' * 43,
      'expiresAt': moment + 900000
    });
    expect(jsonDecode(f.journal.value!.encode()).containsKey('token'), isFalse);
  });
  testWidgets(
      'missing unknown request offers only explicit original continuation',
      (tester) async {
    final f = Fixture(
        saved: intent(),
        handler: (req) async => req.method == 'GET'
            ? response({'errorCode': 'ENROLLMENT_CREATION_UNAVAILABLE'}, 404)
            : response(issued(), 201));
    await mount(tester, f);
    expect(find.text('结果尚未确认'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
    await press(tester, '继续原操作');
    expect(f.requests.last.headers['client-request-id'], request);
    expect(f.journal.value!.requestId, request);
  });
  testWidgets(
      'lost secret requires cancelling the old pending pairing before a new form',
      (tester) async {
    var cancelled = false;
    final f = Fixture(
        saved: intent(),
        handler: (req) async {
          if (req.method == 'DELETE') {
            cancelled = true;
            return response(null, 204);
          }
          return response(status(cancelled ? 'CANCELLED' : 'PENDING_CLAIM'));
        });
    await mount(tester, f);
    expect(find.text('凭证已隐藏，无法重新显示'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    await press(tester, '取消这次配对');
    await press(tester, '确认取消');
    expect(find.text('配对已取消'), findsOneWidget);
    expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
    await press(tester, '重新开始');
    expect(f.journal.value, isNull);
    expect(find.text('生成配对凭证'), findsOneWidget);
  });
  testWidgets(
      'field confirmation normalizes the code and reads the resulting pairing fact',
      (tester) async {
    var done = false;
    String? opened;
    final f = Fixture(
        saved: intent(),
        handler: (req) async {
          if (req.method == 'POST') {
            done = true;
            return response(confirmedDevice());
          }
          return response(status(done ? 'CONFIRMED' : 'AWAITING_CONFIRMATION'));
        });
    await mount(tester, f, open: (id) => opened = id);
    await tester.enterText(
        find.byKey(const ValueKey('enrollment-code')), 'abcdef01');
    await press(tester, '确认配对');
    expect(
        jsonDecode(f.requests.firstWhere((r) => r.method == 'POST').body)[
            'pairingCode'],
        'ABCDEF01');
    expect(find.text('配对已确认'), findsOneWidget);
    await press(tester, '查看设备');
    expect(opened, device);
    expect(find.textContaining('设备当前在线'), findsNothing);
  });
  testWidgets(
      'reauthentication preserves the same non-secret recovery pointer without replay',
      (tester) async {
    var reauth = 0;
    final f = Fixture(
        handler: (_) async => response({'errorCode': 'REAUTH_REQUIRED'}, 401));
    await mount(tester, f, reauth: () => reauth++);
    await press(tester, '生成配对凭证');
    await press(tester, '重新安全验证');
    expect(reauth, 1);
    expect(f.journal.value!.requestId, request);
    expect(f.requests.where((r) => r.method == 'POST').length, 1);
  });
  testWidgets('background hides the QR and retains only its recovery pointer',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    await press(tester, '生成配对凭证');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('连接信息已隐藏'), findsOneWidget);
    expect(f.controller.ticket, isNull);
    expect(f.journal.value!.requestId, request);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(f.requests.where((r) => r.method == 'POST').length, 1);
  });
  testWidgets('scope invalidation hides credentials and disables actions',
      (tester) async {
    final f = Fixture();
    await mount(tester, f);
    await press(tester, '生成配对凭证');
    f.controller.invalidate();
    await tester.pumpAndSettle();
    expect(find.text('工作空间或权限已变化'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('复制配对凭证'), findsNothing);
  });
  testWidgets(
      'narrow large text keeps the form action reachable without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final f = Fixture();
    await mount(tester, f, scale: 1.5);
    await tester.ensureVisible(find.text('生成配对凭证'));
    expect(tester.takeException(), isNull);
    expect(find.text('生成配对凭证'), findsOneWidget);
  });
  testWidgets('resume notice opens the existing request without issuing writes',
      (tester) async {
    final f = Fixture(saved: intent());
    var opens = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: EnrollmentResumeNotice(
                journal: f.journal,
                scope: scope,
                isCurrent: () => true,
                onOpen: () async {
                  opens++;
                }))));
    await tester.pumpAndSettle();
    await press(tester, '继续连接设备');
    expect(opens, 1);
    expect(f.requests, isEmpty);
  });
  testWidgets(
      'damaged recovery notice gives inspection instead of a new-create action',
      (tester) async {
    final f = Fixture();
    f.journal.failure =
        const ApiFailure(409, 'ENROLLMENT_RECOVERY_STORAGE_INVALID');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: EnrollmentResumeNotice(
                journal: f.journal,
                scope: scope,
                isCurrent: () => true,
                onOpen: () async {}))));
    await tester.pumpAndSettle();
    expect(find.text('检查恢复记录'), findsOneWidget);
    expect(find.text('生成配对凭证'), findsNothing);
  });
}
