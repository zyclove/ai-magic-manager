import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/api.dart';
import 'design.dart';

/// Class names enrich a member's granted IDs; the directory never grants access.
class MemberClassScope extends StatefulWidget {
  final Api api;
  final String path;
  final List<String> classIds;
  final Listenable accessChanges;
  final bool Function() isCurrent;
  const MemberClassScope({super.key, required this.api, required this.path,
    required this.classIds, required this.accessChanges, required this.isCurrent});

  @override
  State<MemberClassScope> createState() => _MemberClassScopeState();
}

class _MemberClassScopeState extends State<MemberClassScope> {
  late List<String> ids;
  Map<String, String> names = const {};
  Object? error;
  bool loading = false, active = true, lost = false;
  bool listening = false, rebuildPending = false;
  int generation = 0;

  void loseAccess() {
    if (lost) return;
    lost = true;
    generation++;
    names = const {};
    error = null;
    loading = false;
  }

  bool get current {
    if (!lost && !widget.isCurrent()) loseAccess();
    return mounted && active && !lost;
  }

  void accessChanged() {
    if (current || !mounted || !active || rebuildPending) return;
    // Permission changes can arrive while the owning page is being retired.
    rebuildPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      rebuildPending = false;
      if (mounted && active) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void initState() {
    super.initState();
    ids = List<String>.unmodifiable(widget.classIds);
    if (!current) return;
    widget.accessChanges.addListener(accessChanged);
    listening = true;
    if (ids.isNotEmpty) unawaited(load());
  }

  @override
  void didUpdateWidget(MemberClassScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = !identical(oldWidget.api, widget.api) ||
        oldWidget.path != widget.path || !listEquals(ids, widget.classIds);
    if (changed) loseAccess();
    if (!identical(oldWidget.accessChanges, widget.accessChanges)) {
      if (listening) oldWidget.accessChanges.removeListener(accessChanged);
      listening = false;
      if (current) {
        widget.accessChanges.addListener(accessChanged);
        listening = true;
      }
    }
  }

  @override
  void deactivate() {
    active = false;
    loseAccess();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    active = true;
  }

  @override
  void dispose() {
    active = false;
    loseAccess();
    if (listening) widget.accessChanges.removeListener(accessChanged);
    super.dispose();
  }

  Future<void> load() async {
    if (!current || loading || ids.isEmpty) return;
    final requested = ++generation;
    final allowed = ids.toSet();
    bool accepts() => current && generation == requested;
    setState(() {
      loading = true;
      names = const {};
      error = null;
    });
    try {
      final rows = await widget.api.all(widget.path, isCurrent: accepts);
      if (!accepts()) return;
      final result = <String, String>{};
      for (final row in rows) {
        final id = row['id'], name = row['name'];
        if (id is String && allowed.contains(id) &&
            name is String && name.trim().isNotEmpty) {
          result[id] = '$name${row['state'] == 'ARCHIVED' ? '（已归档）' : ''}';
        }
      }
      setState(() => names = Map<String, String>.unmodifiable(result));
    } catch (failure) {
      if (accepts()) setState(() => error = failure);
    } finally {
      if (accepts()) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!current) {
      return const Notice('工作空间或权限已变化，已隐藏班级名称与编号。', warning: true);
    }
    if (ids.isEmpty) return const SizedBox.shrink();
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('获授班级', style: TextStyle(fontSize: 12, color: muted)),
          const SizedBox(height: 4),
          for (final id in ids)
            Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: SelectableText(names[id] != null
                    ? '${names[id]} · $id'
                    : loading || error != null
                        ? '班级编号：$id'
                        : '名称未提供 · $id',
                    style: const TextStyle(fontSize: 14, height: 1.6))),
          if (loading) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Semantics(liveRegion: true,
                child: const Text('正在读取班级名称；成员资料已可查看。',
                    style: TextStyle(fontSize: 12, color: muted))),
          ] else if (error != null) ...[
            const Text('班级名称未读到，以上完整编号来自当前成员权限。',
                style: TextStyle(fontSize: 12, color: muted)),
            const SizedBox(height: 8),
            FailureView(error!, retry: () => unawaited(load())),
          ] else
            const Text('名称仅用于识别，访问范围以当前成员权限为准。',
                style: TextStyle(fontSize: 12, color: muted)),
        ]));
  }
}
