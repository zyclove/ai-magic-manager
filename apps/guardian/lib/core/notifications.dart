import 'package:notification_client/notification_client.dart' as shared;
import 'api.dart';
export 'package:notification_client/notification_client.dart'
    hide NotificationRepository, Json, NotificationTransport;

/// Browser transport adapter; protocol validation is shared with native clients.
class NotificationRepository extends shared.NotificationRepository {
  NotificationRepository(
      {required Api api, required super.root, required super.current})
      : super(
            transport: (method, path, {body}) =>
                api.send(method, path, body: body));
  static Stream<String> get changes => shared.NotificationRepository.changes;
  @override
  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<T> _mapped<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on shared.NotificationFailure catch (e) {
      throw ApiFailure(e.status, e.code);
    }
  }

  @override
  Future<shared.InboxCount> count() => _mapped(() => super.count());
  @override
  Future<shared.InboxSnapshot> load(
          {String? cursor, bool unreadOnly = false}) =>
      _mapped(() => super.load(cursor: cursor, unreadOnly: unreadOnly));
  @override
  Future<void> markRead(List<String> ids) => _mapped(() => super.markRead(ids));
}
