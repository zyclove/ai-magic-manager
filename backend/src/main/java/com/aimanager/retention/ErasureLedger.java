package com.aimanager.retention;

import java.util.*;

/**
 * Trusted server-side journal. Callers must authorize, confirm and isolate before accepting
 * erasure.
 */
public interface ErasureLedger {
  record Registration(String deviceId, String registrationId) {
    public Registration {
      uuid(deviceId);
      uuid(registrationId);
    }
  }

  record Request(
      String requestId,
      String tenantId,
      String subjectId,
      String actorHash,
      String policyHash,
      String scopeHash,
      List<Registration> registrations) {
    public Request {
      uuid(requestId);
      uuid(tenantId);
      uuid(subjectId);
      digest(actorHash);
      digest(policyHash);
      digest(scopeHash);
      if (registrations == null || registrations.size() > 1000) throw invalid();
      var ordered = new ArrayList<>(registrations);
      if (ordered.stream().anyMatch(Objects::isNull)) throw invalid();
      ordered.sort(
          Comparator.comparing(Registration::deviceId).thenComparing(Registration::registrationId));
      if (new HashSet<>(ordered).size() != ordered.size()) throw invalid();
      registrations = List.copyOf(ordered);
    }
  }

  record Checkpoint(String ledgerId, long sequence, String hash) {
    public Checkpoint {
      uuid(ledgerId);
      digest(hash);
      if (sequence < 0) throw invalid();
    }
  }

  record Entry(long sequence, Request request, long acceptedAt, String previousHash, String hash) {}

  /**
   * A verified read cursor only. Reaching this snapshot's end does not mean erasure was applied,
   * authorize advancing the business checkpoint, or permit reopening traffic.
   */
  record Page(Checkpoint head, Checkpoint nextRead, List<Entry> entries, boolean endOfSnapshot) {
    public Page {
      entries = List.copyOf(entries);
    }
  }

  Checkpoint head();

  Entry append(Request request);

  Page readAfter(Checkpoint checkpoint, int limit);

  /** Stable code only; never return JDBC messages, credentials or a stored manifest. */
  final class Failure extends RuntimeException {
    private final String code;

    public Failure(String code) {
      super(code);
      this.code = code;
    }

    public String code() {
      return code;
    }
  }

  private static void uuid(String value) {
    if (value == null
        || !value.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))
      throw invalid();
  }

  private static void digest(String value) {
    if (value == null || !value.matches("[0-9a-f]{64}")) throw invalid();
  }

  private static IllegalArgumentException invalid() {
    return new IllegalArgumentException("Invalid erasure ledger value");
  }
}
