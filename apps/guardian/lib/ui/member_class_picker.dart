import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show setEquals;

/// Local filtering only; the parent owns the selected IDs and their validity.
class MemberClassPicker extends StatefulWidget {
  final Map<String, String>? options;
  final Set<String> selectedIds;
  final bool enabled;
  final bool Function() canInteract;
  final void Function(String id, bool selected) onChanged;
  final String Function(String id) unavailableLabel;

  const MemberClassPicker(
      {super.key,
      required this.options,
      required this.selectedIds,
      required this.enabled,
      required this.canInteract,
      required this.onChanged,
      required this.unavailableLabel});

  @override
  State<MemberClassPicker> createState() => _MemberClassPickerState();
}

class _MemberClassPickerState extends State<MemberClassPicker> {
  final search = TextEditingController();
  final scroll = ScrollController(debugLabel: 'member-class-picker');
  String query = '';
  bool selectedOnly = false, active = true;
  int generation = 0, ownerGeneration = 0;

  bool ownerPermitted(int owner) => mounted && active && ownerGeneration == owner &&
      widget.enabled && widget.canInteract();
  bool permitted(int view) => generation == view && ownerPermitted(ownerGeneration);

  @override
  void didUpdateWidget(MemberClassPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.options, widget.options) ||
        !setEquals(oldWidget.selectedIds, widget.selectedIds) ||
        oldWidget.enabled != widget.enabled) {
      generation++;
      ownerGeneration++;
    }
  }

  @override
  void deactivate() {
    active = false;
    generation++;
    ownerGeneration++;
    super.deactivate();
  }

  @override
  void dispose() {
    active = false;
    generation++;
    ownerGeneration++;
    search.dispose();
    scroll.dispose();
    super.dispose();
  }

  void resetScroll() {
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  void updateQuery(int owner, String value) {
    if (!ownerPermitted(owner)) return;
    final next = value.trim().toLowerCase();
    setState(() { query = next; generation++; });
    resetScroll();
  }

  void clearSearch(int view) {
    if (!permitted(view)) return;
    search.clear();
    setState(() { query = ''; generation++; });
    resetScroll();
  }

  void filterSelected(int view, bool value) {
    if (!permitted(view) || selectedOnly == value) return;
    setState(() { selectedOnly = value; generation++; });
    resetScroll();
  }

  void change(int view, String id, bool? selected) {
    if (!permitted(view) || selected == null ||
        widget.selectedIds.contains(id) == selected) return;
    if (selected && (widget.options?.containsKey(id) != true ||
        widget.selectedIds.length >= 50)) return;
    widget.onChanged(id, selected);
  }

  @override
  Widget build(BuildContext context) {
    final view = generation;
    final owner = ownerGeneration;
    final canEdit = permitted(view);
    final ids = <String>{...?widget.options?.keys, ...widget.selectedIds};
    final visible = ids.where((id) =>
        (!selectedOnly || widget.selectedIds.contains(id)) &&
        (query.isEmpty ||
            '${widget.options?[id] ?? ''}\n$id'.toLowerCase().contains(query)))
        .toList(growable: false);
    final full = widget.selectedIds.length >= 50;
    final caption = Theme.of(context).textTheme.bodySmall;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
          key: const Key('member-class-search'),
          controller: search,
          enabled: canEdit,
          onChanged: (value) => updateQuery(owner, value),
          decoration: InputDecoration(
              isDense: true,
              hintText: '搜索已加载的班级名称或完整编号',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: search.text.isEmpty ? null : IconButton(
                  key: const Key('member-class-clear-search'),
                  tooltip: '清除班级搜索',
                  onPressed: canEdit ? () => clearSearch(view) : null,
                  icon: const Icon(Icons.close, size: 18)))),
      const SizedBox(height: 8),
      Wrap(spacing: 12, runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center, children: [
        FilterChip(
            key: const Key('member-class-selected-only'),
            label: const Text('仅看已选'),
            selected: selectedOnly,
            onSelected: canEdit ? (value) => filterSelected(view, value) : null),
        Text('匹配 ${visible.length} / ${ids.length} 个 · 已选 ${widget.selectedIds.length} / 50',
            style: caption),
      ]),
      if (full) Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('已达到 50 个班级上限，请先取消已选项后再选择。', style: caption)),
      if (visible.isNotEmpty) ...[
        const SizedBox(height: 8),
        ConstrainedBox(constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
                key: const Key('member-class-list'),
                controller: scroll,
                primary: false,
                shrinkWrap: visible.length <= 2,
                cacheExtent: 120,
                padding: EdgeInsets.zero,
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final id = visible[index];
                  final name = widget.options?[id];
                  final selected = widget.selectedIds.contains(id);
                  final available = widget.options?.containsKey(id) == true;
                  return CheckboxListTile(
                      key: ValueKey('member-class-$id'),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(name ?? widget.unavailableLabel(id)),
                      subtitle: name == null ? null : Text(id),
                      value: selected,
                      onChanged: canEdit && (selected || (available && !full))
                          ? (value) => change(view, id, value) : null);
                })),
      ] else if (query.isNotEmpty || (selectedOnly && ids.isNotEmpty)) Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(query.isNotEmpty ? '没有匹配的班级' : '当前没有已选班级', style: caption),
            if (query.isNotEmpty) TextButton.icon(
                key: const Key('member-class-clear-no-match'),
                onPressed: canEdit ? () => clearSearch(view) : null,
                icon: const Icon(Icons.clear, size: 16),
                label: const Text('清除搜索')),
          ])),
    ]);
  }
}
