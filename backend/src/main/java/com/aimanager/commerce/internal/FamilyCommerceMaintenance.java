package com.aimanager.commerce.internal;

import com.aimanager.shared.DomainException;
import java.time.Clock;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionTemplate;

/** 短事务抢占持久租约，事务之外访问微信，再核对租约代际应用真实证据。 */
@Service
class FamilyCommerceMaintenance {
  private static final long LEASE_MILLIS=30_000;
  private final JdbcTemplate jdbc;
  private final FamilySubscriptionService subscriptions;
  private final FamilyPaymentGateway gateway;
  private final Clock clock;
  private final TransactionTemplate transactions;

  FamilyCommerceMaintenance(JdbcTemplate jdbc,FamilySubscriptionService subscriptions,
      FamilyPaymentGateway gateway,Clock clock,PlatformTransactionManager manager) {
    this.jdbc=jdbc;this.subscriptions=subscriptions;this.gateway=gateway;this.clock=clock;
    transactions=new TransactionTemplate(manager);transactions.setTimeout(10);
  }

  /** 售后操作只预约同一原单；已有在途租约不会被人工点击抢走。 */
  void enqueueOrderVerification(String tenant,String id) {enqueue(tenant,id,"ORDER");}
  void enqueueRefundVerification(String tenant,String id) {enqueue(tenant,id,"REFUND");}
  private void enqueue(String tenant,String id,String kind) {
    transactions.executeWithoutResult(status->{
      subscriptions.lockAccount(tenant);entity(tenant,id,kind);
      ensure(tenant,id,kind);
      jdbc.update("UPDATE family_commerce_work SET state='READY',next_attempt_at=?,last_code=NULL,updated_at=?"
          +" WHERE job_key=? AND lease_until<=?",clock.millis(),clock.millis(),key(kind,id),clock.millis());
    });
  }

  @Transactional(propagation=Propagation.NEVER)
  void reconcileOrder(String tenant,String id) {run(tenant,id,"ORDER");}
  @Transactional(propagation=Propagation.NEVER)
  void reconcileRefund(String tenant,String id) {run(tenant,id,"REFUND");}

  @Transactional(propagation=Propagation.NEVER)
  int sweep(int limit) {
    if(limit<1||limit>100)throw DomainException.invalid("INVALID_COMMERCE_BATCH_SIZE");
    if(!gateway.verificationAvailable())return 0;
    long now=clock.millis();
    List<Map<String,Object>> orders=jdbc.queryForList("SELECT o.tenant_id,o.id FROM family_orders o"
        +" LEFT JOIN family_commerce_work w ON w.job_key=CONCAT('ORDER:',o.id)"
        +" WHERE (o.status='PAYMENT_PENDING' OR (o.status='CREATED' AND o.expires_at<=?))"
        +" AND (w.job_key IS NULL OR (w.state NOT IN ('DONE','ATTENTION') AND w.next_attempt_at<=? AND w.lease_until<=?))"
        +" ORDER BY o.expires_at,o.id LIMIT ?",now,now,now,limit);
    List<Map<String,Object>> refunds=jdbc.queryForList("SELECT r.tenant_id,r.id FROM family_refund_requests r"
        +" LEFT JOIN family_commerce_work w ON w.job_key=CONCAT('REFUND:',r.id)"
        +" WHERE ((r.status='REQUESTED' AND r.reviewed_at IS NOT NULL) OR r.status='PROCESSING')"
        +" AND (w.job_key IS NULL OR (w.state NOT IN ('DONE','ATTENTION') AND w.next_attempt_at<=? AND w.lease_until<=?))"
        +" ORDER BY r.created_at,r.id LIMIT ?",now,now,limit);
    // 人工补查终态或异常单同样仅查询原单，不重审、不新建退款。
    var queued=jdbc.queryForList("SELECT tenant_id,entity_id,kind FROM family_commerce_work WHERE state='READY'"
        +" AND next_attempt_at<=? AND lease_until<=? ORDER BY next_attempt_at,job_key LIMIT ?",now,now,limit);
    var candidates=new java.util.LinkedHashMap<String,Candidate>();
    int pages=Math.max(queued.size(),Math.max(orders.size(),refunds.size()));
    for(int index=0;index<pages;index++){
      if(index<queued.size())candidate(candidates,queued.get(index),true,null);
      if(index<orders.size())candidate(candidates,orders.get(index),false,"ORDER");
      if(index<refunds.size())candidate(candidates,refunds.get(index),false,"REFUND");
    }
    int count=0;
    long deadline=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(20);
    for(var candidate:candidates.values()){
      if(count>=limit||System.nanoTime()>=deadline)break;
      run(candidate.tenant(),candidate.id(),candidate.kind());count++;
    }
    return count;
  }
  private static void candidate(Map<String,Candidate> candidates,Map<String,Object> row,boolean queued,String kind){
    String id=(String)row.get(queued?"entity_id":"id");String type=queued?(String)row.get("kind"):kind;
    candidates.putIfAbsent(key(type,id),new Candidate((String)row.get("tenant_id"),id,type));
  }
  private record Candidate(String tenant,String id,String kind){}

