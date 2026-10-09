package com.aimanager.tenant.internal;

import com.aimanager.tenant.TenantAccess.Role;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1")
class MembershipController {
  private final MembershipService members;

  MembershipController(MembershipService members) {
    this.members = members;
  }

  @PostMapping("/tenants/{tenantId}/invitations")
  @ResponseStatus(HttpStatus.CREATED)
  MembershipService.Invitation invite(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @Valid @RequestBody Invite input) {
    return members.invite(
        tenantId, actor, input.recipientEmail(), input.role(), input.subjectId(), input.classIds());
  }

  @PostMapping("/invitations/accept")
  MembershipService.Accepted accept(
      @AuthenticationPrincipal Jwt actor,
      Authentication authentication,
      @Valid @RequestBody Accept input) {
    boolean adult =
        authentication.getAuthorities().stream()
            .anyMatch(a -> "SCOPE_tenant:create".equals(a.getAuthority()));
    return members.accept(actor, adult, input.token());
  }

  @DeleteMapping("/tenants/{tenantId}/members/{memberActor}")
  @ResponseStatus(HttpStatus.NO_CONTENT)
  void revoke(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String memberActor) {
    members.revoke(tenantId, actor, memberActor);
  }

  @DeleteMapping("/tenants/{tenantId}/invitations/{invitationId}")
  @ResponseStatus(HttpStatus.NO_CONTENT)
  void cancelInvitation(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String invitationId) {
    members.cancelInvitation(tenantId, actor, invitationId);
  }

  @GetMapping("/tenants/{tenantId}/members/{memberKey}/access")
  org.springframework.http.ResponseEntity<MembershipService.MemberAccess> memberAccess(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String memberKey) {
    var result = members.memberAccess(tenantId, actor.getSubject(), memberKey);
    return org.springframework.http.ResponseEntity.ok()
        .eTag(com.aimanager.shared.ResourceVersions.tag(result.version()))
        .body(result);
  }

  @PatchMapping("/tenants/{tenantId}/members/{memberKey}/access")
  org.springframework.http.ResponseEntity<MembershipService.MemberAccess> changeAccess(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String memberKey,
      @Valid @RequestBody EditAccess input,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    var result =
        members.changeAccess(
            tenantId,
            actor,
            memberKey,
            input.role(),
            input.subjectId(),
            input.classIds(),
            etag,
            key);
    return org.springframework.http.ResponseEntity.ok()
        .eTag(com.aimanager.shared.ResourceVersions.tag(result.version()))
        .body(result);
  }

  record EditAccess(
      @NotNull Role role,
      @Size(max = 36) String subjectId,
      @Size(max = 50) java.util.List<@NotBlank @Size(max = 36) String> classIds) {}

  @DeleteMapping("/tenants/{tenantId}/members/{memberKey}/access")
  @ResponseStatus(HttpStatus.NO_CONTENT)
  void revokeAccess(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String memberKey,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    members.revokeAccess(tenantId, actor, memberKey, etag, key);
  }

  @GetMapping("/tenants/{tenantId}/members/{memberKey}/access-history")
  com.aimanager.shared.ItemPage<MembershipService.AccessChange> accessHistory(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String memberKey,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return members.accessHistory(tenantId, actor.getSubject(), memberKey, limit, cursor);
  }

  record Invite(
      @NotBlank @Email @Size(max = 254) String recipientEmail,
      @NotNull Role role,
      @Size(max = 36) String subjectId,
      @Size(max = 50) java.util.List<@NotBlank @Size(max = 36) String> classIds) {}

  record Accept(@NotBlank @Size(max = 128) String token) {}
}
