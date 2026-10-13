package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import java.time.Instant;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** Real subject HTTP and SQL authority checks; tenant/member and external issuer are fixtures. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:tenant-resource-identity;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password="
})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class TenantResourceIdentityJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired TenantAccess access;
  @MockitoBean JwtDecoder decoder;

  @DynamicPropertySource
  static void isolatedDatabase(DynamicPropertyRegistry properties) {
    String url = System.getenv("P0_RESOURCE_ID_TEST_DATABASE_URL");
    String user = System.getenv("P0_RESOURCE_ID_TEST_DATABASE_USERNAME");
    String password = System.getenv("P0_RESOURCE_ID_TEST_DATABASE_PASSWORD");
    if (url == null) {
      if (user != null || password != null) throw new IllegalArgumentException("Isolated URL required");
      return;
    }
    if (!url.matches("jdbc:mysql://127\\.0\\.0\\.1:3308/notification_it_[a-f0-9]{32}\\?.*")
        || user == null || user.isBlank() || password == null)
      throw new IllegalArgumentException("Resource identity tests require an isolated schema");
    properties.add("spring.datasource.url", () -> url);
    properties.add("spring.datasource.username", () -> user);
    properties.add("spring.datasource.password", () -> password);
  }

  @Test
  void nonCanonicalTenantPathCannotAliasAnAuthorizedTenantOrCreateAnotherProfile() throws Exception {
    var scope = scope();
    String originalKey = UUID.randomUUID().toString();
    mvc.perform(post(route(scope.tenant())).with(actor(scope.owner()))
            .header("Idempotency-Key", originalKey).contentType(MediaType.APPLICATION_JSON)
            .content(input()))
        .andExpect(status().isCreated());
    // MySQL's default text collation otherwise aliases this spelling to the stored lower-case UUID.
    for (String key : List.of(UUID.randomUUID().toString(), originalKey, "")) {
      var request = post(route(scope.tenant().toUpperCase(Locale.ROOT))).with(actor(scope.owner()))
          .contentType(MediaType.APPLICATION_JSON).content(input());
      if (!key.isEmpty()) request.header("Idempotency-Key", key);
      mvc.perform(request).andExpect(status().isForbidden())
          .andExpect(jsonPath("$.errorCode").value("SCOPE_DENIED"));
    }
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects WHERE tenant_id=?", Integer.class, scope.tenant()))
        .isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=?", Integer.class, scope.tenant()))
        .isEqualTo(1);
  }

  @Test
  void canonicalTenantPathRetainsItsStableOriginalResponse() throws Exception {
    var scope = scope();
    String key = UUID.randomUUID().toString();
    String original = mvc.perform(post(route(scope.tenant())).with(actor(scope.owner()))
            .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON).content(input()))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
    String replay = mvc.perform(post(route(scope.tenant())).with(actor(scope.owner()))
            .header("Idempotency-Key", key).contentType(MediaType.APPLICATION_JSON).content(input()))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString();
    assertThat(replay).isEqualTo(original);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects WHERE tenant_id=?", Integer.class, scope.tenant()))
        .isEqualTo(1);
  }

  @Test
  void scopeFilterRejectsNonCanonicalTenantBeforeTakingAnAdultShortcut() {
    var scope = scope();
    var grant = access.requireRole(scope.tenant(), scope.owner(), TenantAccess.Role.OWNER);
    assertThat(access.subjectFilter(scope.tenant(), scope.owner(), grant, "id").sql()).isEqualTo("1=1");
    assertThatThrownBy(() -> access.subjectFilter(scope.tenant().toUpperCase(Locale.ROOT), scope.owner(), grant, "id"))
        .isInstanceOfSatisfying(DomainException.class, error -> {
          assertThat(error.status()).isEqualTo(HttpStatus.FORBIDDEN);
          assertThat(error.errorCode()).isEqualTo("SCOPE_DENIED");
        });
  }

  @Test
  void subjectReadRejectsNonCanonicalTenantBeforeTakingAnAdultShortcut() {
    var scope = scope();
    var grant = access.requireRole(scope.tenant(), scope.owner(), TenantAccess.Role.OWNER);
    assertThatThrownBy(() -> access.canReadSubject(scope.tenant().toUpperCase(Locale.ROOT), scope.owner(), grant, UUID.randomUUID().toString()))
        .isInstanceOfSatisfying(DomainException.class, error -> {
          assertThat(error.status()).isEqualTo(HttpStatus.FORBIDDEN);
          assertThat(error.errorCode()).isEqualTo("SCOPE_DENIED");
        });
  }

  private Scope scope() {
    // Include a known hex letter so the case-alias regression has no random skip or numeric-only ID.
    String tenant = "a" + UUID.randomUUID().toString().substring(1);
    String owner = "resource-owner-" + UUID.randomUUID();
    db.update("INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'Identity fixture','FAMILY','UTC',1)", tenant);
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'OWNER')", tenant, owner, ActorKeys.key(owner));
    return new Scope(tenant, owner);
  }

  private String route(String tenant) { return "/api/v1/tenants/" + tenant + "/subjects"; }
  private String input() { return "{\"nickname\":\"Identity fixture child\",\"ageBand\":\"AGE_7_12\"}"; }
  private RequestPostProcessor actor(String owner) {
    return jwt().jwt(token -> token.subject(owner).claim("auth_time", Instant.now().getEpochSecond())
            .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }
  private record Scope(String tenant, String owner) {}
}
