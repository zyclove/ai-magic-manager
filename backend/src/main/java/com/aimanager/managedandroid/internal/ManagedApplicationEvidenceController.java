package com.aimanager.managedandroid.internal;

import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.ResourceVersions;
import io.swagger.v3.oas.annotations.Operation;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

/** Adult server-side report workflow; no device-submitted fact or policy execution endpoint. */
@RestController
class ManagedApplicationEvidenceController {
  private static final String ROOT =
      "/api/v1/tenants/{tenant}/managed-android/agent-bindings/{binding}/applications/{application}/evidence";
  private final ManagedApplicationEvidenceStore store;
  private final ManagedApplicationEvidenceService service;
  private final RecentAuthentication recent;

  ManagedApplicationEvidenceController(
      ManagedApplicationEvidenceStore store,
      ManagedApplicationEvidenceService service,
      RecentAuthentication recent) {
    this.store = store;
    this.service = service;
    this.recent = recent;
  }

  @PostMapping(ROOT + "/refresh")
  @Operation(summary = "刷新当前绑定中指定应用的提供方证据；不执行策略，需要近期多因素认证")
  ResponseEntity<ManagedApplicationEvidenceStore.View> refresh(
      @PathVariable String tenant,
      @PathVariable String binding,
      @PathVariable String application,
      @AuthenticationPrincipal Jwt actor,
      @RequestHeader(value = "If-Match", required = false) String version) {
    recent.require(actor);
    return response(
        service.refresh(
            tenant, actor.getSubject(), binding, ResourceVersions.require(version), application));
  }

  @GetMapping(ROOT)
  @Operation(summary = "读取当前应用证据状态；重新校验授权与时效，不刷新报告")
  ResponseEntity<ManagedApplicationEvidenceStore.View> get(
      @PathVariable String tenant,
      @PathVariable String binding,
      @PathVariable String application,
      @AuthenticationPrincipal Jwt actor,
      @RequestHeader(value = "If-Match", required = false) String version) {
    return response(
        store.get(
            tenant, actor.getSubject(), binding, ResourceVersions.require(version), application));
  }

  private ResponseEntity<ManagedApplicationEvidenceStore.View> response(
      ManagedApplicationEvidenceStore.View view) {
    // If-Match always names the parent binding version; do not advertise evidence version as its
    // ETag.
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(view);
  }
}
