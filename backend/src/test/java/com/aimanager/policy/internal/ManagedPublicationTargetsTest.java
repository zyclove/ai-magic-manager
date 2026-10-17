package com.aimanager.policy.internal;

import static org.assertj.core.api.Assertions.*;

import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.aimanager.managedandroid.internal.ManagedExecutionTestData;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.List;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.transaction.support.TransactionTemplate;

/** Real publication SQL and role checks; static RED candidate, not evidence of provider support. */
class ManagedPublicationTargetsTest {
  ManagedExecutionTestData data;
  ManagedExecutionTestData.Fixture f;
  ManagedExecutionPublicationReader reader;
  TransactionTemplate tx;
  final ObjectMapper json = new ObjectMapper();

  @BeforeEach
  void setup() {
    data = new ManagedExecutionTestData();
    f = data.fixture();
    reader = new ManagedExecutionPublicationReader(data.db, json, new TenantAccess(data.db));
    tx = new TransactionTemplate(data.transactions);
  }

  @AfterEach
  void close() {
    data.close();
  }

  @Test
  void returnsEveryFrozenTargetInStableDeviceOrderWithoutWriting() {
    var second =
        new ManagedExecutionPublicationAccess.Target(
            ManagedExecutionTestData.id(), ManagedExecutionTestData.id());
    var first = new ManagedExecutionPublicationAccess.Target(f.device(), f.registration());
    var root = snapshot();
    root.withArray("targets")
        .addObject()
        .put("deviceId", second.deviceId())
        .put("registrationId", second.registrationId());
    store(root.toString());
    String before = rawSnapshot();
    var result = lookup();
    assertThat(result.publication())
        .isEqualTo(
            new ManagedExecutionPublicationAccess.Publication(f.version(), "c".repeat(64), 1));
    assertThat(result.targets())
        .containsExactlyElementsOf(
            List.of(first, second).stream()
                .sorted(
                    java.util.Comparator.comparing(
                        ManagedExecutionPublicationAccess.Target::deviceId))
                .toList());
    assertThat(rawSnapshot()).isEqualTo(before);
    assertThat(
            data.db.queryForObject(
                "SELECT COUNT(*) FROM policy_publications WHERE tenant_id=?",
                Long.class,
                f.tenant()))
        .isEqualTo(1);
    assertThat(
            data.db.queryForObject(
                "SELECT COUNT(*) FROM managed_policy_execution_tasks WHERE tenant_id=?",
                Long.class,
                f.tenant()))
        .isZero();
  }

  @Test
  void maximumFiftyTargetsAreNotSilentlyTruncated() {
    var root = snapshot();
    for (int i = 1; i < 50; i++)
      root.withArray("targets")
          .addObject()
          .put("deviceId", ManagedExecutionTestData.id())
          .put("registrationId", ManagedExecutionTestData.id());
    store(root.toString());
    assertThat(lookup().targets()).hasSize(50);
  }

  @Test
  void callerCannotMutateTheReturnedFrozenSet() {
    var result = lookup();
    assertThatThrownBy(() -> result.targets().clear())
        .isInstanceOf(UnsupportedOperationException.class);
    assertThat(lookup()).isEqualTo(result);
  }

  @Test
  void currentRegistrationDoesNotRewriteThePublishedTarget() {
    String frozenRegistration = ManagedExecutionTestData.id();
    var root = snapshot();
    ((ObjectNode) root.withArray("targets").get(0)).put("registrationId", frozenRegistration);
    store(root.toString());
    assertThat(lookup().targets())
        .containsExactly(
            new ManagedExecutionPublicationAccess.Target(f.device(), frozenRegistration));
    assertThat(
            data.db.queryForObject(
                "SELECT registration_id FROM devices WHERE tenant_id=? AND id=?",
                String.class,
                f.tenant(),
                f.device()))
        .isEqualTo(f.registration());
  }

  @Test
  void organizationAdministratorCanReadFrozenAdmissionTargets() {
    role("ORG_ADMIN");
    assertThat(lookup().targets()).hasSize(1);
  }

  @Test
  void directInvocationWithoutTransactionIsRejected() {
    assertThatThrownBy(() -> invoke(f.tenant(), f.actor(), f.publication()))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Execution publication snapshot requires a transaction");
  }

  @Test
  void foreignTenantCannotReadPublication() {
    var other = data.fixture();
    assertThatThrownBy(
            () -> tx.execute(s -> invoke(other.tenant(), other.actor(), f.publication())))
        .isInstanceOf(DomainException.class);
  }

  @Test
  void unrelatedActorCannotReadPublication() {
    assertThatThrownBy(
            () -> tx.execute(s -> invoke(f.tenant(), "unrelated-actor", f.publication())))
        .isInstanceOf(DomainException.class);
  }

