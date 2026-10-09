package com.aimanager.catalog.internal;

import com.aimanager.catalog.*;
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
class InventoryController {
    private final InventoryService inventories;
    InventoryController(InventoryService inventories) { this.inventories = inventories; }
    @PostMapping("/api/v1/device-api/application-inventory")
    @SecurityRequirement(name = "deviceBearer")
    InventoryService.Accepted report(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal, @Valid @RequestBody InventoryReport input) {
        return inventories.report(DeviceContext.from(principal), input);
    }
    @GetMapping("/api/v1/tenants/{tenantId}/devices/{deviceId}/application-inventory")
    ApplicationInventory get(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String deviceId) {
        return inventories.read(tenantId, actor.getSubject(), deviceId);
    }
    record InventoryReport(@NotNull @Min(1) @Max(9007199254740991L) Long sequence, @NotNull Visibility visibility,
                           @NotNull @Size(max = 500) List<@NotNull @Valid ReportedApplication> applications) {}
    enum Visibility { VISIBLE_PACKAGES }
}
