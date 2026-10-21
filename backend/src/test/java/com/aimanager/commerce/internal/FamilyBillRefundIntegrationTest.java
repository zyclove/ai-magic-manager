package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.jdbc.Sql;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/** 使用实际订阅服务落退款事实，避免账单测试自造与业务不一致的状态。 */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:family-bill-refund;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=",
    "manager.exports.worker.enabled=false", "manager.report-jobs.worker.enabled=false",
    "manager.diagnostic-packages.worker.enabled=false", "manager.family.bills.worker.enabled=false"})
@Sql("/family/family-bill-reconciliation.sql")
class FamilyBillRefundIntegrationTest {
  @Autowired JdbcTemplate jdbc;
  @Autowired FamilySubscriptionService subscriptions;
  @Autowired FamilyBillReconciliationService bills;
  @Autowired PlatformTransactionManager transactions;
  @MockitoBean Clock clock;
  @MockitoBean JwtDecoder decoder;
  @MockitoBean FamilyBillGateway gateway;
  long now = Instant.parse("2026-10-16T03:00:00Z").toEpochMilli();

  @BeforeEach void configure() {
    jdbc.update("DELETE FROM family_refund_requests");
    jdbc.update("DELETE FROM family_orders");
    when(clock.millis()).thenReturn(now); when(clock.instant()).thenReturn(Instant.ofEpochMilli(now));
    when(clock.getZone()).thenReturn(ZoneId.of("UTC"));
    when(gateway.available()).thenReturn(true); when(gateway.merchantId()).thenReturn("1900000001"); when(gateway.appId()).thenReturn("wx-app");
  }

  @ParameterizedTest @ValueSource(strings = {"PROCESSING", "ABNORMAL", "CLOSED"})
  void actualRefundEvidenceWritesTheStatesAndAcceptedTimeRecognizedByBills(String status) {
    String tenant = UUID.randomUUID().toString(), order = UUID.randomUUID().toString(), refund = UUID.randomUUID().toString();
    long created = Instant.parse("2026-10-14T22:00:00Z").toEpochMilli();
    long paid = Instant.parse("2026-10-14T23:00:00Z").toEpochMilli();
    long accepted = Instant.parse("2026-10-15T00:10:00Z").toEpochMilli();
    jdbc.update("INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'账单测试','FAMILY','Asia/Shanghai',?)", tenant, created);
    jdbc.update("INSERT INTO family_orders(id,tenant_id,actor_key,key_hash,request_hash,plan_key,status,price_minor,currency,period_start,period_end,created_at,expires_at,provider_transaction_id,paid_at)"
        + " VALUES(?,?,?, ?,?,'FAMILY_MONTH','PAID',1900,'CNY',?,?,?,?,'tx-1',?)", order, tenant, "a".repeat(64), "b".repeat(64), "c".repeat(64), created, now + 2_000_000, created, created+900000, paid);
    jdbc.update("INSERT INTO family_refund_requests(id,tenant_id,order_id,actor_key,key_hash,request_hash,reason,status,price_minor,created_at,reviewed_at)"
        + " VALUES(?,?,?,?,?,?,'测试','REQUESTED',1900,?,?)", refund, tenant, order, "a".repeat(64), "d".repeat(64), "e".repeat(64), accepted-10000, accepted-5000);
    new TransactionTemplate(transactions).executeWithoutResult(tx -> {
      subscriptions.lockAccount(tenant);
      subscriptions.applyRefundEvidence(tenant, refund, new FamilyPaymentGateway.RefundEvidence(FamilySubscriptionService.merchantId(refund),
          FamilySubscriptionService.merchantId(order), "rf-1", "tx-1", 1900, "CNY", status, 0, "f".repeat(64), accepted));
    });
    assertThat(jdbc.queryForObject("SELECT status FROM family_refund_requests WHERE id=?", String.class, refund)).isEqualTo(status);
    assertThat(jdbc.queryForObject("SELECT provider_accepted_at FROM family_refund_requests WHERE id=?", Long.class, refund)).isEqualTo(accepted);
    String payment = FamilyTradeBillParserTest.payment(FamilySubscriptionService.merchantId(order), "tx-1").split("\n")[1].replace("23:59:59", "07:00:00");
    String row = "`2026-10-15 08:10:00,`wx-app,`1900000001,`0,`,`tx-1,`" + FamilySubscriptionService.merchantId(order)
        + ",`payer-private,`APP,`REFUND,`OTHERS,`CNY,`0.00,`0.00,`rf-1,`" + FamilySubscriptionService.merchantId(refund)
        + ",`19.00,`0.00,`ORIGINAL,`PROCESSING,`家庭会员,`,`-0.11,`0.60%,`0.00,`19.00,`";
    byte[] file = FamilyTradeBillParserTest.bytes(FamilyTradeBillParserTest.HEADER + "\n" + payment + "\n" + row + "\n" + FamilyTradeBillParserTest.FOOTER
        + "\n`2,`19.00,`19.00,`0.00,`0.00,`19.00,`19.00\n");
    when(gateway.download(FamilyTradeBillParserTest.DAY)).thenReturn(new FamilyBillGateway.BillFile(file, FamilyBillGateway.sha1(file)));
    var task = bills.enqueue(FamilyTradeBillParserTest.DAY);
    if (!"PENDING".equals(task.status())) bills.retry(task.id());
    var result = bills.run(task.id());
    assertThat(result.status()).isEqualTo("MATCHED");
    assertThat(result.matchedCount()).isEqualTo(2);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?", String.class, order)).isEqualTo("PAID");
  }
}
