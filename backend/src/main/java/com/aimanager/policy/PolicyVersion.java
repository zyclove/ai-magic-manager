package com.aimanager.policy;

public record PolicyVersion(String id, String policyId, long draftRevision, long sequence, String previewHash,
                            PolicyPublication.Mode mode, PolicySnapshot snapshot, String sourceVersionId, long createdAt) {}
