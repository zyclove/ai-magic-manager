import 'dart:convert';
import 'package:device_policy/device_policy.dart' show validId, freezeJson;
import 'models.dart';
import 'payloads.dart';

/// 两类 pending 与序号在一个加密记录里提交；读取错误不得重置为新设备。
class ObservationJournal {
  final ObservationScope scope;
  final ObservationStore store;
  ObservationAuthorization? authorization;
  int inventorySequence = 0,
      usageSequence = 0,
      inventoryCount = 0,
      usageCount = 0;
  int? lastInventoryAt, lastUsageAt, pendingInventoryAt;
  Map<String, dynamic>? pendingInventory, pendingUsage;
  ObservationJournal(this.scope, this.store);
  Future<void> load() async {
    try {
      final encoded = await store.read();
      if (encoded == null) return;
      if (utf8.encode(encoded).length > 1048576) throw const FormatException();
      final json = jsonDecode(encoded);
      if (json is! Map<String, dynamic> ||
          !exactKeys(json, {
            'schema',
            'scope',
            'authorization',
            'inventorySequence',
            'usageSequence',
            'pendingInventory',
            'pendingInventoryAt',
            'pendingUsage',
            'lastInventoryAt',
            'lastUsageAt',
            'inventoryCount',
            'usageCount'
          }) ||
          json['schema'] is! int ||
          json['schema'] != 1 ||
          json['scope'] != scope.storageKey) throw const FormatException();
      for (final key in [
        'inventorySequence',
        'usageSequence',
        'inventoryCount',
        'usageCount'
      ]) {
        if (!safeNumber(json[key])) throw const FormatException();
      }
      for (final key in [
        'lastInventoryAt',
        'lastUsageAt',
        'pendingInventoryAt'
      ]) {
        if (json[key] != null && !safeNumber(json[key], minimum: 1)) {
          throw const FormatException();
        }
      }
      inventorySequence = json['inventorySequence'];
      usageSequence = json['usageSequence'];
      inventoryCount = json['inventoryCount'];
      usageCount = json['usageCount'];
      if (inventoryCount > 500 || usageCount > 500) {
        throw const FormatException();
      }
      lastInventoryAt = json['lastInventoryAt'];
      lastUsageAt = json['lastUsageAt'];
      pendingInventoryAt = json['pendingInventoryAt'];
      if (json['authorization'] != null) {
        authorization = ObservationAuthorization.parse(
            Map<String, dynamic>.from(json['authorization'] as Map), scope);
      }
      pendingInventory = _pending(json['pendingInventory'], false);
      pendingUsage = _pending(json['pendingUsage'], true);
      if ((pendingInventory == null) != (pendingInventoryAt == null)) {
        throw const FormatException();
      }
    } catch (_) {
      throw const ObservationFailure('OBSERVATION_STORAGE_FAILED');
    }
  }

  Map<String, dynamic>? _pending(dynamic raw, bool usage) {
    if (raw == null) return null;
    if (raw is! Map<String, dynamic> ||
        authorization == null ||
        raw['authorizationVersion'] != authorization!.version ||
        raw['sequence'] != (usage ? usageSequence : inventorySequence) ||
        !safeNumber(raw['sequence'], minimum: 1) ||
        !(usage
            ? authorization!.usageEnabled
            : authorization!.inventoryEnabled)) throw const FormatException();
    if (usage) {
      if (!exactKeys(raw, {
            'reportId',
            'sequence',
            'authorizationVersion',
            'source',
            'profile',
            'queryStart',
            'queryEnd',
            'observedAt',
            'timeZone',
            'applications'
          }) ||
          !validId(raw['reportId']) ||
          raw['source'] != 'ANDROID_USAGE_STATS') throw const FormatException();
      usagePayload(
          UsageSample(
              queryStart: raw['queryStart'],
              queryEnd: raw['queryEnd'],
              observedAt: raw['observedAt'],
              timeZone: raw['timeZone'],
              profile: raw['profile'],
              applications:
                  List<Map<String, dynamic>>.from(raw['applications'] as List)),
          usageSequence,
          authorization!.version,
          raw['reportId']);
    } else {
      if (!exactKeys(raw, {
            'sequence',
            'authorizationVersion',
            'visibility',
            'applications'
          }) ||
          raw['visibility'] != 'VISIBLE_PACKAGES') {
        throw const FormatException();
      }
      inventoryApplications(raw['applications']);
    }
    return freezeJson(raw);
  }

  Future<void> save() async {
    try {
      final encoded = jsonEncode({
        'schema': 1,
        'scope': scope.storageKey,
        'authorization': authorization?.toJson(),
        'inventorySequence': inventorySequence,
        'usageSequence': usageSequence,
        'pendingInventory': pendingInventory,
        'pendingInventoryAt': pendingInventoryAt,
        'pendingUsage': pendingUsage,
        'lastInventoryAt': lastInventoryAt,
        'lastUsageAt': lastUsageAt,
        'inventoryCount': inventoryCount,
        'usageCount': usageCount
      });
      if (utf8.encode(encoded).length > 1048576) throw const FormatException();
      await store.write(encoded);
    } catch (_) {
      throw const ObservationFailure('OBSERVATION_STORAGE_FAILED');
    }
  }

  void forgetReports({bool forgetAuthorization = false}) {
    pendingInventory = null;
    pendingInventoryAt = null;
    pendingUsage = null;
    inventoryCount = 0;
    usageCount = 0;
    lastInventoryAt = null;
    lastUsageAt = null;
    if (forgetAuthorization) authorization = null;
  }

  ObservationView view(
          {ObservationPlatformState? platform, bool online = false}) =>
      ObservationView(
          authorization: authorization,
          platform: platform,
          onlineConfirmed: online,
          pendingReports: (pendingInventory == null ? 0 : 1) +
              (pendingUsage == null ? 0 : 1),
          inventoryCount: inventoryCount,
          usageCount: usageCount,
          lastInventoryAt: lastInventoryAt,
          lastUsageAt: lastUsageAt);
}
