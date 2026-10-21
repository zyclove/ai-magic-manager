package com.aimanager.identity;

import java.util.List;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
class CurrentActorController {
  private final IdentityProfiles profiles;

  CurrentActorController(IdentityProfiles profiles) {
    this.profiles = profiles;
  }

  @GetMapping("/api/v1/me")
  Profile me(@AuthenticationPrincipal Jwt actor, Authentication authentication) {
    profiles.observe(actor);
    return new Profile(
        actor.getSubject(),
        actor.getClaimAsString("email"),
        actor.getClaimAsString("name"),
        authentication.getAuthorities().stream()
            .anyMatch(a -> a.getAuthority().equals("SCOPE_tenant:create")),
        authentication.getAuthorities().stream()
            .anyMatch(a -> a.getAuthority().equals("SCOPE_catalog:manage")),
        authentication.getAuthorities().stream()
            .anyMatch(a -> a.getAuthority().equals("SCOPE_catalog:approve")),
        authentication.getAuthorities().stream()
            .anyMatch(a -> a.getAuthority().equals("SCOPE_contract:manage")),
        authentication.getAuthorities().stream()
            .anyMatch(a -> a.getAuthority().equals("SCOPE_contract:approve")),
        authentication.getAuthorities().stream()
            .anyMatch(a -> a.getAuthority().equals("SCOPE_emm:approve")),
        authentication.getAuthorities().stream()
            .anyMatch(a -> a.getAuthority().equals("SCOPE_family-refunds:review")),
        authentication.getAuthorities().stream()
            .anyMatch(a -> a.getAuthority().equals("SCOPE_family-finance:manage")),
        authentication.getAuthorities().stream()
            .anyMatch(a -> a.getAuthority().equals("SCOPE_identity-config:read")),
        authentication.getAuthorities().stream()
            .anyMatch(a -> a.getAuthority().equals("SCOPE_identity-config:manage")),
        authentication.getAuthorities().stream()
            .anyMatch(a -> a.getAuthority().equals("SCOPE_identity-config:test")),
        authentication.getAuthorities().stream()
            .anyMatch(a -> a.getAuthority().equals("SCOPE_identity-config:publish")),
        authentication.getAuthorities().stream()
            .anyMatch(a -> a.getAuthority().equals("SCOPE_identity-config:rollback")),
        actor.getClaimAsStringList("amr") == null ? List.of() : actor.getClaimAsStringList("amr"),
        Boolean.TRUE.equals(actor.getClaim("phone_number_verified")) && actor.getClaimAsString("phone_number") != null);
  }

  record Profile(
      String subject,
      String email,
      String name,
      boolean canCreateTenant,
      boolean canManageCatalog,
      boolean canApproveCatalog,
      boolean canManageContracts,
      boolean canApproveContracts,
      boolean canReviewManagedAndroid,
      boolean canReviewFamilyRefunds,
      boolean canManageFamilyFinance,
      boolean canReadIdentityProviders,
      boolean canManageIdentityProviders,
      boolean canTestIdentityProviders,
      boolean canPublishIdentityProviders,
      boolean canRollbackIdentityProviders,
      List<String> authenticationMethods,
      boolean canCreateFamily) {}
}
