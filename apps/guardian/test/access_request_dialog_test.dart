import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/ui/access_request_dialog.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/owned_dialog_route.dart';

const deviceId = '11111111-1111-1111-1111-111111111111';
Json policy({String version = 'version-1', int rules = 1}) => {
      'id': 'policy-1',
      'name': '课堂策略',
      'baseVersionId': version,
      'commonRules': [
        {'id': 'window', 'kind': 'TIME_WINDOW'}
      ],
      'applications': [
        {
          'id': 'app-1',
          'displayName': '课堂练习',
          'rules': List.generate(
              rules, (i) => {'id': 'lesson_$i', 'kind': 'APP_LAUNCH'}),
        }
      ],
    };
Future<PageResult> load(String path, String? cursor) async => path == 'devices'
    ? PageResult([
        {'id': deviceId, 'displayName': '教室平板', 'state': 'ACTIVE'},
        {
          'id': 'unconfirmed',
          'displayName': '待确认设备',
          'state': 'AWAITING_CONFIRMATION'
        }
      ], null)
    : PageResult([policy()], null);

Future<void> open(WidgetTester tester, Future<Json> Function(Json) submit,
    {Future<PageResult> Function(String, String?)? loader,
    ValueChanged<Json?>? onResult}) async {
  await tester.pumpWidget(MaterialApp(
      theme: consoleTheme(),
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    late final OwnedDialogRoute<Json> route;
                    route = OwnedDialogRoute<Json>(
                        context: context,
                        builder: (_) => AccessRequestDialog(
                            load: loader ?? load, submit: submit,
                            onComplete: route.finish));
                    final result = await presentOwnedDialog(context, route);
                    onResult?.call(result);
                  },
                  child: const Text('打开申请'))))));
  await tester.tap(find.text('打开申请'));
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, Key key, String label) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> selectDevice(WidgetTester tester) =>
    choose(tester, const Key('request-device'), '教室平板 · 11111111…');
Future<void> selectApp(WidgetTester tester) =>
    choose(tester, const ValueKey('option-$deviceId'), '课堂练习 · 课堂策略');
Future<void> submit(WidgetTester tester, [String title = '提交申请']) async {
  final control = find.widgetWithText(FilledButton, title);
  await tester.ensureVisible(control);
  await tester.tap(control);
  await tester.pumpAndSettle();
}

DropdownButton<String> _deviceDropdown(WidgetTester tester, Finder field) =>
    tester.widget<DropdownButton<String>>(find.descendant(
        of: field,
        matching: find
            .byWidgetPredicate((widget) => widget is DropdownButton<String>)));

Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 40 && !done(); attempt++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(done(), isTrue, reason: 'The dialog did not finish within one second.');
}

