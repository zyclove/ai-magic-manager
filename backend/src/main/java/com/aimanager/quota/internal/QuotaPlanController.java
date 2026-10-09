package com.aimanager.quota.internal;

import com.aimanager.quota.*;
import com.aimanager.shared.*;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.time.DayOfWeek;
import java.util.Map;
import org.springframework.http.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/quota-plans")
class QuotaPlanController {
  private final QuotaPlanService plans;

  QuotaPlanController(QuotaPlanService plans) {
    this.plans = plans;
  }

  @PostMapping
  ResponseEntity<QuotaPlan> create(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @Valid @RequestBody Create input,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(plans.create(tenantId, actor, input, key), HttpStatus.CREATED);
  }

  @GetMapping
  ItemPage<QuotaPlan> list(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return plans.list(tenantId, actor.getSubject(), limit, cursor);
  }

  @GetMapping("/{planId}")
  ResponseEntity<QuotaPlan> get(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String planId) {
    return response(plans.get(tenantId, actor.getSubject(), planId), HttpStatus.OK);
  }

  @GetMapping("/calendar")
  Map<String, String> calendar(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @RequestParam String subjectId,
      @RequestParam String defaultTimeZone) {
    return plans.calendarPreview(tenantId, actor.getSubject(), subjectId, defaultTimeZone);
  }

  @PutMapping("/{planId}")
  ResponseEntity<QuotaPlan> update(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String planId,
      @Valid @RequestBody Update input,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(plans.update(tenantId, actor, planId, input, etag, key), HttpStatus.OK);
  }

  @GetMapping("/{planId}/revisions")
  ItemPage<QuotaPlan.Revision> revisions(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String planId,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return plans.revisions(tenantId, actor.getSubject(), planId, limit, cursor);
  }

  private ResponseEntity<QuotaPlan> response(QuotaPlan plan, HttpStatus status) {
    return ResponseEntity.status(status).eTag(ResourceVersions.tag(plan.version())).body(plan);
  }

  record Create(
      @NotBlank @Size(max = 100) String name,
      @NotNull @Pattern(regexp = UUID) String subjectId,
      @NotNull QuotaPool.Scope scope,
      @Pattern(regexp = UUID) String applicationId,
      @NotBlank @Size(max = 100) String timeZone,
      @NotNull @Pattern(regexp = "[0-9]{4}-[0-9]{2}-[0-9]{2}") String effectiveFrom,
      @NotNull @Size(min = 7, max = 7)
          Map<DayOfWeek, @NotNull @Min(0) @Max(86400) Long> weeklyLimits,
      @NotNull @Size(max = 60)
          Map<@NotBlank String, @NotNull @Min(0) @Max(86400) Long> dateOverrides) {}

  record Update(
      @NotBlank @Size(max = 100) String name,
      @NotNull QuotaPlan.State state,
      @NotNull @Size(min = 7, max = 7)
          Map<DayOfWeek, @NotNull @Min(0) @Max(86400) Long> weeklyLimits,
      @NotNull @Size(max = 60)
          Map<@NotBlank String, @NotNull @Min(0) @Max(86400) Long> dateOverrides) {}

  private static final String UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
}
