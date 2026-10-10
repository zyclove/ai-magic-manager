package com.aimanager.catalog;

import com.aimanager.fleet.Device;
import java.util.Map;
import java.util.Set;

/** Reporting labels declared in a tenant; not installation, signer or safety evidence. */
public interface ApplicationCategories {
  enum Category {
    UNCLASSIFIED,
    EDUCATION,
    PRODUCTIVITY,
    GAMES,
    SOCIAL,
    ENTERTAINMENT,
    TOOLS,
    OTHER
  }

  record Identity(
      Device.Platform platform, ApplicationDefinition.Profile profile, String packageName) {
    public Identity {
      if (platform == null
          || profile == null
          || packageName == null
          || packageName.length() > 255
          || !packageName.matches("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+"))
        throw new IllegalArgumentException("Invalid application classification identity");
    }
  }

  record Classification(
      Identity identity, Category category, String source, long version, Long updatedAt) {
    public static Classification unclassified(Identity identity) {
      return new Classification(identity, Category.UNCLASSIFIED, "NONE", 0, null);
    }
  }

  /**
   * Caller must hold current report member/device/consent authorization in the same transaction.
   * Returns only the requested observed identities; it never enumerates the tenant's directory.
   * Labels are current configuration, not a reconstruction of historical classification.
   */
  Map<Identity, Classification> forAuthorizedUsageReport(String tenantId, Set<Identity> identities);
}
