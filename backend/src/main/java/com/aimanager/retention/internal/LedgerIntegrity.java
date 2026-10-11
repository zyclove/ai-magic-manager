package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HexFormat;

final class LedgerIntegrity {
  private LedgerIntegrity() {}

  static String hash(String value) {
    try {
      return HexFormat.of()
          .formatHex(
              MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));
    } catch (NoSuchAlgorithmException impossible) {
      throw new IllegalStateException("SHA-256 unavailable", impossible);
    }
  }

  static String genesis(String ledgerId) {
    return hash("ai-manager-erasure-ledger-v1|" + ledgerId);
  }

  static String requestHash(ErasureLedger.Request request) {
    var canonical =
        new StringBuilder("erasure-request-v1|")
            .append(request.requestId())
            .append('|')
            .append(request.tenantId())
            .append('|')
            .append(request.subjectId())
            .append('|')
            .append(request.actorHash())
            .append('|')
            .append(request.policyHash())
            .append('|')
            .append(request.scopeHash());
    for (var registration : request.registrations())
      canonical
          .append('|')
          .append(registration.deviceId())
          .append(':')
          .append(registration.registrationId());
    return hash(canonical.toString());
  }

  static String entryHash(
      String ledgerId, long sequence, long acceptedAt, String previous, String requestHash) {
    return hash(
        "erasure-entry-v1|"
            + ledgerId
            + "|"
            + sequence
            + "|"
            + acceptedAt
            + "|"
            + previous
            + "|"
            + requestHash);
  }
}
