package com.aimanager.notification.internal;

import static org.assertj.core.api.Assertions.*;

import com.aimanager.identity.ActorKeys;
import com.aimanager.notification.FamilyAttentionEvent;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.MembershipRevoked;
import com.aimanager.tenant.TenantAccess;
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

/** Real persisted queue and authority; only the external provider is replaced. */
class FamilyPushJourneyTest {
  final String tenant=UUID.randomUUID().toString(), other=UUID.randomUUID().toString();
  final String owner="adult-owner", guardian="adult-guardian", child="child-actor";
  final String installation=UUID.randomUUID().toString();
  final MutableClock clock=new MutableClock();
  JdbcTemplate jdbc;
  TransactionTemplate tx;
  FamilyPushService service;
  FamilyPushDispatcher dispatcher;
  final RecordingGateway gateway=new RecordingGateway();

  @BeforeEach void database() {
    var ds=new DriverManagerDataSource("jdbc:h2:mem:"+UUID.randomUUID()+";MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1","sa","");
    jdbc=new JdbcTemplate(ds);
    jdbc.execute("CREATE TABLE tenants(id VARCHAR(36) PRIMARY KEY,kind VARCHAR(20))");
    jdbc.execute("CREATE TABLE tenant_members(tenant_id VARCHAR(36),actor_key VARCHAR(64),actor_id VARCHAR(255),role VARCHAR(30),revoked_at TIMESTAMP,version BIGINT DEFAULT 0,subject_id VARCHAR(36),PRIMARY KEY(tenant_id,actor_key))");
    new ResourceDatabasePopulator(new ClassPathResource("family/family-push.sql")).execute(ds);
    jdbc.update("INSERT INTO tenants VALUES(?,'FAMILY'),(?,'FAMILY')",tenant,other);
    member(tenant,owner,"OWNER"); member(tenant,guardian,"GUARDIAN"); member(tenant,child,"CHILD"); member(other,"other-owner","OWNER");
    var manager=new DataSourceTransactionManager(ds);
    tx=new TransactionTemplate(manager);
    service=new FamilyPushService(jdbc,new TenantAccess(jdbc),clock);
    dispatcher=new FamilyPushDispatcher(jdbc,manager,gateway,clock,3,60,Optional.empty());
  }

  @Test void onlyCurrentAdultsInSameFamilyMayRegisterAndTokensCannotBeStolen() {
    register(owner,installation,"token-owner");
    assertThatThrownBy(()->write(()->service.register(tenant,child,UUID.randomUUID().toString(),registration("token-child"))))
        .isInstanceOf(DomainException.class).hasMessage("SCOPE_DENIED");
    assertThatThrownBy(()->write(()->service.register(other,owner,UUID.randomUUID().toString(),registration("token-cross-tenant"))))
        .isInstanceOf(DomainException.class).hasMessage("SCOPE_DENIED");
    assertThatThrownBy(()->register(guardian,installation,"replacement-token"))
        .isInstanceOf(DomainException.class).hasMessage("SCOPE_DENIED");
    assertThatThrownBy(()->register(guardian,UUID.randomUUID().toString(),"token-owner"))
        .isInstanceOf(DomainException.class).hasMessage("PUSH_TOKEN_ALREADY_BOUND");
    assertThatThrownBy(()->register(owner,UUID.randomUUID().toString(),"a".repeat(256)))
        .isInstanceOf(DomainException.class).hasMessage("INVALID_PUSH_REGISTRATION");
    assertThat(jdbc.queryForObject("SELECT provider_token FROM family_push_installations WHERE installation_id=?",String.class,installation)).isEqualTo("token-owner");
  }

  @Test void explicitConsentAndCategoryOptInAreRequiredBeforeAnyQueueIsCreated() {
    assertThatThrownBy(()->write(()->service.register(tenant,owner,installation,new FamilyPushService.Registration("ALIYUN","ANDROID","token-owner",false,true))))
        .isInstanceOf(DomainException.class).hasMessage("PUSH_CONSENT_REQUIRED");
    register(owner,installation,"token-owner");
    emit(event("FAMILY_REQUEST_PENDING"));
    assertThat(count("family_push_outbox")).isZero();
    optIn(owner);
    emit(event("FAMILY_REQUEST_PENDING"));
    assertThat(count("family_push_outbox")).isEqualTo(1);
    write(()->service.preferences(tenant,owner,new FamilyPushService.Preferences(false,false,false,false)));
    dispatcher.dispatch(10);
    assertThat(gateway.commands).isEmpty();
    assertThat(state()).isEqualTo("SUPPRESSED");
  }

