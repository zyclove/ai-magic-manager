package com.aimanager.commerce.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.commerce.FamilyAssistedActivationGate;
import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.tenant.TenantAccess;
import com.aimanager.tenant.TenantAccess.Role;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.beans.factory.ObjectProvider;

/** Frozen purchases and source-specific facts, independent from device technical capability. */
@Service
class FamilySubscriptionService {
  private static final ZoneId BILLING_ZONE = ZoneId.of("Asia/Shanghai");
  private static final String ORDER_COLUMNS = "id,tenant_id,plan_key,status,price_minor,currency,"
      + "period_start,period_end,created_at,expires_at,provider_transaction_id";
  private static final String REFUND_COLUMNS="r.*,(SELECT v.note FROM family_refund_reviews v WHERE v.refund_id=r.id) AS review_note";
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final CommercialLedger ledger;
  private final AuditService audit;
  private final Clock clock;
  private final ObjectMapper json;
  private final FamilyPaymentGateway gateway;
  private final FamilyAssistedActivationGate activationGate;
  private final TransactionTemplate transactions;
  private final ObjectProvider<FamilyCommerceMaintenance> maintenance;

  FamilySubscriptionService(JdbcTemplate jdbc, TenantAccess access, CommercialLedger ledger,
      AuditService audit, Clock clock, ObjectMapper json, FamilyPaymentGateway gateway,
      FamilyAssistedActivationGate activationGate, PlatformTransactionManager transactionManager,
      ObjectProvider<FamilyCommerceMaintenance> maintenance) {
    this.jdbc = jdbc; this.access = access; this.ledger = ledger; this.audit = audit;
    this.clock = clock; this.json = json; this.gateway = gateway; this.activationGate = activationGate;
    this.transactions = new TransactionTemplate(transactionManager);
    this.transactions.setTimeout(10);
    this.maintenance=maintenance;
  }

  @Transactional(readOnly = true, timeout = 10)
  Offers offers(String tenant, String actor) {
    requireFamily(tenant, actor, false, false);
    boolean payable=gateway.available() && hasVerifiedActivation(tenant);
    return new Offers(List.of(offer("FAMILY_MONTH",payable), offer("FAMILY_YEAR",payable)));
  }

  @Transactional(timeout = 10)
  Subscription subscription(String tenant, String actor) {
    requireFamily(tenant, actor, false, false);
    lockAccount(tenant);
    return subscriptionView(tenant);
  }

  @Transactional(timeout = 10)
  Subscription startTrial(String tenant, Jwt identity, String deviceId) {
    String actor=identity.getSubject();
    requireFamily(tenant, actor, true, true);
    String phone=identity.getClaimAsString("phone_number");
    if (!Boolean.TRUE.equals(identity.getClaim("phone_number_verified")) || phone==null || !phone.matches("\\+861[3-9][0-9]{9}"))
      throw new DomainException(HttpStatus.PRECONDITION_REQUIRED,"VERIFIED_PHONE_REQUIRED");
    canonicalId(deviceId);
    lockAccount(tenant);
    Long existing = jdbc.queryForObject("SELECT trial_started_at FROM family_subscription_accounts WHERE tenant_id=? FOR UPDATE", Long.class, tenant);
    if (existing != null) return subscriptionView(tenant);
    var activation = activationGate.verify(tenant, deviceId);
    if (!activationValid(tenant,deviceId,activation)) throw conflict("TRIAL_ACTIVATION_NOT_VERIFIED");
    var device = jdbc.queryForList("SELECT registration_id,created_at FROM devices WHERE tenant_id=? AND id=?"
        + " AND platform='ANDROID' AND state='ACTIVE' FOR UPDATE", tenant, deviceId);
    if (device.isEmpty() || !java.util.Objects.equals(activation.registrationId(),device.get(0).get("registration_id"))
        || activation.activatedAt() < ((Number) device.get(0).get("created_at")).longValue())
      throw conflict("TRIAL_ACTIVATION_NOT_VERIFIED");
    List<String> claims=List.of("ACTOR_"+ActorKeys.key(actor),"PHONE_"+hash(phone)).stream().sorted().toList();
    for (String claim:claims) {
      jdbc.update("INSERT INTO family_trial_claims(identity_key) VALUES(?) ON DUPLICATE KEY UPDATE identity_key=identity_key",claim);
      Long used=jdbc.queryForObject("SELECT claimed_at FROM family_trial_claims WHERE identity_key=? FOR UPDATE",Long.class,claim);
      if (used!=null) throw conflict("FAMILY_TRIAL_ALREADY_CLAIMED");
    }
    long end = Instant.ofEpochMilli(activation.activatedAt()).atZone(BILLING_ZONE).plusDays(7).toInstant().toEpochMilli();
    jdbc.update("UPDATE family_subscription_accounts SET trial_started_at=?,trial_ends_at=?,trial_device_id=?,"
        + "trial_evidence_hash=?,version=version+1 WHERE tenant_id=?", activation.activatedAt(), end,
        deviceId, activation.evidenceHash(), tenant);
    for (String claim:claims) jdbc.update("UPDATE family_trial_claims SET tenant_id=?,claimed_at=?,evidence_hash=? WHERE identity_key=?",
        tenant,activation.activatedAt(),activation.evidenceHash(),claim);
    ledger.apply(fact(tenant, CommercialFact.SourceSystem.TRIAL, tenant, 1,
        activation.activatedAt(), end, CommercialFact.State.ACTIVE, activation.evidenceHash(), "system:family-activation"));
    audit.record(tenant, actor, "FAMILY_TRIAL_ACTIVATED", deviceId);
    return subscriptionView(tenant);
  }

