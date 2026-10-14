package com.aimanager.subject.internal;

import com.aimanager.shared.ItemPage;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

/** 成人管理接口不替换旧档案 API；所有响应禁止客户端缓存。 */
@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/subjects")
class SubjectManagementController {
  private final SubjectManagementService service;
  SubjectManagementController(SubjectManagementService service) { this.service = service; }

  @GetMapping("/management")
  ResponseEntity<ItemPage<SubjectManagementService.Snapshot>> list(@AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId, @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor, @RequestParam(defaultValue = "false") boolean includeArchived) {
    return response(service.list(tenantId, actor.getSubject(), limit, cursor, includeArchived));
  }

  @GetMapping("/{subjectId}/management")
  ResponseEntity<SubjectManagementService.Snapshot> get(@AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId, @PathVariable String subjectId) {
    return response(service.get(tenantId, actor.getSubject(), subjectId));
  }

  @PostMapping("/changes")
  ResponseEntity<SubjectManagementService.Snapshot> change(@AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId, @RequestBody SubjectManagementService.Change input,
      @RequestHeader("Idempotency-Key") String key) {
    return response(service.change(tenantId, actor, input, key));
  }

  @PostMapping("/operation-results/{requestId}/query")
  ResponseEntity<SubjectManagementService.Result> query(@AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId, @PathVariable String requestId,
      @RequestBody SubjectManagementService.Change input) {
    return response(service.query(tenantId, actor.getSubject(), requestId, input));
  }

  private <T> ResponseEntity<T> response(T body) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(body);
  }
}
