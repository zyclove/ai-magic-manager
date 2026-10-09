package com.aimanager.catalog;

import jakarta.validation.constraints.*;
import java.util.List;

/** Agent-reported observations only. No permission, safety or installation certification is implied. */
public record ReportedApplication(@NotBlank @Size(max = 255) @Pattern(regexp = "[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+") String packageName,
                                  @NotBlank @Size(max = 100) String displayName, @NotNull ApplicationDefinition.Profile profile,
                                  @NotNull @Size(max = 8) List<@NotNull @Pattern(regexp = "[0-9a-f]{64}") String> signingDigests,
                                  @NotNull @Min(0) @Max(9007199254740991L) Long versionCode, @NotNull Boolean systemApplication) {}
