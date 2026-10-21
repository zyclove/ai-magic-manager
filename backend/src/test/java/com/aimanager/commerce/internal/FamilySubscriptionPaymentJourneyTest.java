package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.shared.DomainException;
import com.aimanager.audit.AuditService;
import com.aimanager.commerce.FamilyAssistedActivationGate;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.context.jdbc.Sql;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** Provider calls are the external boundary; all authorization, SQL, ledger and audit are real. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:family-payments;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=",
    "manager.exports.worker.enabled=false", "manager.report-jobs.worker.enabled=false",
    "manager.diagnostic-packages.worker.enabled=false"})
@AutoConfigureMockMvc
@Sql("/family/family-subscription.sql")
@org.springframework.context.annotation.Import(com.aimanager.support.ControlledIdempotencyTimeConfiguration.class)
class FamilySubscriptionPaymentJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate jdbc;
  @Autowired CommercialLedger ledger;
  @Autowired org.springframework.context.ApplicationContext context;
  @MockitoBean JwtDecoder decoder;
  @MockitoBean Clock clock;
  @MockitoBean FamilyPaymentGateway gateway;
  @MockitoBean FamilyAssistedActivationGate activationGate;
  @MockitoSpyBean AuditService audit;
  private String tenant;
  private String owner;
  private String phone;
  private String verifiedDevice;
  private final long now = Instant.parse("2026-01-31T02:00:00Z").toEpochMilli();

  @BeforeEach
  void createFamily() throws Exception {
    when(clock.millis()).thenReturn(now);
    when(clock.instant()).thenReturn(Instant.ofEpochMilli(now));
    when(clock.getZone()).thenReturn(ZoneId.of("UTC"));
    when(gateway.available()).thenReturn(true);
    when(gateway.verificationAvailable()).thenReturn(true);
    when(gateway.refundsAvailable()).thenReturn(true);
    when(gateway.createAppPayment(any())).thenReturn(new FamilyPaymentGateway.AppPayment(Map.of("prepayid", "test-external-prepay")));
    owner = "family-owner-" + UUID.randomUUID();
    phone = "+8613"+String.format("%09d",Math.floorMod(UUID.randomUUID().hashCode(),1000000000));
    var result = mvc.perform(post("/api/v1/tenants").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"Family\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
        .andExpect(status().isCreated()).andReturn();
    tenant = json.readTree(result.getResponse().getContentAsString()).path("id").asText();
    verifiedDevice = activeDevice(tenant);
  }

  @Test
  void closingSalesStopsReadyAttemptReplayButKeepsOriginalPaymentVerificationAvailable() throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);
    when(gateway.available()).thenReturn(false);
    mvc.perform(post(base()+"/orders/"+id+"/payment-attempts").with(actor(owner)).header("Idempotency-Key","attempt-"+id)
        .contentType(MediaType.APPLICATION_JSON).content("{}")).andExpect(status().isServiceUnavailable());
    verify(gateway,times(1)).createAppPayment(any());
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("PAYMENT_PENDING");
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(payment(id,1900,"tx-"+id));
    verifyPayment(id,200);
    assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isEqualTo(3);
  }

  @Test
  void closingSalesRedactsOldPaymentParametersWithoutChangingAttemptFacts() throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);
    when(gateway.available()).thenReturn(false);
    JsonNode attempt=body(mvc.perform(get(base()+"/orders/"+id+"/payment-attempts").with(actor(owner)))
        .andExpect(status().isOk()).andReturn()).path("items").get(0);
    assertThat(attempt.path("status").asText()).isEqualTo("READY");
    assertThat(attempt.path("parameters").isObject()).isTrue();assertThat(attempt.path("parameters").isEmpty()).isTrue();
    assertThat(jdbc.queryForObject("SELECT provider_payload FROM family_payment_attempts WHERE order_id=?",String.class,id))
        .contains("test-external-prepay");
    verify(gateway,times(1)).createAppPayment(any());
  }

  @Test
  void closingSalesWhileProviderRespondsKeepsAnUncertainAttemptWithoutReturningPaymentParameters() throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();
    var open=new java.util.concurrent.atomic.AtomicBoolean(true);
    when(gateway.available()).thenAnswer(call->open.get());
    when(gateway.createAppPayment(any())).thenAnswer(call->{
      open.set(false);return new FamilyPaymentGateway.AppPayment(Map.of("prepayid","test-external-prepay"));
    });
    mvc.perform(post(base()+"/orders/"+id+"/payment-attempts").with(actor(owner)).header("Idempotency-Key","attempt-"+id)
        .contentType(MediaType.APPLICATION_JSON).content("{}")).andExpect(status().isServiceUnavailable());
    assertThat(jdbc.queryForObject("SELECT status FROM family_payment_attempts WHERE order_id=?",String.class,id)).isEqualTo("INITIATED");
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("PAYMENT_PENDING");
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_payment_attempts WHERE order_id=?",Integer.class,id)).isEqualTo(1);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(payment(id,1900,"tx-"+id));
    verifyPayment(id,200);assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isEqualTo(3);
  }

  @Test
  void aCreatedOrderWithImportedProviderIdentityCannotBeLocallyExpired()throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();
    jdbc.update("UPDATE family_orders SET provider_transaction_id=? WHERE id=?","tx-imported",id);
    when(clock.millis()).thenReturn(now+900001);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(
        new FamilyPaymentGateway.PaymentEvidence(FamilySubscriptionService.merchantId(id),null,1900,"CNY","NOTPAY",0,"b".repeat(64)));
    maintenance("reconcileOrder",tenant,id);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("CREATED");
    verify(gateway,times(2)).queryPayment(FamilySubscriptionService.merchantId(id));
  }

  @Test
  void expiredOrderThatNeverReservedPaymentIsReleasedWithoutInventingAProviderClose()throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();when(clock.millis()).thenReturn(now+900001);
    maintenance("reconcileOrder",tenant,id);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("EXPIRED");
    verify(gateway,never()).queryPayment(anyString());verify(gateway,never()).closePayment(anyString());
    mvc.perform(post(base()+"/orders/"+id+"/payment-attempts").with(actor(owner)).header("Idempotency-Key","expired-attempt")
        .contentType(MediaType.APPLICATION_JSON).content("{}")).andExpect(status().isConflict());
    assertThat(order("FAMILY_YEAR").path("id").asText()).isNotEqualTo(id);
  }

  @Test
  void overdueAutomaticCloseRequiresTheFinalProviderClosedEvidence() throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);
    when(clock.millis()).thenReturn(now+900001);
    var notPaid=new FamilyPaymentGateway.PaymentEvidence(FamilySubscriptionService.merchantId(id),null,1900,"CNY","NOTPAY",0,"b".repeat(64));
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenAnswer(call->{
      assertThat(org.springframework.transaction.support.TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
      return notPaid;
    });
    maintenance("reconcileOrder",tenant,id);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("PAYMENT_PENDING");
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(new FamilyPaymentGateway.PaymentEvidence(
        FamilySubscriptionService.merchantId(id),null,1900,"CNY","CLOSED",0,"c".repeat(64)));
    maintenance("enqueueOrderVerification",tenant,id);maintenance("reconcileOrder",tenant,id);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("CLOSED");
    assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isZero();
  }

  @Test void uncertainCloseFollowedByVerifiedPaymentGrantsOnlyTheOriginalFrozenPeriod()throws Exception {
    var original=order("FAMILY_MONTH");String id=original.path("id").asText();preparePayment(id);
    when(clock.millis()).thenReturn(now+900001);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(
        new FamilyPaymentGateway.PaymentEvidence(FamilySubscriptionService.merchantId(id),null,1900,"CNY","NOTPAY",0,"b".repeat(64)),
        payment(id,1900,"tx-"+id));
    doThrow(new DomainException(HttpStatus.SERVICE_UNAVAILABLE,"FAMILY_PAYMENT_UNAVAILABLE")).when(gateway).closePayment(anyString());
    maintenance("reconcileOrder",tenant,id);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("PAID");
    assertThat(jdbc.queryForObject("SELECT period_end FROM family_orders WHERE id=?",Long.class,id)).isEqualTo(original.path("periodEnd").asLong());
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
  }

  @Test void unknownFinalCloseResultKeepsTheOrderPendingAndPersistsRetry()throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);when(clock.millis()).thenReturn(now+900001);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(
        new FamilyPaymentGateway.PaymentEvidence(FamilySubscriptionService.merchantId(id),null,1900,"CNY","NOTPAY",0,"b".repeat(64)),null);
    maintenance("reconcileOrder",tenant,id);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("PAYMENT_PENDING");
    var work=jdbc.queryForMap("SELECT state,last_code,lease_until FROM family_commerce_work WHERE entity_id=?",id);
    assertThat(work.get("state")).isEqualTo("READY");assertThat(work.get("lease_until")).isEqualTo(0L);
    assertThat(work.get("last_code")).isEqualTo("FAMILY_PAYMENT_UNAVAILABLE");
  }

  @Test void optionalAmountCanConfirmUnpaidCloseButCanNeverConfirmSuccessfulPayment()throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);when(clock.millis()).thenReturn(now+900001);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(
        new FamilyPaymentGateway.PaymentEvidence(FamilySubscriptionService.merchantId(id),null,null,null,"NOTPAY",0,"b".repeat(64)),
        new FamilyPaymentGateway.PaymentEvidence(FamilySubscriptionService.merchantId(id),null,null,null,"CLOSED",0,"c".repeat(64)));
    maintenance("reconcileOrder",tenant,id);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("CLOSED");
    String next=order("FAMILY_MONTH").path("id").asText();preparePayment(next);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(next))).thenReturn(
        new FamilyPaymentGateway.PaymentEvidence(FamilySubscriptionService.merchantId(next),"tx-"+next,null,"CNY","SUCCESS",now+900001,"b".repeat(64)));
    verifyPayment(next,409);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,next)).isEqualTo("PAYMENT_PENDING");
    assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isZero();
  }

  @Test void staleLeaseGenerationCannotApplyAnOldPaidResponse()throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenAnswer(call->{
      jdbc.update("UPDATE family_commerce_work SET generation=generation+1 WHERE entity_id=?",id);
      return payment(id,1900,"tx-"+id);
    });
    maintenance("reconcileOrder",tenant,id);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("PAYMENT_PENDING");
    assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isZero();
  }

  @Test void paymentCallbackDuringCloseCannotBeDowngradedByAnEarlierClosedSnapshot()throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);when(clock.millis()).thenReturn(now+900001);
    String raw="{\"id\":\"paid-during-close\"}";
    when(gateway.verifyNotification(anyMap(),eq(raw))).thenReturn(new FamilyPaymentGateway.Notification("race-"+id,"PAYMENT",FamilySubscriptionService.hash(raw),payment(id,1900,"tx-"+id),null));
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenAnswer(call->{
      callback(raw,200);
      return new FamilyPaymentGateway.PaymentEvidence(FamilySubscriptionService.merchantId(id),null,1900,"CNY","CLOSED",0,"b".repeat(64));
    });
    maintenance("reconcileOrder",tenant,id);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("PAID");
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
  }

  @Test void lateSignedPaymentAfterLocalCloseStillRecordsMoneyAndPreservesFrozenDates()throws Exception {
    JsonNode original=order("FAMILY_MONTH");String id=original.path("id").asText();preparePayment(id);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(new FamilyPaymentGateway.PaymentEvidence(FamilySubscriptionService.merchantId(id),null,1900,"CNY","CLOSED",0,"b".repeat(64)));verifyPayment(id,200);
    String raw="{\"id\":\"late-paid\"}";
    when(gateway.verifyNotification(anyMap(),eq(raw))).thenReturn(new FamilyPaymentGateway.Notification("late-"+id,"PAYMENT",FamilySubscriptionService.hash(raw),payment(id,1900,"tx-"+id),null));
    callback(raw,200);callback(raw,200);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("PAID");
    assertThat(jdbc.queryForObject("SELECT period_end FROM family_orders WHERE id=?",Long.class,id)).isEqualTo(original.path("periodEnd").asLong());
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
  }

  @Test void concurrentMaintenanceInstancesShareOneDurableLease()throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);
    var entered=new java.util.concurrent.CountDownLatch(1);var release=new java.util.concurrent.CountDownLatch(1);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenAnswer(call->{
      assertThat(org.springframework.transaction.support.TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
      entered.countDown();if(!release.await(5,java.util.concurrent.TimeUnit.SECONDS))throw new IllegalStateException("test release timeout");
      return payment(id,1900,"tx-"+id);
    });
    var pool=java.util.concurrent.Executors.newSingleThreadExecutor();
    try {
      var first=pool.submit(()->{try{maintenance("reconcileOrder",tenant,id);}catch(Exception error){throw new IllegalStateException(error);}});
      assertThat(entered.await(5,java.util.concurrent.TimeUnit.SECONDS)).isTrue();
      // 另一个实例共用数据库，不能在前一实例持租约时发出第二个网络请求。
      var second=new FamilyCommerceMaintenance(jdbc,context.getBean(FamilySubscriptionService.class),gateway,clock,context.getBean(org.springframework.transaction.PlatformTransactionManager.class));
      second.reconcileOrder(tenant,id);release.countDown();first.get(5,java.util.concurrent.TimeUnit.SECONDS);
      verify(gateway,times(1)).queryPayment(FamilySubscriptionService.merchantId(id));
      assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isEqualTo(3);
    } finally {release.countDown();pool.shutdownNow();}
  }

  @Test void approvedRefundUnknownSubmissionQueriesAndRetriesTheSameRefundIdentityOnly()throws Exception {
    String order=paidOrder();String id=refund(order,"approved-unknown").path("id").asText();approveForMaintenance(id);
    doThrow(new DomainException(HttpStatus.SERVICE_UNAVAILABLE,"FAMILY_PAYMENT_UNAVAILABLE")).doNothing().when(gateway).submitRefund(any());
    maintenance("reconcileRefund",tenant,id);
    assertThat(jdbc.queryForObject("SELECT status FROM family_refund_requests WHERE id=?",String.class,id)).isEqualTo("REQUESTED");
    when(clock.millis()).thenReturn(now+60001);
    when(gateway.queryRefund(FamilySubscriptionService.merchantId(id))).thenThrow(new FamilyPaymentGateway.ResourceMissing());
    maintenance("reconcileRefund",tenant,id);
    var captured=org.mockito.ArgumentCaptor.forClass(FamilyPaymentGateway.RefundCommand.class);verify(gateway,times(2)).submitRefund(captured.capture());
    assertThat(captured.getAllValues().get(0)).isEqualTo(captured.getAllValues().get(1));
    assertThat(captured.getValue().merchantRefundId()).isEqualTo(FamilySubscriptionService.merchantId(id));
    assertThat(jdbc.queryForObject("SELECT status FROM family_refund_requests WHERE id=?",String.class,id)).isEqualTo("PROCESSING");
    assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isEqualTo(3);
  }

  @Test void unknownRefundQueryDoesNotResubmitAndManualDeclineNeverSubmits()throws Exception {
    String order=paidOrder();String id=refund(order,"unknown-query").path("id").asText();approveForMaintenance(id);
    doThrow(new DomainException(HttpStatus.SERVICE_UNAVAILABLE,"FAMILY_PAYMENT_UNAVAILABLE")).when(gateway).submitRefund(any());
    maintenance("reconcileRefund",tenant,id);when(clock.millis()).thenReturn(now+60001);
    when(gateway.queryRefund(FamilySubscriptionService.merchantId(id))).thenReturn(null);maintenance("reconcileRefund",tenant,id);
    verify(gateway,times(1)).submitRefund(any());
    jdbc.update("UPDATE family_refund_requests SET status='DECLINED' WHERE id=?",id);
    maintenance("enqueueRefundVerification",tenant,id);maintenance("reconcileRefund",tenant,id);
    verify(gateway,times(1)).submitRefund(any());
    assertThat(jdbc.queryForObject("SELECT status FROM family_refund_requests WHERE id=?",String.class,id)).isEqualTo("DECLINED");
  }

  @Test void verifiedRefundAcceptanceTimeIsImmutableAndSeparateFromReviewAndSettlementTime()throws Exception {
    String order=paidOrder();String id=refund(order,"accepted-time").path("id").asText();approveForMaintenance(id);
    when(clock.millis()).thenReturn(now+120000);
    var processing=new FamilyPaymentGateway.RefundEvidence(FamilySubscriptionService.merchantId(id),FamilySubscriptionService.merchantId(order),
        "rf-"+id,"tx-"+order,1900,"CNY","PROCESSING",0,"c".repeat(64),now+60000);
    when(gateway.queryRefund(FamilySubscriptionService.merchantId(id))).thenReturn(processing);
    mvc.perform(post(base()+"/refund-requests/"+id+"/verifications").with(actor(owner)).contentType(MediaType.APPLICATION_JSON).content("{}"))
        .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("PROCESSING"));
    assertThat(jdbc.queryForObject("SELECT provider_accepted_at FROM family_refund_requests WHERE id=?",Long.class,id)).isEqualTo(now+60000);
    when(gateway.queryRefund(FamilySubscriptionService.merchantId(id))).thenReturn(new FamilyPaymentGateway.RefundEvidence(
        processing.merchantRefundId(),processing.merchantOrderId(),processing.providerRefundId(),processing.providerTransactionId(),1900,"CNY","SUCCESS",now+120000,"d".repeat(64),now+61000));
    mvc.perform(post(base()+"/refund-requests/"+id+"/verifications").with(actor(owner)).contentType(MediaType.APPLICATION_JSON).content("{}"))
        .andExpect(status().isConflict());
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,order)).isEqualTo("PAID");
    assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isEqualTo(3);
  }

  @Test void awaitingReviewRefundCannotBeAutoApprovedAndWorkerIsDisabledByDefault()throws Exception {
    String order=paidOrder();String id=refund(order,"awaiting-review").path("id").asText();
    context.getBean(FamilyCommerceMaintenance.class).sweep(10);
    verify(gateway,never()).submitRefund(any());
    assertThat(jdbc.queryForObject("SELECT status FROM family_refund_requests WHERE id=?",String.class,id)).isEqualTo("AWAITING_REVIEW");
    assertThat(context.getBeansOfType(FamilyCommerceMaintenanceWorker.class)).isEmpty();
  }

  @Test void aMaintenanceBatchLimitAppliesAcrossOrdersRefundsAndOperatorQueue()throws Exception {
    String order=paidOrder();String refund=refund(order,"bounded-worker").path("id").asText();approveForMaintenance(refund);
    maintenance("enqueueOrderVerification",tenant,order);
    assertThat(context.getBean(FamilyCommerceMaintenance.class).sweep(1)).isLessThanOrEqualTo(1);
  }

  @Test void aCallerCannotAccidentallyWrapMaintenanceNetworkWorkInItsOwnTransaction()throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(payment(id,1900,"tx-"+id));
    var outer=new org.springframework.transaction.support.TransactionTemplate(context.getBean(org.springframework.transaction.PlatformTransactionManager.class));
    org.assertj.core.api.Assertions.assertThatThrownBy(()->outer.executeWithoutResult(status->context.getBean(FamilyCommerceMaintenance.class).reconcileOrder(tenant,id)))
        .isInstanceOf(org.springframework.transaction.IllegalTransactionStateException.class);
    verify(gateway,never()).queryPayment(anyString());
  }

  private String paidOrder()throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(payment(id,1900,"tx-"+id));verifyPayment(id,200);return id;
  }
  private void approveForMaintenance(String id) {
    jdbc.update("UPDATE family_refund_requests SET status='REQUESTED',reviewed_at=?,reviewed_by=? WHERE id=?",now,"e".repeat(64),id);
  }

  private void maintenance(String method,String family,String id) throws Exception {
    Class<?> type;
    try {type=Class.forName("com.aimanager.commerce.internal.FamilyCommerceMaintenance");}
    catch(ClassNotFoundException absent){throw new AssertionError("持久关单与退款维护入口尚未实现",absent);}
    var operation=type.getDeclaredMethod(method,String.class,String.class);operation.setAccessible(true);
    try{operation.invoke(context.getBean(type),family,id);}catch(java.lang.reflect.InvocationTargetException failure){
      if(failure.getCause() instanceof Exception error)throw error;throw failure;
    }
  }

  @Test
  void providerVerificationNeverHoldsTheFamilyDatabaseTransaction() throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenAnswer(call->{
      assertThat(org.springframework.transaction.support.TransactionSynchronizationManager.isActualTransactionActive())
          .as("网络查单不能持有家庭账户事务").isFalse();
      return payment(id,1900,"tx-"+id);
    });
    verifyPayment(id,200);
    assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isEqualTo(3);
  }

  @Test
  void verifiedServerQueryGrantsExactlyFrozenPeriodAndNeverClientAmount() throws Exception {
    JsonNode order = order("FAMILY_MONTH");
    String id = order.path("id").asText();
    preparePayment(id);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(payment(id, 1901, "tx-bad"));
    verifyPayment(id, 409);
    assertThat(ledger.read(tenant, owner).paidDeviceCapacity()).isZero();
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(payment(id, 1900, "tx-" + id));
    verifyPayment(id, 200);
    verifyPayment(id, 200);
    assertThat(ledger.read(tenant, owner).paidDeviceCapacity()).isEqualTo(3);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?", Integer.class, tenant)).isEqualTo(1);
    assertThat(jdbc.queryForObject("SELECT expires_at FROM commercial_sources WHERE tenant_id=? AND source_system='WECHAT_PAY'", Long.class, tenant))
        .isEqualTo(Instant.parse("2026-02-28T02:00:00Z").toEpochMilli());
    mvc.perform(get(base() + "/subscription").with(actor(owner))).andExpect(status().isOk())
        .andExpect(jsonPath("$.status").value("ACTIVE"));
  }

  @Test
  void signedNotificationDedupesAndInvalidSignatureOrAmountLeavesNoInboxOrRights() throws Exception {
    String id = order("FAMILY_MONTH").path("id").asText();
    preparePayment(id);
    String invalid = "{\"id\":\"invalid\"}";
    when(gateway.verifyNotification(anyMap(), eq(invalid))).thenThrow(new DomainException(HttpStatus.UNAUTHORIZED, "WECHAT_SIGNATURE_INVALID"));
    callback(invalid, 401);
    String bad = "{\"id\":\"bad-amount\"}";
    when(gateway.verifyNotification(anyMap(), eq(bad))).thenReturn(new FamilyPaymentGateway.Notification("bad-" + id, "PAYMENT",
        FamilySubscriptionService.hash(bad), payment(id, 9, "tx-bad"), null));
    callback(bad, 409);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_payment_inbox WHERE order_id=?", Integer.class, id)).isZero();
    assertThat(ledger.read(tenant, owner).paidDeviceCapacity()).isZero();
    String valid = "{\"id\":\"valid\"}";
    when(gateway.verifyNotification(anyMap(), eq(valid))).thenReturn(new FamilyPaymentGateway.Notification("event-" + id, "PAYMENT",
        FamilySubscriptionService.hash(valid), payment(id, 1900, "tx-" + id), null));
    callback(valid, 200);
    callback(valid, 200);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_payment_inbox WHERE order_id=?", Integer.class, id)).isEqualTo(1);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?", Integer.class, tenant)).isEqualTo(1);
  }

  @Test
  void actualActivationStartsSevenDaysAtObservedInstantOnceAndRefundCannotRevokeTrial() throws Exception {
    String subject = UUID.randomUUID().toString();
    String device = UUID.randomUUID().toString();
    String registration = UUID.randomUUID().toString();
    jdbc.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,?,'UNDER_13',?)", tenant, subject, "Child", now - 200000);
    jdbc.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
        + " VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}',?,?)", tenant, device, subject, registration, "Phone", "a".repeat(64), now-200000);
    long activatedAt = now-100000;
    when(activationGate.verify(tenant, device)).thenReturn(new FamilyAssistedActivationGate.VerifiedActivation(tenant, device, registration, activatedAt, "a".repeat(64)));
    mvc.perform(post(base() + "/subscription/trial").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"deviceId\":\"" + device + "\"}"))
        .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("TRIAL"))
        .andExpect(jsonPath("$.periodStart").value(activatedAt)).andExpect(jsonPath("$.periodEnd").value(activatedAt+604800000));
    mvc.perform(post(base() + "/subscription/trial").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"deviceId\":\"" + device + "\"}"))
        .andExpect(status().isOk());
    JsonNode order = order("FAMILY_MONTH");
    assertThat(order.path("periodStart").asLong()).isEqualTo(activatedAt+604800000);
    String id = order.path("id").asText();
    preparePayment(id);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(payment(id, 1900, "tx-" + id));
    verifyPayment(id, 200);
    JsonNode refund = refund(id, "refund-one");
    when(gateway.queryRefund(FamilySubscriptionService.merchantId(refund.path("id").asText())))
        .thenReturn(new FamilyPaymentGateway.RefundEvidence(FamilySubscriptionService.merchantId(refund.path("id").asText()),
            FamilySubscriptionService.merchantId(id), "refund-provider-" + id, "tx-" + id, 1900, "CNY", "SUCCESS", now, "c".repeat(64)));
    mvc.perform(post(base() + "/refund-requests/" + refund.path("id").asText() + "/verifications").with(actor(owner))
        .contentType(MediaType.APPLICATION_JSON).content("{}")).andExpect(status().isOk());
    assertThat(ledger.read(tenant, owner).paidDeviceCapacity()).isEqualTo(3);
    assertThat(jdbc.queryForObject("SELECT state FROM commercial_sources WHERE tenant_id=? AND source_system='TRIAL'", String.class, tenant)).isEqualTo("ACTIVE");
    assertThat(jdbc.queryForObject("SELECT state FROM commercial_sources WHERE tenant_id=? AND source_system='WECHAT_PAY'", String.class, tenant)).isEqualTo("REVOKED");
  }

  @Test
  void refundKeepsLaterRenewalPeriodFrozenAndRequiresOriginalSourceAmount() throws Exception {
    String firstId = order("FAMILY_MONTH").path("id").asText();
    preparePayment(firstId);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(firstId))).thenReturn(payment(firstId, 1900, "tx-"+firstId));
    verifyPayment(firstId, 200);
    JsonNode second = order("FAMILY_YEAR");
    assertThat(second.path("periodStart").asLong()).isEqualTo(Instant.parse("2026-02-28T02:00:00Z").toEpochMilli());
    String secondId = second.path("id").asText();
    preparePayment(secondId);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(secondId))).thenReturn(payment(secondId, 19900, "tx-"+secondId));
    verifyPayment(secondId, 200);
    JsonNode request = refund(firstId, "refund-order");
    assertThat(refund(firstId, "refund-order").path("id").asText()).isEqualTo(request.path("id").asText());
    String refundId = request.path("id").asText();
    when(gateway.queryRefund(FamilySubscriptionService.merchantId(refundId))).thenReturn(new FamilyPaymentGateway.RefundEvidence(
        FamilySubscriptionService.merchantId(refundId), FamilySubscriptionService.merchantId(firstId), "rf-" + firstId, "tx-"+firstId,
        1, "CNY", "SUCCESS", now, "d".repeat(64)));
    mvc.perform(post(base()+"/refund-requests/"+refundId+"/verifications").with(actor(owner)).contentType(MediaType.APPLICATION_JSON).content("{}"))
        .andExpect(status().isConflict());
    assertThat(ledger.read(tenant, owner).paidDeviceCapacity()).isEqualTo(3);
    when(gateway.queryRefund(FamilySubscriptionService.merchantId(refundId))).thenReturn(new FamilyPaymentGateway.RefundEvidence(
        FamilySubscriptionService.merchantId(refundId), FamilySubscriptionService.merchantId(firstId), "rf-" + firstId, "tx-"+firstId,
        1900, "CNY", "SUCCESS", now, "d".repeat(64)));
    mvc.perform(post(base()+"/refund-requests/"+refundId+"/verifications").with(actor(owner)).contentType(MediaType.APPLICATION_JSON).content("{}"))
        .andExpect(status().isOk());
    assertThat(ledger.read(tenant, owner).paidDeviceCapacity()).isZero();
    mvc.perform(get(base()+"/orders/"+secondId).with(actor(owner))).andExpect(status().isOk())
        .andExpect(jsonPath("$.periodStart").value(second.path("periodStart").asLong()))
        .andExpect(jsonPath("$.periodEnd").value(second.path("periodEnd").asLong()));
  }

  @Test void immediateVerifiedRefundAnchorsGraceToProviderTimeEvenWhenFirstReadIsDaysLate()throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(payment(id,1900,"tx-"+id));verifyPayment(id,200);
    String refundId=refund(id,"precise-refund-anchor").path("id").asText();
    when(gateway.queryRefund(FamilySubscriptionService.merchantId(refundId))).thenReturn(new FamilyPaymentGateway.RefundEvidence(
        FamilySubscriptionService.merchantId(refundId),FamilySubscriptionService.merchantId(id),"rf-"+id,"tx-"+id,1900,"CNY","SUCCESS",now,"d".repeat(64)));
    when(clock.millis()).thenReturn(now+3*86400000L);when(clock.instant()).thenReturn(Instant.ofEpochMilli(now+3*86400000L));
    mvc.perform(post(base()+"/refund-requests/"+refundId+"/verifications").with(actor(owner)).contentType(MediaType.APPLICATION_JSON).content("{}"))
        .andExpect(status().isOk());
    mvc.perform(get(base()+"/family-device-access").with(actor(owner))).andExpect(status().isOk())
        .andExpect(jsonPath("$.status").value("GRACE")).andExpect(jsonPath("$.graceEndsAt").value(now+7*86400000L));
    when(clock.millis()).thenReturn(now+4*86400000L);when(clock.instant()).thenReturn(Instant.ofEpochMilli(now+4*86400000L));
    mvc.perform(post(base()+"/refund-requests/"+refundId+"/verifications").with(actor(owner)).contentType(MediaType.APPLICATION_JSON).content("{}"))
        .andExpect(status().isOk());
    mvc.perform(get(base()+"/family-device-access").with(actor(owner))).andExpect(status().isOk())
        .andExpect(jsonPath("$.graceEndsAt").value(now+7*86400000L));
    assertThat(jdbc.queryForObject("SELECT refunded_at FROM family_refund_requests WHERE id=?",Long.class,refundId)).isEqualTo(now);
    assertThat(jdbc.queryForObject("SELECT state FROM devices WHERE tenant_id=? AND id=?",String.class,tenant,verifiedDevice)).isEqualTo("ACTIVE");
  }

  @Test void acceptedRefundWithProviderClockSkewCannotKeepCurrentMemberAccess()throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(payment(id,1900,"tx-"+id));verifyPayment(id,200);
    String refundId=refund(id,"refund-clock-skew").path("id").asText();
    when(gateway.queryRefund(FamilySubscriptionService.merchantId(refundId))).thenReturn(new FamilyPaymentGateway.RefundEvidence(
        FamilySubscriptionService.merchantId(refundId),FamilySubscriptionService.merchantId(id),"rf-"+id,"tx-"+id,1900,"CNY","SUCCESS",now+120000,"d".repeat(64)));
    mvc.perform(post(base()+"/refund-requests/"+refundId+"/verifications").with(actor(owner)).contentType(MediaType.APPLICATION_JSON).content("{}"))
        .andExpect(status().isOk());
    mvc.perform(get(base()+"/family-device-access").with(actor(owner))).andExpect(status().isOk())
        .andExpect(jsonPath("$.status").value("GRACE")).andExpect(jsonPath("$.graceEndsAt").value(now+7*86400000L));
    assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isZero();
  }

  @Test
  void uncertainPrepayPersistsMerchantIdentityAndBlocksOverlappingPurchaseUntilProviderCloses() throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();
    when(gateway.createAppPayment(any())).thenThrow(new DomainException(HttpStatus.SERVICE_UNAVAILABLE,"FAMILY_PAYMENT_UNAVAILABLE"));
    mvc.perform(post(base()+"/orders/"+id+"/payment-attempts").with(actor(owner)).header("Idempotency-Key","timeout-attempt")
        .contentType(MediaType.APPLICATION_JSON).content("{}")).andExpect(status().isServiceUnavailable());
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("PAYMENT_PENDING");
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_payment_attempts WHERE order_id=?",Integer.class,id)).isEqualTo(1);
    when(clock.millis()).thenReturn(now+3600000);
    mvc.perform(post(base()+"/orders").with(actor(owner)).header("Idempotency-Key","another-order")
        .contentType(MediaType.APPLICATION_JSON).content("{\"planKey\":\"FAMILY_YEAR\"}")).andExpect(status().isConflict());
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(new FamilyPaymentGateway.PaymentEvidence(
        FamilySubscriptionService.merchantId(id),null,1900,"CNY","CLOSED",0,"b".repeat(64)));
    verifyPayment(id,200);
    order("FAMILY_YEAR");
    assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isZero();
  }

  @Test
  void auditFailureRollsBackInboxOrderAndLedgerThenSameNotificationCanRetry() throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();
    preparePayment(id);
    String raw="{\"id\":\"rollback\"}";
    when(gateway.verifyNotification(anyMap(),eq(raw))).thenReturn(new FamilyPaymentGateway.Notification("rollback-"+id,"PAYMENT",
        FamilySubscriptionService.hash(raw),payment(id,1900,"tx-"+id),null));
    AuditService target=AopTestUtils.getTargetObject(audit);
    doThrow(new IllegalStateException("audit unavailable")).doCallRealMethod().when(target)
        .record(tenant,"system:wechat-v3","FAMILY_PAYMENT_VERIFIED",id);
    callback(raw,500);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?",String.class,id)).isEqualTo("PAYMENT_PENDING");
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_payment_inbox WHERE order_id=?",Integer.class,id)).isZero();
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?",Integer.class,tenant)).isZero();
    assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isZero();
    callback(raw,200);
    assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isEqualTo(3);
  }

  @Test
  void verifiedAbnormalRefundIsVisibleAndLeavesOriginalPaidSourceActive() throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();
    preparePayment(id);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(payment(id,1900,"tx-"+id));
    verifyPayment(id,200);
    String refundId=refund(id,"abnormal-refund").path("id").asText();
    String raw="{\"id\":\"refund-abnormal\"}";
    when(gateway.verifyNotification(anyMap(),eq(raw))).thenReturn(new FamilyPaymentGateway.Notification("abnormal-"+refundId,"REFUND",
        FamilySubscriptionService.hash(raw),null,new FamilyPaymentGateway.RefundEvidence(FamilySubscriptionService.merchantId(refundId),
            FamilySubscriptionService.merchantId(id),"rf-"+id,"tx-"+id,1900,"CNY","ABNORMAL",0,"c".repeat(64))));
    callback(raw,200);
    mvc.perform(get(base()+"/refund-requests/"+refundId).with(actor(owner))).andExpect(status().isOk())
        .andExpect(jsonPath("$.status").value("ABNORMAL"));
    assertThat(ledger.read(tenant,owner).paidDeviceCapacity()).isEqualTo(3);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
  }

  @Test
  void configuredMerchantCannotMakeAnUnverifiedFamilyPayable() throws Exception {
    when(activationGate.verify(anyString(),anyString())).thenThrow(new DomainException(HttpStatus.CONFLICT,"TRIAL_ACTIVATION_NOT_VERIFIED"));
    mvc.perform(get(base()+"/subscription-offers").with(actor(owner))).andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].paymentAvailable").value(false));
    mvc.perform(post(base()+"/orders").with(actor(owner)).header("Idempotency-Key","unverified")
        .contentType(MediaType.APPLICATION_JSON).content("{\"planKey\":\"FAMILY_MONTH\"}")).andExpect(status().isConflict());
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_orders WHERE tenant_id=?",Integer.class,tenant)).isZero();
  }

  @Test
  void verifiedActivationTrialRequiresTrustedVerifiedPhoneAndPersistsActorAndPhoneClaims() throws Exception {
    mvc.perform(post(base()+"/subscription/trial").with(jwt().jwt(token->token.subject(owner)))
        .contentType(MediaType.APPLICATION_JSON).content("{\"deviceId\":\""+verifiedDevice+"\"}"))
        .andExpect(status().is(428));
    mvc.perform(post(base()+"/subscription/trial").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"deviceId\":\""+verifiedDevice+"\"}")).andExpect(status().isOk());
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_trial_claims WHERE tenant_id=? AND claimed_at IS NOT NULL",Integer.class,tenant)).isEqualTo(2);
    String other=createAnotherFamily(owner);
    String device=activeDevice(other);
    phone="+8613"+String.format("%09d",Math.floorMod(UUID.randomUUID().hashCode(),1000000000));
    mvc.perform(post("/api/v1/tenants/"+other+"/subscription/trial").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"deviceId\":\""+device+"\"}")).andExpect(status().isConflict());
  }

  @Test
  void anotherActorUsingTheSameVerifiedPhoneCannotRestartTrialInAnotherFamily() throws Exception {
    mvc.perform(post(base()+"/subscription/trial").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"deviceId\":\""+verifiedDevice+"\"}")).andExpect(status().isOk());
    String another="second-owner-"+UUID.randomUUID();
    String other=createAnotherFamily(another);
    String device=activeDevice(other);
    mvc.perform(post("/api/v1/tenants/"+other+"/subscription/trial").with(actor(another)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"deviceId\":\""+device+"\"}")).andExpect(status().isConflict());
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_sources WHERE tenant_id=?",Integer.class,other)).isZero();
  }

  private JsonNode order(String plan) throws Exception {
    return body(mvc.perform(post(base()+"/orders").with(actor(owner)).header("Idempotency-Key", UUID.randomUUID().toString())
        .contentType(MediaType.APPLICATION_JSON).content("{\"planKey\":\""+plan+"\"}")).andExpect(status().isOk()).andReturn());
  }
  private JsonNode refund(String id, String key) throws Exception {
    return body(mvc.perform(post(base()+"/orders/"+id+"/refund-requests").with(actor(owner)).header("Idempotency-Key",key)
        .contentType(MediaType.APPLICATION_JSON).content("{\"reason\":\"Not needed\"}")).andExpect(status().isOk()).andReturn());
  }
  private void preparePayment(String id) throws Exception {
    mvc.perform(post(base()+"/orders/"+id+"/payment-attempts").with(actor(owner)).header("Idempotency-Key","attempt-"+id)
        .contentType(MediaType.APPLICATION_JSON).content("{}")).andExpect(status().isOk());
  }
  private void verifyPayment(String id, int expected) throws Exception {
    mvc.perform(post(base()+"/orders/"+id+"/payment-verifications").with(actor(owner)).contentType(MediaType.APPLICATION_JSON).content("{}"))
        .andExpect(status().is(expected));
  }
  private void callback(String raw, int expected) throws Exception {
    mvc.perform(post("/api/v1/payments/wechat/notifications").contentType(MediaType.APPLICATION_JSON).content(raw))
        .andExpect(status().is(expected));
  }
  private FamilyPaymentGateway.PaymentEvidence payment(String id, int amount, String transaction) {
    return new FamilyPaymentGateway.PaymentEvidence(FamilySubscriptionService.merchantId(id), transaction, amount, "CNY", "SUCCESS", now, "b".repeat(64));
  }
  private JsonNode body(org.springframework.test.web.servlet.MvcResult result) throws Exception { return json.readTree(result.getResponse().getContentAsString()); }
  private String base() { return "/api/v1/tenants/"+tenant; }
  private String createAnotherFamily(String actorId) throws Exception {
    var result=mvc.perform(post("/api/v1/tenants").with(actor(actorId)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"Another\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}")).andExpect(status().isCreated()).andReturn();
    return body(result).path("id").asText();
  }
  private String activeDevice(String family) {
    String subject=UUID.randomUUID().toString(),device=UUID.randomUUID().toString(),registration=UUID.randomUUID().toString();
    jdbc.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,?,'UNDER_13',?)",family,subject,"Child",now-200000);
    jdbc.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
        +" VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}',?,?)",family,device,subject,registration,"Phone","a".repeat(64),now-200000);
    when(activationGate.verify(family,device)).thenReturn(new FamilyAssistedActivationGate.VerifiedActivation(family,device,registration,now-100000,"a".repeat(64)));
    return device;
  }
  private RequestPostProcessor actor(String subject) {
    return jwt().jwt(token->token.subject(subject).claim("phone_number",phone).claim("phone_number_verified",true)
        .claim("auth_time",now/1000).claim("amr",java.util.List.of("sms")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }
  @Test void refundNeedsSeparateManualReviewAndFreshOwnerAuthentication()throws Exception {
    String id=order("FAMILY_MONTH").path("id").asText();preparePayment(id);
    when(gateway.queryPayment(FamilySubscriptionService.merchantId(id))).thenReturn(payment(id,1900,"tx-"+id));verifyPayment(id,200);
    mvc.perform(post(base()+"/orders/"+id+"/refund-requests").with(jwt().jwt(j->j.subject(owner)))
      .header("Idempotency-Key","stale-refund").contentType(MediaType.APPLICATION_JSON).content("{\"reason\":\"Not needed\"}"))
      .andExpect(status().isUnauthorized());
    String refund=refund(id,"manual-refund").path("id").asText();
    mvc.perform(post(base()+"/refund-requests/"+refund+"/submissions").with(actor(owner)).contentType(MediaType.APPLICATION_JSON).content("{}"))
      .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("REFUND_REVIEW_REQUIRED"));
    verify(gateway,never()).submitRefund(any());
    var ownerReviewer=jwt().jwt(j->j.subject(owner).claim("auth_time",now/1000).claim("amr",java.util.List.of("pwd","otp")))
      .authorities(new SimpleGrantedAuthority("SCOPE_family-refunds:review"));
    String reviewPath="/api/v1/platform/family-subscription/refund-requests/"+refund;
    JsonNode preview=body(mvc.perform(get(reviewPath+"/preview").with(ownerReviewer)).andExpect(status().isOk()).andReturn());
    String decision=json.writeValueAsString(Map.of("decision","APPROVE","previewHash",preview.path("previewHash").asText()));
    mvc.perform(post(reviewPath+"/reviews").with(ownerReviewer).header("Idempotency-Key","owner-self-review")
      .contentType(MediaType.APPLICATION_JSON).content(decision)).andExpect(status().isForbidden());
    var reviewer=jwt().jwt(j->j.subject("operator-"+UUID.randomUUID()).claim("auth_time",now/1000).claim("amr",java.util.List.of("pwd","otp")))
      .authorities(new SimpleGrantedAuthority("SCOPE_family-refunds:review"));
    mvc.perform(post(reviewPath+"/reviews").with(reviewer).header("Idempotency-Key","manual-approval")
      .contentType(MediaType.APPLICATION_JSON).content(decision)).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("REQUESTED"))
      .andExpect(jsonPath("$.externalRefundSubmitted").value(false));
    mvc.perform(post(reviewPath+"/reviews").with(reviewer).header("Idempotency-Key","manual-approval")
      .contentType(MediaType.APPLICATION_JSON).content(decision)).andExpect(status().isOk());
    mvc.perform(post(base()+"/refund-requests/"+refund+"/submissions").with(actor(owner)).contentType(MediaType.APPLICATION_JSON).content("{}"))
      .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("PROCESSING"));
    verify(gateway,times(1)).submitRefund(any());
  }
}
