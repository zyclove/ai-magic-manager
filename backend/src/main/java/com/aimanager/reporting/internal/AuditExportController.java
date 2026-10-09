package com.aimanager.reporting.internal;

import com.aimanager.audit.AuditSelection;
import com.aimanager.shared.ItemPage;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import org.springframework.http.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenant}/audit-exports")
class AuditExportController {
  private final AuditExportService exports;

  AuditExportController(AuditExportService exports) {
    this.exports = exports;
  }

  record Create(
      @NotNull Long from,
      @NotNull Long to,
      String action,
      String resourceId,
      String correlationId) {}

  @PostMapping
  @ResponseStatus(HttpStatus.ACCEPTED)
  ExportStore.Job create(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenant,
      @Valid @RequestBody Create input,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return exports.create(
        tenant,
        actor,
        new AuditSelection(
            input.from(), input.to(), input.action(), input.resourceId(), input.correlationId()),
        key);
  }

  @GetMapping
  ItemPage<ExportStore.Job> list(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenant,
      @RequestParam(defaultValue = "20") int limit,
      @RequestParam(required = false) String cursor) {
    return exports.list(tenant, actor, limit, cursor);
  }

  @GetMapping("/{id}")
  ExportStore.Job get(
      @AuthenticationPrincipal Jwt actor, @PathVariable String tenant, @PathVariable String id) {
    return exports.get(tenant, id, actor);
  }

  @PostMapping("/{id}/cancel")
  ExportStore.Job cancel(
      @AuthenticationPrincipal Jwt actor, @PathVariable String tenant, @PathVariable String id) {
    return exports.cancel(tenant, id, actor);
  }

  @GetMapping("/{id}/content")
  ResponseEntity<byte[]> content(
      @AuthenticationPrincipal Jwt actor, @PathVariable String tenant, @PathVariable String id) {
    byte[] bytes = exports.content(tenant, id, actor);
    return ResponseEntity.ok()
        .contentType(MediaType.APPLICATION_JSON)
        .contentLength(bytes.length)
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .header(
            HttpHeaders.CONTENT_DISPOSITION,
            ContentDisposition.attachment().filename("audit-" + id + ".json").build().toString())
        .body(bytes);
  }
}
