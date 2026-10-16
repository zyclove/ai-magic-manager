package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;

import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.aimanager.policy.PolicySnapshot;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.context.annotation.ComponentScan;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.FilterType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.EnableTransactionManagement;
import org.springframework.transaction.support.TransactionTemplate;

/** Real publication SQL and domain reader to SDK document; fixture is not provider authority. */
class PublishedGooglePolicyDocumentTest {
  @Configuration(proxyBeanMethods = false)
  @EnableTransactionManagement
  @ComponentScan(
      basePackageClasses = PolicySnapshot.class,
      useDefaultFilters = false,
      includeFilters =
          @ComponentScan.Filter(
              type = FilterType.ASSIGNABLE_TYPE,
              classes = ManagedExecutionPublicationAccess.class))
  static class ReaderConfiguration {}

  @Test
  void readsFrozenPublicationAndBuildsOneCompleteSdkDocument() throws Exception {
    try (var data = new ManagedExecutionTestData()) {
      var f = data.fixture();
      var json = new ObjectMapper();
      String app = ManagedExecutionTestData.id();
      var rules =
          List.of(
              Map.of(
                  "id",
                  "launch",
                  "kind",
                  "APP_LAUNCH",
                  "effect",
                  "DENY",
                  "required",
                  true,
                  "applicationId",
                  app),
              Map.of(
                  "id",
                  "camera",
                  "kind",
                  "RUNTIME_PERMISSION",
                  "effect",
                  "DENY",
                  "required",
                  true,
                  "applicationId",
                  app,
                  "permission",
                  "android.permission.CAMERA"));
      var evaluations =
          List.of(
              Map.of(
                  "sourceRuleIds",
                  List.of("launch"),
                  "kind",
                  "APP_LAUNCH",
                  "applicationId",
                  app,
                  "required",
                  true,
                  "predictedEffect",
                  "DENY",
                  "status",
                  "UNVERIFIED",
                  "reasonCode",
                  "APPLICATION_PROFILE_NOT_VERIFIED"),
              Map.of(
                  "sourceRuleIds",
                  List.of("camera"),
                  "kind",
                  "RUNTIME_PERMISSION",
                  "applicationId",
                  app,
                  "permission",
                  "android.permission.CAMERA",
                  "required",
                  true,
                  "predictedEffect",
                  "DENY",
                  "status",
                  "UNVERIFIED",
                  "reasonCode",
                  "APPLICATION_PROFILE_NOT_VERIFIED"));
      var snapshot =
          Map.of(
              "schemaVersion",
              1,
              "name",
              "Published",
              "sourceRules",
              rules,
              "applications",
              List.of(
                  Map.of(
                      "id",
                      app,
                      "displayName",
                      "Lesson",
                      "platform",
                      "ANDROID",
                      "packageName",
                      "com.example.lesson",
                      "profile",
                      "PRIMARY",
                      "signingDigests",
                      List.of("a".repeat(64)),
                      "evidenceStatus",
                      "DECLARED")),
              "schedules",
              List.of(),
              "protectedPackageExemptions",
              List.of(),
              "targets",
              List.of(
                  Map.of(
                      "deviceId",
                      f.device(),
                      "registrationId",
                      f.registration(),
                      "platform",
                      "ANDROID",
                      "state",
                      "ACTIVE",
                      "managementMode",
                      "FULLY_MANAGED",
                      "rules",
                      evaluations)));
      data.db.update(
          "UPDATE policy_versions SET snapshot_json=? WHERE tenant_id=?",
          json.writeValueAsString(snapshot),
          f.tenant());
      new ApplicationContextRunner()
          .withUserConfiguration(ReaderConfiguration.class)
          .withBean(JdbcTemplate.class, () -> data.db)
          .withBean(ObjectMapper.class, () -> json)
          .withBean(TenantAccess.class, () -> new TenantAccess(data.db))
          .withBean(PlatformTransactionManager.class, () -> data.transactions)
          .run(
              context -> {
                assertThat(context).hasNotFailed();
                var reader = context.getBean(ManagedExecutionPublicationAccess.class);
                assertThatThrownBy(
                        () ->
                            reader.requireDesiredTarget(
                                f.tenant(),
                                f.actor(),
                                f.publication(),
                                f.device(),
                                f.registration()))
                    .isInstanceOf(
                        org.springframework.transaction.IllegalTransactionStateException.class);
                var desired =
                    new TransactionTemplate(data.transactions)
                        .execute(
                            s ->
                                reader.requireDesiredTarget(
                                    f.tenant(),
                                    f.actor(),
                                    f.publication(),
                                    f.device(),
                                    f.registration()));
                var compiler = new GoogleCompletePolicyCompiler("com.aimanager.child", Set.of());
                var result = compiler.compileDesired(30, "DEVICE_OWNER", desired);
                var lesson =
                    result.requestBody().getApplications().stream()
                        .filter(a -> "com.example.lesson".equals(a.getPackageName()))
                        .findFirst()
                        .orElseThrow();
                assertThat(lesson.getDisabled()).isTrue();
                assertThat(lesson.getPermissionGrants().get(0).getPolicy()).isEqualTo("DENY");
                assertThat(desired.publication().versionId()).isEqualTo(f.version());
                assertThat(desired.rules())
                    .hasSize(2)
                    .allMatch(r -> "UNVERIFIED".equals(r.status()));
                assertThat(
                        compiler
                            .restore(result.documentJson(), result.sha256(), 30, "DEVICE_OWNER")
                            .requestBody())
                    .isEqualTo(result.requestBody());
              });
    }
  }
}
