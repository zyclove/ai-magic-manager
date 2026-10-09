package com.aimanager.approval;

/**
 * Minimal in-transaction fact. Never contains the child's reason, a token, or an actor identifier.
 */
public record AccessRequestChanged(
    String tenantId,
    String requestId,
    String subjectId,
    String deviceId,
    String requesterKey,
    long requestVersion,
    AccessRequest.State state,
    long occurredAt,
    RequesterKind requesterKind) {
  public enum RequesterKind {
    MEMBER,
    DEVICE
  }

  public AccessRequestChanged {
    java.util.Objects.requireNonNull(requesterKind, "requesterKind");
  }

  /** Existing member event producers retain their original authority semantics. */
  public AccessRequestChanged(
      String tenantId,
      String requestId,
      String subjectId,
      String deviceId,
      String requesterKey,
      long requestVersion,
      AccessRequest.State state,
      long occurredAt) {
    this(
        tenantId,
        requestId,
        subjectId,
        deviceId,
        requesterKey,
        requestVersion,
        state,
        occurredAt,
        RequesterKind.MEMBER);
  }
}
