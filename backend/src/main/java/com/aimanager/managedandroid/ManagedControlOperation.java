package com.aimanager.managedandroid;

/** Exact reviewed operation; a runtime permission always names one permission, never a wildcard. */
public record ManagedControlOperation(Kind kind, Effect effect, String permission) {
  public enum Kind {
    APP_LAUNCH,
    APP_INSTALL,
    RUNTIME_PERMISSION
  }

  public enum Effect {
    ALLOW,
    DENY,
    DEFAULT
  }
}
