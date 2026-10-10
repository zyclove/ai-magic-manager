package com.aimanager;

import static org.assertj.core.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.*;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(
    properties = {
      "spring.datasource.url=${USAGE_REPORT_TEST_DATABASE_URL:jdbc:h2:mem:application-classification;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${USAGE_REPORT_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${USAGE_REPORT_TEST_DATABASE_PASSWORD:}",
      "manager.exports.worker.enabled=false"
    })
@AutoConfigureMockMvc
class ApplicationClassificationJourneyTest {
  @Autowired com.aimanager.catalog.ApplicationCategories categories;
  @Autowired org.springframework.transaction.support.TransactionTemplate transactions;

  @Test
  void publicReportLookupIsBoundedImmutableAndOnlyReturnsRequestedIdentities() throws Exception {
    update(owner, app, "\"0\"", null, "EDUCATION").andExpect(status().isOk());
    var requested = new HashSet<com.aimanager.catalog.ApplicationCategories.Identity>();
    var observed =
        new com.aimanager.catalog.ApplicationCategories.Identity(
            com.aimanager.fleet.Device.Platform.ANDROID,
            com.aimanager.catalog.ApplicationDefinition.Profile.PRIMARY,
            "org.example.reader");
    requested.add(observed);
    for (int i = 0; i < 501; i++)
      requested.add(
          new com.aimanager.catalog.ApplicationCategories.Identity(
              com.aimanager.fleet.Device.Platform.ANDROID,
              com.aimanager.catalog.ApplicationDefinition.Profile.PRIMARY,
              "org.example.app" + i));
    var values =
        transactions.execute(status -> categories.forAuthorizedUsageReport(tenant, requested));
    assertThat(values).hasSize(502);
    assertThat(values.get(observed).category())
        .isEqualTo(com.aimanager.catalog.ApplicationCategories.Category.EDUCATION);
    assertThat(values.values().stream().filter(v -> v.source().equals("NONE")).count())
        .isEqualTo(501);
    assertThatThrownBy(() -> values.clear()).isInstanceOf(UnsupportedOperationException.class);
    var foreign =
        transactions.execute(
            status ->
                categories.forAuthorizedUsageReport(
                    UUID.randomUUID().toString(), Set.of(observed)));
    assertThat(foreign.get(observed).source()).isEqualTo("NONE");
  }

  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;
  String tenant, owner, root, app;

  RequestPostProcessor actor(String who) {
    return jwt()
        .jwt(j -> j.subject(who))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  JsonNode body(ResultActions response) throws Exception {
    return json.readTree(response.andReturn().getResponse().getContentAsString());
  }

  @BeforeEach
  void setup() throws Exception {
    owner = "classification-owner-" + UUID.randomUUID();
    tenant =
        body(mvc.perform(
                    post("/api/v1/tenants")
                        .with(actor(owner))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            "{\"name\":\"Categories\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
                .andExpect(status().isCreated()))
            .path("id")
            .asText();
    root = "/api/v1/tenants/" + tenant + "/applications/";
    app = application("ANDROID", "PRIMARY", "org.example.reader", List.of());
  }

  String application(String platform, String profile, String name, List<String> digests)
      throws Exception {
    return body(mvc.perform(
                post(root.substring(0, root.length() - 1))
                    .with(actor(owner))
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(
                        json.writeValueAsString(
                            Map.of(
                                "displayName",
                                "Reader",
                                "platform",
                                platform,
                                "profile",
                                profile,
                                "packageName",
                                name,
                                "signingDigests",
                                digests))))
            .andExpect(status().isCreated()))
        .path("id")
        .asText();
  }

  ResultActions read(String who, String id) throws Exception {
    return mvc.perform(get(root + id + "/classification").with(actor(who)));
  }

  ResultActions update(String who, String id, String version, String key, String category)
      throws Exception {
    var request =
        put(root + id + "/classification")
            .with(actor(who))
            .contentType(MediaType.APPLICATION_JSON)
            .content(json.writeValueAsString(Map.of("category", category)));
    if (version != null) request.header("If-Match", version);
    if (key != null) request.header("Idempotency-Key", key);
    return mvc.perform(request);
  }

  void member(String who, String role) {
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,?)",
        tenant,
        who,
        ActorKeys.key(who),
        role);
  }