  @Transactional(timeout = 10)
  Order createOrder(String tenant, String actor, String key, String planKey,Long requestedOfferVersion) {
    requireFamily(tenant, actor, true, true);
    String keyHash = keyHash(key);
    String requestHash = hash(planKey+"\u0000"+(requestedOfferVersion==null?1:requestedOfferVersion));
    lockAccount(tenant);
    Offer offer = offer(planKey,false);
    var existing = jdbc.query("SELECT " + ORDER_COLUMNS + ",request_hash FROM family_orders WHERE tenant_id=? AND actor_key=? AND key_hash=? FOR UPDATE",
        (r, i) -> new ExistingOrder(order(r), r.getString("request_hash")), tenant, ActorKeys.key(actor), keyHash);
    if (!existing.isEmpty()) {
      if (!requestHash.equals(existing.get(0).requestHash())) throw conflict("IDEMPOTENCY_KEY_REUSED");
      return existing.get(0).order();
    }
    if((requestedOfferVersion==null?1:requestedOfferVersion)!=offer.offerVersion())throw conflict("FAMILY_OFFER_CHANGED");
    if (gateway.available() && !hasVerifiedActivation(tenant)) throw conflict("ASSISTED_ACTIVATION_REQUIRED");
    // Serializing an unresolved purchase prevents two paid renewals with overlapping frozen periods.
    var pending = jdbc.queryForList("SELECT id FROM family_orders WHERE tenant_id=? AND (status='PAYMENT_PENDING' OR (status='CREATED' AND expires_at>?)) ORDER BY id FOR UPDATE",
        String.class, tenant, clock.millis());
    if (!pending.isEmpty()) throw conflict("FAMILY_ORDER_PENDING");
    long start = clock.millis();
    Long trialEnd = jdbc.queryForObject("SELECT trial_ends_at FROM family_subscription_accounts WHERE tenant_id=? FOR UPDATE", Long.class, tenant);
    var paidEnds = jdbc.queryForList("SELECT period_end FROM family_orders WHERE tenant_id=? AND status='PAID' ORDER BY period_end DESC LIMIT 1 FOR UPDATE", Long.class, tenant);
    Long paidEnd = paidEnds.isEmpty()?null:paidEnds.get(0);
    if (trialEnd != null) start = Math.max(start, trialEnd);
    if (paidEnd != null) start = Math.max(start, paidEnd);
    var localStart = Instant.ofEpochMilli(start).atZone(BILLING_ZONE);
    long end = (offer.period().equals("MONTH") ? localStart.plusMonths(1) : localStart.plusYears(1)).toInstant().toEpochMilli();
    String id = UUID.randomUUID().toString();
    jdbc.update("INSERT INTO family_orders(id,tenant_id,actor_key,key_hash,request_hash,plan_key,status,price_minor,currency,"
        + "period_start,period_end,created_at,expires_at) VALUES(?,?,?,?,?,?,'CREATED',?,'CNY',?,?,?,?)",
        id, tenant, ActorKeys.key(actor), keyHash, requestHash, planKey, offer.priceMinor(), start, end,
        clock.millis(), Math.addExact(clock.millis(), 900_000));
    audit.record(tenant, actor, "FAMILY_ORDER_CREATED", id);
    jdbc.update("UPDATE family_orders SET offer_version=? WHERE tenant_id=? AND id=?",offer.offerVersion(),tenant,id);
    return findOrder(tenant, id, false);
  }

  @Transactional(readOnly = true, timeout = 10)
  Order getOrder(String tenant, String actor, String id) {
    requireFamily(tenant, actor, false, false);
    return findOrder(tenant, id, false);
  }
  @Transactional(readOnly = true, timeout = 10)
  List<RefundRequest> refundsForOrder(String tenant,String actor,String orderId){
    requireFamily(tenant,actor,false,false);findOrder(tenant,orderId,false);
    return jdbc.query("SELECT "+REFUND_COLUMNS+" FROM family_refund_requests r WHERE r.tenant_id=? AND r.order_id=?",(r,i)->refund(r),tenant,orderId);
  }

  @Transactional(readOnly = true, timeout = 10)
  ItemPage<Order> orders(String tenant, String actor, int limit, String cursor) {
    requireFamily(tenant, actor, false, false);
    ItemPage.validate(limit, cursor);
    var rows = cursor == null
        ? jdbc.query("SELECT " + ORDER_COLUMNS + " FROM family_orders WHERE tenant_id=? ORDER BY id LIMIT ?", (r,i) -> order(r), tenant, limit+1)
        : jdbc.query("SELECT " + ORDER_COLUMNS + " FROM family_orders WHERE tenant_id=? AND id>? ORDER BY id LIMIT ?", (r,i) -> order(r), tenant, cursor, limit+1);
    return ItemPage.from(rows, limit, Order::id);
  }

