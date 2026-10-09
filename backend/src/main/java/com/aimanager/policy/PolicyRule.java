package com.aimanager.policy;

import jakarta.validation.constraints.*;

/** Tagged rule schema. Incompatible and unused fields are rejected, never silently ignored. */
public record PolicyRule(@NotBlank @Pattern(regexp = "[a-z][a-z0-9_-]{0,49}") String id,
                         @NotNull Kind kind, @NotNull Effect effect, @NotNull Boolean required,
                         @Size(max = 36) @Pattern(regexp = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}") String applicationId,
                         @Size(max = 36) @Pattern(regexp = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}") String scheduleId,
                         @Min(1) @Max(86400) Long seconds, @Size(max = 150) String permission,
                         @Size(max = 253) String domain) {
    public enum Kind { APP_LAUNCH, APP_INSTALL, APP_UNINSTALL, RUNTIME_PERMISSION, SPECIAL_ACCESS,
                       DAILY_QUOTA, TIME_WINDOW, DOMAIN_ACCESS, USAGE_REMINDER }
    public enum Effect { ALLOW, DENY, DEFAULT, GRANT, PROTECT, LIMIT, REMIND }
}