  private void run(String tenant,String id,String kind) {
    if(!gateway.verificationAvailable())throw FamilyCommerceConfiguration.unavailable();
    Reservation reservation=transactions.execute(status->reserve(tenant,id,kind));
    if(reservation==null)return;
    try {
      if("ORDER".equals(kind))order(reservation);else refund(reservation);
    } catch(RuntimeException failure) {
      finish(reservation,null,failure instanceof DomainException domain?domain.errorCode():failure instanceof FamilyPaymentGateway.ResourceMissing?"WECHAT_PROVIDER_RESOURCE_NOT_EXISTS":"FAMILY_PROVIDER_RESULT_UNKNOWN");
      // 定时维护持久记录可恢复的失败；交互式调用随后读取原订单事实。
    }
  }

  private void order(Reservation reservation) {
    String merchant=FamilySubscriptionService.merchantId(reservation.id());
    var evidence=gateway.queryPayment(merchant);
    if(evidence==null)throw FamilyCommerceConfiguration.unavailable();
    validatePayment(reservation,evidence);
    if("NOTPAY".equals(evidence.tradeState()) && reservation.expiresAt()<=clock.millis()
        && Set.of("CREATED","PAYMENT_PENDING").contains(reservation.status())) {
      // 即使关单应答未知，也再次查原单；只有最终 CLOSED 才在本地关单。
      try {gateway.closePayment(merchant);}catch(RuntimeException uncertain){/* 最后的查单承担事实确认。 */}
      evidence=gateway.queryPayment(merchant);
      if(evidence==null)throw FamilyCommerceConfiguration.unavailable();
      validatePayment(reservation,evidence);
    }
    var result=evidence;
    finish(reservation,()->subscriptions.applyPaymentEvidence(reservation.tenant(),reservation.id(),result),
        Set.of("SUCCESS","CLOSED").contains(evidence.tradeState())?"DONE":null);
  }

  private void refund(Reservation reservation) {
    FamilyPaymentGateway.RefundEvidence evidence=null;
    boolean confirmedMissing=false;
    boolean maySubmit="REQUESTED".equals(reservation.status())&&reservation.approved();
    if(!maySubmit || reservation.attempt()>1) {
      try {evidence=gateway.queryRefund(FamilySubscriptionService.merchantId(reservation.id()));}
      catch(FamilyPaymentGateway.ResourceMissing absent){
        if(!maySubmit)throw absent;
        confirmedMissing=true;
      }
      if(evidence==null&&!maySubmit)throw FamilyCommerceConfiguration.unavailable();
      if(evidence==null&&reservation.attempt()>1&&!confirmedMissing){
        // 只有可信的 RESOURCE_NOT_EXISTS 分支可允许重试；普通空结果保持未知。
        throw FamilyCommerceConfiguration.unavailable();
      }
    }
    if(evidence!=null) {
      var result=evidence;
      finish(reservation,()->subscriptions.applyRefundEvidence(reservation.tenant(),reservation.id(),result),
          "SUCCESS".equals(evidence.refundState())?"DONE":Set.of("CLOSED","ABNORMAL").contains(evidence.refundState())?"ATTENTION":null);
      return;
    }
    if(!maySubmit||!gateway.refundsAvailable())throw FamilyCommerceConfiguration.unavailable();
    gateway.submitRefund(new FamilyPaymentGateway.RefundCommand(FamilySubscriptionService.merchantId(reservation.id()),
        FamilySubscriptionService.merchantId(reservation.orderId()),reservation.transactionId(),reservation.price(),reservation.currency(),reservation.reason()));
    finish(reservation,()->subscriptions.markRefundSubmitted(reservation.tenant(),reservation.id()),null);
  }

  private void validatePayment(Reservation reservation,FamilyPaymentGateway.PaymentEvidence evidence) {
    if(!FamilySubscriptionService.merchantId(reservation.id()).equals(evidence.merchantOrderId())
        ||evidence.priceMinor()!=null&&reservation.price()!=evidence.priceMinor()
        ||evidence.currency()!=null&&!reservation.currency().equals(evidence.currency())
        ||evidence.evidenceHash()==null||!evidence.evidenceHash().matches("[0-9a-f]{64}"))
      throw new DomainException(HttpStatus.CONFLICT,"WECHAT_PAYMENT_EVIDENCE_MISMATCH");
  }

