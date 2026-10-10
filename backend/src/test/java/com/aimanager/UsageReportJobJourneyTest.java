package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.JWEAlgorithm;
import com.nimbusds.jose.jwk.*;
import com.nimbusds.jose.jwk.gen.OctetSequenceKeyGenerator;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.*;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "spring.datasource.url=${USAGE_REPORT_TEST_DATABASE_URL:jdbc:h2:mem:report-jobs;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${USAGE_REPORT_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${USAGE_REPORT_TEST_DATABASE_PASSWORD:}",
      "manager.report-jobs.worker.enabled=false",
      "manager.exports.worker.enabled=false",
      "manager.notifications.retention-job.enabled=false"
    })
@AutoConfigureMockMvc
class UsageReportJobJourneyTest {
  @org.springframework.boot.test.web.server.LocalServerPort int port;
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;
  @MockitoSpyBean com.aimanager.observation.UsageReportSource observationSource;

  @Test
  @org.junit.jupiter.api.condition.EnabledIfSystemProperty(
      named = "device.dart.command",
      matches = ".+")
  void realHttpJobsAreConsumedByProductionDartClient() throws Exception {
    devices = new ArrayList<>(devices.subList(0, 2));
    String other = "job-http-other-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')",
        tenant,
        other,
        com.aimanager.identity.ActorKeys.key(other));
    String ownerToken = UUID.randomUUID().toString(),
        weakToken = UUID.randomUUID().toString(),
        otherToken = UUID.randomUUID().toString();
    when(decoder.decode(anyString()))
        .thenAnswer(
            call -> {
              String token = call.getArgument(0);
              if (!List.of(ownerToken, weakToken, otherToken).contains(token)) {
                throw new org.springframework.security.oauth2.jwt.BadJwtException(
                    "Unknown fixture");
              }
              return org.springframework.security.oauth2.jwt.Jwt.withTokenValue(token)
                  .header("alg", "fixture")
                  .subject(token.equals(otherToken) ? other : owner)
                  .issuedAt(Instant.now())
                  .expiresAt(Instant.now().plusSeconds(300))
                  .claim("auth_time", Instant.now().getEpochSecond())
                  .claim("amr", token.equals(weakToken) ? List.of("pwd") : List.of("pwd", "otp"))
                  .build();
            });
    var directory =
        Files.createTempDirectory(
            Files.createDirectories(Path.of(".local").toAbsolutePath()), "report-job-http-");
    var fixture = directory.resolve("fixture.json");
    var output = directory.resolve("client.log");
    var values = new LinkedHashMap<String, Object>();
    values.put("testOnly", true);
    values.put("apiRoot", "http://127.0.0.1:" + port + "/api/v1");
    values.put("tenantId", tenant);
    values.put("ownerToken", ownerToken);
    values.put("weakToken", weakToken);
    values.put("otherToken", otherToken);
    values.put("selection", input());
    json.writeValue(fixture.toFile(), values);
    Process process = null;
    try {
      process =
          new ProcessBuilder(
                  System.getProperty("device.dart.command"),
                  "run",
                  "tool/verify_usage_report_jobs_http.dart",
                  fixture.toString())
              .directory(
                  Path.of(System.getProperty("usage.report.guardian.package", "../apps/guardian"))
                      .toAbsolutePath()
                      .toFile())
              .redirectErrorStream(true)
              .redirectOutput(output.toFile())
              .start();
      long deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(60);
      while (process.isAlive() && System.nanoTime() < deadline) {
        worker.runBatch(25);
        process.waitFor(100, java.util.concurrent.TimeUnit.MILLISECONDS);
      }
      assertThat(process.isAlive()).as("Report task client deadline exceeded").isFalse();
      assertThat(process.exitValue()).as("Report task client diagnostics: %s", output).isZero();
      assertThat(Files.readString(output)).contains("PASS usage report jobs HTTP");
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM usage_report_jobs WHERE tenant_id=? AND state='CANCELLED'",
                  Integer.class,
                  tenant))
          .isEqualTo(1);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM usage_report_parts WHERE tenant_id=? AND artifact IS NOT"
                      + " NULL",
                  Integer.class,
                  tenant))
          .isZero();
    } finally {
      if (process != null && process.isAlive()) process.destroyForcibly();
      Files.deleteIfExists(fixture);
    }
  }

  @Test
  void intermediateStepsAuthorizeOnlyTheirDeviceAndFinalStepRechecksAll() throws Exception {
    devices = new ArrayList<>(devices.subList(0, 3));
    String id = create();
    clearInvocations(observationSource);
    worker.runBatch(25);
    worker.runBatch(25);
    verify(observationSource, times(2))
        .authorize(eq(tenant), eq(owner), argThat(ids -> ids.size() == 1));
    verify(observationSource, never())
        .authorize(eq(tenant), eq(owner), argThat(ids -> ids.size() > 1));
    db.update(
        "UPDATE device_observation_settings SET version=version+1 WHERE tenant_id=? AND"
            + " device_id=(SELECT device_id FROM usage_report_parts WHERE tenant_id=? AND job_id=?"
            + " AND ordinal=0)",
        tenant,
        tenant,
        id);
    worker.runBatch(25);
    assertThat(job(id).path("state").asText()).isEqualTo("REVOKED");
  }

  @Test
  void maximumSelectionCompletesWithoutUnboundedWholeSelectionReads() throws Exception {
    while (devices.size() < 200) addDevice();
    String id = create();
    for (int i = 0; i < 200; i++) worker.runBatch(25);
    var result = job(id);
    assertThat(result.path("state").asText()).isEqualTo("READY");
    assertThat(result.path("completedDevices").asInt()).isEqualTo(200);
    mvc.perform(get(root + "/" + id + "/parts/199").with(actor(owner))).andExpect(status().isOk());
  }

  @Test
  void archivedClassRevokesAlreadyGeneratedJob() throws Exception {
    devices = new ArrayList<>(List.of(devices.get(0)));
    db.update("UPDATE tenants SET kind='ORGANIZATION' WHERE id=?", tenant);
    String classroom = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO organization_classes(tenant_id,id,name,created_at,updated_at)"
            + " VALUES(?,?,'Class',?,?)",
        tenant,
        classroom,
        now,
        now);
    db.update(
        "INSERT INTO organization_class_students(tenant_id,class_id,subject_id,added_at)"
            + " VALUES(?,?,?,?)",
        tenant,
        classroom,
        subject,
        now);
    var selected = new HashMap<>(input());
    selected.put("scope", Map.of("kind", "CLASS", "id", classroom, "version", 0));
    String id =
        body(create(UUID.randomUUID().toString(), selected).andExpect(status().isAccepted()))
            .path("id")
            .asText();
    worker.runBatch(25);
    db.update(
        "UPDATE organization_classes SET archived_at=? WHERE tenant_id=? AND id=?",
        now,
        tenant,
        classroom);
    assertThat(job(id).path("state").asText()).isEqualTo("REVOKED");
  }

  @Test
  void sameTenantOtherGuardianCannotReadPrivateJob() throws Exception {
    String id = create(), guardian = "guardian-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')",
        tenant,
        guardian,
        com.aimanager.identity.ActorKeys.key(guardian));
    mvc.perform(get(root + "/" + id).with(actor(guardian))).andExpect(status().isNotFound());
    mvc.perform(post(root + "/" + id + "/cancel").with(actor(guardian)))
        .andExpect(status().isNotFound());
    mvc.perform(get(root).with(actor(guardian)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items").isEmpty());
  }

  @Test
  void newKeyRateLimitDoesNotBlockOriginalRetryAndUnknownInputIsRejected() throws Exception {
    String key = UUID.randomUUID().toString();
    create(key, input()).andExpect(status().isAccepted());
    create(UUID.randomUUID().toString(), input()).andExpect(status().isTooManyRequests());
    create(key, input()).andExpect(status().isAccepted());
    var invalid = new HashMap<>(input());
    invalid.put("includePrivateOtherDevices", true);
    create(UUID.randomUUID().toString(), invalid).andExpect(status().isBadRequest());
  }

  @Test
  void nonEmptyResultUsesExistingAggregationAndRejectsTampering() throws Exception {
    now =
        Instant.now()
            .atOffset(java.time.ZoneOffset.UTC)
            .toLocalDate()
            .minusDays(1)
            .atTime(12, 0)
            .toInstant(java.time.ZoneOffset.UTC)
            .toEpochMilli();
    devices = new ArrayList<>(List.of(devices.get(0)));
    String device = devices.get(0);
    String registration =
        db.queryForObject(
            "SELECT registration_id FROM devices WHERE tenant_id=? AND id=?",
            String.class,
            tenant,
            device);
    String reportId = UUID.randomUUID().toString();
    var payload =
        Map.of(
            "reportId",
            reportId,
            "sequence",
            1,
            "authorizationVersion",
            1,
            "source",
            "ANDROID_USAGE_STATS",
            "profile",
            "PRIMARY",
            "queryStart",
            now - 3600000,
            "queryEnd",
            now - 1000,
            "observedAt",
            now - 1000,
            "timeZone",
            "UTC",
            "applications",
            List.of(
                Map.of(
                    "packageName",
                    "org.example.reader",
                    "displayName",
                    "阅读",
                    "firstTimeStamp",
                    now - 3600000,
                    "lastTimeStamp",
                    now - 1000,
                    "foregroundMillis",
                    2000)));
    db.update(
        "INSERT INTO"
            + " usage_observation_batches(tenant_id,device_id,registration_id,sequence_number,report_id,authorization_version,payload_json,received_at)"
            + " VALUES(?,?,?,1,?,1,?,?)",
        tenant,
        device,
        registration,
        reportId,
        json.writeValueAsString(payload),
        now);
    String id = create();
    worker.runBatch(25);
    mvc.perform(get(root + "/" + id + "/parts/0").with(actor(owner)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.devices[0].applications[0].buckets[0].lowerMillis").value(2000))
        .andExpect(jsonPath("$.evidenceStatus").value("AGENT_REPORTED_UNVERIFIED"));
    String encrypted =
        db.queryForObject(
            "SELECT artifact FROM usage_report_parts WHERE tenant_id=? AND job_id=?",
            String.class,
            tenant,
            id);
    db.update(
        "UPDATE usage_report_parts SET artifact=? WHERE tenant_id=? AND job_id=?",
        encrypted + "x",
        tenant,
        id);
    mvc.perform(get(root + "/" + id + "/parts/0").with(actor(owner)))
        .andExpect(status().isServiceUnavailable());
  }

  @Test
  void twoWorkersPublishOneSingleDeviceResult() throws Exception {
    devices = new ArrayList<>(List.of(devices.get(0)));
    String id = create();
    var executor = java.util.concurrent.Executors.newFixedThreadPool(2);
    try {
      var one = executor.submit(() -> worker.runBatch(25));
      var two = executor.submit(() -> worker.runBatch(25));
      one.get(20, java.util.concurrent.TimeUnit.SECONDS);
      two.get(20, java.util.concurrent.TimeUnit.SECONDS);
      assertThat(job(id).path("completedDevices").asInt()).isEqualTo(1);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND resource_id=? AND"
                      + " action='USAGE_REPORT_JOB_GENERATED'",
                  Integer.class,
                  tenant,
                  id))
          .isEqualTo(1);
    } finally {
      executor.shutdownNow();
    }
  }

  @Test
  void lostLeaseResumesAfterAlreadyPublishedPart() throws Exception {
    devices = new ArrayList<>(devices.subList(0, 2));
    String id = create();
    worker.runBatch(25);
    assertThat(job(id).path("completedDevices").asInt()).isEqualTo(1);
    String first =
        db.queryForObject(
            "SELECT artifact FROM usage_report_parts WHERE tenant_id=? AND job_id=? AND ordinal=0",
            String.class,
            tenant,
            id);
    db.update(
        "UPDATE usage_report_jobs SET state='RUNNING',claim_token=?,lease_until=0,attempts=1 WHERE"
            + " tenant_id=? AND id=?",
        UUID.randomUUID().toString(),
        tenant,
        id);
    worker.runBatch(25);
    assertThat(job(id).path("state").asText()).isEqualTo("READY");
    assertThat(
            db.queryForObject(
                "SELECT artifact FROM usage_report_parts WHERE tenant_id=? AND job_id=? AND"
                    + " ordinal=0",
                String.class,
                tenant,
                id))
        .isEqualTo(first);
  }

  @Test
  void transientFailureBacksOffThenResumesWithoutPartialDownload() throws Exception {
    devices = new ArrayList<>(List.of(devices.get(0)));
    String id = create();
    doThrow(new IllegalStateException("isolated temporary failure"))
        .when(observationSource)
        .read(eq(tenant), eq(owner), anyList(), anyLong());
    worker.runBatch(25);
    assertThat(job(id).path("failureCode").asText()).isEqualTo("REPORT_TEMPORARY_FAILURE");
    worker.runBatch(25);
    assertThat(
            db.queryForObject(
                "SELECT attempts FROM usage_report_jobs WHERE tenant_id=? AND id=?",
                Integer.class,
                tenant,
                id))
        .isEqualTo(1);
    mvc.perform(get(root + "/" + id + "/parts/0").with(actor(owner)))
        .andExpect(status().isConflict());
    doCallRealMethod().when(observationSource).read(eq(tenant), eq(owner), anyList(), anyLong());
    db.update(
        "UPDATE usage_report_jobs SET next_attempt_at=0 WHERE tenant_id=? AND id=?", tenant, id);
    worker.runBatch(25);
    assertThat(job(id).path("state").asText()).isEqualTo("READY");
  }

  @Test
  void archiveRebindAndMembershipVersionChangesInvalidateResults() throws Exception {
    devices = new ArrayList<>(List.of(devices.get(0)));
    String id = create();
    worker.runBatch(25);
    db.update("UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?", now, tenant, subject);
    assertThat(job(id).path("state").asText()).isEqualTo("REVOKED");
    assertThat(
            db.queryForObject(
                "SELECT artifact FROM usage_report_parts WHERE tenant_id=? AND job_id=?",
                String.class,
                tenant,
                id))
        .isNull();
  }

  @Test
  void membershipVersionChangePreventsGeneration() throws Exception {
    String id = create();
    db.update("UPDATE tenant_members SET version=version+1 WHERE tenant_id=?", tenant);
    worker.runBatch(25);
    assertThat(job(id).path("state").asText()).isEqualTo("REVOKED");
    assertThat(job(id).path("completedDevices").asInt()).isZero();
  }

  @Test
  void reRegistrationPreventsSavedReportRead() throws Exception {
    devices = new ArrayList<>(List.of(devices.get(0)));
    String id = create();
    worker.runBatch(25);
    db.update(
        "DELETE FROM device_observation_settings WHERE tenant_id=? AND device_id=?",
        tenant,
        devices.get(0));
    db.update(
        "UPDATE devices SET registration_id=? WHERE tenant_id=? AND id=?",
        UUID.randomUUID().toString(),
        tenant,
        devices.get(0));
    mvc.perform(get(root + "/" + id + "/parts/0").with(actor(owner)))
        .andExpect(status().isConflict());
    assertThat(job(id).path("state").asText()).isEqualTo("REVOKED");
  }

  @Test
  void downloadRequiresRecentAuthenticationAndCancellationErasesCiphertext() throws Exception {
    devices = new ArrayList<>(List.of(devices.get(0)));
    String id = create();
    worker.runBatch(25);
    mvc.perform(get(root + "/" + id + "/parts/0").with(jwt().jwt(j -> j.subject(owner))))
        .andExpect(status().isUnauthorized())
        .andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
    mvc.perform(post(root + "/" + id + "/cancel").with(actor(owner))).andExpect(status().isOk());
    assertThat(
            db.queryForObject(
                "SELECT artifact FROM usage_report_parts WHERE tenant_id=? AND job_id=?",
                String.class,
                tenant,
                id))
        .isNull();
  }

  @Test
  void taskByteLimitFailsWholeJobWithoutPartialSuccess() throws Exception {
    String id = create();
    db.update(
        "UPDATE usage_report_jobs SET byte_count=? WHERE tenant_id=? AND id=?",
        128L * 1024 * 1024,
        tenant,
        id);
    worker.runBatch(25);
    assertThat(job(id).path("state").asText()).isEqualTo("FAILED");
    assertThat(job(id).path("failureCode").asText()).isEqualTo("REPORT_JOB_BYTE_LIMIT_EXCEEDED");
  }

  @Autowired(required = false)
  com.aimanager.reporting.ReportJobMaintenance worker;

  @Test
  void generatesTwentyOneEncryptedPartsAndServesCurrentAuthorizedResults() throws Exception {
    String id = create();
    assertThat(worker).isNotNull();
    for (int i = 0; i < 21; i++) worker.runBatch(25);
    assertThat(job(id).path("state").asText()).isEqualTo("READY");
    assertThat(job(id).path("completedDevices").asInt()).isEqualTo(21);
    var encrypted =
        db.queryForList(
            "SELECT artifact FROM usage_report_parts WHERE tenant_id=? AND job_id=?",
            String.class,
            tenant,
            id);
    assertThat(encrypted)
        .hasSize(21)
        .allMatch(v -> v != null && !v.contains("NO_DATA") && v.split("\\.", -1).length == 5);
    mvc.perform(get(root + "/" + id + "/parts/0").with(actor(owner)))
        .andExpect(status().isOk())
        .andExpect(header().string("Cache-Control", "no-store"))
        .andExpect(jsonPath("$.devices[0].status").value("NO_DATA"));
  }

  @Test
  void changedConsentRevokesJobAndRemovesCompletedParts() throws Exception {
    String id = create();
    assertThat(worker).isNotNull();
    worker.runBatch(25);
    db.update(
        "UPDATE device_observation_settings SET version=version+1,usage_enabled=false WHERE"
            + " tenant_id=? AND device_id=?",
        tenant,
        devices.get(0));
    assertThat(job(id).path("state").asText()).isEqualTo("REVOKED");
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM usage_report_parts WHERE tenant_id=? AND job_id=? AND"
                    + " artifact IS NOT NULL",
                Integer.class,
                tenant,
                id))
        .isZero();
    mvc.perform(get(root + "/" + id + "/parts/0").with(actor(owner)))
        .andExpect(status().isConflict());
  }

  @Test
  void expiredJobsPurgeEncryptedPartsAndCannotBeRead() throws Exception {
    String id = create();
    assertThat(worker).isNotNull();
    worker.runBatch(25);
    db.update(
        "UPDATE usage_report_jobs SET expires_at=? WHERE tenant_id=? AND id=?",
        now - 1,
        tenant,
        id);
    worker.purge(100);
    assertThat(job(id).path("state").asText()).isEqualTo("EXPIRED");
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM usage_report_parts WHERE tenant_id=? AND job_id=? AND"
                    + " artifact IS NOT NULL",
                Integer.class,
                tenant,
                id))
        .isZero();
  }

  static Path keyFile;
  String tenant, owner, subject, root;
  List<String> devices;
  long now;

  @DynamicPropertySource
  static void keys(DynamicPropertyRegistry registry) throws Exception {
    keyFile = Files.createTempFile("report-job-test-", ".jwk");
    var key =
        new OctetSequenceKeyGenerator(256)
            .keyID("test-report")
            .keyUse(KeyUse.ENCRYPTION)
            .algorithm(JWEAlgorithm.DIR)
            .generate();
    Files.writeString(keyFile, new JWKSet(key).toString(false));
    registry.add("manager.exports.key-file", () -> keyFile.toString());
  }

  @AfterAll
  static void removeKey() throws Exception {
    if (keyFile != null) Files.deleteIfExists(keyFile);
  }

  RequestPostProcessor actor(String name) {
    return jwt()
        .jwt(
            j ->
                j.subject(name)
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  JsonNode body(ResultActions result) throws Exception {
    return json.readTree(result.andReturn().getResponse().getContentAsString());
  }

  @BeforeEach
  void setup() throws Exception {
    now = System.currentTimeMillis();
    owner = "job-owner-" + UUID.randomUUID();
    tenant =
        body(mvc.perform(
                    post("/api/v1/tenants")
                        .with(actor(owner))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            "{\"name\":\"Report jobs\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
                .andExpect(status().isCreated()))
            .path("id")
            .asText();
    subject = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'Child','AGE_7_12',?)",
        tenant,
        subject,
        now);
    devices = new ArrayList<>();
    for (int i = 0; i < 21; i++) addDevice();
    root = "/api/v1/tenants/" + tenant + "/usage-report-jobs";
  }

  void addDevice() {
    String id = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString();
    devices.add(id);
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'Report device','ANDROID','14','ACTIVE','{}','fixture',?)",
        tenant,
        id,
        subject,
        registration,
        now);
    db.update(
        "INSERT INTO"
            + " device_observation_settings(tenant_id,device_id,registration_id,version,inventory_enabled,usage_enabled,updated_at,last_reason)"
            + " VALUES(?,?,?,1,false,true,?,'fixture')",
        tenant,
        id,
        registration,
        now);
  }

  Map<String, Object> input() {
    return Map.of(
        "deviceIds",
        devices,
        "from",
        now - 3600000,
        "to",
        now - 1000,
        "timeZone",
        "UTC",
        "period",
        "DAY",
        "scope",
        Map.of("kind", "DEVICES"));
  }

  ResultActions create(String key, Map<String, Object> input) throws Exception {
    return mvc.perform(
        post(root)
            .with(actor(owner))
            .header("Idempotency-Key", key)
            .contentType(MediaType.APPLICATION_JSON)
            .content(json.writeValueAsBytes(input)));
  }

  String create() throws Exception {
    return body(create(UUID.randomUUID().toString(), input()).andExpect(status().isAccepted()))
        .path("id")
        .asText();
  }

  JsonNode job(String id) throws Exception {
    return body(mvc.perform(get(root + "/" + id).with(actor(owner))).andExpect(status().isOk()));
  }

  @Test
  void acceptsMoreThanSynchronousLimitAndReplaysCurrentState() throws Exception {
    String key = UUID.randomUUID().toString();
    var first = body(create(key, input()).andExpect(status().isAccepted()));
    assertThat(first.path("totalDevices").asInt()).isEqualTo(21);
    assertThat(first.path("completedDevices").asInt()).isZero();
    String id = first.path("id").asText();
    mvc.perform(post(root + "/" + id + "/cancel").with(actor(owner)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("CANCELLED"));
    create(key, input())
        .andExpect(status().isAccepted())
        .andExpect(jsonPath("$.id").value(id))
        .andExpect(jsonPath("$.state").value("CANCELLED"));
    var changed = new HashMap<>(input());
    changed.put("period", "WEEK");
    create(key, changed).andExpect(status().isConflict());
  }

  @Test
  void anotherMemberCannotReadOrCancelCreatorJob() throws Exception {
    String id = create();
    mvc.perform(get(root + "/" + id).with(actor("outsider"))).andExpect(status().isForbidden());
    mvc.perform(post(root + "/" + id + "/cancel").with(actor("outsider")))
        .andExpect(status().isForbidden());
    assertThat(job(id).path("state").asText()).isEqualTo("QUEUED");
  }

  @Test
  void rejectsDuplicateUnknownDeviceAndWeakAuthentication() throws Exception {
    var duplicate = new HashMap<>(input());
    duplicate.put("deviceIds", List.of(devices.get(0), devices.get(0)));
    create(UUID.randomUUID().toString(), duplicate).andExpect(status().isBadRequest());
    var foreign = new HashMap<>(input());
    foreign.put("deviceIds", List.of(UUID.randomUUID().toString()));
    create(UUID.randomUUID().toString(), foreign).andExpect(status().isForbidden());
    mvc.perform(
            post(root)
                .with(jwt().jwt(j -> j.subject(owner).claim("amr", List.of("pwd"))))
                .header("Idempotency-Key", UUID.randomUUID())
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(input())))
        .andExpect(status().isUnauthorized())
        .andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
  }
}
