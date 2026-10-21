package com.aimanager.commerce.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** 日账单仅产生证据与差异；修复必须另走微信可信查询，不能由 CSV 发放或撤销会员。 */
@Service
class FamilyBillReconciliationService {
  private static final ZoneId ZONE = ZoneId.of("Asia/Shanghai");
  private static final long LEASE_MS = 120_000;
  private static final long RETRY_MS = 900_000;
  private static final int AUTOMATIC_ATTEMPTS = 6;
  private static final int MAX_ATTEMPTS = 50;
  private static final String VIEW = "SELECT t.*,a.bill_hash,a.row_count,a.matched_count,a.ignored_count,a.difference_count,a.error_code"
      + " FROM family_bill_tasks t LEFT JOIN family_bill_attempts a ON a.id=t.latest_attempt_id";
  private final JdbcTemplate jdbc;
  private final FamilyBillGateway gateway;
  private final Clock clock;
  private final TransactionTemplate tx;
  private final AuditService audit;

  FamilyBillReconciliationService(JdbcTemplate jdbc, FamilyBillGateway gateway, Clock clock,
      PlatformTransactionManager manager, AuditService audit) {
    this.jdbc = jdbc; this.gateway = gateway; this.clock = clock; this.audit = audit;
    tx = new TransactionTemplate(manager); tx.setTimeout(10);
    tx.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
  }

  Task enqueue(LocalDate date) {
    validateDate(date);
    if (!gateway.available()) throw unavailable();
    String merchant = merchantKey();
    tx.executeWithoutResult(status -> jdbc.update("INSERT INTO family_bill_tasks(id,merchant_key,bill_date,status,created_at,updated_at,next_attempt_at)"
        + " VALUES(?,?,?,'PENDING',?,?,?) ON DUPLICATE KEY UPDATE merchant_key=merchant_key", UUID.randomUUID().toString(), merchant, date.toString(), clock.millis(), clock.millis(), clock.millis()));
    String id = jdbc.queryForObject("SELECT id FROM family_bill_tasks WHERE merchant_key=? AND bill_date=?", String.class, merchant, date.toString());
    return task(id);
  }

  ItemPage<Task> tasks(int limit, String cursor) {
    ItemPage.validate(limit, cursor);
    return ItemPage.from(jdbc.query(VIEW + " WHERE t.id>? ORDER BY t.id LIMIT ?", (r, i) -> task(r), cursor == null ? "" : cursor, limit + 1), limit, Task::id);
  }

  Task task(String id) {
    canonicalId(id);
    var result = jdbc.query(VIEW + " WHERE t.id=?", (r, i) -> task(r), id);
    if (result.isEmpty()) throw missing();
    return result.get(0);
  }

  Task retry(String id) {
    canonicalId(id);
    return tx.execute(status -> {
      var current = lock(id);
      validateDate(LocalDate.parse(current.billDate()));
      if ("PENDING".equals(current.status()) || "RUNNING".equals(current.status())) return current;
      if (current.attemptCount() >= MAX_ATTEMPTS) throw conflict("FAMILY_BILL_ATTEMPTS_EXHAUSTED");
      jdbc.update("UPDATE family_bill_tasks SET status='PENDING',next_attempt_at=?,updated_at=? WHERE id=?", clock.millis(), clock.millis(), id);
      return task(id);
    });
  }

