package com.aimanager.subject;

/** Trusted synchronous lifecycle event; emitted inside the subject transaction. No private profile fields. */
public record SubjectArchived(String tenantId, String subjectId) {}
