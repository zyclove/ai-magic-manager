package com.aimanager.notification.internal;

import static org.assertj.core.api.Assertions.*;

import com.aimanager.commerce.FamilySubscriptionReminders;
import com.aimanager.identity.ActorKeys;
import com.aimanager.notification.FamilyAttentionEvent;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;
import org.springframework.transaction.support.TransactionTemplate;

/** Persists real episodes, outbox and cursor; only the provider and public commercial snapshot port are fixtures. */
class FamilyReminderJourneyTest {
  final String tenant=UUID.randomUUID().toString(),subject=UUID.randomUUID().toString(),device=UUID.randomUUID().toString(),registration=UUID.randomUUID().toString();
  final String owner="reminder-adult",installation=UUID.randomUUID().toString();
  final FamilyPushJourneyTest.MutableClock clock=new FamilyPushJourneyTest.MutableClock();
  final ObjectMapper json=new ObjectMapper();
  final Map<String,FamilySubscriptionReminders.Window> periods=new HashMap<>();
  JdbcTemplate jdbc; TransactionTemplate tx; FamilyPushService push; FamilyReminderService reminders;
  FamilyPushDispatcher dispatcher; FamilyPushJourneyTest.RecordingGateway gateway;

  @BeforeEach void database() {
    var ds=new DriverManagerDataSource("jdbc:h2:mem:"+UUID.randomUUID()+";MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1","sa","");
    jdbc=new JdbcTemplate(ds);
    jdbc.execute("CREATE TABLE tenants(id VARCHAR(36) PRIMARY KEY,kind VARCHAR(20))");
    jdbc.execute("CREATE TABLE tenant_members(tenant_id VARCHAR(36),actor_key VARCHAR(64),actor_id VARCHAR(255),role VARCHAR(30),revoked_at TIMESTAMP,version BIGINT DEFAULT 0,subject_id VARCHAR(36),PRIMARY KEY(tenant_id,actor_key))");
    jdbc.execute("CREATE TABLE subjects(tenant_id VARCHAR(36),id VARCHAR(36),archived_at TIMESTAMP,PRIMARY KEY(tenant_id,id))");
    jdbc.execute("CREATE TABLE devices(tenant_id VARCHAR(36),id VARCHAR(36),subject_id VARCHAR(36),registration_id VARCHAR(36),state VARCHAR(30),platform VARCHAR(20),created_at BIGINT,last_heartbeat_at BIGINT,PRIMARY KEY(tenant_id,id))");
    jdbc.execute("CREATE TABLE family_runtime_reports(tenant_id VARCHAR(36),device_id VARCHAR(36),registration_id VARCHAR(36),report_sequence BIGINT,observed_at BIGINT,received_at BIGINT,report_json TEXT,PRIMARY KEY(tenant_id,device_id))");
    jdbc.execute("CREATE TABLE configuration_deliveries(tenant_id VARCHAR(36),id VARCHAR(36),device_id VARCHAR(36),registration_id VARCHAR(36),policy_id VARCHAR(36),version_id VARCHAR(36),source_sequence BIGINT,document_json TEXT,PRIMARY KEY(tenant_id,id))");
    jdbc.execute("CREATE TABLE configuration_streams(tenant_id VARCHAR(36),delivery_id VARCHAR(36))");
    new ResourceDatabasePopulator(new ClassPathResource("family/family-push.sql"),new ClassPathResource("family/family-reminders.sql")).execute(ds);
    jdbc.update("INSERT INTO tenants VALUES(?,'FAMILY')",tenant);
    jdbc.update("INSERT INTO tenant_members(tenant_id,actor_key,actor_id,role) VALUES(?,?,?,'OWNER')",tenant,ActorKeys.key(owner),owner);
    jdbc.update("INSERT INTO subjects(tenant_id,id) VALUES(?,?)",tenant,subject);
    addDevice(device,registration,clock.millis()-1000,clock.millis());
    var manager=new DataSourceTransactionManager(ds);tx=new TransactionTemplate(manager);
    push=new FamilyPushService(jdbc,new TenantAccess(jdbc),clock);
    FamilySubscriptionReminders commercial=new FamilySubscriptionReminders() {
      public Window current(String t){return periods.getOrDefault(t,new Window(null,null,null,false));}
      public Window lockCurrent(String t){return current(t);}
    };
    reminders=new FamilyReminderService(jdbc,manager,commercial,event->{if(event instanceof FamilyAttentionEvent attention)push.record(attention);},json,clock,1800,1800,600);
    gateway=new FamilyPushJourneyTest.RecordingGateway();
    dispatcher=new FamilyPushDispatcher(jdbc,manager,gateway,clock,3,60,Optional.of(reminders));
    write(()->{push.register(tenant,owner,installation,new FamilyPushService.Registration("ALIYUN","ANDROID","real-sdk-fixture-token",true,true));push.preferences(tenant,owner,new FamilyPushService.Preferences(true,true,true,true));});
  }

