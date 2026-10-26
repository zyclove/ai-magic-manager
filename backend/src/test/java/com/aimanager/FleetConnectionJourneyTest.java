package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.BadJwtException;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** 连接筛选沿用真实 HTTP 授权与数据库分页，固定时钟仅用于精确观测边界。 */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:fleet_connection_filter;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa",
    "spring.datasource.password=",
    "spring.flyway.enabled=true",
    "manager.devices.observation-max-age-seconds=180"
})
@AutoConfigureMockMvc
class FleetConnectionJourneyTest {
  private static final Instant NOW = Instant.parse("2026-10-26T00:00:00Z");
  private static final long CUTOFF = NOW.toEpochMilli() - 180_000;

  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper mapper;
  @MockitoBean Clock clock;
  @MockitoBean JwtDecoder decoder;

  @BeforeEach
  void fixedObservationTime() {
    when(clock.instant()).thenReturn(NOW);
    when(clock.millis()).thenReturn(NOW.toEpochMilli());
    when(clock.getZone()).thenReturn(ZoneOffset.UTC);
    when(decoder.decode(anyString())).thenThrow(new BadJwtException("Invalid user token"));
  }

  @Test
  void onlyActiveDevicesStrictlyPastTheObservationBoundaryNeedChecking() throws Exception {
    var scope = scope();
    device(scope, 1, scope.subject(), "ACTIVE", null);
    device(scope, 2, scope.subject(), "ACTIVE", CUTOFF - 1);
    device(scope, 3, scope.subject(), "ACTIVE", CUTOFF);
    device(scope, 4, scope.subject(), "ACTIVE", NOW.toEpochMilli());
    device(scope, 5, scope.subject(), "REVOKED", null);
    device(scope, 6, scope.subject(), "AWAITING_CONFIRMATION", null);

    var filtered = page(scope, scope.owner(), "NEEDS_CHECK", 50, null);
    assertThat(ids(filtered)).containsExactly(id(1), id(2));
    assertThat(filtered.path("items").get(0).path("observationStatus").asText())
        .isEqualTo("UNKNOWN");
    assertThat(filtered.path("items").get(1).path("observationStatus").asText())
        .isEqualTo("STALE");
    assertThat(filtered.path("nextCursor").isNull()).isTrue();
    assertThat(ids(page(scope, scope.owner(), null, 50, null)))
        .containsExactly(id(1), id(2), id(3), id(4), id(5), id(6));
  }

  @Test
  void filteringPrecedesKeysetPagingAndPreservesTenantAndSubjectScopes() throws Exception {
    var scope = scope();
    device(scope, 1, scope.subject(), "ACTIVE", null);
    device(scope, 2, scope.subject(), "ACTIVE", NOW.toEpochMilli());
    device(scope, 3, scope.otherSubject(), "ACTIVE", CUTOFF - 1);
    device(scope, 4, scope.subject(), "ACTIVE", CUTOFF - 1);
    device(scope, 5, scope.subject(), "AWAITING_CONFIRMATION", null);
    var otherTenant = scope();
    device(otherTenant, 0, otherTenant.subject(), "ACTIVE", null);
    String child = "connection-child-" + UUID.randomUUID();
    String teacher = "connection-teacher-" + UUID.randomUUID();
    member(scope.tenant(), child, "CHILD", scope.subject());
    member(scope.tenant(), teacher, "TEACHER", scope.subject());

    var first = page(scope, scope.owner(), "NEEDS_CHECK", 1, null);
    assertThat(ids(first)).containsExactly(id(1));
    assertThat(first.path("nextCursor").asText()).isEqualTo(id(1));
    var second = page(scope, scope.owner(), "NEEDS_CHECK", 1, first.path("nextCursor").asText());
    assertThat(ids(second)).containsExactly(id(3));
    assertThat(second.path("nextCursor").asText()).isEqualTo(id(3));
    var last = page(scope, scope.owner(), "NEEDS_CHECK", 1, second.path("nextCursor").asText());
    assertThat(ids(last)).containsExactly(id(4));
    assertThat(last.path("nextCursor").isNull()).isTrue();

    var childFirst = page(scope, child, "NEEDS_CHECK", 1, null);
    assertThat(ids(childFirst)).containsExactly(id(1));
    assertThat(childFirst.path("nextCursor").asText()).isEqualTo(id(1));
    var childLast = page(scope, child, "NEEDS_CHECK", 1, childFirst.path("nextCursor").asText());
    assertThat(ids(childLast)).containsExactly(id(4));
    assertThat(childLast.path("nextCursor").isNull()).isTrue();
    assertThat(ids(page(scope, teacher, "NEEDS_CHECK", 50, null)))
        .containsExactly(id(1), id(4));

    for (String invalid : List.of("ALL", "needs_check", "")) {
      mvc.perform(get("/api/v1/tenants/{tenant}/devices", scope.tenant())
              .with(actor(scope.owner())).param("connection", invalid))
          .andExpect(status().isBadRequest());
    }
    mvc.perform(get("/api/v1/tenants/{tenant}/devices", scope.tenant())
            .with(actor(scope.owner())).param("connection", "NEEDS_CHECK").param("limit", "0"))
        .andExpect(status().isBadRequest());
    mvc.perform(get("/api/v1/tenants/{tenant}/devices", scope.tenant())
            .with(actor(scope.owner())).param("connection", "NEEDS_CHECK").param("cursor", "bad-cursor"))
        .andExpect(status().isBadRequest());
  }

