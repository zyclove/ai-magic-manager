import 'dart:io';
import 'dart:ui' as ui;
import 'package:child/ui/child_app.dart';
import 'package:child/ui/tv_workspace.dart';
import 'package:child/ui/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/identity_fixture.dart';

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  if (key == LogicalKeyboardKey.goBack) {
    // The pinned Flutter fixture has no Android scan-code entry for Go Back.
    // Exercise its logical event here; platform Back is tested separately via
    // handlePopRoute. This does not certify an OEM remote's physical mapping.
    await tester.sendKeyEvent(key, physicalKey: PhysicalKeyboardKey.escape);
  } else {
    await tester.sendKeyEvent(key);
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('TV starts in the menu and opens rules using only the remote',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fixture = IdentityFixture();
    addTearDown(fixture.close);
    await fixture.activate();
    const font = String.fromEnvironment('UI_CAPTURE_FONT');
    if (font.isNotEmpty) {
      await tester.runAsync(() async {
        for (final entry in {
          'Roboto': font,
          'Ahem': font,
          'MaterialIcons': const String.fromEnvironment('UI_CAPTURE_ICONS')
        }.entries) {
          if (entry.value.isEmpty) continue;
          await (FontLoader(entry.key)
                ..addFont(Future.value(ByteData.sublistView(
                    await File(entry.value).readAsBytes()))))
              .load();
        }
      });
    }
    final capture = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: capture,
        child: ChildApp(
            session: fixture.session(), nativeAvailable: true, tvMode: true)));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('我的规则'), findsOneWidget);
    expect(find.text('返回菜单'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.nearestScope?.debugLabel,
        'TV menu');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(FocusManager.instance.primaryFocus?.nearestScope?.debugLabel,
        'TV content');
    await press(tester, LogicalKeyboardKey.escape);
    expect(FocusManager.instance.primaryFocus?.nearestScope?.debugLabel,
        'TV menu');
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('设备帮助'), findsOneWidget);
    const path = String.fromEnvironment('TV_CAPTURE_PATH');
    if (path.isNotEmpty) {
      await tester.runAsync(() async {
        final picture = await (capture.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
        picture.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'remote can read a long non-interactive page and stay at its bounds',
      (tester) async {
    final host = GlobalKey<RemoteHostState>();
    await tester.pumpWidget(remoteHost(host));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(Focus.of(tester.element(find.text('向下翻页'))).hasFocus, true);
    await press(tester, LogicalKeyboardKey.escape);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(Focus.of(tester.element(find.text('向下翻页'))).hasFocus, true);
    await press(tester, LogicalKeyboardKey.select);
    expect(host.currentState!.scroll.offset, greaterThan(0));
    expect(find.text('向下翻页').hitTestable(), findsOneWidget);
    for (int n = 0; n < 12; n++) {
      await press(tester, LogicalKeyboardKey.pageDown);
    }
    expect(find.text('已到底部'), findsOneWidget);
    final bottom = host.currentState!.scroll.offset;
    await press(tester, LogicalKeyboardKey.pageDown);
    expect(host.currentState!.scroll.offset, bottom);
    for (int n = 0; n < 12; n++) {
      await press(tester, LogicalKeyboardKey.pageUp);
    }
    expect(host.currentState!.scroll.offset, 0);
    expect(find.text('已到顶部'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('platform back returns to the menu then permits leaving the app',
      (tester) async {
    int exits = 0;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits++;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(remoteHost(GlobalKey<RemoteHostState>()));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowRight);
    await tester.binding.handlePopRoute();
    expect(exits, 0);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.nearestScope?.debugLabel,
        'TV menu');
    await tester.binding.handlePopRoute();
    expect(exits, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a modal consumes back before the television menu',
      (tester) async {
    final host = GlobalKey<RemoteHostState>();
    await tester.pumpWidget(remoteHost(host, action: true));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.select);
    expect(find.text('确认窗口'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('确认窗口'), findsNothing);
    expect(Focus.of(tester.element(find.text('查看说明'))).hasFocus, true);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('editing keys are not repurposed as page or menu actions',
      (tester) async {
    final host = GlobalKey<RemoteHostState>();
    final input = FocusNode();
    addTearDown(input.dispose);
    await tester.pumpWidget(remoteHost(host, input: input));
    await tester.pumpAndSettle();
    input.requestFocus();
    await tester.pumpAndSettle();
    final offset = host.currentState!.scroll.offset;
    await press(tester, LogicalKeyboardKey.pageDown);
    expect(host.currentState!.scroll.offset, offset);
    await press(tester, LogicalKeyboardKey.escape);
    expect(FocusManager.instance.primaryFocus?.nearestScope?.debugLabel,
        'TV content');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'menu selection resets reading position without dispatching page actions',
      (tester) async {
    final host = GlobalKey<RemoteHostState>();
    await tester.pumpWidget(remoteHost(host));
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.pageDown);
    await press(tester, LogicalKeyboardKey.goBack);
    expect(FocusManager.instance.primaryFocus?.nearestScope?.debugLabel,
        'TV menu');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(Focus.of(tester.element(find.text('规则'))).hasFocus, true);
    await press(tester, LogicalKeyboardKey.enter);
    expect(host.currentState!.tab, 1);
    expect(host.currentState!.scroll.offset, 0);
    expect(FocusManager.instance.primaryFocus?.nearestScope?.debugLabel,
        'TV menu');
    await tester.pumpWidget(const SizedBox());
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('television controls fit at 960 by 540 and $scale text',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(remoteHost(GlobalKey<RemoteHostState>()));
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.pageDown);
      expect(find.text('返回菜单').hitTestable(), findsOneWidget);
      expect(find.text('向上翻页').hitTestable(), findsOneWidget);
      expect(find.text('向下翻页').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

Widget remoteHost(GlobalKey<RemoteHostState> key,
        {bool action = false, FocusNode? input}) =>
    MaterialApp(
        theme: childTheme(television: true),
        home:
            Scaffold(body: RemoteHost(key: key, action: action, input: input)));

class RemoteHost extends StatefulWidget {
  final bool action;
  final FocusNode? input;
  const RemoteHost({super.key, required this.action, this.input});
  @override
  State<RemoteHost> createState() => RemoteHostState();
}

class RemoteHostState extends State<RemoteHost> {
  int tab = 0;
  late ScrollController scroll;
  @override
  Widget build(BuildContext context) => TvWorkspace(
      selectedIndex: tab,
      onDestinationSelected: (n) => setState(() => tab = n),
      contentBuilder: (controller) {
        scroll = controller;
        return SingleChildScrollView(
            controller: controller,
            padding: const EdgeInsets.all(24),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('阅读规则 $tab',
                  style: Theme.of(context).textTheme.headlineMedium),
              if (widget.input != null) TextField(focusNode: widget.input),
              if (widget.action)
                FilledButton(
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (c) => AlertDialog(
                                title: const Text('确认窗口'),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(c),
                                      child: const Text('关闭'))
                                ])),
                    child: const Text('查看说明')),
              for (int i = 0; i < 30; i++)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text('第 ${i + 1} 项约定：长页面内容需要可以完整阅读。')),
            ]));
      });
}