  @Transactional(propagation=org.springframework.transaction.annotation.Propagation.NEVER)
  PaymentAttempt paymentAttempt(String tenant, String actor, String orderId, String key) {
    PaymentReservation reservation = transactions.execute(status -> reservePayment(tenant,actor,orderId,key));
    if (!"INITIATED".equals(reservation.attempt().status())) return reservation.attempt();
    var payment = gateway.createAppPayment(reservation.command());
    if (payment == null || payment.parameters().isEmpty()) throw FamilyCommerceConfiguration.unavailable();
    return transactions.execute(status -> {
      requireFamily(tenant,actor,true,true);
      lockAccount(tenant);
      Order order = findOrder(tenant,orderId,true);
      // The sales gate can close while the provider prepares the payment. Keep
      // the reserved identity for verification, but do not release parameters.
      if (!gateway.available()) throw FamilyCommerceConfiguration.unavailable();
      if (!hasVerifiedActivation(tenant)) throw conflict("ASSISTED_ACTIVATION_REQUIRED");
      var attempts = jdbc.query("SELECT id,order_id,status,provider_payload,created_at FROM family_payment_attempts WHERE id=? FOR UPDATE",
          (r,i) -> attempt(r),reservation.attempt().id());
      PaymentAttempt attempt = attempts.get(0);
      if (!"INITIATED".equals(attempt.status())) return attempt;
      if (!"PAYMENT_PENDING".equals(order.status())) throw conflict("FAMILY_ORDER_NOT_PAYABLE");
      jdbc.update("UPDATE family_payment_attempts SET status='READY',provider_payload=? WHERE id=?",encode(payment.parameters()),attempt.id());
      audit.record(tenant,actor,"FAMILY_PAYMENT_ATTEMPT_READY",attempt.id());
      return new PaymentAttempt(attempt.id(),orderId,"READY",payment.parameters(),attempt.createdAt());
    });
  }

  private PaymentReservation reservePayment(String tenant, String actor, String orderId, String key) {
    requireFamily(tenant, actor, true, true);
    String keyHash = keyHash(key);
    lockAccount(tenant);
    Order order = findOrder(tenant, orderId, true);
    var existing = jdbc.query("SELECT id,order_id,status,provider_payload,created_at FROM family_payment_attempts WHERE tenant_id=? AND actor_key=? AND key_hash=? FOR UPDATE",
        (r,i) -> attempt(r), tenant, ActorKeys.key(actor), keyHash);
    if (!existing.isEmpty()) {
      if (!orderId.equals(existing.get(0).orderId())) throw conflict("IDEMPOTENCY_KEY_REUSED");
      if (Set.of("INITIATED","READY").contains(existing.get(0).status()) && (!gateway.available() || !hasVerifiedActivation(tenant)))
        throw FamilyCommerceConfiguration.unavailable();
      return new PaymentReservation(existing.get(0),paymentCommand(order));
    }
    if (!gateway.available()) throw FamilyCommerceConfiguration.unavailable();
    if (!hasVerifiedActivation(tenant)) throw conflict("ASSISTED_ACTIVATION_REQUIRED");
    if (!order.status().equals("CREATED") || order.expiresAt() <= clock.millis()) throw conflict("FAMILY_ORDER_NOT_PAYABLE");
    String id = UUID.randomUUID().toString();
    jdbc.update("INSERT INTO family_payment_attempts(id,tenant_id,order_id,actor_key,key_hash,status,provider_payload,created_at)"
        + " VALUES(?,?,?,?,?,'INITIATED','{}',?)", id, tenant, orderId, ActorKeys.key(actor), keyHash, clock.millis());
    jdbc.update("UPDATE family_orders SET status='PAYMENT_PENDING' WHERE tenant_id=? AND id=?", tenant, orderId);
    audit.record(tenant, actor, "FAMILY_PAYMENT_ATTEMPT_CREATED", id);
    return new PaymentReservation(new PaymentAttempt(id,orderId,"INITIATED",Map.of(),clock.millis()),paymentCommand(order));
  }

  private FamilyPaymentGateway.PaymentCommand paymentCommand(Order order) {
    return new FamilyPaymentGateway.PaymentCommand(merchantId(order.id()),order.priceMinor(),order.currency(),"AI Manager 家庭会员",order.expiresAt());
  }

  @Transactional(readOnly = true, timeout = 10)
  List<PaymentAttempt> paymentAttempts(String tenant, String actor, String orderId) {
    requireFamily(tenant, actor, false, true);
    findOrder(tenant, orderId, false);
    boolean paymentAvailable = gateway.available();
    return jdbc.query("SELECT id,order_id,status,provider_payload,created_at FROM family_payment_attempts WHERE tenant_id=? AND order_id=?",
        (r,i) -> {
          PaymentAttempt attempt=attempt(r);
          return paymentAvailable?attempt:new PaymentAttempt(attempt.id(),attempt.orderId(),attempt.status(),Map.of(),attempt.createdAt());
        }, tenant, orderId);
  }

  @Transactional(propagation=org.springframework.transaction.annotation.Propagation.NEVER)
  Order verifyPayment(String tenant, String actor, String orderId) {
    transactions.executeWithoutResult(status -> { requireFamily(tenant, actor, true, true); lockAccount(tenant); findOrder(tenant,orderId,true); });
    if (!gateway.verificationAvailable()) throw FamilyCommerceConfiguration.unavailable();
    var evidence = gateway.queryPayment(merchantId(orderId));
    if (evidence == null) throw FamilyCommerceConfiguration.unavailable();
    return transactions.execute(status -> { requireFamily(tenant,actor,true,true); lockAccount(tenant); return applyPaymentEvidence(tenant,orderId,evidence); });
  }

  Order applyPaymentEvidence(String tenant, String orderId, FamilyPaymentGateway.PaymentEvidence evidence) {
    Order order=findOrder(tenant,orderId,true);
    if (!merchantId(orderId).equals(evidence.merchantOrderId())
        || evidence.priceMinor()!=null&&evidence.priceMinor()!=order.priceMinor()
        || evidence.currency()!=null&&!order.currency().equals(evidence.currency())
        || !hashValid(evidence.evidenceHash())) throw conflict("WECHAT_PAYMENT_EVIDENCE_MISMATCH");
    if (!"SUCCESS".equals(evidence.tradeState())) {
      if ("CLOSED".equals(evidence.tradeState()) && Set.of("CREATED","PAYMENT_PENDING").contains(order.status())) {
        jdbc.update("UPDATE family_orders SET status='CLOSED' WHERE tenant_id=? AND id=?",tenant,orderId);
        jdbc.update("UPDATE family_payment_attempts SET status='CLOSED' WHERE order_id=?",orderId);
        audit.record(tenant,"system:wechat-v3","FAMILY_ORDER_CLOSED",orderId);
        return findOrder(tenant,orderId,false);
      }
      return order;
    }
    acceptPayment(order, evidence);
    return findOrder(tenant, orderId, false);
  }

