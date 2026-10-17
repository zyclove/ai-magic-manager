import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/managed_execution.dart';
import '../core/managed_execution_repository.dart';

/// One device window owns this state. No read retry replays a cancellation.
class ManagedExecutionController extends ChangeNotifier {
  final ManagedExecutionRepository repository;
  final String registrationId;

  ManagedExecutionController(
      {required this.repository, required this.registrationId});

  List<ManagedExecution> items = const [];
  List<ManagedExecutionEvent> events = const [];
  ManagedExecution? selected;
  String? filter, cursor, eventCursor, notice;
  Object? listError, detailError, eventError;
  bool listBusy = false, detailBusy = false, eventsBusy = false;
  bool writeBusy = false, needsReauth = false;
  bool _allowed = true, _disposed = false, _detailVerified = false;
  int _listGeneration = 0, _detailGeneration = 0, _eventGeneration = 0;
  // Retained across back/filter/refresh. Old READY does not prove a write failed.
  final _uncertainCancellationIds = <String>{};
  // Refreshing a page cannot erase progress already observed in this window.
  final _highestEventRevision = <String, int>{};

  bool get hasAccess => !_disposed && _allowed && repository.current();
  bool get busy => listBusy || detailBusy || eventsBusy || writeBusy;
  bool get historical =>
      selected != null && selected!.registrationId != registrationId;
  bool get resultUnknown =>
      selected != null && _uncertainCancellationIds.contains(selected!.id);
  bool get eventsAhead =>
      selected != null &&
      (_highestEventRevision[selected!.id] ?? 0) > selected!.revision;
  bool get canCancel =>
      hasAccess &&
      !busy &&
      _detailVerified &&
      !needsReauth &&
      !resultUnknown &&
      !eventsAhead &&
      selected != null &&
      repository.canCancel(selected!);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _clearDetail() {
    _detailGeneration++;
    _eventGeneration++;
    selected = null;
    events = const [];
    eventCursor = null;
    detailError = eventError = null;
    notice = null;
    needsReauth = false;
    _detailVerified = false;
    detailBusy = eventsBusy = false;
  }

  void _lose(Object failure) {
    if (_disposed) return;
    _allowed = false;
    _listGeneration++;
    _clearDetail();
    items = const [];
    cursor = filter = null;
    _uncertainCancellationIds.clear();
    _highestEventRevision.clear();
    listError = failure;
    listBusy = writeBusy = false;
    _changed();
  }

  bool _guard() {
    if (_disposed || !_allowed) return false;
    try {
      repository.ensureCurrent();
      return true;
    } catch (failure) {
      _lose(failure);
      return false;
    }
  }

  void checkScope() {
    _guard();
  }

  bool _listCurrent(int generation) =>
      _guard() && generation == _listGeneration;
  bool _detailCurrent(int generation) =>
      _guard() && generation == _detailGeneration && selected != null;

  bool _privateFailure(Object failure) {
    if (failure is! ApiFailure) return false;
    if (failure.code == 'WORKSPACE_CHANGED' ||
        failure.status == 403 ||
        (failure.status == 401 && failure.code != 'REAUTH_REQUIRED')) {
      _lose(failure);
      return true;
    }
    if (failure.code == 'REAUTH_REQUIRED') needsReauth = true;
    return false;
  }

  Future<void> load({String? state}) async {
    final next = state == '' ? null : state;
    if (!_guard() || writeBusy || (listBusy && next == filter)) return;
    filter = next;
    final generation = ++_listGeneration;
    _clearDetail();
    items = const [];
    cursor = null;
    listError = null;
    listBusy = true;
    _changed();
    try {
      final page = await repository.list(state: filter);
      if (!_listCurrent(generation)) return;
      items = page.items;
      cursor = page.nextCursor;
    } catch (failure) {
      if (_listCurrent(generation) && !_privateFailure(failure)) {
        listError = failure;
      }
    } finally {
      if (_listCurrent(generation)) {
        listBusy = false;
        _changed();
      }
    }
  }

  Future<void> loadMore() async {
    if (!_guard() || busy || cursor == null) return;
    final generation = _listGeneration, requested = cursor;
    var reset = false;
    listBusy = true;
    listError = null;
    _changed();
    try {
      final page = await repository.list(cursor: requested, state: filter);
      if (!_listCurrent(generation)) return;
      final seen = items.map((item) => item.id).toSet();
      if (page.items.any((item) => seen.contains(item.id))) {
        throw const ApiFailure(502, 'INVALID_MANAGED_EXECUTION_RESPONSE');
      }
      // Also enforce ordering across the page boundary, not only within pages.
      if (items.isNotEmpty && page.items.isNotEmpty) {
        final previous = items.last, next = page.items.first;
        if (next.createdAt > previous.createdAt ||
            (next.createdAt == previous.createdAt &&
                next.id.compareTo(previous.id) >= 0)) {
          throw const ApiFailure(502, 'INVALID_MANAGED_EXECUTION_RESPONSE');
        }
      }
      items = List.unmodifiable([...items, ...page.items]);
      cursor = page.nextCursor;
    } catch (failure) {
      if (_listCurrent(generation) && !_privateFailure(failure)) {
        reset = failure is ApiFailure && failure.code == 'INVALID_CURSOR';
        listError = failure;
      }
    } finally {
      if (_listCurrent(generation)) {
        listBusy = false;
        _changed();
      }
    }
    if (reset && _listCurrent(generation)) await load(state: filter);
  }

