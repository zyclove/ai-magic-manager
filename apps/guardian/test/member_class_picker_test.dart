import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/ui/design.dart';
import 'package:guardian/ui/member_class_picker.dart';

const _missing = 'missing-class-0000-0000-full-reference';
String _id(int index) => 'class-${index.toString().padLeft(4, '0')}';

class _Fixture {
  Map<String, String>? options;
  Set<String> selected;
  bool enabled = true, allowed = true;
  final changes = <(String, bool)>[];
  late StateSetter rebuild;
  _Fixture(this.options, this.selected);

  Widget host() => MaterialApp(theme: consoleTheme(), home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return MemberClassPicker(
                options: options,
                selectedIds: Set<String>.unmodifiable(selected),
                enabled: enabled,
                canInteract: () => allowed,
                unavailableLabel: (id) => '不可用班级：$id',
                onChanged: (id, checked) {
                  changes.add((id, checked));
                  setState(() {
                    if (checked) { selected.add(id); } else { selected.remove(id); }
                  });
                });
          }))));
}

Finder get _search => find.byKey(const Key('member-class-search'));
Finder get _selectedOnly => find.byKey(const Key('member-class-selected-only'));
Finder _row(String id) => find.byKey(ValueKey('member-class-$id'));

Future<void> _query(WidgetTester tester, String value) async {
  await tester.enterText(_search, value);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('large class lists search lazily and retain selection across local views',
      (tester) async {
    final options = {for (var i = 0; i < 500; i++) _id(i): '七年级第${i}班'};
    final fixture = _Fixture(options, {_missing});
    await tester.pumpWidget(fixture.host());
    await tester.pumpAndSettle();
    final built = find.byType(CheckboxListTile).evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(40), reason: 'The 500-row catalog must remain lazy.');
    expect(tester.getSize(find.byKey(const Key('member-class-list'))).height,
        lessThanOrEqualTo(240));
    await _query(tester, '七年级第499班');
    expect(find.byType(CheckboxListTile), findsOneWidget);
    await tester.tap(_row(_id(499)));
    await tester.pumpAndSettle();
    expect(fixture.selected, {_missing, _id(499)});
    await _query(tester, _id(499));
    expect(tester.widget<CheckboxListTile>(_row(_id(499))).value, isTrue);
    await tester.tap(find.byKey(const Key('member-class-clear-search')));
    await tester.pumpAndSettle();
    await tester.tap(_selectedOnly);
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
    expect(find.text('不可用班级：$_missing'), findsOneWidget);
    await tester.tap(_row(_missing));
    await tester.pumpAndSettle();
    expect(fixture.selected, {_id(499)});
    expect(fixture.changes, [(_id(499), true), (_missing, false)]);
    fixture.rebuild(() => fixture.options = {...options}..remove(_id(499)));
    await tester.pumpAndSettle();
    expect(fixture.selected, {_id(499)}, reason: 'Missing directory IDs stay selected.');
    expect(find.text('不可用班级：${_id(499)}'), findsOneWidget);
    await _query(tester, '0499');
    expect(find.byType(CheckboxListTile), findsOneWidget);
    expect(fixture.changes, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('frozen and stale views cannot mutate filters or selections and full lists permit removal',
      (tester) async {
    final fixture = _Fixture({'a': '甲班', 'b': '乙班'}, {'a'});
    await tester.pumpWidget(fixture.host());
    await tester.pumpAndSettle();
    final input = tester.widget<TextField>(_search);
    final inputChanged = input.onChanged!;
    final earlyRow = tester.widget<CheckboxListTile>(_row('b')).onChanged!;
    // Text input updates its controller before onChanged; two events can arrive
    // before the parent has rendered a new callback.
    input.controller!.text = '甲';
    inputChanged('甲');
    input.controller!.text = '乙';
    inputChanged('乙');
    await tester.pumpAndSettle();
    expect(input.controller!.text, '乙');
    expect(_row('b'), findsOneWidget);
    expect(_row('a'), findsNothing);
    earlyRow(true);
    expect(fixture.changes, isEmpty, reason: 'The first query retires old row callbacks.');
    await _query(tester, '班');
    final heldRow = tester.widget<CheckboxListTile>(_row('b')).onChanged!;
    final heldSearch = tester.widget<TextField>(_search).onChanged!;
    final heldFilter = tester.widget<FilterChip>(_selectedOnly).onSelected!;
    final heldClear = tester.widget<IconButton>(find.byKey(
        const Key('member-class-clear-search'))).onPressed!;
    fixture.allowed = false;
    heldRow(true);
    heldSearch('不应改变筛选');
    heldFilter(true);
    heldClear();
    await tester.pump();
    expect(fixture.selected, {'a'});
    expect(fixture.changes, isEmpty);
    expect(tester.widget<TextField>(_search).controller!.text, '班');
    expect(tester.widget<FilterChip>(_selectedOnly).selected, isFalse);

    fixture.allowed = true;
    await _query(tester, '甲');
    heldRow(true);
    heldFilter(true);
    heldClear();
    await tester.pump();
    expect(fixture.changes, isEmpty);
    expect(tester.widget<TextField>(_search).controller!.text, '甲');
    final oldOption = tester.widget<CheckboxListTile>(_row('a')).onChanged!;
    fixture.rebuild(() => fixture.options = {'a': '甲班更新', 'b': '乙班', 'c': '丙班'});
    await tester.pumpAndSettle();
    oldOption(false);
    await tester.pump();
    expect(fixture.selected, {'a'});
    expect(fixture.changes, isEmpty);
    expect(tester.widget<TextField>(_search).controller!.text, '甲');

    fixture.rebuild(() {
      fixture.options = {for (var i = 0; i < 60; i++) _id(i): '班级$i'};
      fixture.selected = {for (var i = 0; i < 50; i++) _id(i)};
    });
    await tester.pumpAndSettle();
    await _query(tester, _id(50));
    expect(tester.widget<CheckboxListTile>(_row(_id(50))).onChanged, isNull);
    expect(find.textContaining('50 个班级上限'), findsOneWidget);
    await _query(tester, _id(0));
    expect(tester.widget<CheckboxListTile>(_row(_id(0))).onChanged, isNotNull);
    await tester.tap(_row(_id(0)));
    await tester.pumpAndSettle();
    expect(fixture.selected, hasLength(49));
    final lateRow = tester.widget<CheckboxListTile>(_row(_id(0))).onChanged!;
    final lateSearch = tester.widget<TextField>(_search).onChanged!;
    final lateFilter = tester.widget<FilterChip>(_selectedOnly).onSelected!;
    final lateClear = tester.widget<IconButton>(find.byKey(
        const Key('member-class-clear-search'))).onPressed!;
    final count = fixture.changes.length;
    fixture.rebuild(() => fixture.enabled = false);
    await tester.pumpAndSettle();
    lateRow(true);
    lateSearch('被禁用后的旧搜索');
    lateFilter(true);
    lateClear();
    await tester.pump();
    expect(fixture.selected, hasLength(49));
    expect(fixture.changes, hasLength(count));
    expect(tester.widget<TextField>(_search).controller!.text, _id(0));
    await tester.pumpWidget(const SizedBox.shrink());
    lateRow(true);
    lateSearch('卸载后的旧搜索');
    lateFilter(true);
    lateClear();
    expect(fixture.selected, hasLength(49));
    expect(fixture.changes, hasLength(count));
    expect(tester.takeException(), isNull);
  });
}
