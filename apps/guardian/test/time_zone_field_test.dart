import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/time_zone_field.dart';
import 'package:timezone/timezone.dart' as time_zones;

Widget _host(Widget child) => MaterialApp(
    home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)));

void main() {
  testWidgets('city lookup writes an IANA name and keeps unknown manual values',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final form = GlobalKey<FormState>();
    await tester.pumpWidget(_host(Form(
        key: form,
        child: TimeZoneField(
            controller: controller,
            enabled: true,
            validator: (value) => value == null || value.isEmpty ? '请输入时区' : null))));
    final field = find.byType(TextFormField);
    await tester.tap(field);
    await tester.enterText(field, '北京');
    await tester.pumpAndSettle();
    final shanghai = find.byKey(const ValueKey('time-zone-option-Asia/Shanghai'));
    expect(shanghai, findsOneWidget);
    expect(find.text('北京 / 上海 / 广州 / 深圳'), findsOneWidget);
    expect(controller.text, '北京', reason: 'Suggestions do not rewrite input.');
    final raw = tester.widget<RawAutocomplete<String>>(find.byType(RawAutocomplete<String>));
    final common = await raw.optionsBuilder(TextEditingValue.empty);
    expect(common, hasLength(12));
    expect(common.first, 'Asia/Shanghai');
    final matching = await raw.optionsBuilder(const TextEditingValue(text: 'a'));
    expect(matching.length, lessThanOrEqualTo(12));
    await tester.tap(shanghai);
    await tester.pumpAndSettle();
    expect(controller.text, 'Asia/Shanghai');
    expect(controller.selection.baseOffset, 'Asia/Shanghai'.length);
    await tester.enterText(field, '');
    await tester.pumpAndSettle();
    for (var index = 0; index < 9; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final laterZone = common.elementAt(9);
    final laterOption = find.byKey(ValueKey('time-zone-option-$laterZone'));
    expect(tester.widget<ListTile>(laterOption).selected, isTrue);
    final optionBounds = tester.getRect(laterOption);
    final popupBounds = tester.getRect(
        find.byKey(const ValueKey('time-zone-options-scroll')));
    expect(optionBounds.top, greaterThanOrEqualTo(popupBounds.top - 1));
    expect(optionBounds.bottom, lessThanOrEqualTo(popupBounds.bottom + 1));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(controller.text, laterZone);
    final local = time_zones.local;
    final locations = time_zones.timeZoneDatabase.locations.length;
    await tester.enterText(field, 'Server/Configured_Zone');
    await tester.pumpAndSettle();
    expect(form.currentState!.validate(), isTrue);
    expect(controller.text, 'Server/Configured_Zone');
    expect(identical(time_zones.local, local), isTrue);
    expect(time_zones.timeZoneDatabase.locations.length, locations);
    await tester.pumpWidget(_host(const Text('表单已关闭')));
  });

  testWidgets('frozen or removed fields reject retained option and submit callbacks',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var enabled = true, allowed = true;
    Widget host() => _host(TimeZoneField(
        controller: controller, enabled: enabled, canInteract: () => allowed));
    await tester.pumpWidget(host());
    final field = find.byType(TextFormField);
    await tester.enterText(field, '北京');
    await tester.pumpAndSettle();
    final heldSelect = tester.widget<ListTile>(find.byKey(
        const ValueKey('time-zone-option-Asia/Shanghai'))).onTap!;
    final heldSubmit = tester.widget<TextFormField>(field).onFieldSubmitted!;
    allowed = false;
    heldSelect();
    heldSubmit('北京');
    expect(controller.text, '北京', reason: 'The host freezes before rebuilding.');
    enabled = false;
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNothing);
    heldSelect();
    heldSubmit('北京');
    expect(controller.text, '北京');
    allowed = enabled = true;
    await tester.pumpWidget(host());
    await tester.enterText(field, '东京');
    await tester.pumpAndSettle();
    heldSelect();
    heldSubmit('北京');
    expect(controller.text, '东京', reason: 'Re-enabling does not revive old callbacks.');
    final lateSelect = tester.widget<ListTile>(find.byKey(
        const ValueKey('time-zone-option-Asia/Tokyo'))).onTap!;
    final lateSubmit = tester.widget<TextFormField>(field).onFieldSubmitted!;
    await tester.pumpWidget(_host(const Text('另一个页面')));
    lateSelect();
    lateSubmit('东京');
    expect(controller.text, '东京');
    expect(find.text('另一个页面'), findsOneWidget);
    controller.text = '外部仍持有控制器';
    expect(controller.text, '外部仍持有控制器');
    expect(tester.takeException(), isNull);
  });
}
