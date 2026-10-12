package com.aimanager.managedandroid.internal;

import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

/** Contract seat projection; provider execution and local Agent registration remain separate. */
@RestController
class ManagedCapacityController {
  private final ManagedEnrollmentStore enrollments;

  ManagedCapacityController(ManagedEnrollmentStore enrollments) {
    this.enrollments = enrollments;
  }

  @GetMapping("/api/v1/tenants/{tenantId}/managed-android/capacity")
  ResponseEntity<ManagedEnrollmentStore.CapacitySnapshot> capacity(
      @PathVariable String tenantId, @AuthenticationPrincipal Jwt actor) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(enrollments.capacity(tenantId, actor.getSubject()));
  }
}