  @Test
  void missingPublicationIsNotAnEmptyAcceptedSet() {
    assertThatThrownBy(
            () -> tx.execute(s -> invoke(f.tenant(), f.actor(), ManagedExecutionTestData.id())))
        .isInstanceOf(DomainException.class);
  }

  @ParameterizedTest
  @ValueSource(strings = {"CHILD", "GUARDIAN", "AUDITOR", "TEACHER"})
  void rolesWithoutManagedWriteAuthorityAreDenied(String role) {
    role(role);
    assertThatThrownBy(this::lookup).isInstanceOf(DomainException.class);
  }

  @Test
  void revokedAdministratorCannotReusePublication() {
    data.db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", f.tenant());
    assertThatThrownBy(this::lookup).isInstanceOf(DomainException.class);
  }

  @Test
  void configurationOnlyPublicationIsNotAnExecutionRequest() {
    var configured = data.publication(f, "CONFIGURE_ONLY");
    assertThatThrownBy(
            () -> tx.execute(s -> invoke(f.tenant(), f.actor(), configured.publication())))
        .isInstanceOf(DomainException.class)
        .hasMessage("EXECUTION_PUBLICATION_REQUIRED");
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "EMPTY",
        "MISSING",
        "NULL_SET",
        "NULL_TARGET",
        "DUPLICATE_DEVICE",
        "DUPLICATE_DEVICE_NEW_REGISTRATION",
        "TOO_MANY",
        "INVALID_DEVICE",
        "MISSING_DEVICE",
        "INVALID_REGISTRATION",
        "MISSING_REGISTRATION",
        "SCHEMA",
        "SCALAR_SCHEMA",
        "UNKNOWN_FIELD"
      })
  void malformedTargetSetCannotBePartiallyAdmitted(String corruption) {
    var root = snapshot();
    var targets = root.withArray("targets");
    var target = (ObjectNode) targets.get(0);
    switch (corruption) {
      case "EMPTY" -> targets.removeAll();
      case "MISSING" -> root.remove("targets");
      case "NULL_SET" -> root.putNull("targets");
      case "NULL_TARGET" -> targets.addNull();
      case "DUPLICATE_DEVICE" -> targets.add(target.deepCopy());
      case "DUPLICATE_DEVICE_NEW_REGISTRATION" ->
          targets.add(target.deepCopy().put("registrationId", ManagedExecutionTestData.id()));
      case "TOO_MANY" -> {
        for (int i = 1; i < 51; i++)
          targets
              .addObject()
              .put("deviceId", ManagedExecutionTestData.id())
              .put("registrationId", ManagedExecutionTestData.id());
      }
      case "INVALID_DEVICE" -> target.put("deviceId", "device");
      case "MISSING_DEVICE" -> target.remove("deviceId");
      case "INVALID_REGISTRATION" -> target.put("registrationId", "registration");
      case "MISSING_REGISTRATION" -> target.remove("registrationId");
      case "SCHEMA" -> root.put("schemaVersion", 2);
      case "SCALAR_SCHEMA" -> root.put("schemaVersion", "1");
      case "UNKNOWN_FIELD" -> root.put("clientAuthorized", true);
      default -> throw new AssertionError("Unknown test fixture");
    }
    store(root.toString());
    assertThatThrownBy(this::lookup)
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Invalid stored execution publication");
  }

  @Test
  void duplicateJsonKeysCannotSelectAnAlternativeTargetSet() {
    String original = rawSnapshot();
    store(original.substring(0, original.length() - 1) + ",\"targets\":[]}");
    assertThatThrownBy(this::lookup)
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Invalid stored execution publication");
  }

  private ManagedExecutionPublicationAccess.Targets lookup() {
    return tx.execute(s -> invoke(f.tenant(), f.actor(), f.publication()));
  }

  private ManagedExecutionPublicationAccess.Targets invoke(
      String tenant, String actor, String publication) {
    try {
      return reader.requireTargets(tenant, actor, publication);
    } catch (UnsupportedOperationException missing) {
      if ("MANAGED_PUBLICATION_TARGETS_NOT_IMPLEMENTED".equals(missing.getMessage()))
        throw new AssertionError("MANAGED_PUBLICATION_TARGETS_NOT_IMPLEMENTED", missing);
      throw missing;
    }
  }

  private void role(String role) {
    data.db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, f.tenant());
  }

  private String rawSnapshot() {
    return data.db.queryForObject(
        "SELECT snapshot_json FROM policy_versions WHERE tenant_id=? AND id=?",
        String.class,
        f.tenant(),
        f.version());
  }

  private ObjectNode snapshot() {
    try {
      return (ObjectNode) json.readTree(rawSnapshot());
    } catch (Exception invalidFixture) {
      throw new AssertionError("Invalid test fixture", invalidFixture);
    }
  }

  private void store(String snapshot) {
    data.db.update(
        "UPDATE policy_versions SET snapshot_json=? WHERE tenant_id=? AND id=?",
        snapshot,
        f.tenant(),
        f.version());
  }
}
