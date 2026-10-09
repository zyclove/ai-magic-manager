package com.aimanager.lifecycle;

/** Trusted scheduler boundary, not an HTTP or device operation. Expiry records uncertainty, never cleanup success. */
public interface CleanupMaintenance {
    int expireDue(int limit);
}
