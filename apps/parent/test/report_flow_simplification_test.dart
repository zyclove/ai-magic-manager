import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/ui/multi_device_reports.dart';
import 'package:parent/ui/usage_report_center.dart';
import 'package:usage_reporting/usage_reporting.dart';
import 'multi_device_reports_test.dart' show Session, device, response, id;

void main() {
  testWidgets('report center directly opens the shared device directory',
      (tester) async {
    var reads = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((_) async {
      reads++;
      return response({
        'items': [device(1)],
        'nextCursor': null
      });
    }));
    await tester.pumpWidget(
        MaterialApp(home: UsageReportCenter(session: Session(api))));
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.byType(ParentReportDevicePicker), findsOneWidget);
    expect(find.text('多选'), findsOneWidget);
    expect(find.text('选择多台设备查看报告'), findsNothing);
    expect(find.text('查看所选设备报告'), findsNothing);
    expect(tester.takeException(), isNull);
    api.close();
  });
  testWidgets(
      'one tap opens one original target; multi-select stays on the same directory',
      (tester) async {
    var reads = 0;
    final opened = <List<UsageReportTarget>>[];
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((_) async {
      reads++;
      return response({
        'items': [device(1), device(2)],
        'nextCursor': null
      });
    }));
    await tester.pumpWidget(MaterialApp(
        home: ParentReportDevicePicker(
            session: Session(api),
            browseFirst: true,
            onSelected: (targets) async {
              opened.add(targets);
            })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学习设备 2'));
    await tester.pumpAndSettle();
    expect(opened.single.single.deviceId, id(2));
    expect(opened.single.single.registrationId, id(102));
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择筛选结果'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看所选设备报告'));
    await tester.pumpAndSettle();
    expect(opened.last.map((t) => t.deviceId), [id(1), id(2)]);
    await tester.tap(find.text('取消多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    expect(find.text('已明确选择 0 / 20 台'), findsOneWidget);
    expect(reads, 1);
    expect(tester.takeException(), isNull);
    api.close();
  });
  testWidgets(
      'clearing a directory search restores items without a network request',
      (tester) async {
    var reads = 0;
    final api = ParentApi(() async => 'fixture',
        baseUrl: 'https://fixture.invalid/api/v1',
        client: MockClient((_) async {
      reads++;
      return response({
        'items': [device(1), device(2)],
        'nextCursor': null
      });
    }));
    await tester.pumpWidget(MaterialApp(
        home: ParentReportDevicePicker(
            session: Session(api), browseFirst: true)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '设备 2');
    await tester.pumpAndSettle();
    expect(find.text('学习设备 1'), findsNothing);
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    expect(find.text('学习设备 1'), findsOneWidget);
    expect(reads, 1);
    api.close();
  });
}
