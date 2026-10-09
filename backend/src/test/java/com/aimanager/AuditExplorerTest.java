package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

@SpringBootTest(
    properties = {
      "spring.datasource.url=${AUDIT_TEST_DATABASE_URL:jdbc:h2:mem:audit-explorer;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${AUDIT_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${AUDIT_TEST_DATABASE_PASSWORD:}",
      "manager.notifications.retention-job.enabled=false"
    })
@AutoConfigureMockMvc
class AuditExplorerTest {
  @Test
  void hashedActorResourceCanBeSearched() throws Exception {
    String hashed = "ab".repeat(32);
    db.update(
        "UPDATE audit_events SET resource_id=? WHERE tenant_id=? AND id=?", hashed, tenant, A);
    var result = read(query().param("resourceId", hashed));
    assertThat(result.path("items").size()).isEqualTo(1);
    assertThat(result.at("/items/0/id").asText()).isEqualTo(A);
  }

  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper mapper;
  @MockitoBean JwtDecoder decoder;
  String tenant, owner, root;
  static final long START = 1791500000000L;
  static final String RESOURCE = "11111111-1111-1111-1111-111111111111";
  static final String TRACE = "22222222-2222-2222-2222-222222222222";
  static final String A = "aaaaaaaa-1111-1111-1111-111111111111";
  static final String B = "bbbbbbbb-1111-1111-1111-111111111111";
  static final String C = "cccccccc-1111-1111-1111-111111111111";

  @BeforeEach
  void setup() throws Exception {
    owner = "audit-owner-" + UUID.randomUUID();
    var response =
        mvc.perform(
                post("/api/v1/tenants")
                    .with(
                        jwt()
                            .jwt(t -> t.subject(owner))
                            .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create")))
                    .header("Idempotency-Key", UUID.randomUUID())
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("{\"name\":\"Audit\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse();
    tenant = mapper.readTree(response.getContentAsString()).path("id").asText();
    root = "/api/v1/tenants/" + tenant + "/audit-events";
    row(A, START + 10, "SUBJECT_CREATED");
    row(B, START + 20, "SUBJECT_CREATED");
    row(C, START + 20, "SUBJECT_UPDATED");
  }

  void row(String id, long time, String action) {
    db.update(
        "INSERT INTO"
            + " audit_events(tenant_id,id,actor_id,action,resource_id,correlation_id,occurred_at)"
            + " VALUES(?,?,?,?,?,?,?)",
        tenant,
        id,
        owner,
        action,
        RESOURCE,
        TRACE,
        time);
  }

  MockHttpServletRequestBuilder query() {
    return get(root + "/search")
        .with(jwt().jwt(t -> t.subject(owner)))
        .param("from", "" + START)
        .param("to", "" + (START + 100))
        .param("limit", "2");
  }

  JsonNode read(MockHttpServletRequestBuilder request) throws Exception {
    return mapper.readTree(
        mvc.perform(request)
            .andExpect(status().isOk())
            .andReturn()
            .getResponse()
            .getContentAsString());
  }

  @Test
  void newestFirstStableTiesAndBoundedPages() throws Exception {
    var page = read(query());
    assertThat(page.path("items").size()).isEqualTo(2);
    assertThat(page.at("/items/0/id").asText()).isEqualTo(C);
    assertThat(page.at("/items/1/id").asText()).isEqualTo(B);
    var next = read(query().param("cursor", page.path("nextCursor").asText()));
    assertThat(next.path("items").size()).isEqualTo(1);
    assertThat(next.at("/items/0/id").asText()).isEqualTo(A);
    assertThat(next.path("nextCursor").isNull()).isTrue();
  }

  @Test
  void filtersIntersectAndEndIsExclusive() throws Exception {
    var page =
        read(
            query()
                .param("action", "SUBJECT_CREATED")
                .param("resourceId", RESOURCE)
                .param("correlationId", TRACE));
    assertThat(page.path("items").size()).isEqualTo(2);
    var before =
        read(
            query()
                .with(
                    r -> {
                      r.setParameter("to", "" + (START + 20));
                      return r;
                    }));
    assertThat(before.path("items").size()).isEqualTo(1);
    assertThat(
            read(query().param("resourceId", UUID.randomUUID().toString())).path("items").isEmpty())
        .isTrue();
  }

  @Test
  void invalidBoundsFiltersAndCursorAre400() throws Exception {
    for (var entry :
        Map.of(
                "limit",
                "51",
                "from",
                "-1",
                "to",
                "9999999999999",
                "action",
                "x' OR 1=1",
                "resourceId",
                "bad",
                "correlationId",
                "bad",
                "cursor",
                "bad")
            .entrySet()) {
      mvc.perform(
              query()
                  .with(
                      r -> {
                        r.setParameter(entry.getKey(), entry.getValue());
                        return r;
                      }))
          .andExpect(status().isBadRequest());
    }
    mvc.perform(get(root + "/search").with(jwt().jwt(t -> t.subject(owner))))
        .andExpect(status().isBadRequest());
  }

  @Test
  void cursorCannotCrossFilterOrTenant() throws Exception {
    var cursor = read(query()).path("nextCursor").asText();
    mvc.perform(query().param("action", "SUBJECT_UPDATED").param("cursor", cursor))
        .andExpect(status().isBadRequest());
    setup();
    mvc.perform(query().param("cursor", cursor)).andExpect(status().isBadRequest());
  }

  @Test
  void rolesRevocationAndTenantIsolation() throws Exception {
    mvc.perform(query().with(jwt().jwt(t -> t.subject("outsider"))))
        .andExpect(status().isForbidden());
    for (String role : List.of("AUDITOR", "GUARDIAN", "ORG_ADMIN", "TEACHER", "CHILD")) {
      db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, tenant);
      mvc.perform(query())
          .andExpect(
              role.equals("CHILD") || role.equals("TEACHER")
                  ? status().isForbidden()
                  : status().isOk());
    }
    db.update(
        "UPDATE tenant_members SET role='OWNER',revoked_at=? WHERE tenant_id=?",
        new java.sql.Timestamp(START),
        tenant);
    mvc.perform(query()).andExpect(status().isForbidden());
    mvc.perform(get(root + "/" + A).with(jwt().jwt(t -> t.subject(owner))))
        .andExpect(status().isForbidden());
  }

  @Test
  void detailFreshAuthorizationAndLegacyCompatibility() throws Exception {
    var item = read(get(root + "/" + A).with(jwt().jwt(t -> t.subject(owner))));
    assertThat(item.path("actorId").asText()).isEqualTo(owner);
    assertThat(item.path("correlationId").asText()).isEqualTo(TRACE);
    mvc.perform(get(root + "/" + UUID.randomUUID()).with(jwt().jwt(t -> t.subject(owner))))
        .andExpect(status().isNotFound());
    assertThat(read(get(root).with(jwt().jwt(t -> t.subject(owner)))).path("items").size())
        .isGreaterThanOrEqualTo(3);
  }
}
