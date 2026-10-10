import 'api.dart';

const catalogChannels = [
  'GOOGLE_PLAY',
  'APP_STORE',
  'CONTRACT',
  'PRIVATE_LICENSE'
];
const catalogBuyerKinds = ['FAMILY', 'ORGANIZATION'];
const catalogPlatforms = ['ANDROID', 'ANDROID_TV', 'IOS', 'WINDOWS', 'MACOS'];
const catalogDeviceModes = [
  'BYOD',
  'WORK_PROFILE',
  'FULLY_MANAGED',
  'DEDICATED'
];
const catalogBillingPeriods = ['MONTH', 'YEAR', 'ONE_TIME'];
const catalogPriceTypes = ['FIXED', 'QUOTE'];
const catalogTaxBases = ['INCLUSIVE', 'EXCLUSIVE', 'QUOTE_REQUIRED'];
const catalogCapacityKinds = ['BASE', 'ADD_ON'];
const catalogFeatures = [
  'ADVANCED_SCHEDULES',
  'WEB_FILTERING',
  'MANAGED_ANDROID',
  'ORG_BULK',
  'AI_INSIGHTS'
];
const catalogStates = ['DRAFT', 'IN_REVIEW', 'APPROVED', 'RETIRED'];

final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _sku = RegExp(r'^[A-Z0-9_]{1,80}$');
final _region = RegExp(r'^[A-Z]{2}$');
final _currency = RegExp(r'^[A-Z]{3}$');

Never _invalid() => throw const ApiFailure(502, 'INVALID_CATALOG_RESPONSE');
bool isCatalogId(String value) => _uuid.hasMatch(value);

/// Immutable server snapshot. Approval is deliberately separate from sales eligibility.
class CatalogOffer {
  final String id, state, createdBy, lastEditor;
  final String? approvedBy;
  final int revision, createdAt, updatedAt;
  final Map<String, dynamic> offer;

  const CatalogOffer._(
      this.id,
      this.state,
      this.revision,
      this.offer,
      this.createdBy,
      this.lastEditor,
      this.approvedBy,
      this.createdAt,
      this.updatedAt);

  static CatalogOffer parse(dynamic raw) {
    if (raw is! Json ||
        raw['id'] is! String ||
        !isCatalogId(raw['id']) ||
        !catalogStates.contains(raw['state']) ||
        raw['revision'] is! int ||
        raw['revision'] < 1 ||
        raw['createdBy'] is! String ||
        raw['lastEditor'] is! String ||
        raw['createdBy'].isEmpty ||
        raw['lastEditor'].isEmpty ||
        (raw['approvedBy'] != null && raw['approvedBy'] is! String) ||
        raw['createdAt'] is! int ||
        raw['updatedAt'] is! int ||
        raw['createdAt'] < 0 ||
        raw['updatedAt'] < raw['createdAt'] ||
        raw['purchaseAvailable'] != false) _invalid();
    final draft = CatalogDraft.fromServer(raw['offer']);
    return CatalogOffer._(
        raw['id'],
        raw['state'],
        raw['revision'],
        Map.unmodifiable(draft.toJson()),
        raw['createdBy'],
        raw['lastEditor'],
        raw['approvedBy'],
        raw['createdAt'],
        raw['updatedAt']);
  }
}

/// The complete operator-authored payload; the server remains the final validator.
class CatalogDraft {
  final Map<String, dynamic> fields;
  const CatalogDraft(this.fields);

  factory CatalogDraft.fromServer(dynamic raw) {
    if (raw is! Json ||
        raw['sku'] is! String ||
        !_sku.hasMatch(raw['sku']) ||
        raw['skuVersion'] is! int ||
        raw['skuVersion'] < 1 ||
        raw['region'] is! String ||
        !_region.hasMatch(raw['region']) ||
        !catalogChannels.contains(raw['channel']) ||
        !catalogBuyerKinds.contains(raw['buyerKind']) ||
        !catalogPlatforms.contains(raw['platform']) ||
        !catalogDeviceModes.contains(raw['deviceMode']) ||
        !catalogBillingPeriods.contains(raw['billingPeriod']) ||
        !catalogPriceTypes.contains(raw['priceType']) ||
        raw['currency'] is! String ||
        !_currency.hasMatch(raw['currency']) ||
        !catalogTaxBases.contains(raw['taxBasis']) ||
        !catalogCapacityKinds.contains(raw['capacityKind']) ||
        raw['deviceCapacity'] is! int ||
        raw['deviceCapacity'] < 0 ||
        raw['features'] is! List ||
        raw['availableFrom'] is! int ||
        raw['availableUntil'] is! int ||
        raw['availableUntil'] <= raw['availableFrom']) _invalid();
    final features = <String>{};
    for (final feature in raw['features']) {
      if (feature is! String ||
          !catalogFeatures.contains(feature) ||
          !features.add(feature)) _invalid();
    }
    final price = raw['priceMinor'];
    if (raw['priceType'] == 'FIXED'
        ? price is! int || price < 0
        : price != null || raw['taxBasis'] != 'QUOTE_REQUIRED') _invalid();
    return CatalogDraft(Map.unmodifiable({
      for (final key in const [
        'sku',
        'skuVersion',
        'region',
        'channel',
        'buyerKind',
        'platform',
        'deviceMode',
        'billingPeriod',
        'priceType',
        'currency',
        'priceMinor',
        'taxBasis',
        'capacityKind',
        'deviceCapacity',
        'availableFrom',
        'availableUntil'
      ])
        key: raw[key],
      'features': features.toList()..sort()
    }));
  }

