package com.aimanager.commerce.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.idempotency.ResponseOwnership;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** 平台权限与家庭角色独立；人工操作只排队核验，不能以账单或按钮修改权益。 */
@RestController
@RequestMapping("/api/v1/platform/family-subscription")
class FamilyFinanceOperationsController {
  private static final String FINANCE_SCOPE="family-finance:manage";
  private static final String REFUND_SCOPE="family-refunds:review";
  private static final String PLATFORM_SCOPE="platform-family-finance";
  private final FamilyBillReconciliationService bills;
  private final FamilyCommerceMaintenance maintenance;
  private final RecentAuthentication recent;
  private final IdempotencyService idempotency;
  private final JdbcTemplate jdbc;
  private final AuditService audit;
  private final ObjectMapper json;
  FamilyFinanceOperationsController(FamilyBillReconciliationService bills,FamilyCommerceMaintenance maintenance,
      RecentAuthentication recent,IdempotencyService idempotency,JdbcTemplate jdbc,AuditService audit,ObjectMapper json){
    this.bills=bills;this.maintenance=maintenance;this.recent=recent;this.idempotency=idempotency;
    this.jdbc=jdbc;this.audit=audit;this.json=json;
  }
  record BillInput(String billDate){}
  record NoteInput(String note){}

  @GetMapping("/reconciliation/tasks")
  ResponseEntity<?> tasks(Authentication authentication,@AuthenticationPrincipal Jwt actor,
      @RequestParam(defaultValue="50")int limit,@RequestParam(required=false)String cursor){
    authorize(authentication,actor,FINANCE_SCOPE);return response(bills.tasks(limit,cursor));
  }
  @GetMapping("/reconciliation/tasks/{id}")
  ResponseEntity<?> task(@PathVariable String id,Authentication authentication,@AuthenticationPrincipal Jwt actor){
    authorize(authentication,actor,FINANCE_SCOPE);return response(bills.task(id));
  }
  @PostMapping("/reconciliation/tasks") @Transactional(timeout=10)
  ResponseEntity<?> enqueue(Authentication authentication,@AuthenticationPrincipal Jwt actor,
      @RequestHeader("Idempotency-Key")String key,@RequestBody BillInput input){
    authorize(authentication,actor,FINANCE_SCOPE);
    if(input==null||input.billDate()==null||!input.billDate().matches("[0-9]{4}-[0-9]{2}-[0-9]{2}"))throw DomainException.invalid("INVALID_FAMILY_BILL_DATE");
    final LocalDate date;
    try{date=LocalDate.parse(input.billDate());}catch(DateTimeParseException invalid){throw DomainException.invalid("INVALID_FAMILY_BILL_DATE");}
    return mutation(PLATFORM_SCOPE,actor,"family.bill.enqueue",key,Map.of("billDate",date.toString()),()->{
      var value=bills.enqueue(date);bills.recordOperatorAction(value.id(),null,"FAMILY_BILL_ENQUEUED",actor.getSubject());return value;
    });
  }
  @PostMapping("/reconciliation/tasks/{id}/retries") @Transactional(timeout=10)
  ResponseEntity<?> retry(@PathVariable String id,Authentication authentication,@AuthenticationPrincipal Jwt actor,
      @RequestHeader("Idempotency-Key")String key){
    authorize(authentication,actor,FINANCE_SCOPE);bills.task(id);
    return mutation(PLATFORM_SCOPE,actor,"family.bill.retry",key,Map.of("id",id),()->{
      var value=bills.retry(id);bills.recordOperatorAction(id,null,"FAMILY_BILL_RETRY_ENQUEUED",actor.getSubject());return value;
    });
  }
  @GetMapping("/reconciliation/tasks/{id}/differences")
  ResponseEntity<?> differences(@PathVariable String id,Authentication authentication,@AuthenticationPrincipal Jwt actor,
      @RequestParam(defaultValue="50")int limit,@RequestParam(required=false)String cursor){
    authorize(authentication,actor,FINANCE_SCOPE);return response(bills.differences(id,limit,cursor));
  }
  @PostMapping("/reconciliation/tasks/{id}/differences/{differenceId}/acknowledgements") @Transactional(timeout=10)
  ResponseEntity<?> acknowledge(@PathVariable String id,@PathVariable String differenceId,Authentication authentication,
      @AuthenticationPrincipal Jwt actor,@RequestHeader("Idempotency-Key")String key,@RequestBody NoteInput input){
    authorize(authentication,actor,FINANCE_SCOPE);
    if(input==null||input.note()==null)throw DomainException.invalid("INVALID_FAMILY_BILL_NOTE");
    return mutation(PLATFORM_SCOPE,actor,"family.bill.acknowledge",key,Map.of("id",id,"differenceId",differenceId,"note",input.note()),
        ()->bills.acknowledge(id,differenceId,input.note(),actor.getSubject()));
  }
  @PostMapping("/reconciliation/tasks/{id}/differences/{differenceId}/verifications") @Transactional(timeout=10)
  ResponseEntity<?> verifyDifference(@PathVariable String id,@PathVariable String differenceId,Authentication authentication,
      @AuthenticationPrincipal Jwt actor,@RequestHeader("Idempotency-Key")String key){
    authorize(authentication,actor,FINANCE_SCOPE);
    // Replay the committed receipt before asking whether the old difference is still current.
    // New mutations still require the current attempt and are rechecked under its task lock.
    return mutation(PLATFORM_SCOPE,actor,"family.bill.verify",key,Map.of("id",id,"differenceId",differenceId),()->{
      var difference=bills.difference(id,differenceId);
      if(difference.tenantId()==null||difference.orderId()==null)throw new DomainException(HttpStatus.CONFLICT,"FAMILY_BILL_UNMAPPED_TRANSACTION");
      String target=difference.refundId()==null?difference.orderId():difference.refundId();
      if(difference.refundId()==null)maintenance.enqueueOrderVerification(difference.tenantId(),target);
      else maintenance.enqueueRefundVerification(difference.tenantId(),target);
      audit.record(difference.tenantId(),actor.getSubject(),"FAMILY_BILL_VERIFICATION_QUEUED",differenceId);
      bills.recordOperatorAction(id,differenceId,"FAMILY_BILL_VERIFICATION_QUEUED",actor.getSubject());
      return Map.of("queued",true,"resourceId",target);
    });
  }
  @PostMapping("/refund-requests/{id}/verifications") @Transactional(timeout=10)
  ResponseEntity<?> verifyRefund(@PathVariable String id,Authentication authentication,@AuthenticationPrincipal Jwt actor,
      @RequestHeader("Idempotency-Key")String key){
    authorize(authentication,actor,REFUND_SCOPE);canonicalId(id);
    var values=jdbc.queryForList("SELECT tenant_id,status,reviewed_at FROM family_refund_requests WHERE id=?",id);
    if(values.size()!=1)throw new DomainException(HttpStatus.NOT_FOUND,"FAMILY_REFUND_NOT_FOUND");
    var refund=values.get(0);String tenant=(String)refund.get("tenant_id");
    if(refund.get("reviewed_at")==null||!Set.of("REQUESTED","PROCESSING","REFUNDED","CLOSED","ABNORMAL").contains(refund.get("status")))
      throw new DomainException(HttpStatus.CONFLICT,"REFUND_REVIEW_REQUIRED");
    return mutation(tenant,actor,"family.refund.verify.queue",key,Map.of("id",id),()->{
      maintenance.enqueueRefundVerification(tenant,id);audit.record(tenant,actor.getSubject(),"FAMILY_REFUND_VERIFICATION_QUEUED",id);
      return Map.of("queued",true,"resourceId",id);
    });
  }
  private ResponseEntity<?> mutation(String scope,Jwt actor,String operation,String key,Map<String,?> attributes,Supplier<?> action){
    return response(idempotency.execute(scope,actor.getSubject(),operation,key,attributes,Map.class,
        ()->json.convertValue(action.get(),Map.class),ignored->ResponseOwnership.nonSubject()));
  }
  private void authorize(Authentication authentication,Jwt actor,String scope){
    if(authentication.getAuthorities().stream().noneMatch(a->a.getAuthority().equals("SCOPE_"+scope)))throw DomainException.denied();
    recent.require(actor);
  }
  private static void canonicalId(String id){
    try{if(!UUID.fromString(id).toString().equals(id))throw new IllegalArgumentException();}
    catch(IllegalArgumentException invalid){throw DomainException.invalid("INVALID_REFUND_ID");}
  }
  private static ResponseEntity<?> response(Object body){return FamilySubscriptionController.response(body);}
}
