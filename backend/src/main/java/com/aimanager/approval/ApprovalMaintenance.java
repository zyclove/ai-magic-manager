package com.aimanager.approval;

/** Trusted scheduler boundary, not a user or device API. Each invocation owns a bounded transaction. */
public interface ApprovalMaintenance {
    int expireDue(int limit);
}