  /** 只有从未预约支付的订单可按本地期限结束；已发起或未知支付必须查微信。 */
  boolean expireUnstartedOrder(String tenant,String orderId) {
    Order order=findOrder(tenant,orderId,true);
    if(!"CREATED".equals(order.status())||order.expiresAt()>clock.millis())return false;
    if(jdbc.queryForObject("SELECT provider_transaction_id FROM family_orders WHERE tenant_id=? AND id=? FOR UPDATE",String.class,tenant,orderId)!=null)return false;
    if(!jdbc.queryForList("SELECT id FROM family_payment_attempts WHERE tenant_id=? AND order_id=? FOR UPDATE",String.class,tenant,orderId).isEmpty())return false;
    jdbc.update("UPDATE family_orders SET status='EXPIRED' WHERE tenant_id=? AND id=?",tenant,orderId);
    audit.record(tenant,"system:family-commerce","FAMILY_UNSTARTED_ORDER_EXPIRED",orderId);
    return true;
  }

  @Transactional(timeout = 10)
  RefundRequest requestRefund(String tenant, String actor, String orderId, String key, String reason) {
    requireFamily(tenant, actor, true, true);
    String keyHash = keyHash(key);
    if (reason == null || reason.isBlank() || reason.length()>200 || reason.chars().anyMatch(Character::isISOControl))
      throw DomainException.invalid("INVALID_REFUND_REASON");
    String normalized = reason.strip();
    String requestHash = hash(orderId + "\u0000" + normalized);
    lockAccount(tenant);
    Order order = findOrder(tenant, orderId, true);
    var existing = jdbc.query("SELECT "+REFUND_COLUMNS+" FROM family_refund_requests r WHERE r.tenant_id=? AND r.actor_key=? AND r.key_hash=? FOR UPDATE",
        (r,i) -> new ExistingRefund(refund(r),r.getString("request_hash")), tenant, ActorKeys.key(actor), keyHash);
    if (!existing.isEmpty()) {
      if (!requestHash.equals(existing.get(0).requestHash())) throw conflict("IDEMPOTENCY_KEY_REUSED");
      return existing.get(0).request();
    }
    if (!"PAID".equals(order.status())) throw conflict("FAMILY_ORDER_NOT_REFUNDABLE");
    if (!jdbc.queryForList("SELECT id FROM family_refund_requests WHERE order_id=? FOR UPDATE",String.class,orderId).isEmpty())
      throw conflict("FAMILY_REFUND_ALREADY_REQUESTED");
    String id = UUID.randomUUID().toString();
    jdbc.update("INSERT INTO family_refund_requests(id,tenant_id,order_id,actor_key,key_hash,request_hash,reason,status,price_minor,created_at)"
        + " VALUES(?,?,?,?,?,?,?,'AWAITING_REVIEW',?,?)", id, tenant, orderId, ActorKeys.key(actor), keyHash, requestHash, normalized, order.priceMinor(), clock.millis());
    audit.record(tenant, actor, "FAMILY_REFUND_REQUESTED", id);
    return findRefund(tenant, id, false);
  }

  /** Persist the refund ID before external submission, so an uncertain response can be reconciled. */
  @Transactional(propagation=org.springframework.transaction.annotation.Propagation.NEVER)
  RefundRequest submitRefund(String tenant, String actor, String refundId) {
    RefundRequest request=transactions.execute(status -> {
    requireFamily(tenant, actor, true, true); lockAccount(tenant);
    RefundRequest refund = findRefund(tenant, refundId, true);
    if ("AWAITING_REVIEW".equals(refund.status()) || "REQUESTED".equals(refund.status()) && jdbc.queryForObject("SELECT reviewed_at FROM family_refund_requests WHERE tenant_id=? AND id=? FOR UPDATE",Long.class,tenant,refundId)==null)
      throw conflict("REFUND_REVIEW_REQUIRED");
    if (!gateway.refundsAvailable()) throw FamilyCommerceConfiguration.unavailable();
    if (!"REQUESTED".equals(refund.status())) return refund;
    Order order = findOrder(tenant, refund.orderId(), true);
    if (!"PAID".equals(order.status())) throw conflict("FAMILY_ORDER_NOT_REFUNDABLE");
    return refund; });
    if(!"REQUESTED".equals(request.status()))return request;
    maintenance.getObject().reconcileRefund(tenant,refundId);
    return transactions.execute(status->{requireFamily(tenant,actor,true,true);lockAccount(tenant);return findRefund(tenant,refundId,false);});
  }

  @Transactional(propagation=org.springframework.transaction.annotation.Propagation.NEVER)
  RefundRequest verifyRefund(String tenant, String actor, String refundId) {
    transactions.executeWithoutResult(status->{requireFamily(tenant,actor,true,true);lockAccount(tenant);findRefund(tenant,refundId,true);});
    if (!gateway.verificationAvailable()) throw FamilyCommerceConfiguration.unavailable();
    var evidence = gateway.queryRefund(merchantId(refundId));
    if (evidence == null) throw FamilyCommerceConfiguration.unavailable();
    return transactions.execute(status->{requireFamily(tenant,actor,true,true);lockAccount(tenant);return applyRefundEvidence(tenant,refundId,evidence);});
  }

