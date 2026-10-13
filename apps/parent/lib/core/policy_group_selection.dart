import 'parent_api.dart';

final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// An immutable complete CURRENT-member snapshot, never a truncated selection.
class PolicyGroupSelection {
  final String id, name;
  final int version, excludedCount;
  final Map<String, String> registrations, names;
  PolicyGroupSelection(
      {required this.id,
      required this.name,
      required this.version,
      required this.excludedCount,
      required Map<String, String> registrations,
      required Map<String, String> names})
      : registrations = Map.unmodifiable(registrations),
        names = Map.unmodifiable(names);
  Json get reference => {'groupId': id, 'groupVersion': version};

  bool matchesReference(dynamic value) =>
      value is Json &&
      value['groupId'] == id &&
      value['groupVersion'] == version;

  static Future<PolicyGroupSelection> load(ParentApi api, String tenant,
      String id, bool Function() isCurrent) async {
    if (!_uuid.hasMatch(id)) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    void checkScope() {
      if (!isCurrent()) throw const ParentApiException(409, 'SCOPE_DENIED');
    }

    checkScope();
    final before = await api.object('/tenants/$tenant/device-groups/$id',
        isCurrent: isCurrent);
    checkScope();
    _validate(before, id);
    if (before['state'] != 'ACTIVE') {
      throw const ParentApiException(409, 'POLICY_GROUP_CHANGED');
    }
    // CURRENT is server-derived from subject lifecycle, device state and registration.
    final page = await api.page(
        '/tenants/$tenant/device-groups/$id/devices?status=CURRENT',
        limit: 50,
        isCurrent: isCurrent);
    checkScope();
    if (page.nextCursor != null || page.items.length > 50) {
      throw const ParentApiException(422, 'POLICY_GROUP_TOO_LARGE');
    }
    if (page.items.isEmpty) {
      throw const ParentApiException(422, 'POLICY_GROUP_EMPTY');
    }
    final registrations = <String, String>{}, names = <String, String>{};
    for (final member in page.items) {
      final device = member['deviceId'],
          registration = member['registrationId'];
      if (device is! String ||
          !_uuid.hasMatch(device) ||
          registration is! String ||
          !_uuid.hasMatch(registration) ||
          member['membershipStatus'] != 'CURRENT' ||
          member['state'] != 'ACTIVE' ||
          member['displayName'] is! String ||
          registrations.containsKey(device)) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      registrations[device] = registration;
      names[device] = member['displayName'];
    }
    final after = await api.object('/tenants/$tenant/device-groups/$id',
        isCurrent: isCurrent);
    checkScope();
    _validate(after, id);
    if (after['state'] != 'ACTIVE' ||
        after['version'] != before['version'] ||
        after['deviceCount'] != before['deviceCount']) {
      throw const ParentApiException(409, 'POLICY_GROUP_CHANGED');
    }
    if ((after['deviceCount'] as int) < registrations.length) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return PolicyGroupSelection(
        id: id,
        name: after['name'],
        version: after['version'],
        excludedCount: (after['deviceCount'] as int) - registrations.length,
        registrations: registrations,
        names: names);
  }

  /// Re-read the complete registration set, not just the group revision. Device
  /// lifecycle changes can invalidate membership without changing that revision.
  Future<void> recheck(
      ParentApi api, String tenant, bool Function() isCurrent) async {
    final latest = await load(api, tenant, id, isCurrent);
    if (latest.version != version ||
        latest.registrations.length != registrations.length ||
        registrations.entries
            .any((e) => latest.registrations[e.key] != e.value)) {
      throw const ParentApiException(409, 'POLICY_GROUP_CHANGED');
    }
  }

  static void _validate(Json group, String id) {
    if (group['id'] != id ||
        group['name'] is! String ||
        group['version'] is! int ||
        group['version'] < 0 ||
        group['deviceCount'] is! int ||
        group['deviceCount'] < 0 ||
        !const {'ACTIVE', 'ARCHIVED'}.contains(group['state'])) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
  }
}
