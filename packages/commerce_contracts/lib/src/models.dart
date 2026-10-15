import '../vocabulary.dart';

typedef Json = Map<String, dynamic>;
bool _safeVersion(dynamic value) =>
    value is int && value >= 1 && value <= 9007199254740991;
bool _safeDate(dynamic value) =>
    value is int && value >= 0 && value <= 253402300799999;

/// Transport-independent validation error; application adapters translate it to their API error.
class ContractProtocolException implements Exception {
  const ContractProtocolException();
  @override
  String toString() => '合同数据未通过校验，请重新读取。';
}

final _contractId =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _sha256 = RegExp(r'^[0-9a-f]{64}$');
const contractStates = {
  'PENDING_REVIEW',
  'AWAITING_CUSTOMER',
  'APPLIED',
  'REJECTED'
};

bool isContractId(String value) => _contractId.hasMatch(value);

Never _invalid() => throw const ContractProtocolException();

/// A tenant projection deliberately has no platform operator identities.
class ContractReview {
  final String id, tenantId, offerId, contractReference, state, buyerReference;
  final String capacityKind, sourceState;
  final String evidenceHash;
  final String? submittedBy, approvedBy, acceptedBy;
  final int offerRevision, sourceRevision, version, deviceCapacity;
  final int activeFrom, expiresAt, executedAt, createdAt, updatedAt;
  final List<String> features;
  final bool entitlementApplied;

  ContractReview._(Json raw)
      : id = raw['id'],
        tenantId = raw['tenantId'],
        offerId = raw['offerId'],
        contractReference = raw['contractReference'],
        state = raw['state'],
        buyerReference = raw['buyerReference'],
        capacityKind = raw['capacityKind'],
        sourceState = raw['sourceState'],
        evidenceHash = raw['evidenceHash'],
        submittedBy = raw['submittedBy'],
        approvedBy = raw['approvedBy'],
        acceptedBy = raw['acceptedBy'],
        offerRevision = raw['offerRevision'],
        sourceRevision = raw['sourceRevision'],
        version = raw['version'],
        deviceCapacity = raw['deviceCapacity'],
        activeFrom = raw['activeFrom'],
        expiresAt = raw['expiresAt'],
        executedAt = raw['executedAt'],
        createdAt = raw['createdAt'],
        updatedAt = raw['updatedAt'],
        features = List<String>.unmodifiable(raw['features']),
        entitlementApplied = raw['entitlementApplied'];

  static ContractReview parse(dynamic raw, {required bool platform}) {
    if (raw is! Json ||
        !['offerRevision', 'sourceRevision', 'version']
            .every((k) => _safeVersion(raw[k])) ||
        !['activeFrom', 'expiresAt', 'executedAt', 'createdAt', 'updatedAt']
            .every((k) => _safeDate(raw[k])) ||
        raw['id'] is! String ||
        !isContractId(raw['id']) ||
        raw['tenantId'] is! String ||
        !isContractId(raw['tenantId']) ||
        raw['offerId'] is! String ||
        !isContractId(raw['offerId']) ||
        raw['contractReference'] is! String ||
        (raw['contractReference'] as String).trim().isEmpty ||
        (raw['contractReference'] as String).length > 200 ||
        !contractStates.contains(raw['state']) ||
        raw['buyerReference'] is! String ||
        (raw['buyerReference'] as String).trim().isEmpty ||
        (raw['buyerReference'] as String).length > 200 ||
        raw['capacityKind'] is! String ||
        !['BASE', 'ADD_ON'].contains(raw['capacityKind']) ||
        raw['sourceState'] is! String ||
        !['ACTIVE', 'REVOKED'].contains(raw['sourceState']) ||
        (raw['sourceState'] == 'REVOKED' &&
            raw['state'] == 'AWAITING_CUSTOMER') ||
        raw['offerRevision'] is! int ||
        raw['offerRevision'] < 1 ||
        raw['sourceRevision'] is! int ||
        raw['sourceRevision'] < 1 ||
        raw['version'] is! int ||
        raw['version'] < 1 ||
        raw['deviceCapacity'] is! int ||
        raw['deviceCapacity'] < 0 ||
        raw['deviceCapacity'] > 1000000 ||
        raw['activeFrom'] is! int ||
        raw['activeFrom'] < 0 ||
        raw['expiresAt'] is! int ||
        raw['expiresAt'] <= raw['activeFrom'] ||
        raw['executedAt'] is! int ||
        raw['executedAt'] < 0 ||
        raw['evidenceHash'] is! String ||
        !_sha256.hasMatch(raw['evidenceHash']) ||
        raw['createdAt'] is! int ||
        raw['createdAt'] < 0 ||
        raw['updatedAt'] is! int ||
        raw['updatedAt'] < raw['createdAt'] ||
        raw['features'] is! List ||
        (raw['features'] as List).any(
            (item) => item is! String || !catalogFeatures.contains(item)) ||
        (raw['features'] as List).toSet().length !=
            (raw['features'] as List).length ||
        raw['entitlementApplied'] is! bool ||
        (raw['entitlementApplied'] != (raw['state'] == 'APPLIED')) ||
        (!platform &&
            (raw.containsKey('submittedBy') ||
                raw.containsKey('approvedBy') ||
                raw.containsKey('acceptedBy'))) ||
        (platform &&
            (raw['submittedBy'] is! String ||
                (raw['approvedBy'] != null && raw['approvedBy'] is! String) ||
                (raw['acceptedBy'] != null && raw['acceptedBy'] is! String)))) {
      _invalid();
    }
    return ContractReview._(raw);
  }
}

