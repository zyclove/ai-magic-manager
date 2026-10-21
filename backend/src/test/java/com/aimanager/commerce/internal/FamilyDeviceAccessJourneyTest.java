package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.identity.ActorKeys;
import com.aimanager.commerce.FamilyDeviceAccess;
import com.aimanager.commerce.FamilySubscriptionReminders;
import com.aimanager.family.FamilyRulesService;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.JOSEObjectType;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.ECDSASigner;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.Date;
import java.util.ArrayList;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/** Real database, commercial ledger and HTTP projection; fixtures contain no default paid bypass. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:family-device-access;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=",
    "manager.exports.worker.enabled=false", "manager.report-jobs.worker.enabled=false",
    "manager.diagnostic-packages.worker.enabled=false"})
@AutoConfigureMockMvc
@org.springframework.context.annotation.Import(com.aimanager.support.ControlledIdempotencyTimeConfiguration.class)
class FamilyDeviceAccessJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate jdbc;
  @Autowired CommercialLedger ledger;
  @Autowired FamilyDeviceAccess deviceAccess;
  @Autowired FamilySubscriptionReminders reminderFacts;
  @Autowired FamilyRulesService familyRules;
  @Autowired PlatformTransactionManager transactionManager;
  @MockitoBean JwtDecoder decoder;
  @MockitoBean Clock clock;
  String tenant, owner, subject;
  long now;

  @BeforeEach void family() {
    time("2026-02-01T02:00:00Z");
    tenant=UUID.randomUUID().toString(); owner="seats-owner-"+UUID.randomUUID();
    subject=UUID.randomUUID().toString();
    jdbc.update("INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'Seats','FAMILY','Asia/Shanghai',?)",tenant,now);
    jdbc.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'OWNER')",tenant,owner,ActorKeys.key(owner));
    jdbc.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'Child','AGE_7_12',?)",tenant,subject,now);
  }

  @Test void reminderFactsUseMergedCoverageAndNeverExtendGraceOnDelayedRead() {
    device(subject,now-20);device(subject,now-10);
    long end=now+172800000L;
    membership("reminder-first",1,now-86400000L,now+86400000L,CommercialFact.State.ACTIVE);
    membership("reminder-contiguous",1,now+86400000L,end,CommercialFact.State.ACTIVE);
    membership("reminder-future-gap",1,end+172800000L,end+345600000L,CommercialFact.State.ACTIVE);
    assertThat(reminderFacts.current(tenant).activePeriodEnd()).isEqualTo(end);
    time("2026-02-04T02:00:00Z");
    var expired=reminderFacts.current(tenant);
    assertThat(expired.activePeriodEnd()).isNull();assertThat(expired.lastPeriodEnd()).isEqualTo(end);
    assertThat(expired.graceEndsAt()).isEqualTo(Instant.parse("2026-02-10T02:00:00Z").toEpochMilli());
    assertThat(expired.selectionPending()).isTrue();
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_device_access_accounts WHERE tenant_id=?",Integer.class,tenant)).isZero();
  }

  @Test void reminderFactsUseVerifiedRevocationTimeAndRespectExplicitDeviceChoice()throws Exception {
    String first=device(subject,now-20);device(subject,now-10);
    long start=now-86400000L,end=now+30*86400000L;
    membership("reminder-revoked",1,start,end,CommercialFact.State.ACTIVE);
    time("2026-02-01T02:05:00Z");
    membership("reminder-revoked",2,start,end,CommercialFact.State.REVOKED);
    assertThat(reminderFacts.current(tenant).lastPeriodEnd()).isEqualTo(now);
    var grace=read();String registration=jdbc.queryForObject("SELECT registration_id FROM devices WHERE tenant_id=? AND id=?",String.class,tenant,first);
    mvc.perform(put(path()+"/selection").with(actor()).header("If-Match","\""+grace.path("version").asLong()+"\"").header("Idempotency-Key","reminder-choice")
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of("deviceId",first,"registrationId",registration))))
        .andExpect(status().isOk());
    assertThat(reminderFacts.current(tenant).selectionPending()).isFalse();
    assertThat(reminderFacts.current(tenant).lastPeriodEnd()).isEqualTo(now);
  }

  @Test void freeFamilyDefaultsToItsFirstDeviceAndRejectsAnotherRegistration() throws Exception {
    String first=device(subject,now-1);
    mvc.perform(get(path()).with(actor())).andExpect(status().isOk())
        .andExpect(jsonPath("$.status").value("FREE"))
        .andExpect(jsonPath("$.effectiveDeviceLimit").value(1))
        .andExpect(jsonPath("$.activeCount").value(1))
        .andExpect(jsonPath("$.selectedDeviceId").value(first))
        .andExpect(jsonPath("$.devices[0].access").value("BASIC"));
    mvc.perform(get(base()+"/subscription").with(actor())).andExpect(status().isOk())
        .andExpect(jsonPath("$.childDeviceLimit").value(1));
    mvc.perform(post(base()+"/enrollments").with(actor()).contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(java.util.Map.of("subjectId",subject,"requestedMode","BYOD","platform","ANDROID"))))
        .andExpect(status().isPaymentRequired()).andExpect(jsonPath("$.errorCode").value("FAMILY_DEVICE_LIMIT_REACHED"));
  }

  @Test void delayedFirstReadUsesActualExpiryAndSelectionDoesNotRestartTheWindow() throws Exception {
    String first=device(subject,now-20), second=device(subject,now-10);
    membership("paid",1,now-86400000,now+86400000,CommercialFact.State.ACTIVE);
    time("2026-02-05T02:00:00Z");
    JsonNode grace=read();
    assertThat(grace.path("status").asText()).isEqualTo("GRACE");
    assertThat(grace.path("graceEndsAt").asLong()).isEqualTo(Instant.parse("2026-02-09T02:00:00Z").toEpochMilli());
    String registration=jdbc.queryForObject("SELECT registration_id FROM devices WHERE tenant_id=? AND id=?",String.class,tenant,second);
    var selection=mvc.perform(put(path()+"/selection").with(actor()).header("If-Match","\""+grace.path("version").asLong()+"\"")
        .header("Idempotency-Key","choose").contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(java.util.Map.of("deviceId",second,"registrationId",registration))))
        .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("EXPIRED"))
        .andExpect(jsonPath("$.selectedDeviceId").value(second)).andReturn();
    JsonNode selected=json.readTree(selection.getResponse().getContentAsString());
    assertThat(selected.path("devices").findValuesAsText("access")).containsExactly("RECOVERY_ONLY","BASIC");
    assertThat(read().path("graceEndsAt").asLong()).isEqualTo(grace.path("graceEndsAt").asLong());
    assertThat(first).isNotEqualTo(second);
  }

  @Test void onlyTheSelectedDeviceCanReceiveANewBasicRestrictionAfterExpiry() throws Exception {
    String first=device(subject,now-20);
    String secondSubject=UUID.randomUUID().toString();
    jdbc.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'Sibling','AGE_7_12',?)",tenant,secondSubject,now);
    device(secondSubject,now-10);
    membership("expired",1,now-86400000,now+86400000,CommercialFact.State.ACTIVE);
    time("2026-02-10T02:00:00Z");
    assertThat(read().path("selectedDeviceId").asText()).isEqualTo(first);
    mvc.perform(put(base()+"/subjects/"+secondSubject+"/family-rules").with(actor())
        .header("If-Match","\"0\"").header("Idempotency-Key","recovery-restrict")
        .contentType(MediaType.APPLICATION_JSON).content(basicRules(true)))
        .andExpect(status().isPaymentRequired());
    mvc.perform(put(base()+"/subjects/"+secondSubject+"/family-rules").with(actor())
        .header("If-Match","\"0\"").header("Idempotency-Key","recovery-relax")
        .contentType(MediaType.APPLICATION_JSON).content(basicRules(false)))
        .andExpect(status().isOk());
  }

  @Test void concurrentClaimsAcrossAdultsAndChildrenShareExactlyThreeReservations() throws Exception {
    membership("trial",1,now-1000,now+86400000,CommercialFact.State.ACTIVE);
    membership("overlapping-renewal",1,now-1000,now+172800000,CommercialFact.State.ACTIVE);
    var tickets=new ArrayList<JsonNode>();
    for(int i=0;i<4;i++) {
      String guardian="guardian-seats-"+UUID.randomUUID(),child=UUID.randomUUID().toString();
      jdbc.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')",tenant,guardian,ActorKeys.key(guardian));
      jdbc.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'Sibling','AGE_7_12',?)",tenant,child,now);
      tickets.add(ticket(guardian,child));
    }
    var ready=new CountDownLatch(4);var start=new CountDownLatch(1);var executor=Executors.newFixedThreadPool(4);
    try {
      var outcomes=new ArrayList<java.util.concurrent.Future<Integer>>();
      for(var ticket:tickets) {
        String body=claimBody(ticket);
        outcomes.add(executor.submit(()->{ready.countDown();assertThat(start.await(5,TimeUnit.SECONDS)).isTrue();
          return mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON).content(body)).andReturn().getResponse().getStatus();}));
      }
      assertThat(ready.await(5,TimeUnit.SECONDS)).isTrue();start.countDown();
      var statuses=new ArrayList<Integer>();for(var outcome:outcomes)statuses.add(outcome.get(15,TimeUnit.SECONDS));
      assertThat(statuses).containsExactlyInAnyOrder(201,201,201,402);
      JsonNode view=read();
      assertThat(view.path("effectiveDeviceLimit").asInt()).isEqualTo(3);
      assertThat(view.path("activeCount").asInt()).isEqualTo(3);
    } finally {executor.shutdownNow();}
  }

  @Test void cancellationExpiryAndRevocationReleaseReservationsWithoutErasingRegistration() throws Exception {
    JsonNode first=ticket(owner,subject),second=ticket(owner,subject),third=ticket(owner,subject);
    JsonNode claimed=claim(first,201);
    claim(second,402);
    mvc.perform(delete(base()+"/enrollments/"+first.path("id").asText()).with(actor())).andExpect(status().isNoContent());
    JsonNode next=claim(second,201);
    jdbc.update("UPDATE device_enrollments SET expires_at=? WHERE tenant_id=? AND id=?",now,tenant,second.path("id").asText());
    JsonNode replacement=claim(third,201);
    assertThat(read().path("activeCount").asInt()).isEqualTo(1);
    assertThat(jdbc.queryForObject("SELECT registration_id FROM devices WHERE tenant_id=? AND id=?",String.class,tenant,next.path("deviceId").asText()))
        .isEqualTo(next.path("registrationId").asText());
    mvc.perform(post(base()+"/devices/"+replacement.path("deviceId").asText()+"/revoke").with(actor())).andExpect(status().isNoContent());
    assertThat(read().path("activeCount").asInt()).isZero();
    assertThat(jdbc.queryForObject("SELECT state FROM devices WHERE tenant_id=? AND id=?",String.class,tenant,claimed.path("deviceId").asText())).isEqualTo("REVOKED");
  }

  @Test void futureRenewalCannotActivateNowAndAStartedRenewalRestoresAllDevices() throws Exception {
    device(subject,now-20);device(subject,now-10);
    membership("past",1,now-172800000,now-86400000,CommercialFact.State.ACTIVE);
    membership("future",1,now+86400000,now+172800000,CommercialFact.State.ACTIVE);
    JsonNode before=read();
    assertThat(before.path("status").asText()).isEqualTo("GRACE");
    assertThat(before.path("effectiveDeviceLimit").asInt()).isEqualTo(1);
    time("2026-02-02T02:00:00Z");
    assertThat(read().path("devices").findValuesAsText("access")).containsExactly("MEMBER","MEMBER");
    assertThat(read().path("status").asText()).isEqualTo("PAID");
  }

  @Test void selectionIsVersionedIdempotentAndBoundToTheExactRegistration() throws Exception {
    String first=device(subject,now-20),second=device(subject,now-10);
    membership("past",1,now-172800000,now-86400000,CommercialFact.State.ACTIVE);
    JsonNode grace=read();
    String registration=jdbc.queryForObject("SELECT registration_id FROM devices WHERE tenant_id=? AND id=?",String.class,tenant,second);
    String body=json.writeValueAsString(Map.of("deviceId",second,"registrationId",registration));
    String version="\""+grace.path("version").asLong()+"\"";
    mvc.perform(put(path()+"/selection").with(actor()).header("Idempotency-Key","choice").contentType(MediaType.APPLICATION_JSON).content(body))
        .andExpect(status().isPreconditionRequired());
    var chosen=mvc.perform(put(path()+"/selection").with(actor()).header("If-Match",version).header("Idempotency-Key","choice").contentType(MediaType.APPLICATION_JSON).content(body))
        .andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
    mvc.perform(put(path()+"/selection").with(actor()).header("If-Match",version).header("Idempotency-Key","choice").contentType(MediaType.APPLICATION_JSON).content(body))
        .andExpect(status().isOk()).andExpect(jsonPath("$.version").value(json.readTree(chosen).path("version").asLong()));
    mvc.perform(put(path()+"/selection").with(actor()).header("If-Match",version).header("Idempotency-Key","stale").contentType(MediaType.APPLICATION_JSON).content(body))
        .andExpect(status().isPreconditionFailed());
    long current=read().path("version").asLong();
    mvc.perform(put(path()+"/selection").with(actor()).header("If-Match","\""+current+"\"").header("Idempotency-Key","wrong-registration").contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(Map.of("deviceId",first,"registrationId",registration))))
        .andExpect(status().isConflict());
  }

  @Test void anExistingChoiceCannotSilentlyTransferToAReplacementRegistration()throws Exception {
    String selected=device(subject,now-20),other=device(subject,now-10);
    assertThat(read().path("selectedDeviceId").asText()).isEqualTo(selected);
    String selectedRegistration=read().path("selectedRegistrationId").asText();
    jdbc.update("UPDATE devices SET state='REVOKED' WHERE tenant_id=? AND id=?",tenant,selected);
    JsonNode after=read();
    assertThat(after.path("selectedDeviceId").isNull()).isTrue();
    assertThat(after.path("selectedRegistrationId").isNull()).isTrue();
    assertThat(jdbc.queryForObject("SELECT selected_device_id FROM family_device_access_accounts WHERE tenant_id=?",String.class,tenant)).isEqualTo(selected);
    assertThat(jdbc.queryForObject("SELECT selected_registration_id FROM family_device_access_accounts WHERE tenant_id=?",String.class,tenant)).isEqualTo(selectedRegistration);
    assertThat(after.path("devices").get(0).path("id").asText()).isEqualTo(other);
    assertThat(after.path("devices").get(0).path("access").asText()).isEqualTo("RECOVERY_ONLY");
  }

  @Test void archivingAChildDoesNotFreeItsStillConnectedDeviceSeat()throws Exception {
    String connected=device(subject,now-1);
    jdbc.update("UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?",now,tenant,subject);
    String sibling=UUID.randomUUID().toString();
    jdbc.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'Sibling','AGE_7_12',?)",tenant,sibling,now);
    JsonNode view=read();
    assertThat(view.path("activeCount").asInt()).isEqualTo(1);
    assertThat(view.path("devices").get(0).path("id").asText()).isEqualTo(connected);
    assertThat(view.path("devices").get(0).path("canSelect").asBoolean()).isFalse();
    mvc.perform(post(base()+"/enrollments").with(actor()).contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(Map.of("subjectId",sibling,"requestedMode","BYOD","platform","ANDROID"))))
        .andExpect(status().isPaymentRequired());
    mvc.perform(post(base()+"/devices/"+connected+"/revoke").with(actor())).andExpect(status().isNoContent());
    assertThat(read().path("activeCount").asInt()).isZero();
    ticket(owner,sibling);
  }

  @Test void admissionWaitsForAConcurrentLedgerChangeThenUsesTheRevokedEntitlement()throws Exception {
    membership("lock-race",1,now-1000,now+86400000,CommercialFact.State.ACTIVE);
    device(subject,now-20);device(subject,now-10);
    JsonNode pending=ticket(owner,subject);String body=claimBody(pending);
    var locked=new CountDownLatch(1);var release=new CountDownLatch(1);var started=new CountDownLatch(1);
    var executor=Executors.newFixedThreadPool(2);
    try {
      var writer=executor.submit(()->new TransactionTemplate(transactionManager).executeWithoutResult(tx->{
        deviceAccess.lockFamily(tenant);membership("lock-race",2,now-1000,now+86400000,CommercialFact.State.REVOKED);locked.countDown();
        try{assertThat(release.await(10,TimeUnit.SECONDS)).isTrue();}catch(InterruptedException e){Thread.currentThread().interrupt();throw new AssertionError(e);}
      }));
      assertThat(locked.await(5,TimeUnit.SECONDS)).isTrue();
      var claimant=executor.submit(()->{started.countDown();return mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON).content(body)).andReturn().getResponse().getStatus();});
      assertThat(started.await(5,TimeUnit.SECONDS)).isTrue();
      org.assertj.core.api.Assertions.assertThatThrownBy(()->claimant.get(200,TimeUnit.MILLISECONDS)).isInstanceOf(java.util.concurrent.TimeoutException.class);
      release.countDown();writer.get(10,TimeUnit.SECONDS);
      assertThat(claimant.get(10,TimeUnit.SECONDS)).isEqualTo(402);
      assertThat(read().path("activeCount").asInt()).isEqualTo(2);
    } finally {release.countDown();executor.shutdownNow();}
  }

  @Test void confirmationRechecksExpiredCapacityWithoutRevokingThePendingRegistration()throws Exception {
    membership("short",1,now-1000,now+60000,CommercialFact.State.ACTIVE);
    String first=device(subject,now-20),second=device(subject,now-10);
    JsonNode pending=ticket(owner,subject),claimed=claim(pending,201);
    time("2026-02-01T02:02:00Z");
    String confirm=base()+"/enrollments/"+pending.path("id").asText()+"/confirm";
    String body=json.writeValueAsString(Map.of("pairingCode",claimed.path("pairingCode").asText()));
    mvc.perform(post(confirm).with(actor()).contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isPaymentRequired());
    assertThat(jdbc.queryForObject("SELECT state FROM devices WHERE tenant_id=? AND id=?",String.class,tenant,claimed.path("deviceId").asText())).isEqualTo("AWAITING_CONFIRMATION");
    mvc.perform(post(base()+"/devices/"+first+"/revoke").with(actor())).andExpect(status().isNoContent());
    mvc.perform(post(base()+"/devices/"+second+"/revoke").with(actor())).andExpect(status().isNoContent());
    mvc.perform(post(confirm).with(actor()).contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isOk());
  }

  @Test void scheduledRepublishKeepsTheUnselectedDevicesExistingArrangement()throws Exception {
    String first=device(subject,now-20),second=device(subject,now-10);
    membership("renewal-isolation",1,now-1000,now+60000,CommercialFact.State.ACTIVE);
    String rules=basicRules(true).replace("600","480").replace("660","1200");
    mvc.perform(put(base()+"/subjects/"+subject+"/family-rules").with(actor()).header("If-Match","\"0\"").header("Idempotency-Key","original")
        .contentType(MediaType.APPLICATION_JSON).content(rules)).andExpect(status().isOk());
    time("2026-02-09T02:02:00Z");
    assertThat(read().path("selectedDeviceId").asText()).isEqualTo(first);
    mvc.perform(put(base()+"/subjects/"+subject+"/family-rules").with(actor()).header("If-Match","\"1\"").header("Idempotency-Key","selected-tightens")
        .contentType(MediaType.APPLICATION_JSON).content(basicRules(true))).andExpect(status().isOk());
    assertThat(delivered(first).path("allowedWindows").get(0).path("startMinute").asInt()).isEqualTo(600);
    assertThat(delivered(second).path("allowedWindows").get(0).path("startMinute").asInt()).isEqualTo(480);
    familyRules.republish(tenant,owner,subject);
    assertThat(delivered(first).path("allowedWindows").get(0).path("startMinute").asInt()).isEqualTo(600);
    assertThat(delivered(second).path("allowedWindows").get(0).path("startMinute").asInt()).isEqualTo(480);
    assertThat(delivered(second).path("validUntil").asLong()).isEqualTo(now+604800000L);
    // Loosening the selected device's new arrangement must not tighten another device's older one.
    String registration=jdbc.queryForObject("SELECT registration_id FROM devices WHERE tenant_id=? AND id=?",String.class,tenant,second);
    long necessaryUntil=now+300000;
    jdbc.update("INSERT INTO family_temporary_grants(tenant_id,device_id,registration_id,subject_id,not_after,request_id) VALUES(?,?,?,?,?,?)",
        tenant,second,registration,subject,necessaryUntil,UUID.randomUUID().toString());
    String looser=basicRules(true).replace("600","540").replace("660","720");
    mvc.perform(put(base()+"/subjects/"+subject+"/family-rules").with(actor()).header("If-Match","\"2\"").header("Idempotency-Key","selected-relaxes")
        .contentType(MediaType.APPLICATION_JSON).content(looser)).andExpect(status().isOk());
    assertThat(delivered(first).path("allowedWindows").get(0).path("startMinute").asInt()).isEqualTo(540);
    assertThat(delivered(second).path("allowedWindows").get(0).path("startMinute").asInt()).isEqualTo(480);
    assertThat(delivered(second).path("exceptionUntil").asLong()).isEqualTo(necessaryUntil);
  }

  JsonNode delivered(String device)throws Exception {
    return json.readTree(jdbc.queryForObject("SELECT d.document_json FROM configuration_deliveries d JOIN configuration_streams s ON s.tenant_id=d.tenant_id AND s.delivery_id=d.id WHERE d.tenant_id=? AND d.device_id=?",String.class,tenant,device)).path("familyAssistance");
  }

  String basicRules(boolean enabled){return "{\"enabled\":"+enabled+",\"dailyAllowanceSeconds\":86400,\"timeZoneId\":\"Asia/Shanghai\",\"meteredPackages\":[\"com.example.game\"],\"allowedWindows\":[{\"daysOfWeek\":[1],\"startMinute\":600,\"endMinute\":660}]}";}
  JsonNode ticket(String creator,String child)throws Exception {
    return json.readTree(mvc.perform(post(base()+"/enrollments").with(actor(creator)).contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(Map.of("subjectId",child,"requestedMode","BYOD","platform","ANDROID"))))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
  }
  JsonNode claim(JsonNode ticket,int expected)throws Exception {
    var response=mvc.perform(post("/api/v1/enrollment-claims").contentType(MediaType.APPLICATION_JSON).content(claimBody(ticket)))
        .andExpect(status().is(expected)).andReturn().getResponse();
    return json.readTree(response.getContentAsString());
  }
  String claimBody(JsonNode ticket)throws Exception {
    var key=new ECKeyGenerator(Curve.P_256).generate();
    var token=new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.ES256).type(JOSEObjectType.JWT).build(),
        new JWTClaimsSet.Builder().subject(ticket.path("id").asText()).audience("ai-manager:enrollment-claim")
        .claim("nonce",ticket.path("token").asText()).issueTime(new Date(now)).expirationTime(new Date(now+90000)).jwtID(UUID.randomUUID().toString()).build());
    token.sign(new ECDSASigner(key));
    return json.writeValueAsString(Map.of("enrollmentId",ticket.path("id").asText(),"token",ticket.path("token").asText(),"publicKeyJwk",key.toPublicJWK().toJSONString(),
        "proof",token.serialize(),"displayName","Child device","osVersion","14"));
  }

  void membership(String ref,long revision,long start,long end,CommercialFact.State state) {
    ledger.apply(new CommercialFact(tenant,CommercialFact.SourceSystem.CONTRACT,ref,revision,"FAMILY",
        CommercialFact.CapacityKind.BASE,3,Set.of(CommercialFact.Feature.FAMILY_MULTI_DEVICE),start,end,state,"a".repeat(64),"system:seats-test"));
  }
  String device(String child,long created) {
    String id=UUID.randomUUID().toString();
    jdbc.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)",
        tenant,id,child,UUID.randomUUID().toString(),"Device",created);
    return id;
  }
  JsonNode read() throws Exception {return json.readTree(mvc.perform(get(path()).with(actor())).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());}
  void time(String instant) {
    Instant value=Instant.parse(instant);now=value.toEpochMilli();
    when(clock.millis()).thenReturn(now);when(clock.instant()).thenReturn(value);when(clock.getZone()).thenReturn(ZoneId.of("UTC"));
  }
  String base(){return "/api/v1/tenants/"+tenant;}
  String path(){return base()+"/family-device-access";}
  RequestPostProcessor actor(){return actor(owner);}
  RequestPostProcessor actor(String identity){return jwt().jwt(t->t.subject(identity).claim("auth_time",now/1000)
      .claim("amr",List.of("sms")).claim("phone_number","+8613900000000").claim("phone_number_verified",true));}
}
