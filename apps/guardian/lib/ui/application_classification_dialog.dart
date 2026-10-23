import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/application_classification.dart';
import '../core/labels.dart';
import 'design.dart';
import 'owned_dialog_route.dart';

class ApplicationClassificationDialog extends StatefulWidget {
  final ApplicationClassificationRepository repository;
  final String applicationName;
  final bool canEdit;
  final Listenable? accessChanges;
  const ApplicationClassificationDialog(
      {super.key,
      required this.repository,
      required this.applicationName,
      required this.canEdit,
      this.accessChanges});
  @override
  State<ApplicationClassificationDialog> createState() =>
      _ApplicationClassificationDialogState();
}

class _ApplicationClassificationDialogState
    extends State<ApplicationClassificationDialog> {
  ApplicationClassification? before;
  String? selected, pending, key;
  Object? error;
  bool loading = true, busy = false, invalidated = false;
  int generation = 0;
  bool get terminal =>
      error is ApiFailure &&
      const {401, 403, 404, 409, 412, 428}
          .contains((error as ApiFailure).status);
  bool get locked => busy || pending != null || terminal;
  @override
  void initState() {
    super.initState();
    widget.accessChanges?.addListener(accessChanged);
    load();
  }

  @override
  void didUpdateWidget(covariant ApplicationClassificationDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.accessChanges, widget.accessChanges)) {
      oldWidget.accessChanges?.removeListener(accessChanged);
      widget.accessChanges?.addListener(accessChanged);
    }
    if (!identical(oldWidget.repository, widget.repository)) {
      invalidate();
    } else {
      accessChanged();
    }
  }

  bool current(ApplicationClassificationRepository repository) =>
      mounted && !invalidated && identical(widget.repository, repository) &&
      repository.current();

  @override
  void dispose() {
    generation++;
    widget.accessChanges?.removeListener(accessChanged);
    super.dispose();
  }

  void close({bool saved = false}) {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route is OwnedDialogRoute<bool>) {
      route.finish(saved);
    } else if (route is OwnedDialogRoute<void>) {
      route.finish();
    } else if (route?.isActive == true) {
      if (route!.isCurrent) {
        route.navigator!.pop();
      } else {
        route.navigator!.removeRoute(route);
      }
    }
  }

  void accessChanged() {
    if (!mounted || invalidated || widget.repository.current()) return;
    invalidate();
  }

  void invalidate() {
    if (!mounted || invalidated) return;
    setState(() {
      invalidated = true;
      generation++;
      before = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => close());
  }

  Future<void> load() async {
    final repository = widget.repository;
    if (!current(repository)) {
      accessChanged();
      return;
    }
    final revision = ++generation;
    setState(() {
      loading = true;
      error = null;
      before = null;
      pending = null;
      key = null;
    });
    try {
      final result = await repository.load();
      if (current(repository) && revision == generation) {
        setState(() {
          before = result;
          selected = result.category;
        });
      }
    } catch (e) {
      if (current(repository) && revision == generation) setState(() => error = e);
    } finally {
      if (current(repository) && revision == generation) setState(() => loading = false);
    }
  }

  Future<void> save() async {
    final repository = widget.repository;
    if (!current(repository)) {
      accessChanged();
      return;
    }
    if (busy ||
        terminal ||
        !widget.canEdit ||
        before == null ||
        selected == null) return;
    final revision = generation;
    pending ??= selected;
    key ??= requestId();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await repository.save(before!, pending!, key!);
      if (current(repository) && revision == generation) close(saved: true);
    } catch (e) {
      if (current(repository) && revision == generation) {
        setState(() {
          error = e;
          if (e is ApiFailure && e.status != 0 && e.status < 500) {
            pending = null;
            key = null;
          }
        });
      }
    } finally {
      if (current(repository) && revision == generation) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = widget.repository;
    if (!current(repository)) return const SizedBox.shrink();
    final identity = repository.identity;
    return PopScope(
        canPop: !busy,
        child: AlertDialog(
          title: const Text('应用分类'),
          content: SizedBox(
              width: 540,
              child: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(widget.applicationName,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(identity.packageName),
                    Text(
                        '${label(identity.platform)} · ${label(identity.profile)}'),
                    const SizedBox(height: 16),
                    const Notice(
                        '分类由本工作空间管理员声明，用于报表整理。相同平台、资料与包名共享分类；不同签名的目录项也会共享，不代表签名验证或安全评级。'),
                    const SizedBox(height: 16),
                    if (loading)
                      const LinearProgressIndicator()
                    else if (before != null) ...[
                      if (widget.canEdit)
                        DropdownButtonFormField<String>(
                            key: const Key('classification-category'),
                            value: selected,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: '应用类别'),
                            items: applicationCategories.entries
                                .map((e) => DropdownMenuItem(
                                    value: e.key, child: Text(e.value)))
                                .toList(),
                            onChanged: locked
                                ? null
                                : (value) {
                                    if (!current(repository) || locked) return;
                                    setState(() => selected = value);
                                  })
                      else
                        Text(applicationCategories[before!.category]!,
                            style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 12),
                      Text(before!.source == 'NONE'
                          ? '尚未设置分类'
                          : '来源：管理员声明 · 版本 ${before!.version}'),
                      if (before!.updatedAt != null)
                        Text('更新于 ${dateLabel(before!.updatedAt)}'),
                      const SizedBox(height: 12),
                      const Text('这是当前分类，应用于历史报表时不代表当时的分类。修改分类不会改变设备策略或使用额度。'),
                    ],
                    if (pending != null && !busy) ...[
                      const SizedBox(height: 16),
                      const Notice('上次修改结果尚未确认。重试会发送相同修改；关闭后请先重新查看最新分类。',
                          warning: true)
                    ],
                    if (error != null) ...[
                      const SizedBox(height: 16),
                      FailureView(error!, retry: before == null ? load : null)
                    ],
                  ]))),
          actions: [
            TextButton(
                onPressed: busy ? null : close,
                child: const Text('关闭')),
            if (before != null && terminal)
              TextButton(
                  onPressed: busy ? null : load, child: const Text('重新加载分类')),
            if (widget.canEdit && before != null && !terminal)
              FilledButton(
                  onPressed:
                      busy || (pending == null && selected == before!.category)
                          ? null
                          : save,
                  child: Text(busy
                      ? '正在保存…'
                      : pending != null
                          ? '重试相同修改'
                          : '保存分类')),
          ],
        ));
  }
}
