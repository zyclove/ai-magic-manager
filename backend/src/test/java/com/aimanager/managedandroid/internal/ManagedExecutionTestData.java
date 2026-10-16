package com.aimanager.managedandroid.internal;

import com.aimanager.identity.ActorKeys;
import java.util.UUID;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;

/** Shared SQL fixture only: simulated binding authority does not certify a real managed device. */
public final class ManagedExecutionTestData implements AutoCloseable {
  public final DriverManagerDataSource source =
      new DriverManagerDataSource(
          "jdbc:h2:mem:execution-"
              + id()
              + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE;LOCK_TIMEOUT=10000",
          "sa",
          "");
  public final JdbcTemplate db = new JdbcTemplate(source);
  public final DataSourceTransactionManager transactions = new DataSourceTransactionManager(source);

  public ManagedExecutionTestData() {
    new ResourceDatabasePopulator(new ClassPathResource("db/migration/V1__initial_schema.sql"))
        .execute(source);
  }

  public static String id() {
    return UUID.randomUUID().toString();
  }

  public record Fixture(
      String tenant,
      String actor,
      String subject,
      String device,
      String registration,
      String binding,
      String enrollment,
      String enterprise,
      String providerDevice,
      String publication,
      String version) {}

  public Fixture fixture() {
    String tenant = id(),
        actor = "execution-admin-" + id(),
        subject = id(),
        device = id(),
        registration = id(),
        binding = id(),
        enrollment = id(),
        enterprise = "e" + id(),
        providerDevice = "d" + id();
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'local execution"
            + " fixture','ORGANIZATION','UTC',1)",
        tenant);
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'fixture','AGE_7_12',1)",
        tenant,
        subject);
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'OWNER')",
        tenant,
        actor,
        ActorKeys.key(actor));
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'fixture','ANDROID','14','ACTIVE','{}',?,1)",
        tenant,
        device,
        subject,
        registration,
        "a".repeat(64));
    db.update(
        "INSERT INTO"
            + " managed_enterprise_bindings(tenant_id,provider,enterprise_id,contract_reference,state,version,requested_by,created_at,updated_at)"
            + " VALUES(?,'LOCAL_TEST',?,'fixture','ACTIVE',1,?,1,1)",
        tenant,
        enterprise,
        actor);
    db.update(
        "INSERT INTO"
            + " managed_enrollment_intents(tenant_id,id,subject_id,provider,enterprise_id,binding_version,policy_id,nonce_hash,provider_device_id,provider_mode,state,version,requested_by,created_at,expires_at,updated_at)"
            + " VALUES(?,?,?,'LOCAL_TEST',?,1,'p1',?,?,'DEVICE_OWNER','VERIFIED',1,?,1,9999999999999,1)",
        tenant,
        enrollment,
        subject,
        enterprise,
        id().replace("-", "").repeat(2),
        providerDevice,
        actor);
    db.update(
        "INSERT INTO"
            + " managed_agent_bindings(tenant_id,id,subject_id,enrollment_id,device_id,registration_id,key_thumbprint,provider,enterprise_id,enterprise_binding_version,provider_device_id,package_name,request_key,requested_by,state,version,active_device_id,active_enrollment_id,created_at,expires_at,updated_at,verified_at,agent_trust_revision)"
            + " VALUES(?,?,?,?,?,?,?,'LOCAL_TEST',?,1,?,'com.aimanager.child',?,?,'VERIFIED',2,?,?,1,600001,2,2,?)",
        tenant,
        binding,
        subject,
        enrollment,
        device,
        registration,
        "a".repeat(64),
        enterprise,
        providerDevice,
        id(),
        actor,
        device,
        enrollment,
        "b".repeat(64));
    return publication(
        new Fixture(
            tenant,
            actor,
            subject,
            device,
            registration,
            binding,
            enrollment,
            enterprise,
            providerDevice,
            null,
            null),
        "ENFORCE");
  }

  public Fixture publication(Fixture f, String mode) {
    String draft = id(), preview = id(), version = id(), publication = id();
    String snapshot =
        "{\"schemaVersion\":1,\"targets\":[{\"deviceId\":\""
            + f.device()
            + "\",\"registrationId\":\""
            + f.registration()
            + "\"}]}";
    db.update(
        "INSERT INTO policy_drafts(tenant_id,id,name,kind,rules_json,created_at,updated_at)"
            + " VALUES(?,?,'fixture','POLICY','[]',1,1)",
        f.tenant(),
        draft);
    db.update(
        "INSERT INTO"
            + " policy_previews(tenant_id,id,policy_id,draft_revision,hash,snapshot_json,created_at,expires_at)"
            + " VALUES(?,?,?,0,?,?,1,9999999999999)",
        f.tenant(),
        preview,
        draft,
        "c".repeat(64),
        snapshot);
    db.update(
        "INSERT INTO"
            + " policy_versions(tenant_id,id,policy_id,draft_revision,sequence_number,preview_id,preview_hash,mode,snapshot_json,created_at)"
            + " VALUES(?,?,?,0,1,?,?,?,?,1)",
        f.tenant(),
        version,
        draft,
        preview,
        "c".repeat(64),
        mode,
        snapshot);
    db.update(
        "INSERT INTO policy_publications(tenant_id,id,version_id,state,created_at)"
            + " VALUES(?,?,?,'QUEUED',1)",
        f.tenant(),
        publication,
        version);
    return new Fixture(
        f.tenant(),
        f.actor(),
        f.subject(),
        f.device(),
        f.registration(),
        f.binding(),
        f.enrollment(),
        f.enterprise(),
        f.providerDevice(),
        publication,
        version);
  }

  @Override
  public void close() {
    db.execute("SHUTDOWN");
  }
}
