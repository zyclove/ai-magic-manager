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
    MembershipController(MembershipService members) { this.members = members; }

    @PostMapping("/tenants/{tenantId}/invitations")
    @ResponseStatus(HttpStatus.CREATED)
    MembershipService.Invitation invite(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
                                        @Valid @RequestBody Invite input) {
        return members.invite(tenantId, actor, input.recipientEmail(), input.role(), input.subjectId());
    }

    @PostMapping("/invitations/accept")
    MembershipService.Accepted accept(@AuthenticationPrincipal Jwt actor, Authentication authentication,
                                      @Valid @RequestBody Accept input) {
        boolean adult = authentication.getAuthorities().stream().anyMatch(a -> "SCOPE_tenant:create".equals(a.getAuthority()));
        return members.accept(actor, adult, input.token());
    }

    @DeleteMapping("/tenants/{tenantId}/members/{memberActor}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    void revoke(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String memberActor) {
        members.revoke(tenantId, actor, memberActor);
    }

    @DeleteMapping("/tenants/{tenantId}/invitations/{invitationId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    void cancelInvitation(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String invitationId) {
        members.cancelInvitation(tenantId, actor, invitationId);
    }

    record Invite(@NotBlank @Email @Size(max = 254) String recipientEmail, @NotNull Role role,
                  @Size(max = 36) String subjectId) {}
    record Accept(@NotBlank @Size(max = 128) String token) {}
}
