@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/session.dart';
import 'package:guardian/pages/console_pages.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/device_management_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const tenantId = '44444444-4444-4444-8444-444444444444';
const deviceId = '11111111-1111-4111-8111-111111111111';
Json record() => {
      'id': deviceId,
      'subjectId': '22222222-2222-4222-8222-222222222222',
      'registrationId': '33333333-3333-4333-8333-333333333333',
      'displayName': '学习平板',
      'platform': 'ANDROID',
      'osVersion': '14',
      'state': 'ACTIVE',
      'managementMode': 'BYOD',
      'controlLevel': 'LIMITED',
      'lastHeartbeatAt': null,
      'observationStatus': 'UNKNOWN',
      'keyThumbprint': 'a' * 43,
      'version': 0,
    };
http.Response reply() => http.Response(jsonEncode(record()), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

class EntrySession extends Session {
  EntrySession(Future<http.Response> Function(http.Request) handler) {
    profile = {'subject': 'adult-a'};
    tenant = {'id': tenantId, 'kind': 'FAMILY'};
    role = 'OWNER';
    transport = MockClient(handler);
  }
  late final http.Client transport;
  late final Api _testApi =
      Api(() async => transport, baseUrl: 'http://mock.invalid/api/v1');
  @override
  Api get api => _testApi;
  bool signedIn = true;
  int epoch = 0;
  @override
  bool get authenticated => signedIn;
  @override
  int get scopeGeneration => epoch;
  void changed() {
    epoch++;
    notifyListeners();
  }
}

Future<void> mount(WidgetTester tester, EntrySession session,
    {ValueChanged<bool>? onResult, Listenable? accessChanges,
    bool Function()? hasAccess}) async {
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    final changed = await ConsoleActions(context, session)
                        .deviceDetailsChanged({'id': deviceId},
                            accessChanges: accessChanges, hasAccess: hasAccess);
                    onResult?.call(changed);
                  },
                  child: const Text('打开设备'))))));
  await tester.tap(find.text('打开设备'));
  await tester.pump();
}

Future<void> settleReads(WidgetTester tester) async {
  // Browser streams use the native event queue. Advance it as well as Flutter's
  // fake frame clock; a pump alone does not complete a real streamed response.
  for (var frame = 0; frame < 6; frame++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'device entry opens its managed window while first GET is pending',
      (tester) async {
    final pending = Completer<http.Response>();
    var requests = 0;
    final session = EntrySession((_) {
      requests++;
      return pending.future;
    });
    addTearDown(session.dispose);
    final results = <bool>[];
    await mount(tester, session, onResult: results.add);
    expect(find.byType(DeviceManagementDialog), findsOneWidget);
    expect(requests, 1);
    pending.complete(reply());
    await settleReads(tester);
    expect(find.text('学习平板'), findsOneWidget,
        reason: tester
            .widget<DeviceManagementDialog>(find.byType(DeviceManagementDialog))
            .controller
            .error
            .toString());
    await tester.tap(find.byKey(const Key('device-management-close')));
    await settleReads(tester);
    expect(results, [false], reason: 'Viewing a device does not change the list.');
    expect(requests, 1);
  });
  testWidgets('unauthenticated device entry dispatches no GET', (tester) async {
    var requests = 0;
    final session = EntrySession((_) async {
      requests++;
      return reply();
    })
      ..signedIn = false;
    addTearDown(session.dispose);
    await mount(tester, session);
    await settleReads(tester);
    expect(requests, 0);
    expect(find.byType(DeviceManagementDialog), findsNothing);
    expect(find.text('学习平板'), findsNothing);
  });
  testWidgets('ABA before late initial response never opens private details',
      (tester) async {
    final pending = Completer<http.Response>();
    var requests = 0;
    final session = EntrySession((_) {
      requests++;
      return pending.future;
    });
    addTearDown(session.dispose);
    await mount(tester, session);
    session.role = 'GUARDIAN';
    session.changed();
    session.role = 'OWNER';
    session.changed();
    pending.complete(reply());
    await settleReads(tester);
    expect(requests, 1);
    expect(find.text('学习平板'), findsNothing);
    expect(find.byType(DeviceManagementDialog), findsNothing);
  });
  testWidgets(
      'scope change hides loaded private details and cannot revive them',
      (tester) async {
    final session = EntrySession((_) async => reply());
    addTearDown(session.dispose);
    await mount(tester, session);
    await settleReads(tester);
    expect(find.text('学习平板'), findsOneWidget,
        reason: tester
            .widget<DeviceManagementDialog>(find.byType(DeviceManagementDialog))
            .controller
            .error
            .toString());
    session.changed();
    await settleReads(tester);
    expect(find.text('学习平板'), findsNothing);
    expect(find.byType(DeviceManagementDialog), findsNothing);
  });
  for (final rawParentRemoval in [false, true]) {
  testWidgets('device parent retirement preserves a cover: raw=$rawParentRemoval',
      (tester) async {
    final session = EntrySession((_) async => reply());
    final access = ValueNotifier<bool>(true);
    addTearDown(session.dispose);
    addTearDown(access.dispose);
    final results = <bool>[];
    await mount(tester, session, onResult: results.add,
        accessChanges: access, hasAccess: () => access.value);
    await settleReads(tester);
    final close = tester.widget<IconButton>(
        find.byKey(const Key('device-management-close'))).onPressed!;
    final parent = ModalRoute.of(tester.element(
        find.text('打开设备', skipOffstage: false)))!;
    final dialogContext = tester.element(find.byType(DeviceManagementDialog));
    unawaited(showDialog<void>(context: dialogContext,
        builder: (_) => const AlertDialog(
            key: Key('independent-device-cover'), title: Text('独立通知'))));
    await tester.pumpAndSettle();
    close();
    await tester.pump();
    expect(find.byKey(const Key('independent-device-cover')), findsOneWidget);
    if (rawParentRemoval) {
      parent.navigator!.removeRoute(parent);
    } else {
      access.value = false;
    }
    await settleReads(tester);
    expect(results, [false]);
    expect(find.byType(DeviceManagementDialog), findsNothing);
    expect(find.text('学习平板'), findsNothing);
    expect(find.byKey(const Key('independent-device-cover')), findsOneWidget);
    access.value = true;
    close();
    await tester.pump();
    expect(find.byKey(const Key('independent-device-cover')), findsOneWidget);
    expect(results, [false]);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  }
}