class ContractReviewPage {
  final List<ContractReview> items;
  final String? nextCursor;
  const ContractReviewPage(this.items, this.nextCursor);

  static ContractReviewPage parse(dynamic raw, {required bool platform}) {
    if (raw is! Json ||
        raw['items'] is! List ||
        (raw['nextCursor'] != null &&
            (raw['nextCursor'] is! String ||
                !isContractId(raw['nextCursor'])))) {
      _invalid();
    }
    final items = (raw['items'] as List)
        .map((item) => ContractReview.parse(item, platform: platform))
        .toList();
    if (items.length > 50 ||
        items.map((item) => item.id).toSet().length != items.length) {
      _invalid();
    }
    return ContractReviewPage(List.unmodifiable(items), raw['nextCursor']);
  }
}

class ContractCapabilities {
  final bool submissionEnabled, revocationSubmissionEnabled;
  const ContractCapabilities(
      this.submissionEnabled, this.revocationSubmissionEnabled);

  bool get canSubmit => submissionEnabled || revocationSubmissionEnabled;

  static ContractCapabilities parse(dynamic raw) {
    if (raw is! Json ||
        raw['submissionEnabled'] is! bool ||
        raw['revocationSubmissionEnabled'] is! bool ||
        raw['region'] != 'CN' ||
        raw['channel'] != 'CONTRACT' ||
        raw['recentAuthenticationRequired'] != true ||
        raw['independentApprovalRequired'] != true ||
        raw['customerAcceptanceRequired'] != true) _invalid();
    return ContractCapabilities(
        raw['submissionEnabled'], raw['revocationSubmissionEnabled']);
  }
}

const contractComparisonIssues = {
  'OFFER_MISSING',
  'REVISION_CHANGED',
  'OFFER_NOT_APPROVED',
  'SALES_SCOPE_CHANGED',
  'CAPACITY_KIND_CHANGED',
  'CAPACITY_CHANGED',
  'FEATURES_CHANGED',
  'CONTRACT_EXPIRED',
  'SIGNATURE_OUTSIDE_OFFER_WINDOW'
};

/// A current catalog snapshot for review. The write path rechecks it under a database lock.
class ContractComparison {
  final String reviewId, offerId, offerState;
  final int reviewVersion, contractOfferRevision;
  final int? currentOfferRevision;
  final bool factsMatch;
  final List<String> issues;
  final ContractOfferTerms? offer;

