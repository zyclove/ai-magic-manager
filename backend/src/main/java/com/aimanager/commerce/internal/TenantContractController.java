package com.aimanager.commerce.internal;

import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Tenant administrators accept an independently approved contract for their own organization. */
@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/contracts")
class TenantContractController {
  private final CommercialContractService contracts;

  TenantContractController(CommercialContractService contracts) {
    this.contracts = contracts;
  }

  @PostMapping("/{id}/accept")
  ResponseEntity<CommercialContractService.TenantReviewView> accept(
      @PathVariable String tenantId,
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String id,
      @RequestHeader(value = "If-Match", required = false) String ifMatch) {
    return response(contracts.accept(tenantId, actor, id, ResourceVersions.require(ifMatch)));
  }

  @GetMapping("/{id}")
  ResponseEntity<CommercialContractService.TenantReviewView> get(
      @PathVariable String tenantId, @AuthenticationPrincipal Jwt actor, @PathVariable String id) {
    return response(contracts.tenantGet(tenantId, actor.getSubject(), id));
  }

  @GetMapping("/{id}/history")
  ResponseEntity<CommercialContractService.TenantHistoryPage> history(
      @PathVariable String tenantId,
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String id,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) Long beforeVersion) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(contracts.tenantHistory(tenantId, actor.getSubject(), id, limit, beforeVersion));
  }

  @GetMapping
  ResponseEntity<ItemPage<CommercialContractService.TenantReviewView>> list(
      @PathVariable String tenantId,
      @AuthenticationPrincipal Jwt actor,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(contracts.tenantList(tenantId, actor.getSubject(), limit, cursor));
  }

  private static ResponseEntity<CommercialContractService.TenantReviewView> response(
      CommercialContractService.TenantReviewView review) {
    return ResponseEntity.ok()
        .eTag(ResourceVersions.tag(review.version()))
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(review);
  }
}
