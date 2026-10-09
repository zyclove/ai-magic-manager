package com.aimanager.policy.internal;

import com.aimanager.policy.*;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.util.List;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenantId}")
class PolicyController {
    private final PolicyService policies;
    PolicyController(PolicyService policies) { this.policies = policies; }
    @PostMapping("/policies")
    ResponseEntity<PolicyDraft> create(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
                                       @Valid @RequestBody CreateDraft input, @RequestHeader(name = "Idempotency-Key", required = false) String key) {
        var draft = policies.create(tenantId, actor.getSubject(), input, key);
        return ResponseEntity.status(HttpStatus.CREATED).eTag(ResourceVersions.tag(draft.revision())).body(draft);
    }
    @GetMapping("/policies")
    ItemPage<PolicyDraft> list(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
                              @RequestParam(defaultValue = "50") int limit, @RequestParam(required = false) String cursor,
                              @RequestParam(required = false) PolicyDraft.Kind kind) {
        return policies.list(tenantId, actor.getSubject(), limit, cursor, kind);
    }
    @GetMapping("/policies/{policyId}")
    ResponseEntity<PolicyDraft> get(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String policyId) {
        var draft = policies.get(tenantId, actor.getSubject(), policyId);
        return ResponseEntity.ok().eTag(ResourceVersions.tag(draft.revision())).body(draft);
    }
    @PutMapping("/policies/{policyId}")
    ResponseEntity<PolicyDraft> edit(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String policyId,
                                    @Valid @RequestBody EditDraft input, @RequestHeader(name = "If-Match", required = false) String etag) {
        var draft = policies.update(tenantId, actor.getSubject(), policyId, input, etag);
        return ResponseEntity.ok().eTag(ResourceVersions.tag(draft.revision())).body(draft);
    }
    @PostMapping("/policies/{policyId}/copies")
    ResponseEntity<PolicyDraft> copy(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String policyId,
                                    @Valid @RequestBody Named input, @RequestHeader(name = "If-Match", required = false) String etag,
                                    @RequestHeader(name = "Idempotency-Key", required = false) String key) {
        var draft = policies.copyTemplate(tenantId, actor.getSubject(), policyId, input.name(), etag, key);
        return ResponseEntity.status(HttpStatus.CREATED).eTag(ResourceVersions.tag(draft.revision())).body(draft);
    }
    @PostMapping("/policies/{policyId}/previews") @ResponseStatus(HttpStatus.CREATED)
    PolicyPreview preview(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String policyId,
                          @Valid @RequestBody Preview input, @RequestHeader(name = "If-Match", required = false) String etag) {
        return policies.preview(tenantId, actor.getSubject(), policyId, etag, input.deviceIds());
    }
    @PostMapping("/policies/{policyId}/publications") @ResponseStatus(HttpStatus.CREATED)
    PolicyPublication publish(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String policyId,
                              @Valid @RequestBody Publish input, @RequestHeader(name = "If-Match", required = false) String etag,
                              @RequestHeader(name = "Idempotency-Key", required = false) String key) {
        return policies.publish(tenantId, actor, policyId, input, etag, key);
    }
    @GetMapping("/policies/{policyId}/versions")
    ItemPage<PolicyVersion> versions(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String policyId,
                                    @RequestParam(defaultValue = "50") int limit, @RequestParam(required = false) String cursor) {
        return policies.versions(tenantId, actor.getSubject(), policyId, limit, cursor);
    }
    @GetMapping("/policies/{policyId}/versions/{versionId}")
    PolicyVersion version(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String policyId, @PathVariable String versionId) {
        return policies.version(tenantId, actor.getSubject(), policyId, versionId);
    }
    @GetMapping("/policy-publications/{publicationId}")
    PolicyPublication operation(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String publicationId) {
        return policies.publication(tenantId, actor.getSubject(), publicationId);
    }
    @PostMapping("/policies/{policyId}/versions/{versionId}/rollback-drafts")
    ResponseEntity<PolicyDraft> rollback(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String policyId,
                                        @PathVariable String versionId, @Valid @RequestBody Named input,
                                        @RequestHeader(name = "If-Match", required = false) String etag,
                                        @RequestHeader(name = "Idempotency-Key", required = false) String key) {
        var draft = policies.rollbackDraft(tenantId, actor, policyId, versionId, input.name(), etag, key);
        return ResponseEntity.status(HttpStatus.CREATED).eTag(ResourceVersions.tag(draft.revision())).body(draft);
    }
    record CreateDraft(@NotBlank @Size(max = 100) String name, @NotNull PolicyDraft.Kind kind,
                       @NotNull @Size(max = 100) List<@NotNull @Valid PolicyRule> rules) {}
    record EditDraft(@NotBlank @Size(max = 100) String name, @NotNull @Size(max = 100) List<@NotNull @Valid PolicyRule> rules) {}
    record Named(@NotBlank @Size(max = 100) String name) {}
    record Preview(@NotNull @Size(min = 1, max = 50) List<@NotNull @Pattern(regexp = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}") String> deviceIds) {}
    record Publish(@NotNull @Pattern(regexp = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}") String previewId,
                   @NotNull @Pattern(regexp = "[0-9a-f]{64}") String previewHash, @NotNull PolicyPublication.Mode mode) {}
}