  Map<String, dynamic> toJson() => Map<String, dynamic>.from(fields);
}

class CatalogHistory {
  final int revision, occurredAt;
  final String eventId, action, actorId, correlationId, payloadHash;
  final String? reason;
  final CatalogDraft offer;

  const CatalogHistory._(
      this.revision,
      this.eventId,
      this.action,
      this.actorId,
      this.reason,
      this.correlationId,
      this.payloadHash,
      this.offer,
      this.occurredAt);

  static CatalogHistory parse(dynamic raw) {
    if (raw is! Json ||
        raw['revision'] is! int ||
        raw['revision'] < 1 ||
        raw['eventId'] is! String ||
        !isCatalogId(raw['eventId']) ||
        !['CREATED', 'REVISED', 'SUBMITTED', 'APPROVED', 'RETIRED']
            .contains(raw['action']) ||
        raw['actorId'] is! String ||
        raw['actorId'].isEmpty ||
        (raw['reason'] != null && raw['reason'] is! String) ||
        raw['correlationId'] is! String ||
        !isCatalogId(raw['correlationId']) ||
        raw['payloadHash'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(raw['payloadHash']) ||
        raw['occurredAt'] is! int ||
        raw['occurredAt'] < 0) _invalid();
    return CatalogHistory._(
        raw['revision'],
        raw['eventId'],
        raw['action'],
        raw['actorId'],
        raw['reason'],
        raw['correlationId'],
        raw['payloadHash'],
        CatalogDraft.fromServer(raw['offer']),
        raw['occurredAt']);
  }
}

class CatalogOfferPage {
  final List<CatalogOffer> items;
  final String? nextCursor;
  const CatalogOfferPage(this.items, this.nextCursor);

  static CatalogOfferPage parse(dynamic raw) {
    if (raw is! Json ||
        raw['items'] is! List ||
        raw['items'].length > 100 ||
        (raw['nextCursor'] != null &&
            (raw['nextCursor'] is! String ||
                !isCatalogId(raw['nextCursor'])))) {
      _invalid();
    }
    final items = (raw['items'] as List).map(CatalogOffer.parse).toList();
    for (var i = 1; i < items.length; i++) {
      if (items[i - 1].id.compareTo(items[i].id) >= 0) {
        _invalid();
      }
    }
    if (items.isEmpty && raw['nextCursor'] != null) {
      _invalid();
    }
    if (raw['nextCursor'] != null && raw['nextCursor'] != items.last.id) {
      _invalid();
    }
    return CatalogOfferPage(List.unmodifiable(items), raw['nextCursor']);
  }
}

class CatalogHistoryPage {
  final List<CatalogHistory> items;
  final int? nextBeforeRevision;
  const CatalogHistoryPage(this.items, this.nextBeforeRevision);

  static CatalogHistoryPage parse(dynamic raw) {
    if (raw is! Json ||
        raw['items'] is! List ||
        raw['items'].length > 100 ||
        (raw['nextBeforeRevision'] != null &&
            (raw['nextBeforeRevision'] is! int ||
                raw['nextBeforeRevision'] < 1))) _invalid();
    final items = (raw['items'] as List).map(CatalogHistory.parse).toList();
    for (var i = 1; i < items.length; i++) {
      if (items[i - 1].revision <= items[i].revision) _invalid();
    }
    if (items.isEmpty && raw['nextBeforeRevision'] != null) {
      _invalid();
    }
    if (raw['nextBeforeRevision'] != null &&
        raw['nextBeforeRevision'] != items.last.revision) _invalid();
    return CatalogHistoryPage(
        List.unmodifiable(items), raw['nextBeforeRevision']);
  }
}