void main() {
  testWidgets('requires device application rules and bounded duration',
      (tester) async {
    int writes = 0;
    await open(tester, (body) async {
      writes++;
      return body;
    });
    await submit(tester);
    expect(find.text('请选择设备'), findsOneWidget);
    expect(writes, 0);
    await selectDevice(tester);
    expect(find.text('待确认设备'), findsNothing);
    await selectApp(tester);
    for (final (minutes, seconds, message) in [
      ('61', '', '请输入 0–60 的整数'),
      ('0', '0', '合计需为 1 秒至 60 分钟'),
      ('60', '1', '合计需为 1 秒至 60 分钟'),
      ('1', '60', '请输入 0–59 的整数或留空'),
    ]) {
      await tester.enterText(find.byKey(const Key('request-minutes')), minutes);
      await tester.enterText(find.byKey(const Key('request-seconds')), seconds);
      await submit(tester);
      expect(find.text(message), findsOneWidget);
      expect(writes, 0);
    }
  });
  testWidgets('merges common rules and sends trimmed reason and seconds',
      (tester) async {
    Json? sent;
    await open(tester, (body) async {
      sent = body;
      return body;
    });
    await selectDevice(tester);
    await selectApp(tester);
    expect(find.text('申请放宽的规则（2/20）'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('request-minutes')), '5');
    await tester.enterText(find.byKey(const Key('request-seconds')), '17');
    await tester.enterText(find.byKey(const Key('request-reason')), '  课堂活动  ');
    await submit(tester);
    expect(sent, {
      'deviceId': deviceId,
      'policyId': 'policy-1',
      'baseVersionId': 'version-1',
      'applicationId': 'app-1',
      'ruleIds': ['lesson_0', 'window'],
      'requestedWindowSeconds': 317,
      'reason': '课堂活动'
    });
    expect(find.text('申请临时访问'), findsNothing);
  });
  testWidgets('accepts subminute maximum and blank second durations',
      (tester) async {
    for (final (minutes, seconds, expected) in [
      ('0', '1', 1),
      ('60', '0', 3600),
      ('15', '', 900),
    ]) {
      Json? sent;
      await open(tester, (body) async {
        sent = body;
        return body;
      });
      final minuteField = find.byKey(const Key('request-minutes'));
      final secondField = find.byKey(const Key('request-seconds'));
      expect(tester.widget<TextFormField>(minuteField).controller!.text, '15');
      expect(tester.widget<TextFormField>(secondField).controller!.text, isEmpty);
      await selectDevice(tester);
      await selectApp(tester);
      await tester.enterText(minuteField, minutes);
      await tester.enterText(secondField, seconds);
      await submit(tester);
      expect(sent?['requestedWindowSeconds'], expected);
      expect(sent?['requestedWindowSeconds'], isA<int>());
      expect(sent, isNot(contains('minutes')));
      expect(sent, isNot(contains('seconds')));
      expect(find.text('申请临时访问'), findsNothing);
    }
  });
  testWidgets('empty option page preserves cursor and can load the next page',
      (tester) async {
    final cursors = <String?>[];
    await open(tester, (body) async => body, loader: (path, cursor) async {
      if (path == 'devices') return load(path, cursor);
      cursors.add(cursor);
      return cursor == null
          ? PageResult([], 'next-policy')
          : PageResult([policy()], null);
    });
    await selectDevice(tester);
    expect(find.text('本页没有可申请规则，可继续加载。'), findsOneWidget);
    await tester.ensureVisible(find.text('加载更多规则'));
    await tester.tap(find.text('加载更多规则'));
    await tester.pumpAndSettle();
    await selectApp(tester);
    expect(cursors, [null, 'next-policy']);
    expect(find.text('申请放宽的规则（2/20）'), findsOneWidget);
  });
  testWidgets(
      'expired device cursor restarts from the first page without losing the draft',
      (tester) async {
    final selectedDevice = (await load('devices', null)).items.first;
    final restarted = Completer<PageResult>();
    final cursors = <String?>[];
    Json? sent;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!restarted.isCompleted) restarted.complete(PageResult([], null));
      await tester.pumpAndSettle();
    });
    await open(tester, (body) async {
      sent = body;
      return body;
    }, loader: (path, cursor) async {
      if (path != 'devices') return load(path, cursor);
      cursors.add(cursor);
      return switch (cursors.length) {
        1 => PageResult([
            selectedDevice,
            {'id': 'old-unselected', 'displayName': '旧列表设备', 'state': 'ACTIVE'},
          ], 'expired-page'),
        2 => throw const ApiFailure(400, 'INVALID_CURSOR'),
        3 => restarted.future,
        _ => PageResult([], null),
      };
    });
    await selectDevice(tester);
    await selectApp(tester);
    await tester.enterText(find.byKey(const Key('request-minutes')), '7');
    await tester.enterText(find.byKey(const Key('request-reason')), '保留的申请理由');
    await tester.ensureVisible(find.text('加载更多设备'));
    await tester.tap(find.text('加载更多设备'));
    await tester.pumpAndSettle();
    expect(find.text('从首页重新加载设备'), findsOneWidget);
    expect(find.text('重试加载设备'), findsNothing);
    final deviceField = find.byKey(const Key('request-device'));
    expect(tester.state<FormFieldState<String>>(deviceField).value, deviceId);
    final restart = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '从首页重新加载设备'))
        .onPressed!;
    restart();
    restart();
    await tester.pump();
    expect(cursors, [null, 'expired-page', null]);
    expect(
        _deviceDropdown(tester, deviceField).items!.map((item) => item.value),
        contains('old-unselected'),
        reason:
            'Keep the existing choices until the replacement page succeeds.');
    restarted.complete(PageResult([
      {'id': 'new-first', 'displayName': '新首页设备', 'state': 'ACTIVE'},
    ], 'fresh-next'));
    await tester.pumpAndSettle();
    expect(
        _deviceDropdown(tester, deviceField).items!.map((item) => item.value),
        unorderedEquals(['new-first', deviceId]));
    expect(tester.state<FormFieldState<String>>(deviceField).value, deviceId);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('request-minutes')))
            .controller!
            .text,
        '7');
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('request-reason')))
            .controller!
            .text,
        '保留的申请理由');
    expect(find.text('申请放宽的规则（2/20）'), findsOneWidget);
    await tester.ensureVisible(find.text('加载更多设备'));
    await tester.tap(find.text('加载更多设备'));
    await tester.pumpAndSettle();
    expect(cursors, [null, 'expired-page', null, 'fresh-next']);
    await submit(tester);
    expect(sent?['deviceId'], deviceId);
    expect(sent?['requestedWindowSeconds'], 420);
    expect(sent?['reason'], '保留的申请理由');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'restarting devices clears an explicitly revoked selection and ignores its late rules error',
      (tester) async {
    const replacement = '33333333-3333-3333-3333-333333333333';
    const targetChanged = ApiFailure(409, 'ACCESS_TARGET_CHANGED');
    final selectedDevice = (await load('devices', null)).items.first;
    final oldRules = Completer<PageResult>();
    var deviceReads = 0, ruleReads = 0;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!oldRules.isCompleted) oldRules.complete(PageResult([], null));
      await tester.pumpAndSettle();
    });
    await open(tester, (body) async => body, loader: (path, cursor) async {
      if (path != 'devices') {
        return ++ruleReads == 2
            ? oldRules.future
            : PageResult([policy()], null);
      }
      return switch (++deviceReads) {
        1 => PageResult([selectedDevice], 'expired-page'),
        2 => throw const ApiFailure(400, 'INVALID_CURSOR'),
        _ => PageResult([
            {...selectedDevice, 'state': 'REVOKED'},
            {'id': replacement, 'displayName': '替代设备', 'state': 'ACTIVE'},
          ], null),
      };
    });
    await selectDevice(tester);
    await selectApp(tester);
    await tester.enterText(find.byKey(const Key('request-minutes')), '8');
    await tester.enterText(find.byKey(const Key('request-reason')), '不要丢失的理由');
    final oldDevice = tester
        .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('request-device')))
        .onChanged!;
    final oldOption = tester
        .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('option-$deviceId')))
        .onChanged!;
    final oldRule = tester
        .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
        .onChanged!;
    await tester.ensureVisible(find.text('加载更多设备'));
    await tester.tap(find.text('加载更多设备'));
    await tester.pumpAndSettle();
    final refreshRules = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '刷新可申请规则'))
        .onPressed!;
    refreshRules();
    refreshRules();
    await tester.pump();
    expect(ruleReads, 2);
    final restart = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '从首页重新加载设备'))
        .onPressed!;
    restart();
    restart();
    await tester.pumpAndSettle();

    final deviceField = find.byKey(const Key('request-device'));
    expect(tester.state<FormFieldState<String>>(deviceField).value, isNull);
    final dropdown = _deviceDropdown(tester, deviceField);
    expect(dropdown.items!.map((item) => item.value), [replacement]);
    expect(dropdown.onChanged, isNotNull);
    expect(find.text('当前选择的设备已失效，已保留时长和理由。请重新选择设备。'), findsOneWidget);
    oldRules.completeError(const ApiFailure(403, 'SCOPE_DENIED'));
    await tester.pumpAndSettle();
    expect(find.text(targetChanged.message), findsOneWidget,
        reason:
            'The old device rules request must not replace the recovery reason.');
    expect(find.byKey(const ValueKey('option-$deviceId')), findsNothing);
    expect(find.text('申请放宽的规则（2/20）'), findsNothing);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('request-minutes')))
            .controller!
            .text,
        '8');
    expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('request-reason')))
            .controller!
            .text,
        '不要丢失的理由');
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交申请'))
            .onPressed,
        isNull);
    oldDevice(deviceId);
    oldOption('policy-1/app-1');
    oldRule(true);
    refreshRules();
    await tester.pump();
    expect(deviceReads, 3);
    expect(ruleReads, 2);
    expect(tester.state<FormFieldState<String>>(deviceField).value, isNull);
    await choose(tester, const Key('request-device'), '替代设备 · 33333333…');
    final optionField = find.byKey(const ValueKey('option-$replacement'));
    oldOption('policy-1/app-1');
    await tester.pump();
    expect(tester.state<FormFieldState<String>>(optionField).value, isNull);
    expect(find.text('申请放宽的规则（2/20）'), findsNothing);
    await choose(tester, const ValueKey('option-$replacement'), '课堂练习 · 课堂策略');
    oldRule(false);
    oldDevice(deviceId);
    refreshRules();
    await tester.pump();
    expect(ruleReads, 3);
    expect(tester.state<FormFieldState<String>>(deviceField).value, replacement);
    expect(find.text('申请放宽的规则（2/20）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'saved controls cannot change a covered or pending request and completion preserves the notification',
      (tester) async {
    const replacement = '33333333-3333-3333-3333-333333333333';
    final pending = Completer<Json>();
    final reads = <(String, String?)>[];
    final writes = <Json>[];
    final results = <Json?>[];
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!pending.isCompleted) pending.complete(<String, dynamic>{});
      await tester.pump();
    });
    await open(tester, (body) {
      writes.add(body);
      return pending.future;
    }, onResult: results.add, loader: (path, cursor) async {
      reads.add((path, cursor));
      return path == 'devices'
          ? PageResult([
              {'id': deviceId, 'displayName': '教室平板', 'state': 'ACTIVE'},
              {'id': replacement, 'displayName': '替代设备', 'state': 'ACTIVE'},
            ], 'more-devices')
          : PageResult([policy()], 'more-rules');
    });
    await selectDevice(tester);
    await selectApp(tester);
    await tester.enterText(find.byKey(const Key('request-minutes')), '6');
    await tester.enterText(find.byKey(const Key('request-seconds')), '19');
    await tester.enterText(find.byKey(const Key('request-reason')), '保留原申请');
    final readSnapshot = List<(String, String?)>.of(reads);
    final oldDevice = tester
        .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('request-device')))
        .onChanged!;
    final oldOption = tester
        .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('option-$deviceId')))
        .onChanged!;
    final oldRule = tester
        .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
        .onChanged!;
    VoidCallback button(String label) => tester
        .widget<TextButton>(find.widgetWithText(TextButton, label))
        .onPressed!;
    final moreDevices = button('加载更多设备');
    final moreRules = button('加载更多规则');
    final refresh = button('刷新可申请规则');
    final close = button('关闭');
    final send = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '提交申请'))
        .onPressed!;
    final navigator =
        Navigator.of(tester.element(find.byType(AccessRequestDialog)));
    final request = find.byType(AccessRequestDialog, skipOffstage: false);

    void invokeSavedControls() {
      oldDevice(replacement);
      oldOption(null);
      oldRule(false);
      moreDevices();
      moreRules();
      refresh();
      send();
      close();
    }

    void expectDraft() {
      expect(
          tester
              .state<FormFieldState<String>>(find.byKey(
                  const Key('request-device'),
                  skipOffstage: false))
              .value,
          deviceId);
      expect(
          tester
              .state<FormFieldState<String>>(find.byKey(
                  const ValueKey('option-$deviceId'),
                  skipOffstage: false))
              .value,
          'policy-1/app-1');
      expect(
          find.text('申请放宽的规则（2/20）', skipOffstage: false), findsOneWidget);
      expect(reads, readSnapshot);
      expect(results, isEmpty);
    }

    Future<DialogRoute<void>> cover() async {
      final notice = DialogRoute<void>(
          context: navigator.context,
          builder: (_) => const AlertDialog(title: Text('独立通知')));
      unawaited(navigator.push<void>(notice));
      await _pumpUntil(tester,
          () => notice.animation?.status == AnimationStatus.completed);
      return notice;
    }

    final firstNotice = await cover();
    invokeSavedControls();
    await tester.pump();
    expectDraft();
    expect(writes, isEmpty);
    expect(firstNotice.isCurrent, isTrue);
    navigator.pop();
    await tester.pumpAndSettle();

    send();
    invokeSavedControls();
    await tester.pump();
    expectDraft();
    expect(writes, hasLength(1));
    expect(writes.single['deviceId'], deviceId);
    expect(writes.single['ruleIds'], ['lesson_0', 'window']);
    expect(writes.single['requestedWindowSeconds'], 379);
    expect(writes.single['reason'], '保留原申请');
    expect(find.text('提交中…'), findsOneWidget);

    final notice = await cover();
    invokeSavedControls();
    await tester.pump();
    expectDraft();
    expect(writes, hasLength(1));
    final response = <String, dynamic>{'id': 'request-1', ...writes.single};
    pending.complete(response);
    await _pumpUntil(
        tester, () => request.evaluate().isEmpty && results.length == 1);
    expect(results.single, response);
    expect(notice.isCurrent, isTrue);
    expect(find.text('独立通知'), findsOneWidget);
    invokeSavedControls();
    await tester.pump();
    expect(notice.isCurrent, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    invokeSavedControls();
    await tester.pump();
    expect(reads, readSnapshot);
    expect(writes, hasLength(1));
    expect(results, [response]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'directory read denials erase the private draft and retire saved controls',
      (tester) async {
    for (final directory in ['devices', 'options']) {
      for (final status in [401, 403]) {
        final reads = <(String, String?)>[];
        final writes = <Json>[];
        final results = <Json?>[];
        final latePage = Completer<PageResult>();
        var denyReads = true;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          if (!latePage.isCompleted) latePage.complete(PageResult([], null));
          await tester.pumpAndSettle();
        });
        await open(tester, (body) async {
          writes.add(body);
          return body;
        }, onResult: results.add, loader: (path, cursor) async {
          reads.add((path, cursor));
          final kind = path == 'devices' ? 'devices' : 'options';
          if (cursor == null || !denyReads) {
            final page = await load(path, cursor);
            return PageResult(page.items, 'more-$kind');
          }
          if (kind == directory) {
            throw ApiFailure(status, 'READ_DENIED');
          }
          return latePage.future;
        });
        await selectDevice(tester);
        await selectApp(tester);
        await tester.enterText(find.byKey(const Key('request-minutes')), '6');
        await tester.enterText(find.byKey(const Key('request-seconds')), '19');
        await tester.enterText(
            find.byKey(const Key('request-reason')), '需隐藏的私有申请理由');
        final textControllers = [
          for (final key in [
            'request-minutes',
            'request-seconds',
            'request-reason',
          ])
            tester.widget<TextFormField>(find.byKey(Key(key))).controller!,
        ];
        final oldDevice = tester
            .widget<DropdownButtonFormField<String>>(
                find.byKey(const Key('request-device')))
            .onChanged!;
        final oldOption = tester
            .widget<DropdownButtonFormField<String>>(
                find.byKey(const ValueKey('option-$deviceId')))
            .onChanged!;
        final oldRule = tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
            .onChanged!;
        VoidCallback button(String label) => tester
            .widget<TextButton>(find.widgetWithText(TextButton, label))
            .onPressed!;
        final moreDevices = button('加载更多设备');
        final moreRules = button('加载更多规则');
        final refresh = button('刷新可申请规则');
        final send = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交申请'))
            .onPressed!;
        void invokeSavedControls() {
          oldDevice(null);
          oldOption(null);
          oldRule(false);
          moreDevices();
          moreRules();
          refresh();
          send();
        }

        // Keep the other directory in flight when this directory denies access.
        (directory == 'devices' ? moreRules : moreDevices)();
        await tester.pump();
        button(directory == 'devices' ? '加载更多设备' : '加载更多规则')();
        await tester.pumpAndSettle();
        final deniedReads = List<(String, String?)>.of(reads);
        expect(deniedReads, hasLength(4));
        expect(deniedReads.last.$2, 'more-$directory');

        void expectHidden() {
          expect(find.text('读取权限已变化'), findsOneWidget);
          expect(find.text('原申请资料已隐藏。请关闭窗口，在当前工作空间重新打开申请。'),
              findsOneWidget);
          expect(find.byType(Form, skipOffstage: false), findsNothing);
          expect(find.byType(TextFormField, skipOffstage: false), findsNothing);
          expect(find.byType(CheckboxListTile, skipOffstage: false), findsNothing);
          for (final privateText in [
            '教室平板 · 11111111…',
            '课堂练习 · 课堂策略',
            '规则 lesson_0',
            '规则 window',
            '需隐藏的私有申请理由',
          ]) {
            expect(find.text(privateText, skipOffstage: false), findsNothing);
          }
          expect(textControllers.map((controller) => controller.text),
              ['', '', '']);
          final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
          expect(dialog.actions, hasLength(1));
          expect(button('关闭'), isNotNull);
          expect(reads, deniedReads);
          expect(writes, isEmpty);
          expect(results, isEmpty);
        }

        expectHidden();
        invokeSavedControls();
        await tester.pump();
        expectHidden();
        latePage.complete(await load(
            directory == 'devices'
                ? 'access-requests/options?deviceId=$deviceId'
                : 'devices',
            null));
        await tester.pumpAndSettle();
        expectHidden();
        denyReads = false;
        invokeSavedControls();
        await tester.pumpAndSettle();
        expectHidden();
        await tester.tap(find.widgetWithText(TextButton, '关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(AccessRequestDialog), findsNothing);
        expect(results, [null]);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('ordinary and reauthentication device failures preserve the draft',
      (tester) async {
    for (final failure in [
      const ApiFailure(503, 'TEMPORARY_FAILURE'),
      const ApiFailure(401, 'REAUTH_REQUIRED'),
    ]) {
      final selectedDevice = (await load('devices', null)).items.first;
      final cursors = <String?>[];
      await open(tester, (body) async => body, loader: (path, cursor) async {
        if (path != 'devices') return load(path, cursor);
        cursors.add(cursor);
        return switch (cursors.length) {
          1 => PageResult([selectedDevice], 'retry-page'),
          2 => throw failure,
          _ => PageResult([
              {'id': 'next-device', 'displayName': '后续设备', 'state': 'ACTIVE'},
            ], null),
        };
      });
      await selectDevice(tester);
      await selectApp(tester);
      await tester.enterText(find.byKey(const Key('request-minutes')), '7');
      await tester.enterText(find.byKey(const Key('request-seconds')), '12');
      await tester.enterText(find.byKey(const Key('request-reason')), '保留的申请理由');
      void expectDraft() {
        expect(find.text('读取权限已变化'), findsNothing);
        expect(
            tester
                .state<FormFieldState<String>>(
                    find.byKey(const Key('request-device')))
                .value,
            deviceId);
        expect(
            tester
                .state<FormFieldState<String>>(
                    find.byKey(const ValueKey('option-$deviceId')))
                .value,
            'policy-1/app-1');
        expect(find.text('申请放宽的规则（2/20）'), findsOneWidget);
        expect([
          for (final key in [
            'request-minutes',
            'request-seconds',
            'request-reason',
          ])
            tester.widget<TextFormField>(find.byKey(Key(key))).controller!.text,
        ], ['7', '12', '保留的申请理由']);
      }

      await tester.ensureVisible(find.text('加载更多设备'));
      await tester.tap(find.text('加载更多设备'));
      await tester.pumpAndSettle();
      expect(find.text('从首页重新加载设备'), findsNothing);
      expectDraft();
      await tester.ensureVisible(find.text('重试加载设备'));
      await tester.tap(find.text('重试加载设备'));
      await tester.pumpAndSettle();
      expect(cursors, [null, 'retry-page', 'retry-page']);
      final deviceField = find.byKey(const Key('request-device'));
      expect(
          _deviceDropdown(tester, deviceField).items!.map((item) => item.value),
          unorderedEquals([deviceId, 'next-device']));
      expect(find.text('加载更多设备'), findsNothing);
      expectDraft();
      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('unknown retries preserve the immutable body through refusals',
      (tester) async {
    for (final terminal in <ApiFailure?>[
      null,
      const ApiFailure(412, 'VERSION_CONFLICT'),
      const ApiFailure(410, 'IDEMPOTENCY_RESPONSE_ERASED'),
    ]) {
      final writes = <Json>[];
      await open(tester, (body) async {
        writes.add(body);
        switch (writes.length) {
          case 1:
            throw const ApiFailure(503, 'TEMPORARY_FAILURE');
          case 2:
            throw const ApiFailure(401, 'REAUTH_REQUIRED');
          case 3:
            throw const ApiFailure(400, 'INVALID_REQUEST');
          default:
            if (terminal != null) throw terminal;
            return body;
        }
      });
      await selectDevice(tester);
      await selectApp(tester);
      await submit(tester);
      final Json originalBody = writes.single;
      final List<String> originalRules = originalBody['ruleIds'] as List<String>;
      expect(originalBody['requestedWindowSeconds'], 900);
      expect(originalRules, ['lesson_0', 'window']);
      expect(() => originalBody['reason'] = '替换理由', throwsUnsupportedError);
      expect(() => originalRules.add('replacement'), throwsUnsupportedError);

      void expectLocked() {
        for (final key in [
          'request-minutes',
          'request-seconds',
          'request-reason',
        ]) {
          expect(tester.widget<TextFormField>(find.byKey(Key(key))).enabled,
              false);
        }
        expect(
            tester
                .widget<DropdownButtonFormField<String>>(
                    find.byKey(const Key('request-device')))
                .onChanged,
            isNull);
        expect(
            tester
                .widget<DropdownButtonFormField<String>>(
                    find.byKey(const ValueKey('option-$deviceId')))
                .onChanged,
            isNull);
        for (final rule in tester.widgetList<CheckboxListTile>(
            find.byType(CheckboxListTile))) {
          expect(rule.onChanged, isNull);
        }
      }

      expectLocked();
      tester
          .widget<TextFormField>(find.byKey(const Key('request-minutes')))
          .controller!
          .text = 'invalid';
      tester
          .widget<TextFormField>(find.byKey(const Key('request-seconds')))
          .controller!
          .text = '60';
      tester
          .widget<TextFormField>(find.byKey(const Key('request-reason')))
          .controller!
          .text = '修改当前控件不能替换原提交';
      await tester.pump();
      for (var attempt = 2; attempt <= 4; attempt++) {
        await submit(tester, '重试原提交');
        expect(writes.length, attempt);
        final Json replayedBody = writes.last;
        expect(identical(replayedBody, originalBody), isTrue);
        expect(
            identical(replayedBody['ruleIds'] as List<String>, originalRules),
            isTrue);
        expect(replayedBody['requestedWindowSeconds'], 900);
        expect(replayedBody['reason'], isNull);
        if (attempt < 4 || terminal != null) expectLocked();
      }
      if (terminal == null) {
        expect(find.text('申请临时访问'), findsNothing);
      } else {
        expect(find.text('原提交已停止'), findsOneWidget);
        final button = find.widgetWithText(FilledButton, '原提交已停止');
        expect(tester.widget<FilledButton>(button).onPressed, isNull);
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(writes.length, 4);
        await tester.tap(find.widgetWithText(TextButton, '关闭'));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('stale baseline disables resubmit until refreshed and reselected',
      (tester) async {
    int writes = 0, reads = 0;
    await open(tester, (body) async {
      writes++;
      throw const ApiFailure(409, 'BASELINE_CHANGED');
    }, loader: (path, cursor) async {
      if (path == 'devices') return load(path, cursor);
      reads++;
      return PageResult([policy(version: 'version-$reads')], null);
    });
    await selectDevice(tester);
    await selectApp(tester);
    final oldOption = tester
        .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('option-$deviceId')))
        .onChanged!;
    final oldRule = tester
        .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
        .onChanged!;
    await submit(tester);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交申请'))
            .onPressed,
        isNull);
    await tester.ensureVisible(find.text('刷新可申请规则'));
    await tester.tap(find.text('刷新可申请规则'));
    await tester.pumpAndSettle();
    oldOption('policy-1/app-1');
    oldRule(true);
    await tester.pump();
    expect(
        tester
            .state<FormFieldState<String>>(
                find.byKey(const ValueKey('option-$deviceId')))
            .value,
        isNull);
    expect(find.text('申请放宽的规则（2/20）'), findsNothing);
    await selectApp(tester);
    oldRule(false);
    await tester.pump();
    expect(find.text('申请放宽的规则（2/20）'), findsOneWidget);
    expect(reads, 2);
    expect(writes, 1);
  });
  testWidgets('twenty-rule maximum keeps selected rules removable',
      (tester) async {
    await open(tester, (body) async => body,
        loader: (path, cursor) async => path == 'devices'
            ? load(path, cursor)
            : PageResult([policy(rules: 21)], null));
    await selectDevice(tester);
    await selectApp(tester);
    expect(find.text('申请放宽的规则（0/20）'), findsOneWidget);
    for (int i = 0; i < 20; i++) {
      final item = find.byType(CheckboxListTile).at(i);
      await tester.ensureVisible(item);
      await tester.tap(item);
      await tester.pump();
    }
    expect(find.text('申请放宽的规则（20/20）'), findsOneWidget);
    expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).at(20))
            .onChanged,
        isNull);
    expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
            .onChanged,
        isNotNull);
  });
  testWidgets('mobile submit failure reveals the reason and recovery action',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const failure = ApiFailure(409, 'BASELINE_CHANGED');
    await open(tester, (body) async => throw failure);
    await selectDevice(tester);
    await selectApp(tester);
    await submit(tester);
    expect(find.text(failure.message).hitTestable(), findsOneWidget);
    expect(find.text('刷新可申请规则').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
