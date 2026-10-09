package com.aimanager.identity;

import java.util.List;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
class CurrentActorController {
    @GetMapping("/api/v1/me")
    Profile me(@AuthenticationPrincipal Jwt actor, Authentication authentication) {
        return new Profile(actor.getSubject(), actor.getClaimAsString("email"), actor.getClaimAsString("name"),
            authentication.getAuthorities().stream().anyMatch(a -> a.getAuthority().equals("SCOPE_tenant:create")),
            actor.getClaimAsStringList("amr") == null ? List.of() : actor.getClaimAsStringList("amr"));
    }
    record Profile(String subject, String email, String name, boolean canCreateTenant, List<String> authenticationMethods) {}
}