  @Test void initialPermissionsMissingNoRuleAndFreshDeviceAreNotInventedFailures()throws Exception {
    report("PERMISSION_MISSING",false,false,false,true);reminders.scan(100);
    assertThat(events()).isZero();
    report("INITIALIZING",true,true,true,true);reminders.scan(100);assertThat(events()).isZero();
    report("ACTIVE",true,true,true,false);reminders.scan(100);assertThat(events()).isZero();
    jdbc.update("UPDATE devices SET last_heartbeat_at=NULL,created_at=? WHERE id=?",clock.millis(),device);
    clock.advance(1_799_999);reminders.scan(100);assertThat(events()).isZero();
    clock.advance(2);reminders.scan(100);assertThat(kinds()).containsExactly("FAMILY_DEVICE_ATTENTION");
  }

  @Test void realHealthyToRevokedTransitionDeduplicatesUntilRecoveryAndCanAlertAgain()throws Exception {
    report("ACTIVE",true,true,true,true);reminders.scan(100);
    report("PERMISSION_MISSING",true,false,true,true);reminders.scan(100);reminders.scan(100);
    assertThat(events()).isEqualTo(1);assertThat(pending()).isEqualTo(1);
    report("ACTIVE",true,true,true,true);reminders.scan(100);
    assertThat(pending()).isZero();assertThat(suppressed()).isEqualTo(1);
    report("PERMISSION_MISSING",true,false,true,true);reminders.scan(100);
    assertThat(events()).isEqualTo(2);assertThat(pending()).isEqualTo(1);
  }

  @Test void recoveryAfterQueueBeforeNextScanStillSuppressesAtDispatch()throws Exception {
    report("ACTIVE",true,true,true,true);reminders.scan(100);
    report("CLOCK_ANOMALY",true,true,true,true);reminders.scan(100);
    report("ACTIVE",true,true,true,true);dispatcher.dispatch(10);
    assertThat(gateway.commands).isEmpty();assertThat(suppressed()).isEqualTo(1);
  }

  @Test void heartbeatReplayCannotMakeOfflineFreshAndFreshHeartbeatSuppressesOldEpisode() {
    clock.advance(1_800_000);reminders.scan(100);assertThat(events()).isEqualTo(1);
    reminders.scan(100);assertThat(events()).isEqualTo(1);
    jdbc.update("UPDATE devices SET last_heartbeat_at=? WHERE id=?",clock.millis(),device);
    dispatcher.dispatch(10);assertThat(gateway.commands).isEmpty();assertThat(suppressed()).isEqualTo(1);
    clock.advance(1_800_000);reminders.scan(100);assertThat(events()).isEqualTo(2);
  }

  @Test void staleReportOrOldRegistrationIsNotCurrentPermissionEvidence()throws Exception {
    report("ACTIVE",true,true,true,true);reminders.scan(100);
    report("PERMISSION_MISSING",true,false,true,true);
    jdbc.update("UPDATE family_runtime_reports SET observed_at=? WHERE device_id=?",clock.millis()-600001,device);
    reminders.scan(100);assertThat(events()).isZero();
    jdbc.update("UPDATE family_runtime_reports SET observed_at=?,registration_id=? WHERE device_id=?",clock.millis(),UUID.randomUUID().toString(),device);
    reminders.scan(100);assertThat(events()).isZero();
  }

  @Test void missingRuntimeEvidenceDoesNotPretendRecoveryAndRearmTheSameFailure()throws Exception {
    report("ACTIVE",true,true,true,true);reminders.scan(100);
    report("PERMISSION_MISSING",true,false,true,true);reminders.scan(100);assertThat(events()).isEqualTo(1);
    clock.advance(600001);reminders.scan(100);
    report("PERMISSION_MISSING",true,false,true,true);reminders.scan(100);
    assertThat(events()).isEqualTo(1);
    report("ACTIVE",true,true,true,true);reminders.scan(100);
    report("PERMISSION_MISSING",true,false,true,true);reminders.scan(100);assertThat(events()).isEqualTo(2);
  }

  @Test void disabledActualDeviceConfigurationClearsFaultAndDoesNotUseAnotherDevicesRule()throws Exception {
    report("ACTIVE",true,true,true,true);reminders.scan(100);
    report("PERMISSION_MISSING",true,false,true,false);reminders.scan(100);assertThat(events()).isZero();
  }

