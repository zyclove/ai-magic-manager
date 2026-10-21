package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

class FamilyErasureConfigurationProcessorTest {
  static final List<String> FAMILY_COPIES = List.of(
      "family_rules", "family_ai_suggestions", "family_access_requests",
      "family_runtime_reports", "family_temporary_grants");
  ErasureConfigurationProcessorTest fixture;
  JdbcTemplate db;
  String tenant;

  @BeforeEach
  void setup() {
    fixture = new ErasureConfigurationProcessorTest();
    fixture.setup();
    db = fixture.db;
    tenant = fixture.tenant;
  }

  void familyCopies(ErasureObservationProcessorTest.Device device) {
    String request = fixture.id();
    db.update("INSERT INTO family_rules(tenant_id,subject_id,policy_id,version,rules_json,updated_at)"
        + " VALUES(?,?,?,1,'private rules',1)", tenant, device.subject(), fixture.id());
    db.update("INSERT INTO family_ai_suggestions(tenant_id,id,actor_key,subject_id,rule_version,request_hash,task,result_json,created_at,expires_at)"
        + " VALUES(?,?,?,?,1,?,'RULE_DRAFT','private suggestion',1,100)",
        tenant, fixture.id(), fixture.fixture.creator, device.subject(), "a".repeat(64));
    db.update("INSERT INTO family_access_requests(tenant_id,id,subject_id,device_id,registration_id,base_rule_version,state,requested_seconds,reason,created_at,expires_at,version)"
        + " VALUES(?,?,?,?,?,1,'PENDING',60,'private reason',1,100,0)",
        tenant, request, device.subject(), device.id(), device.registration());
    db.update("INSERT INTO family_runtime_reports(tenant_id,device_id,registration_id,report_sequence,observed_at,received_at,report_json)"
        + " VALUES(?,?,?,1,1,1,'private runtime')", tenant, device.id(), device.registration());
    db.update("INSERT INTO family_temporary_grants(tenant_id,device_id,registration_id,subject_id,not_after,request_id)"
        + " VALUES(?,?,?,?,100,?)", tenant, device.id(), device.registration(), device.subject(), request);
  }

  void trialAccount(String device) {
    db.update("INSERT INTO family_subscription_accounts(tenant_id,trial_started_at,trial_ends_at,trial_device_id,trial_evidence_hash,version)"
        + " VALUES(?,100,200,?,?,3)", tenant, device, "b".repeat(64));
    db.update("INSERT INTO family_trial_claims(identity_key,tenant_id,claimed_at,evidence_hash)"
        + " VALUES(?,?,100,?)", "PHONE_" + tenant, tenant, "b".repeat(64));
  }

  void sharedBillingAndAdultData() {
    String order = fixture.id(), refund = fixture.id();
    db.update("INSERT INTO family_orders(id,tenant_id,actor_key,key_hash,request_hash,plan_key,status,price_minor,currency,period_start,period_end,created_at,expires_at)"
        + " VALUES(?,?,?,?,?,'FAMILY_MONTH','PAID',1900,'CNY',100,200,1,100)",
        order, tenant, fixture.fixture.creator, "c".repeat(64), "d".repeat(64));
    db.update("INSERT INTO family_payment_attempts(id,tenant_id,order_id,actor_key,key_hash,status,created_at)"
        + " VALUES(?,?,?,?,?,'PAID',1)", fixture.id(), tenant, order, fixture.fixture.creator, "e".repeat(64));
    db.update("INSERT INTO family_refund_requests(id,tenant_id,order_id,actor_key,key_hash,request_hash,reason,status,price_minor,created_at)"
        + " VALUES(?,?,?,?,?,?,'billing reason','REFUNDED',1900,1)",
        refund, tenant, order, fixture.fixture.creator, "f".repeat(64), "a".repeat(64));
    db.update("INSERT INTO family_payment_inbox(event_id,event_type,order_id,evidence_hash,accepted_at)"
        + " VALUES(?,'PAYMENT',?,?,1)", fixture.id(), order, "a".repeat(64));
    db.update("INSERT INTO family_guardian_declarations(actor_key,phone_hash,declaration_version,declared_at,tenant_id)"
        + " VALUES(?,?,'family-guardian-v1',1,?)", fixture.fixture.creator, "a".repeat(64), tenant);
    db.update("INSERT INTO family_ai_months(tenant_id,month_key,completed) VALUES(?,'TRIAL',5)", tenant);
  }

