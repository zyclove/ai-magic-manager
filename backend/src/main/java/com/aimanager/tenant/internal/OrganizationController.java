package com.aimanager.tenant.internal;

import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/classes")
class OrganizationController {
  private final OrganizationService classes;

  OrganizationController(OrganizationService classes) {
    this.classes = classes;
  }

  @GetMapping
  ItemPage<OrganizationService.Classroom> list(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor,
      @RequestParam(defaultValue = "false") boolean includeArchived) {
    return classes.list(tenantId, actor.getSubject(), limit, cursor, includeArchived);
  }

  @PostMapping
  ResponseEntity<OrganizationService.Classroom> create(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @Valid @RequestBody Name body,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(classes.create(tenantId, actor, body.name(), key), HttpStatus.CREATED);
  }

  @GetMapping("/{classId}")
  ResponseEntity<OrganizationService.Classroom> get(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String classId) {
    return response(classes.get(tenantId, actor.getSubject(), classId), HttpStatus.OK);
  }

  @PatchMapping("/{classId}")
  ResponseEntity<OrganizationService.Classroom> update(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String classId,
      @Valid @RequestBody Name body,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(
        classes.rename(tenantId, actor, classId, body.name(), etag, key), HttpStatus.OK);
  }

  @PostMapping("/{classId}/archive")
  ResponseEntity<OrganizationService.Classroom> archive(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String classId,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(classes.archive(tenantId, actor, classId, etag, key), HttpStatus.OK);
  }

  @GetMapping("/{classId}/students")
  ItemPage<OrganizationService.Student> students(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String classId,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return classes.students(tenantId, actor.getSubject(), classId, limit, cursor);
  }

  @PostMapping("/{classId}/students")
  ResponseEntity<OrganizationService.Classroom> add(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String classId,
      @Valid @RequestBody Student body,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(
        classes.student(tenantId, actor, classId, body.subjectId(), true, etag, key),
        HttpStatus.OK);
  }

  @DeleteMapping("/{classId}/students/{subjectId}")
  ResponseEntity<OrganizationService.Classroom> remove(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String classId,
      @PathVariable String subjectId,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(
        classes.student(tenantId, actor, classId, subjectId, false, etag, key), HttpStatus.OK);
  }

  @PostMapping("/{classId}/students/{subjectId}/transfer")
  OrganizationService.Transfer transfer(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String classId,
      @PathVariable String subjectId,
      @Valid @RequestBody Move body,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return classes.transfer(
        tenantId, actor, classId, subjectId, body.targetClassId(), body.targetVersion(), etag, key);
  }

  private ResponseEntity<OrganizationService.Classroom> response(
      OrganizationService.Classroom result, HttpStatus status) {
    return ResponseEntity.status(status).eTag(ResourceVersions.tag(result.version())).body(result);
  }

  record Name(@NotBlank @Size(max = 100) String name) {}

  record Student(@NotNull @Pattern(regexp = UUID) String subjectId) {}

  record Move(
      @NotNull @Pattern(regexp = UUID) String targetClassId, @NotNull @Min(0) Long targetVersion) {}

  private static final String UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
}
