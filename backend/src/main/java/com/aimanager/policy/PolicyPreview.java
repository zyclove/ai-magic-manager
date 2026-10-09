package com.aimanager.policy;

import java.util.List;

public record PolicyPreview(String id, String policyId, long draftRevision, String phase, String hash,
                            long expiresAt, boolean enforceable, List<PolicySnapshot.Target> targets,
                            PolicySnapshot snapshot) {}