  RefundRequest applyRefundEvidence(String tenant,String refundId,FamilyPaymentGateway.RefundEvidence evidence) {
    RefundRequest refund=findRefund(tenant,refundId,true);Order order=findOrder(tenant,refund.orderId(),true);
    recordRefundOutcome(order,refund,evidence);return findRefund(tenant,refundId,false);
  }
  void markRefundSubmitted(String tenant,String refundId) {
    RefundRequest refund=findRefund(tenant,refundId,true);
    if("REQUESTED".equals(refund.status())){
      jdbc.update("UPDATE family_refund_requests SET status='PROCESSING' WHERE tenant_id=? AND id=?",tenant,refundId);
      audit.record(tenant,"system:wechat-v3","FAMILY_REFUND_SUBMITTED",refundId);
    }
  }

  @Transactional(readOnly = true, timeout = 10)
  ItemPage<RefundRequest> refunds(String tenant, String actor, int limit, String cursor) {
    requireFamily(tenant, actor, false, false);
    ItemPage.validate(limit, cursor);
    var rows = jdbc.query("SELECT "+REFUND_COLUMNS+" FROM family_refund_requests r WHERE r.tenant_id=? AND r.id>? ORDER BY r.id LIMIT ?",
        (r,i) -> refund(r), tenant, cursor == null ? "" : cursor, limit+1);
    return ItemPage.from(rows, limit, RefundRequest::id);
  }

  @Transactional(readOnly = true, timeout = 10)
  RefundRequest getRefund(String tenant, String actor, String id) {
    requireFamily(tenant, actor, false, false);
    return findRefund(tenant, id, false);
  }

  /** The verified provider envelope, order mutation, ledger event and inbox commit atomically. */
  @Transactional(timeout = 10)
  void notification(Map<String,String> headers, String rawBody) {
    if (rawBody == null || rawBody.getBytes(StandardCharsets.UTF_8).length>65536)
      throw DomainException.invalid("INVALID_WECHAT_NOTIFICATION");
    var notification = gateway.verifyNotification(headers, rawBody);
    if (notification == null || notification.eventId() == null || notification.eventId().isBlank()
        || notification.eventId().length()>100 || !hashValid(notification.evidenceHash())
        || !hash(rawBody).equals(notification.evidenceHash())) throw DomainException.invalid("INVALID_WECHAT_NOTIFICATION");
    String merchantOrder;
    if ("PAYMENT".equals(notification.eventType()) && notification.payment()!=null && notification.refund()==null)
      merchantOrder = notification.payment().merchantOrderId();
    else if ("REFUND".equals(notification.eventType()) && notification.refund()!=null && notification.payment()==null)
      merchantOrder = notification.refund().merchantOrderId();
    else throw DomainException.invalid("INVALID_WECHAT_NOTIFICATION");
    Order order = findMerchantOrder(merchantOrder);
    lockAccount(order.tenantId());
    order = findOrder(order.tenantId(), order.id(), true);
    var previous = jdbc.queryForList("SELECT event_type,order_id,evidence_hash FROM family_payment_inbox WHERE event_id=? FOR UPDATE", notification.eventId());
    if (!previous.isEmpty()) {
      var prior = previous.get(0);
      if (!notification.evidenceHash().equals(prior.get("evidence_hash")) || !order.id().equals(prior.get("order_id"))
          || !notification.eventType().equals(prior.get("event_type"))) throw conflict("WECHAT_NOTIFICATION_REPLAY_CONFLICT");
      return;
    }
    if (notification.payment()!=null) acceptPayment(order, notification.payment());
    else {
      String refundId = canonicalMerchantId(notification.refund().merchantRefundId());
      RefundRequest refund = findRefund(order.tenantId(), refundId, true);
      recordRefundOutcome(order, refund, notification.refund());
    }
    jdbc.update("INSERT INTO family_payment_inbox(event_id,event_type,order_id,evidence_hash,accepted_at) VALUES(?,?,?,?,?)",
        notification.eventId(), notification.eventType(), order.id(), notification.evidenceHash(), clock.millis());
  }

  private void acceptPayment(Order order, FamilyPaymentGateway.PaymentEvidence evidence) {
    if (!merchantId(order.id()).equals(evidence.merchantOrderId()) || !"SUCCESS".equals(evidence.tradeState())
        || evidence.priceMinor()==null || order.priceMinor()!=evidence.priceMinor() || !order.currency().equals(evidence.currency())
        || !referenceValid(evidence.providerTransactionId()) || !hashValid(evidence.evidenceHash())
        || evidence.paidAt()<order.createdAt() || evidence.paidAt()>clock.millis()+300000)
      throw conflict("WECHAT_PAYMENT_EVIDENCE_MISMATCH");
    if ("PAID".equals(order.status()) || "REFUNDED".equals(order.status())) {
      if (!evidence.providerTransactionId().equals(transactionId(order.id()))) throw conflict("WECHAT_PAYMENT_EVIDENCE_MISMATCH");
      return;
    }
    // 已签名的迟到支付事实仍应入账；保留原订单周期，不因关单竞态吞掉真实付款。
    if (!Set.of("CREATED","PAYMENT_PENDING","CLOSED").contains(order.status())) throw conflict("FAMILY_ORDER_NOT_PAYABLE");
    jdbc.update("UPDATE family_orders SET status='PAID',provider_transaction_id=?,paid_at=? WHERE tenant_id=? AND id=?",
        evidence.providerTransactionId(), evidence.paidAt(), order.tenantId(), order.id());
    jdbc.update("UPDATE family_payment_attempts SET status='PAID' WHERE order_id=?", order.id());
    ledger.apply(fact(order.tenantId(), CommercialFact.SourceSystem.WECHAT_PAY, order.id(), 1,
        order.periodStart(), order.periodEnd(), CommercialFact.State.ACTIVE, evidence.evidenceHash(), "system:wechat-v3"));
    audit.record(order.tenantId(), "system:wechat-v3", "FAMILY_PAYMENT_VERIFIED", order.id());
  }

