import 'models.dart';

/// A durable terminal receipt. The URL uses requestId; the body only contains
/// fields accepted by the device receipt endpoint.
class AccessReceipt {
  final String requestId, documentId, phase;
  final String? reasonCode;
  final int approvalVersion, deliveryAttempt;
  const AccessReceipt.internal(this.requestId, this.documentId,
      this.approvalVersion, this.deliveryAttempt, this.phase, this.reasonCode);
  String get key => '$documentId:$deliveryAttempt:$phase';
  Map<String, dynamic> toJson() => {
        'documentId': documentId,
        'deliveryAttempt': deliveryAttempt,
        'phase': phase,
        if (reasonCode != null) 'reasonCode': reasonCode
      };
}

/// Only construct from a response of the authenticated device transport.
class AccessReceiptAcknowledgement {
  final String documentId, phase;
  final int approvalVersion, deliveryAttempt, receivedAt;
  final bool current;
  const AccessReceiptAcknowledgement._(
      this.documentId,
      this.phase,
      this.approvalVersion,
      this.deliveryAttempt,
      this.receivedAt,
      this.current);
  factory AccessReceiptAcknowledgement.fromJson(Map<String, dynamic> json) {
    if (!accessId(json['documentId']) ||
        !{'STORED', 'REJECTED'}.contains(json['phase']) ||
        !accessInteger(json['approvalVersion'], 1) ||
        !accessInteger(json['deliveryAttempt'], 1) ||
        json['deliveryAttempt'] > 10 ||
        !accessInteger(json['receivedAt'], 0) ||
        json['current'] is! bool ||
        json['evidenceStatus'] != 'DEVICE_REPORT_UNVERIFIED' ||
        json['executionState'] != 'NOT_ENFORCED') {
      throw const AccessFailure('ACK_INVALID');
    }
    return AccessReceiptAcknowledgement._(
        json['documentId'],
        json['phase'],
        json['approvalVersion'],
        json['deliveryAttempt'],
        json['receivedAt'],
        json['current']);
  }
  String get key => '$documentId:$deliveryAttempt:$phase';
  bool matches(AccessReceipt receipt) =>
      documentId == receipt.documentId &&
      phase == receipt.phase &&
      approvalVersion == receipt.approvalVersion &&
      deliveryAttempt == receipt.deliveryAttempt;
}
