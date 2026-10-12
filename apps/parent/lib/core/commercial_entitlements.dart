import 'parent_api.dart';

/// A verified commercial projection. Paid rights do not establish OS control.
class ParentCommercialEntitlements {
  static const featureNames = <String, String>{
    'ADVANCED_SCHEDULES': '精细时间计划',
    'WEB_FILTERING': '网站分类管理',
    'MANAGED_ANDROID': '受管 Android 功能权益',
    'ORG_BULK': '机构批量管理',
    'AI_INSIGHTS': '智能使用建议',
  };

  final int version;
  final int evaluatedAt;
  final int activeSourceCount;
  final int baseDeviceCapacity;
  final int addOnDeviceCapacity;
  final int paidDeviceCapacity;
  final List<String> features;

  const ParentCommercialEntitlements._(
      this.version,
      this.evaluatedAt,
      this.activeSourceCount,
      this.baseDeviceCapacity,
      this.addOnDeviceCapacity,
      this.paidDeviceCapacity,
      this.features);

  static ParentCommercialEntitlements parse(Json value, String tenantId) {
    const maxSafe = 9007199254740991;
    bool valid(Object? value) => value is int && value >= 0 && value <= maxSafe;
    Never invalid() => throw const ParentApiException(502, 'INVALID_RESPONSE');

    if (value['tenantId'] != tenantId ||
        value['technicalCapabilityIndependent'] != true ||
        !valid(value['version']) ||
        !valid(value['evaluatedAt']) ||
        !valid(value['activeSourceCount']) ||
        !valid(value['baseDeviceCapacity']) ||
        !valid(value['addOnDeviceCapacity']) ||
        !valid(value['paidDeviceCapacity'])) {
      invalid();
    }
    final raw = value['features'];
    if (raw is! List || raw.length > featureNames.length) invalid();
    final features = <String>[];
    for (final item in raw) {
      if (item is! String ||
          !featureNames.containsKey(item) ||
          features.contains(item)) {
        invalid();
      }
      features.add(item);
    }
    final base = value['baseDeviceCapacity'] as int;
    final addOn = value['addOnDeviceCapacity'] as int;
    final total = value['paidDeviceCapacity'] as int;
    final sources = value['activeSourceCount'] as int;
    final version = value['version'] as int;
    if (base + addOn != total ||
        (base == 0 && addOn != 0) ||
        (sources == 0 && (total != 0 || features.isNotEmpty)) ||
        (version == 0 && sources != 0)) {
      invalid();
    }
    return ParentCommercialEntitlements._(version, value['evaluatedAt'] as int,
        sources, base, addOn, total, List.unmodifiable(features));
  }
}
