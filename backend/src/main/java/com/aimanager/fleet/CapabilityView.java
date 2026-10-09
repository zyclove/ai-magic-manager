package com.aimanager.fleet;

/** Agent observations do not certify OS privileges. Unknown/old evidence never becomes enforced support. */
public record CapabilityView(String key, boolean reportedSupported, String grantStatus, String evidenceSource,
                             Long checkedAt, String status, boolean effectiveSupported, String limitationCode) {}
