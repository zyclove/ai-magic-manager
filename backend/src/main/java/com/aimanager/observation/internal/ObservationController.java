package com.aimanager.observation.internal;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.observation.ObservationSettings;
import com.aimanager.shared.ResourceVersions;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
class ObservationController {
    private final ObservationSettingsService settings;
    ObservationController(ObservationSettingsService settings) { this.settings = settings; }

    @GetMapping("/api/v1/tenants/{tenantId}/devices/{deviceId}/observation-settings")
    ResponseEntity<ObservationSettings> get(@AuthenticationPrincipal Jwt actor,
            @PathVariable String tenantId, @PathVariable String deviceId) {
        return response(settings.read(tenantId, actor.getSubject(), deviceId));
    }

    @PutMapping("/api/v1/tenants/{tenantId}/devices/{deviceId}/observation-settings")
    ResponseEntity<ObservationSettings> update(@AuthenticationPrincipal Jwt actor,
            @PathVariable String tenantId, @PathVariable String deviceId,
            @RequestHeader(name = "If-Match", required = false) String version,
            @RequestHeader(name = "Idempotency-Key", required = false) String key,
            @Valid @RequestBody Update input) {
        return response(settings.update(tenantId, actor, deviceId, ResourceVersions.require(version), key, input));
    }

    @GetMapping("/api/v1/device-api/observation-settings")
    @SecurityRequirement(name = "deviceBearer")
    ObservationSettings device(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal) {
        return settings.device(DeviceContext.from(principal));
    }

    private ResponseEntity<ObservationSettings> response(ObservationSettings value) {
        return ResponseEntity.ok().eTag(ResourceVersions.tag(value.version())).body(value);
    }

    record Update(@NotNull Boolean inventoryEnabled, @NotNull Boolean usageEnabled,
                  @NotBlank @Size(max = 300) String reason) {}
}
