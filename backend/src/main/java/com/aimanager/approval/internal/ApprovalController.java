package com.aimanager.approval.internal;

import com.aimanager.approval.AccessRequest;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.util.List;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

/** Scope is derived from JWT/current membership; body fields never grant an adult role. */
@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/access-requests")
class ApprovalController {
  private final ApprovalService approvals;

  ApprovalController(ApprovalService approvals) {
    this.approvals = approvals;
  }

  @PostMapping
  ResponseEntity<AccessRequest> create(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @Valid @RequestBody Create input,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(approvals.create(tenantId, actor.getSubject(), input, key), HttpStatus.CREATED);
  }

  @GetMapping
  ItemPage<AccessRequest> list(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return approvals.list(tenantId, actor.getSubject(), limit, cursor);
  }

  @GetMapping("/options")
  ItemPage<com.aimanager.policy.PolicyExceptionAccess.WindowOptions> options(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @RequestParam @Pattern(regexp = UUID) String deviceId,
      @RequestParam(defaultValue = "50") @Min(1) @Max(100) int limit,
      @RequestParam(required = false) String cursor) {
    return approvals.options(tenantId, actor.getSubject(), deviceId, limit, cursor);
  }

  @GetMapping("/{requestId}")
  ResponseEntity<AccessRequest> get(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String requestId) {
    return response(approvals.get(tenantId, actor.getSubject(), requestId), HttpStatus.OK);
  }

  @PostMapping("/{requestId}/decisions")
  ResponseEntity<AccessRequest> decide(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String requestId,
      @Valid @RequestBody Decision input,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(approvals.decide(tenantId, actor, requestId, input, etag, key), HttpStatus.OK);
  }

  @PostMapping("/{requestId}/cancel")
  ResponseEntity<AccessRequest> cancel(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String requestId,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(
        approvals.cancel(tenantId, actor.getSubject(), requestId, etag, key), HttpStatus.OK);
  }

  @PostMapping("/{requestId}/revoke")
  ResponseEntity<AccessRequest> revoke(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String requestId,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(approvals.revoke(tenantId, actor, requestId, etag, key), HttpStatus.OK);
  }

  private ResponseEntity<AccessRequest> response(AccessRequest result, HttpStatus status) {
    return ResponseEntity.status(status).eTag(ResourceVersions.tag(result.version())).body(result);
  }

  record Create(
      @NotNull @Pattern(regexp = UUID) String deviceId,
      @NotNull @Pattern(regexp = UUID) String policyId,
      @NotNull @Pattern(regexp = UUID) String baseVersionId,
      @NotNull @Pattern(regexp = UUID) String applicationId,
      @NotNull @Size(min = 1, max = 20)
          List<@NotNull @Pattern(regexp = "[a-z][a-z0-9_-]{0,49}") String> ruleIds,
      @NotNull @Min(1) @Max(3600) Long requestedWindowSeconds,
      @Size(max = 300) String reason) {
    @Override
    public String toString() {
      return "AccessRequestInput[deviceId=" + deviceId + "]";
    }
  }

  record Decision(
      @NotNull Choice decision,
      @Min(1) @Max(3600) Long grantedWindowSeconds,
      DenialReason reasonCode) {}

  enum Choice {
    APPROVE,
    DENY
  }

  enum DenialReason {
    NOT_NOW,
    NOT_ALLOWED,
    OTHER
  }

  private static final String UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
}
