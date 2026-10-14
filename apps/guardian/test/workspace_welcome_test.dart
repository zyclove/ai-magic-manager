import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/workspace_welcome.dart';

void main() {
  testWidgets('create and invitation remain separate intentional actions',
      (tester) async {
    var creates = 0, joins = 0;
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: WorkspaceWelcome(
                onCreate: () => creates++, onJoin: () => joins++))));
    await tester.tap(find.text('创建工作空间'));
    expect(creates, 1);
    expect(joins, 0);
    await tester.tap(find.text('使用邀请加入'));
    expect(joins, 1);
    expect(find.text('平台工具'), findsNothing);
  });
  testWidgets('users without creation access only see invitation entry',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: WorkspaceWelcome(onJoin: () {}))));
    expect(find.text('加入你的工作空间'), findsOneWidget);
    expect(find.text('创建工作空间'), findsNothing);
    expect(find.text('使用邀请加入'), findsOneWidget);
  });
  testWidgets(
      'mobile large text keeps actions usable and platform tools secondary',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
                body: SingleChildScrollView(
                    padding: const EdgeInsets.all(18),
                    child: WorkspaceWelcome(
                        onCreate: () {},
                        onJoin: () {},
                        platformTools: [
                          TextButton(
                              onPressed: () {}, child: const Text('产品目录'))
                        ]))))));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('使用邀请加入'));
    expect(find.text('使用邀请加入').hitTestable(), findsOneWidget);
    expect(find.text('平台工具'), findsOneWidget);
  });
}
