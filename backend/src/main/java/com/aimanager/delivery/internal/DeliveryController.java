package com.aimanager.delivery.internal;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.shared.ItemPage;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.util.Map;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
class DeliveryController {
    private final ConfigurationDeliveryService deliveries;
    DeliveryController(ConfigurationDeliveryService deliveries) { this.deliveries = deliveries; }
    @GetMapping("/api/v1/device-api/configurations") @SecurityRequirement(name = "deviceBearer")
    ConfigurationDeliveryService.Pull pull(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal,
                                           @RequestParam(defaultValue = "0") long after, @RequestParam(defaultValue = "50") int limit) {
        return deliveries.pull(DeviceContext.from(principal), after, limit);
    }
    @GetMapping("/api/v1/device-api/signing-keys") @SecurityRequirement(name = "deviceBearer")
    Map<String, Object> keys(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal) { return deliveries.keys(DeviceContext.from(principal)); }
    @PostMapping("/api/v1/device-api/configuration-receipts") @SecurityRequirement(name = "deviceBearer")
    ConfigurationDeliveryService.ReceiptAccepted receipt(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal, @Valid @RequestBody Receipt input) {
        return deliveries.acknowledge(DeviceContext.from(principal), input);
    }
    @GetMapping("/api/v1/tenants/{tenantId}/policy-publications/{publicationId}/deliveries")
    ItemPage<ConfigurationDeliveryService.DeliveryView> list(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String publicationId,
                                                            @RequestParam(defaultValue = "50") int limit, @RequestParam(required = false) String cursor) {
        return deliveries.list(tenantId, actor.getSubject(), publicationId, limit, cursor);
    }
    record Receipt(@NotNull @Pattern(regexp = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}") String receiptId,
                   @NotNull @Pattern(regexp = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}") String deliveryId,
                   @NotNull @Min(1) @Max(9007199254740991L) Long cursor,
                   @NotNull @Pattern(regexp = "[0-9a-f]{64}") String envelopeHash, @NotNull Stage stage, RejectionReason reason) {}
    enum Stage { RECEIVED, STORED, REJECTED }
    enum RejectionReason { UNSUPPORTED_SCHEMA, SIGNATURE_INVALID, IDENTITY_MISMATCH, UNSUPPORTED_RULES, STORAGE_FAILURE, EXPIRED, OLDER_VERSION }
}
