package com.aimanager.fleet.internal;

import com.aimanager.fleet.*;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import jakarta.validation.Valid;
import io.swagger.v3.oas.annotations.security.SecurityRequirements;
import jakarta.validation.constraints.*;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1")
class FleetController {
    private final EnrollmentService enrollments;
    private final FleetReads reads;
    FleetController(EnrollmentService enrollments, FleetReads reads) { this.enrollments = enrollments; this.reads = reads; }

    @PostMapping("/tenants/{tenantId}/enrollments") @ResponseStatus(HttpStatus.CREATED)
    EnrollmentService.Ticket create(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @Valid @RequestBody Create input) {
        return enrollments.create(tenantId, actor, input.subjectId(), input.requestedMode(), input.platform());
    }

    @PostMapping("/enrollment-claims") @ResponseStatus(HttpStatus.CREATED)
    @SecurityRequirements
    EnrollmentService.Claimed claim(@Valid @RequestBody Claim input) { return enrollments.claim(input); }

    @PostMapping("/enrollment-claims/recover") @SecurityRequirements
    EnrollmentService.Claimed recover(@Valid @RequestBody Recover input) { return enrollments.recover(input); }

    @GetMapping("/tenants/{tenantId}/enrollments/{id}")
    Enrollment getEnrollment(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String id) {
        return reads.enrollment(tenantId, actor.getSubject(), id);
    }

    @PostMapping("/tenants/{tenantId}/enrollments/{id}/confirm")
    Device confirm(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String id, @Valid @RequestBody Confirm input) {
        var outcome = enrollments.confirm(tenantId, actor, id, input.pairingCode());
        if (!outcome.accepted()) throw new DomainException(HttpStatus.FORBIDDEN, "PAIRING_VERIFICATION_FAILED");
        return outcome.device();
    }

    @DeleteMapping("/tenants/{tenantId}/enrollments/{id}") @ResponseStatus(HttpStatus.NO_CONTENT)
    void cancel(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String id) {
        enrollments.cancel(tenantId, actor, id);
    }

    @GetMapping("/tenants/{tenantId}/devices")
    ItemPage<Device> devices(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
                             @RequestParam(defaultValue = "50") int limit, @RequestParam(required = false) String cursor) {
        return reads.devices(tenantId, actor.getSubject(), limit, cursor);
    }

    @GetMapping("/tenants/{tenantId}/devices/{id}")
    ResponseEntity<Device> device(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String id) {
        var result = reads.device(tenantId, actor.getSubject(), id);
        return ResponseEntity.ok().eTag(ResourceVersions.tag(result.version())).body(result);
    }

    @GetMapping("/tenants/{tenantId}/devices/{id}/capabilities")
    FleetReads.Capabilities capabilities(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String id) {
        return reads.capabilities(tenantId, actor.getSubject(), id);
    }

    @PostMapping("/tenants/{tenantId}/devices/{id}/revoke") @ResponseStatus(HttpStatus.NO_CONTENT)
    void revoke(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId, @PathVariable String id) {
        enrollments.revoke(tenantId, actor, id);
    }

    record Create(@NotBlank @Size(max = 36) String subjectId, @NotNull Device.Mode requestedMode, @NotNull Device.Platform platform) {}
    record Confirm(@NotBlank @Size(min = 8, max = 8) String pairingCode) {}
    record Claim(@NotBlank @Size(max = 36) String enrollmentId, @NotBlank @Pattern(regexp = "[A-Za-z0-9_-]{43}") String token,
                 @NotBlank @Size(max = 2048) String publicKeyJwk, @NotBlank @Size(max = 8192) String proof,
                 @NotBlank @Size(max = 100) String displayName, @NotBlank @Size(max = 100) String osVersion) {}
    record Recover(@NotBlank @Size(max = 36) String enrollmentId, @NotBlank @Pattern(regexp = "[A-Za-z0-9_-]{43}") String token,
                   @NotBlank @Size(max = 2048) String publicKeyJwk, @NotBlank @Size(max = 8192) String proof) {}
}
