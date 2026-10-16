package com.aimanager.policy.internal;

import static org.assertj.core.api.Assertions.*;

import com.aimanager.managedandroid.internal.ManagedExecutionTestData;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Real domain authority and publication SQL; no provider activation or device capability fixture.
 */
class ManagedExecutionPublicationReaderTest {
  ManagedExecutionTestData data;
  ManagedExecutionTestData.Fixture f;
  ManagedExecutionPublicationReader reader;
  TransactionTemplate tx;

  @BeforeEach
  void setup() {
    data = new ManagedExecutionTestData();
    f = data.fixture();
    reader =
        new ManagedExecutionPublicationReader(
            data.db, new ObjectMapper(), new TenantAccess(data.db));
    tx = new TransactionTemplate(data.transactions);
  }

  @AfterEach
  void close() {
    data.close();
  }

  @Test
  void exactPublishedTargetProvidesOnlyImmutableReference() {
    var ref =
        tx.execute(
            s ->
                reader.requireTarget(
                    f.tenant(), f.actor(), f.publication(), f.device(), f.registration()));
    assertThat(ref.versionId()).isEqualTo(f.version());
    assertThat(ref.previewHash()).isEqualTo("c".repeat(64));
  }

  @Test
  void configurationPublicationCannotBecomeExecutionAdmission() {
    var configured = data.publication(f, "CONFIGURE_ONLY");
    assertThatThrownBy(
            () ->
                tx.execute(
                    s ->
                        reader.requireTarget(
                            f.tenant(),
                            f.actor(),
                            configured.publication(),
                            f.device(),
                            f.registration())))
        .isInstanceOf(DomainException.class)
        .hasMessageContaining("EXECUTION_PUBLICATION_REQUIRED");
  }

  @Test
  void anotherRegistrationOrDeviceIsNotThisFrozenTarget() {
    assertThatThrownBy(
            () ->
                tx.execute(
                    s ->
                        reader.requireTarget(
                            f.tenant(),
                            f.actor(),
                            f.publication(),
                            f.device(),
                            ManagedExecutionTestData.id())))
        .isInstanceOf(DomainException.class);
    assertThatThrownBy(
            () ->
                tx.execute(
                    s ->
                        reader.requireTarget(
                            f.tenant(),
                            f.actor(),
                            f.publication(),
                            ManagedExecutionTestData.id(),
                            f.registration())))
        .isInstanceOf(DomainException.class);
  }

  @Test
  void anotherTenantOrUnrelatedActorCannotReadTarget() {
    var other = data.fixture();
    assertThatThrownBy(
            () ->
                tx.execute(
                    s ->
                        reader.requireTarget(
                            other.tenant(),
                            other.actor(),
                            f.publication(),
                            f.device(),
                            f.registration())))
        .isInstanceOf(DomainException.class);
    assertThatThrownBy(
            () ->
                tx.execute(
                    s ->
                        reader.requireTarget(
                            f.tenant(),
                            other.actor(),
                            f.publication(),
                            f.device(),
                            f.registration())))
        .isInstanceOf(DomainException.class);
  }

  @ParameterizedTest
  @ValueSource(strings = {"CHILD", "GUARDIAN", "AUDITOR", "TEACHER"})
  void unsupportedRolesCannotAdmitManagedExecution(String role) {
    data.db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, f.tenant());
    assertThatThrownBy(
            () ->
                tx.execute(
                    s ->
                        reader.requireTarget(
                            f.tenant(), f.actor(), f.publication(), f.device(), f.registration())))
        .isInstanceOf(DomainException.class);
  }

  @Test
  void revokedMembershipCannotReuseAnOldPublication() {
    data.db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", f.tenant());
    assertThatThrownBy(
            () ->
                tx.execute(
                    s ->
                        reader.requireTarget(
                            f.tenant(), f.actor(), f.publication(), f.device(), f.registration())))
        .isInstanceOf(DomainException.class);
  }

  @ParameterizedTest
  @ValueSource(strings = {"null", "[]", "{}", "{\"schemaVersion\":2,\"targets\":[]}"})
  void malformedStoredSnapshotCannotSupplyProvenance(String snapshot) {
    data.db.update(
        "UPDATE policy_versions SET snapshot_json=? WHERE tenant_id=?", snapshot, f.tenant());
    assertThatThrownBy(
            () ->
                tx.execute(
                    s ->
                        reader.requireTarget(
                            f.tenant(), f.actor(), f.publication(), f.device(), f.registration())))
        .isInstanceOf(IllegalStateException.class);
  }
}
