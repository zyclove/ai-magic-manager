import 'package:parent/core/parent_api.dart';

const tenant = '11111111-1111-1111-1111-111111111111';
const reviewId = '22222222-2222-2222-2222-222222222222';
const offerId = '33333333-3333-3333-3333-333333333333';

Json review(
        {bool platform = false,
        String state = 'AWAITING_CUSTOMER',
        int version = 1,
        String sourceState = 'ACTIVE'}) =>
    {
      'id': reviewId,
      'tenantId': tenant,
      'offerId': offerId,
      'offerRevision': 3,
      'contractReference': 'CN-2026-01',
      'sourceRevision': 1,
      'state': state,
      'version': version,
      'buyerReference': 'buyer-1',
      'capacityKind': 'BASE',
      'deviceCapacity': 25,
      'features': ['ORG_BULK'],
      'activeFrom': 1791619200000,
      'expiresAt': 1823155200000,
      'sourceState': sourceState,
      'executedAt': 1791619200000,
      'evidenceHash': 'a' * 64,
      'createdAt': 100,
      'updatedAt': 200,
      'entitlementApplied': state == 'APPLIED',
      if (platform) ...{
        'submittedBy': 'contract-author',
        'approvedBy': state == 'PENDING_REVIEW' ? null : 'contract-approver',
        'acceptedBy':
            state == 'APPLIED' && sourceState == 'ACTIVE' ? 'org-owner' : null
      }
    };

Json comparison({int version = 1, bool match = true}) => {
      'reviewId': reviewId,
      'reviewVersion': version,
      'offerId': offerId,
      'contractOfferRevision': 3,
      'currentOfferRevision': match ? 3 : 4,
      'offerState': 'APPROVED',
      'factsMatch': match,
      'issues': match ? <String>[] : ['REVISION_CHANGED'],
      'offer': {
        'sku': 'ORG_STANDARD',
        'platform': 'ANDROID',
        'deviceMode': 'FULLY_MANAGED',
        'billingPeriod': 'YEAR',
        'capacityKind': 'BASE',
        'deviceCapacity': 25,
        'features': ['ORG_BULK'],
        'availableFrom': 100,
        'availableUntil': 500
      }
    };
