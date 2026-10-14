package com.aimanager.tenant.internal;

import com.aimanager.tenant.TenantAccess.Role;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.util.List;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

/** Recoverable invitation issuance; response caching must never retain the one-time token. */
@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/invitations")
class InvitationWorkflowController {
  private final InvitationWorkflowService workflow;
  InvitationWorkflowController(InvitationWorkflowService workflow) { this.workflow = workflow; }

  @PostMapping("/issuances")
  ResponseEntity<InvitationWorkflowService.Issuance> issue(@AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId, @RequestHeader("Idempotency-Key") String key,
      @Valid @RequestBody Issue input) {
    return ResponseEntity.status(HttpStatus.CREATED).cacheControl(org.springframework.http.CacheControl.noStore())
        .body(workflow.issue(tenantId, actor, key, input));
  }

  @PostMapping("/issuance-results/{requestId}/query")
  ResponseEntity<InvitationWorkflowService.Issuance> query(@AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId, @PathVariable String requestId, @Valid @RequestBody Issue input) {
    return ResponseEntity.ok().cacheControl(org.springframework.http.CacheControl.noStore())
        .body(workflow.result(tenantId, actor.getSubject(), requestId, input));
  }

  @GetMapping("/{invitationId}")
  ResponseEntity<InvitationWorkflowService.Summary> detail(@AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId, @PathVariable String invitationId) {
    return ResponseEntity.ok().cacheControl(org.springframework.http.CacheControl.noStore())
        .body(workflow.detail(tenantId, actor.getSubject(), invitationId));
  }

  record Issue(@NotBlank @Email @Size(max=254) String recipientEmail, @NotNull Role role,
      @Size(max=36) String subjectId,
      @Size(max=50) List<@NotBlank @Size(max=36) String> classIds) {}
}
