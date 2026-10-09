package com.aimanager.quota.internal;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.quota.*;
import com.aimanager.shared.*;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.http.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1")
class QuotaController {
  private final QuotaService quotas;

  QuotaController(QuotaService quotas) {
    this.quotas = quotas;
  }

  @PostMapping("/tenants/{tenantId}/quota-pools")
  ResponseEntity<QuotaPool> create(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @Valid @RequestBody Create input,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(quotas.create(tenantId, actor, input, key), HttpStatus.CREATED);
  }

  @GetMapping("/tenants/{tenantId}/quota-pools")
  ItemPage<QuotaPool> list(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return quotas.list(tenantId, actor.getSubject(), limit, cursor);
  }

  @GetMapping("/tenants/{tenantId}/quota-pools/{poolId}")
  ResponseEntity<QuotaPool> get(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String poolId) {
    return response(quotas.get(tenantId, actor.getSubject(), poolId), HttpStatus.OK);
  }

  @PostMapping("/tenants/{tenantId}/quota-pools/{poolId}/adjustments")
  ResponseEntity<QuotaPool> adjust(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String poolId,
      @Valid @RequestBody Adjustment input,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(quotas.adjust(tenantId, actor, poolId, input, etag, key), HttpStatus.OK);
  }

  @GetMapping("/tenants/{tenantId}/quota-pools/{poolId}/ledger")
  ItemPage<QuotaService.Entry> ledger(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String poolId,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return quotas.ledger(tenantId, actor.getSubject(), poolId, limit, cursor);
  }

  @PostMapping("/device-api/quota-leases")
  @SecurityRequirement(name = "deviceBearer")
  @ResponseStatus(HttpStatus.CREATED)
  QuotaLease reserve(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal actor,
      @Valid @RequestBody Reserve input) {
    return quotas.reserve(DeviceContext.from(actor), input);
  }

  @GetMapping("/device-api/quota-leases/{leaseId}")
  @SecurityRequirement(name = "deviceBearer")
  QuotaLease lease(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal actor, @PathVariable String leaseId) {
    return quotas.lease(DeviceContext.from(actor), leaseId);
  }

  @PostMapping("/device-api/quota-leases/{leaseId}/settlements")
  @SecurityRequirement(name = "deviceBearer")
  QuotaLease settle(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal actor,
      @PathVariable String leaseId,
      @Valid @RequestBody Settlement input) {
    return quotas.settle(DeviceContext.from(actor), leaseId, input);
  }

  private ResponseEntity<QuotaPool> response(QuotaPool pool, HttpStatus status) {
    return ResponseEntity.status(status).eTag(ResourceVersions.tag(pool.version())).body(pool);
  }

  record Create(
      @NotBlank @Size(max = 100) String name,
      @NotNull @Pattern(regexp = UUID) String subjectId,
      @NotNull QuotaPool.Scope scope,
      @Pattern(regexp = UUID) String applicationId,
      @NotNull @Pattern(regexp = "[0-9]{4}-[0-9]{2}-[0-9]{2}") String periodId,
      @NotBlank @Size(max = 100) String timeZone,
      @NotNull @Min(0) @Max(86400) Long limitSeconds) {}

  record Adjustment(@NotNull @Min(-86400) @Max(86400) Long deltaSeconds, @NotNull Reason reason) {}

  enum Reason {
    EXTRA_TIME,
    CORRECTION
  }

  record Reserve(
      @NotNull @Pattern(regexp = UUID) String requestId,
      @NotNull @Pattern(regexp = UUID) String applicationId,
      @NotNull @Pattern(regexp = UUID) String bootId,
      @NotNull @Pattern(regexp = UUID) String sessionId,
      @NotNull @Min(0) @Max(9007199254740991L) Long startTickMillis,
      @NotNull @Min(1) @Max(300) Long requestedSeconds) {}

  record Settlement(
      @NotNull @Pattern(regexp = UUID) String bootId,
      @NotNull @Min(1) @Max(9007199254740991L) Long sequence,
      @NotNull @Min(0) @Max(300) Long cumulativeUsedSeconds,
      @NotNull @Min(0) @Max(9007199254740991L) Long elapsedRealtimeMillis,
      @NotNull Boolean finished) {}

  private static final String UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
}
