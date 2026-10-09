package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(
    properties = {
      "spring.datasource.url=${ORGANIZATION_TEST_DATABASE_URL:jdbc:h2:mem:organization;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${ORGANIZATION_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${ORGANIZATION_TEST_DATABASE_PASSWORD:}",
      "spring.flyway.enabled=true"
    })
@AutoConfigureMockMvc
class OrganizationJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;

  RequestPostProcessor actor(String name) {
    return actor(name, true);
  }

  RequestPostProcessor actor(String name, boolean mfa) {
    return jwt()
        .jwt(
            t ->
                t.subject(name)
                    .claim("email", name + "@example.test")
                    .claim("email_verified", true)
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", mfa ? List.of("pwd", "otp") : List.of("pwd")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  record Space(String id, String owner) {
    String root() {
      return "/api/v1/tenants/" + id;
    }

    String classes() {
      return root() + "/classes";
    }
  }

  Space space(String kind) throws Exception {
    String owner = "organization-owner-" + UUID.randomUUID();
    var r =
        mvc.perform(
                post("/api/v1/tenants")
                    .with(actor(owner))
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(
                        json.writeValueAsBytes(
                            Map.of("name", "班级工作流", "kind", kind, "timeZone", "UTC"))))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse();
    return new Space(json.readTree(r.getContentAsString()).path("id").asText(), owner);
  }

  String classroom(Space s, String name) throws Exception {
    return json.readTree(
            mvc.perform(
                    post(s.classes())
                        .with(actor(s.owner()))
                        .header("Idempotency-Key", UUID.randomUUID())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsBytes(Map.of("name", name))))
                .andExpect(status().isCreated())
                .andExpect(header().string("ETag", "\"0\""))
                .andReturn()
                .getResponse()
                .getContentAsString())
        .path("id")
        .asText();
  }

  String subject(Space s) throws Exception {
    return json.readTree(
            mvc.perform(
                    post(s.root() + "/subjects")
                        .with(actor(s.owner()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"nickname\":\"学生档案\",\"ageBand\":\"AGE_7_12\"}"))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString())
        .path("id")
        .asText();
  }

  void add(Space s, String group, String student, long version) throws Exception {
    mvc.perform(
            post(s.classes() + "/" + group + "/students")
                .with(actor(s.owner()))
                .header("If-Match", "\"" + version + "\"")
                .header("Idempotency-Key", UUID.randomUUID())
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("subjectId", student))))
        .andExpect(status().isOk());
  }

  @Test
  void classesAreOrganizationOnlyAndMutationsRequireRecentMfa() throws Exception {
    var family = space("FAMILY");
    mvc.perform(
            post(family.classes())
                .with(actor(family.owner()))
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"name\":\"班级\"}"))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.errorCode").value("ORGANIZATION_REQUIRED"));
    var s = space("ORGANIZATION");
    mvc.perform(
            post(s.classes())
                .with(actor(s.owner(), false))
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"name\":\"班级\"}"))
        .andExpect(status().isUnauthorized());
    String c = classroom(s, "七年级一班");
    mvc.perform(get(s.classes()).with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].name").value("七年级一班"));
    mvc.perform(
            patch(s.classes() + "/" + c)
                .with(actor(s.owner()))
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"name\":\"新名称\"}"))
        .andExpect(status().isPreconditionRequired());
  }

  @Test
  void rosterAddIsIdempotentAndCrossTenantOrArchivedStudentsAreRejected() throws Exception {
    var s = space("ORGANIZATION");
    String c = classroom(s, "一班"), student = subject(s);
    var req =
        post(s.classes() + "/" + c + "/students")
            .with(actor(s.owner()))
            .header("If-Match", "\"0\"")
            .header("Idempotency-Key", "add")
            .contentType(MediaType.APPLICATION_JSON)
            .content(json.writeValueAsBytes(Map.of("subjectId", student)));
    mvc.perform(req).andExpect(status().isOk()).andExpect(jsonPath("$.version").value(1));
    mvc.perform(req).andExpect(status().isOk()).andExpect(jsonPath("$.version").value(1));
    mvc.perform(get(s.classes() + "/" + c + "/students").with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1))
        .andExpect(jsonPath("$.items[0].id").value(student));
    var other = space("ORGANIZATION");
    String foreign = subject(other);
    mvc.perform(
            post(s.classes() + "/" + c + "/students")
                .with(actor(s.owner()))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("subjectId", foreign))))
        .andExpect(status().isForbidden());
    String archived = subject(s);
    db.update("UPDATE subjects SET archived_at=1 WHERE tenant_id=? AND id=?", s.id(), archived);
    mvc.perform(
            post(s.classes() + "/" + c + "/students")
                .with(actor(s.owner()))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("subjectId", archived))))
        .andExpect(status().isForbidden());
  }

  @Test
  void transferIsAtomicAndChecksBothClassVersions() throws Exception {
    var s = space("ORGANIZATION");
    String first = classroom(s, "一班"), second = classroom(s, "二班"), student = subject(s);
    add(s, first, student, 0);
    String path = s.classes() + "/" + first + "/students/" + student + "/transfer";
    mvc.perform(
            post(path)
                .with(actor(s.owner()))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    json.writeValueAsBytes(Map.of("targetClassId", second, "targetVersion", 1))))
        .andExpect(status().isPreconditionFailed());
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM organization_class_students WHERE tenant_id=? AND class_id=?",
                Integer.class,
                s.id(),
                first))
        .isEqualTo(1);
    var req =
        post(path)
            .with(actor(s.owner()))
            .header("If-Match", "\"1\"")
            .header("Idempotency-Key", "transfer")
            .contentType(MediaType.APPLICATION_JSON)
            .content(json.writeValueAsBytes(Map.of("targetClassId", second, "targetVersion", 0)));
    mvc.perform(req)
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.source.version").value(2))
        .andExpect(jsonPath("$.target.version").value(1));
    mvc.perform(req).andExpect(status().isOk());
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM organization_class_students WHERE tenant_id=? AND class_id=?",
                Integer.class,
                s.id(),
                first))
        .isZero();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM organization_class_students WHERE tenant_id=? AND class_id=?",
                Integer.class,
                s.id(),
                second))
        .isEqualTo(1);
  }

  @Test
  void archiveHidesClassAndStopsRosterMutationWithoutDeletingStudent() throws Exception {
    var s = space("ORGANIZATION");
    String c = classroom(s, "一班"), student = subject(s);
    add(s, c, student, 0);
    mvc.perform(
            post(s.classes() + "/" + c + "/archive")
                .with(actor(s.owner()))
                .header("If-Match", "\"1\"")
                .header("Idempotency-Key", "archive"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("ARCHIVED"));
    mvc.perform(get(s.classes()).with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items").isEmpty());
    mvc.perform(get(s.classes() + "?includeArchived=true").with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1));
    mvc.perform(get(s.root() + "/subjects/" + student).with(actor(s.owner())))
        .andExpect(status().isOk());
    mvc.perform(
            post(s.classes() + "/" + c + "/students")
                .with(actor(s.owner()))
                .header("If-Match", "\"2\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("subjectId", student))))
        .andExpect(status().isConflict());
  }

  @Test
  void nonManagerCannotCreateClassAndForeignTenantCannotReadIt() throws Exception {
    var s = space("ORGANIZATION");
    String teacher = "teacher-" + UUID.randomUUID(), student = subject(s);
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'TEACHER',?)",
        s.id(),
        teacher,
        ActorKeys.key(teacher),
        student);
    mvc.perform(
            post(s.classes())
                .with(actor(teacher))
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"name\":\"非法\"}"))
        .andExpect(status().isForbidden());
    String c = classroom(s, "班级");
    var other = space("ORGANIZATION");
    mvc.perform(get(other.classes() + "/" + c).with(actor(other.owner())))
        .andExpect(status().isForbidden());
  }

  @Test
  void unsupportedHttpMethodIsReportedAsClientErrorWithoutChangingTheClass() throws Exception {
    var s = space("ORGANIZATION");
    String c = classroom(s, "方法边界");
    mvc.perform(delete(s.classes() + "/" + c).with(actor(s.owner())))
        .andExpect(status().isMethodNotAllowed())
        .andExpect(header().exists("Allow"))
        .andExpect(jsonPath("$.errorCode").value("METHOD_NOT_ALLOWED"));
    mvc.perform(get(s.classes() + "/" + c).with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.version").value(0));
  }

  String teacher(Space s, List<String> classes) throws Exception {
    String who = "teacher-" + UUID.randomUUID();
    var invitation =
        json.readTree(
            mvc.perform(
                    post(s.root() + "/invitations")
                        .with(actor(s.owner()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            json.writeValueAsBytes(
                                Map.of(
                                    "recipientEmail",
                                    who + "@example.test",
                                    "role",
                                    "TEACHER",
                                    "classIds",
                                    classes))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString());
    mvc.perform(
            post("/api/v1/invitations/accept")
                .with(actor(who))
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    json.writeValueAsBytes(Map.of("token", invitation.path("token").asText()))))
        .andExpect(status().isOk());
    return who;
  }

  @Test
  void teacherClassInvitationLimitsRosterProfilesAndDevicesToAssignedClasses() throws Exception {
    var s = space("ORGANIZATION");
    String first = classroom(s, "一班"),
        second = classroom(s, "二班"),
        student = subject(s),
        other = subject(s);
    add(s, first, student, 0);
    add(s, second, other, 0);
    String who = teacher(s, List.of(first));
    mvc.perform(get(s.classes()).with(actor(who)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1))
        .andExpect(jsonPath("$.items[0].id").value(first));
    mvc.perform(get(s.classes() + "/" + second + "/students").with(actor(who)))
        .andExpect(status().isForbidden());
    mvc.perform(get(s.root() + "/subjects").with(actor(who)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1))
        .andExpect(jsonPath("$.items[0].id").value(student));
    mvc.perform(get(s.root() + "/subjects/" + other).with(actor(who)))
        .andExpect(status().isForbidden());
    var devices = new java.util.HashMap<String, String>();
    for (String child : List.of(student, other)) {
      String device = UUID.randomUUID().toString();
      devices.put(child, device);
      db.update(
          "INSERT INTO"
              + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
              + " VALUES(?,?,?,?,'机构设备','ANDROID','14','ACTIVE','{}','fixture',1)",
          s.id(),
          device,
          child,
          UUID.randomUUID().toString());
    }
    mvc.perform(get(s.root() + "/devices").with(actor(who)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1))
        .andExpect(jsonPath("$.items[0].id").value(devices.get(student)));
    mvc.perform(get(s.root() + "/devices/" + devices.get(other)).with(actor(who)))
        .andExpect(status().isForbidden());
    mvc.perform(
            get(s.root() + "/devices/" + devices.get(student) + "/application-inventory")
                .with(actor(who)))
        .andExpect(status().isForbidden());
    for (String route : List.of("/policies", "/members"))
      mvc.perform(get(s.root() + route).with(actor(who))).andExpect(status().isForbidden());
    mvc.perform(get(s.root() + "/access-requests").with(actor(who)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(0));
    mvc.perform(
            post(s.root() + "/subjects")
                .with(actor(who))
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"nickname\":\"禁止\",\"ageBand\":\"AGE_7_12\"}"))
        .andExpect(status().isForbidden());
  }

  @Test
  void changingClassScopeIsVersionedAndOldScopeCannotReturnAfterRejoin() throws Exception {
    var s = space("ORGANIZATION");
    String first = classroom(s, "一班"), second = classroom(s, "二班");
    String who = teacher(s, List.of(first));
    String path = s.root() + "/members/" + ActorKeys.key(who) + "/access";
    mvc.perform(get(path).with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.classIds[0]").value(first));
    mvc.perform(
            patch(path)
                .with(actor(s.owner()))
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    json.writeValueAsBytes(Map.of("role", "TEACHER", "classIds", List.of(second)))))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.version").value(1))
        .andExpect(jsonPath("$.classIds[0]").value(second));
    mvc.perform(get(s.classes() + "/" + first).with(actor(who))).andExpect(status().isForbidden());
    mvc.perform(get(path + "-history").with(actor(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].previousClassIds[0]").value(first))
        .andExpect(jsonPath("$.items[0].classIds[0]").value(second));
    mvc.perform(delete(path).with(actor(s.owner())).header("If-Match", "\"1\""))
        .andExpect(status().isNoContent());
    db.update(
        "UPDATE tenant_members SET revoked_at=NULL,version=version+1 WHERE tenant_id=? AND"
            + " actor_key=?",
        s.id(),
        ActorKeys.key(who));
    mvc.perform(get(s.classes()).with(actor(who)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items").isEmpty());
  }

  @Test
  void removingOneClassRetainsAnotherScopeButArchiveAndSubjectArchiveImmediatelyHideProfiles()
      throws Exception {
    var s = space("ORGANIZATION");
    String a = classroom(s, "甲班"), b = classroom(s, "乙班"), child = subject(s);
    add(s, a, child, 0);
    add(s, b, child, 0);
    String who = teacher(s, List.of(a, b));
    mvc.perform(
            delete(s.classes() + "/" + a + "/students/" + child)
                .with(actor(s.owner()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isOk());
    mvc.perform(get(s.root() + "/subjects/" + child).with(actor(who))).andExpect(status().isOk());
    mvc.perform(
            post(s.classes() + "/" + b + "/archive")
                .with(actor(s.owner()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isOk());
    mvc.perform(get(s.root() + "/subjects/" + child).with(actor(who)))
        .andExpect(status().isForbidden());
    add(s, a, child, 2);
    mvc.perform(get(s.root() + "/subjects/" + child).with(actor(who))).andExpect(status().isOk());
    mvc.perform(
            post(s.root() + "/subjects/" + child + "/archive")
                .with(actor(s.owner()))
                .header("If-Match", "\"0\""))
        .andExpect(status().isNoContent());
    mvc.perform(get(s.root() + "/subjects").with(actor(who)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items").isEmpty());
    mvc.perform(get(s.classes() + "/" + a + "/students").with(actor(who)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items").isEmpty());
  }

  @Test
  void concurrentTransfersCannotLoseOrDuplicateRosterMembership() throws Exception {
    var s = space("ORGANIZATION");
    String from = classroom(s, "源班"),
        a = classroom(s, "甲班"),
        b = classroom(s, "乙班"),
        child = subject(s);
    add(s, from, child, 0);
    var pool = java.util.concurrent.Executors.newFixedThreadPool(2);
    var gate = new java.util.concurrent.CountDownLatch(1);
    try {
      var jobs = new java.util.ArrayList<java.util.concurrent.Future<Integer>>();
      for (String target : List.of(a, b))
        jobs.add(
            pool.submit(
                () -> {
                  gate.await();
                  return mvc.perform(
                          post(s.classes() + "/" + from + "/students/" + child + "/transfer")
                              .with(actor(s.owner()))
                              .header("If-Match", "\"1\"")
                              .header("Idempotency-Key", target)
                              .contentType(MediaType.APPLICATION_JSON)
                              .content(
                                  json.writeValueAsBytes(
                                      Map.of("targetClassId", target, "targetVersion", 0))))
                      .andReturn()
                      .getResponse()
                      .getStatus();
                }));
      gate.countDown();
      var statuses = new java.util.ArrayList<Integer>();
      for (var job : jobs) statuses.add(job.get(30, java.util.concurrent.TimeUnit.SECONDS));
      assertThat(statuses).containsExactlyInAnyOrder(200, 412);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM organization_class_students WHERE tenant_id=? AND"
                      + " subject_id=?",
                  Integer.class,
                  s.id(),
                  child))
          .isEqualTo(1);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM organization_class_students WHERE tenant_id=? AND"
                      + " class_id=?",
                  Integer.class,
                  s.id(),
                  from))
          .isZero();
    } finally {
      pool.shutdownNow();
    }
  }

  @Test
  void scopeInvitationRejectsMixedDuplicateForeignAndArchivedClasses() throws Exception {
    var s = space("ORGANIZATION");
    var other = space("ORGANIZATION");
    String own = classroom(s, "一班"), foreign = classroom(other, "外班"), child = subject(s);
    for (var body :
        List.of(
            Map.of(
                "recipientEmail",
                "t@example.test",
                "role",
                "TEACHER",
                "subjectId",
                child,
                "classIds",
                List.of(own)),
            Map.of(
                "recipientEmail",
                "t@example.test",
                "role",
                "TEACHER",
                "classIds",
                List.of(own, own)),
            Map.of(
                "recipientEmail",
                "t@example.test",
                "role",
                "TEACHER",
                "classIds",
                List.of(foreign))))
      mvc.perform(
              post(s.root() + "/invitations")
                  .with(actor(s.owner()))
                  .contentType(MediaType.APPLICATION_JSON)
                  .content(json.writeValueAsBytes(body)))
          .andExpect(status().isBadRequest());
    var invite =
        json.readTree(
            mvc.perform(
                    post(s.root() + "/invitations")
                        .with(actor(s.owner()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            json.writeValueAsBytes(
                                Map.of(
                                    "recipientEmail",
                                    "t@example.test",
                                    "role",
                                    "TEACHER",
                                    "classIds",
                                    List.of(own)))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString());
    mvc.perform(
            post(s.classes() + "/" + own + "/archive")
                .with(actor(s.owner()))
                .header("If-Match", "\"0\""))
        .andExpect(status().isOk());
    mvc.perform(
            post("/api/v1/invitations/accept")
                .with(actor("t"))
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("token", invite.path("token").asText()))))
        .andExpect(status().isBadRequest());
  }
}
