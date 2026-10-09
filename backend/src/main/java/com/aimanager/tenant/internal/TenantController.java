package com.aimanager.tenant.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.shared.ItemPage;
import com.aimanager.tenant.Tenant;
import com.aimanager.tenant.TenantAccess;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

import static com.aimanager.tenant.TenantAccess.Role.*;

@RestController
@RequestMapping("/api/v1/tenants")
class TenantController {
    private final TenantService tenants;
    private final TenantAccess access;
    private final AuditService audit;
    TenantController(TenantService tenants, TenantAccess access, AuditService audit) { this.tenants = tenants; this.access = access; this.audit = audit; }

    /** Creation scope is enforced by the resource-server security chain, issued only to verified adults. */
    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    Tenant create(@AuthenticationPrincipal Jwt actor, @Valid @RequestBody CreateTenant input,
                  @RequestHeader(name = "Idempotency-Key", required = false) String key) {
        return tenants.create(actor.getSubject(), input.name(), input.kind(), input.timeZone(), key);
    }

    @GetMapping
    ItemPage<Tenant> list(@AuthenticationPrincipal Jwt actor, @RequestParam(defaultValue = "50") int limit,
                          @RequestParam(required = false) String cursor) {
        return tenants.list(actor.getSubject(), limit, cursor);
    }

    @GetMapping("/{tenantId}/audit-events")
    ItemPage<AuditService.Event> audit(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
                                     @RequestParam(defaultValue = "50") int limit, @RequestParam(required = false) String cursor) {
        access.requireRole(tenantId, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
        return audit.list(tenantId, limit, cursor);
    }

    record CreateTenant(@NotBlank @Size(max = 100) String name, @NotNull Tenant.Kind kind,
                        @NotBlank @Size(max = 100) String timeZone) {}
}