  private void acceptRefund(Order order, RefundRequest refund, FamilyPaymentGateway.RefundEvidence evidence) {
    if (!order.id().equals(refund.orderId()) || !merchantId(order.id()).equals(evidence.merchantOrderId())
        || !merchantId(refund.id()).equals(evidence.merchantRefundId()) || !"SUCCESS".equals(evidence.refundState())
        || !referenceValid(evidence.providerRefundId()) || !referenceValid(evidence.providerTransactionId())
        || !evidence.providerTransactionId().equals(transactionId(order.id()))
        || order.priceMinor()!=evidence.priceMinor() || !order.currency().equals(evidence.currency())
        || !hashValid(evidence.evidenceHash()) || evidence.refundedAt()<refund.createdAt() || evidence.refundedAt()>clock.millis()+300000)
      throw conflict("WECHAT_REFUND_EVIDENCE_MISMATCH");
    if ("REFUNDED".equals(order.status())) {
      String prior = jdbc.queryForObject("SELECT provider_refund_id FROM family_refund_requests WHERE id=? FOR UPDATE", String.class, refund.id());
      if (!evidence.providerRefundId().equals(prior)) throw conflict("WECHAT_REFUND_EVIDENCE_MISMATCH");
      return;
    }
    if (!"PAID".equals(order.status())) throw conflict("FAMILY_ORDER_NOT_REFUNDABLE");
    jdbc.update("UPDATE family_orders SET status='REFUNDED' WHERE tenant_id=? AND id=?", order.tenantId(), order.id());
    jdbc.update("UPDATE family_refund_requests SET status='REFUNDED',provider_refund_id=?,refunded_at=? WHERE tenant_id=? AND id=?",
        evidence.providerRefundId(), evidence.refundedAt(), order.tenantId(), refund.id());
    ledger.apply(fact(order.tenantId(), CommercialFact.SourceSystem.WECHAT_PAY, order.id(), 2,
        order.periodStart(), order.periodEnd(), CommercialFact.State.REVOKED, evidence.evidenceHash(), "system:wechat-v3"));
    audit.record(order.tenantId(), "system:wechat-v3", "FAMILY_REFUND_VERIFIED", refund.id());
  }

  private void recordRefundOutcome(Order order,RefundRequest refund,FamilyPaymentGateway.RefundEvidence evidence) {
    if ("SUCCESS".equals(evidence.refundState())) { acceptRefund(order,refund,evidence); recordRefundAcceptance(order,refund,evidence); return; }
    if (!order.id().equals(refund.orderId()) || !merchantId(order.id()).equals(evidence.merchantOrderId())
        || !merchantId(refund.id()).equals(evidence.merchantRefundId()) || !referenceValid(evidence.providerRefundId())
        || !referenceValid(evidence.providerTransactionId()) || !evidence.providerTransactionId().equals(transactionId(order.id()))
        || order.priceMinor()!=evidence.priceMinor() || !order.currency().equals(evidence.currency()) || !hashValid(evidence.evidenceHash()))
      throw conflict("WECHAT_REFUND_EVIDENCE_MISMATCH");
    recordRefundAcceptance(order,refund,evidence);
    if("PROCESSING".equals(evidence.refundState())&&"REQUESTED".equals(refund.status()))
      jdbc.update("UPDATE family_refund_requests SET status='PROCESSING',provider_refund_id=? WHERE tenant_id=? AND id=?",evidence.providerRefundId(),order.tenantId(),refund.id());
    if (Set.of("CLOSED","ABNORMAL").contains(evidence.refundState()) && !"REFUNDED".equals(refund.status())) {
      jdbc.update("UPDATE family_refund_requests SET status=?,provider_refund_id=? WHERE tenant_id=? AND id=?",
          evidence.refundState(),evidence.providerRefundId(),order.tenantId(),refund.id());
      audit.record(order.tenantId(),"system:wechat-v3","FAMILY_REFUND_REQUIRES_ATTENTION",refund.id());
    }
  }

  /** 微信 create_time 是受理事实；不能用本机发起、审核或到账时间替代账单日期。 */
  private void recordRefundAcceptance(Order order,RefundRequest refund,FamilyPaymentGateway.RefundEvidence evidence) {
    if(evidence.acceptedAt()==null)return;
    Long previous=jdbc.queryForObject("SELECT provider_accepted_at FROM family_refund_requests WHERE tenant_id=? AND id=? FOR UPDATE",Long.class,order.tenantId(),refund.id());
    if(evidence.acceptedAt()<refund.createdAt()-300000L||evidence.acceptedAt()>clock.millis()+300000L
        ||(previous!=null&&!previous.equals(evidence.acceptedAt()))
        ||(evidence.refundedAt()>0&&evidence.acceptedAt()>evidence.refundedAt()+300000L))throw conflict("WECHAT_REFUND_EVIDENCE_MISMATCH");
    jdbc.update("UPDATE family_refund_requests SET provider_accepted_at=? WHERE tenant_id=? AND id=?",evidence.acceptedAt(),order.tenantId(),refund.id());
  }

  private Order findMerchantOrder(String merchantOrder) {
    String id = canonicalMerchantId(merchantOrder);
    var tenants = jdbc.queryForList("SELECT tenant_id FROM family_orders WHERE id=?", String.class, id);
    if (tenants.isEmpty()) throw new DomainException(HttpStatus.NOT_FOUND, "FAMILY_ORDER_NOT_FOUND");
    return findOrder(tenants.get(0), id, false);
  }

