import 'package:flutter/material.dart';
import '../core/usage_reports.dart';
import 'design.dart';

class UsageReportDevicePicker extends StatefulWidget {
  final List<UsageReportTarget> targets;
  final Set<String> selected;
  final int limit;
  const UsageReportDevicePicker(
      {super.key,
      required this.targets,
      required this.selected,
      required this.limit});
  @override
  State<UsageReportDevicePicker> createState() =>
      _UsageReportDevicePickerState();
}

class _UsageReportDevicePickerState extends State<UsageReportDevicePicker> {
  late final Set<String> selected = widget.selected
      .intersection(widget.targets.map((t) => t.deviceId).toSet());
  String search = '';
  @override
  Widget build(BuildContext context) {
    final visible = widget.targets
        .where((t) => '${t.displayName} ${t.deviceId} ${t.subjectId}'
            .toLowerCase()
            .contains(search))
        .toList();
    final union = selected.union(visible.map((t) => t.deviceId).toSet());
    return AlertDialog(
        title: const Text('选择设备'),
        content: SizedBox(
            width: 480,
            height: (MediaQuery.sizeOf(context).height * .52).clamp(180, 400),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                  decoration: const InputDecoration(
                      labelText: '搜索设备或档案', prefixIcon: Icon(Icons.search)),
                  onChanged: (value) =>
                      setState(() => search = value.trim().toLowerCase())),
              const SizedBox(height: 8),
              Text('已选 ${selected.length} / ${widget.limit} 台'),
              Wrap(spacing: 8, children: [
                TextButton(
                    onPressed: union.length > widget.limit || visible.isEmpty
                        ? null
                        : () => setState(() => selected.addAll(union)),
                    child: const Text('选择筛选结果')),
                TextButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () => setState(selected.clear),
                    child: const Text('清空选择')),
              ]),
              if (union.length > widget.limit)
                Text('筛选结果超出 ${widget.limit} 台上限，请缩小范围或逐项选择。',
                    style: const TextStyle(color: muted, fontSize: 12)),
              Expanded(
                  child: visible.isEmpty
                      ? const Center(child: Text('没有匹配的设备'))
                      : ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (context, index) {
                            final target = visible[index],
                                checked =
                                    selected.contains(visible[index].deviceId);
                            return CheckboxListTile(
                                value: checked,
                                title: Text(target.displayName),
                                subtitle: Text(
                                    '设备 ${target.deviceId.substring(0, 8)} · 档案 ${target.subjectId.substring(0, 8)}'),
                                onChanged: !checked &&
                                        selected.length >= widget.limit
                                    ? null
                                    : (value) => setState(() {
                                          if (value == true) {
                                            selected.add(target.deviceId);
                                          } else {
                                            selected.remove(target.deviceId);
                                          }
                                        }));
                          })),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
              onPressed: selected.isEmpty || selected.length > widget.limit
                  ? null
                  : () => Navigator.pop(context, Set<String>.of(selected)),
              child: const Text('确认选择')),
        ]);
  }
}
