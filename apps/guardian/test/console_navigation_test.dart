import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/console_navigation.dart';
import 'package:guardian/ui/design.dart';

void main() {
  Widget navigation(
          {String section = 'overview',
          bool Function(String)? canOpen,
          ValueChanged<String>? onSelect,
          bool organization = false}) =>
      MaterialApp(
          theme: consoleTheme(),
          home: Scaffold(
              body: SizedBox(
                  width: 232,
                  height: 800,
                  child: ConsoleNavigation(
                      section: section,
                      canOpen: canOpen ?? (_) => true,
                      onSelect: onSelect ?? (_) {},
                      organization: organization))));

  test('every existing destination belongs to exactly one group', () {
    final grouped = navigationGroups.expand((g) => g.$3).toList();
    expect(grouped, hasLength(destinations.length));
    expect(grouped.toSet(), hasLength(destinations.length));
    expect(grouped.toSet(), destinations.map((d) => d.$1).toSet());
    expect(navigationLabel('subjects', organization: true), '学生档案');
    expect(navigationLabel('help-requests', organization: true), '学生求助');
  });

  testWidgets('common tasks are visible and workspace tools start collapsed',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: Scaffold(
            body: SizedBox(
                width: 232,
                height: 800,
                child: ConsoleNavigation(
                    section: 'overview',
                    canOpen: (_) => true,
                    onSelect: (_) {})))));
    expect(find.text('日常管理'), findsOneWidget);
    expect(find.text('设备管理'), findsOneWidget);
    expect(find.text('所有者交接'), findsNothing);
  });

  testWidgets(
      'search reveals allowed collapsed tools and opens the exact route',
      (tester) async {
    String? selected;
    await tester.pumpWidget(navigation(onSelect: (value) => selected = value));
    await tester.enterText(find.byType(TextField), '交接');
    await tester.pump();
    expect(find.text('所有者交接'), findsOneWidget);
    await tester.tap(find.text('所有者交接'));
    expect(selected, 'ownership');
    await tester.tap(find.byTooltip('清除功能搜索'));
    await tester.pump();
    expect(find.text('所有者交接'), findsNothing);
    expect(find.text('设备管理'), findsOneWidget);
  });

  testWidgets('search never exposes destinations outside current access',
      (tester) async {
    await tester.pumpWidget(
        navigation(canOpen: (id) => {'overview', 'devices'}.contains(id)));
    await tester.enterText(find.byType(TextField), '平台');
    await tester.pump();
    expect(find.text('平台管理'), findsNothing);
    expect(find.text('平台产品目录'), findsNothing);
    expect(find.text('没有匹配的可用功能，试试其他关键词。'), findsOneWidget);
    await tester.pumpWidget(navigation(canOpen: (id) => id == 'overview'));
    await tester.enterText(find.byType(TextField), '设备');
    await tester.pump();
    expect(find.text('设备管理'), findsNothing);
  });

  testWidgets(
      'current section opens its group and user can expand another group',
      (tester) async {
    await tester.pumpWidget(navigation(
        section: 'audit',
        canOpen: (id) => {'overview', 'audit', 'catalog'}.contains(id)));
    expect(find.text('审计日志'), findsOneWidget);
    expect(find.text('平台产品目录'), findsNothing);
    await tester.pumpWidget(navigation(
        section: 'catalog',
        canOpen: (id) => {'overview', 'audit', 'catalog'}.contains(id)));
    expect(
        tester
            .widget<ListTile>(find.ancestor(
                of: find.text('平台产品目录'), matching: find.byType(ListTile)))
            .selected,
        isTrue);
    await tester.tap(find.text('平台管理'));
    await tester.pump();
    expect(find.text('平台产品目录'), findsNothing);
    await tester.tap(find.text('平台管理'));
    await tester.pump();
    expect(find.text('平台产品目录'), findsOneWidget);
  });

  testWidgets('organization labels and narrow large text remain readable',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: consoleTheme(),
        home: MediaQuery(
            data: const MediaQueryData(
                size: Size(232, 800), textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
                body: SizedBox(
                    width: 232,
                    height: 800,
                    child: ConsoleNavigation(
                        section: 'overview',
                        organization: true,
                        canOpen: (id) => {
                              'overview',
                              'subjects',
                              'help-requests'
                            }.contains(id),
                        onSelect: (_) {}))))));
    expect(find.text('学生档案'), findsOneWidget);
    expect(find.text('学生求助'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
