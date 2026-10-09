package com.aimanager.lifecycle.internal;

import com.aimanager.lifecycle.DeprovisionOperation;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.web.bind.annotation.*;

/** Narrow cleanup channel survives ordinary credential revocation; it cannot change policies or system ownership. */
@RestController
@RequestMapping("/api/v1/device-cleanup")
@SecurityRequirement(name = "cleanupProof")
class CleanupController {
    private final LifecycleService lifecycle;
    CleanupController(LifecycleService lifecycle) { this.lifecycle = lifecycle; }
    @GetMapping("/command")
    Command command(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal) { return lifecycle.command(CleanupContext.from(principal)); }
    @GetMapping("/signing-keys")
    java.util.Map<String, Object> keys(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal) {
        return lifecycle.verificationKeys(CleanupContext.from(principal));
    }
    @PostMapping("/receipts")
    DeprovisionOperation receipt(@AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal, @Valid @RequestBody Receipt input) {
        return lifecycle.receipt(CleanupContext.from(principal), input);
    }
    record Command(String operationId, String commandId, long notAfter, String compactJws) {
        @Override public String toString() { return "CleanupCommand[commandId=" + commandId + "]"; }
    }
    record Receipt(@NotNull @Pattern(regexp = LifecycleController.UUID) String receiptId,
        @NotNull @Pattern(regexp = LifecycleController.UUID) String commandId, @NotNull @Pattern(regexp = "[0-9a-f]{64}") String commandHash,
        @NotNull Stage stage, FailureReason reasonCode) {}
    enum Stage { RECEIVED, AGENT_DATA_CLEARED, FAILED }
    enum FailureReason { STORAGE_FAILURE, KEY_UNAVAILABLE, UNSUPPORTED_AGENT, USER_ACTION_REQUIRED }
}
