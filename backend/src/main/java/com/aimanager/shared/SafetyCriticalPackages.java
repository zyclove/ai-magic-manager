package com.aimanager.shared;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

/** Shared safety floor for policy compilation and provider-side application updates. */
public final class SafetyCriticalPackages {
  private static final Set<String> BASELINE = Set.of(
      "com.android.settings",
      "com.android.dialer",
      "com.google.android.dialer",
      "com.google.android.apps.work.clouddpc",
      "com.aimanager.device",
      "com.aimanager.child",
      "com.aimanager.child.debug",
      "com.aimanager.guardian");

  private SafetyCriticalPackages() {}

  /** Additional packages are deployment-controlled; callers cannot remove baseline packages. */
  public static Set<String> withAdditional(String configured) {
    var packages = new HashSet<>(BASELINE);
    if (configured != null) {
      Arrays.stream(configured.split(","))
          .map(String::strip)
          .filter(value -> !value.isEmpty())
          .map(value -> value.toLowerCase(Locale.ROOT))
          .forEach(packages::add);
    }
    return Set.copyOf(packages);
  }
}
