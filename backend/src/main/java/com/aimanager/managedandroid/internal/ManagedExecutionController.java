package com.aimanager.managedandroid.internal;

import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import io.swagger.v3.oas.annotations.Operation;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

/**
 * Administrative observation and local cancellation only; does not admit tasks or dispatch provider
 * writes.
 */
@RestController
class ManagedExecutionController {
  private static final String ROOT = "/api/v1/tenants/{tenant}/managed-android/executions";
  private final ManagedExecutionQueries queries;
  private final ManagedPolicyExecutionJournal journal;
  private final RecentAuthentication recent;

  ManagedExecutionController(
      ManagedExecutionQueries queries,
      ManagedPolicyExecutionJournal journal,
      RecentAuthentication recent) {
    this.queries = queries;
    this.journal = journal;
    this.recent = recent;
  }

  @GetMapping(ROOT)
  @Operation(summary = "分页查看受管策略执行记录，支持设备、发布记录和状态筛选")
  ResponseEntity<ItemPage<ManagedPolicyExecutionJournal.View>> list(
      @PathVariable String tenant,
      @AuthenticationPrincipal Jwt actor,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor,
      @RequestParam(required = false) String deviceId,
      @RequestParam(required = false) String publicationId,
      @RequestParam(required = false) ManagedPolicyExecutionJournal.State state) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(
            queries.list(
                tenant, actor.getSubject(), limit, cursor, deviceId, publicationId, state));
  }

  @GetMapping(ROOT + "/{id}")
  @Operation(summary = "查看受管执行状态与当前版本，不返回提供方凭证或内部租约")
  ResponseEntity<ManagedPolicyExecutionJournal.View> get(
      @PathVariable String tenant, @PathVariable String id, @AuthenticationPrincipal Jwt actor) {
    return response(journal.get(tenant, actor.getSubject(), id));
  }

  @GetMapping(ROOT + "/{id}/events")
  @Operation(summary = "按版本递增分页查看受管执行时间线")
  ResponseEntity<ItemPage<ManagedExecutionQueries.Event>> events(
      @PathVariable String tenant,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(queries.events(tenant, actor.getSubject(), id, limit, cursor));
  }

  @PostMapping(ROOT + "/{id}/cancel")
  @Operation(summary = "取消本地执行或登记待复核；需要近期多因素认证及强 If-Match，不回滚设备策略")
  ResponseEntity<ManagedPolicyExecutionJournal.View> cancel(
      @PathVariable String tenant,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      @RequestHeader(value = "If-Match", required = false) String version) {
    recent.require(actor);
    return response(
        journal.cancel(tenant, actor.getSubject(), id, ResourceVersions.require(version)));
  }

  private ResponseEntity<ManagedPolicyExecutionJournal.View> response(
      ManagedPolicyExecutionJournal.View view) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .eTag(ResourceVersions.tag(view.revision()))
        .body(view);
  }
}
