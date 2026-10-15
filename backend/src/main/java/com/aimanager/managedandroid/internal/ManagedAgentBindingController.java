package com.aimanager.managedandroid.internal;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** 管理员只读元数据；设备挑战固定入口只从设备认证上下文取得归属。 */
@RestController
class ManagedAgentBindingController {
  private static final String ROOT = "/api/v1/tenants/{tenantId}/managed-android/agent-bindings";
  private final ManagedAgentBindingStore store;
  private final ManagedAgentBindingService service;
  private final RecentAuthentication recent;

  ManagedAgentBindingController(
      ManagedAgentBindingStore store,
      ManagedAgentBindingService service,
      RecentAuthentication recent) {
    this.store = store;
    this.service = service;
    this.recent = recent;
  }

  @PostMapping(ROOT)
  @Operation(summary = "发起或恢复受管儿童端绑定请求；需要近期多因素认证")
  ResponseEntity<ManagedAgentBindingStore.View> create(
      @PathVariable String tenantId,
      @AuthenticationPrincipal Jwt actor,
      @RequestHeader(value = "Idempotency-Key", required = false) String request,
      @RequestBody Create input) {
    recent.require(actor);
    if (input == null) throw DomainException.invalid("INVALID_MANAGED_BINDING");
    return response(
        store.create(
            tenantId,
            actor.getSubject(),
            request,
            input.enrollmentId(),
            input.deviceId(),
            input.registrationId()),
        201);
  }

  @GetMapping(ROOT)
  @Operation(summary = "分页查看受管儿童端绑定记录，不返回挑战值")
  ResponseEntity<ItemPage<ManagedAgentBindingStore.View>> list(
      @PathVariable String tenantId,
      @AuthenticationPrincipal Jwt actor,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(store.list(tenantId, actor.getSubject(), limit, cursor));
  }

  @GetMapping(ROOT + "/{id}")
  @Operation(summary = "查询绑定记录及当前资源版本")
  ResponseEntity<ManagedAgentBindingStore.View> get(
      @PathVariable String tenantId, @PathVariable String id, @AuthenticationPrincipal Jwt actor) {
    return response(store.get(tenantId, actor.getSubject(), id), 200);
  }

  @GetMapping(ROOT + "/context/{enrollmentId}")
  @Operation(summary = "读取绑定接入条件、当前关联及同一学生的已激活设备候选")
  ResponseEntity<ManagedAgentBindingStore.ContextView> selectionContext(
      @PathVariable String tenantId,
      @PathVariable String enrollmentId,
      @AuthenticationPrincipal Jwt actor,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(store.selectionContext(tenantId, actor.getSubject(), enrollmentId, limit, cursor));
  }

  @PostMapping(ROOT + "/{id}/verify")
  @Operation(summary = "核验提供方证明并一次性消费挑战；202 表示等待反馈")
  ResponseEntity<ManagedAgentBindingStore.View> verify(
      @PathVariable String tenantId,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      @RequestHeader(value = "If-Match", required = false) String version) {
    recent.require(actor);
    var result =
        service.verify(tenantId, actor.getSubject(), id, ResourceVersions.require(version));
    return response(result, "PENDING".equals(result.state()) ? 202 : 200);
  }

  @PostMapping(ROOT + "/{id}/revoke")
  @Operation(summary = "撤销本地关联；不退管提供方设备或释放合同名额")
  ResponseEntity<ManagedAgentBindingStore.View> revoke(
      @PathVariable String tenantId,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      @RequestHeader(value = "If-Match", required = false) String version) {
    recent.require(actor);
    return response(
        store.revoke(tenantId, actor.getSubject(), id, ResourceVersions.require(version)), 200);
  }

  @GetMapping("/api/v1/device-api/managed-agent-challenge")
  @SecurityRequirement(name = "deviceBearer")
  @Operation(summary = "当前已认证设备领取短期挑战；204 表示无待处理请求")
  ResponseEntity<ManagedAgentBindingStore.Challenge> challenge(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal principal) {
    var result = store.challenge(DeviceContext.from(principal));
    return ResponseEntity.status(result.isPresent() ? 200 : 204)
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(result.orElse(null));
  }

  private static ResponseEntity<ManagedAgentBindingStore.View> response(
      ManagedAgentBindingStore.View view, int status) {
    return ResponseEntity.status(status)
        .eTag(ResourceVersions.tag(view.version()))
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(view);
  }

  record Create(String enrollmentId, String deviceId, String registrationId) {}
}
