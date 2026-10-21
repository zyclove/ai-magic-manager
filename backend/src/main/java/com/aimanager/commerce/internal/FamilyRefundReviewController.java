package com.aimanager.commerce.internal;
import com.aimanager.audit.AuditService;
import com.aimanager.identity.*;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.shared.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.*;
import org.springframework.http.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.*;

/** A separate operator reviews frozen refund consequences; no payment call occurs here. */
@RestController
@RequestMapping("/api/v1/platform/family-subscription/refund-requests")
class FamilyRefundReviewController {
  private final JdbcTemplate jdbc;private final RecentAuthentication recent;private final AuditService audit;
  private final IdempotencyService idempotency;private final Clock clock;private final ObjectMapper json;
  private final FamilySubscriptionService subscriptions;
  FamilyRefundReviewController(JdbcTemplate jdbc,RecentAuthentication recent,AuditService audit,IdempotencyService idempotency,Clock clock,ObjectMapper json,FamilySubscriptionService subscriptions){
    this.jdbc=jdbc;this.recent=recent;this.audit=audit;this.idempotency=idempotency;this.clock=clock;this.json=json;this.subscriptions=subscriptions;
  }
  record Decision(String decision,String previewHash,String note){}
  record QueueItem(String id,String tenantId,String orderId,String status,String reason,
      int priceMinor,String currency,long createdAt,Long reviewedAt,Long refundedAt,
      String reviewNote,boolean canReview){}

