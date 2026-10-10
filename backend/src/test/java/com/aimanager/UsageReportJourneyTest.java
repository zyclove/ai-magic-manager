package com.aimanager;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.*;
import java.time.*;
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
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "server.address=127.0.0.1",
      "spring.datasource.url=${USAGE_REPORT_TEST_DATABASE_URL:jdbc:h2:mem:usage-report;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${USAGE_REPORT_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${USAGE_REPORT_TEST_DATABASE_PASSWORD:}",
      "manager.exports.worker.enabled=false",
      "manager.reports.max-source-bytes=2048"
    })
@AutoConfigureMockMvc(
    print = org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint.NONE)
class UsageReportJourneyTest {
  @MockitoSpyBean com.aimanager.deviceidentity.DeviceCredentials deviceCredentials;

  com.aimanager.deviceidentity.DeviceCredentials.Issued reportDeviceCredential() {
    return transactions.execute(
        status -> {
          var issued = deviceCredentials.issuePending(tenant, device, registration);
          deviceCredentials.activate(tenant, registration);
          return issued;
        });
  }

  org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder deviceReport(
      String token) {
    return get("/api/v1/device-api/usage-report")
        .header("Authorization", "Bearer " + token)
        .param("from", "" + from)
        .param("to", "" + to)
        .param("timeZone", "UTC");
  }

  @Test
  void deviceReportUsesItsAuthenticatedScopeAndTheSameAggregationAndConfigurationEvidence()
      throws Exception {
    batch(1, 2000, now);
    publishReportConfiguration();
    var issued = reportDeviceCredential();
    var result =
        mvc.perform(deviceReport(issued.credential()))
            .andExpect(status().isOk())
            .andExpect(
                header().string("Cache-Control", org.hamcrest.Matchers.containsString("no-store")))
            .andExpect(jsonPath("$.scope.kind").value("DEVICES"))
            .andExpect(jsonPath("$.devices.length()").value(1))
            .andExpect(jsonPath("$.devices[0].deviceId").value(device))
            .andExpect(jsonPath("$.devices[0].registrationId").value(registration))
            .andExpect(jsonPath("$.devices[0].subjectId").value(subject))
            .andExpect(jsonPath("$.devices[0].applications[0].buckets[0].lowerMillis").value(2000))
            .andExpect(
                jsonPath("$.devices[0].configurationState.evidenceStatus")
                    .value("DELIVERY_ONLY_NOT_EXECUTION"));
    assertThat(body(result).path("devices").get(0).path("applications"))
        .isEqualTo(
            body(read(owner).andExpect(status().isOk()))
                .path("devices")
                .get(0)
                .path("applications"));
    assertThat(result.andReturn().getResponse().getContentAsString())
        .doesNotContain(issued.credential(), owner);
  }

  @Test
  void deviceReportRejectsScopeOverridesDuplicatesAndInvalidWindows() throws Exception {
    var token = reportDeviceCredential().credential();
    for (String parameter :
        List.of("deviceId", "tenantId", "scopeKind", "scopeId", "scopeVersion", "subjectId"))
      mvc.perform(deviceReport(token).param(parameter, UUID.randomUUID().toString()))
          .andExpect(status().isBadRequest());
    mvc.perform(deviceReport(token).param("from", "" + from)).andExpect(status().isBadRequest());
    mvc.perform(deviceReport(token).param("period", "MONTH")).andExpect(status().isBadRequest());
    mvc.perform(
            get("/api/v1/device-api/usage-report")
                .header("Authorization", "Bearer " + token)
                .param("from", "" + (to - 33L * 86400000))
                .param("to", "" + to)
                .param("timeZone", "UTC"))
        .andExpect(status().isBadRequest());
  }

  @Test
  void deviceReportPreservesNoDataAndWithdrawnConsentWithoutPrivateUsage() throws Exception {
    var token = reportDeviceCredential().credential();
    mvc.perform(deviceReport(token))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.devices[0].status").value("NO_DATA"));
    batch(1, 2000, now);
    db.update(
        "UPDATE device_observation_settings SET usage_enabled=false,version=version+1 WHERE"
            + " tenant_id=? AND device_id=?",
        tenant,
        device);
    mvc.perform(deviceReport(token))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.devices[0].status").value("NOT_AUTHORIZED"))
        .andExpect(jsonPath("$.devices[0].applications.length()").value(0));
  }

  @Test
  void deviceReportRejectsInactiveDeviceArchivedSubjectAndExpiredCredential() throws Exception {
    var issued = reportDeviceCredential();
    mvc.perform(deviceReport("not-a-device-credential")).andExpect(status().isUnauthorized());
    db.update("UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?", now, tenant, subject);
    mvc.perform(deviceReport(issued.credential())).andExpect(status().isForbidden());
    db.update("UPDATE subjects SET archived_at=NULL WHERE tenant_id=? AND id=?", tenant, subject);
    db.update("UPDATE devices SET state='REVOKED' WHERE tenant_id=? AND id=?", tenant, device);
    mvc.perform(deviceReport(issued.credential())).andExpect(status().isForbidden());
    db.update("UPDATE devices SET state='ACTIVE' WHERE tenant_id=? AND id=?", tenant, device);
    db.update(
        "UPDATE device_credentials SET expires_at=? WHERE id=?", now - 1, issued.credentialId());
    mvc.perform(deviceReport(issued.credential())).andExpect(status().isUnauthorized());
  }

  @Test
  void deviceReportRechecksCredentialAfterSecurityAuthentication() throws Exception {
    var issued = reportDeviceCredential();
    doAnswer(
            invocation -> {
              var authenticated = invocation.callRealMethod();
              db.update(
                  "UPDATE device_credential_scopes SET revoked_at=?,active=false WHERE tenant_id=?"
                      + " AND registration_id=?",
                  now,
                  tenant,
                  registration);
              return authenticated;
            })
        .when(deviceCredentials)
        .introspect(issued.credential());
    mvc.perform(deviceReport(issued.credential()))
        .andExpect(status().isUnauthorized())
        .andExpect(jsonPath("$.errorCode").value("DEVICE_CREDENTIAL_REVOKED"));
  }