  /** 网络调用在租约短事务之外；过期工作者即使稍后拿到响应也不能覆盖新证据。 */
  Task run(String id) {
    if (TransactionSynchronizationManager.isActualTransactionActive()) throw conflict("FAMILY_BILL_NETWORK_REQUIRES_NO_TRANSACTION");
    canonicalId(id);
    Claim claim = tx.execute(status -> claim(id));
    if (claim == null) return task(id);
    Outcome outcome;
    try {
      validateDate(claim.date());
      if (!gateway.available() || !merchantKey().equals(claim.merchantKey())) throw new FamilyBillGateway.Unavailable("BILL_PROVIDER_UNAVAILABLE");
      var downloaded = gateway.download(claim.date());
      byte[] bytes = downloaded == null ? null : downloaded.bytes();
      if (bytes == null || bytes.length == 0 || bytes.length > FamilyTradeBillParser.MAX_BYTES) throw new FamilyTradeBillParser.InvalidBill();
      if (downloaded.sha1() == null || !downloaded.sha1().matches("[a-fA-F0-9]{40}")
          || !FamilyBillGateway.sha1(bytes).equalsIgnoreCase(downloaded.sha1())) outcome = Outcome.failed("INVALID_BILL", "BILL_HASH_MISMATCH");
      else {
        var bill = FamilyTradeBillParser.parse(bytes, claim.date());
        outcome = compare(claim.date(), bill, downloaded.sha1().toLowerCase(java.util.Locale.ROOT));
      }
    } catch (FamilyBillGateway.Unavailable unavailable) {
      Set<String> permitted = Set.of("NO_STATEMENT_EXIST", "STATEMENT_CREATING", "FREQUENCY_LIMITED", "BILL_PROVIDER_UNAVAILABLE");
      outcome = Outcome.failed("UNAVAILABLE", permitted.contains(unavailable.code()) ? unavailable.code() : "BILL_PROVIDER_UNAVAILABLE");
    } catch (FamilyTradeBillParser.InvalidBill invalid) {
      outcome = Outcome.failed("INVALID_BILL", "BILL_FORMAT_OR_SUMMARY_INVALID");
    } catch (RuntimeException unknown) {
      // 不存储异常文本或下载 URL，避免下载凭证、付款人标识进入运营日志。
      outcome = Outcome.failed("UNAVAILABLE", "BILL_PROVIDER_UNAVAILABLE");
    }
    Outcome completed = outcome;
    tx.executeWithoutResult(status -> publish(claim, completed));
    return task(id);
  }

  List<String> readyIds(int limit) {
    if (limit < 1 || limit > 20) throw DomainException.invalid("INVALID_FAMILY_BILL_BATCH");
    tx.executeWithoutResult(status -> {
      var exhausted = jdbc.queryForList("SELECT id FROM family_bill_tasks WHERE status='RUNNING' AND attempt_count>=? AND lease_until<=? ORDER BY updated_at,id LIMIT 20 FOR UPDATE", String.class, MAX_ATTEMPTS, clock.millis());
      for (String id : exhausted) markExhausted(id);
    });
    return jdbc.queryForList("SELECT id FROM family_bill_tasks WHERE (status='PENDING' OR (status='UNAVAILABLE' AND attempt_count<? AND next_attempt_at<=?)"
        + " OR (status='RUNNING' AND attempt_count<? AND lease_until<=?)) ORDER BY updated_at,id LIMIT ?", String.class, AUTOMATIC_ATTEMPTS, clock.millis(), MAX_ATTEMPTS, clock.millis(), limit);
  }

  /** 从启用后的昨日开始持久排队；停机后逐日补齐，人工补单不会跳过调度游标。 */
  boolean scheduleOneDay() {
    var now = Instant.ofEpochMilli(clock.millis()).atZone(ZONE);
    if (now.getHour() < 10 || !gateway.available()) return false;
    String merchant = merchantKey();
    return Boolean.TRUE.equals(tx.execute(status -> {
      jdbc.update("INSERT INTO family_bill_cursors(merchant_key,updated_at) VALUES(?,?) ON DUPLICATE KEY UPDATE merchant_key=merchant_key", merchant, clock.millis());
      String last = jdbc.queryForObject("SELECT last_scheduled_date FROM family_bill_cursors WHERE merchant_key=? FOR UPDATE", String.class, merchant);
      LocalDate target = last == null ? now.toLocalDate().minusDays(1) : LocalDate.parse(last).plusDays(1);
      LocalDate oldest = now.toLocalDate().minusMonths(3);
      if (target.isBefore(oldest)) target = oldest;
      if (!target.isBefore(now.toLocalDate())) return false;
      enqueue(target);
      jdbc.update("UPDATE family_bill_cursors SET last_scheduled_date=?,updated_at=? WHERE merchant_key=?", target.toString(), clock.millis(), merchant);
      return true;
    }));
  }