  private String transactionId(String orderId) {
    return jdbc.queryForObject("SELECT provider_transaction_id FROM family_orders WHERE id=? FOR UPDATE", String.class, orderId);
  }

  private RefundRequest findRefund(String tenant, String id, boolean lock) {
    canonicalId(id);
    var requests = jdbc.query("SELECT "+REFUND_COLUMNS+" FROM family_refund_requests r WHERE r.tenant_id=? AND r.id=?" + (lock ? " FOR UPDATE" : ""), (r,i) -> refund(r), tenant,id);
    if (requests.isEmpty()) throw new DomainException(HttpStatus.NOT_FOUND,"FAMILY_REFUND_NOT_FOUND");
    return requests.get(0);
  }

  private RefundRequest refund(ResultSet r) throws SQLException {
    return new RefundRequest(r.getString("id"),r.getString("order_id"),r.getString("status"),r.getString("reason"),
        r.getInt("price_minor"),"CNY",r.getLong("created_at"),gateway.available(),r.getString("review_note"));
  }

  private Offer offer(String key,boolean payable) {
    if (!Set.of("FAMILY_MONTH","FAMILY_YEAR").contains(key))throw DomainException.invalid("INVALID_FAMILY_PLAN");
    var rows=jdbc.queryForList("SELECT version,price_minor FROM family_product_offers WHERE plan_key=?"+(currentRead()?" FOR UPDATE":""),key);
    if(rows.size()!=1)throw DomainException.invalid("INVALID_FAMILY_PLAN");
    return new Offer(key,"FAMILY_MONTH".equals(key)?"MONTH":"YEAR",((Number)rows.get(0).get("price_minor")).intValue(),"CNY",3,"MANUAL",payable,((Number)rows.get(0).get("version")).longValue());
  }

  private Subscription subscriptionView(String tenant) {
    long now = clock.millis();
    var sources = jdbc.query("SELECT source_system,active_from,expires_at FROM commercial_sources WHERE tenant_id=?"
        + " AND source_system IN ('WECHAT_PAY','TRIAL') AND state='ACTIVE' ORDER BY active_from,expires_at FOR UPDATE",
        (r,i) -> new Period(r.getString(1), r.getLong(2), r.getLong(3)), tenant);
    Period active = sources.stream().filter(p -> p.start()<=now && p.end()>now)
        .max(java.util.Comparator.comparingLong(Period::end)).orElse(null);
    Period latest = sources.stream().max(java.util.Comparator.comparingLong(Period::end)).orElse(null);
    String status = active != null ? ("TRIAL".equals(active.source()) ? "TRIAL" : "ACTIVE")
        : latest == null ? "NONE" : latest.start()>now ? "SCHEDULED" : "EXPIRED";
    Period display = active == null ? latest : active;
    return new Subscription(tenant, status, display == null ? null : display.start(), display == null ? null : display.end(),
        active==null?1:3, "MANUAL", gateway.available() && hasVerifiedActivation(tenant), false, "Asia/Shanghai");
  }

  private boolean hasVerifiedActivation(String tenant) {
    String locking=currentRead()?" FOR UPDATE":"";
    var validTrial=jdbc.queryForList("SELECT tenant_id FROM family_subscription_accounts WHERE tenant_id=?"
        +" AND trial_started_at<=? AND trial_ends_at>? AND trial_evidence_hash IS NOT NULL"+locking,String.class,tenant,clock.millis(),clock.millis());
    if (!validTrial.isEmpty()) return true;
    var devices=jdbc.queryForList("SELECT id,registration_id,created_at FROM devices WHERE tenant_id=? AND platform='ANDROID' AND state='ACTIVE' ORDER BY id LIMIT 10"+locking,tenant);
    for (var device:devices) {
      String id=(String)device.get("id");
      try {
        var activation=activationGate.verify(tenant,id);
        if (activationValid(tenant,id,activation) && java.util.Objects.equals(activation.registrationId(),device.get("registration_id"))
            && activation.activatedAt()>=((Number)device.get("created_at")).longValue()) return true;
      } catch (DomainException unverified) {
        // Availability is a projection; a rejected activation never becomes a selling signal.
      }
    }
    return false;
  }

  private boolean currentRead() {
    return org.springframework.transaction.support.TransactionSynchronizationManager.isActualTransactionActive()
        && !org.springframework.transaction.support.TransactionSynchronizationManager.isCurrentTransactionReadOnly();
  }

  private boolean activationValid(String tenant,String device,FamilyAssistedActivationGate.VerifiedActivation activation) {
    return activation!=null && tenant.equals(activation.tenantId()) && device.equals(activation.deviceId())
        && activation.activatedAt()>=0 && activation.activatedAt()<=clock.millis() && hashValid(activation.evidenceHash());
  }

  private void requireFamily(String tenant, String actor, boolean write, boolean ownerOnly) {
    Role[] roles = ownerOnly ? new Role[] {Role.OWNER} : new Role[] {Role.OWNER, Role.GUARDIAN};
    if (write) access.requireWriteRole(tenant, actor, roles); else access.requireRole(tenant, actor, roles);
    String kind = jdbc.queryForObject("SELECT kind FROM tenants WHERE id=?", String.class, tenant);
    if (!"FAMILY".equals(kind)) throw DomainException.denied();
  }