  Future<void> open(ManagedExecution task) async {
    if (!_guard() ||
        busy ||
        !items.any((row) =>
            row.id == task.id &&
            row.revision == task.revision &&
            row.registrationId == task.registrationId)) {
      return;
    }
    _clearDetail();
    selected = task;
    await refreshDetail();
  }

  void back() {
    if (!_guard() || writeBusy) return;
    _clearDetail();
    _changed();
  }

  Future<void> refreshDetail() => _refreshDetail();

  Future<void> _refreshDetail({bool afterWrite = false}) async {
    if (!_guard() ||
        selected == null ||
        detailBusy ||
        (writeBusy && !afterWrite)) {
      return;
    }
    final generation = _detailGeneration, task = selected!;
    detailBusy = true;
    _detailVerified = false;
    detailError = null;
    _changed();
    var readEvents = false;
    try {
      final value = await repository.detail(task);
      if (!_detailCurrent(generation)) return;
      selected = value;
      _detailVerified = true;
      // Confirmation can be offered only after a new authenticated read.
      needsReauth = false;
      _replaceListRecord(value);
      readEvents = true;
    } catch (failure) {
      if (_detailCurrent(generation) && !_privateFailure(failure)) {
        detailError = failure;
      }
    } finally {
      if (_detailCurrent(generation)) {
        detailBusy = false;
        _changed();
      }
    }
    if (readEvents && _detailCurrent(generation)) {
      await _readEvents(more: false, afterWrite: afterWrite);
    }
  }

  Future<void> loadMoreEvents() => _readEvents(more: true);

  Future<void> _readEvents(
      {required bool more, bool afterWrite = false}) async {
    if (!_guard() ||
        selected == null ||
        eventsBusy ||
        detailBusy ||
        (writeBusy && !afterWrite) ||
        (more && eventCursor == null)) {
      return;
    }
    final detailGeneration = _detailGeneration;
    final eventGeneration = ++_eventGeneration, task = selected!;
    final requested = more ? eventCursor : null;
    eventsBusy = true;
    eventError = null;
    if (!more) {
      events = const [];
      eventCursor = null;
    }
    _changed();
    bool current() =>
        _detailCurrent(detailGeneration) && eventGeneration == _eventGeneration;
    var reset = false;
    try {
      final page = await repository.events(task, cursor: requested);
      if (!current()) return;
      if (more &&
          events.isNotEmpty &&
          page.items.isNotEmpty &&
          page.items.first.revision <= events.last.revision) {
        throw const ApiFailure(502, 'INVALID_MANAGED_EXECUTION_RESPONSE');
      }
      events =
          List.unmodifiable(more ? [...events, ...page.items] : page.items);
      if (page.items.isNotEmpty) {
        final highest = _highestEventRevision[task.id] ?? 0;
        if (page.items.last.revision > highest) {
          _highestEventRevision[task.id] = page.items.last.revision;
        }
      }
      eventCursor = page.nextCursor;
    } catch (failure) {
      if (current() && !_privateFailure(failure)) {
        eventError = failure;
        reset =
            more && failure is ApiFailure && failure.code == 'INVALID_CURSOR';
      }
    } finally {
      if (current()) {
        eventsBusy = false;
        _changed();
      }
    }
    if (reset && current()) {
      await _readEvents(more: false, afterWrite: afterWrite);
    }
  }

  void _replaceListRecord(ManagedExecution value) {
    items = List.unmodifiable(items
        .where((old) =>
            old.id != value.id || filter == null || value.state == filter)
        .map((old) => old.id == value.id ? value : old));
  }

  Future<void> cancel(
      Future<bool> Function(ManagedExecution task) confirm) async {
    if (!canCancel || !_guard()) return;
    final task = selected!, generation = _detailGeneration;
    writeBusy =
        true; // Set before awaiting confirmation; closes double-click races.
    notice = null;
    _changed();
    var sent = false;
    try {
      final accepted = await confirm(task);
      if (!accepted ||
          !_detailCurrent(generation) ||
          selected!.id != task.id ||
          selected!.revision != task.revision ||
          !_detailVerified ||
          needsReauth ||
          resultUnknown ||
          eventsAhead ||
          !repository.canCancel(task)) {
        return;
      }
      sent = true;
      final result = await repository.cancel(task);
      if (!_detailCurrent(generation)) return;
      selected = result;
      _detailVerified = true;
      _replaceListRecord(result);
      notice = result.state == 'CANCELLED'
          ? '后续执行已取消。已存在的远端策略或设备状态仍需分别核对。'
          : '已登记取消，仍需复核。当前不能确认设备已停止执行。';
      await _readEvents(more: false, afterWrite: true);
    } catch (failure) {
      if (!_detailCurrent(generation) || _privateFailure(failure)) return;
      detailError = failure;
      if (failure is ApiFailure && failure.code == 'REAUTH_REQUIRED') {
        needsReauth = true;
        notice = '请完成安全验证，重新读取记录后再次确认；不会自动提交取消。';
      } else if (failure is ApiFailure && failure.status == 412) {
        notice = '记录已更新，原确认已失效。请核对最新进展后重新确认。';
        await _refreshDetail(afterWrite: true);
      } else if (sent) {
        _uncertainCancellationIds.add(task.id);
        notice = '尚不能确认取消结果。请读取核对，不会再次提交取消。';
      }
    } finally {
      if (_detailCurrent(generation)) {
        writeBusy = false;
        _changed();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _allowed = false;
    _listGeneration++;
    _clearDetail();
    items = const [];
    _uncertainCancellationIds.clear();
    _highestEventRevision.clear();
    super.dispose();
  }
}