  @Test void reenrollmentResetsHealthyBaselineAndSuppressesOldRegistrationEvent()throws Exception {
    report("ACTIVE",true,true,true,true);reminders.scan(100);
    report("PERMISSION_MISSING",true,false,true,true);reminders.scan(100);
    jdbc.update("UPDATE devices SET registration_id=?,created_at=?,last_heartbeat_at=? WHERE id=?",UUID.randomUUID().toString(),clock.millis(),clock.millis(),device);
    dispatcher.dispatch(10);assertThat(gateway.commands).isEmpty();
    reminders.scan(100);assertThat(events()).isEqualTo(1);
  }

  @Test void preferenceDisabledEventsDoNotReplayWhenConsentIsLaterEnabled()throws Exception {
    write(()->push.preferences(tenant,owner,new FamilyPushService.Preferences(true,true,false,true)));
    clock.advance(1_800_000);reminders.scan(100);assertThat(events()).isEqualTo(1);assertThat(pending()).isZero();
    write(()->push.preferences(tenant,owner,new FamilyPushService.Preferences(true,true,true,true)));
    reminders.scan(100);assertThat(pending()).isZero();
  }

  @Test void enablingNotificationsAfterAnAlreadyPassedBoundaryDoesNotBackfillThatReminder() {
    jdbc.update("UPDATE devices SET last_heartbeat_at=? WHERE id=?",clock.millis()-2_400_000,device);
    reminders.scan(100);
    assertThat(events()).isEqualTo(1);assertThat(pending()).isZero();
  }

  @Test void currentFaultAndOnTimeMembershipBoundaryAreActuallyEligibleForDelivery()throws Exception {
    report("ACTIVE",true,true,true,true);reminders.scan(100);
    report("PERMISSION_MISSING",true,false,true,true);reminders.scan(100);dispatcher.dispatch(10);
    assertThat(gateway.commands).hasSize(1);assertThat(gateway.commands.get(0).installationId()).isEqualTo(installation);
    report("ACTIVE",true,true,true,true);reminders.scan(100);
    periods.put(tenant,new FamilySubscriptionReminders.Window(clock.millis()+3*86_400_000L,null,null,false));
    reminders.scan(100);dispatcher.dispatch(10);assertThat(gateway.commands).hasSize(2);
  }

  @Test void memberExpiryAndChoiceWindowUseOriginalBoundariesOnceAndRenewalSuppressesOldQueue() {
    jdbc.update("UPDATE devices SET state='EXITED'");
    long end=clock.millis()+86_400_000;periods.put(tenant,new FamilySubscriptionReminders.Window(end,null,null,false));
    reminders.scan(100);reminders.scan(100);assertThat(kinds()).containsExactly("FAMILY_SUBSCRIPTION_EXPIRES_SOON");
    clock.advance(86_400_000);periods.put(tenant,new FamilySubscriptionReminders.Window(null,end,end+604_800_000,true));
    reminders.scan(100);assertThat(kinds()).contains("FAMILY_SUBSCRIPTION_EXPIRED");
    clock.advance(6*86_400_000);reminders.scan(100);assertThat(kinds()).contains("FAMILY_SUBSCRIPTION_SELECTION_DUE");
    periods.put(tenant,new FamilySubscriptionReminders.Window(clock.millis()+31*86_400_000L,null,null,false));
    dispatcher.dispatch(20);assertThat(gateway.commands).isEmpty();
    assertThat(pending()).isZero();
  }

  @Test void lateStartDoesNotRestartExpiryTimeAndNeverSendsAncientMembershipReminder() {
    jdbc.update("UPDATE devices SET state='EXITED'");
    long actualEnd=clock.millis()-10*86_400_000L;
    periods.put(tenant,new FamilySubscriptionReminders.Window(null,actualEnd,actualEnd+604_800_000,false));
    reminders.scan(100);dispatcher.dispatch(20);assertThat(gateway.commands).isEmpty();
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_notification_subscription_states WHERE period_end=?",Integer.class,actualEnd)).isEqualTo(1);
  }

  @Test void confirmedFreeDeviceSuppressesSelectionReminderWithoutInventingRenewal() {
    jdbc.update("UPDATE devices SET state='EXITED'");
    long end=clock.millis()-6*86_400_000;periods.put(tenant,new FamilySubscriptionReminders.Window(null,end,end+604_800_000,true));
    reminders.scan(100);assertThat(kinds()).contains("FAMILY_SUBSCRIPTION_SELECTION_DUE");
    periods.put(tenant,new FamilySubscriptionReminders.Window(null,end,end+604_800_000,false));
    dispatcher.dispatch(20);assertThat(gateway.commands).isEmpty();
  }

