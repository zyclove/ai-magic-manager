package com.aimanager.managedandroid.internal;

import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Enterprise binding review APIs; provider credentials and enrollment material are never exposed. */
@RestController
class ManagedEnterpriseBindingController {
  private final ManagedEnterpriseBindingService service;
  private final RecentAuthentication recent;

  ManagedEnterpriseBindingController(
      ManagedEnterpriseBindingService service, RecentAuthentication recent) {
    this.service = service;
    this.recent = recent;
  }

  @PostMapping("/api/v1/tenants/{tenantId}/managed-android/enterprise-binding")
  ResponseEntity<TenantBinding> propose(
      @PathVariable String tenantId,
      @AuthenticationPrincipal Jwt actor,
      @RequestBody Proposal input) {
    recent.require(actor);
    if (input == null) throw DomainException.invalid("INVALID_ENTERPRISE_BINDING");
    return tenantResponse(
        HttpStatus.CREATED,
        service.propose(tenantId, actor.getSubject(), input.enterpriseId(), input.contractReference()));
  }

  @GetMapping("/api/v1/tenants/{tenantId}/managed-android/enterprise-binding")
  ResponseEntity<TenantBinding> tenantGet(
      @PathVariable String tenantId, @AuthenticationPrincipal Jwt actor) {
    return tenantResponse(HttpStatus.OK, service.tenantGet(tenantId, actor.getSubject()));
  }

  @GetMapping("/api/v1/tenants/{tenantId}/managed-android/readiness")
  ResponseEntity<ManagedEnterpriseBindingService.Readiness> readiness(
      @PathVariable String tenantId, @AuthenticationPrincipal Jwt actor) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).header("Vary", "Authorization")
        .body(service.readiness(tenantId, actor.getSubject()));
  }

  @GetMapping("/api/v1/platform/managed-android/enterprise-bindings")
  ResponseEntity<ItemPage<ManagedEnterpriseBindingService.Binding>> pending(
      Authentication auth,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).header("Vary", "Authorization")
        .body(service.pending(auth, limit, cursor));
  }

  @GetMapping("/api/v1/platform/managed-android/enterprise-bindings/{tenantId}")
  ResponseEntity<ManagedEnterpriseBindingService.Binding> platformGet(
      Authentication auth, @PathVariable String tenantId) {
    return platformResponse(HttpStatus.OK, service.platformGet(auth, tenantId));
  }

  @PostMapping("/api/v1/platform/managed-android/enterprise-bindings/{tenantId}/approve")
  ResponseEntity<ManagedEnterpriseBindingService.Binding> approve(
      Authentication auth,
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @RequestHeader(value = "If-Match", required = false) String ifMatch,
      @RequestBody Approval input) {
    recent.require(actor);
    if (input == null) throw DomainException.invalid("INVALID_ENTERPRISE_BINDING_APPROVAL");
    long expected = ResourceVersions.require(ifMatch);
    var identity = service.inspectProvider(auth, tenantId, expected);
    return platformResponse(
        HttpStatus.OK,
        service.approve(auth, tenantId, actor.getSubject(), expected,
            input.ownershipEvidenceReference(), input.reason(), identity));
  }

  @PostMapping("/api/v1/platform/managed-android/enterprise-bindings/{tenantId}/revoke")
  ResponseEntity<ManagedEnterpriseBindingService.Binding> revoke(
      Authentication auth,
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @RequestHeader(value = "If-Match", required = false) String ifMatch,
      @RequestBody Action input) {
    recent.require(actor);
    if (input == null) throw DomainException.invalid("INVALID_ENTERPRISE_BINDING_REVOCATION");
    return platformResponse(
        HttpStatus.OK,
        service.revoke(auth, tenantId, actor.getSubject(), ResourceVersions.require(ifMatch),
            input.reason()));
  }

  private static ResponseEntity<TenantBinding> tenantResponse(
      HttpStatus status, ManagedEnterpriseBindingService.Binding binding) {
    return ResponseEntity.status(status).eTag(ResourceVersions.tag(binding.version()))
        .cacheControl(CacheControl.noStore()).header("Vary", "Authorization")
        .body(new TenantBinding(binding.tenantId(), binding.provider(), binding.enterpriseId(),
            binding.contractReference(), binding.state(), binding.version(),
            binding.providerDisplayName(), binding.createdAt(), binding.updatedAt()));
  }

  private static ResponseEntity<ManagedEnterpriseBindingService.Binding> platformResponse(
      HttpStatus status, ManagedEnterpriseBindingService.Binding binding) {
    return ResponseEntity.status(status).eTag(ResourceVersions.tag(binding.version()))
        .cacheControl(CacheControl.noStore()).header("Vary", "Authorization").body(binding);
  }

  record Proposal(String enterpriseId, String contractReference) {}
  record Approval(String ownershipEvidenceReference, String reason) {}
  record Action(String reason) {}
  record TenantBinding(
      String tenantId, String provider, String enterpriseId, String contractReference,
      String state, long version, String providerDisplayName, long createdAt, long updatedAt) {}
}
