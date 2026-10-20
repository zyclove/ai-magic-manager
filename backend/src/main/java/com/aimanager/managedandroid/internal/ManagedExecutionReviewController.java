package com.aimanager.managedandroid.internal;

import com.aimanager.identity.RecentAuthentication;
import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ResourceVersions;
import io.swagger.v3.oas.annotations.Operation;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

/**
 * Explicit administrative consent to another bounded observation round. No provider write, manual
 * success override, expiry extension, or cancellation reversal is available through this endpoint.
 */
@RestController
class ManagedExecutionReviewController {
  private final ManagedPolicyExecutionJournal journal;
  private final RecentAuthentication recent;
  private final ManagedAndroidGateway gateway;
  private final ObjectProvider<ManagedExecutionRecoveryJob> recovery;
  private final boolean enabled;

  ManagedExecutionReviewController(
      ManagedPolicyExecutionJournal journal,
      RecentAuthentication recent,
      ManagedAndroidGateway gateway,
      ObjectProvider<ManagedExecutionRecoveryJob> recovery,
      @Value("${manager.emm.execution.manual-review.enabled:false}") boolean enabled,
      @Value("${manager.emm.execution.device-recovery.enabled:false}") boolean recoveryEnabled) {
    if (enabled && !recoveryEnabled)
      throw new IllegalArgumentException("Manual execution review requires device recovery");
    this.journal = journal;
    this.recent = recent;
    this.gateway = gateway;
    this.recovery = recovery;
    this.enabled = enabled;
  }

  @GetMapping("/api/v1/tenants/{tenant}/managed-android/executions/{id}/review-eligibility")
  @Operation(summary = "只读查看当前复核资格和原因；不续期、不触发设备查询，也不要求近期认证")
  ResponseEntity<ManagedPolicyExecutionJournal.ReviewEligibility> eligibility(
      @PathVariable String tenant, @PathVariable String id, @AuthenticationPrincipal Jwt actor) {
    journal.get(tenant, actor.getSubject(), id);
    var service = availability();
    // Availability/time can change without a task revision. Do not issue a projection ETag.
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(
            journal.reviewEligibility(
                tenant, actor.getSubject(), id, service.available(), service.provider()));
  }

  @PostMapping("/api/v1/tenants/{tenant}/managed-android/executions/{id}/recheck-device")
  @Operation(summary = "申请重新核实待复核设备；需要近期多因素认证和强 If-Match，只读且不延长原有效期")
  ResponseEntity<ManagedPolicyExecutionJournal.View> recheck(
      @PathVariable String tenant,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      @RequestHeader(value = "If-Match", required = false) String version) {
    recent.require(actor);
    long expected = ResourceVersions.require(version);
    // Authorize the existing tenant/task before exposing operational availability. The mutation
    // repeats write authorization under locks and accepts no caller-supplied remote identifiers.
    journal.requireReviewAdministrator(tenant, actor.getSubject(), id);
    var service = availability();
    if (!service.available())
      throw new DomainException(HttpStatus.CONFLICT, "EXECUTION_RECHECK_UNAVAILABLE");
    var view =
        journal.requestDeviceRecheck(tenant, actor.getSubject(), id, expected, service.provider());
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .eTag(ResourceVersions.tag(view.revision()))
        .body(view);
  }

  private record Availability(boolean available, String provider) {}

  private Availability availability() {
    // All checks are local. Default-off does not touch the gateway or create a recovery consumer.
    if (!enabled || recovery.getIfAvailable() == null || !gateway.available())
      return new Availability(false, null);
    return new Availability(true, gateway.providerCode());
  }
}
