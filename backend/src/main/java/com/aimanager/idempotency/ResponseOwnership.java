package com.aimanager.idempotency;

import com.aimanager.shared.SecretMaterial;
import java.util.Collection;
import java.util.List;
import java.util.TreeSet;
import java.util.UUID;

/** Explicit subject dependencies of one cached response, committed with its mutation. */
public record ResponseOwnership(Kind kind, String tenantId, List<String> subjectIds) {
  /** 与最大报表选择兼容；创建、重放及删除校验使用同一主体数量上限。 */
  public static final int MAX_SUBJECTS = 200;

  public enum Kind { UNCLASSIFIED, NON_SUBJECT, SCOPED }

  public ResponseOwnership {
    if (kind == null || subjectIds == null) throw invalid();
    if (kind == Kind.SCOPED) {
      requireUuid(tenantId);
      var unique = new TreeSet<String>();
      for (String subject : subjectIds) {
        requireUuid(subject);
        unique.add(subject);
        if (unique.size() > MAX_SUBJECTS) throw invalid();
      }
      if (unique.isEmpty()) throw invalid();
      subjectIds = List.copyOf(unique);
    } else {
      if (tenantId != null || !subjectIds.isEmpty()) throw invalid();
      subjectIds = List.of();
    }
  }

  public static ResponseOwnership subjects(String tenantId, Collection<String> subjectIds) {
    if (subjectIds == null) throw invalid();
    return new ResponseOwnership(Kind.SCOPED, tenantId, new java.util.ArrayList<>(subjectIds));
  }

  public static ResponseOwnership nonSubject() {
    return new ResponseOwnership(Kind.NON_SUBJECT, null, List.of());
  }

  public static ResponseOwnership unclassified() {
    return new ResponseOwnership(Kind.UNCLASSIFIED, null, List.of());
  }

  public static String subjectKey(String tenantId, String subjectId) {
    requireUuid(tenantId);
    requireUuid(subjectId);
    return SecretMaterial.hash("idempotency-subject-v1\n" + tenantId + "\n" + subjectId);
  }

  private static void requireUuid(String value) {
    try {
      if (value == null || !UUID.fromString(value).toString().equals(value)) throw invalid();
    } catch (IllegalArgumentException malformed) {
      throw invalid();
    }
  }

  private static IllegalArgumentException invalid() {
    return new IllegalArgumentException("Invalid cached response ownership");
  }
}
