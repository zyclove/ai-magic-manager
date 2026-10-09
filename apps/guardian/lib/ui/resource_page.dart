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
      this.reauth});
  @override
  State<ResourcePage> createState() => ResourcePageState();
}

class ResourcePageState extends State<ResourcePage> {
  List<Json> rows = [];
  String? cursor;
  String query = '';
  bool loading = true;
  bool more = false;
  Object? error;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(ResourcePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      load();
    }
  }

  Future<void> load({bool append = false}) async {
    final epoch = ++generation;
    setState(() {
      if (append) {
        more = true;
      } else {
        loading = true;
        rows = [];
        cursor = null;
      }
      error = null;
    });
    try {
      final result =
          await widget.api.page(widget.path, cursor: append ? cursor : null);
      if (mounted && generation == epoch) {
        setState(() {
          rows = append ? [...rows, ...result.items] : result.items;
          cursor = result.nextCursor;
        });
      }
    } catch (e) {
      if (mounted && generation == epoch) setState(() => error = e);
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
    try {
      await callback();
      if (mounted) await load();
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = rows
        .where((r) => r.values.any(
            (v) => v.toString().toLowerCase().contains(query.toLowerCase())))
        .toList();
    final narrow = MediaQuery.sizeOf(context).width < 760;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PageHeading(widget.title, widget.subtitle,
          action: widget.create == null
              ? null
              : FilledButton.icon(
                  onPressed: () => action(widget.create!),
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
                              onChanged: (v) => setState(() => query = v),
                              decoration: const InputDecoration(
                                  hintText: '搜索已加载记录',
                                  prefixIcon: Icon(Icons.search, size: 20),
                                  isDense: true))),
                      IconButton(
                          tooltip: '刷新',
                          onPressed: loading ? null : () => load(),
                          icon: const Icon(Icons.refresh, size: 20)),
                      ...widget.toolbar
                    ])),
            const Divider(),
            if (loading)
              const Padding(
                  padding: EdgeInsets.all(60),
                  child:
                      Center(child: CircularProgressIndicator(strokeWidth: 2)))
            else if (error != null)
              Padding(
                  padding: const EdgeInsets.all(24),
                  child: FailureView(error!,
                      retry: () => load(append: rows.isNotEmpty),
                      reauth: widget.reauth))
            else if (rows.isEmpty)
              EmptyView(widget.emptyTitle, widget.emptyDescription,
                  action: widget.create == null
                      ? null
                      : OutlinedButton.icon(
                          onPressed: () => action(widget.create!),
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(widget.createLabel)))
            else if (filtered.isEmpty)
              const EmptyView('没有匹配记录', '调整搜索关键词后再试。')
            else if (narrow)
              ...filtered.map((row) => InkWell(
                  onTap: widget.onOpen == null
                      ? null
                      : () => action(() => widget.onOpen!(row)),
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
                                          onSelectChanged: widget.onOpen == null
                                              ? null
                                              : (_) => action(
                                                  () => widget.onOpen!(row)),
                                          cells: [
                                            ...widget.columns.map((c) =>
                                                DataCell(ConstrainedBox(
                                                    constraints:
                                                        const BoxConstraints(
                                                            maxWidth: 280),
                                                    child: c.build(row)))),
                                            if (widget.onOpen != null)
                                              DataCell(TextButton(
                                                  onPressed: () => action(() =>
                                                      widget.onOpen!(row)),
                                                  child: const Text('查看详情')))
                                          ]))
                                  .toList())))),
            if (!loading)
              Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Expanded(
                        child: Text(
                            '已加载 ${rows.length} 条${query.isEmpty ? '' : ' · 匹配 ${filtered.length} 条'}',
                            style:
                                const TextStyle(color: muted, fontSize: 12))),
                    if (cursor != null)
                      OutlinedButton(
                          onPressed: more ? null : () => load(append: true),
                          child: Text(more ? '加载中…' : '加载更多'))
                  ]))
          ]))
    ]);
  }
}