  @Test
  void deviceReportRetainsCredentialLockThroughFinalSerialization() throws Exception {
    var issued = reportDeviceCredential();
    var copied = new CountDownLatch(1);
    var resume = new CountDownLatch(1);
    var started = new CountDownLatch(1);
    doAnswer(
            invocation -> {
              var result = invocation.callRealMethod();
              if (invocation
                  .getArgument(0)
                  .getClass()
                  .getName()
                  .equals("com.aimanager.reporting.internal.UsageReportService$Report")) {
                copied.countDown();
                assertThat(resume.await(5, TimeUnit.SECONDS)).isTrue();
              }
              return result;
            })
        .when(json)
        .writeValueAsBytes(any());
    var executor = Executors.newFixedThreadPool(2);
    try {
      var response =
          executor.submit(
              () -> mvc.perform(deviceReport(issued.credential())).andExpect(status().isOk()));
      assertThat(copied.await(5, TimeUnit.SECONDS)).isTrue();
      var revocation =
          executor.submit(
              () -> {
                started.countDown();
                return db.update(
                    "UPDATE device_credentials SET revoked_at=? WHERE id=?",
                    now,
                    issued.credentialId());
              });
      assertThat(started.await(2, TimeUnit.SECONDS)).isTrue();
      assertThatThrownBy(() -> revocation.get(150, TimeUnit.MILLISECONDS))
          .isInstanceOf(TimeoutException.class);
      resume.countDown();
      response.get(8, TimeUnit.SECONDS);
      assertThat(revocation.get(8, TimeUnit.SECONDS)).isEqualTo(1);
      mvc.perform(deviceReport(issued.credential())).andExpect(status().isUnauthorized());
    } finally {
      resume.countDown();
      executor.shutdownNow();
      executor.awaitTermination(5, TimeUnit.SECONDS);
    }
  }

  @Test
  void reportRetainsConfigurationHeadThroughFinalSerialization() throws Exception {
    publishReportConfiguration();
    var copied = new CountDownLatch(1);
    var resume = new CountDownLatch(1);
    var started = new CountDownLatch(1);
    doAnswer(
            invocation -> {
              var value = invocation.callRealMethod();
              if (invocation
                  .getArgument(0)
                  .getClass()
                  .getName()
                  .equals("com.aimanager.reporting.internal.UsageReportService$Report")) {
                copied.countDown();
                assertThat(resume.await(5, TimeUnit.SECONDS)).isTrue();
              }
              return value;
            })
        .when(json)
        .writeValueAsBytes(any());
    var executor = Executors.newFixedThreadPool(2);
    try {
      var response = executor.submit(() -> read(owner).andExpect(status().isOk()));
      assertThat(copied.await(5, TimeUnit.SECONDS)).isTrue();
      var mutation =
          executor.submit(
              () -> {
                started.countDown();
                return db.update(
                    "UPDATE configuration_device_heads SET next_cursor=next_cursor+1 WHERE"
                        + " tenant_id=? AND registration_id=?",
                    tenant,
                    registration);
              });
      assertThat(started.await(2, TimeUnit.SECONDS)).isTrue();
      assertThatThrownBy(() -> mutation.get(150, TimeUnit.MILLISECONDS))
          .isInstanceOf(TimeoutException.class);
      resume.countDown();
      response.get(8, TimeUnit.SECONDS);
      assertThat(mutation.get(8, TimeUnit.SECONDS)).isEqualTo(1);
    } finally {
      resume.countDown();
      executor.shutdownNow();
      executor.awaitTermination(5, TimeUnit.SECONDS);
    }
  }

  @Test
  void reportIncludesCurrentConfigurationEvidenceSeparatelyFromHistoricalUsage() throws Exception {
    publishReportConfiguration();
    var response =
        read(owner)
            .andExpect(status().isOk())
            .andExpect(
                jsonPath("$.devices[0].configurationState.evidenceStatus")
                    .value("DELIVERY_ONLY_NOT_EXECUTION"))
            .andExpect(
                jsonPath("$.devices[0].configurationState.configurations[0].name")
                    .value("Report reminder"))
            .andExpect(
                jsonPath(
                        "$.devices[0].configurationState.configurations[0].rules[0].predictedEffect")
                    .value("REMIND"));
    var report = body(response);
    assertThat(report.path("devices").get(0).path("configurationState").path("checkedAt").asLong())
        .isGreaterThan(report.path("to").asLong());
    assertThat(response.andReturn().getResponse().getContentAsString())
        .doesNotContain("compactJws", "effectiveEffect");
  }

  @Autowired com.aimanager.delivery.ReportConfigurationSource configurationSource;
  @Autowired com.aimanager.observation.UsageReportSource observationSource;

  @Test
  void configurationSourceUsesCurrentReadsAfterAnEarlierTransactionSnapshot() throws Exception {
    String id = publishReportConfiguration();
    var executor = Executors.newSingleThreadExecutor();
    try {
      transactions.executeWithoutResult(
          status -> {
            String old =
                db.queryForObject(
                    "SELECT document_json FROM configuration_deliveries WHERE tenant_id=? AND id=?",
                    String.class,
                    tenant,
                    id);
            try {
              executor
                  .submit(
                      () ->
                          transactions.executeWithoutResult(
                              write -> {
                                db.queryForList(
                                    "SELECT device_id FROM configuration_device_heads WHERE"
                                        + " tenant_id=? AND registration_id=? FOR UPDATE",
                                    tenant,
                                    registration);
                                db.update(
                                    "UPDATE configuration_deliveries SET document_json=? WHERE"
                                        + " tenant_id=? AND id=?",
                                    old.replace("Report reminder", "Current reminder"),
                                    tenant,
                                    id);
                              }))
                  .get(5, TimeUnit.SECONDS);
            } catch (Exception failure) {
              throw new AssertionError(failure);
            }
            var snapshot = observationSource.read(tenant, owner, List.of(device), from);
            var state =
                configurationSource
                    .forAuthorizedReport(
                        tenant,
                        snapshot.devices().stream()
                            .map(com.aimanager.observation.UsageReportSource.DeviceData::device)
                            .toList())
                    .get(device);
            assertThat(state.configurations().get(0).name()).isEqualTo("Current reminder");
          });
    } finally {
      executor.shutdownNow();
      executor.awaitTermination(5, TimeUnit.SECONDS);
    }
  }

