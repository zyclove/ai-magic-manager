package com.aimanager.notification.internal;

import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

/** Identity-owned revocation remains available after leaving the installation's old family. */
@RestController
class FamilyPushRecoveryController {
  private final FamilyPushService service;
  FamilyPushRecoveryController(FamilyPushService service){this.service=service;}
  @DeleteMapping("/api/v1/notifications/push-installations/{installationId}")
  ResponseEntity<Void> revoke(@AuthenticationPrincipal Jwt actor,@PathVariable String installationId) {
    service.revokeOwned(actor.getSubject(),installationId);
    return ResponseEntity.noContent().cacheControl(CacheControl.noStore()).build();
  }
}
