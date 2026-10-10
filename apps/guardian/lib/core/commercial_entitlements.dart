import 'api.dart';

/// Paid rights only. A successful purchase never establishes Android system control.
class CommercialEntitlements {
  static const knownFeatures = {
    'ADVANCED_SCHEDULES',
    'WEB_FILTERING',
    'MANAGED_ANDROID',
    'ORG_BULK',
    'AI_INSIGHTS'
  };

  final String tenantId;
  final int version, evaluatedAt, activeSourceCount;
  final int baseDeviceCapacity, addOnDeviceCapacity, paidDeviceCapacity;
  final List<String> features;
  final bool technicalCapabilityIndependent;

  const CommercialEntitlements._(
      this.tenantId,
      this.version,
      this.evaluatedAt,
      this.activeSourceCount,
      this.baseDeviceCapacity,
      this.addOnDeviceCapacity,
      this.paidDeviceCapacity,
      this.features,
      this.technicalCapabilityIndependent);

  bool has(String feature) => features.contains(feature);

  static CommercialEntitlements parse(dynamic raw, String expectedTenant) {
    const maxSafe = 9007199254740991;
    Never invalid() =>
        throw const ApiFailure(502, 'INVALID_COMMERCIAL_RESPONSE');
    bool validNumber(dynamic number) =>
        number is int && number >= 0 && number <= maxSafe;
    if (raw is! Json || raw['tenantId'] != expectedTenant) invalid();
    final version = raw['version'],
        evaluatedAt = raw['evaluatedAt'],
        sourceCount = raw['activeSourceCount'],
        base = raw['baseDeviceCapacity'],
        addOn = raw['addOnDeviceCapacity'],
        total = raw['paidDeviceCapacity'],
        featureList = raw['features'];
    if (![version, evaluatedAt, sourceCount, base, addOn, total]
            .every(validNumber) ||
        featureList is! List ||
        featureList.length > knownFeatures.length ||
        raw['technicalCapabilityIndependent'] != true) invalid();
    final features = <String>[];
    for (final feature in featureList) {
      if (feature is! String ||
          !knownFeatures.contains(feature) ||
          features.contains(feature)) invalid();
      features.add(feature);
    }
    if (base + addOn != total ||
        (base == 0 && addOn != 0) ||
        (sourceCount == 0 && (total != 0 || features.isNotEmpty)) ||
        (version == 0 && sourceCount != 0)) invalid();
    return CommercialEntitlements._(expectedTenant, version, evaluatedAt,
        sourceCount, base, addOn, total, List.unmodifiable(features), true);
  }
}

String commercialFeatureLabel(String feature) => switch (feature) {
      'ADVANCED_SCHEDULES' => '精细时间计划',
      'WEB_FILTERING' => '网站分类管理',
      'MANAGED_ANDROID' => '受管 Android 功能权益',
      'ORG_BULK' => '机构批量管理',
      'AI_INSIGHTS' => '智能使用建议',
      _ => '未知权益'
    };
