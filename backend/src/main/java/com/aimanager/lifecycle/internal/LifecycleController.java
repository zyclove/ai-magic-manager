package com.aimanager.lifecycle.internal;

import com.aimanager.lifecycle.*;
import com.aimanager.shared.*;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.http.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

/** Destructive actions require current adult scope, recent MFA, a concrete preview and a strong device version. */
@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/devices/{deviceId}/deprovision")
class LifecycleController {
    private final LifecycleService lifecycle;
    LifecycleController(LifecycleService lifecycle) { this.lifecycle = lifecycle; }
    @PostMapping("/previews")
    ResponseEntity<DeprovisionPreview> preview(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
        @PathVariable String deviceId, @RequestHeader(name = "If-Match", required = false) String etag, @Valid @RequestBody Preview input) {
        var result = lifecycle.preview(tenantId, actor, deviceId, input.action(), etag);
        return ResponseEntity.status(HttpStatus.CREATED).eTag(ResourceVersions.tag(result.deviceVersion())).body(result);
    }
    @PostMapping("/operations")
    ResponseEntity<DeprovisionOperation> start(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
        @PathVariable String deviceId, @RequestHeader(name = "If-Match", required = false) String etag,
        @RequestHeader(name = "Idempotency-Key", required = false) String key, @Valid @RequestBody Confirm input) {
        return response(lifecycle.start(tenantId, actor, deviceId, input, etag, key), HttpStatus.CREATED);
    }
    @GetMapping("/operations")
    ItemPage<DeprovisionOperation> list(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
        @PathVariable String deviceId, @RequestParam(defaultValue = "50") int limit, @RequestParam(required = false) String cursor) {
        return lifecycle.list(tenantId, actor.getSubject(), deviceId, limit, cursor);
    }
    @GetMapping("/operations/{operationId}")
    ResponseEntity<DeprovisionOperation> get(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
        @PathVariable String deviceId, @PathVariable String operationId) {
        return response(lifecycle.get(tenantId, actor.getSubject(), deviceId, operationId), HttpStatus.OK);
    }
    @PostMapping("/operations/{operationId}/cancel")
    ResponseEntity<DeprovisionOperation> cancel(@AuthenticationPrincipal Jwt actor, @PathVariable String tenantId,
        @PathVariable String deviceId, @PathVariable String operationId, @RequestHeader(name = "If-Match", required = false) String etag,
        @RequestHeader(name = "Idempotency-Key", required = false) String key) {
        return response(lifecycle.cancel(tenantId, actor, deviceId, operationId, etag, key), HttpStatus.OK);
    }
    private ResponseEntity<DeprovisionOperation> response(DeprovisionOperation result, HttpStatus status) {
        return ResponseEntity.status(status).eTag(ResourceVersions.tag(result.version())).body(result);
    }
    record Preview(@NotNull Action action) {}
    record Confirm(@NotNull @Pattern(regexp = UUID) String previewId, @NotNull @Pattern(regexp = "[0-9a-f]{64}") String previewHash) {}
    enum Action { AGENT_UNENROLL, SYSTEM_UNMANAGE, DEVICE_WIPE }
    static final String UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
}
