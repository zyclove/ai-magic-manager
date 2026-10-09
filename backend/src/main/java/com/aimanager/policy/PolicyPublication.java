package com.aimanager.policy;

/** The operation ID is separate from the immutable content version; transport acknowledgements come later. */
public record PolicyPublication(String id, String versionId, long sequence, Mode mode, String state, long createdAt) {
    public enum Mode { CONFIGURE_ONLY, ENFORCE }
}
