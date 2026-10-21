package com.aimanager.tenant.internal;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

/** A copied link contains only an opaque id and secret. The API accepts that secret in POST bodies. */
@RestController
@RequestMapping("/api/v1")
class FamilyPhoneInvitationController {
  private final FamilyPhoneInvitationService families;
  private final FamilyInvitationAttempts attempts;
  FamilyPhoneInvitationController(FamilyPhoneInvitationService families,FamilyInvitationAttempts attempts){this.families=families;this.attempts=attempts;}

  @GetMapping("/tenants/{tenantId}/family-members")
  ResponseEntity<FamilyPhoneInvitationService.Members> members(@AuthenticationPrincipal Jwt actor,@PathVariable String tenantId) {
    return ok(families.members(tenantId,actor));
  }
  @PostMapping("/tenants/{tenantId}/family-guardian-declaration")
  ResponseEntity<FamilyPhoneInvitationService.DeclarationReceipt> declaration(@AuthenticationPrincipal Jwt actor,@PathVariable String tenantId,
      @Valid @RequestBody Declaration input) {
    return ok(families.declareGuardian(tenantId,actor,input));
  }
  @GetMapping("/tenants/{tenantId}/family-invitations")
  ResponseEntity<FamilyPhoneInvitationService.Invitations> invitations(@AuthenticationPrincipal Jwt actor,@PathVariable String tenantId) {
    return ok(families.invitations(tenantId,actor));
  }
  @PostMapping("/tenants/{tenantId}/family-invitations")
  ResponseEntity<FamilyPhoneInvitationService.Summary> issue(@AuthenticationPrincipal Jwt actor,@PathVariable String tenantId,
      @RequestHeader("Idempotency-Key") String key,@Valid @RequestBody Issue input) {
    return ResponseEntity.status(HttpStatus.CREATED).cacheControl(CacheControl.noStore()).body(families.issue(tenantId,actor,key,input));
  }
  @DeleteMapping("/tenants/{tenantId}/family-invitations/{invitationId}")
  ResponseEntity<Void> revoke(@AuthenticationPrincipal Jwt actor,@PathVariable String tenantId,@PathVariable String invitationId) {
    families.revoke(tenantId,actor,invitationId);
    return ResponseEntity.noContent().cacheControl(CacheControl.noStore()).build();
  }
  @DeleteMapping("/tenants/{tenantId}/family-members/{memberKey}")
  ResponseEntity<Void> remove(@AuthenticationPrincipal Jwt actor,@PathVariable String tenantId,@PathVariable String memberKey,
      @RequestHeader(value="If-Match",required=false) String etag,@RequestHeader("Idempotency-Key") String key) {
    families.remove(tenantId,actor,memberKey,etag,key);
    return ResponseEntity.noContent().cacheControl(CacheControl.noStore()).build();
  }
  @PostMapping("/family-invitations/preview")
  ResponseEntity<FamilyPhoneInvitationService.Preview> preview(@AuthenticationPrincipal Jwt actor,@Valid @RequestBody Secret input) {
    attempts.require(actor.getSubject());
    return ok(families.preview(actor,input));
  }
  @PostMapping("/family-invitations/accept")
  ResponseEntity<FamilyPhoneInvitationService.Acceptance> accept(@AuthenticationPrincipal Jwt actor,
      @RequestHeader("Idempotency-Key") String key,@Valid @RequestBody Accept input) {
    attempts.require(actor.getSubject());
    return ok(families.accept(actor,key,input));
  }
  private static <T>ResponseEntity<T> ok(T value){return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(value);}
  record Issue(@NotBlank @Size(max=36) String invitationId,@NotBlank @Size(max=16) String targetPhone,@NotBlank @Size(max=43) String token){}
  record Secret(@NotBlank @Size(max=36) String invitationId,@NotBlank @Size(max=43) String token){}
  record Accept(@NotBlank @Size(max=36) String invitationId,@NotBlank @Size(max=43) String token,
      boolean adultGuardian,@NotBlank @Size(max=40) String declarationVersion){}
  record Declaration(boolean adultGuardian,@NotBlank @Size(max=40) String declarationVersion){}
}
