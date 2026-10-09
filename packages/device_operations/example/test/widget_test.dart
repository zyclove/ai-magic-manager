import 'package:flutter_test/flutter_test.dart';
import 'package:device_operations_showcase/main.dart';

void main() {
  testWidgets('showcase discloses fixtures and renders actual exit component',
      (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('组件验收 · 设备退出'), findsOneWidget);
    expect(find.text('测试夹具，无真实设备操作'), findsOneWidget);
    expect(find.text('退出设备管理'), findsOneWidget);
  });
}