  ItemPage<Difference> differences(String taskId, int limit, String cursor) {
    ItemPage.validate(limit, cursor);
    var current = task(taskId);
    return ItemPage.from(jdbc.query("SELECT * FROM family_bill_differences WHERE task_id=? AND attempt_id=? AND id>? ORDER BY id LIMIT ?",
        (r, i) -> difference(r), taskId, current.latestAttemptId(), cursor == null ? "" : cursor, limit + 1), limit, Difference::id);
  }

  Difference difference(String taskId, String id) {
    canonicalId(id); var current = task(taskId);
    var rows = jdbc.query("SELECT * FROM family_bill_differences WHERE task_id=? AND attempt_id=? AND id=?", (r, i) -> difference(r), taskId, current.latestAttemptId(), id);
    if (rows.isEmpty()) throw missing();
    return rows.get(0);
  }

  Difference acknowledge(String taskId, String id, String note, String actor) {
    if (note == null || note.isBlank() || note.length() > 200 || note.chars().anyMatch(Character::isISOControl)) throw DomainException.invalid("INVALID_FAMILY_BILL_NOTE");
    canonicalId(taskId); canonicalId(id);
    return tx.execute(status -> {
      var current = lock(taskId);
      var rows = jdbc.query("SELECT * FROM family_bill_differences WHERE task_id=? AND attempt_id=? AND id=? FOR UPDATE", (r,i) -> difference(r), taskId, current.latestAttemptId(), id);
      if (rows.isEmpty()) throw missing();
      var row = rows.get(0);
      if ("ACKNOWLEDGED".equals(row.state())) {
        if (!note.equals(row.note())) throw conflict("FAMILY_BILL_ACKNOWLEDGEMENT_IMMUTABLE");
        return row;
      }
      jdbc.update("UPDATE family_bill_differences SET state='ACKNOWLEDGED',note=?,acknowledged_by=?,acknowledged_at=? WHERE id=?",
          note, ActorKeys.key(actor), clock.millis(), id);
      jdbc.update("INSERT INTO family_bill_audit_events(id,task_id,difference_id,action,actor_key,evidence_hash,occurred_at) VALUES(?,?,?,?,?,?,?)",
          UUID.randomUUID().toString(), taskId, id, "FAMILY_BILL_DIFFERENCE_ACKNOWLEDGED", ActorKeys.key(actor),
          FamilySubscriptionService.hash(taskId + "\u0000" + id + "\u0000" + row.kind() + "\u0000" + row.rowHash() + "\u0000" + note), clock.millis());
      if (row.tenantId() != null) audit.record(row.tenantId(), actor, "FAMILY_BILL_DIFFERENCE_ACKNOWLEDGED", id);
      return difference(taskId, id);
    });
  }

