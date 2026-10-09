package com.aimanager.approval.internal;

import com.aimanager.approval.AccessRequest;
import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.policy.PolicyExceptionAccess;
import com.aimanager.shared.*;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.util.List;
import org.springframework.http.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.web.bind.annotation.*;

/** Request workflow, separate from signed-document delivery and adult decision routes. */
@RestController
@RequestMapping("/api/v1/device-api/access-submissions")
@SecurityRequirement(name = "deviceBearer")
class DeviceAccessSubmissionController {
  private final DeviceAccessSubmissionService service;

  DeviceAccessSubmissionController(DeviceAccessSubmissionService service) {
    this.service = service;
  }

  @PostMapping
  ResponseEntity<AccessRequest> create(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal actor,
      @Valid @RequestBody Create input,
      @RequestHeader(value = "Idempotency-Key", required = false) String key) {
    return view(service.create(DeviceContext.from(actor), input, key), HttpStatus.CREATED);
  }

  @GetMapping("/options")
  ResponseEntity<ItemPage<PolicyExceptionAccess.WindowOptions>> options(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal actor,
      @RequestParam(defaultValue = "20") int limit,
      @RequestParam(required = false) String cursor) {
    return noStore().body(service.options(DeviceContext.from(actor), limit, cursor));
  }

  @GetMapping
  ResponseEntity<ItemPage<AccessRequest>> list(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal actor,
      @RequestParam(defaultValue = "20") int limit,
      @RequestParam(required = false) String cursor) {
    return noStore().body(service.list(DeviceContext.from(actor), limit, cursor));
  }

  @GetMapping("/{requestId}")
  ResponseEntity<AccessRequest> get(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal actor,
      @PathVariable @Pattern(regexp = UUID) String requestId) {
    return view(service.get(DeviceContext.from(actor), requestId), HttpStatus.OK);
  }

  @PostMapping("/{requestId}/cancel")
  ResponseEntity<AccessRequest> cancel(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal actor,
      @PathVariable @Pattern(regexp = UUID) String requestId,
      @RequestHeader(value = "If-Match", required = false) String etag,
      @RequestHeader(value = "Idempotency-Key", required = false) String key) {
    return view(service.cancel(DeviceContext.from(actor), requestId, etag, key), HttpStatus.OK);
  }

  private ResponseEntity.BodyBuilder noStore() {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).varyBy("Authorization");
  }

  private ResponseEntity<AccessRequest> view(AccessRequest result, HttpStatus status) {
    return ResponseEntity.status(status)
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .eTag(ResourceVersions.tag(result.version()))
        .body(result);
  }

  record Create(
      @NotNull @Pattern(regexp = UUID) String policyId,
      @NotNull @Pattern(regexp = UUID) String baseVersionId,
      @NotNull @Pattern(regexp = UUID) String applicationId,
      @NotNull @Size(min = 1, max = 20)
          List<@NotNull @Pattern(regexp = "[a-z][a-z0-9_-]{0,49}") String> ruleIds,
      @NotNull @Min(1) @Max(3600) Long requestedWindowSeconds,
      @Size(max = 300) String reason) {
    ApprovalController.Create forDevice(String device) {
      return new ApprovalController.Create(
          device, policyId, baseVersionId, applicationId, ruleIds, requestedWindowSeconds, reason);
    }

    @Override
    public String toString() {
      return "DeviceAccessSubmissionInput[private]";
    }
  }

  private static final String UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
}
