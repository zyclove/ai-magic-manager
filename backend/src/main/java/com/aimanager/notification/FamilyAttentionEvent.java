package com.aimanager.notification;

/** Publish synchronously inside the FAMILY mutation transaction. IDs never become lock-screen text. */
public record FamilyAttentionEvent(String tenantId, String eventId, String subjectId,
    String deviceId, String kind, long occurredAt) {}