  /** 平台入队操作的永久审计；控制器仍须先鉴权，并在其幂等短事务内调用。 */
  void recordOperatorAction(String taskId, String differenceId, String action, String actor) {
    canonicalId(taskId);
    if (!Set.of("FAMILY_BILL_ENQUEUED", "FAMILY_BILL_RETRY_ENQUEUED", "FAMILY_BILL_VERIFICATION_QUEUED").contains(action))
      throw DomainException.invalid("INVALID_FAMILY_BILL_AUDIT_ACTION");
    if ("FAMILY_BILL_VERIFICATION_QUEUED".equals(action) && differenceId == null) throw DomainException.invalid("FAMILY_BILL_DIFFERENCE_REQUIRED");
    tx.executeWithoutResult(status -> {
      var current = lock(taskId);
      if (differenceId != null) {
        canonicalId(differenceId);
        var values = jdbc.query("SELECT * FROM family_bill_differences WHERE task_id=? AND attempt_id=? AND id=? FOR UPDATE", (r,i) -> difference(r), taskId, current.latestAttemptId(), differenceId);
        if (values.isEmpty()) throw missing();
        if ("FAMILY_BILL_VERIFICATION_QUEUED".equals(action) && values.get(0).tenantId() == null)
          throw conflict("UNMAPPED_BILL_TRANSACTION_NOT_REPAIRABLE");
      }
      jdbc.update("INSERT INTO family_bill_audit_events(id,task_id,difference_id,action,actor_key,evidence_hash,occurred_at) VALUES(?,?,?,?,?,?,?)",
          UUID.randomUUID().toString(), taskId, differenceId, action, ActorKeys.key(actor),
          FamilySubscriptionService.hash(taskId + "\u0000" + current.billDate() + "\u0000" + current.latestAttemptId() + "\u0000" + action + "\u0000" + differenceId), clock.millis());
    });
  }

  private Claim claim(String id) {
    var current = lock(id);
    long now = clock.millis();
    var metadata = jdbc.queryForMap("SELECT merchant_key,lease_until,next_attempt_at FROM family_bill_tasks WHERE id=?", id);
    Long lease = (Long) metadata.get("lease_until"), next = (Long) metadata.get("next_attempt_at");
    boolean ready = "PENDING".equals(current.status()) || "RUNNING".equals(current.status()) && lease != null && lease <= now
        || "UNAVAILABLE".equals(current.status()) && current.attemptCount() < AUTOMATIC_ATTEMPTS && next != null && next <= now;
    if (!ready) return null;
    if (current.attemptCount() >= MAX_ATTEMPTS) { markExhausted(id); return null; }
    if ("RUNNING".equals(current.status()) && current.latestAttemptId() != null) {
      jdbc.update("UPDATE family_bill_attempts SET status='LEASE_EXPIRED',error_code='BILL_LEASE_EXPIRED',completed_at=? WHERE id=? AND status='RUNNING'", now, current.latestAttemptId());
    }
    String attempt = UUID.randomUUID().toString(), token = UUID.randomUUID().toString();
    jdbc.update("INSERT INTO family_bill_attempts(id,task_id,attempt_number,status,created_at) VALUES(?,?,?,'RUNNING',?)", attempt, id, current.attemptCount() + 1, now);
    jdbc.update("UPDATE family_bill_tasks SET status='RUNNING',attempt_count=attempt_count+1,latest_attempt_id=?,lease_token=?,lease_until=?,next_attempt_at=NULL,updated_at=? WHERE id=?",
        attempt, token, now + LEASE_MS, now, id);
    return new Claim(id, attempt, token, (String) metadata.get("merchant_key"), LocalDate.parse(current.billDate()));
  }

  private void markExhausted(String id) {
    jdbc.update("UPDATE family_bill_attempts SET status='ATTENTION',error_code='BILL_ATTEMPTS_EXHAUSTED',completed_at=?"
        + " WHERE id=(SELECT latest_attempt_id FROM family_bill_tasks WHERE id=?) AND status='RUNNING'", clock.millis(), id);
    jdbc.update("UPDATE family_bill_tasks SET status='ATTENTION',lease_token=NULL,lease_until=NULL,next_attempt_at=NULL,updated_at=? WHERE id=?", clock.millis(), id);
  }