  @GetMapping @Transactional(readOnly=true,timeout=10)
  ResponseEntity<?> queue(Authentication authentication,@AuthenticationPrincipal Jwt actor,
      @RequestParam(defaultValue="50")int limit,@RequestParam(required=false)String cursor,
      @RequestParam(required=false)String status,@RequestParam(required=false)String orderId){
    authorize(authentication,actor);ItemPage.validate(limit,cursor);
    if(status!=null&&!Set.of("AWAITING_REVIEW","REQUESTED","DECLINED","PROCESSING","REFUNDED","CLOSED","ABNORMAL").contains(status))
      throw DomainException.invalid("INVALID_REFUND_STATUS");
    if(orderId!=null)canonicalId(orderId);
    var args=new ArrayList<Object>();args.add(cursor==null?"":cursor);
    String filters="";
    if(status!=null){filters+=" AND r.status=?";args.add(status);}
    if(orderId!=null){filters+=" AND r.order_id=?";args.add(orderId);}
    args.add(limit+1);
    var rows=jdbc.query("SELECT r.*,o.currency,v.note AS review_note FROM family_refund_requests r JOIN family_orders o"
        +" ON o.id=r.order_id AND o.tenant_id=r.tenant_id LEFT JOIN family_refund_reviews v ON v.refund_id=r.id AND v.tenant_id=r.tenant_id"
        +" WHERE r.id>?"+filters+" ORDER BY r.id LIMIT ?",(r,n)->queueItem(r,actor.getSubject()),args.toArray());
    return FamilySubscriptionController.response(ItemPage.from(rows,limit,QueueItem::id));
  }
  @GetMapping("/{id}") @Transactional(readOnly=true,timeout=10)
  ResponseEntity<?> detail(@PathVariable String id,Authentication authentication,@AuthenticationPrincipal Jwt actor){
    authorize(authentication,actor);canonicalId(id);
    var rows=jdbc.query("SELECT r.*,o.currency,v.note AS review_note FROM family_refund_requests r JOIN family_orders o"
        +" ON o.id=r.order_id AND o.tenant_id=r.tenant_id LEFT JOIN family_refund_reviews v ON v.refund_id=r.id AND v.tenant_id=r.tenant_id WHERE r.id=?",
        (r,n)->queueItem(r,actor.getSubject()),id);
    if(rows.size()!=1)throw new DomainException(HttpStatus.NOT_FOUND,"FAMILY_REFUND_NOT_FOUND");
    return FamilySubscriptionController.response(rows.get(0));
  }
  private QueueItem queueItem(java.sql.ResultSet r,String actor)throws java.sql.SQLException{
    return new QueueItem(r.getString("id"),r.getString("tenant_id"),r.getString("order_id"),r.getString("status"),r.getString("reason"),
        r.getInt("price_minor"),r.getString("currency"),r.getLong("created_at"),r.getObject("reviewed_at",Long.class),r.getObject("refunded_at",Long.class),
        r.getString("review_note"),"AWAITING_REVIEW".equals(r.getString("status"))&&!ActorKeys.key(actor).equals(r.getString("actor_key")));
  }
  private void canonicalId(String value){
    try{if(!UUID.fromString(value).toString().equals(value))throw new IllegalArgumentException();}
    catch(IllegalArgumentException invalid){throw DomainException.invalid("INVALID_REFUND_ID");}
  }
  @GetMapping("/{id}/preview") @Transactional(timeout=10)
  ResponseEntity<?> preview(@PathVariable String id,Authentication authentication,@AuthenticationPrincipal Jwt actor){
    authorize(authentication,actor);return FamilySubscriptionController.response(preview(lock(id)));
  }
  @PostMapping("/{id}/reviews") @Transactional(timeout=10)
  ResponseEntity<?> decide(@PathVariable String id,Authentication authentication,@AuthenticationPrincipal Jwt actor,
      @RequestHeader("Idempotency-Key")String key,@RequestBody Decision input){
    authorize(authentication,actor);
    if(input==null||input.decision()==null||!Set.of("APPROVE","DENY").contains(input.decision())||input.previewHash()==null||!input.previewHash().matches("[0-9a-f]{64}"))throw DomainException.invalid("INVALID_REFUND_REVIEW");
    String note=input.note()==null?("APPROVE".equals(input.decision())?"人工审核通过":"人工审核未通过"):input.note().strip();
    if(note.isEmpty()||note.length()>200||note.chars().anyMatch(Character::isISOControl))throw DomainException.invalid("INVALID_REFUND_REVIEW_NOTE");
    var row=lock(id);String tenant=(String)row.get("tenant_id");
    var attributes=new LinkedHashMap<String,Object>();attributes.put("id",id);attributes.put("decision",input.decision());attributes.put("previewHash",input.previewHash());
    if(input.note()!=null)attributes.put("note",note);
    var result=idempotency.execute(tenant,actor.getSubject(),"family.refund.review",key,attributes,Map.class,()->{
      if(ActorKeys.key(actor.getSubject()).equals(row.get("actor_key")))throw DomainException.denied();
      if(!"AWAITING_REVIEW".equals(row.get("status")))throw new DomainException(HttpStatus.CONFLICT,"REFUND_REVIEW_NOT_PENDING");
      if(!input.previewHash().equals(preview(row).get("previewHash")))throw new DomainException(HttpStatus.CONFLICT,"REFUND_PREVIEW_CHANGED");
      String state="APPROVE".equals(input.decision())?"REQUESTED":"DECLINED";
      jdbc.update("UPDATE family_refund_requests SET status=?,reviewed_by=?,reviewed_at=? WHERE tenant_id=? AND id=?",state,ActorKeys.key(actor.getSubject()),clock.millis(),tenant,id);
      jdbc.update("INSERT INTO family_refund_reviews(refund_id,tenant_id,decision,note,reviewer_key,reviewed_at,preview_hash) VALUES(?,?,?,?,?,?,?)",
          id,tenant,input.decision(),note,ActorKeys.key(actor.getSubject()),clock.millis(),input.previewHash());
      audit.record(tenant,actor.getSubject(),"FAMILY_REFUND_"+("APPROVE".equals(input.decision())?"APPROVED":"DECLINED"),id);
      return Map.of("id",id,"status",state,"externalRefundSubmitted",false);
    });return FamilySubscriptionController.response(result);
  }
  private Map<String,Object> lock(String id){
    canonicalId(id);
    var tenants=jdbc.queryForList("SELECT tenant_id FROM family_refund_requests WHERE id=?",String.class,id);
    if(tenants.size()!=1)throw new DomainException(HttpStatus.NOT_FOUND,"FAMILY_REFUND_NOT_FOUND");
    subscriptions.lockAccount(tenants.get(0));
    var rows=jdbc.queryForList("SELECT * FROM family_refund_requests WHERE id=? FOR UPDATE",id);return rows.get(0);
  }
  private Map<String,Object> preview(Map<String,Object> refund){
    String tenant=(String)refund.get("tenant_id"),order=(String)refund.get("order_id");
    var target=jdbc.queryForMap("SELECT id,status,price_minor,currency,period_start,period_end FROM family_orders WHERE tenant_id=? AND id=? FOR UPDATE",tenant,order);
    // A normal read would retain the snapshot from the tenant lookup on MySQL RR.
    // Account locks serialize commercial writes; this current read includes renewals committed while waiting.
    var retained=jdbc.queryForList("SELECT id,status,period_start,period_end FROM family_orders WHERE tenant_id=? AND id<>? AND status='PAID' ORDER BY period_start,id FOR UPDATE",tenant,order);
    var facts=new LinkedHashMap<String,Object>();facts.put("id",refund.get("id"));facts.put("status",refund.get("status"));facts.put("reason",refund.get("reason"));facts.put("createdAt",refund.get("created_at"));facts.put("order",target);facts.put("preservedOrders",retained);
    facts.put("consequence","仅原路全额退款；退款核实成功后撤销对应订单来源，其他订单起止时间保留，不向前平移。");
    try{String hash=SecretMaterial.hash(json.writeValueAsString(facts));facts.put("previewHash",hash);return facts;}catch(Exception failure){throw new IllegalStateException("Refund preview unavailable");}
  }
  private void authorize(Authentication auth,Jwt actor){
    if(auth.getAuthorities().stream().noneMatch(a->a.getAuthority().equals("SCOPE_family-refunds:review")))throw DomainException.denied();
    recent.require(actor);
  }
}
