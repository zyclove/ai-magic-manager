package com.aimanager.reporting.internal;

import com.aimanager.shared.ItemPage;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import java.util.List;
import org.springframework.http.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenant}/usage-report-jobs")
class ReportJobController {
  private final ReportJobService jobs;

  ReportJobController(ReportJobService jobs) {
    this.jobs = jobs;
  }

  record Create(
      @NotNull List<String> deviceIds,
      @NotNull Long from,
      @NotNull Long to,
      @NotNull String timeZone,
      @NotNull String period,
      @NotNull UsageReportScope.Selection scope) {}

  @PostMapping
  ResponseEntity<ReportJobStore.Job> create(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenant,
      @Valid @RequestBody Create input,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(
        HttpStatus.ACCEPTED,
        jobs.create(
            tenant,
            actor,
            new ReportJobSelection(
                input.deviceIds(),
                input.from(),
                input.to(),
                input.timeZone(),
                input.period(),
                input.scope()),
            key));
  }

  @GetMapping
  ResponseEntity<ItemPage<ReportJobStore.Job>> list(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenant,
      @RequestParam(defaultValue = "20") int limit,
      @RequestParam(required = false) String cursor) {
    return response(HttpStatus.OK, jobs.list(tenant, actor, limit, cursor));
  }

  @GetMapping("/{id}")
  ResponseEntity<ReportJobStore.Job> get(
      @AuthenticationPrincipal Jwt actor, @PathVariable String tenant, @PathVariable String id) {
    return response(HttpStatus.OK, jobs.get(tenant, id, actor));
  }

  @PostMapping("/{id}/cancel")
  ResponseEntity<ReportJobStore.Job> cancel(
      @AuthenticationPrincipal Jwt actor, @PathVariable String tenant, @PathVariable String id) {
    return response(HttpStatus.OK, jobs.cancel(tenant, id, actor));
  }

  private <T> ResponseEntity<T> response(HttpStatus status, T body) {
    return ResponseEntity.status(status)
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(body);
  }

  @GetMapping("/{id}/parts/{ordinal}")
  ResponseEntity<byte[]> content(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenant,
      @PathVariable String id,
      @PathVariable int ordinal) {
    byte[] bytes = jobs.content(tenant, id, ordinal, actor);
    return ResponseEntity.ok()
        .contentType(MediaType.APPLICATION_JSON)
        .contentLength(bytes.length)
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .header(
            HttpHeaders.CONTENT_DISPOSITION,
            ContentDisposition.attachment()
                .filename("usage-" + id + "-" + ordinal + ".json")
                .build()
                .toString())
        .body(bytes);
  }
}
