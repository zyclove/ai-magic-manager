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

/** Current administrative progress and explicit local cancellation of preparation requests. */
@RestController
class ManagedPreparationController {
  private static final String ROOT =
      "/api/v1/tenants/{tenant}/managed-android/preparation-requests";
  private final ManagedPreparationQueries queries;
  private final ManagedPreparationRequestJournal journal;
  private final RecentAuthentication recent;

  ManagedPreparationController(
      ManagedPreparationQueries queries,
      ManagedPreparationRequestJournal journal,
      RecentAuthentication recent) {
    this.queries = queries;
    this.journal = journal;
    this.recent = recent;
  }

  @GetMapping(ROOT)
  @Operation(summary = "按发布分页查看准备请求，最多 50 条；进入执行不代表设备已生效")
  ResponseEntity<ItemPage<ManagedPreparationRequestJournal.View>> list(
      @PathVariable String tenant,
      @AuthenticationPrincipal Jwt actor,
      @RequestParam String publicationId,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return privateResponse()
        .body(queries.list(tenant, actor.getSubject(), publicationId, limit, cursor));
  }

  @GetMapping(ROOT + "/summary")
  @Operation(summary = "读取发布的准备状态计数；单次数据库快照，不包含设备生效结论")
  ResponseEntity<ManagedPreparationQueries.Summary> summary(
      @PathVariable String tenant,
      @AuthenticationPrincipal Jwt actor,
      @RequestParam String publicationId) {
    return privateResponse().body(queries.summary(tenant, actor.getSubject(), publicationId));
  }

  @GetMapping(ROOT + "/{id}")
  @Operation(summary = "查看准备状态、原因和执行记录引用，返回当前强 ETag")
  ResponseEntity<ManagedPreparationRequestJournal.View> get(
      @PathVariable String tenant, @PathVariable String id, @AuthenticationPrincipal Jwt actor) {
    return detail(journal.get(tenant, actor.getSubject(), id));
  }

  @PostMapping(ROOT + "/{id}/cancel")
  @Operation(summary = "取消准备请求；需要近期多因素认证及强 If-Match，已进入执行返回冲突")
  ResponseEntity<ManagedPreparationRequestJournal.View> cancel(
      @PathVariable String tenant,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      @RequestHeader(value = "If-Match", required = false) String version) {
    recent.require(actor);
    return detail(
        journal.cancel(tenant, actor.getSubject(), id, ResourceVersions.require(version)));
  }

  private ResponseEntity<ManagedPreparationRequestJournal.View> detail(
      ManagedPreparationRequestJournal.View view) {
    return privateResponse().eTag(ResourceVersions.tag(view.revision())).body(view);
  }

  private ResponseEntity.BodyBuilder privateResponse() {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).varyBy("Authorization");
  }
}
