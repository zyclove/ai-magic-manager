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
        actor.getClaimAsStringList("amr") == null ? List.of() : actor.getClaimAsStringList("amr"));
  }

  record Profile(
      String subject,
      String email,
      String name,
      boolean canCreateTenant,
      boolean canManageCatalog,
      boolean canApproveCatalog,
      List<String> authenticationMethods) {}
}
