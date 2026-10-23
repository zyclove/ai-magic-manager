import 'package:flutter/material.dart';
import '../core/api.dart';
import 'design.dart';

class ColumnSpec {
  final String title;
  final Widget Function(Json) build;
  const ColumnSpec(this.title, this.build);
}

class ResourcePage extends StatefulWidget {
  final String title, subtitle, emptyTitle, emptyDescription, path;
  final Api api;
  final List<ColumnSpec> columns;
  final Future<void> Function(Json)? onOpen;
  final Future<void> Function()? create;
  final String createLabel;
  final List<Widget> toolbar;
  final String? notice;
  final VoidCallback? reauth;
  /// Captures this list's owner; its page key must change with the owner scope.
  final bool Function()? isCurrent;
  /// Gates new user events without invalidating accepted or in-flight reads.
  final bool Function()? canInteract;
  const ResourcePage(
      {super.key,
      required this.title,
      required this.subtitle,
      required this.path,
      required this.api,
      required this.columns,
      this.onOpen,
      this.create,
      this.createLabel = '新建',
      this.emptyTitle = '暂无记录',
      this.emptyDescription = '创建第一条记录，开始管理。',
      this.toolbar = const [],
      this.notice,
      this.reauth,
      this.isCurrent,
      this.canInteract});
  @override
  State<ResourcePage> createState() => ResourcePageState();
}

class ResourcePageState extends State<ResourcePage> {
  final search = TextEditingController();
  final searchFocus = FocusNode(debugLabel: 'resource-search');
  List<Json> rows = [];
  String? cursor;
  bool cursorExpired = false;
  String query = '';
  bool loading = true;
  bool more = false;
  bool acting = false;
  Object? error;
  Object? appendError;
  Object? actionError;
  int generation = 0;
  int resourceGeneration = 0;

