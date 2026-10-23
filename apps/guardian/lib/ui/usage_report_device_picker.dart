import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../core/labels.dart';
import '../core/usage_reports.dart';
import 'design.dart';
import 'owned_dialog_route.dart';

class UsageReportDevicePicker extends StatefulWidget {
  final List<UsageReportTarget> targets;
  final Set<String> selected;
  final int limit;
  final Listenable? accessChanges;
  final bool Function()? hasAccess;
  const UsageReportDevicePicker(
      {super.key,
      required this.targets,
      required this.selected,
      required this.limit,
      this.accessChanges,
      this.hasAccess});
  @override
  State<UsageReportDevicePicker> createState() =>
      _UsageReportDevicePickerState();
}

class _UsageReportDevicePickerState extends State<UsageReportDevicePicker> {
  late final int initialLimit;
  late final Map<String, (String, String, String)> initialTargets;
  late final Set<String> selected = widget.selected
      .intersection(widget.targets.map((t) => t.deviceId).toSet());
  final searchController = TextEditingController();
  final searchFocus = FocusNode(debugLabel: 'usage-report-device-search');
  String search = '';
  bool onlySelected = false;
  bool invalidated = false, closing = false, rebuildPending = false;
  String invalidationMessage = '工作空间或权限已变化，请关闭窗口后重新选择设备。';

