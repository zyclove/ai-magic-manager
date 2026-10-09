package com.aimanager.tenant.internal;

import com.aimanager.tenant.Tenant;
import com.aimanager.tenant.TenantAccess;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenantId}")
class ConsoleTenantController {
    private final ConsoleTenantService service;
    private final TenantAccess access;
    ConsoleTenantController(ConsoleTenantService service, TenantAccess access) { this.service = service; this.access = access; }
    @GetMapping("/membership")
    TenantAccess.Grant membership(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId) {
        return access.requireRole(tenantId, actor.getSubject(), TenantAccess.Role.values());
    }
    @GetMapping("/members")
    ConsoleTenantService.Members members(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
                                        @RequestParam(defaultValue="50") int limit, @RequestParam(required=false) String cursor) {
        return service.members(tenantId, actor.getSubject(), limit, cursor);
    }
    @GetMapping("/invitations")
    ItemPage<ConsoleTenantService.InvitationSummary> invitations(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
                                        @RequestParam(defaultValue="50") int limit, @RequestParam(required=false) String cursor) {
        return service.invitations(tenantId, actor.getSubject(), limit, cursor);
    }
    @PatchMapping
    ResponseEntity<Tenant> update(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
                                 @Valid @RequestBody Edit input, @RequestHeader(name="If-Match", required=false) String etag) {
        Tenant result = service.update(tenantId, actor.getSubject(), input.name(), input.timeZone(), etag);
        return ResponseEntity.ok().eTag(ResourceVersions.tag(result.version())).body(result);
    }
    record Edit(@NotBlank @Size(max=100) String name, @NotBlank @Size(max=100) String timeZone) {}
}