  ContractComparison._(Json raw)
      : reviewId = raw['reviewId'],
        offerId = raw['offerId'],
        offerState = raw['offerState'],
        reviewVersion = raw['reviewVersion'],
        contractOfferRevision = raw['contractOfferRevision'],
        currentOfferRevision = raw['currentOfferRevision'],
        factsMatch = raw['factsMatch'],
        issues = List<String>.unmodifiable(raw['issues']),
        offer = raw['offer'] == null
            ? null
            : ContractOfferTerms.parse(raw['offer']);

  static ContractComparison parse(dynamic raw) {
    if (raw is! Json ||
        !_safeVersion(raw['reviewVersion']) ||
        !_safeVersion(raw['contractOfferRevision']) ||
        (raw['currentOfferRevision'] != null &&
            !_safeVersion(raw['currentOfferRevision'])) ||
        raw['reviewId'] is! String ||
        !isContractId(raw['reviewId']) ||
        raw['offerId'] is! String ||
        !isContractId(raw['offerId']) ||
        raw['reviewVersion'] is! int ||
        raw['reviewVersion'] < 1 ||
        raw['contractOfferRevision'] is! int ||
        raw['contractOfferRevision'] < 1 ||
        ![...catalogStates, 'MISSING'].contains(raw['offerState']) ||
        raw['factsMatch'] is! bool ||
        raw['issues'] is! List ||
        (raw['issues'] as List).any((issue) =>
            issue is! String || !contractComparisonIssues.contains(issue)) ||
        (raw['issues'] as List).toSet().length != raw['issues'].length ||
        raw['factsMatch'] != (raw['issues'] as List).isEmpty ||
        (raw['offerState'] == 'MISSING'
            ? raw['offer'] != null ||
                raw['currentOfferRevision'] != null ||
                !raw['issues'].contains('OFFER_MISSING')
            : raw['offer'] == null ||
                raw['currentOfferRevision'] is! int ||
                raw['currentOfferRevision'] < 1)) _invalid();
    return ContractComparison._(raw);
  }
}

class ContractOfferTerms {
  final String sku, platform, deviceMode, billingPeriod, capacityKind;
  final int deviceCapacity, availableFrom, availableUntil;
  final List<String> features;

  ContractOfferTerms._(Json raw)
      : sku = raw['sku'],
        platform = raw['platform'],
        deviceMode = raw['deviceMode'],
        billingPeriod = raw['billingPeriod'],
        capacityKind = raw['capacityKind'],
        deviceCapacity = raw['deviceCapacity'],
        availableFrom = raw['availableFrom'],
        availableUntil = raw['availableUntil'],
        features = List<String>.unmodifiable(raw['features']);

  static ContractOfferTerms parse(dynamic raw) {
    if (raw is! Json ||
        !_safeDate(raw['availableFrom']) ||
        !_safeDate(raw['availableUntil']) ||
        raw['sku'] is! String ||
        !RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(raw['sku']) ||
        !catalogPlatforms.contains(raw['platform']) ||
        !catalogDeviceModes.contains(raw['deviceMode']) ||
        !catalogBillingPeriods.contains(raw['billingPeriod']) ||
        !['BASE', 'ADD_ON'].contains(raw['capacityKind']) ||
        raw['deviceCapacity'] is! int ||
        raw['deviceCapacity'] < 0 ||
        raw['deviceCapacity'] > 1000000 ||
        raw['features'] is! List ||
        (raw['features'] as List).any((feature) =>
            feature is! String || !catalogFeatures.contains(feature)) ||
        (raw['features'] as List).toSet().length != raw['features'].length ||
        raw['availableFrom'] is! int ||
        raw['availableFrom'] < 0 ||
        raw['availableUntil'] is! int ||
        raw['availableUntil'] <= raw['availableFrom']) _invalid();
    return ContractOfferTerms._(raw);
  }
}

