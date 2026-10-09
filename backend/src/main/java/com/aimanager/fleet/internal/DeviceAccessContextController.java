package com.aimanager.fleet.internal;

import com.aimanager.deviceidentity.DeviceContext;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Fixed read route; no caller-selected tenant, subject or credential attributes. */
@RestController
@SecurityRequirement(name = "deviceBearer")
class DeviceAccessContextController {
  private final DeviceAccessContextService contexts;

  DeviceAccessContextController(DeviceAccessContextService contexts) {
    this.contexts = contexts;
  }

  @GetMapping("/api/v1/device-api/access-context")
  @Operation(summary = "Read the authenticated active device binding for access configuration")
  ResponseEntity<DeviceAccessContextService.Binding> context(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore())
        .varyBy("Authorization").body(contexts.current(DeviceContext.from(principal)));
  }
}
