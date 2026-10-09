import 'models.dart';

class ConfigurationDelivery {
  final String id, compactJws, state;
  final int cursor, deliveryExpiresAt;
  const ConfigurationDelivery._(this.id, this.cursor, this.compactJws,
      this.deliveryExpiresAt, this.state);
}

/// Transport facts are validated separately from the signed envelope.
class ConfigurationPage {
  final List<ConfigurationDelivery> items;
  final int requestedAfter, nextAfter, serverTime;
  final bool hasMore;
  const ConfigurationPage._(this.items, this.requestedAfter, this.nextAfter,
      this.hasMore, this.serverTime);
  factory ConfigurationPage.fromJson(Map<String, dynamic> json,
      {required int after, int limit = 10}) {
    if (after < 0 || after > maxSafeInteger || limit < 1 || limit > 50) {
      throw ArgumentError('Invalid paging input');
    }
    final raw = json['items'];
    final next = _integer(json['nextAfter']);
    final time = _integer(json['serverTime']);
    if (raw is! List ||
        raw.length > limit ||
        json['hasMore'] is! bool ||
        next < after) {
      throw const FormatException('Invalid configuration page');
    }
    final items = <ConfigurationDelivery>[];
    var previous = after;
    for (final entry in raw) {
      if (entry is! Map<String, dynamic> ||
          !validId(entry['id']) ||
          entry['compactJws'] is! String ||
          entry['compactJws'].isEmpty ||
          entry['compactJws'].length > 1048576 ||
          !const {
            'SERVED',
            'DEVICE_REPORTED_RECEIVED',
            'DEVICE_REPORTED_STORED',
            'DEVICE_REPORTED_REJECTED'
          }.contains(entry['state'])) {
        throw const FormatException('Invalid configuration item');
      }
      final cursor = _integer(entry['cursor'], minimum: 1);
      if (cursor <= previous || cursor > next) {
        throw const FormatException('Invalid page order');
      }
      previous = cursor;
      items.add(ConfigurationDelivery._(
          entry['id'],
          cursor,
          entry['compactJws'],
          _integer(entry['deliveryExpiresAt']),
          entry['state']));
    }
    final more = json['hasMore'] as bool;
    if (more && (items.isEmpty || next != items.last.cursor)) {
      throw const FormatException('Invalid continuation');
    }
    return ConfigurationPage._(
        List.unmodifiable(items), after, next, more, time);
  }
}

class ReceiptAcknowledgement {
  final String id, state;
  final bool historical;
  final int receivedAt;
  const ReceiptAcknowledgement._(
      this.id, this.state, this.historical, this.receivedAt);
  factory ReceiptAcknowledgement.fromJson(Map<String, dynamic> json,
      {required String receiptId}) {
    if (json['id'] != receiptId ||
        !validId(json['id']) ||
        json['historical'] is! bool ||
        json['evidenceStatus'] != 'DEVICE_REPORT_NOT_EXECUTION' ||
        !const {
          'SERVED',
          'DEVICE_REPORTED_RECEIVED',
          'DEVICE_REPORTED_STORED',
          'DEVICE_REPORTED_REJECTED',
          'SUPERSEDED',
          'EXPIRED_ATTEMPT'
        }.contains(json['state']) ||
        (json['historical'] == false &&
            json['state'] != 'DEVICE_REPORTED_STORED')) {
      throw const FormatException('Invalid receipt acknowledgement');
    }
    return ReceiptAcknowledgement._(json['id'], json['state'],
        json['historical'], _integer(json['receivedAt']));
  }
}

int _integer(dynamic value, {int minimum = 0}) {
  if (value is! int || value < minimum || value > maxSafeInteger) {
    throw const FormatException('Invalid protocol integer');
  }
  return value;
}
