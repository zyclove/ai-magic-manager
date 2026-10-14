import 'package:flutter/foundation.dart';
import 'package:notification_client/notification_client.dart' as shared;
import 'parent_api.dart';
export 'package:notification_client/notification_client.dart'
    show InboxNotice, InboxSnapshot, InboxCount;

/// One adult/workspace inbox. No notification content is persisted locally.
class ParentNotificationInbox extends ChangeNotifier {
  final ParentApi api;
  final String root;
  final bool Function() isCurrent;
  late final shared.NotificationRepository repository;
  bool foreground = true, busy = false, unreadOnly = true, disposed = false;
  bool opening = false;
  int generation = 0;
  final cursors = <String?>[null];
  shared.InboxSnapshot? snapshot;
  Object? error;
  List<String>? retryIds;
  String? retryRequestId, confirmation;
  bool get available => !disposed && foreground && isCurrent();

  ParentNotificationInbox(
      {required this.api, required this.root, required this.isCurrent}) {
    repository = shared.NotificationRepository(
        root: root,
        current: () => available,
        transport: (method, path, {body}) {
          final g = generation;
          return api.send(method, path, body: body, isCurrent: () => valid(g));
        });
  }
  bool valid(int g) => available && g == generation;
  void notify() {
    if (!disposed) notifyListeners();
  }

  Object mapped(Object e) => e is shared.NotificationFailure
      ? ParentApiException(e.status, e.code)
      : e;

  Future<void> load({bool first = false, bool? unread}) async {
    if (!available || busy) return;
    if (first || unread != null) {
      cursors
        ..clear()
        ..add(null);
    }
    if (unread != null) unreadOnly = unread;
    final g = ++generation;
    busy = true;
    snapshot = null;
    error = null;
    retryIds = null;
    retryRequestId = null;
    notify();
    try {
      final value =
          await repository.load(cursor: cursors.last, unreadOnly: unreadOnly);
      if (!valid(g)) return;
      if (value.page.nextCursor != null &&
          cursors.contains(value.page.nextCursor)) {
        throw const ParentApiException(502, 'INVALID_NOTIFICATION_RESPONSE');
      }
      snapshot = value;
    } catch (e) {
      if (valid(g)) error = mapped(e);
    } finally {
      if (valid(g)) {
        busy = false;
        notify();
      }
    }
  }

  Future<void> next() async {
    if (!available || busy || snapshot?.page.nextCursor == null) return;
    cursors.add(snapshot!.page.nextCursor);
    await load();
  }

  Future<void> previous() async {
    if (!available || busy || cursors.length == 1) return;
    cursors.removeLast();
    await load();
  }

  /// Retry is explicit and retains the original IDs, never the next loaded page.
  Future<void> read(List<String> selection,
      {String? requestId, required Future<void> Function(String) open}) async {
    if (!available || busy) return;
    final ids = List<String>.unmodifiable(selection);
    final g = ++generation;
    busy = true;
    error = null;
    retryIds = null;
    retryRequestId = null;
    confirmation = null;
    notify();
    var completed = false;
    try {
      if (ids.isNotEmpty) await repository.markRead(ids);
      if (!valid(g)) return;
      if (requestId != null) {
        opening = true;
        notify();
        await open(requestId);
      }
      if (!valid(g)) return;
      completed = true;
      confirmation = requestId == null ? '已标为已读，仅影响你的账号。' : null;
    } catch (e) {
      if (valid(g)) {
        error = mapped(e);
        if (error is ParentApiException &&
            {401, 403}.contains((error as ParentApiException).status)) {
          snapshot = null;
        } else {
          retryIds = ids;
          retryRequestId = requestId;
        }
      }
    } finally {
      if (valid(g)) {
        busy = false;
        opening = false;
        notify();
      }
    }
    if (completed && valid(g)) await load(first: true);
  }

  void setForeground(bool value) {
    foreground = value;
    if (!value) invalidate();
  }

  void invalidate() {
    generation++;
    busy = false;
    opening = false;
    snapshot = null;
    error = null;
    retryIds = null;
    retryRequestId = null;
    confirmation = null;
    notify();
  }

  @override
  void dispose() {
    disposed = true;
    generation++;
    super.dispose();
  }
}