  private void publish(Claim claim, Outcome result) {
    lock(claim.taskId());
    var token = jdbc.queryForObject("SELECT lease_token FROM family_bill_tasks WHERE id=?", String.class, claim.taskId());
    Long lease = jdbc.queryForObject("SELECT lease_until FROM family_bill_tasks WHERE id=?", Long.class, claim.taskId());
    if (!claim.token().equals(token) || lease == null || lease < clock.millis()) return;
    for (PendingDifference difference : result.differences()) {
      jdbc.update("INSERT INTO family_bill_differences(id,task_id,attempt_id,kind,tenant_id,order_id,refund_id,provider_reference,row_hash,expected_minor,actual_minor,state,created_at)"
          + " VALUES(?,?,?,?,?,?,?,?,?,?,?,'OPEN',?)", UUID.randomUUID().toString(), claim.taskId(), claim.attemptId(), difference.kind(), difference.tenantId(), difference.orderId(), difference.refundId(),
          difference.providerReference(), difference.rowHash(), difference.expectedMinor(), difference.actualMinor(), clock.millis());
    }
    jdbc.update("UPDATE family_bill_attempts SET status=?,bill_hash=?,row_count=?,matched_count=?,ignored_count=?,difference_count=?,error_code=?,completed_at=? WHERE id=?",
        result.status(), result.hash(), result.rows(), result.matched(), result.ignored(), result.differences().size(), result.error(), clock.millis(), claim.attemptId());
    jdbc.update("UPDATE family_bill_tasks SET status=?,lease_token=NULL,lease_until=NULL,next_attempt_at=?,updated_at=? WHERE id=?",
        result.status(), "UNAVAILABLE".equals(result.status()) ? clock.millis() + RETRY_MS : null, clock.millis(), claim.taskId());
  }