  private Reservation reserve(String tenant,String id,String kind) {
    subscriptions.lockAccount(tenant);
    Map<String,Object> row=entity(tenant,id,kind);
    ensure(tenant,id,kind);
    Map<String,Object> work=jdbc.queryForMap("SELECT * FROM family_commerce_work WHERE job_key=? FOR UPDATE",key(kind,id));
    long now=clock.millis();
    if(((Number)work.get("lease_until")).longValue()>now || ((Number)work.get("next_attempt_at")).longValue()>now)return null;
    if(!"READY".equals(work.get("state"))&&!"LEASED".equals(work.get("state")))return null;
    if("ORDER".equals(kind)&&subscriptions.expireUnstartedOrder(tenant,id)) {
      jdbc.update("UPDATE family_commerce_work SET state='DONE',lease_until=0,last_code='UNSTARTED_ORDER_EXPIRED',updated_at=? WHERE job_key=?",now,key(kind,id));
      return null;
    }
    long generation=((Number)work.get("generation")).longValue()+1;
    int attempt=((Number)work.get("attempts")).intValue()+1;
    jdbc.update("UPDATE family_commerce_work SET state='LEASED',generation=?,lease_until=?,attempts=?,updated_at=? WHERE job_key=?",
        generation,now+LEASE_MILLIS,attempt,now,key(kind,id));
    boolean isRefund="REFUND".equals(kind);
    if(isRefund) {
      var order=jdbc.queryForMap("SELECT * FROM family_orders WHERE tenant_id=? AND id=? FOR UPDATE",tenant,row.get("order_id"));
      return new Reservation(tenant,id,kind,generation,attempt,(String)row.get("status"),0,
          (String)order.get("id"),(String)order.get("provider_transaction_id"),((Number)order.get("price_minor")).intValue(),
          (String)order.get("currency"),(String)row.get("reason"),row.get("reviewed_at")!=null&&"PAID".equals(order.get("status"))
              &&((Number)row.get("price_minor")).intValue()==((Number)order.get("price_minor")).intValue());
    }
    return new Reservation(tenant,id,kind,generation,attempt,(String)row.get("status"),((Number)row.get("expires_at")).longValue(),
        id,null,((Number)row.get("price_minor")).intValue(),(String)row.get("currency"),null,false);
  }

  private void finish(Reservation reservation,Runnable mutation,String outcome) {
    transactions.executeWithoutResult(status->{
      subscriptions.lockAccount(reservation.tenant());entity(reservation.tenant(),reservation.id(),reservation.kind());
      var work=jdbc.queryForMap("SELECT generation,lease_until FROM family_commerce_work WHERE job_key=? FOR UPDATE",key(reservation.kind(),reservation.id()));
      if(((Number)work.get("generation")).longValue()!=reservation.generation()||((Number)work.get("lease_until")).longValue()<=clock.millis())return;
      if(mutation!=null)mutation.run();
      String state="DONE".equals(outcome)?"DONE":"ATTENTION".equals(outcome)?"ATTENTION":"READY";
      long delay=Math.min(3_600_000L,60_000L*(1L<<Math.min(reservation.attempt()-1,6)));
      jdbc.update("UPDATE family_commerce_work SET state=?,lease_until=0,next_attempt_at=?,last_code=?,updated_at=? WHERE job_key=?",
          state,clock.millis()+delay,outcome,clock.millis(),key(reservation.kind(),reservation.id()));
    });
  }

  private Map<String,Object> entity(String tenant,String id,String kind) {
    try{if(!UUID.fromString(id).toString().equals(id))throw new IllegalArgumentException();}catch(RuntimeException invalid){throw DomainException.invalid("INVALID_RESOURCE_ID");}
    String table="ORDER".equals(kind)?"family_orders":"family_refund_requests";
    var rows=jdbc.queryForList("SELECT * FROM "+table+" WHERE tenant_id=? AND id=? FOR UPDATE",tenant,id);
    if(rows.size()!=1)throw new DomainException(HttpStatus.NOT_FOUND,"ORDER".equals(kind)?"FAMILY_ORDER_NOT_FOUND":"FAMILY_REFUND_NOT_FOUND");
    return rows.get(0);
  }
  private void ensure(String tenant,String id,String kind) {
    jdbc.update("INSERT INTO family_commerce_work(job_key,tenant_id,kind,entity_id,generation,lease_until,next_attempt_at,attempts,state,updated_at)"
        +" VALUES(?,?,?,?,0,0,0,0,'READY',?) ON DUPLICATE KEY UPDATE job_key=job_key",key(kind,id),tenant,kind,id,clock.millis());
  }
  private static String key(String kind,String id){return kind+":"+id;}
  private record Reservation(String tenant,String id,String kind,long generation,int attempt,String status,long expiresAt,
      String orderId,String transactionId,int price,String currency,String reason,boolean approved) {}
}
