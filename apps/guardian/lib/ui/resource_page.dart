import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/labels.dart';
import 'design.dart';
import 'resource_action_lease.dart';
export 'resource_action_lease.dart' show ResourceActionLease;

// Search server values and the same localized labels displayed by status cells.
// JSON rows are acyclic; traverse nested values without constructing widgets.
String _resourceSearchText(Object? value) {
  if (value == null) return '';
  if (value is Map) {
    return value.values.map(_resourceSearchText).join('\n');
  }
  if (value is Iterable) {
    return value.map(_resourceSearchText).join('\n');
  }
  return '${value.toString()}\n${label(value)}'.toLowerCase();
}

class ColumnSpec {
  final String title;
  final Widget Function(Json) build;
  const ColumnSpec(this.title, this.build);
}

class ResourcePage extends StatefulWidget {
  final String title, subtitle, emptyTitle, emptyDescription, path;
  final Api api;
  final List<ColumnSpec> columns;
  /// Pure admission of accepted page rows; never replaces server authorization.
  /// Keep the callback stable. A changed predicate starts a new list lifecycle.
  final bool Function(Json)? includeRow;
  final Future<void> Function(Json)? onOpen;
  /// Explicit write outcomes request refresh, including unresolved writes
  /// closed with user confirmation; true does not imply a successful save.
  final Future<bool> Function(Json, ResourceActionLease)? onOpenChanged;
  /// Read-only details can keep the current pages and filter on return.
  final bool refreshAfterOpen;
  final Future<void> Function()? create;
  /// Like onOpenChanged: true requests a read, including unresolved creation.
  final Future<bool> Function(ResourceActionLease)? onCreateChanged;
  final String createLabel;
  final List<Widget> toolbar;
  final String? notice;
  final VoidCallback? reauth;
  /// Lets a domain owner retire its scope after an authoritative read denial.
  final ValueChanged<Object>? onReadDenied;
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
      this.includeRow,
      this.onOpen,
      this.onOpenChanged,
      this.refreshAfterOpen = true,
      this.create,
      this.onCreateChanged,
      this.createLabel = '新建',
      this.emptyTitle = '暂无记录',
      this.emptyDescription = '当前没有可显示的记录。',
      this.toolbar = const [],
      this.notice,
      this.reauth,
      this.onReadDenied,
      this.isCurrent,
      this.canInteract}) : assert(onOpen == null || onOpenChanged == null),
        assert(create == null || onCreateChanged == null);
  @override
  State<ResourcePage> createState() => ResourcePageState();
}

class ResourcePageState extends State<ResourcePage> {
  final search = TextEditingController();
  final searchFocus = FocusNode(debugLabel: 'resource-search');
  List<Json> rows = [];
  String? cursor;
  final _receivedCursors = <String>{};
  bool cursorExpired = false;
  bool readDenied = false;
  String query = '';
  bool loading = true;
  bool more = false;
  bool acting = false;
  Object? error;
  Object? appendError;
  Object? actionError;
  int generation = 0;
  int resourceGeneration = 0;
  int _interactionEpoch = 0;
  bool _active = true;
  ResourceActionLease? _actionLease;