  private Outcome compare(LocalDate date, FamilyTradeBillParser.Bill bill, String hash) {
    long start = date.atStartOfDay(ZONE).toInstant().toEpochMilli(), end = date.plusDays(1).atStartOfDay(ZONE).toInstant().toEpochMilli();
    var orders = referencedOrders(bill);
    var refunds = referencedRefunds(bill);
    List<LocalOrder> expectedOrders = jdbc.query("SELECT * FROM family_orders WHERE paid_at>=? AND paid_at<? ORDER BY id LIMIT ?", (r,i) -> localOrder(r), start, end, FamilyTradeBillParser.MAX_ROWS + 1);
    List<LocalRefund> expectedRefunds = jdbc.query("SELECT * FROM family_refund_requests WHERE provider_accepted_at>=? AND provider_accepted_at<? ORDER BY id LIMIT ?", (r,i) -> localRefund(r), start, end, FamilyTradeBillParser.MAX_ROWS + 1);
    if (expectedOrders.size() > FamilyTradeBillParser.MAX_ROWS || expectedRefunds.size() > FamilyTradeBillParser.MAX_ROWS) throw new FamilyTradeBillParser.InvalidBill();
    var differences = new ArrayList<PendingDifference>();
    Set<String> paid = new HashSet<>(), refunded = new HashSet<>(), transactionIds = new HashSet<>(), refundIds = new HashSet<>();
    int matched = 0, ignored = 0;
    boolean substantive = false;
    for (var row : bill.rows()) {
      boolean payment = "SUCCESS".equals(row.state());
      boolean duplicate = payment ? !transactionIds.add(row.transactionId()) : !refundIds.add(row.providerRefundId());
      LocalOrder order = orders.get(uuid(row.merchantOrderId()));
      if (order == null) {
        ignored++;
        differences.add(new PendingDifference("UNMAPPED_PROVIDER_TRANSACTION", null, null, null, "SUCCESS".equals(row.state()) ? row.transactionId() : row.providerRefundId(),
            row.evidenceHash(), null, "SUCCESS".equals(row.state()) ? row.orderMinor() : row.refundMinor()));
        if (duplicate) {
          substantive = true;
          differences.add(new PendingDifference(payment ? "DUPLICATE_TRANSACTION" : "DUPLICATE_REFUND", null, null, null,
              payment ? row.transactionId() : row.providerRefundId(), row.evidenceHash(), null, payment ? row.orderMinor() : row.refundMinor()));
        }
        continue;
      }
      int before = differences.size();
      LocalRefund refund = payment ? null : refunds.get(uuid(row.merchantRefundId()));
      String refundId = refund == null ? null : refund.id();
      if (!gateway.merchantId().equals(row.merchantId()) || !gateway.appId().equals(row.appId()) || !"0".equals(row.subMerchantId())) add(differences, "MERCHANT_OR_APP_MISMATCH", order, refundId, row, null, null);
      if (!"APP".equals(row.tradeType())) add(differences, "TRADE_TYPE_MISMATCH", order, refundId, row, null, null);
      if (row.at() < start || row.at() >= end) add(differences, "BILL_DATE_MISMATCH", order, refundId, row, null, null);
      if (!order.currency().equals(row.currency()) || !"CNY".equals(row.currency())) add(differences, "CURRENCY_MISMATCH", order, refundId, row, null, null);
      if (order.priceMinor() != (payment ? row.orderMinor() : row.refundMinor())) add(differences, "AMOUNT_MISMATCH", order, refundId, row, order.priceMinor(), payment ? row.orderMinor() : row.refundMinor());
      if (payment) {
        paid.add(order.id());
        if (duplicate) add(differences, "DUPLICATE_TRANSACTION", order, null, row, null, null);
        if (!Set.of("PAID", "REFUNDED").contains(order.status()) || order.transactionId() == null || order.paidAt() == null) add(differences, "LOCAL_PAYMENT_UNCONFIRMED", order, null, row, order.priceMinor(), row.orderMinor());
        else {
          if (!order.transactionId().equals(row.transactionId())) add(differences, "TRANSACTION_ID_MISMATCH", order, null, row, null, null);
          if (order.paidAt() / 1000 != row.at() / 1000) add(differences, "PAYMENT_TIME_MISMATCH", order, null, row, null, null);
        }
      } else {
        if (duplicate) add(differences, "DUPLICATE_REFUND", order, refundId, row, null, null);
        if (refund == null || !refund.orderId().equals(order.id()) || !refund.tenantId().equals(order.tenantId())) add(differences, "UNKNOWN_FAMILY_REFUND", order, null, row, order.priceMinor(), row.refundMinor());
        else {
          refunded.add(refund.id());
          if (refund.priceMinor() != row.refundMinor()) add(differences, "REFUND_AMOUNT_MISMATCH", order, refund.id(), row, refund.priceMinor(), row.refundMinor());
          if (order.transactionId() == null || !order.transactionId().equals(row.transactionId())) add(differences, "TRANSACTION_ID_MISMATCH", order, refund.id(), row, null, null);
          if (refund.providerRefundId() == null || !Set.of("REFUNDED", "PROCESSING", "ABNORMAL", "CLOSED").contains(refund.status())) add(differences, "LOCAL_REFUND_UNCONFIRMED", order, refund.id(), row, null, null);
          else if (!refund.providerRefundId().equals(row.providerRefundId())) add(differences, "REFUND_ID_MISMATCH", order, refund.id(), row, null, null);
          if (refund.acceptedAt() == null) add(differences, "UNVERIFIABLE_LOCAL_REFUND_DATE", order, refund.id(), row, null, null);
          else if (refund.acceptedAt() / 1000 != row.at() / 1000) add(differences, "REFUND_ACCEPTED_TIME_MISMATCH", order, refund.id(), row, null, null);
          if (!"ORIGINAL".equals(row.refundType())) add(differences, "REFUND_CHANNEL_MISMATCH", order, refund.id(), row, null, null);
          if ("REVOKED".equals(row.state())) add(differences, "UNEXPECTED_REVERSAL", order, refund.id(), row, null, null);
          // 账单退款状态是出账时快照，不能用 PROCESSING 降级后来查询确认的 REFUNDED。
        }
      }
      if (before == differences.size()) matched++; else substantive = true;
    }
    for (var order : expectedOrders) if (!paid.contains(order.id())) {
      substantive = true;
      differences.add(new PendingDifference("MISSING_PAYMENT_ROW", order.tenantId(), order.id(), null, order.transactionId(), null, order.priceMinor(), null));
    }
    for (var refund : expectedRefunds) if (!refunded.contains(refund.id())) {
      substantive = true;
      differences.add(new PendingDifference("MISSING_REFUND_ROW", refund.tenantId(), refund.orderId(), refund.id(), refund.providerRefundId(), null, refund.priceMinor(), null));
    }
    // 历史退款缺少已验签受理时间：只标待核对，绝不按退款完成日推断账单归属。
    var legacy = jdbc.query("SELECT * FROM family_refund_requests WHERE provider_accepted_at IS NULL AND provider_refund_id IS NOT NULL"
        + " AND created_at<? ORDER BY id LIMIT ?", (r,i) -> localRefund(r), end, FamilyTradeBillParser.MAX_ROWS + 1);
    if (legacy.size() > FamilyTradeBillParser.MAX_ROWS) throw new FamilyTradeBillParser.InvalidBill();
    for (var refund : legacy) if (!refunded.contains(refund.id())) {
      differences.add(new PendingDifference("UNVERIFIABLE_LOCAL_REFUND_DATE", refund.tenantId(), refund.orderId(), refund.id(), refund.providerRefundId(), null, refund.priceMinor(), null));
    }
    return new Outcome(substantive ? "DIFFERENCES" : ignored > 0 || !legacy.isEmpty() ? "PARTIAL" : "MATCHED", hash, bill.rows().size(), matched, ignored, null, List.copyOf(differences));
  }

