package com.aimanager.delivery;

import com.aimanager.fleet.Device;
import java.util.List;

/** Current-registration metadata only; no configuration document, JWS or receipt body. */
public interface DeliveryDiagnosticSource {
  /** Caller retains member, subject and device lifecycle locks through response serialization. */
  List<Item> forAuthorizedDevice(String tenantId, Device device);

  record Item(
      String id,
      String policyId,
      String versionId,
      long sourceSequence,
      String action,
      String deliveryState,
      String envelopeHash,
      long issuedAt,
      long deliveryExpiresAt,
      Long receivedReportedAt,
      Long storedReportedAt,
      String rejectionCode) {}
}
