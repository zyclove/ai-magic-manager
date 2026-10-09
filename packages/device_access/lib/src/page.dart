import 'models.dart';

class AccessReference {
  final String requestId, approvalState;
  final int approvalVersion, absoluteNotAfter;
  const AccessReference._(this.requestId, this.approvalState,
      this.approvalVersion, this.absoluteNotAfter);
  factory AccessReference.fromJson(Map<String, dynamic> json) {
    if (!accessId(json['requestId']) ||
        !{'APPROVED_PENDING_DELIVERY', 'REVOKED', 'EXPIRED'}
            .contains(json['approvalState']) ||
        !accessInteger(json['approvalVersion'], 1) ||
        !accessInteger(json['absoluteNotAfter'], 1)) {
      throw const AccessFailure('TRANSPORT_INVALID');
    }
    return AccessReference._(json['requestId'], json['approvalState'],
        json['approvalVersion'], json['absoluteNotAfter']);
  }
  void requireMatch(VerifiedAccessWindow value) {
    if (value.requestId != requestId ||
        value.approvalVersion < approvalVersion ||
        value.absoluteNotAfter != absoluteNotAfter ||
        (value.approvalVersion == approvalVersion &&
            value.fields['approvalState'] != approvalState)) {
      throw const AccessFailure('TRANSPORT_MISMATCH');
    }
  }
}

/// UUID ordering is a full-scan cursor, never a change-feed watermark.
class AccessReferencePage {
  final List<AccessReference> items;
  final String? nextCursor;
  const AccessReferencePage._(this.items, this.nextCursor);
  factory AccessReferencePage.fromJson(Map<String, dynamic> json,
      {required String? after, required int limit}) {
    if (limit < 1 || limit > 100 || (after != null && !accessId(after))) {
      throw ArgumentError('Invalid access page context');
    }
    final items = json['items'];
    final next = json['nextCursor'];
    if (items is! List ||
        items.length > limit ||
        (next != null && !accessId(next)) ||
        !json.containsKey('nextCursor')) {
      throw const AccessFailure('TRANSPORT_INVALID');
    }
    final result = <AccessReference>[];
    String? previous = after;
    for (final item in items) {
      if (item is! Map<String, dynamic>) {
        throw const AccessFailure('TRANSPORT_INVALID');
      }
      final reference = AccessReference.fromJson(item);
      if (previous != null && reference.requestId.compareTo(previous) <= 0) {
        throw const AccessFailure('TRANSPORT_INVALID');
      }
      result.add(reference);
      previous = reference.requestId;
    }
    if (next != null && (result.length != limit || next != previous)) {
      throw const AccessFailure('TRANSPORT_INVALID');
    }
    return AccessReferencePage._(List.unmodifiable(result), next);
  }
}

class AccessRetryResult {
  final String documentId;
  final int deliveryAttempt, createdAt;
  final bool current;
  const AccessRetryResult._(
      this.documentId, this.deliveryAttempt, this.createdAt, this.current);
  factory AccessRetryResult.fromJson(Map<String, dynamic> json,
      {required String documentId, required int failedAttempt}) {
    if (!accessId(documentId) || failedAttempt < 1 || failedAttempt > 9) {
      throw ArgumentError('Invalid access retry context');
    }
    if (json['documentId'] != documentId ||
        !accessInteger(json['deliveryAttempt'], 1) ||
        json['deliveryAttempt'] != failedAttempt + 1 ||
        !accessInteger(json['createdAt'], 0) ||
        json['current'] is! bool) {
      throw const AccessFailure('TRANSPORT_INVALID');
    }
    return AccessRetryResult._(
        documentId, failedAttempt + 1, json['createdAt'], json['current']);
  }
}
