package com.aimanager.commerce.internal;

import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

/** Read-only account view. There is deliberately no self-grant or unverified purchase endpoint. */
@RestController
class CommercialEntitlementController {
  private final CommercialLedger ledger;

  CommercialEntitlementController(CommercialLedger ledger) {
    this.ledger = ledger;
  }

  @GetMapping("/api/v1/tenants/{tenantId}/commercial-entitlements")
  ResponseEntity<CommercialEntitlementView> read(
      @AuthenticationPrincipal Jwt actor, @PathVariable String tenantId) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(ledger.read(tenantId, actor.getSubject()));
  }
}