  private Scope scope() {
    String tenant = UUID.randomUUID().toString();
    String subject = UUID.randomUUID().toString();
    String otherSubject = UUID.randomUUID().toString();
    String owner = "connection-owner-" + UUID.randomUUID();
    db.update("INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'连接测试','ORGANIZATION','UTC',?)",
        tenant, NOW.toEpochMilli());
    for (String id : List.of(subject, otherSubject)) {
      db.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'成员','AGE_7_12',?)",
          tenant, id, NOW.toEpochMilli());
    }
    member(tenant, owner, "OWNER", null);
    return new Scope(tenant, owner, subject, otherSubject);
  }

  private void member(String tenant, String actor, String role, String subject) {
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id) VALUES(?,?,?,?,?)",
        tenant, actor, ActorKeys.key(actor), role, subject);
  }

  private void device(Scope scope, int sequence, String subject, String state, Long heartbeat) {
    db.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,"
            + "state,public_key_jwk,key_thumbprint,created_at,last_heartbeat_at)"
            + " VALUES(?,?,?,?,'设备','ANDROID','14',?,'{}','fixture',?,?)",
        scope.tenant(), id(sequence), subject, UUID.randomUUID().toString(), state,
        NOW.toEpochMilli(), heartbeat);
  }

  private JsonNode page(Scope scope, String actor, String connection, int limit, String cursor)
      throws Exception {
    var request = get("/api/v1/tenants/{tenant}/devices", scope.tenant())
        .with(actor(actor)).param("limit", Integer.toString(limit));
    if (connection != null) request.param("connection", connection);
    if (cursor != null) request.param("cursor", cursor);
    var response = mvc.perform(request).andExpect(status().isOk()).andReturn().getResponse();
    return mapper.readTree(response.getContentAsString());
  }

  private RequestPostProcessor actor(String name) {
    return jwt().jwt(token -> token.subject(name).claim("auth_time", NOW.getEpochSecond())
            .claim("amr", List.of("pwd", "otp")).claim("email", name + "@example.test")
            .claim("email_verified", true))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private static List<String> ids(JsonNode page) {
    var result = new ArrayList<String>();
    page.path("items").forEach(item -> result.add(item.path("id").asText()));
    return result;
  }

  private static String id(int sequence) {
    return String.format(Locale.ROOT, "00000000-0000-0000-0000-%012d", sequence);
  }

  private record Scope(String tenant, String owner, String subject, String otherSubject) {}
}