  void invalidate([String? message]) {
    if (invalidated) return;
    invalidated = true;
    if (message != null) invalidationMessage = message;
    selected.clear();
    if (!mounted || closing) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (rebuildPending) return;
      rebuildPending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        rebuildPending = false;
        if (mounted && !closing) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void observeAccess() {
    if (widget.hasAccess?.call() == false) invalidate();
    if (invalidated) return;
    // Pin values rather than List identity: callers can reuse or reorder a list.
    if (widget.limit != initialLimit ||
        widget.targets.length != initialTargets.length ||
        widget.targets.map((t) => t.deviceId).toSet().length !=
            initialTargets.length ||
        widget.targets.any((target) =>
            initialTargets[target.deviceId] !=
            (target.registrationId, target.subjectId, target.platform))) {
      invalidate('可选设备或选择上限已变化，请关闭窗口后重新选择。');
    }
  }

  bool get current {
    observeAccess();
    return mounted && !invalidated && !closing;
  }

  bool get editable {
    if (!current) return false;
    final route = ModalRoute.of(context);
    return route?.isActive == true &&
        route?.isCurrent == true &&
        (route is! OwnedDialogRoute<dynamic> || route.available);
  }

  @override
  void initState() {
    super.initState();
    initialLimit = widget.limit;
    initialTargets = Map.unmodifiable({
      for (final target in widget.targets)
        target.deviceId:
            (target.registrationId, target.subjectId, target.platform),
    });
    if (initialTargets.length != widget.targets.length) {
      invalidate('可选设备列表存在重复记录，请关闭窗口后刷新设备列表。');
    }
    observeAccess();
    widget.accessChanges?.addListener(changed);
  }

  @override
  void didUpdateWidget(covariant UsageReportDevicePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Replacing a listener must not revive a selection from an expired owner.
    if (oldWidget.hasAccess?.call() == false) invalidate();
    if (!identical(oldWidget.accessChanges, widget.accessChanges)) {
      oldWidget.accessChanges?.removeListener(changed);
      widget.accessChanges?.addListener(changed);
    }
    observeAccess();
  }

  void changed() {
    if (!mounted || closing) return;
    observeAccess();
  }

  @override
  void dispose() {
    widget.accessChanges?.removeListener(changed);
    searchController.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void finish([Set<String>? value]) {
    if (!mounted || closing) return;
    final route = ModalRoute.of(context);
    if (value != null &&
        (!editable ||
            value.isEmpty ||
            value.length > widget.limit ||
            !widget.targets.map((t) => t.deviceId).toSet().containsAll(value))) {
      return;
    }
    if (route is OwnedDialogRoute<Set<String>>) {
      if (!route.available) return;
      closing = true;
      route.finish(value);
    } else if (route?.isActive == true && route?.isCurrent == true) {
      closing = true;
      route!.navigator!.pop(value);
    }
  }

  void clearSearch() {
    if (!editable) return;
    searchController.clear();
    setState(() => search = '');
    searchFocus.requestFocus();
  }

  List<UsageReportTarget> get visibleTargets => widget.targets
      .where((t) =>
          (!onlySelected || selected.contains(t.deviceId)) &&
          '${t.displayName} ${t.deviceId} ${t.subjectId}'
              .toLowerCase()
              .contains(search))
      .toList();

  void selectVisible() {
    if (!editable) return;
    // Recheck at invocation: a callback can outlive the selection it displayed.
    final next = selected.union(visibleTargets.map((t) => t.deviceId).toSet());
    if (next.length > widget.limit) return;
    setState(() => selected.addAll(next));
  }

  void toggleDevice(String id, bool checked) {
    if (!editable || !widget.targets.any((t) => t.deviceId == id)) return;
    if (checked && !selected.contains(id) && selected.length >= widget.limit) {
      return;
    }
    setState(() {
      if (checked) {
        selected.add(id);
      } else {
        selected.remove(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final allowed = current;
    final visible = allowed ? visibleTargets : <UsageReportTarget>[];
    final union = selected.union(visible.map((t) => t.deviceId).toSet());
    return AlertDialog(
        title: const Text('选择设备'),
        scrollable: true,
        content: SizedBox(
            width: 480,
            child: allowed
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                          controller: searchController,
                          focusNode: searchFocus,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                              labelText: '搜索设备或档案',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: searchController.text.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: '清除设备搜索',
                                      onPressed: clearSearch,
                                      icon: const Icon(Icons.close))),
                          onChanged: (value) {
                            if (editable) {
                              setState(() => search = value.trim().toLowerCase());
                            }
                          }),
                      const SizedBox(height: 12),
                      Semantics(
                          liveRegion: true,
                          child: Text('已选 ${selected.length} / ${widget.limit} 台')),
                      const SizedBox(height: 8),
                      FilterChip(
                          label: const Text('仅看已选'),
                          selected: onlySelected,
                          onSelected: (value) {
                            if (editable) setState(() => onlySelected = value);
                          }),
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        TextButton(
                            onPressed: union.length > widget.limit ||
                                    union.length == selected.length
                                ? null
                                : selectVisible,
                            child: const Text('选择筛选结果')),
                        TextButton(
                            onPressed: selected.isEmpty
                                ? null
                                : () {
                                    if (editable) setState(selected.clear);
                                  },
                            child: const Text('清空选择')),
                      ]),
                      if (union.length > widget.limit)
                        Text('筛选结果超出 ${widget.limit} 台上限，请缩小范围或逐项选择。',
                            style: const TextStyle(color: muted, fontSize: 12)),
                      Text('显示 ${visible.length} / ${widget.targets.length} 台设备',
                          style: const TextStyle(color: muted, fontSize: 12)),
                      const SizedBox(height: 8),
                      SizedBox(
                          height: (MediaQuery.sizeOf(context).height * .36)
                              .clamp(100.0, 320.0)
                              .toDouble(),
                          child: visible.isEmpty
                              ? Center(
                                  child: Text(widget.targets.isEmpty
                                      ? '暂无可选择的设备，请关闭窗口后刷新设备列表。'
                                      : onlySelected && selected.isEmpty
                                          ? '还没有选择设备，关闭“仅看已选”后继续选择。'
                                          : '没有匹配的设备，请调整或清除搜索。'))
                              : ListView.builder(
                                  itemCount: visible.length,
                                  itemBuilder: (context, index) {
                                    final target = visible[index];
                                    final checked = selected.contains(target.deviceId);
                                    return CheckboxListTile(
                                        key: ValueKey(target.deviceId),
                                        value: checked,
                                        title: Text(target.displayName),
                                        subtitle: Text(
                                            '设备 ${shortId(target.deviceId)} · 档案 ${shortId(target.subjectId)}'),
                                        onChanged: !checked &&
                                                selected.length >= widget.limit
                                            ? null
                                            : (value) => toggleDevice(
                                                target.deviceId, value == true));
                                  })),
                    ])
                : Notice(invalidationMessage, warning: true)),
        actions: [
          TextButton(
              onPressed: finish, child: Text(allowed ? '取消' : '关闭')),
          if (allowed)
            FilledButton(
                onPressed: selected.isEmpty || selected.length > widget.limit
                    ? null
                    : () => finish(Set<String>.of(selected)),
                child: const Text('确认选择')),
        ]);
  }
}