  @Test void boundedCursorEventuallyVisitsEveryDeviceAcrossRestartsAndConcurrentScans()throws Exception {
    jdbc.update("UPDATE devices SET last_heartbeat_at=? WHERE id=?",clock.millis()-1_800_000,device);
    for(int i=0;i<7;i++)addDevice(UUID.randomUUID().toString(),UUID.randomUUID().toString(),clock.millis()-3_600_000,clock.millis()-1_800_000);
    var pool=Executors.newFixedThreadPool(2);
    try {var first=pool.submit(()->reminders.scan(2));var second=pool.submit(()->reminders.scan(2));first.get(10,TimeUnit.SECONDS);second.get(10,TimeUnit.SECONDS);}finally{pool.shutdownNow();}
    for(int i=0;i<5;i++)reminders.scan(2);
    assertThat(events()).isEqualTo(8);assertThat(pending()).isEqualTo(8);
    assertThatThrownBy(()->reminders.scan(101)).isInstanceOf(IllegalArgumentException.class);
  }

  @Test void inactiveArchivedAndOrganizationDevicesAreNeverFamilyAttentionRecipients() {
    jdbc.update("UPDATE devices SET last_heartbeat_at=? WHERE id=?",clock.millis()-1_800_000,device);
    jdbc.update("UPDATE subjects SET archived_at=CURRENT_TIMESTAMP WHERE id=?",subject);reminders.scan(100);assertThat(events()).isZero();
    jdbc.update("UPDATE subjects SET archived_at=NULL WHERE id=?",subject);
    jdbc.update("UPDATE tenants SET kind='ORGANIZATION' WHERE id=?",tenant);reminders.scan(100);assertThat(events()).isZero();
  }

  @Test void exitedDeviceErasureIsNotUndoneByTheNextScanOrItsCursor()throws Exception {
    report("ACTIVE",true,true,true,true);reminders.scan(100);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_notification_device_states",Integer.class)).isEqualTo(1);
    // Erasure is admitted only after device exit, and removes its episode and runtime data.
    jdbc.update("UPDATE devices SET state='REVOKED' WHERE id=?",device);
    jdbc.update("DELETE FROM family_notification_device_states WHERE device_id=?",device);
    jdbc.update("DELETE FROM family_runtime_reports WHERE device_id=?",device);
    reminders.scan(1);reminders.scan(1);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_notification_device_states",Integer.class)).isZero();
    assertThat(jdbc.queryForObject("SELECT last_entity_id FROM family_notification_scan_cursors WHERE scope_key='DEVICES'",String.class)).isEmpty();
    assertThat(events()).isZero();
  }

  void report(String health,boolean opted,boolean usage,boolean accessibility,boolean enabled)throws Exception {
    String policy="policy",version="version",delivery="delivery";
    jdbc.update("DELETE FROM configuration_streams WHERE tenant_id=?",tenant);jdbc.update("DELETE FROM configuration_deliveries WHERE tenant_id=?",tenant);
    jdbc.update("INSERT INTO configuration_deliveries VALUES(?,?,?,?,?,?,?,?)",tenant,delivery,device,registration,policy,version,1,json.writeValueAsString(Map.of("familyAssistance",Map.of("mode","FAMILY_ASSISTED","enabled",enabled))));
    jdbc.update("INSERT INTO configuration_streams VALUES(?,?)",tenant,delivery);
    jdbc.update("DELETE FROM family_runtime_reports WHERE tenant_id=? AND device_id=?",tenant,device);
    jdbc.update("INSERT INTO family_runtime_reports VALUES(?,?,?,?,?,?,?)",tenant,device,registration,1,clock.millis(),clock.millis(),json.writeValueAsString(Map.of("health",health,"optedIn",opted,"usageGranted",usage,"accessibilityConnected",accessibility,"policyId",policy,"versionId",version,"sourceSequence",1)));
  }
  void addDevice(String id,String reg,long created,Long heartbeat){jdbc.update("INSERT INTO devices VALUES(?,?,?,?, 'ACTIVE','ANDROID',?,?)",tenant,id,subject,reg,created,heartbeat);}
  void write(Runnable action){tx.executeWithoutResult(status->action.run());}
  int events(){return jdbc.queryForObject("SELECT COUNT(*) FROM family_push_events",Integer.class);}
  List<String> kinds(){return jdbc.queryForList("SELECT kind FROM family_push_events ORDER BY occurred_at,event_id",String.class);}
  int pending(){return jdbc.queryForObject("SELECT COUNT(*) FROM family_push_outbox WHERE state='PENDING'",Integer.class);}
  int suppressed(){return jdbc.queryForObject("SELECT COUNT(*) FROM family_push_outbox WHERE state='SUPPRESSED'",Integer.class);}
}