  @Test void duplicateDomainEventsProduceOneOpaqueGenericPushAndAcceptanceIsNotDelivery() {
    register(owner,installation,"token-owner"); optIn(owner);
    var event=event("FAMILY_REQUEST_PENDING"); emit(event); emit(event);
    assertThat(count("family_push_outbox")).isEqualTo(1);
    assertThat(dispatcher.dispatch(10)).isEqualTo(1);
    assertThat(dispatcher.dispatch(10)).isZero();
    assertThat(gateway.commands).hasSize(1);
    var command=gateway.commands.get(0);
    assertThat(command.eventId()).isEqualTo(event.eventId());
    assertThat(command.deepLink()).isEqualTo("aimanager://notifications/"+event.eventId());
    assertThat(command.title()+command.body()+command.deepLink()).doesNotContain(event.subjectId(),event.deviceId(),"reason","phone");
    assertThat(state()).isEqualTo("ACCEPTED");
    assertThat(jdbc.queryForObject("SELECT provider_message_id FROM family_push_outbox",String.class)).isEqualTo("provider-message-1");
  }

  @Test void databaseRevocationBeforeDispatchSuppressesEvenAnAlreadyQueuedEvent() {
    register(owner,installation,"token-owner"); optIn(owner); emit(event("FAMILY_REQUEST_PENDING"));
    jdbc.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?",tenant,ActorKeys.key(owner));
    dispatcher.dispatch(10);
    assertThat(gateway.commands).isEmpty(); assertThat(state()).isEqualTo("SUPPRESSED");
  }

  @Test void logoutErasesTokenAndMembershipRevocationErasesAllAdultRegistrations() {
    register(owner,installation,"token-owner"); optIn(owner); emit(event("FAMILY_REQUEST_PENDING"));
    assertThatThrownBy(()->write(()->service.revoke(tenant,guardian,installation))).isInstanceOf(DomainException.class);
    write(()->service.revoke(tenant,owner,installation));
    assertThat(jdbc.queryForObject("SELECT provider_token FROM family_push_installations WHERE installation_id=?",String.class,installation)).isNull();
    dispatcher.dispatch(10); assertThat(gateway.commands).isEmpty();
    register(guardian,UUID.randomUUID().toString(),"token-guardian"); optIn(guardian);
    write(()->service.membershipRevoked(new MembershipRevoked(tenant,ActorKeys.key(guardian))));
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_push_installations WHERE provider_token IS NOT NULL",Integer.class)).isZero();
    assertThat(service.preferences(tenant,guardian).enabled()).isFalse();
  }

  @Test void providerFailuresPersistAttemptsBackoffStableDeliveryIdAndDeadLetter() {
    register(owner,installation,"token-owner"); optIn(owner); emit(event("FAMILY_DEVICE_ATTENTION")); gateway.fail=true;
    dispatcher.dispatch(10);
    assertThat(state()).isEqualTo("PENDING");
    assertThat(jdbc.queryForObject("SELECT attempts FROM family_push_outbox",Integer.class)).isEqualTo(1);
    assertThat(dispatcher.dispatch(10)).isZero();
    clock.advance(60_000); dispatcher.dispatch(10);
    clock.advance(120_000); dispatcher.dispatch(10);
    assertThat(state()).isEqualTo("DEAD");
    assertThat(jdbc.queryForObject("SELECT attempts FROM family_push_outbox",Integer.class)).isEqualTo(3);
    assertThat(gateway.commands.stream().map(FamilyPushGateway.Command::deliveryId).distinct()).hasSize(1);
    clock.advance(3600_000); assertThat(dispatcher.dispatch(10)).isZero();
  }

  @Test void expiredLeaseCanBeRecoveredButRotatedRegistrationCannotReceiveOldQueue() {
    register(owner,installation,"token-owner"); optIn(owner); emit(event("FAMILY_REQUEST_PENDING"));
    jdbc.update("UPDATE family_push_outbox SET state='LEASED',lease_id='lost-worker',lease_until=?",clock.millis()-1);
    dispatcher.dispatch(10); assertThat(state()).isEqualTo("ACCEPTED");
    emit(event("FAMILY_REQUEST_PENDING")); register(owner,installation,"token-rotated");
    dispatcher.dispatch(10); assertThat(gateway.commands).hasSize(1);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_push_outbox WHERE state='SUPPRESSED'",Integer.class)).isEqualTo(1);
  }

