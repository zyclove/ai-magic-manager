package com.aimanager.observation.internal;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.observation.ObservationSettings;
import com.aimanager.shared.ResourceVersions;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Pattern;
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

    /** 手机显式绑定原注册周期，避免安全验证期间设备变化后误授权。 */
    @PostMapping("/api/v1/tenants/{tenantId}/devices/{deviceId}/observation-settings/changes")
    ResponseEntity<ObservationSettings> change(@AuthenticationPrincipal Jwt actor,
            @PathVariable String tenantId, @PathVariable String deviceId,
            @RequestHeader(name = "Idempotency-Key", required = false) String key,
            @Valid @RequestBody Change input) {
        return response(settings.changeBound(tenantId, actor, deviceId, key, input));
    }

    /** 只读恢复：查询原提交及当前授权，不重放写入或延长幂等保留期。 */
    @PostMapping("/api/v1/tenants/{tenantId}/devices/{deviceId}/observation-settings/operation-results/{requestId}/query")
    ResponseEntity<ObservationSettingsService.Recovery> result(@AuthenticationPrincipal Jwt actor,
            @PathVariable String tenantId, @PathVariable String deviceId,
            @PathVariable String requestId, @Valid @RequestBody Change input) {
        return ResponseEntity.ok().header("Cache-Control", "no-store").header("Vary", "Authorization")
            .body(settings.operationResult(tenantId, actor.getSubject(), deviceId, requestId, input).toHttpResult());
    }

    record Change(@NotNull @Pattern(regexp = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}") String registrationId,
                  @NotNull @Min(0) @Max(9007199254740990L) Long version,
                  @NotNull Boolean inventoryEnabled, @NotNull Boolean usageEnabled,
                  @NotBlank @Size(max = 300) String reason) {
        Update update() { return new Update(inventoryEnabled, usageEnabled, reason); }
    }

    private ResponseEntity<ObservationSettings> response(ObservationSettings value) {
        return ResponseEntity.ok().eTag(ResourceVersions.tag(value.version()))
            .header("Cache-Control", "no-store").header("Vary", "Authorization").body(value);
    }

    record Update(@NotNull Boolean inventoryEnabled, @NotNull Boolean usageEnabled,
                  @NotBlank @Size(max = 300) String reason) {}
}
