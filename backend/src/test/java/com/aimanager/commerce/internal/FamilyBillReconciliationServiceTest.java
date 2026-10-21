package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.audit.AuditService;
import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.h2.jdbcx.JdbcDataSource;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;

class FamilyBillReconciliationServiceTest {
  JdbcTemplate jdbc;
  TestClock clock;
  FakeBillGateway gateway;
  FamilyBillReconciliationService service;
  String tenant = UUID.randomUUID().toString();
  String order = UUID.randomUUID().toString();
  LocalDate day = FamilyTradeBillParserTest.DAY;

  @BeforeEach void setup() {
    var dataSource = new JdbcDataSource();
    dataSource.setURL("jdbc:h2:mem:bills-" + UUID.randomUUID() + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE");
    jdbc = new JdbcTemplate(dataSource);
    jdbc.execute("CREATE TABLE family_orders(id VARCHAR(36) PRIMARY KEY,tenant_id VARCHAR(36),status VARCHAR(30),price_minor INT,currency VARCHAR(3),provider_transaction_id VARCHAR(80),paid_at BIGINT,created_at BIGINT)");
    jdbc.execute("CREATE TABLE family_refund_requests(id VARCHAR(36) PRIMARY KEY,tenant_id VARCHAR(36),order_id VARCHAR(36),status VARCHAR(30),price_minor INT,provider_refund_id VARCHAR(80),created_at BIGINT,reviewed_at BIGINT,refunded_at BIGINT,provider_accepted_at BIGINT)");
    jdbc.execute("CREATE TABLE audit_events(tenant_id VARCHAR(36) NOT NULL,id VARCHAR(36),actor_id VARCHAR(200),action VARCHAR(200),resource_id VARCHAR(100),correlation_id VARCHAR(100),occurred_at BIGINT)");
    new ResourceDatabasePopulator(new ClassPathResource("family/family-bill-reconciliation.sql")).execute(dataSource);
    clock = new TestClock(Instant.parse("2026-10-16T03:00:00Z").toEpochMilli());
    gateway = new FakeBillGateway();
    gateway.csv = FamilyTradeBillParserTest.payment(reference(order), "tx-1");
    service = new FamilyBillReconciliationService(jdbc, gateway, clock, new DataSourceTransactionManager(dataSource), new AuditService(jdbc, clock));
  }

  @Test void completeVerifiedFamilyBillMatchesKnownPaidOrdersAndDoesNotChangeThem() {
    paid("PAID", 1900, "tx-1");
    var first = service.enqueue(day);
    assertThat(service.enqueue(day).id()).isEqualTo(first.id());
    var result = service.run(first.id());
    assertThat(result.status()).isEqualTo("MATCHED");
    assertThat(result.matchedCount()).isEqualTo(1);
    assertThat(result.differenceCount()).isZero();
    assertThat(result.billHash()).hasSize(40);
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?", String.class, order)).isEqualTo("PAID");
  }

  @Test void repeatDayInsideControllerIdempotencyTransactionDoesNotPoisonOuterTransaction() {
    var outer = new org.springframework.transaction.support.TransactionTemplate(new DataSourceTransactionManager(jdbc.getDataSource()));
    outer.executeWithoutResult(status -> {
      String original = service.enqueue(day).id();
      assertThat(service.enqueue(day).id()).isEqualTo(original);
    });
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_bill_tasks", Integer.class)).isEqualTo(1);
  }

  @Test void permanentOperatorAuditJoinsTheSameShortTransactionAndNeedsNoFakeTenant() {
    var outer = new org.springframework.transaction.support.TransactionTemplate(new DataSourceTransactionManager(jdbc.getDataSource()));
    assertThatThrownBy(() -> outer.executeWithoutResult(status -> {
      var task = service.enqueue(day);
      service.recordOperatorAction(task.id(), null, "FAMILY_BILL_ENQUEUED", "operator-1");
      throw new IllegalStateException("force rollback");
    })).isInstanceOf(IllegalStateException.class);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_bill_tasks", Integer.class)).isZero();
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_bill_audit_events", Integer.class)).isZero();
    var task = service.enqueue(day);
    service.recordOperatorAction(task.id(), null, "FAMILY_BILL_ENQUEUED", "operator-1");
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_bill_audit_events WHERE task_id=?", Integer.class, task.id())).isEqualTo(1);
    assertThat(jdbc.queryForObject("SELECT actor_key FROM family_bill_audit_events WHERE task_id=?", String.class, task.id())).isEqualTo(com.aimanager.identity.ActorKeys.key("operator-1"));
  }

  @Test void exhaustedExpiredLeaseBecomesAttentionAndCannotStarveLaterTasks() {
    String exhausted = service.enqueue(day).id();
    var old = service.run(exhausted);
    jdbc.update("UPDATE family_bill_tasks SET status='RUNNING',attempt_count=50,lease_until=1,lease_token=?,updated_at=1 WHERE id=?", UUID.randomUUID().toString(), exhausted);
    jdbc.update("UPDATE family_bill_attempts SET status='RUNNING' WHERE id=?", old.latestAttemptId());
    var pending = service.enqueue(day.minusDays(1));
    assertThat(service.readyIds(1)).containsExactly(pending.id());
    assertThat(service.task(exhausted).status()).isEqualTo("ATTENTION");
    assertThat(service.task(exhausted).errorCode()).isEqualTo("BILL_ATTEMPTS_EXHAUSTED");
    assertThatThrownBy(() -> service.retry(exhausted)).isInstanceOf(com.aimanager.shared.DomainException.class);
  }

  @Test void providerPaidButLocalPendingNeedsTrustedQueryAndCannotGrantFromCsv() {
    paid("PAYMENT_PENDING", 1900, null);
    jdbc.update("UPDATE family_orders SET paid_at=NULL WHERE id=?", order);
    var result = service.run(service.enqueue(day).id());
    assertThat(result.status()).isEqualTo("DIFFERENCES");
    assertThat(service.differences(result.id(), 20, null).items()).extracting(FamilyBillReconciliationService.Difference::kind).contains("LOCAL_PAYMENT_UNCONFIRMED");
    assertThat(jdbc.queryForObject("SELECT status FROM family_orders WHERE id=?", String.class, order)).isEqualTo("PAYMENT_PENDING");
  }

  @Test void missingLocalPaidRowCannotBeHiddenByUnknownBusinessTraffic() {
    paid("PAID", 1900, "tx-1");
    gateway.csv = FamilyTradeBillParserTest.payment("c".repeat(32), "other-business");
    var result = service.run(service.enqueue(day).id());
    assertThat(result.status()).isEqualTo("DIFFERENCES");
    assertThat(result.ignoredCount()).isEqualTo(1);
    assertThat(service.differences(result.id(), 20, null).items()).extracting(FamilyBillReconciliationService.Difference::kind).contains("MISSING_PAYMENT_ROW", "UNMAPPED_PROVIDER_TRANSACTION");
  }

  @Test void unknownOtherBusinessRowsAreTraceableWithoutImportingOrAssumingFamilyOwnership() {
    gateway.csv = FamilyTradeBillParserTest.payment("c".repeat(32), "other-business");
    var result = service.run(service.enqueue(day).id());
    assertThat(result.status()).isEqualTo("PARTIAL");
    assertThat(result.ignoredCount()).isEqualTo(1);
    assertThat(result.differenceCount()).isEqualTo(1);
    var unmapped = service.differences(result.id(), 20, null).items().get(0);
    assertThat(unmapped.kind()).isEqualTo("UNMAPPED_PROVIDER_TRANSACTION");
    assertThat(unmapped.tenantId()).isNull();
    assertThat(unmapped.orderId()).isNull();
    assertThat(unmapped.rowHash()).hasSize(64);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_orders", Integer.class)).isZero();
  }

  @Test void unmappedBillFollowUpHasItsOwnImmutableAuditWithoutInventingATenant() {
    gateway.csv = FamilyTradeBillParserTest.payment("c".repeat(32), "other-business");
    var task = service.run(service.enqueue(day).id());
    var difference = service.differences(task.id(), 20, null).items().get(0);
    service.acknowledge(task.id(), difference.id(), "另一业务待确认", "operator-1");
    service.acknowledge(task.id(), difference.id(), "另一业务待确认", "operator-1");
    assertThat(service.difference(task.id(), difference.id()).state()).isEqualTo("ACKNOWLEDGED");
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_bill_audit_events WHERE difference_id=?", Integer.class, difference.id())).isEqualTo(1);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM audit_events", Integer.class)).isZero();
    assertThat(service.task(task.id()).status()).isEqualTo("PARTIAL");
  }

  @Test void knownOrderWrongMerchantAppAmountAndDateAreDifferences() {
    paid("PAID", 19900, "tx-1");
    gateway.csv = gateway.csv.replace("wx-app", "wrong-app").replace("1900000001", "1900000002").replace("2026-10-15 23:59:59", "2026-10-14 23:59:59");
    var result = service.run(service.enqueue(day).id());
    assertThat(service.differences(result.id(), 20, null).items()).extracting(FamilyBillReconciliationService.Difference::kind)
        .contains("MERCHANT_OR_APP_MISMATCH", "AMOUNT_MISMATCH", "BILL_DATE_MISMATCH");
  }

  @Test void duplicateProviderTransactionCannotBeSilentlyDeduplicated() {
    paid("PAID", 1900, "tx-1");
    var lines = gateway.csv.split("\n");
    gateway.csv = lines[0] + "\n" + lines[1] + "\n" + lines[1] + "\n" + lines[2] + "\n`2,`38.00,`0.00,`0.00,`0.22,`38.00,`0.00\n";
    var result = service.run(service.enqueue(day).id());
    assertThat(service.differences(result.id(), 20, null).items()).extracting(FamilyBillReconciliationService.Difference::kind).contains("DUPLICATE_TRANSACTION");
  }

  @Test void duplicateUnmappedProviderTransactionIsVisibleWithoutInventingFamilyOwnership() {
    var lines = FamilyTradeBillParserTest.payment("c".repeat(32), "other-business").split("\n");
    gateway.csv = lines[0] + "\n" + lines[1] + "\n" + lines[1] + "\n" + lines[2] + "\n`2,`38.00,`0.00,`0.00,`0.22,`38.00,`0.00\n";
    var result = service.run(service.enqueue(day).id());
    assertThat(service.differences(result.id(), 20, null).items()).extracting(FamilyBillReconciliationService.Difference::kind).contains("DUPLICATE_TRANSACTION");
    assertThat(service.differences(result.id(), 20, null).items()).allSatisfy(item -> assertThat(item.tenantId()).isNull());
    assertThat(result.status()).isEqualTo("DIFFERENCES");
  }

  @Test void unknownHistoricRefundAcceptedDateCannotBeExcludedByReviewOrSuccessDates() {
    paid("REFUNDED", 1900, "tx-1");
    long possible = day.minusDays(2).atTime(8,10).atZone(ZoneId.of("Asia/Shanghai")).toInstant().toEpochMilli();
    jdbc.update("UPDATE family_orders SET paid_at=? WHERE id=?", possible, order);
    jdbc.update("INSERT INTO family_refund_requests(id,tenant_id,order_id,status,price_minor,provider_refund_id,created_at,reviewed_at,refunded_at) VALUES(?,?,?,'REFUNDED',1900,'rf-old',?,?,?)",
        UUID.randomUUID().toString(), tenant, order, possible+1000, possible+2000, clock.millis()+86_400_000);
    gateway.csv = FamilyTradeBillParserTest.HEADER + "\n" + FamilyTradeBillParserTest.FOOTER + "\n`0,`0.00,`0.00,`0.00,`0.00,`0.00,`0.00\n";
    var result = service.run(service.enqueue(day).id());
    assertThat(result.status()).isEqualTo("PARTIAL");
    assertThat(service.differences(result.id(),20,null).items()).extracting(FamilyBillReconciliationService.Difference::kind).containsExactly("UNVERIFIABLE_LOCAL_REFUND_DATE");
  }

  @Test void corruptHashOrUnknownBillNeverPublishesMatchedEvidence() {
    gateway.wrongHash = true;
    var result = service.run(service.enqueue(day).id());
    assertThat(result.status()).isEqualTo("INVALID_BILL");
    assertThat(result.errorCode()).isEqualTo("BILL_HASH_MISMATCH");
    assertThat(result.matchedCount()).isZero();
    gateway.wrongHash = false;
    gateway.csv = "not-a-trade-bill";
    service.retry(result.id());
    var invalid = service.run(result.id());
    assertThat(invalid.status()).isEqualTo("INVALID_BILL");
  }

  @Test void signedNoStatementIsUnavailableAndNeverPretendsEmptyMatchedBill() {
    gateway.failure = new FamilyBillGateway.Unavailable("NO_STATEMENT_EXIST");
    var result = service.run(service.enqueue(day).id());
    assertThat(result.status()).isEqualTo("UNAVAILABLE");
    assertThat(result.errorCode()).isEqualTo("NO_STATEMENT_EXIST");
    assertThat(result.billHash()).isNull();
  }

  @Test void retriesKeepOldEvidenceAndAcknowledgementCannotEraseDifferences() {
    paid("PAYMENT_PENDING", 1900, null);
    var result = service.run(service.enqueue(day).id());
    var diff = service.differences(result.id(), 20, null).items().get(0);
    service.acknowledge(result.id(), diff.id(), "已安排核对", "operator-1");
    service.acknowledge(result.id(), diff.id(), "已安排核对", "operator-1");
    assertThat(service.task(result.id()).status()).isEqualTo("DIFFERENCES");
    assertThat(service.difference(result.id(), diff.id()).state()).isEqualTo("ACKNOWLEDGED");
    assertThatThrownBy(() -> service.acknowledge(result.id(), diff.id(), "修改旧证据", "operator-1")).isInstanceOf(com.aimanager.shared.DomainException.class);
    jdbc.update("UPDATE family_orders SET status='PAID',provider_transaction_id='tx-1' WHERE id=?", order);
    service.retry(result.id()); service.retry(result.id());
    var refreshed = service.run(result.id());
    assertThat(refreshed.status()).isEqualTo("MATCHED");
    assertThat(refreshed.attemptCount()).isEqualTo(2);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_bill_differences WHERE task_id=?", Integer.class, result.id())).isPositive();
    assertThat(service.differences(result.id(), 20, null).items()).isEmpty();
  }

  @Test void leasedIoDoesNotHoldDatabaseLocksAndConcurrentWorkerCannotDownloadTwice() throws Exception {
    paid("PAID", 1900, "tx-1");
    gateway.entered = new CountDownLatch(1); gateway.release = new CountDownLatch(1);
    var task = service.enqueue(day);
    var pool = Executors.newSingleThreadExecutor();
    try {
      var first = pool.submit(() -> service.run(task.id()));
      assertThat(gateway.entered.await(3, TimeUnit.SECONDS)).isTrue();
      assertThat(service.run(task.id()).status()).isEqualTo("RUNNING");
      jdbc.update("UPDATE family_orders SET currency='CNY' WHERE id=?", order);
      assertThat(gateway.calls.get()).isEqualTo(1);
      gateway.release.countDown();
      assertThat(first.get(5, TimeUnit.SECONDS).status()).isEqualTo("MATCHED");
    } finally { gateway.release.countDown(); pool.shutdownNow(); }
  }

  @Test void yesterdayBeforeTenAndOutsideThreeNaturalMonthsAreNotFetched() {
    clock.now = Instant.parse("2026-10-16T01:59:59Z").toEpochMilli();
    assertThatThrownBy(() -> service.enqueue(day)).isInstanceOf(com.aimanager.shared.DomainException.class);
    assertThatThrownBy(() -> service.enqueue(LocalDate.of(2026, 7, 15))).isInstanceOf(com.aimanager.shared.DomainException.class);
    assertThatThrownBy(() -> service.enqueue(LocalDate.of(2026, 10, 16))).isInstanceOf(com.aimanager.shared.DomainException.class);
    assertThat(gateway.calls).hasValue(0);
    assertThat(service.enqueue(LocalDate.of(2026, 7, 16)).billDate()).isEqualTo("2026-07-16");
  }

  @Test void durableSchedulerFillsOutageDaysEvenIfOperatorManuallyQueuedYesterday() {
    assertThat(service.scheduleOneDay()).isTrue();
    assertThat(service.scheduleOneDay()).isFalse();
    clock.now += 3 * 86_400_000L;
    service.enqueue(day.plusDays(3));
    assertThat(service.scheduleOneDay()).isTrue();
    assertThat(service.scheduleOneDay()).isTrue();
    assertThat(service.scheduleOneDay()).isTrue();
    assertThat(service.scheduleOneDay()).isFalse();
    assertThat(jdbc.queryForList("SELECT bill_date FROM family_bill_tasks ORDER BY bill_date", String.class))
        .containsExactly("2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18");
  }

  @Test void billingNetworkCannotBeInvokedInsideAnOuterTransaction() {
    String id = service.enqueue(day).id();
    var outer = new org.springframework.transaction.support.TransactionTemplate(new DataSourceTransactionManager(jdbc.getDataSource()));
    assertThatThrownBy(() -> outer.executeWithoutResult(status -> service.run(id))).isInstanceOf(com.aimanager.shared.DomainException.class);
    assertThat(gateway.calls).hasValue(0);
  }

  @Test void expiredDownloadCannotPublishAfterASecondWorkerReclaimsItsLease() throws Exception {
    paid("PAID", 1900, "tx-1");
    gateway.entered = new CountDownLatch(1); gateway.release = new CountDownLatch(1);
    var task = service.enqueue(day);
    var pool = Executors.newSingleThreadExecutor();
    try {
      var first = pool.submit(() -> service.run(task.id()));
      assertThat(gateway.entered.await(3, TimeUnit.SECONDS)).isTrue();
      clock.now += 120_001;
      CountDownLatch firstRelease = gateway.release;
      gateway.entered = null;
      var replacement = service.run(task.id());
      assertThat(replacement.attemptCount()).isEqualTo(2);
      assertThat(replacement.status()).isEqualTo("MATCHED");
      firstRelease.countDown();
      assertThat(first.get(5, TimeUnit.SECONDS).latestAttemptId()).isEqualTo(replacement.latestAttemptId());
      assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM family_bill_attempts WHERE status='LEASE_EXPIRED'", Integer.class)).isEqualTo(1);
    } finally { gateway.release.countDown(); pool.shutdownNow(); }
  }

  @Test void refundSnapshotProcessingDoesNotOverrideAuthoritativeLocalSuccessAndUsesAcceptedDate() {
    paid("REFUNDED", 1900, "tx-1");
    String refundId = UUID.randomUUID().toString();
    long accepted = day.atTime(8,10).atZone(ZoneId.of("Asia/Shanghai")).toInstant().toEpochMilli();
    jdbc.update("INSERT INTO family_refund_requests(id,tenant_id,order_id,status,price_minor,provider_refund_id,created_at,reviewed_at,refunded_at,provider_accepted_at) VALUES(?,?,?,'REFUNDED',1900,'rf-1',?,?,?,?)",
        refundId, tenant, order, accepted-100_000, accepted-50_000, clock.millis(), accepted);
    String row = "`2026-10-15 08:10:00,`wx-app,`1900000001,`0,`,`tx-1,`" + reference(order)
        + ",`payer-private,`APP,`REFUND,`OTHERS,`CNY,`0.00,`0.00,`rf-1,`" + reference(refundId)
        + ",`19.00,`0.00,`ORIGINAL,`PROCESSING,`家庭会员,`,`-0.11,`0.60%,`0.00,`19.00,`";
    String paymentRow = gateway.csv.split("\n")[1];
    gateway.csv = FamilyTradeBillParserTest.HEADER + "\n" + paymentRow + "\n" + row + "\n" + FamilyTradeBillParserTest.FOOTER
        + "\n`2,`19.00,`19.00,`0.00,`0.00,`19.00,`19.00\n";
    var result = service.run(service.enqueue(day).id());
    assertThat(result.status()).isEqualTo("MATCHED");
    assertThat(result.matchedCount()).isEqualTo(2);
    assertThat(jdbc.queryForObject("SELECT status FROM family_refund_requests WHERE id=?", String.class, refundId)).isEqualTo("REFUNDED");
  }

  @Test void missingRefundUsesTrustedProviderAcceptedDateInsteadOfLaterSuccessDate() {
    paid("REFUNDED", 1900, "tx-1");
    String refundId = UUID.randomUUID().toString();
    long accepted = day.atTime(8,10).atZone(ZoneId.of("Asia/Shanghai")).toInstant().toEpochMilli();
    jdbc.update("INSERT INTO family_refund_requests(id,tenant_id,order_id,status,price_minor,provider_refund_id,created_at,reviewed_at,refunded_at,provider_accepted_at) VALUES(?,?,?,'REFUNDED',1900,'rf-1',?,?,?,?)",
        refundId, tenant, order, accepted-100_000, accepted-50_000, clock.millis(), accepted);
    var result = service.run(service.enqueue(day).id());
    assertThat(service.differences(result.id(),20,null).items()).extracting(FamilyBillReconciliationService.Difference::kind).containsExactly("MISSING_REFUND_ROW");
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(strings = {"PROCESSING", "ABNORMAL", "CLOSED"})
  void realCommerceRefundStatesAreRecognizedWithoutFakingARefundSuccess(String status) {
    paid("PAID", 1900, "tx-1");
    String refundId = UUID.randomUUID().toString();
    long accepted = day.atTime(8,10).atZone(ZoneId.of("Asia/Shanghai")).toInstant().toEpochMilli();
    jdbc.update("INSERT INTO family_refund_requests(id,tenant_id,order_id,status,price_minor,provider_refund_id,created_at,reviewed_at,provider_accepted_at) VALUES(?,?,?,?,1900,'rf-1',?,?,?)",
        refundId, tenant, order, status, accepted-100_000, accepted-50_000, accepted);
    String row = "`2026-10-15 08:10:00,`wx-app,`1900000001,`0,`,`tx-1,`" + reference(order)
        + ",`payer-private,`APP,`REFUND,`OTHERS,`CNY,`0.00,`0.00,`rf-1,`" + reference(refundId)
        + ",`19.00,`0.00,`ORIGINAL,`PROCESSING,`家庭会员,`,`-0.11,`0.60%,`0.00,`19.00,`";
    gateway.csv = FamilyTradeBillParserTest.HEADER + "\n" + gateway.csv.split("\n")[1] + "\n" + row + "\n" + FamilyTradeBillParserTest.FOOTER
        + "\n`2,`19.00,`19.00,`0.00,`0.00,`19.00,`19.00\n";
    var result = service.run(service.enqueue(day).id());
    assertThat(result.status()).isEqualTo("MATCHED");
    assertThat(jdbc.queryForObject("SELECT status FROM family_refund_requests WHERE id=?", String.class, refundId)).isEqualTo(status);
  }

  void paid(String state, int price, String transaction) {
    jdbc.update("INSERT INTO family_orders(id,tenant_id,status,price_minor,currency,provider_transaction_id,paid_at,created_at) VALUES(?,?,?,?,'CNY',?,?,?)",
        order, tenant, state, price, transaction, day.atTime(23,59,59).atZone(ZoneId.of("Asia/Shanghai")).toInstant().toEpochMilli(), clock.millis() - 86_400_000);
  }
  static String reference(String id) { return id.replace("-", ""); }
  static class TestClock extends Clock {
    volatile long now;
    TestClock(long now) { this.now = now; }
    @Override public ZoneId getZone() { return ZoneId.of("UTC"); }
    @Override public Clock withZone(ZoneId zone) { return this; }
    @Override public Instant instant() { return Instant.ofEpochMilli(now); }
    @Override public long millis() { return now; }
  }
  static class FakeBillGateway implements FamilyBillGateway {
    String csv; boolean wrongHash; RuntimeException failure; AtomicInteger calls = new AtomicInteger();
    CountDownLatch entered, release;
    @Override public boolean available() { return true; }
    @Override public String merchantId() { return "1900000001"; }
    @Override public String appId() { return "wx-app"; }
    @Override public BillFile download(LocalDate date) {
      calls.incrementAndGet();
      if (entered != null) {
        entered.countDown();
        try { if (!release.await(5, TimeUnit.SECONDS)) throw new AssertionError("blocked download"); }
        catch (InterruptedException ex) { Thread.currentThread().interrupt(); throw new AssertionError(ex); }
      }
      if (failure != null) throw failure;
      byte[] bytes = FamilyTradeBillParserTest.bytes(csv);
      return new BillFile(bytes, wrongHash ? "0".repeat(40) : FamilyBillGateway.sha1(bytes));
    }
  }
}