  @Test void organizationEventsAndChildInstallationsNeverBecomePushRecipients() {
    register(owner,installation,"token-owner"); optIn(owner);
    jdbc.update("UPDATE tenants SET kind='ORGANIZATION' WHERE id=?",tenant);
    emit(event("FAMILY_REQUEST_PENDING"));
    assertThat(count("family_push_outbox")).isZero();
    assertThatThrownBy(()->register(owner,UUID.randomUUID().toString(),"new-token"))
        .isInstanceOf(DomainException.class).hasMessage("SCOPE_DENIED");
  }

  @Test void domainRollbackAlsoRollsBackEventAndOutboxProjection() {
    register(owner,installation,"token-owner"); optIn(owner);
    tx.executeWithoutResult(status->{service.record(event("FAMILY_REQUEST_PENDING")); status.setRollbackOnly();});
    assertThat(count("family_push_events")).isZero();
    assertThat(count("family_push_outbox")).isZero();
  }

  @Test void concurrentWorkerCannotSendAnActivelyLeasedDelivery() throws Exception {
    register(owner,installation,"token-owner"); optIn(owner); emit(event("FAMILY_REQUEST_PENDING"));
    gateway.entered=new CountDownLatch(1); gateway.release=new CountDownLatch(1);
    var pool=Executors.newSingleThreadExecutor();
    try {
      var first=pool.submit(()->dispatcher.dispatch(10));
      assertThat(gateway.entered.await(5,TimeUnit.SECONDS)).isTrue();
      assertThat(dispatcher.dispatch(10)).isZero();
      gateway.release.countDown();
      assertThat(first.get(5,TimeUnit.SECONDS)).isEqualTo(1);
      assertThat(gateway.commands).hasSize(1);
      assertThat(state()).isEqualTo("ACCEPTED");
    } finally { gateway.release.countDown(); pool.shutdownNow(); }
  }

  void member(String t,String actor,String role) { jdbc.update("INSERT INTO tenant_members(tenant_id,actor_key,actor_id,role) VALUES(?,?,?,?)",t,ActorKeys.key(actor),actor,role); }
  void write(Runnable action) { tx.executeWithoutResult(status->action.run()); }
  void register(String actor,String id,String token) { write(()->service.register(tenant,actor,id,registration(token))); }
  FamilyPushService.Registration registration(String token) { return new FamilyPushService.Registration("ALIYUN","ANDROID",token,true,true); }
  void optIn(String actor) { write(()->service.preferences(tenant,actor,new FamilyPushService.Preferences(true,true,true,true))); }
  FamilyAttentionEvent event(String kind) { return new FamilyAttentionEvent(tenant,UUID.randomUUID().toString(),UUID.randomUUID().toString(),UUID.randomUUID().toString(),kind,clock.millis()); }
  void emit(FamilyAttentionEvent event) { write(()->service.record(event)); }
  int count(String table) { return jdbc.queryForObject("SELECT COUNT(*) FROM "+table,Integer.class); }
  String state() { return jdbc.queryForObject("SELECT state FROM family_push_outbox ORDER BY created_at LIMIT 1",String.class); }
  static class MutableClock extends Clock {
    long value=Instant.parse("2026-10-15T04:00:00Z").toEpochMilli();
    void advance(long milliseconds) { value+=milliseconds; }
    public ZoneId getZone(){return ZoneOffset.UTC;} public Clock withZone(ZoneId zone){return this;} public Instant instant(){return Instant.ofEpochMilli(value);}
  }
  static class RecordingGateway implements FamilyPushGateway {
    final List<Command> commands=new ArrayList<>(); boolean fail;
    CountDownLatch entered,release;
    public boolean available(){return true;}
    public Accepted send(Command command){
      commands.add(command);
      if(entered!=null) {
        entered.countDown();
        try { if(!release.await(5,TimeUnit.SECONDS)) throw new AssertionError("Worker fixture timed out"); }
        catch(InterruptedException error){Thread.currentThread().interrupt();throw new AssertionError(error);}
      }
      if(fail) throw new Failure("PROVIDER_UNAVAILABLE",true);
      return new Accepted("provider-message-"+commands.size());
    }
  }
}
