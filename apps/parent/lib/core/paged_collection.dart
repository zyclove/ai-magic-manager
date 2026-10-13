import 'package:flutter/foundation.dart';

import 'parent_api.dart';

/// Bounded list reader for large institution workspaces. A reload invalidates
/// in-flight pages; stale responses cannot restore a previous workspace list.
class PagedCollection extends ChangeNotifier {
  final ParentApi api;
  final String path;
  final int pageSize;
  final String idField;

  /// Rechecked after asynchronous token refresh and before accepting a page.
  final bool Function()? isCurrent;
  final _items = <Json>[];
  final _seenCursors = <String>{};
  int _generation = 0;
  String? _nextCursor;
  bool _disposed = false;

  PagedCollection(this.api, this.path,
      {this.pageSize = 50, this.idField = 'id', this.isCurrent}) {
    reload();
  }

  List<Json> get items => List.unmodifiable(_items);
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _nextCursor != null;
  bool get loaded => _loaded;
  Object? get error => _error;

  bool _loading = false, _loadingMore = false, _loaded = false;
  Object? _error;

  Future<void> reload() async {
    if (_disposed || !(isCurrent?.call() ?? true)) return;
    final epoch = ++_generation;
    _items.clear();
    _seenCursors.clear();
    _nextCursor = null;
    _loading = true;
    _loadingMore = false;
    _loaded = false;
    _error = null;
    notifyListeners();
    try {
      final page = await api.page(path,
          limit: pageSize,
          isCurrent: () =>
              !_disposed &&
              epoch == _generation &&
              (isCurrent?.call() ?? true));
      if (_disposed || epoch != _generation || !(isCurrent?.call() ?? true)) {
        return;
      }
      _requireUniqueIds(page.items, const {});
      _items.addAll(page.items);
      _nextCursor = page.nextCursor;
      if (_nextCursor != null) _seenCursors.add(_nextCursor!);
      _loaded = true;
    } catch (failure) {
      if (!_disposed && epoch == _generation) _error = failure;
    } finally {
      if (!_disposed && epoch == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMore() async {
    final cursor = _nextCursor;
    if (_disposed ||
        cursor == null ||
        _loading ||
        _loadingMore ||
        !(isCurrent?.call() ?? true)) return;
    final epoch = _generation;
    _loadingMore = true;
    _error = null;
    notifyListeners();
    try {
      final page = await api.page(path,
          cursor: cursor,
          limit: pageSize,
          isCurrent: () =>
              !_disposed &&
              epoch == _generation &&
              (isCurrent?.call() ?? true));
      if (_disposed || epoch != _generation || !(isCurrent?.call() ?? true)) {
        return;
      }
      if (page.nextCursor != null && _seenCursors.contains(page.nextCursor)) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      _requireUniqueIds(
          page.items, _items.map((item) => item[idField] as String).toSet());
      _items.addAll(page.items);
      _nextCursor = page.nextCursor;
      if (_nextCursor != null) _seenCursors.add(_nextCursor!);
    } catch (failure) {
      if (!_disposed && epoch == _generation) _error = failure;
    } finally {
      if (!_disposed && epoch == _generation) {
        _loadingMore = false;
        notifyListeners();
      }
    }
  }

  void _requireUniqueIds(List<Json> page, Set<String> existing) {
    final ids = {...existing};
    for (final item in page) {
      final id = item[idField];
      if (id is! String || id.isEmpty || !ids.add(id)) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
