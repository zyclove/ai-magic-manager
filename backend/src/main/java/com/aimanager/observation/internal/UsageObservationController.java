package com.aimanager.observation.internal;

import com.aimanager.deviceidentity.DeviceContext;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.util.List;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
class UsageObservationController {
    private final UsageObservationService usage;
    UsageObservationController(UsageObservationService usage) { this.usage = usage; }

    @PostMapping("/api/v1/device-api/usage-observations")
    @SecurityRequirement(name = "deviceBearer")
    UsageObservationService.Accepted report(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal,
            @Valid @RequestBody Report input) {
        return usage.report(DeviceContext.from(principal), input);
    }

    @GetMapping("/api/v1/tenants/{tenantId}/devices/{deviceId}/usage-observations")
    UsageObservationService.Page list(@AuthenticationPrincipal Jwt actor,
            @PathVariable String tenantId, @PathVariable String deviceId,
            @RequestParam(defaultValue = "5") int limit, @RequestParam(required = false) String cursor) {
        return usage.list(tenantId, actor.getSubject(), deviceId, limit, cursor);
    }

    record Report(@NotBlank @Pattern(regexp = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}") String reportId,
                  @NotNull @Min(1) @Max(9007199254740991L) Long sequence,
                  @NotNull @Min(1) @Max(9007199254740991L) Long authorizationVersion,
                  @NotNull @Pattern(regexp = "ANDROID_USAGE_STATS") String source,
                  @NotNull @Pattern(regexp = "PRIMARY|WORK|SECONDARY|UNKNOWN") String profile,
                  @NotNull @Min(1) @Max(9007199254740991L) Long queryStart,
                  @NotNull @Min(1) @Max(9007199254740991L) Long queryEnd,
                  @NotNull @Min(1) @Max(9007199254740991L) Long observedAt,
                  @NotBlank @Size(max = 100) String timeZone,
                  @NotNull @Size(max = 500) List<@NotNull @Valid Application> applications) {}

    record Application(@NotBlank @Size(max = 255)
                       @Pattern(regexp = "[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+") String packageName,
                       @NotBlank @Size(max = 100) String displayName,
                       @NotNull @Min(1) @Max(9007199254740991L) Long firstTimeStamp,
                       @NotNull @Min(1) @Max(9007199254740991L) Long lastTimeStamp,
                       @NotNull @Min(0) @Max(604800000L) Long foregroundMillis) {}
}
