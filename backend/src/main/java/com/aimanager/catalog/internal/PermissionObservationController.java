package com.aimanager.catalog.internal;

import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.deviceidentity.DeviceContext;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.util.List;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Device reported permission facts; neither this route nor its response executes a policy. */
@RestController
@ConditionalOnProperty(name = "manager.observation.permissions.enabled", havingValue = "true")
class PermissionObservationController {
  private final PermissionObservationService observations;

  PermissionObservationController(PermissionObservationService observations) {
    this.observations = observations;
  }

  @PostMapping("/api/v1/device-api/permission-observations")
  @SecurityRequirement(name = "deviceBearer")
  ResponseEntity<PermissionObservationService.Accepted> report(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal,
      @Valid @RequestBody Report input) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore())
        .body(observations.report(DeviceContext.from(principal), input));
  }

  @GetMapping("/api/v1/tenants/{tenantId}/devices/{deviceId}/permission-observations")
  ResponseEntity<PermissionObservationService.View> read(@AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId, @PathVariable String deviceId,
      @RequestParam String packageName) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(observations.read(tenantId, actor.getSubject(), deviceId, packageName));
  }

  record Report(
      @NotBlank @Pattern(regexp = "[0-9a-fA-F-]{36}") String reportId,
      @NotNull @Min(1) @Max(9007199254740991L) Long sequence,
      @NotNull @Min(1) @Max(9007199254740991L) Long authorizationVersion,
      @NotBlank @Size(max = 255)
          @Pattern(regexp = "[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")
          String packageName,
      @NotNull ApplicationDefinition.Profile profile,
      @NotNull @Size(max = 8) List<@NotNull @Pattern(regexp = "[0-9a-f]{64}") String> signingDigests,
      @NotNull @Min(0) @Max(9007199254740991L) Long versionCode,
      @NotNull @Min(1) Long observedAt,
      @NotNull Source source,
      @NotNull @Size(max = 64) List<@NotNull @Valid PermissionFact> permissions) {}

  record PermissionFact(
      @NotBlank @Pattern(regexp = "android\\.permission\\.[A-Z][A-Z0-9_]{1,100}")
          String permissionName,
      @NotNull Classification classification,
      @NotNull ObservedGrant observedGrant) {}

  enum Source { ANDROID_PACKAGE_MANAGER }
  enum Classification { DANGEROUS, OTHER, UNKNOWN }
  enum ObservedGrant { GRANTED, DENIED, UNKNOWN }
}
