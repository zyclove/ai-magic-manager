package com.aimanager.approval.internal;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.shared.ItemPage;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1")
class AccessDeliveryController {
  private final AccessDeliveryService deliveries;

  AccessDeliveryController(AccessDeliveryService deliveries) {
    this.deliveries = deliveries;
  }

  @GetMapping("/device-api/access-requests")
  @SecurityRequirement(name = "deviceBearer")
  ItemPage<AccessDeliveryService.Reference> list(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal actor,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return deliveries.list(DeviceContext.from(actor), limit, cursor);
  }

  @GetMapping("/device-api/access-requests/{requestId}/document")
  @SecurityRequirement(name = "deviceBearer")
  AccessDeliveryService.Document document(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal actor, @PathVariable String requestId) {
    return deliveries.document(DeviceContext.from(actor), requestId);
  }

  @PostMapping("/device-api/access-requests/{requestId}/receipts")
  @SecurityRequirement(name = "deviceBearer")
  AccessDeliveryService.Receipt receipt(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal actor,
      @PathVariable String requestId,
      @Valid @RequestBody Input input) {
    return deliveries.receipt(DeviceContext.from(actor), requestId, input);
  }

  @PostMapping("/device-api/access-requests/{requestId}/delivery-retries")
  @SecurityRequirement(name = "deviceBearer")
  AccessDeliveryService.RetryResult retry(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal actor,
      @PathVariable String requestId,
      @Valid @RequestBody RetryInput input) {
    return deliveries.retry(DeviceContext.from(actor), requestId, input);
  }

  @GetMapping("/tenants/{tenantId}/access-requests/{requestId}/delivery")
  AccessDeliveryService.Summary summary(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String requestId) {
    return deliveries.summary(tenantId, actor.getSubject(), requestId);
  }

  @GetMapping("/tenants/{tenantId}/access-requests/{requestId}/documents")
  ItemPage<AccessDeliveryService.History> history(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String requestId,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return deliveries.history(tenantId, actor.getSubject(), requestId, limit, cursor);
  }

  @GetMapping("/tenants/{tenantId}/access-requests/{requestId}/documents/{documentId}/attempts")
  ItemPage<AccessDeliveryService.Attempt> attempts(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String requestId,
      @PathVariable String documentId) {
    return deliveries.attempts(tenantId, actor.getSubject(), requestId, documentId);
  }

  record Input(
      @NotNull @Pattern(regexp = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
          String documentId,
      @NotNull Phase phase,
      Reason reasonCode,
      @Min(1) @Max(10) Integer deliveryAttempt) {}

  record RetryInput(
      @NotNull @Pattern(regexp = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
          String documentId,
      @NotNull @Min(1) @Max(10) Integer failedAttempt) {}

  enum Phase {
    RECEIVED,
    STORED,
    REJECTED
  }

  enum Reason {
    SIGNATURE_INVALID,
    BASELINE_MISSING,
    EXPIRED,
    UNSUPPORTED_SCHEMA,
    STORAGE_FAILED,
    WRONG_DEVICE,
    OTHER
  }
}