  bool get _currentOwner => mounted && widget.isCurrent?.call() != false;
  bool get _canInteract => _active && _currentOwner && widget.canInteract?.call() != false;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(ResourcePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path || oldWidget.api != widget.api ||
        oldWidget.includeRow != widget.includeRow) {
      _actionLease?.retire();
      resourceGeneration++;
      rows = [];
      cursor = null;
      _receivedCursors.clear();
      cursorExpired = false;
      query = '';
      search.clear();
      acting = false;
      actionError = null;
      load();
    }
  }

  @override
  void deactivate() {
    _active = false;
    _interactionEpoch++;
    _actionLease?.retire();
    acting = false;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void dispose() {
    _active = false;
    _interactionEpoch++;
    _actionLease?.retire();
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

  // Retire all callbacks that captured a formerly readable batch. Only a new
  // authorized read can enable new actions; write-only MFA errors do not enter here.
  void _discardDeniedRead(Object failure) {
    _actionLease?.retire();
    resourceGeneration++;
    generation++;
    rows = [];
    cursor = null;
    _receivedCursors.clear();
    cursorExpired = false;
    readDenied = true;
    query = '';
    search.clear();
    loading = false;
    more = false;
    acting = false;
    appendError = null;
    actionError = null;
    error = failure;
  }

  Future<void> load({bool append = false}) async {
    if (!_currentOwner) return;
    if (append && (loading || more || acting || cursor == null)) return;
    final epoch = ++generation;
    final api = widget.api;
    final path = widget.path;
    final scope = resourceGeneration;
    final permitted = widget.isCurrent;
    final includeRow = widget.includeRow;
    final onReadDenied = widget.onReadDenied;
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
        final pageRows = includeRow == null
            ? result.items
            : result.items.where(includeRow).toList(growable: false);
        final nextCursor = result.nextCursor;
        if (append && nextCursor != null &&
            _receivedCursors.contains(nextCursor)) {
          throw const ApiFailure(502, 'INVALID_RESPONSE');
        }
        setState(() {
          if (!append) _receivedCursors.clear();
          if (nextCursor != null) _receivedCursors.add(nextCursor);
          rows = append ? [...rows, ...pageRows] : pageRows;
          cursor = nextCursor;
          cursorExpired = false;
          readDenied = false;
        });
      }
    } catch (e) {
      if (mounted && generation == epoch) {
        var denied = false;
        setState(() {
          if (e is ApiFailure &&
              (e.status == 401 ||
                  e.status == 403 ||
                  e.code == 'WORKSPACE_CHANGED')) {
            _discardDeniedRead(e);
            denied = true;
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
        if (denied) onReadDenied?.call(e);
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

  Future<void> action(Future<void> Function(ResourceActionLease) callback,
      {bool refresh = true}) async {
    if (!_canInteract || readDenied || acting || loading) return;
    final scope = resourceGeneration;
    final epoch = _interactionEpoch;
    final permitted = widget.isCurrent;
    final api = widget.api;
    final path = widget.path;
    final lease = ResourceActionLease(isCurrent: () => mounted && _active &&
        _interactionEpoch == epoch && resourceGeneration == scope &&
        identical(widget.api, api) && widget.path == path &&
        _currentOwner && permitted?.call() != false);
    _actionLease = lease;
    bool current() => identical(_actionLease, lease) && lease.current;
    setState(() {
      acting = true;
      actionError = null;
    });
    try {
      await callback(lease);
      if (current() && refresh) await load();
    } catch (e) {
      if (current()) {
        setState(() => actionError = e);
      }
    } finally {
      final unlock = current();
      if (identical(_actionLease, lease)) _actionLease = null;
      lease.dispose();
      if (unlock) setState(() => acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isCurrent?.call() == false) {
      _actionLease?.retire();
      _interactionEpoch++;
      acting = false;
      return const Panel(
          child: EmptyView('工作空间或权限已变化', '已隐藏旧记录，请重新打开当前工作空间的页面。'));
    }
    final owner = resourceGeneration;
    final interaction = _interactionEpoch;
    final permitted = widget.isCurrent;
    final interact = widget.canInteract;
    final api = widget.api;
    final path = widget.path;
    final create = widget.create;
    final onCreateChanged = widget.onCreateChanged;
    final canCreate = create != null || onCreateChanged != null;
    final onOpen = widget.onOpen;
    final onOpenChanged = widget.onOpenChanged;
    final canOpen = onOpen != null || onOpenChanged != null;
    final refreshAfterOpen = widget.refreshAfterOpen;
    final reauth = widget.reauth;
    bool resultCurrent() =>
        _active && _interactionEpoch == interaction &&
        _currentOwner && resourceGeneration == owner &&
        identical(widget.api, api) && widget.path == path &&
        permitted?.call() != false;
    bool viewCurrent() =>
        resultCurrent() && _canInteract && interact?.call() != false;
    VoidCallback guard(VoidCallback callback) => () {
          if (viewCurrent()) callback();
        };
    void refreshRecords() {
      if (viewCurrent() && !loading && !acting) load();
    }
    void createRecord() {
      if (!viewCurrent()) return;
      if (onCreateChanged != null &&
          identical(widget.onCreateChanged, onCreateChanged)) {
        action((lease) async {
          final needsReview = await onCreateChanged(lease);
          if (needsReview && lease.current && resultCurrent()) await load();
        }, refresh: false);
        return;
      }
      if (create != null && identical(widget.create, create)) action((_) => create());
    }
    void openRecord(Json row) {
      if (!viewCurrent()) return;
      if (onOpenChanged != null &&
          identical(widget.onOpenChanged, onOpenChanged)) {
        action((lease) async {
          final changed = await onOpenChanged(row, lease);
          if (changed && lease.current && resultCurrent()) await load();
        }, refresh: false);
        return;
      }
      if (viewCurrent() && onOpen != null && identical(widget.onOpen, onOpen)) {
        action((_) => onOpen(row), refresh: refreshAfterOpen);
      }
    }
    final guardedReauth = reauth == null ? null : guard(() {
      if (identical(widget.reauth, reauth)) reauth();
    });
    final terms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList();
    final filtered = terms.isEmpty
        ? rows
        : rows.where((row) {
            final text = _resourceSearchText(row);
            return terms.every((term) => text.contains(term));
          }).toList();
    final narrow = MediaQuery.sizeOf(context).width < 760;
    final canAct = _canInteract && !readDenied && !loading && !acting;
    final showActionProgress = acting && !loading && _canInteract &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageHeading(widget.title, widget.subtitle,
          action: !canCreate
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
            if (showActionProgress)
              Semantics(
                  container: true,
                  liveRegion: true,
                  label: '正在处理，请稍候',
                  child: const ExcludeSemantics(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        LinearProgressIndicator(minHeight: 2),
                        Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 18, vertical: 10),
                            child: Text('正在处理，请稍候',
                                style: TextStyle(color: muted, fontSize: 12)))
                      ]))),
            if (actionError != null)
              Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('操作结果待核对，已保留当前列表',
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
                  action: !canCreate
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
                  onTap: !canOpen || !canAct
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
                            if (canOpen)
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
                              dataRowMaxHeight: double.infinity,
                              showCheckboxColumn: false,
                              columnSpacing: 32,
                              columns: [
                                ...widget.columns.map(
                                    (c) => DataColumn(label: Text(c.title))),
                                if (canOpen)
                                  const DataColumn(label: Text('操作'))
                              ],
                              rows: filtered
                                  .map((row) => DataRow(
                                          onSelectChanged:
                                              !canOpen || !canAct
                                              ? null
                                              : (_) => openRecord(row),
                                          cells: [
                                            ...widget.columns.map((c) =>
                                                DataCell(ConstrainedBox(
                                                    constraints:
                                                        const BoxConstraints(
                                                            maxWidth: 280),
                                                    child: c.build(row)))),
                                            if (canOpen)
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
