import 'api.dart';

/// Complete membership counts from the server, not a count inferred from one page.
class DeviceGroupSummary {
  final String groupId;
  final int version;
  final int total;
  final int current;
  final int staleRegistration;
  final int deviceInactive;
  final int profileArchived;

  const DeviceGroupSummary._(
      this.groupId,
      this.version,
      this.total,
      this.current,
      this.staleRegistration,
      this.deviceInactive,
      this.profileArchived);

  int get excluded => total - current;

  factory DeviceGroupSummary.read(Object? raw, Json group) {
    if (raw is! Json ||
        group['id'] is! String ||
        group['version'] is! int ||
        group['deviceCount'] is! int ||
        raw['groupId'] != group['id'] ||
        raw['version'] != group['version'] ||
        raw['total'] != group['deviceCount'] ||
        raw['total'] is! int ||
        (raw['total'] as int) < 0 ||
        (raw['total'] as int) > 5000) {
      throw const ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
    }
    final total = raw['total'] as int;
    var counted = 0;
    for (final key in [
      'current',
      'staleRegistration',
      'deviceInactive',
      'profileArchived'
    ]) {
      if (raw[key] is! int || (raw[key] as int) < 0 || raw[key] > total) {
        throw const ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
      }
      counted += raw[key] as int;
    }
    if (counted != total) {
      throw const ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
    }
    return DeviceGroupSummary._(
        group['id'] as String,
        group['version'] as int,
        total,
        raw['current'] as int,
        raw['staleRegistration'] as int,
        raw['deviceInactive'] as int,
        raw['profileArchived'] as int);
  }
}
