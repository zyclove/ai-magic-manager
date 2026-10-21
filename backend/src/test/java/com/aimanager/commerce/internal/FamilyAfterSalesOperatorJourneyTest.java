package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(properties={"spring.datasource.url=jdbc:h2:mem:family-operator;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa","spring.datasource.password=", "manager.exports.worker.enabled=false",
    "manager.report-jobs.worker.enabled=false","manager.diagnostic-packages.worker.enabled=false"})
@AutoConfigureMockMvc
class FamilyAfterSalesOperatorJourneyTest {
  private static final String ROOT="/api/v1/platform/family-subscription/refund-requests";
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate jdbc;
  @Autowired ObjectMapper json;
  @Autowired Clock clock;
  @MockitoBean JwtDecoder decoder;
  @MockitoBean FamilyBillGateway billGateway;
  String tenant,refund,order,owner;

  @BeforeEach void seed() throws Exception {
    when(billGateway.available()).thenReturn(true);
    when(billGateway.merchantId()).thenReturn("operator-test-merchant");
    when(billGateway.appId()).thenReturn("operator-test-app");
    owner="family-requester-"+UUID.randomUUID();
    var response=mvc.perform(post("/api/v1/tenants").with(jwt().jwt(j->j.subject(owner))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"))).contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"Family\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"))
        .andExpect(status().isCreated()).andReturn();
    tenant=json.readTree(response.getResponse().getContentAsString()).path("id").asText();
    order=UUID.randomUUID().toString();refund=UUID.randomUUID().toString();
    long now=clock.millis();
    jdbc.update("INSERT INTO family_subscription_accounts(tenant_id,version) VALUES(?,0)",tenant);
    jdbc.update("INSERT INTO family_orders(id,tenant_id,actor_key,key_hash,request_hash,plan_key,status,price_minor,currency,period_start,period_end,created_at,expires_at,provider_transaction_id,paid_at) VALUES(?,?,?,?,?,'FAMILY_MONTH','PAID',1900,'CNY',?,?,?,?,?,?)",
        order,tenant,ActorKeys.key(owner),"a".repeat(64),"b".repeat(64),now,now+86400000L,now-1000,now+600000,"tx-"+order,now);
    jdbc.update("INSERT INTO family_refund_requests(id,tenant_id,order_id,actor_key,key_hash,request_hash,reason,status,price_minor,created_at) VALUES(?,?,?,?,?,?,?,'AWAITING_REVIEW',1900,?)",
        refund,tenant,order,ActorKeys.key(owner),"c".repeat(64),"d".repeat(64),"购买周期选错，希望原路退回",now);
  }
  RequestPostProcessor reviewer(String actor, boolean recent) {
    return jwt().jwt(j->j.subject(actor).claim("auth_time",Instant.now().minusSeconds(recent?0:10000))
        .claim("amr",List.of("mfa"))).authorities(new SimpleGrantedAuthority("SCOPE_family-refunds:review"));
  }
  RequestPostProcessor finance() {
    return jwt().jwt(j->j.subject("finance").claim("auth_time",Instant.now()).claim("amr",List.of("mfa")))
        .authorities(new SimpleGrantedAuthority("SCOPE_family-finance:manage"));
  }
  @Test void changedRenewalRequiresAnewRefundPreview() throws Exception {
    var preview=mvc.perform(get(ROOT+"/"+refund+"/preview").with(reviewer("reviewer",true))).andExpect(status().isOk()).andReturn();
    String hash=json.readTree(preview.getResponse().getContentAsString()).path("previewHash").asText();
    long now=clock.millis();String renewal=UUID.randomUUID().toString();
    jdbc.update("INSERT INTO family_orders(id,tenant_id,actor_key,key_hash,request_hash,plan_key,status,price_minor,currency,period_start,period_end,created_at,expires_at) VALUES(?,?,?,?,?,'FAMILY_MONTH','PAID',1900,'CNY',?,?,?,?)",
        renewal,tenant,ActorKeys.key(owner),UUID.randomUUID().toString(),"e".repeat(64),now+86400000L,now+2678400000L,now,now+600000L);
    mvc.perform(post(ROOT+"/"+refund+"/reviews").with(reviewer("reviewer",true))
        .header("Idempotency-Key",UUID.randomUUID().toString()).contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(java.util.Map.of("decision","APPROVE","previewHash",hash,"note","确认原路退款"))))
        .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("REFUND_PREVIEW_CHANGED"));
    assertThat(jdbc.queryForObject("SELECT status FROM family_refund_requests WHERE id=?",String.class,refund)).isEqualTo("AWAITING_REVIEW");
  }
  @Test void billEnqueueIsIdempotentAndKeepsPermanentOperatorAudit() throws Exception {
    String path="/api/v1/platform/family-subscription/reconciliation/tasks";
    String day=LocalDate.now(clock.withZone(ZoneId.of("Asia/Shanghai"))).minusDays(2).toString();
    String key=UUID.randomUUID().toString();String body=json.writeValueAsString(java.util.Map.of("billDate",day));
    String id=null;
    for(int i=0;i<2;i++){
      var response=mvc.perform(post(path).with(finance()).header("Idempotency-Key",key).contentType(MediaType.APPLICATION_JSON).content(body))
          .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("PENDING")).andReturn();
      String actual=json.readTree(response.getResponse().getContentAsString()).path("id").asText();
      if(id==null)id=actual;else assertThat(actual).isEqualTo(id);
    }
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_bill_audit_events WHERE task_id=? AND action='FAMILY_BILL_ENQUEUED'",Integer.class,id)).isEqualTo(1);
    mvc.perform(post(path).with(finance()).header("Idempotency-Key",UUID.randomUUID().toString()).contentType(MediaType.APPLICATION_JSON).content(body))
        .andExpect(status().isOk()).andExpect(jsonPath("$.id").value(id));
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_bill_audit_events WHERE task_id=? AND action='FAMILY_BILL_ENQUEUED'",Integer.class,id)).isEqualTo(2);
  }
  @Test void refundVerificationQueuesOnlyTheReviewedOriginalAndReplaysWithoutDuplicateWork() throws Exception {
    String path=ROOT+"/"+refund+"/verifications";
    mvc.perform(post(path).with(reviewer("reviewer",true)).header("Idempotency-Key",UUID.randomUUID().toString())).andExpect(status().isConflict());
    jdbc.update("UPDATE family_refund_requests SET status='REQUESTED',reviewed_at=? WHERE id=?",clock.millis(),refund);
    String key=UUID.randomUUID().toString();
    for(int i=0;i<2;i++)mvc.perform(post(path).with(reviewer("reviewer",true)).header("Idempotency-Key",key))
        .andExpect(status().isOk()).andExpect(jsonPath("$.queued").value(true)).andExpect(jsonPath("$.resourceId").value(refund));
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_commerce_work WHERE tenant_id=? AND entity_id=? AND kind='REFUND'",Integer.class,tenant,refund)).isEqualTo(1);
    assertThat(jdbc.queryForObject("SELECT status FROM family_refund_requests WHERE id=?",String.class,refund)).isEqualTo("REQUESTED");
  }
  String[] billDifference(boolean mapped) {
    String task=UUID.randomUUID().toString(),attempt=UUID.randomUUID().toString(),difference=UUID.randomUUID().toString();
    jdbc.update("INSERT INTO family_bill_tasks(id,merchant_key,bill_date,status,attempt_count,latest_attempt_id,created_at,updated_at) VALUES(?,?,?,'DIFFERENCES',1,?,?,?)",
        task,UUID.randomUUID().toString(),"2026-10-01",attempt,clock.millis(),clock.millis());
    jdbc.update("INSERT INTO family_bill_attempts(id,task_id,attempt_number,status,difference_count,created_at) VALUES(?,?,1,'DIFFERENCES',1,?)",attempt,task,clock.millis());
    jdbc.update("INSERT INTO family_bill_differences(id,task_id,attempt_id,kind,tenant_id,order_id,expected_minor,actual_minor,state,created_at) VALUES(?,?,?,'PAYMENT_STATE_MISMATCH',?,?,1900,1900,'OPEN',?)",
        difference,task,attempt,mapped?tenant:null,mapped?order:null,clock.millis());
    return new String[]{task,difference};
  }
  @Test void mappedDifferenceQueuesOriginalVerificationAndNotesDoNotClaimMatching() throws Exception {
    var ids=billDifference(true);String path="/api/v1/platform/family-subscription/reconciliation/tasks/"+ids[0]+"/differences/"+ids[1];
    String key=UUID.randomUUID().toString();
    for(int i=0;i<2;i++)mvc.perform(post(path+"/verifications").with(finance()).header("Idempotency-Key",key))
        .andExpect(status().isOk()).andExpect(jsonPath("$.resourceId").value(order)).andExpect(jsonPath("$.queued").value(true));
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_commerce_work WHERE entity_id=? AND kind='ORDER'",Integer.class,order)).isEqualTo(1);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_bill_audit_events WHERE task_id=? AND action='FAMILY_BILL_VERIFICATION_QUEUED'",Integer.class,ids[0])).isEqualTo(1);
    mvc.perform(post(path+"/acknowledgements").with(finance()).header("Idempotency-Key",UUID.randomUUID().toString())
        .contentType(MediaType.APPLICATION_JSON).content("{\"note\":\"已联系支付服务核查，等待可信结果\"}"))
        .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("ACKNOWLEDGED"));
    mvc.perform(get("/api/v1/platform/family-subscription/reconciliation/tasks/"+ids[0]).with(finance()))
        .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("DIFFERENCES"));
  }
  @Test void unmappedDifferenceAllowsFollowupWithoutInventingAtenantOrPayment() throws Exception {
    var ids=billDifference(false);String path="/api/v1/platform/family-subscription/reconciliation/tasks/"+ids[0]+"/differences/"+ids[1];
    mvc.perform(post(path+"/verifications").with(finance()).header("Idempotency-Key",UUID.randomUUID().toString()))
        .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("FAMILY_BILL_UNMAPPED_TRANSACTION"));
    mvc.perform(post(path+"/acknowledgements").with(finance()).header("Idempotency-Key",UUID.randomUUID().toString())
        .contentType(MediaType.APPLICATION_JSON).content("{\"note\":\"待人工确认所属业务\"}"))
        .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("ACKNOWLEDGED"));
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_bill_audit_events WHERE task_id=?",Integer.class,ids[0])).isEqualTo(1);
  }
  @Test void queuedDifferenceReceiptReplaysAfterANewerBillAttempt() throws Exception {
    var ids=billDifference(true);String path="/api/v1/platform/family-subscription/reconciliation/tasks/"+ids[0]+"/differences/"+ids[1]+"/verifications";
    String key=UUID.randomUUID().toString();
    mvc.perform(post(path).with(finance()).header("Idempotency-Key",key)).andExpect(status().isOk());
    String nextAttempt=UUID.randomUUID().toString();
    jdbc.update("INSERT INTO family_bill_attempts(id,task_id,attempt_number,status,created_at) VALUES(?,?,2,'RUNNING',?)",nextAttempt,ids[0],clock.millis());
    jdbc.update("UPDATE family_bill_tasks SET latest_attempt_id=?,attempt_count=2,status='RUNNING' WHERE id=?",nextAttempt,ids[0]);
    mvc.perform(post(path).with(finance()).header("Idempotency-Key",key)).andExpect(status().isOk())
        .andExpect(jsonPath("$.queued").value(true)).andExpect(jsonPath("$.resourceId").value(order));
    mvc.perform(post(path).with(finance()).header("Idempotency-Key",UUID.randomUUID().toString())).andExpect(status().isNotFound());
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_bill_audit_events WHERE task_id=? AND action='FAMILY_BILL_VERIFICATION_QUEUED'",Integer.class,ids[0])).isEqualTo(1);
  }
  @Test void refundQueueRequiresIndependentScopeAndRecentMfa() throws Exception {
    mvc.perform(get(ROOT).with(jwt().jwt(j->j.subject(owner)))).andExpect(status().isForbidden());
    mvc.perform(get(ROOT).with(reviewer("reviewer",false))).andExpect(status().isUnauthorized());
    mvc.perform(get(ROOT).param("status","AWAITING_REVIEW").param("orderId",order).with(reviewer("reviewer",true)))
        .andExpect(status().isOk()).andExpect(jsonPath("$.items[0].id").value(refund))
        .andExpect(jsonPath("$.items[0].reason").value("购买周期选错，希望原路退回"))
        .andExpect(jsonPath("$.items[0].canReview").value(true))
        .andExpect(jsonPath("$.items[0].actorKey").doesNotExist());
  }
  @Test void detailAndPreviewDoNotPermitSelfApprovalOrInventProviderCompletion() throws Exception {
    mvc.perform(get(ROOT+"/"+refund).with(reviewer(owner,true)))
        .andExpect(status().isOk()).andExpect(jsonPath("$.canReview").value(false));
    var preview=mvc.perform(get(ROOT+"/"+refund+"/preview").with(reviewer("reviewer",true)))
        .andExpect(status().isOk()).andReturn();
    String hash=json.readTree(preview.getResponse().getContentAsString()).path("previewHash").asText();
    mvc.perform(post(ROOT+"/"+refund+"/reviews").with(reviewer(owner,true))
        .header("Idempotency-Key",UUID.randomUUID().toString()).contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(java.util.Map.of("decision","APPROVE","previewHash",hash))))
        .andExpect(status().isForbidden());
    assertThat(jdbc.queryForObject("SELECT status FROM family_refund_requests WHERE id=?",String.class,refund)).isEqualTo("AWAITING_REVIEW");
  }
  @Test void invalidFiltersCannotExpandQueueAndDetailsAreNoStore() throws Exception {
    mvc.perform(get(ROOT).param("status","anything").with(reviewer("reviewer",true))).andExpect(status().isBadRequest());
    var result=mvc.perform(get(ROOT+"/"+refund).with(reviewer("reviewer",true))).andExpect(status().isOk()).andReturn();
    assertThat(result.getResponse().getHeader("Cache-Control")).contains("no-store");
    assertThat(result.getResponse().getContentAsString()).doesNotContain("actor_key","key_hash","request_hash","provider_payload");
  }
  @Test void approvedOrDeclinedReviewPersistsNoteWithoutPretendingMoneyWasReturned() throws Exception {
    var preview=mvc.perform(get(ROOT+"/"+refund+"/preview").with(reviewer("reviewer",true)))
        .andExpect(status().isOk()).andReturn();
    String hash=json.readTree(preview.getResponse().getContentAsString()).path("previewHash").asText();
    String body=json.writeValueAsString(java.util.Map.of("decision","DENY","previewHash",hash,"note","请补充原订单问题的说明"));
    String key=UUID.randomUUID().toString();
    for(int i=0;i<2;i++)mvc.perform(post(ROOT+"/"+refund+"/reviews").with(reviewer("reviewer",true))
        .header("Idempotency-Key",key).contentType(MediaType.APPLICATION_JSON).content(body))
        .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("DECLINED"))
        .andExpect(jsonPath("$.externalRefundSubmitted").value(false));
    mvc.perform(get(ROOT+"/"+refund).with(reviewer("reviewer",true))).andExpect(status().isOk())
        .andExpect(jsonPath("$.reviewNote").value("请补充原订单问题的说明"));
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_refund_reviews WHERE refund_id=?",Integer.class,refund)).isEqualTo(1);
  }
  @Test void financeWorkRequiresItsOwnScopeAndRecentMfa() throws Exception {
    String tasks="/api/v1/platform/family-subscription/reconciliation/tasks";
    mvc.perform(get(tasks).with(reviewer("reviewer",true))).andExpect(status().isForbidden());
    mvc.perform(get(tasks).with(jwt().jwt(j->j.subject("finance").claim("amr",List.of("mfa")).claim("auth_time",Instant.now()))
        .authorities(new SimpleGrantedAuthority("SCOPE_family-finance:manage"))))
        .andExpect(status().isOk()).andExpect(jsonPath("$.items").isArray());
    mvc.perform(post(tasks).with(jwt().jwt(j->j.subject("finance").claim("amr",List.of("mfa")).claim("auth_time",Instant.now().minusSeconds(10000)))
        .authorities(new SimpleGrantedAuthority("SCOPE_family-finance:manage"))).header("Idempotency-Key",UUID.randomUUID().toString())
        .contentType(MediaType.APPLICATION_JSON).content("{\"billDate\":\"2026-99-01\"}"))
        .andExpect(status().isUnauthorized());
  }
  @Test void trustedProfileAdvertisesIndependentOperatorCapabilities() throws Exception {
    mvc.perform(get("/api/v1/me").with(jwt().jwt(j->j.subject("operator")).authorities(
        new SimpleGrantedAuthority("SCOPE_family-refunds:review"),new SimpleGrantedAuthority("SCOPE_family-finance:manage"))))
        .andExpect(status().isOk()).andExpect(jsonPath("$.canReviewFamilyRefunds").value(true))
        .andExpect(jsonPath("$.canManageFamilyFinance").value(true));
    mvc.perform(get("/api/v1/me").with(jwt().jwt(j->j.subject(owner))))
        .andExpect(status().isOk()).andExpect(jsonPath("$.canReviewFamilyRefunds").value(false))
        .andExpect(jsonPath("$.canManageFamilyFinance").value(false));
  }
}