  void lockAccount(String tenant) {
    // Membership authority is locked first. Commercial account precedes every family domain row,
    // including enrollment reservations, device selection and the nested ledger mutation.
    jdbc.update("INSERT INTO commercial_accounts(tenant_id,version) VALUES(?,0) ON DUPLICATE KEY UPDATE tenant_id=tenant_id",tenant);
    jdbc.queryForObject("SELECT version FROM commercial_accounts WHERE tenant_id=? FOR UPDATE",Long.class,tenant);
    jdbc.update("INSERT INTO family_subscription_accounts(tenant_id,version) VALUES(?,0) ON DUPLICATE KEY UPDATE tenant_id=tenant_id", tenant);
    jdbc.queryForObject("SELECT version FROM family_subscription_accounts WHERE tenant_id=? FOR UPDATE", Long.class, tenant);
  }

  private Order findOrder(String tenant, String id, boolean lock) {
    canonicalId(id);
    var orders = jdbc.query("SELECT " + ORDER_COLUMNS + " FROM family_orders WHERE tenant_id=? AND id=?" + (lock ? " FOR UPDATE" : ""),
        (r,i) -> order(r), tenant, id);
    if (orders.isEmpty()) throw new DomainException(HttpStatus.NOT_FOUND, "FAMILY_ORDER_NOT_FOUND");
    return orders.get(0);
  }

  private static Order order(ResultSet r) throws SQLException {
    return new Order(r.getString("id"), r.getString("tenant_id"), r.getString("plan_key"), r.getString("status"),
        r.getInt("price_minor"), r.getString("currency"), r.getLong("period_start"), r.getLong("period_end"),
        r.getLong("created_at"), r.getLong("expires_at"));
  }

  private PaymentAttempt attempt(ResultSet r) throws SQLException {
    try {
      String status = r.getString("status");
      Map<String,String> parameters = Map.of();
      // Only a ready attempt may expose parameters that launch the payment SDK.
      if ("READY".equals(status)) {
        parameters = json.readValue(r.getString("provider_payload"), new com.fasterxml.jackson.core.type.TypeReference<Map<String,String>>() {});
      }
      return new PaymentAttempt(r.getString("id"), r.getString("order_id"), status, parameters, r.getLong("created_at"));
    } catch (JsonProcessingException invalid) { throw new IllegalStateException("Invalid stored provider parameters", invalid); }
  }

  private CommercialFact fact(String tenant, CommercialFact.SourceSystem source, String reference, long revision,
      long from, long until, CommercialFact.State state, String evidence, String verifier) {
    return new CommercialFact(tenant, source, reference, revision, "FAMILY", CommercialFact.CapacityKind.BASE, 3,
        Set.of(CommercialFact.Feature.ADVANCED_SCHEDULES, CommercialFact.Feature.AI_INSIGHTS,
            CommercialFact.Feature.FAMILY_MULTI_DEVICE,CommercialFact.Feature.FAMILY_ASSISTED_LIMITS,
            CommercialFact.Feature.REPORT_HISTORY), from, until, state, evidence, verifier);
  }

  private String encode(Object value) {
    try { return json.writeValueAsString(value); }
    catch (JsonProcessingException invalid) { throw new IllegalStateException("Unable to encode payment parameters", invalid); }
  }

  static String merchantId(String id) { return id.replace("-", ""); }
  private static String canonicalMerchantId(String id) {
    if (id == null || !id.matches("[0-9a-f]{32}")) throw DomainException.invalid("INVALID_WECHAT_MERCHANT_REFERENCE");
    return id.substring(0,8)+"-"+id.substring(8,12)+"-"+id.substring(12,16)+"-"+id.substring(16,20)+"-"+id.substring(20);
  }
  private static boolean referenceValid(String value) { return value != null && value.matches("[A-Za-z0-9_-]{1,80}"); }
  static String hash(String value) {
    try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8))); }
    catch (NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
  }
  private static String keyHash(String key) {
    if (key == null || key.isBlank() || key.length()>100 || key.chars().anyMatch(Character::isISOControl))
      throw DomainException.invalid("INVALID_IDEMPOTENCY_KEY");
    return hash(key);
  }
  private static void canonicalId(String id) {
    try { if (id == null || !UUID.fromString(id).toString().equals(id)) throw new IllegalArgumentException(); }
    catch (IllegalArgumentException invalid) { throw DomainException.invalid("INVALID_RESOURCE_ID"); }
  }
  private static boolean hashValid(String hash) { return hash != null && hash.matches("[0-9a-f]{64}"); }
  private static DomainException conflict(String code) { return new DomainException(HttpStatus.CONFLICT, code); }

  record Offer(String planKey, String period, int priceMinor, String currency, int childDeviceLimit, String renewalMode, boolean paymentAvailable,long offerVersion) {}
  record Offers(List<Offer> items) {}
  record Subscription(String tenantId, String status, Long periodStart, Long periodEnd, int childDeviceLimit,
      String renewalMode, boolean paymentAvailable, boolean trialEligible, String billingTimeZone) {}
  record Order(String id, String tenantId, String planKey, String status, int priceMinor, String currency,
      long periodStart, long periodEnd, long createdAt, long expiresAt) {}
  record PaymentAttempt(String id, String orderId, String status, Map<String,String> parameters, long createdAt) {}
  record RefundRequest(String id, String orderId, String status, String reason, int priceMinor, String currency,
      long createdAt, boolean paymentAvailable,String reviewNote) {
    RefundRequest(String id,String orderId,String status,String reason,int priceMinor,String currency,long createdAt,boolean paymentAvailable){
      this(id,orderId,status,reason,priceMinor,currency,createdAt,paymentAvailable,null);
    }
  }
  private record ExistingOrder(Order order, String requestHash) {}
  private record ExistingRefund(RefundRequest request, String requestHash) {}
  private record PaymentReservation(PaymentAttempt attempt, FamilyPaymentGateway.PaymentCommand command) {}
  private record Period(String source, long start, long end) {}
}