  long count(String table) {
    return db.queryForObject("SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?", Long.class, tenant);
  }

  @Test
  void removesFamilyCopiesAndTrialDeviceAssociationWithoutResettingBillingOrTrialEligibility() {
    var target = fixture.fixture.device(fixture.subject);
    var peer = fixture.fixture.device(fixture.peer);
    familyCopies(target);
    familyCopies(peer);
    trialAccount(target.id());
    sharedBillingAndAdultData();
    var claim = fixture.fixture.accept(target);

    var done = fixture.finish(claim, 1);

    for (String table : FAMILY_COPIES) assertEquals(1, count(table), table);
    assertNull(db.queryForObject("SELECT trial_device_id FROM family_subscription_accounts WHERE tenant_id=?", String.class, tenant));
    var account = db.queryForMap("SELECT * FROM family_subscription_accounts WHERE tenant_id=?", tenant);
    assertEquals(100L, ((Number) account.get("trial_started_at")).longValue());
    assertEquals(200L, ((Number) account.get("trial_ends_at")).longValue());
    assertEquals("b".repeat(64), account.get("trial_evidence_hash"));
    assertEquals(4L, ((Number) account.get("version")).longValue());
    assertEquals(100L, db.queryForObject("SELECT claimed_at FROM family_trial_claims WHERE tenant_id=?", Long.class, tenant));
    for (String table : List.of("family_orders", "family_payment_attempts", "family_refund_requests", "family_guardian_declarations"))
      assertEquals(1, count(table), table);
    assertEquals(1, db.queryForObject("SELECT COUNT(*) FROM family_payment_inbox", Integer.class));
    assertEquals(5, db.queryForObject("SELECT completed FROM family_ai_months WHERE tenant_id=?", Integer.class, tenant));
    assertEquals(6, done.totalRows());
    assertTrue(fixture.processor.process(claim, 1).complete());
    assertEquals(4L, db.queryForObject("SELECT version FROM family_subscription_accounts WHERE tenant_id=?", Long.class, tenant));
  }

  @Test
  void retainsTrialAssociationForPeerDeviceAndDoesNotDeletePeerRuntimeAfterReenrollment() {
    var current = fixture.fixture.device(fixture.peer);
    var old = new ErasureObservationProcessorTest.Device(current.id(), fixture.id(), fixture.subject);
    var trialPeer = fixture.fixture.device(fixture.peer);
    familyCopies(current);
    trialAccount(trialPeer.id());

    assertEquals(0, fixture.finish(fixture.fixture.accept(old), 1).totalRows());

    for (String table : FAMILY_COPIES) assertEquals(1, count(table), table);
    assertNotNull(db.queryForObject("SELECT trial_device_id FROM family_subscription_accounts WHERE tenant_id=?", String.class, tenant));
    assertEquals(3L, db.queryForObject("SELECT version FROM family_subscription_accounts WHERE tenant_id=?", Long.class, tenant));
  }

  @Test
  void subjectCopiesAreRemovedEvenWhenNoCurrentDeviceRemains() {
    var detached = new ErasureObservationProcessorTest.Device(fixture.id(), fixture.id(), fixture.subject);
    familyCopies(detached);

    assertEquals(4, fixture.finish(fixture.fixture.accept(), 1).totalRows());

    for (String table : List.of("family_rules", "family_ai_suggestions", "family_access_requests", "family_temporary_grants"))
      assertEquals(0, count(table), table);
    assertEquals(1, count("family_runtime_reports"));
  }

