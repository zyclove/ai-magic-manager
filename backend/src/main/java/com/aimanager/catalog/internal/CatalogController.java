package com.aimanager.catalog.internal;

import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.fleet.Device;
import com.aimanager.shared.ItemPage;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.util.List;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/applications")
class CatalogController {
    private final CatalogService catalog;
    CatalogController(CatalogService catalog) { this.catalog = catalog; }
    @PostMapping @ResponseStatus(HttpStatus.CREATED)
    ApplicationDefinition create(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
                                 @Valid @RequestBody CreateApplication input,
                                 @RequestHeader(name = "Idempotency-Key", required = false) String key) {
        return catalog.create(tenantId, actor.getSubject(), input, key);
    }
    @GetMapping ItemPage<ApplicationDefinition> list(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
                                                    @RequestParam(defaultValue = "50") int limit, @RequestParam(required = false) String cursor) {
        return catalog.list(tenantId, actor.getSubject(), limit, cursor);
    }
    @GetMapping("/{applicationId}")
    ApplicationDefinition get(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String applicationId) {
        return catalog.requireDeclared(tenantId, actor.getSubject(), applicationId);
    }
    record CreateApplication(@NotBlank @Size(max = 100) String displayName, @NotNull Device.Platform platform,
                             @NotBlank @Size(max = 255) @Pattern(regexp = "[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+") String packageName,
                             @NotNull ApplicationDefinition.Profile profile,
                             @NotNull @Size(max = 8) List<@NotNull @Pattern(regexp = "[0-9a-f]{64}") String> signingDigests) {}
}
