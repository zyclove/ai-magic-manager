package com.aimanager.tenant.internal;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

/** Recipient APIs require an authenticated identity, not an existing tenant membership. */
@RestController
@RequestMapping("/api/v1/invitations")
class InvitationAcceptanceController {
  private final InvitationAcceptanceService service;
  InvitationAcceptanceController(InvitationAcceptanceService service) { this.service=service; }
  @PostMapping("/preview")
  ResponseEntity<InvitationAcceptanceService.Preview> preview(@AuthenticationPrincipal Jwt actor,
      Authentication authentication,@Valid @RequestBody PreviewInput input) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore())
        .body(service.preview(actor,adult(authentication),input.token()));
  }
  @PostMapping("/acceptances")
  ResponseEntity<InvitationAcceptanceService.Result> accept(@AuthenticationPrincipal Jwt actor,
      Authentication authentication,@RequestHeader("Idempotency-Key") String key,@Valid @RequestBody AcceptInput input) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore())
        .body(service.accept(actor,adult(authentication),key,input.invitationId(),input.token()));
  }
  @GetMapping("/{invitationId}/acceptance-results/{requestId}")
  ResponseEntity<InvitationAcceptanceService.Result> result(@AuthenticationPrincipal Jwt actor,
      @PathVariable String invitationId,@PathVariable String requestId) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.result(actor.getSubject(),invitationId,requestId));
  }
  private boolean adult(Authentication authentication) {
    return authentication.getAuthorities().stream().anyMatch(a->"SCOPE_tenant:create".equals(a.getAuthority()));
  }
  record PreviewInput(@NotBlank @Pattern(regexp="[A-Za-z0-9_-]{43}") String token) {}
  record AcceptInput(@NotBlank @Pattern(regexp="[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}") String invitationId,
      @NotBlank @Pattern(regexp="[A-Za-z0-9_-]{43}") String token) {}
}
