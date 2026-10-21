package com.aimanager.identity;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.Arrays;
import org.junit.jupiter.api.Test;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;

class CurrentActorIdentityProviderCapabilitiesTest {
  private final CurrentActorController controller = new CurrentActorController(mock(IdentityProfiles.class));
  private final ObjectMapper mapper = new ObjectMapper();

  @Test void ordinaryFamilyAndWorkspaceCreatorHaveNoProviderCapability() {
    var profile = profile("SCOPE_tenant:create");
    assertThat(profile.path("canReadIdentityProviders").isBoolean()).isTrue();
    assertThat(profile.path("canReadIdentityProviders").asBoolean()).isFalse();
    assertThat(profile.path("canManageIdentityProviders").asBoolean()).isFalse();
    assertThat(profile.path("canTestIdentityProviders").asBoolean()).isFalse();
  }

  @Test void signedReadScopeDoesNotGrantSecretWriteOrTests() {
    var profile = profile("SCOPE_identity-config:read");
    assertThat(profile.path("canReadIdentityProviders").asBoolean()).isTrue();
    assertThat(profile.path("canManageIdentityProviders").asBoolean()).isFalse();
    assertThat(profile.path("canTestIdentityProviders").asBoolean()).isFalse();
  }

  @Test void writeAndTestCapabilitiesAreIndependent() {
    var writer = profile("SCOPE_identity-config:manage");
    assertThat(writer.path("canManageIdentityProviders").asBoolean()).isTrue();
    assertThat(writer.path("canTestIdentityProviders").asBoolean()).isFalse();
    var tester = profile("SCOPE_identity-config:test");
    assertThat(tester.path("canTestIdentityProviders").asBoolean()).isTrue();
    assertThat(tester.path("canManageIdentityProviders").asBoolean()).isFalse();
  }

  @Test void configurationEditorsAndTestersCannotPublishOrRollback() {
    var profile = profile("SCOPE_identity-config:manage", "SCOPE_identity-config:test");
    assertThat(profile.path("canPublishIdentityProviders").isBoolean()).isTrue();
    assertThat(profile.path("canRollbackIdentityProviders").isBoolean()).isTrue();
    assertThat(profile.path("canPublishIdentityProviders").asBoolean()).isFalse();
    assertThat(profile.path("canRollbackIdentityProviders").asBoolean()).isFalse();
  }

  @Test void publishAndRollbackRequireTheirOwnSignedScopes() {
    var publisher = profile("SCOPE_identity-config:publish");
    assertThat(publisher.path("canPublishIdentityProviders").asBoolean()).isTrue();
    assertThat(publisher.path("canRollbackIdentityProviders").asBoolean()).isFalse();
    var rollback = profile("SCOPE_identity-config:rollback");
    assertThat(rollback.path("canRollbackIdentityProviders").asBoolean()).isTrue();
    assertThat(rollback.path("canPublishIdentityProviders").asBoolean()).isFalse();
  }

  private com.fasterxml.jackson.databind.JsonNode profile(String... scopes) {
    var now = Instant.now();
    var jwt = Jwt.withTokenValue("fixture").header("alg", "none").subject("adult-fixture")
        .issuedAt(now).expiresAt(now.plusSeconds(60)).build();
    var authentication = new JwtAuthenticationToken(jwt,
        Arrays.stream(scopes).map(SimpleGrantedAuthority::new).toList());
    return mapper.valueToTree(controller.me(jwt, authentication));
  }
}
