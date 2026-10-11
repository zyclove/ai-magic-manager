import 'package:device_identity/device_identity.dart'
    show validUuid, safeInteger;
import 'models.dart';
import 'verifier.dart';

enum CleanupReceiptStage { received, agentDataCleared, failed }

/// The caller must persist this exact receipt ID and body before sending it.
/// Retries use the same object; a new ID after an unknown outcome is unsafe.
class CleanupReceipt {
  final VerifiedCleanupCommand command;
  final String receiptId;
  final CleanupReceiptStage stage;
  final String? reasonCode;
  CleanupReceipt(this.command, this.receiptId, this.stage, {this.reasonCode}) {
    if (!validUuid(receiptId) ||
        (stage == CleanupReceiptStage.failed) != (reasonCode != null) ||
        (reasonCode != null &&
            !const {
              'STORAGE_FAILURE',
              'KEY_UNAVAILABLE',
              'UNSUPPORTED_AGENT',
              'USER_ACTION_REQUIRED'
            }.contains(reasonCode))) {
      throw ArgumentError('Invalid cleanup receipt');
    }
  }

  String get wireStage => switch (stage) {
        CleanupReceiptStage.received => 'RECEIVED',
        CleanupReceiptStage.agentDataCleared => 'AGENT_DATA_CLEARED',
        CleanupReceiptStage.failed => 'FAILED'
      };
  Map<String, dynamic> get body => {
        'receiptId': receiptId,
        'commandId': command.commandId,
        'commandHash': command.commandHash,
        'stage': wireStage,
        'reasonCode': reasonCode
      };
  @override
  String toString() => 'CleanupReceipt(redacted)';
}

/// A server response confirms acceptance of this receipt. Its state is a
/// snapshot and may already be stale; do not present it as live device state.
class CleanupReceiptAck {
  final String operationId, receiptId, state, localEvidence;
  final int version;
  const CleanupReceiptAck._(this.operationId, this.receiptId, this.state,
      this.localEvidence, this.version);

  static CleanupReceiptAck parse(
      Map<String, dynamic> value, CleanupReceipt receipt) {
    final command = receipt.command;
    const fields = {
      'id',
      'deviceId',
      'registrationId',
      'commandId',
      'action',
      'state',
      'remoteAccess',
      'localEvidence',
      'reasonCode',
      'issuedAt',
      'notAfter',
      'version'
    };
    if (value.length != fields.length ||
        value.keys.any((field) => !fields.contains(field)) ||
        value['id'] != command.operationId ||
        value['deviceId'] != command.scope.deviceId ||
        value['registrationId'] != command.scope.registrationId ||
        value['commandId'] != command.commandId ||
        value['action'] != 'AGENT_UNENROLL' ||
        value['remoteAccess'] != 'REVOKED' ||
        value['issuedAt'] != command.issuedAt ||
        value['notAfter'] != command.notAfter ||
        !safeInteger(value['version']) ||
        !const {'COMMAND_RECEIVED', 'CLEANUP_FAILED', 'CLEANUP_REPORTED'}
            .contains(value['state']) ||
        !const {'NONE', 'DEVICE_REPORT_UNVERIFIED'}
            .contains(value['localEvidence']) ||
        value['reasonCode'] != null &&
            !const {
              'STORAGE_FAILURE',
              'KEY_UNAVAILABLE',
              'UNSUPPORTED_AGENT',
              'USER_ACTION_REQUIRED'
            }.contains(value['reasonCode']) ||
        receipt.stage == CleanupReceiptStage.agentDataCleared &&
            (value['state'] != 'CLEANUP_REPORTED' ||
                value['localEvidence'] != 'DEVICE_REPORT_UNVERIFIED' ||
                value['reasonCode'] != null) ||
        receipt.stage == CleanupReceiptStage.failed &&
            (value['state'] != 'CLEANUP_FAILED' ||
                value['localEvidence'] != 'DEVICE_REPORT_UNVERIFIED' ||
                value['reasonCode'] != receipt.reasonCode)) {
      throw const CleanupFailure('CLEANUP_ACK_INVALID', outcomeUnknown: true);
    }
    return CleanupReceiptAck._(command.operationId, receipt.receiptId,
        value['state'], value['localEvidence'], value['version']);
  }

  @override
  String toString() => 'CleanupReceiptAck(redacted)';
}
