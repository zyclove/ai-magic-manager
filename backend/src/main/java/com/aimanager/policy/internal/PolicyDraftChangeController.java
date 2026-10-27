package com.aimanager.policy.internal;

import com.aimanager.policy.PolicyDraft;
import jakarta.validation.Valid;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** Full draft changes retain their original result without replaying a later edit. */
@RestController
@RequestMapping("/api/v1/tenants/{tenantId}")
class PolicyDraftChangeController {
  private final PolicyDraftChangeService service;

  PolicyDraftChangeController(PolicyDraftChangeService service) {
    this.service = service;
  }

  @PostMapping("/policy-draft-changes")
  ResponseEntity<PolicyDraft> change(@AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId, @Valid @RequestBody PolicyDraftChangeService.Change input,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore())
        .body(service.change(tenantId, actor.getSubject(), input, key));
  }

  @PostMapping("/policy-draft-operation-results/{requestId}/query")
  ResponseEntity<PolicyDraftChangeService.Result> query(@AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId, @PathVariable String requestId,
      @Valid @RequestBody PolicyDraftChangeService.Change input) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore())
        .body(service.query(tenantId, actor.getSubject(), requestId, input).toHttpResult());
  }
}