  bool get _currentOwner => mounted && widget.isCurrent?.call() != false;
  bool get _canInteract => _currentOwner && widget.canInteract?.call() != false;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(ResourcePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path || oldWidget.api != widget.api) {
      resourceGeneration++;
      rows = [];
      cursor = null;
      cursorExpired = false;
      query = '';
      search.clear();
      acting = false;
      actionError = null;
      load();
    }
  }

  @override
  void dispose() {
    searchFocus.dispose();
    search.dispose();
    super.dispose();
  }

  void clearSearch() {
    if (!_canInteract) return;
    search.clear();
    setState(() => query = '');
    searchFocus.requestFocus();
  }

  Future<void> load({bool append = false}) async {
    if (!_currentOwner) return;
    if (append && (loading || more || acting || cursor == null)) return;
    final epoch = ++generation;
    final api = widget.api;
    final path = widget.path;
    final scope = resourceGeneration;
    final permitted = widget.isCurrent;
    bool current() =>
        mounted && resourceGeneration == scope && permitted?.call() != false;
    final requestCursor = append ? cursor : null;
    setState(() {
      if (append) {
        more = true;
        appendError = null;
      } else {
        loading = true;
        more = false;
        error = null;
        appendError = null;
        actionError = null;
      }
    });
    try {
      final result =
          await api.page(path, cursor: requestCursor, isCurrent: current);
      if (current() && generation == epoch) {
        setState(() {
          rows = append ? [...rows, ...result.items] : result.items;
          cursor = result.nextCursor;
          cursorExpired = false;
        });
      }
    } catch (e) {
      if (mounted && generation == epoch) {
        setState(() {
          if (e is ApiFailure &&
              (e.status == 401 ||
                  e.status == 403 ||
                  e.code == 'WORKSPACE_CHANGED')) {
            rows = [];
            cursor = null;
            cursorExpired = false;
            appendError = null;
            error = e;
          } else if (append) {
            appendError = e;
            if (e is ApiFailure && e.code == 'INVALID_CURSOR') {
              cursor = null;
              cursorExpired = true;
            }
          } else {
            error = e;
          }
        });
      }
    } finally {
      if (mounted && generation == epoch) {
        setState(() {
          loading = false;
          more = false;
        });
      }
    }
  }

  Future<void> action(Future<void> Function() callback) async {
    if (!_canInteract || acting || loading) return;
    final scope = resourceGeneration;
    final permitted = widget.isCurrent;
    bool current() =>
        mounted && resourceGeneration == scope && permitted?.call() != false;
    setState(() {
      acting = true;
      actionError = null;
    });
    try {
      await callback();
      if (current()) await load();
    } catch (e) {
      if (current()) {
        setState(() => actionError = e);
      }
    } finally {
      if (current()) {
        setState(() => acting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isCurrent?.call() == false) {
      return const Panel(
          child: EmptyView('工作空间或权限已变化', '已隐藏旧记录，请重新打开当前工作空间的页面。'));
    }
    final owner = resourceGeneration;
    final permitted = widget.isCurrent;
    final interact = widget.canInteract;
    final api = widget.api;
    final path = widget.path;
    final create = widget.create;
    final onOpen = widget.onOpen;
    final reauth = widget.reauth;
    bool viewCurrent() =>
        _canInteract && resourceGeneration == owner &&
        identical(widget.api, api) && widget.path == path &&
        permitted?.call() != false && interact?.call() != false;
    VoidCallback guard(VoidCallback callback) => () {
          if (viewCurrent()) callback();
        };
    void refreshRecords() {
      if (viewCurrent() && !loading && !acting) load();
    }
    void createRecord() {
      if (viewCurrent() && create != null && identical(widget.create, create)) {
        action(create);
      }
    }
    void openRecord(Json row) {
      if (viewCurrent() && onOpen != null && identical(widget.onOpen, onOpen)) {
        action(() => onOpen(row));
      }
    }
    final guardedReauth = reauth == null ? null : guard(() {
      if (identical(widget.reauth, reauth)) reauth();
    });
    final filtered = rows
        .where((r) => r.values.any(
            (v) => v.toString().toLowerCase().contains(query.toLowerCase())))
        .toList();
    final narrow = MediaQuery.sizeOf(context).width < 760;
    final canAct = _canInteract && !loading && !acting;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageHeading(widget.title, widget.subtitle,
          action: widget.create == null
              ? null
              : FilledButton.icon(
                  onPressed: canAct ? createRecord : null,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(widget.createLabel))),
      if (widget.notice != null)
        Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Notice(widget.notice!)),
      Panel(
          padding: EdgeInsets.zero,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
                padding: const EdgeInsets.all(18),
                child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                          width: narrow ? 240 : 300,
                          child: TextField(
                              key: ValueKey(resourceGeneration),
                              controller: search,
                              focusNode: searchFocus,
                              enabled: _canInteract,
                              textInputAction: TextInputAction.search,
                              onChanged: (v) {
                                if (viewCurrent()) setState(() => query = v.trim());
                              },
                              decoration: InputDecoration(
                                  hintText: '搜索已加载记录',
                                  prefixIcon: const Icon(Icons.search, size: 20),
                                  suffixIcon: search.text.isEmpty
                                      ? null
                                      : IconButton(
                                          tooltip: '清除列表搜索',
                                          onPressed: guard(clearSearch),
                                          icon: const Icon(Icons.close, size: 18)),
                                  isDense: true))),
                      IconButton(
                          tooltip: '刷新',
                          onPressed: loading || acting ? null : refreshRecords,
                          icon: const Icon(Icons.refresh, size: 20)),
                      ...widget.toolbar
                    ])),
            const Divider(),
            if (loading && rows.isNotEmpty)
              const LinearProgressIndicator(minHeight: 2),
            if (actionError != null)
              Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('操作未完成，已保留当前列表',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        FailureView(actionError!, reauth: guardedReauth),
                        const Text('请先刷新列表核对结果，再重新打开详情或重新操作。',
                            style: TextStyle(color: muted, fontSize: 12)),
                        TextButton.icon(
                            onPressed: loading || acting ? null : refreshRecords,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('刷新列表'))
                      ])),
            if (error != null && rows.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('刷新未完成，已保留已加载记录',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        FailureView(error!, reauth: guardedReauth),
                        TextButton.icon(
                            onPressed: loading || acting ? null : refreshRecords,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('重新刷新列表'))
                      ])),
            if (loading && rows.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(60),
                  child:
                      Center(child: CircularProgressIndicator(strokeWidth: 2)))
            else if (error != null && rows.isEmpty)
              Padding(
                  padding: const EdgeInsets.all(24),
                  child: FailureView(error!,
                      retry: refreshRecords,
                      reauth: guardedReauth))
            else if (rows.isEmpty)
              EmptyView(widget.emptyTitle, widget.emptyDescription,
                  action: widget.create == null
                      ? null
                      : OutlinedButton.icon(
                          onPressed: canAct ? createRecord : null,
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(widget.createLabel)))
            else if (filtered.isEmpty)
              EmptyView(
                  '没有匹配记录',
                  cursor == null
                      ? '调整搜索关键词后再试。'
                      : '搜索仅匹配已加载记录，可加载更多后继续查找。',
                  action: TextButton.icon(
                      onPressed: guard(clearSearch),
                      icon: const Icon(Icons.clear, size: 18),
                      label: const Text('清除搜索')))
            else if (narrow)
              ...filtered.map((row) => InkWell(
                  onTap: widget.onOpen == null || !canAct
                      ? null
                      : () => openRecord(row),
                  child: Container(
                      padding: const EdgeInsets.all(18),
                      decoration: const BoxDecoration(
                          border: Border(bottom: BorderSide(color: line))),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final c in widget.columns)
                              Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(
                                            width: 84,
                                            child: Text(c.title,
                                                style: const TextStyle(
                                                    color: muted,
                                                    fontSize: 12))),
                                        Expanded(child: c.build(row))
                                      ])),
                            if (widget.onOpen != null)
                              const Align(
                                  alignment: Alignment.centerRight,
                                  child:
                                      Icon(Icons.chevron_right, color: muted))
                          ]))))
            else
              LayoutBuilder(
                  builder: (context, box) => SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                          constraints: BoxConstraints(minWidth: box.maxWidth),
                          child: DataTable(
                              showCheckboxColumn: false,
                              columnSpacing: 32,
                              columns: [
                                ...widget.columns.map(
                                    (c) => DataColumn(label: Text(c.title))),
                                if (widget.onOpen != null)
                                  const DataColumn(label: Text('操作'))
                              ],
                              rows: filtered
                                  .map((row) => DataRow(
                                          onSelectChanged:
                                              widget.onOpen == null || !canAct
                                              ? null
                                              : (_) => openRecord(row),
                                          cells: [
                                            ...widget.columns.map((c) =>
                                                DataCell(ConstrainedBox(
                                                    constraints:
                                                        const BoxConstraints(
                                                            maxWidth: 280),
                                                    child: c.build(row)))),
                                            if (widget.onOpen != null)
                                              DataCell(TextButton(
                                                  onPressed: canAct
                                                      ? () => openRecord(row)
                                                      : null,
                                                  child: const Text('查看详情')))
                                          ]))
                                  .toList())))),
            if (appendError != null)
              Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(cursorExpired
                                ? '列表位置已失效，已保留当前记录'
                                : '后续记录未加载，已保留已加载记录',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        FailureView(appendError!, reauth: guardedReauth)
                      ])),
            if (!loading)
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                    Text(
                            '已加载 ${rows.length} 条${query.isEmpty ? '' : ' · 匹配 ${filtered.length} 条'}',
                            style:
                                const TextStyle(color: muted, fontSize: 12)),
                    if (cursorExpired)
                      OutlinedButton.icon(
                          onPressed: acting ? null : refreshRecords,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('刷新列表后继续查看'))
                    else if (cursor != null)
                      OutlinedButton(
                          onPressed:
                              more || acting ? null : guard(() => load(append: true)),
                          child: Text(more
                              ? '加载中…'
                              : appendError != null
                                  ? '重试加载更多'
                                  : '加载更多'))
                  ]))
          ]))
    ]);
  }
}