  @Test
  void configurationSourceRetainsDeliveryHeadLockUntilCallerTransactionEnds() throws Exception {
    publishReportConfiguration();
    var returned = new CountDownLatch(1);
    var resume = new CountDownLatch(1);
    var started = new CountDownLatch(1);
    var executor = Executors.newFixedThreadPool(2);
    try {
      var reading =
          executor.submit(
              () ->
                  transactions.executeWithoutResult(
                      status -> {
                        assertThat(configurationState(owner).configurations()).hasSize(1);
                        returned.countDown();
                        try {
                          assertThat(resume.await(5, TimeUnit.SECONDS)).isTrue();
                        } catch (InterruptedException failure) {
                          Thread.currentThread().interrupt();
                          throw new AssertionError(failure);
                        }
                      }));
      assertThat(returned.await(5, TimeUnit.SECONDS)).isTrue();
      var mutation =
          executor.submit(
              () -> {
                started.countDown();
                return db.update(
                    "UPDATE configuration_device_heads SET next_cursor=next_cursor+1 WHERE"
                        + " tenant_id=? AND registration_id=?",
                    tenant,
                    registration);
              });
      assertThat(started.await(2, TimeUnit.SECONDS)).isTrue();
      assertThatThrownBy(() -> mutation.get(150, TimeUnit.MILLISECONDS))
          .isInstanceOf(TimeoutException.class);
      resume.countDown();
      reading.get(8, TimeUnit.SECONDS);
      assertThat(mutation.get(8, TimeUnit.SECONDS)).isEqualTo(1);
    } finally {
      resume.countDown();
      executor.shutdownNow();
      executor.awaitTermination(5, TimeUnit.SECONDS);
    }
  }