  @Test
  void unclassifiedIsExplicitAndUpdatesAreVersionedAuditedAndIdempotent() throws Exception {
    read(owner, app)
        .andExpect(status().isOk())
        .andExpect(header().string("ETag", "\"0\""))
        .andExpect(header().string("Cache-Control", "no-store"))
        .andExpect(jsonPath("$.category").value("UNCLASSIFIED"))
        .andExpect(jsonPath("$.source").value("NONE"));
    var first =
        body(
            update(owner, app, "\"0\"", "classify-once", "EDUCATION")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.version").value(1))
                .andExpect(jsonPath("$.source").value("ADMIN_DECLARED")));
    assertThat(
            body(
                update(owner, app, "\"0\"", "classify-once", "EDUCATION")
                    .andExpect(status().isOk())))
        .isEqualTo(first);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                    + " action='APPLICATION_CLASSIFICATION_CHANGED'",
                Integer.class,
                tenant))
        .isEqualTo(1);
    update(owner, app, "\"1\"", "clear", "UNCLASSIFIED")
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.version").value(2))
        .andExpect(jsonPath("$.source").value("ADMIN_DECLARED"));
  }

  @Test
  void matchingUsesExactPlatformProfileAndPackageButDoesNotClaimSignerVerification()
      throws Exception {
    update(owner, app, "\"0\"", null, "EDUCATION").andExpect(status().isOk());
    String otherSigner =
        application("ANDROID", "PRIMARY", "org.example.reader", List.of("a".repeat(64)));
    read(owner, otherSigner)
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.category").value("EDUCATION"));
    for (String id :
        List.of(
            application("ANDROID_TV", "PRIMARY", "org.example.reader", List.of()),
            application("ANDROID", "WORK", "org.example.reader", List.of()),
            application("ANDROID", "PRIMARY", "org.example.Reader", List.of()))) {
      read(owner, id)
          .andExpect(status().isOk())
          .andExpect(jsonPath("$.category").value("UNCLASSIFIED"));
    }
    mvc.perform(get(root + app).with(actor(owner)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.evidenceStatus").value("ADMIN_DECLARED"))
        .andExpect(jsonPath("$.signingDigests.length()").value(0));
  }

  @Test
  void authorizationIsCheckedForReadsWritesAndCachedResponses() throws Exception {
    update(owner, app, "\"0\"", "replay", "TOOLS").andExpect(status().isOk());
    String auditor = "auditor-" + UUID.randomUUID();
    member(auditor, "AUDITOR");
    read(auditor, app).andExpect(status().isOk());
    update(auditor, app, "\"1\"", null, "OTHER").andExpect(status().isForbidden());
    String teacher = "teacher-" + UUID.randomUUID();
    member(teacher, "TEACHER");
    read(teacher, app).andExpect(status().isForbidden());
    read("outsider", app).andExpect(status().isForbidden());
    read(owner, UUID.randomUUID().toString()).andExpect(status().isForbidden());
    db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?",
        tenant,
        ActorKeys.key(owner));
    update(owner, app, "\"0\"", "replay", "TOOLS").andExpect(status().isForbidden());
  }

  @Test
  void missingWeakStaleVersionsAndUnknownCategoriesFailWithoutMutation() throws Exception {
    update(owner, app, null, null, "EDUCATION").andExpect(status().isPreconditionRequired());
    update(owner, app, "W/\"0\"", null, "EDUCATION").andExpect(status().isBadRequest());
    update(owner, app, "\"1\"", null, "EDUCATION").andExpect(status().isPreconditionFailed());
    update(owner, app, "\"0\"", null, "GUESS_FROM_PACKAGE").andExpect(status().isBadRequest());
    read(owner, app).andExpect(status().isOk()).andExpect(jsonPath("$.version").value(0));
  }

  @Test
  void simultaneousFirstUpdatesHaveOneWinnerAcrossDifferentMembers() throws Exception {
    String guardian = "guardian-" + UUID.randomUUID();
    member(guardian, "GUARDIAN");
    var executor = Executors.newFixedThreadPool(2);
    var ready = new CountDownLatch(2);
    var start = new CountDownLatch(1);
    try {
      var futures = new ArrayList<Future<Integer>>();
      for (String who : List.of(owner, guardian))
        futures.add(
            executor.submit(
                () -> {
                  ready.countDown();
                  if (!start.await(5, TimeUnit.SECONDS)) throw new AssertionError("start timeout");
                  return update(who, app, "\"0\"", UUID.randomUUID().toString(), "EDUCATION")
                      .andReturn()
                      .getResponse()
                      .getStatus();
                }));
      assertThat(ready.await(5, TimeUnit.SECONDS)).isTrue();
      start.countDown();
      var statuses = new ArrayList<Integer>();
      for (var future : futures) statuses.add(future.get(15, TimeUnit.SECONDS));
      assertThat(statuses).containsExactlyInAnyOrder(200, 412);
    } finally {
      start.countDown();
      executor.shutdownNow();
    }
  }
}