  @Test
  void clearsOnlyTheErasedRegistrationSelectionWithoutRestartingExpiry() {
    var target = fixture.fixture.device(fixture.subject);
    db.update("INSERT INTO family_device_access_accounts(tenant_id,version,projection_hash,selected_device_id,selected_registration_id,selection_anchor) VALUES(?,9,?,?,?,200)",
        tenant,"a".repeat(64),target.id(),target.registration());
    var claim=fixture.fixture.accept(target);
    assertEquals(1,fixture.finish(claim,1).totalRows());
    var account=db.queryForMap("SELECT * FROM family_device_access_accounts WHERE tenant_id=?",tenant);
    assertNull(account.get("selected_device_id"));
    assertNull(account.get("selected_registration_id"));
    assertNull(account.get("projection_hash"));
    assertEquals(200L,((Number)account.get("selection_anchor")).longValue());
    assertEquals(10L,((Number)account.get("version")).longValue());
    assertTrue(fixture.processor.process(claim,1).complete());
    assertEquals(10L,db.queryForObject("SELECT version FROM family_device_access_accounts WHERE tenant_id=?",Long.class,tenant));
  }

  @Test
  void doesNotClearAReenrolledPeerSelectionWithTheSameDeviceId() {
    var current=fixture.fixture.device(fixture.peer);
    var old=new ErasureObservationProcessorTest.Device(current.id(),fixture.id(),fixture.subject);
    db.update("INSERT INTO family_device_access_accounts(tenant_id,version,selected_device_id,selected_registration_id,selection_anchor) VALUES(?,9,?,?,200)",
        tenant,current.id(),current.registration());
    assertEquals(0,fixture.finish(fixture.fixture.accept(old),1).totalRows());
    assertEquals(current.registration(),db.queryForObject("SELECT selected_registration_id FROM family_device_access_accounts WHERE tenant_id=?",String.class,tenant));
  }

  @Test
  void clearsOnlyErasedDeviceAlertStateAndResetsItsScanCursor() {
    var target=fixture.fixture.device(fixture.subject);
    var peer=fixture.fixture.device(fixture.peer);
    for(var device:List.of(target,peer))db.update("INSERT INTO family_notification_device_states(tenant_id,device_id,registration_id,was_healthy,episode,updated_at) VALUES(?,?,?,TRUE,1,100)",tenant,device.id(),device.registration());
    db.update("INSERT INTO family_notification_scan_cursors(scope_key,last_tenant_id,last_entity_id,updated_at) VALUES('DEVICES',?,?,100)",tenant,target.id());
    var done=fixture.finish(fixture.fixture.accept(target),1);
    assertEquals(2,done.totalRows());
    assertEquals(1,count("family_notification_device_states"));
    assertEquals(peer.id(),db.queryForObject("SELECT device_id FROM family_notification_device_states WHERE tenant_id=?",String.class,tenant));
    assertEquals("",db.queryForObject("SELECT last_entity_id FROM family_notification_scan_cursors WHERE scope_key='DEVICES'",String.class));
  }

  @Test
  void completedStepRejectsRestoredTrialDeviceAssociation() {
    var target = fixture.fixture.device(fixture.subject);
    trialAccount(target.id());
    var claim = fixture.fixture.accept(target);
    assertTrue(fixture.finish(claim, 1).complete());
    db.update("UPDATE family_subscription_accounts SET trial_device_id=? WHERE tenant_id=?", target.id(), tenant);

    fixture.fixture.data.failure("ERASURE_STEP_RECHECK_REQUIRED", () -> fixture.processor.process(claim, 1));

    assertEquals(target.id(), db.queryForObject("SELECT trial_device_id FROM family_subscription_accounts WHERE tenant_id=?", String.class, tenant));
  }
}