  @Test
  void configurationSourceDoesNotReusePreviousRegistrationOrBypassChildOwnership()
      throws Exception {
    publishReportConfiguration();
    String child = "rules-child-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'CHILD',?)",
        tenant,
        child,
        ActorKeys.key(child),
        subject);
    assertThat(configurationState(child).configurations()).hasSize(1);
    String nextRegistration = UUID.randomUUID().toString();
    db.update(
        "DELETE FROM device_observation_settings WHERE tenant_id=? AND device_id=?",
        tenant,
        device);
    db.update(
        "UPDATE devices SET registration_id=? WHERE tenant_id=? AND id=?",
        nextRegistration,
        tenant,
        device);
    db.update(
        "INSERT INTO"
            + " device_observation_settings(tenant_id,device_id,registration_id,version,inventory_enabled,usage_enabled,updated_at,last_reason)"
            + " VALUES(?,?,?,1,false,true,?,'new registration fixture')",
        tenant,
        device,
        nextRegistration,
        now);
    assertThat(configurationState(child).configurations()).isEmpty();
    db.update(
        "UPDATE tenant_members SET role='TEACHER' WHERE tenant_id=? AND actor_key=?",
        tenant,
        ActorKeys.key(child));
    assertThatThrownBy(() -> configurationState(child))
        .isInstanceOf(com.aimanager.shared.DomainException.class);
  }

  @Test
  void configurationSourceRejectsMoreThanOneHundredCurrentConfigurations() throws Exception {
    String original = publishReportConfiguration();
    for (int index = 0; index < 100; index++) {
      String id = UUID.randomUUID().toString(), policy = UUID.randomUUID().toString();
      // Capacity fixture: reuse immutable version/publication parents without creating 100
      // policies.
      db.update(
          "INSERT INTO"
              + " configuration_deliveries(tenant_id,id,publication_id,version_id,policy_id,registration_id,device_id,source_sequence,device_cursor,action,document_json,issued_at,delivery_expires_at,state)"
              + " SELECT"
              + " tenant_id,?,publication_id,version_id,?,registration_id,device_id,source_sequence,device_cursor,action,document_json,issued_at,delivery_expires_at,state"
              + " FROM configuration_deliveries WHERE tenant_id=? AND id=?",
          id,
          policy,
          tenant,
          original);
      db.update(
          "INSERT INTO configuration_streams(tenant_id,registration_id,policy_id,delivery_id)"
              + " VALUES(?,?,?,?)",
          tenant,
          registration,
          policy,
          id);
    }
    assertThatThrownBy(() -> configurationState(owner))
        .hasMessageContaining("USAGE_REPORT_TOO_LARGE");
  }

  com.aimanager.delivery.ReportConfigurationSource.State configurationState(String who) {
    return transactions.execute(
        status -> {
          var snapshot = observationSource.read(tenant, who, List.of(device), from);
          return configurationSource
              .forAuthorizedReport(
                  tenant,
                  snapshot.devices().stream()
                      .map(com.aimanager.observation.UsageReportSource.DeviceData::device)
                      .toList())
              .get(device);
        });
  }

  String publishReportConfiguration() throws Exception {
    String policies = "/api/v1/tenants/" + tenant + "/policies";
    String id =
        body(mvc.perform(
                    post(policies)
                        .with(actor(owner))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            "{\"name\":\"Report"
                                + " reminder\",\"kind\":\"POLICY\",\"rules\":[{\"id\":\"break\",\"kind\":\"USAGE_REMINDER\",\"effect\":\"REMIND\",\"required\":false,\"seconds\":900}]}"))
                .andExpect(status().isCreated()))
            .path("id")
            .asText();
    var preview =
        body(
            mvc.perform(
                    post(policies + "/" + id + "/previews")
                        .with(actor(owner))
                        .header("If-Match", "\"0\"")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("deviceIds", List.of(device)))))
                .andExpect(status().isCreated()));
    mvc.perform(
            post(policies + "/" + id + "/publications")
                .with(actor(owner))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", UUID.randomUUID().toString())
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    json.writeValueAsString(
                        Map.of(
                            "previewId",
                            preview.path("id").asText(),
                            "previewHash",
                            preview.path("hash").asText(),
                            "mode",
                            "CONFIGURE_ONLY"))))
        .andExpect(status().isCreated());
    return db.queryForObject(
        "SELECT delivery_id FROM configuration_streams WHERE tenant_id=? AND registration_id=? AND"
            + " policy_id=?",
        String.class,
        tenant,
        registration,
        id);
  }

  @Test
  void configurationSourceIsReadOnlyAndRequiresTheExistingReportAuthorization() throws Exception {
    assertThat(configurationState(owner).configurations()).isEmpty();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM configuration_device_heads WHERE tenant_id=?",
                Integer.class,
                tenant))
        .isZero();
    publishReportConfiguration();
    assertThatThrownBy(() -> configurationState("outsider"))
        .isInstanceOf(com.aimanager.shared.DomainException.class);
    var current = configurationState(owner);
    assertThat(current.evidenceStatus()).isEqualTo("DELIVERY_ONLY_NOT_EXECUTION");
    assertThat(current.checkedAt()).isGreaterThanOrEqualTo(now);
    assertThat(current.configurations()).hasSize(1);
    var item = current.configurations().get(0);
    assertThat(item.deliveryState()).isEqualTo("PENDING_SIGNATURE");
    assertThat(item.name()).isEqualTo("Report reminder");
    assertThat(item.rules().get(0).kind()).isEqualTo("USAGE_REMINDER");
    assertThat(item.rules().get(0).predictedEffect()).isEqualTo("REMIND");
    assertThat(item.rules().get(0).seconds()).isEqualTo(900L);
    assertThat(json.writeValueAsString(current))
        .doesNotContain("compactJws", "signingDigests", "effectiveEffect", owner);
    assertThatThrownBy(() -> current.configurations().clear())
        .isInstanceOf(UnsupportedOperationException.class);
  }

  @Test
  void configurationSourceDistinguishesExpiredTransportStoredReceiptsAndRemoval() throws Exception {
    String id = publishReportConfiguration();
    db.update(
        "UPDATE configuration_deliveries SET delivery_expires_at=? WHERE tenant_id=? AND id=?",
        now - 1,
        tenant,
        id);
    assertThat(configurationState(owner).configurations().get(0).deliveryState())
        .isEqualTo("EXPIRED_AWAITING_PULL");
    db.update(
        "UPDATE configuration_deliveries SET"
            + " state='DEVICE_REPORTED_STORED',received_reported_at=?,stored_reported_at=? WHERE"
            + " tenant_id=? AND id=?",
        now,
        now,
        tenant,
        id);
    assertThat(configurationState(owner).configurations().get(0).deliveryState())
        .isEqualTo("DEVICE_REPORTED_STORED");
    db.update(
        "UPDATE configuration_deliveries SET action='REMOVE_CONFIGURATION',document_json=NULL WHERE"
            + " tenant_id=? AND id=?",
        tenant,
        id);
    var removed = configurationState(owner).configurations().get(0);
    assertThat(removed.action()).isEqualTo("REMOVE_CONFIGURATION");
    assertThat(removed.rules()).isEmpty();
    assertThat(removed.name()).isNull();
  }

  @Test
  void configurationSourceRejectsOversizeMalformedAndMisboundCurrentDocuments() throws Exception {
    String id = publishReportConfiguration();
    String original =
        db.queryForObject(
            "SELECT document_json FROM configuration_deliveries WHERE tenant_id=? AND id=?",
            String.class,
            tenant,
            id);
    db.update(
        "UPDATE configuration_deliveries SET document_json=? WHERE tenant_id=? AND id=?",
        " ".repeat(2 * 1024 * 1024 + 1),
        tenant,
        id);
    assertThatThrownBy(() -> configurationState(owner))
        .hasMessageContaining("USAGE_REPORT_TOO_LARGE");
    db.update(
        "UPDATE configuration_deliveries SET document_json='{}' WHERE tenant_id=? AND id=?",
        tenant,
        id);
    assertThatThrownBy(() -> configurationState(owner))
        .hasMessageContaining("USAGE_REPORT_DATA_UNAVAILABLE");
    db.update(
        "UPDATE configuration_deliveries SET document_json=?,device_id=? WHERE tenant_id=? AND"
            + " id=?",
        original,
        UUID.randomUUID().toString(),
        tenant,
        id);
    assertThatThrownBy(() -> configurationState(owner))
        .hasMessageContaining("USAGE_REPORT_DATA_UNAVAILABLE");
  }

  @Test
  void reportsAttachCurrentDeclaredCategoriesWithoutExposingUnobservedDirectoryEntries()
      throws Exception {
    batch(1, 2000, now);
    read(owner)
        .andExpect(status().isOk())
        .andExpect(
            jsonPath("$.devices[0].applications[0].classification.category").value("UNCLASSIFIED"))
        .andExpect(jsonPath("$.devices[0].applications[0].classification.source").value("NONE"));
    String catalogRoot = "/api/v1/tenants/" + tenant + "/applications";
    for (String name : List.of("org.example.reader", "org.private.unobserved")) {
      String id =
          body(mvc.perform(
                      post(catalogRoot)
                          .with(actor(owner))
                          .contentType(MediaType.APPLICATION_JSON)
                          .content(
                              json.writeValueAsString(
                                  Map.of(
                                      "displayName",
                                      "Catalog label",
                                      "platform",
                                      "ANDROID",
                                      "profile",
                                      "PRIMARY",
                                      "packageName",
                                      name,
                                      "signingDigests",
                                      List.of()))))
                  .andExpect(status().isCreated()))
              .path("id")
              .asText();
      mvc.perform(
              put(catalogRoot + "/" + id + "/classification")
                  .with(actor(owner))
                  .header("If-Match", "\"0\"")
                  .contentType(MediaType.APPLICATION_JSON)
                  .content("{\"category\":\"EDUCATION\"}"))
          .andExpect(status().isOk());
    }
    String child = "classified-child-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'CHILD',?)",
        tenant,
        child,
        ActorKeys.key(child),
        subject);
    var result =
        read(child)
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.devices[0].applications.length()").value(1))
            .andExpect(
                jsonPath("$.devices[0].applications[0].classification.category").value("EDUCATION"))
            .andExpect(
                jsonPath("$.devices[0].applications[0].classification.source")
                    .value("ADMIN_DECLARED"))
            .andExpect(jsonPath("$.devices[0].applications[0].classification.version").value(1));
    assertThat(result.andReturn().getResponse().getContentAsString())
        .doesNotContain("org.private.unobserved", owner);
    mvc.perform(get(catalogRoot).with(actor(child))).andExpect(status().isForbidden());
  }

  @org.springframework.boot.test.web.server.LocalServerPort int port;

  @Test
  @org.junit.jupiter.api.condition.EnabledIfSystemProperty(
      named = "device.dart.command",
      matches = ".+")
  void realHttpResponseIsConsumedByProductionDartReportClient() throws Exception {
    publishReportConfiguration();
    var deviceCredential = reportDeviceCredential();
    String classId = classroom();
    batch(1, 2000, now);
    String applicationId =
        body(mvc.perform(
                    post("/api/v1/tenants/" + tenant + "/applications")
                        .with(actor(owner))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            json.writeValueAsString(
                                Map.of(
                                    "displayName",
                                    "HTTP reader",
                                    "platform",
                                    "ANDROID",
                                    "profile",
                                    "PRIMARY",
                                    "packageName",
                                    "org.example.reader",
                                    "signingDigests",
                                    List.of()))))
                .andExpect(status().isCreated()))
            .path("id")
            .asText();
    String child = "report-http-child-" + UUID.randomUUID(),
        ownerToken = UUID.randomUUID().toString(),
        childToken = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'CHILD',?)",
        tenant,
        child,
        ActorKeys.key(child),
        subject);
    when(decoder.decode(anyString()))
        .thenAnswer(
            call -> {
              String token = call.getArgument(0), identity;
              if (token.equals(ownerToken)) identity = owner;
              else if (token.equals(childToken)) identity = child;
              else
                throw new org.springframework.security.oauth2.jwt.BadJwtException(
                    "Unknown report fixture");
              return org.springframework.security.oauth2.jwt.Jwt.withTokenValue(token)
                  .header("alg", "fixture")
                  .subject(identity)
                  .issuedAt(Instant.now())
                  .expiresAt(Instant.now().plusSeconds(300))
                  .build();
            });
    var directory =
        java.nio.file.Files.createTempDirectory(
            java.nio.file.Files.createDirectories(java.nio.file.Path.of(".local").toAbsolutePath()),
            "usage-report-http-");
    var fixture = directory.resolve("fixture.json");
    var output = directory.resolve("client.log");
    var values = new LinkedHashMap<String, Object>();
    values.put("testOnly", true);
    values.put("apiRoot", "http://127.0.0.1:" + port + "/api/v1");
    values.put("tenantId", tenant);
    values.put("deviceId", device);
    values.put("registrationId", registration);
    values.put("subjectId", subject);
    values.put("classId", classId);
    values.put("applicationId", applicationId);
    values.put("ownerToken", ownerToken);
    values.put("childToken", childToken);
    values.put("deviceToken", deviceCredential.credential());
    values.put("from", from);
    values.put("to", to);
    json.writeValue(fixture.toFile(), values);
    try {
      var process =
          new ProcessBuilder(
                  System.getProperty("device.dart.command"),
                  "run",
                  "tool/verify_usage_report_fixture.dart",
                  fixture.toString())
              .directory(
                  java.nio.file.Path.of(
                          System.getProperty("usage.report.guardian.package", "../apps/guardian"))
                      .toAbsolutePath()
                      .toFile())
              .redirectErrorStream(true)
              .redirectOutput(output.toFile())
              .start();
      if (!process.waitFor(45, TimeUnit.SECONDS)) {
        process.destroyForcibly();
        throw new AssertionError("Report client deadline exceeded");
      }
      assertThat(process.exitValue()).as("Report client diagnostics: %s", output).isZero();
      assertThat(java.nio.file.Files.readString(output)).contains("PASS usage report HTTP");
      runDeviceReportClient(
          fixture, directory.resolve("device-client.log"), "PASS device usage report HTTP");
      runChildReportClient(
          fixture, directory.resolve("child-client.log"), "PASS child device report HTTP");
      db.update(
          "UPDATE device_credentials SET revoked_at=? WHERE id=?",
          Instant.now().toEpochMilli(),
          deviceCredential.credentialId());
      values.put("deviceExpectedStatus", 401);
      json.writeValue(fixture.toFile(), values);
      runDeviceReportClient(
          fixture,
          directory.resolve("device-revoked-client.log"),
          "PASS device usage report revoked HTTP");
      runChildReportClient(
          fixture,
          directory.resolve("child-revoked-client.log"),
          "PASS child device report revoked HTTP");
    } finally {
      java.nio.file.Files.deleteIfExists(fixture);
    }
  }

  private void runDeviceReportClient(
      java.nio.file.Path fixture, java.nio.file.Path output, String marker) throws Exception {
    var process =
        new ProcessBuilder(
                System.getProperty("device.dart.command"),
                "run",
                "tool/verify_usage_report_http.dart",
                fixture.toString())
            .directory(
                java.nio.file.Path.of(
                        System.getProperty(
                            "usage.report.device.package", "../packages/device_reports"))
                    .toAbsolutePath()
                    .toFile())
            .redirectErrorStream(true)
            .redirectOutput(output.toFile())
            .start();
    if (!process.waitFor(45, TimeUnit.SECONDS)) {
      process.destroyForcibly();
      throw new AssertionError("Device report client deadline exceeded");
    }
    assertThat(process.exitValue()).as("Device report client diagnostics: %s", output).isZero();
    assertThat(java.nio.file.Files.readString(output)).contains(marker);
  }

  private void runChildReportClient(
      java.nio.file.Path fixture, java.nio.file.Path output, String marker) throws Exception {
    String flutter = System.getProperty("device.flutter.command");
    assertThat(flutter).as("Child report acceptance requires device.flutter.command").isNotBlank();
    var builder =
        new ProcessBuilder(flutter, "test", "tool/report_http_session_test.dart", "--concurrency=1")
            .directory(
                java.nio.file.Path.of(System.getProperty("device.child.package", "../apps/child"))
                    .toAbsolutePath()
                    .toFile())
            .redirectErrorStream(true)
            .redirectOutput(output.toFile());
    builder.environment().put("CHILD_REPORT_HTTP_FIXTURE", fixture.toString());
    var process = builder.start();
    if (!process.waitFor(60, TimeUnit.SECONDS)) {
      process.destroyForcibly();
      throw new AssertionError("Child report UI deadline exceeded");
    }
    assertThat(process.exitValue()).as("Child report diagnostics: %s", output).isZero();
    assertThat(java.nio.file.Files.readString(output)).contains(marker);
  }

  @Autowired org.springframework.transaction.support.TransactionTemplate transactions;
  @Autowired com.aimanager.tenant.OrganizationRoster reportRoster;

  @Test
  void rosterReadSeesCommittedChangesEvenAfterSnapshotStarted() throws Exception {
    String id = classroom();
    var executor = Executors.newSingleThreadExecutor();
    try {
      transactions.executeWithoutResult(
          status -> {
            assertThat(
                    db.queryForObject(
                        "SELECT COUNT(*) FROM organization_class_students WHERE tenant_id=? AND"
                            + " class_id=?",
                        Integer.class,
                        tenant,
                        id))
                .isEqualTo(1);
            try {
              executor
                  .submit(
                      () ->
                          transactions.executeWithoutResult(
                              write -> {
                                db.update(
                                    "UPDATE organization_classes SET version=1 WHERE tenant_id=?"
                                        + " AND id=?",
                                    tenant,
                                    id);
                                db.update(
                                    "DELETE FROM organization_class_students WHERE tenant_id=? AND"
                                        + " class_id=?",
                                    tenant,
                                    id);
                              }))
                  .get(5, TimeUnit.SECONDS);
            } catch (Exception failure) {
              throw new AssertionError(failure);
            }
            assertThat(reportRoster.lockForPrivateReport(tenant, owner, id, 1).subjectIds())
                .isEmpty();
          });
    } finally {
      executor.shutdownNow();
      executor.awaitTermination(5, TimeUnit.SECONDS);
    }
  }

  @Test
  void classVersionRemainsLockedThroughReportSerialization() throws Exception {
    String id = classroom();
    batch(1, 2000, now);
    var copied = new CountDownLatch(1);
    var resume = new CountDownLatch(1);
    var changed = new CountDownLatch(1);
    doAnswer(
            invocation -> {
              var result = invocation.callRealMethod();
              if (invocation
                  .getArgument(0)
                  .getClass()
                  .getName()
                  .equals("com.aimanager.reporting.internal.UsageReportService$Report")) {
                copied.countDown();
                assertThat(resume.await(5, TimeUnit.SECONDS)).isTrue();
              }
              return result;
            })
        .when(json)
        .writeValueAsBytes(any());
    var executor = Executors.newFixedThreadPool(2);
    try {
      var report =
          executor.submit(() -> scoped(owner, "CLASS", id, "0").andExpect(status().isOk()));
      assertThat(copied.await(5, TimeUnit.SECONDS)).isTrue();
      var mutation =
          executor.submit(
              () -> {
                changed.countDown();
                return db.update(
                    "UPDATE organization_classes SET version=1 WHERE tenant_id=? AND id=?",
                    tenant,
                    id);
              });
      assertThat(changed.await(2, TimeUnit.SECONDS)).isTrue();
      assertThatThrownBy(() -> mutation.get(150, TimeUnit.MILLISECONDS))
          .isInstanceOf(TimeoutException.class);
      resume.countDown();
      report.get(8, TimeUnit.SECONDS);
      assertThat(mutation.get(8, TimeUnit.SECONDS)).isEqualTo(1);
      scoped(owner, "CLASS", id, "0").andExpect(status().isConflict());
    } finally {
      resume.countDown();
      executor.shutdownNow();
      executor.awaitTermination(5, TimeUnit.SECONDS);
    }
  }

  ResultActions scoped(String who, String kind, String id, String version) throws Exception {
    var request =
        get(root)
            .with(actor(who))
            .param("deviceId", device)
            .param("from", "" + from)
            .param("to", "" + to)
            .param("timeZone", "UTC")
            .param("scopeKind", kind);
    if (id != null) request.param("scopeId", id);
    if (version != null) request.param("scopeVersion", version);
    return mvc.perform(request);
  }

  String classroom() {
    db.update("UPDATE tenants SET kind='ORGANIZATION' WHERE id=?", tenant);
    String id = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO organization_classes(tenant_id,id,name,created_at,updated_at)"
            + " VALUES(?,?,'Class',?,?)",
        tenant,
        id,
        now,
        now);
    db.update(
        "INSERT INTO organization_class_students(tenant_id,class_id,subject_id,added_at)"
            + " VALUES(?,?,?,?)",
        tenant,
        id,
        subject,
        now);
    return id;
  }

  @Test
  void subjectScopeChecksCurrentBindingAndArchivedProfiles() throws Exception {
    var value = body(scoped(owner, "SUBJECT", subject, null).andExpect(status().isOk()));
    assertThat(value.path("scope").path("kind").asText()).isEqualTo("SUBJECT");
    assertThat(value.path("scope").path("id").asText()).isEqualTo(subject);
    scoped(owner, "SUBJECT", UUID.randomUUID().toString(), null).andExpect(status().isConflict());
    db.update("UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?", now, tenant, subject);
    scoped(owner, "SUBJECT", subject, null).andExpect(status().isForbidden());
  }

  ResultActions defaultDeviceScope(String who) throws Exception {
    return mvc.perform(
        get(root)
            .with(actor(who))
            .param("deviceId", device)
            .param("from", "" + from)
            .param("to", "" + to)
            .param("timeZone", "UTC"));
  }

  @Test
  void defaultDeviceScopeRejectsArchivedSubjectForOwnerAndChild() throws Exception {
    String child = "archived-report-child-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'CHILD',?)",
        tenant,
        child,
        ActorKeys.key(child),
        subject);
    batch(1, 2000, now);
    defaultDeviceScope(owner).andExpect(status().isOk());
    defaultDeviceScope(child).andExpect(status().isOk());
    db.update("UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?", now, tenant, subject);
    defaultDeviceScope(owner).andExpect(status().isForbidden());
    defaultDeviceScope(child).andExpect(status().isForbidden());
  }

  @Test
  void defaultDeviceScopeLocksSubjectThroughReportSerialization() throws Exception {
    batch(1, 2000, now);
    var copied = new CountDownLatch(1);
    var resume = new CountDownLatch(1);
    var changed = new CountDownLatch(1);
    doAnswer(
            invocation -> {
              var result = invocation.callRealMethod();
              if (invocation
                  .getArgument(0)
                  .getClass()
                  .getName()
                  .equals("com.aimanager.reporting.internal.UsageReportService$Report")) {
                copied.countDown();
                assertThat(resume.await(5, TimeUnit.SECONDS)).isTrue();
              }
              return result;
            })
        .when(json)
        .writeValueAsBytes(any());
    var executor = Executors.newFixedThreadPool(2);
    try {
      var report = executor.submit(() -> defaultDeviceScope(owner).andExpect(status().isOk()));
      assertThat(copied.await(5, TimeUnit.SECONDS)).isTrue();
      var mutation =
          executor.submit(
              () -> {
                changed.countDown();
                return db.update(
                    "UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?",
                    now,
                    tenant,
                    subject);
              });
      assertThat(changed.await(2, TimeUnit.SECONDS)).isTrue();
      assertThatThrownBy(() -> mutation.get(150, TimeUnit.MILLISECONDS))
          .isInstanceOf(TimeoutException.class);
      resume.countDown();
      report.get(8, TimeUnit.SECONDS);
      assertThat(mutation.get(8, TimeUnit.SECONDS)).isEqualTo(1);
      defaultDeviceScope(owner).andExpect(status().isForbidden());
    } finally {
      resume.countDown();
      executor.shutdownNow();
      executor.awaitTermination(5, TimeUnit.SECONDS);
    }
  }

  @Test
  void classScopeBindsRosterVersionAndRejectsRemovedStudents() throws Exception {
    String id = classroom();
    scoped(owner, "CLASS", id, "0")
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.scope.version").value(0));
    db.update("UPDATE organization_classes SET version=1 WHERE tenant_id=? AND id=?", tenant, id);
    scoped(owner, "CLASS", id, "0")
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("REPORT_SCOPE_CHANGED"));
    db.update(
        "DELETE FROM organization_class_students WHERE tenant_id=? AND class_id=?", tenant, id);
    scoped(owner, "CLASS", id, "1").andExpect(status().isConflict());
  }

  @Test
  void classScopeDoesNotGrantPrivateUsageToTeachersChildrenOrForeignClasses() throws Exception {
    String id = classroom(), child = "scope-child-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'CHILD',?)",
        tenant,
        child,
        ActorKeys.key(child),
        subject);
    scoped(child, "SUBJECT", subject, null).andExpect(status().isOk());
    scoped(child, "CLASS", id, "0").andExpect(status().isForbidden());
    db.update(
        "UPDATE tenant_members SET role='TEACHER' WHERE tenant_id=? AND actor_key=?",
        tenant,
        ActorKeys.key(child));
    scoped(child, "CLASS", id, "0").andExpect(status().isForbidden());
    scoped(owner, "CLASS", UUID.randomUUID().toString(), "0").andExpect(status().isForbidden());
    db.update(
        "UPDATE organization_classes SET archived_at=? WHERE tenant_id=? AND id=?",
        now,
        tenant,
        id);
    scoped(owner, "CLASS", id, "0").andExpect(status().isConflict());
  }

  @Test
  void ambiguousOrIncompleteScopeSelectionIsRejected() throws Exception {
    scoped(owner, "CLASS", UUID.randomUUID().toString(), null).andExpect(status().isBadRequest());
    scoped(owner, "DEVICES", subject, null).andExpect(status().isBadRequest());
    scoped(owner, "SUBJECT", subject, "0").andExpect(status().isBadRequest());
    scoped(owner, "UNKNOWN", null, null).andExpect(status().isBadRequest());
  }

  @Autowired MockMvc mvc;
  @MockitoSpyBean ObjectMapper json;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;
  String owner, tenant, subject, device, registration, root;
  long now, from, to;

  RequestPostProcessor actor(String name) {
    return jwt()
        .jwt(
            j ->
                j.subject(name)
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  JsonNode body(ResultActions response) throws Exception {
    return json.readTree(response.andReturn().getResponse().getContentAsString());
  }

  @BeforeEach
  void setup() throws Exception {
    now = System.currentTimeMillis();
    to =
        Instant.ofEpochMilli(now)
            .atZone(ZoneOffset.UTC)
            .toLocalDate()
            .minusDays(1)
            .atTime(12, 0)
            .toInstant(ZoneOffset.UTC)
            .toEpochMilli();
    from = to - 3600000;
    owner = "report-owner-" + UUID.randomUUID();
    tenant =
        body(mvc.perform(
                    post("/api/v1/tenants")
                        .with(actor(owner))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"name\":\"Reports\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
                .andExpect(status().isCreated()))
            .path("id")
            .asText();
    subject = UUID.randomUUID().toString();
    device = UUID.randomUUID().toString();
    registration = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'Child','AGE_7_12',?)",
        tenant,
        subject,
        now);
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'Report device','ANDROID','14','ACTIVE','{}','fixture',?)",
        tenant,
        device,
        subject,
        registration,
        now);
    db.update(
        "INSERT INTO"
            + " device_observation_settings(tenant_id,device_id,registration_id,version,inventory_enabled,usage_enabled,updated_at,last_reason)"
            + " VALUES(?,?,?,1,false,true,?,'fixture')",
        tenant,
        device,
        registration,
        now);
    root = "/api/v1/tenants/" + tenant + "/usage-reports";
  }

  void batch(int seq, long used, long received) throws Exception {
    var payload =
        Map.of(
            "reportId",
            UUID.randomUUID().toString(),
            "sequence",
            seq,
            "authorizationVersion",
            1,
            "source",
            "ANDROID_USAGE_STATS",
            "profile",
            "PRIMARY",
            "queryStart",
            from,
            "queryEnd",
            to,
            "observedAt",
            to,
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
                    from,
                    "lastTimeStamp",
                    to,
                    "foregroundMillis",
                    used)));
    db.update(
        "INSERT INTO"
            + " usage_observation_batches(tenant_id,device_id,registration_id,sequence_number,report_id,authorization_version,payload_json,received_at)"
            + " VALUES(?,?,?,?,?,1,?,?)",
        tenant,
        device,
        registration,
        seq,
        payload.get("reportId"),
        json.writeValueAsString(payload),
        received);
  }

  ResultActions read(String who) throws Exception {
    return mvc.perform(
        get(root)
            .with(actor(who))
            .param("deviceId", device)
            .param("from", "" + from)
            .param("to", "" + to)
            .param("timeZone", "UTC")
            .param("period", "DAY"));
  }

  @Test
  void authorizedReportUsesLatestIntervalAndDisclosesUnverifiedEvidence() throws Exception {
    batch(1, 1000, now - 500);
    batch(2, 2000, now);
    var v =
        body(
            read(owner)
                .andExpect(status().isOk())
                .andExpect(header().string("Cache-Control", "no-store")));
    assertThat(v.path("precision").asText()).isEqualTo("OS_AGGREGATE");
    assertThat(v.path("evidenceStatus").asText()).isEqualTo("AGENT_REPORTED_UNVERIFIED");
    var d = v.path("devices").get(0);
    assertThat(d.path("deviceId").asText()).isEqualTo(device);
    assertThat(d.path("sourceBatchCount").asInt()).isEqualTo(2);
    assertThat(d.path("queryCoverageMillis").asLong()).isEqualTo(to - from);
    assertThat(d.path("applications").get(0).path("buckets").get(0).path("lowerMillis").asLong())
        .isEqualTo(2000);
    assertThat(v.toString()).doesNotContain(owner, "public_key_jwk", "last_reason");
  }

  @Test
  void noDataAndConsentOffAreDistinctAndNeverImplicitZero() throws Exception {
    var empty = body(read(owner).andExpect(status().isOk())).path("devices").get(0);
    assertThat(empty.path("status").asText()).isEqualTo("NO_DATA");
    assertThat(empty.path("applications").size()).isZero();
    batch(1, 2000, now);
    db.update(
        "UPDATE device_observation_settings SET usage_enabled=false,version=version+1 WHERE"
            + " tenant_id=? AND device_id=?",
        tenant,
        device);
    var off = body(read(owner).andExpect(status().isOk())).path("devices").get(0);
    assertThat(off.path("status").asText()).isEqualTo("NOT_AUTHORIZED");
    assertThat(off.path("sourceBatchCount").asInt()).isZero();
    assertThat(off.path("applications").size()).isZero();
  }

  @Test
  void childCanOnlyReadOwnDeviceAndTeachersAuditorsCannotReadPrivateUsage() throws Exception {
    String child = "child-" + UUID.randomUUID();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'CHILD',?)",
        tenant,
        child,
        ActorKeys.key(child),
        subject);
    read(child).andExpect(status().isOk());
    String other = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'Other','AGE_7_12',?)",
        tenant,
        other,
        now);
    db.update(
        "UPDATE tenant_members SET subject_id=? WHERE tenant_id=? AND actor_key=?",
        other,
        tenant,
        ActorKeys.key(child));
    read(child).andExpect(status().isForbidden());
    for (String role : List.of("TEACHER", "AUDITOR")) {
      db.update(
          "UPDATE tenant_members SET role=? WHERE tenant_id=? AND actor_key=?",
          role,
          tenant,
          ActorKeys.key(child));
      read(child).andExpect(status().isForbidden());
    }
  }

  @Test
  void currentMembershipAndDeviceLifecycleAreRechecked() throws Exception {
    read("outsider").andExpect(status().isForbidden());
    db.update("UPDATE devices SET state='REVOKED' WHERE tenant_id=? AND id=?", tenant, device);
    read(owner).andExpect(status().isConflict());
    db.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", tenant);
    read(owner).andExpect(status().isForbidden());
  }

  @Test
  void retentionDoesNotExposeExpiredData() throws Exception {
    batch(1, 2000, now - 31L * 86400000);
    assertThat(
            body(read(owner).andExpect(status().isOk()))
                .path("devices")
                .get(0)
                .path("status")
                .asText())
        .isEqualTo("NO_DATA");
  }

  @Test
  void invalidSelectionZoneAndRangeAreBadRequests() throws Exception {
    for (String zone : List.of("bad/zone", "+08:00"))
      mvc.perform(
              get(root)
                  .with(actor(owner))
                  .param("deviceId", device)
                  .param("from", "" + from)
                  .param("to", "" + to)
                  .param("timeZone", zone))
          .andExpect(status().isBadRequest());
    mvc.perform(
            get(root)
                .with(actor(owner))
                .param("deviceId", device, device)
                .param("from", "" + from)
                .param("to", "" + to)
                .param("timeZone", "UTC"))
        .andExpect(status().isBadRequest());
    mvc.perform(
            get(root)
                .with(actor(owner))
                .param("deviceId", device)
                .param("from", "" + to)
                .param("to", "" + from)
                .param("timeZone", "UTC"))
        .andExpect(status().isBadRequest());
  }

  @Test
  void oversizedSourceFailsBeforeReturningPartialData() throws Exception {
    batch(1, 2000, now);
    db.update(
        "UPDATE usage_observation_batches SET payload_json=CONCAT(payload_json,REPEAT(' ',4096))"
            + " WHERE tenant_id=?",
        tenant);
    read(owner)
        .andExpect(status().isPayloadTooLarge())
        .andExpect(jsonPath("$.errorCode").value("USAGE_REPORT_TOO_LARGE"));
  }

  @Test
  void authorizationRemainsLockedUntilReportHasBeenComputed() throws Exception {
    batch(1, 2000, now);
    var copied = new CountDownLatch(1);
    var resume = new CountDownLatch(1);
    var revokeStarted = new CountDownLatch(1);
    doAnswer(
            invocation -> {
              var value = invocation.callRealMethod();
              if (invocation
                  .getArgument(0)
                  .getClass()
                  .getName()
                  .equals("com.aimanager.reporting.internal.UsageReportService$Report")) {
                copied.countDown();
                assertThat(resume.await(5, TimeUnit.SECONDS)).isTrue();
              }
              return value;
            })
        .when(json)
        .writeValueAsBytes(any());
    var executor = Executors.newFixedThreadPool(2);
    try {
      var report = executor.submit(() -> read(owner).andExpect(status().isOk()));
      assertThat(copied.await(5, TimeUnit.SECONDS)).isTrue();
      var revoke =
          executor.submit(
              () -> {
                revokeStarted.countDown();
                return db.update(
                    "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?",
                    tenant);
              });
      assertThat(revokeStarted.await(2, TimeUnit.SECONDS)).isTrue();
      assertThatThrownBy(() -> revoke.get(150, TimeUnit.MILLISECONDS))
          .isInstanceOf(TimeoutException.class);
      resume.countDown();
      report.get(8, TimeUnit.SECONDS);
      assertThat(revoke.get(8, TimeUnit.SECONDS)).isEqualTo(1);
      read(owner).andExpect(status().isForbidden());
    } finally {
      resume.countDown();
      executor.shutdownNow();
      executor.awaitTermination(5, TimeUnit.SECONDS);
    }
  }
}