String contractComparisonIssueLabel(String issue) => switch (issue) {
      'OFFER_MISSING' => '当前报价不存在',
      'REVISION_CHANGED' => '报价版本已变化',
      'OFFER_NOT_APPROVED' => '报价不在可审核状态',
      'SALES_SCOPE_CHANGED' => '销售地区、渠道或采购类型不符',
      'CAPACITY_KIND_CHANGED' => '名额类型不一致',
      'CAPACITY_CHANGED' => '设备名额不一致',
      'FEATURES_CHANGED' => '授权功能不一致',
      'CONTRACT_EXPIRED' => '签约服务期已结束',
      'SIGNATURE_OUTSIDE_OFFER_WINDOW' => '签约时间不在报价有效期内',
      _ => '需要人工核对'
    };

const contractActions = {
  'SUBMITTED',
  'APPROVED',
  'REJECTED',
  'CUSTOMER_ACCEPTED',
  'REVOKED'
};

class ContractHistory {
  final int version, occurredAt;
  final String action;
  final String? reason, actorId, eventId, correlationId;
  ContractHistory._(Json raw)
      : version = raw['version'],
        occurredAt = raw['occurredAt'],
        action = raw['action'],
        reason = raw['reason'],
        actorId = raw['actorId'],
        eventId = raw['eventId'],
        correlationId = raw['correlationId'];

  static ContractHistory parse(dynamic raw, {required bool platform}) {
    if (raw is! Json ||
        !_safeVersion(raw['version']) ||
        !_safeDate(raw['occurredAt']) ||
        raw['version'] is! int ||
        raw['version'] < 1 ||
        raw['occurredAt'] is! int ||
        raw['occurredAt'] < 0 ||
        !contractActions.contains(raw['action']) ||
        (raw['reason'] != null && raw['reason'] is! String) ||
        (platform &&
            (raw['actorId'] is! String ||
                raw['eventId'] is! String ||
                !isContractId(raw['eventId']) ||
                raw['correlationId'] is! String ||
                !isContractId(raw['correlationId']))) ||
        (!platform &&
            (raw.containsKey('reason') ||
                raw.containsKey('actorId') ||
                raw.containsKey('eventId') ||
                raw.containsKey('correlationId')))) _invalid();
    return ContractHistory._(raw);
  }
}

class ContractHistoryPage {
  final List<ContractHistory> items;
  final int? nextBeforeVersion;
  const ContractHistoryPage(this.items, this.nextBeforeVersion);

  static ContractHistoryPage parse(dynamic raw, {required bool platform}) {
    if (raw is! Json ||
        raw['items'] is! List ||
        (raw['nextBeforeVersion'] != null &&
            (raw['nextBeforeVersion'] is! int ||
                raw['nextBeforeVersion'] < 1))) {
      _invalid();
    }
    final items = (raw['items'] as List)
        .map((item) => ContractHistory.parse(item, platform: platform))
        .toList();
    if (items.length > 50 ||
        items.map((item) => item.version).toSet().length != items.length ||
        (raw['nextBeforeVersion'] != null &&
            (items.isEmpty ||
                items.last.version != raw['nextBeforeVersion']))) {
      _invalid();
    }
    for (var index = 1; index < items.length; index++) {
      if (items[index - 1].version <= items[index].version) _invalid();
    }
    return ContractHistoryPage(
        List.unmodifiable(items), raw['nextBeforeVersion']);
  }
}

String contractStateLabel(String state) => switch (state) {
      'PENDING_REVIEW' => '待独立审核',
      'AWAITING_CUSTOMER' => '待机构确认',
      'APPLIED' => '已处理',
      'REJECTED' => '已驳回',
      _ => '未知状态'
    };

String contractReviewLabel(ContractReview review) => review.state == 'APPLIED'
    ? review.sourceState == 'REVOKED'
        ? '撤销已执行'
        : '合同已应用'
    : contractStateLabel(review.state);

String contractActionLabel(String action) => switch (action) {
      'SUBMITTED' => '已提交核验',
      'APPROVED' => '独立审核通过',
      'REJECTED' => '独立审核驳回',
      'CUSTOMER_ACCEPTED' => '机构已确认',
      'REVOKED' => '撤销已执行',
      _ => '未知事件'
    };