  private Map<String, LocalOrder> referencedOrders(FamilyTradeBillParser.Bill bill) {
    Set<String> ids = new HashSet<>(); for (var row : bill.rows()) if (uuid(row.merchantOrderId()) != null) ids.add(uuid(row.merchantOrderId()));
    var result = new HashMap<String, LocalOrder>();
    for (List<String> chunk : chunks(ids)) jdbc.query("SELECT * FROM family_orders WHERE id IN (" + placeholders(chunk.size()) + ")", (r,i) -> localOrder(r), chunk.toArray()).forEach(order -> result.put(order.id(), order));
    return result;
  }
  private Map<String, LocalRefund> referencedRefunds(FamilyTradeBillParser.Bill bill) {
    Set<String> ids = new HashSet<>(); for (var row : bill.rows()) if (!"SUCCESS".equals(row.state()) && uuid(row.merchantRefundId()) != null) ids.add(uuid(row.merchantRefundId()));
    var result = new HashMap<String, LocalRefund>();
    for (List<String> chunk : chunks(ids)) jdbc.query("SELECT * FROM family_refund_requests WHERE id IN (" + placeholders(chunk.size()) + ")", (r,i) -> localRefund(r), chunk.toArray()).forEach(refund -> result.put(refund.id(), refund));
    return result;
  }
  private static List<List<String>> chunks(Set<String> input) {
    var ids = new ArrayList<>(input); var result = new ArrayList<List<String>>();
    for (int at = 0; at < ids.size(); at += 200) result.add(ids.subList(at, Math.min(at + 200, ids.size())));
    return result;
  }
  private static String placeholders(int count) { return String.join(",", java.util.Collections.nCopies(count, "?")); }
  private static String uuid(String reference) {
    if (reference == null || !reference.matches("[0-9a-f]{32}")) return null;
    return reference.substring(0,8) + "-" + reference.substring(8,12) + "-" + reference.substring(12,16) + "-" + reference.substring(16,20) + "-" + reference.substring(20);
  }
  private static void add(List<PendingDifference> all, String kind, LocalOrder order, String refund, FamilyTradeBillParser.Row row, Long expected, Long actual) {
    all.add(new PendingDifference(kind, order.tenantId(), order.id(), refund, "SUCCESS".equals(row.state()) ? row.transactionId() : row.providerRefundId(), row.evidenceHash(), expected, actual));
  }
  private Task lock(String id) {
    var rows = jdbc.query(VIEW + " WHERE t.id=? FOR UPDATE", (r,i) -> task(r), id);
    if (rows.isEmpty()) throw missing();
    return rows.get(0);
  }
  private String merchantKey() { return FamilySubscriptionService.hash(gateway.merchantId() + "\u0000" + gateway.appId()); }
  private void validateDate(LocalDate day) {
    var now = Instant.ofEpochMilli(clock.millis()).atZone(ZONE); var today = now.toLocalDate();
    if (day == null || !day.isBefore(today) || day.isBefore(today.minusMonths(3)) || day.equals(today.minusDays(1)) && now.getHour() < 10)
      throw DomainException.invalid("FAMILY_BILL_DATE_UNAVAILABLE");
  }
  private static void canonicalId(String id) { if (id == null || !id.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")) throw DomainException.invalid("INVALID_FAMILY_BILL_ID"); }
  private static DomainException missing() { return new DomainException(HttpStatus.NOT_FOUND, "FAMILY_BILL_NOT_FOUND"); }
  private static DomainException unavailable() { return new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "FAMILY_BILL_PROVIDER_UNAVAILABLE"); }
  private static DomainException conflict(String code) { return new DomainException(HttpStatus.CONFLICT, code); }
  private static Long nullable(ResultSet r, String field) throws SQLException { long value = r.getLong(field); return r.wasNull() ? null : value; }
  private static LocalOrder localOrder(ResultSet r) throws SQLException { return new LocalOrder(r.getString("id"), r.getString("tenant_id"), r.getString("status"), r.getLong("price_minor"), r.getString("currency"), r.getString("provider_transaction_id"), nullable(r,"paid_at")); }
  private static LocalRefund localRefund(ResultSet r) throws SQLException { return new LocalRefund(r.getString("id"), r.getString("tenant_id"), r.getString("order_id"), r.getString("status"), r.getLong("price_minor"), r.getString("provider_refund_id"), nullable(r,"provider_accepted_at")); }
  private static Task task(ResultSet r) throws SQLException { return new Task(r.getString("id"), r.getString("bill_date"), r.getString("status"), r.getInt("attempt_count"), r.getString("latest_attempt_id"), r.getString("bill_hash"), r.getInt("row_count"), r.getInt("matched_count"), r.getInt("ignored_count"), r.getInt("difference_count"), r.getString("error_code"), r.getLong("created_at"), r.getLong("updated_at")); }
  private static Difference difference(ResultSet r) throws SQLException { return new Difference(r.getString("id"), r.getString("kind"), r.getString("tenant_id"), r.getString("order_id"), r.getString("refund_id"), nullable(r,"expected_minor"), nullable(r,"actual_minor"), r.getString("state"), r.getString("note"), r.getLong("created_at"), r.getString("provider_reference"), r.getString("row_hash")); }
  record Task(String id, String billDate, String status, int attemptCount, String latestAttemptId, String billHash,
      int rowCount, int matchedCount, int ignoredCount, int differenceCount, String errorCode, long createdAt, long updatedAt) {}
  record Difference(String id, String kind, String tenantId, String orderId, String refundId, Long expectedMinor, Long actualMinor,
      String state, String note, long createdAt, String providerReference, String rowHash) {}
  private record Claim(String taskId, String attemptId, String token, String merchantKey, LocalDate date) {}
  private record LocalOrder(String id, String tenantId, String status, long priceMinor, String currency, String transactionId, Long paidAt) {}
  private record LocalRefund(String id, String tenantId, String orderId, String status, long priceMinor, String providerRefundId, Long acceptedAt) {}
  private record PendingDifference(String kind, String tenantId, String orderId, String refundId, String providerReference, String rowHash, Long expectedMinor, Long actualMinor) {}
  private record Outcome(String status, String hash, int rows, int matched, int ignored, String error, List<PendingDifference> differences) {
    static Outcome failed(String status, String code) { return new Outcome(status, null, 0, 0, 0, code, List.of()); }
  }
}
