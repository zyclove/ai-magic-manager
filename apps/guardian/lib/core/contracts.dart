import 'api.dart';
import 'commercial_catalog.dart' show catalogFeatures;

final _contractId =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
const contractStates = {
  'PENDING_REVIEW',
  'AWAITING_CUSTOMER',
  'APPLIED',
  'REJECTED'
};

bool isContractId(String value) => _contractId.hasMatch(value);

Never _invalid() => throw const ApiFailure(502, 'INVALID_CONTRACT_RESPONSE');

/// A tenant projection deliberately has no platform operator identities.
class ContractReview {
  final String id, tenantId, offerId, contractReference, state, buyerReference;
  final String capacityKind, sourceState;
  final String? submittedBy, approvedBy, acceptedBy;
  final int offerRevision, sourceRevision, version, deviceCapacity;
  final int activeFrom, expiresAt, createdAt, updatedAt;
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
        submittedBy = raw['submittedBy'],
        approvedBy = raw['approvedBy'],
        acceptedBy = raw['acceptedBy'],
        offerRevision = raw['offerRevision'],
        sourceRevision = raw['sourceRevision'],
        version = raw['version'],
        deviceCapacity = raw['deviceCapacity'],
        activeFrom = raw['activeFrom'],
        expiresAt = raw['expiresAt'],
        createdAt = raw['createdAt'],
        updatedAt = raw['updatedAt'],
        features = List<String>.unmodifiable(raw['features']),
        entitlementApplied = raw['entitlementApplied'];

  static ContractReview parse(dynamic raw, {required bool platform}) {
    if (raw is! Json ||
        raw['id'] is! String ||
        !isContractId(raw['id']) ||
        raw['tenantId'] is! String ||
        !isContractId(raw['tenantId']) ||
        raw['offerId'] is! String ||
        !isContractId(raw['offerId']) ||
        raw['contractReference'] is! String ||
        (raw['contractReference'] as String).isEmpty ||
        !contractStates.contains(raw['state']) ||
        raw['buyerReference'] is! String ||
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
  final bool submissionEnabled;
  const ContractCapabilities(this.submissionEnabled);

  static ContractCapabilities parse(dynamic raw) {
    if (raw is! Json ||
        raw['submissionEnabled'] is! bool ||
        raw['region'] != 'CN' ||
        raw['channel'] != 'CONTRACT' ||
        raw['recentAuthenticationRequired'] != true ||
        raw['independentApprovalRequired'] != true ||
        raw['customerAcceptanceRequired'] != true) _invalid();
    return ContractCapabilities(raw['submissionEnabled']);
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
        : '权益已生效'
    : contractStateLabel(review.state);
