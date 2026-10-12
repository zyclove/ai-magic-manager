package com.aimanager.observation.internal;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.observation.PermissionObservationSettings;
import com.aimanager.shared.ResourceVersions;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

/** Consent for permission observations is independent of the existing inventory/usage consent. */
@RestController
@ConditionalOnProperty(name = "manager.observation.permissions.enabled", havingValue = "true")
class PermissionObservationController {
  private final ObservationSettingsService settings;

  PermissionObservationController(ObservationSettingsService settings) {
    this.settings = settings;
  }

  @GetMapping("/api/v1/tenants/{tenantId}/devices/{deviceId}/permission-observation-settings")
  ResponseEntity<PermissionObservationSettings> get(@AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId, @PathVariable String deviceId) {
    return response(settings.readPermission(tenantId, actor.getSubject(), deviceId));
  }

  @PutMapping("/api/v1/tenants/{tenantId}/devices/{deviceId}/permission-observation-settings")
  ResponseEntity<PermissionObservationSettings> update(@AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId, @PathVariable String deviceId,
      @RequestHeader(name = "If-Match", required = false) String version,
      @RequestHeader(name = "Idempotency-Key", required = false) String key,
      @Valid @RequestBody Update input) {
    return response(settings.updatePermission(tenantId, actor, deviceId,
        ResourceVersions.require(version), key, input));
  }

  @GetMapping("/api/v1/device-api/permission-observation-settings")
  @SecurityRequirement(name = "deviceBearer")
  ResponseEntity<PermissionObservationSettings> device(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal) {
    return response(settings.devicePermission(DeviceContext.from(principal)));
  }

  private ResponseEntity<PermissionObservationSettings> response(PermissionObservationSettings value) {
    return ResponseEntity.ok().eTag(ResourceVersions.tag(value.version()))
        .cacheControl(CacheControl.noStore()).header("Vary", "Authorization").body(value);
  }

  record Update(@NotNull Boolean enabled, @NotBlank @Size(max = 300) String reason) {}
}
