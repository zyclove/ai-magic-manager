package com.aimanager.identityproviders.internal;

import static com.aimanager.identityproviders.internal.ProviderReleaseContracts.*;
import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.security.MessageDigest;
import java.time.Clock;
import java.util.*;
import org.slf4j.MDC;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/** Durable approval and execution fences; only active process observations confirm configuration. */
@Service
class ProviderReleaseService {
  private static final String EXECUTOR="identity-provider-host-executor";
  private static final TypeReference<List<RuntimeInstanceView>> INSTANCES=new TypeReference<>(){};
  private final JdbcTemplate db;private final ObjectMapper json;private final Clock clock;private final ProviderConfigurationService configurations;
  private final ProviderRuntimeProbe probe;private final TransactionTemplate tx;private final String environment;private final byte[] executorKey;
  ProviderReleaseService(JdbcTemplate db,ObjectMapper json,Clock clock,ProviderConfigurationService configurations,ProviderRuntimeProbe probe,PlatformTransactionManager transactions,
      @Value("${manager.identity-providers.environment-id:family-cn-pilot}") String environment,@Value("${manager.identity-providers.executor-key-file:}") String keyFile){
    this.db=db;this.json=json;this.clock=clock;this.configurations=configurations;this.probe=probe;this.environment=environment;
    tx=new TransactionTemplate(transactions);tx.setTimeout(10);byte[] key=null;try{key=ProviderRuntimeCrypto.key(keyFile);}catch(Exception unavailable){/* Optional feature stays closed. */}executorKey=key;
  }
  ReleaseStatusView status(){
    var heads=db.queryForList("SELECT * FROM identity_provider_runtime_heads WHERE environment_id=?",environment);Map<String,Object> head=heads.isEmpty()?Map.of():heads.get(0);
    ReleaseOperationView active=reference(head.get("active_operation_id")),confirmed=reference(head.get("confirmed_operation_id"));
    List<ReleaseTargetView> targets=confirmed==null?List.of():rollbackTargets(confirmed.versionId());
    return new ReleaseStatusView(environment,head.isEmpty()?0:number(head,"revision"),probe.available(),executorKey!=null,active,confirmed,targets,confirmed==null||active!=null?"APPLY_REQUIRED":"APPLIED_CLOSED",false);
  }
  ReleaseOperationView operation(String id){return view(require(uuid(id)));}
  String operationKind(String id){return String.valueOf(require(uuid(id)).get("kind"));}
  ReleaseOperationView cancellation(String id){
    var rows=db.queryForList("SELECT * FROM identity_provider_release_operations WHERE environment_id=? AND cancellation_id=?",environment,uuid(id));
    if(rows.size()!=1)throw missing();return view(rows.get(0));
  }
  ReleaseOperationView create(ReleaseInput input,String actor){
    normalize(input);return tx.execute(status->{
      Map<String,Object> head=lockHead();var old=find(input.id());String actorKey=ActorKeys.key(actor);
      if(old!=null){if(!actorKey.equals(old.get("actor_key"))||!text(input).equals(old.get("request_json")))throw conflict("IDENTITY_PROVIDER_ID_CONFLICT");return view(old);}
      if(number(head,"revision")!=input.expectedRuntimeRevision())throw precondition();
      if(head.get("active_operation_id")!=null)throw conflict("IDENTITY_PROVIDER_RELEASE_IN_PROGRESS");
      if(executorKey==null||!probe.available())throw unavailable("IDENTITY_PROVIDER_RUNTIME_NOT_CONFIGURED");
      var target=configurations.releaseTarget(input.versionId());
      var prepared=configurations.preparation(input.preparationId());
      if(!input.versionId().equals(prepared.versionId())||!"PREPARED".equals(prepared.status())||!"READY".equals(configurations.version(input.versionId()).readinessStatus()))throw conflict("IDENTITY_PROVIDER_RELEASE_TARGET_MISMATCH");
      if("ROLLBACK".equals(input.kind())){
        if(head.get("confirmed_operation_id")==null)throw conflict("IDENTITY_PROVIDER_ROLLBACK_UNAVAILABLE");
        var current=require(String.valueOf(head.get("confirmed_operation_id")));
        if(input.versionId().equals(current.get("version_id"))||!compatible(String.valueOf(current.get("version_id")),input.versionId()))throw conflict("IDENTITY_PROVIDER_ROLLBACK_IDENTITY_MISMATCH");
        Integer history=db.queryForObject("SELECT COUNT(*) FROM identity_provider_release_operations WHERE environment_id=? AND state='APPLIED_CLOSED' AND version_id=? AND preparation_id=? AND provider_jar_sha256=? AND parent_apk_sha256=?",Integer.class,environment,input.versionId(),input.preparationId(),input.providerJarSha256(),input.parentApkSha256());
        if(history==null||history==0)throw conflict("IDENTITY_PROVIDER_ROLLBACK_UNAVAILABLE");
      }
      long revision=number(head,"revision");if(revision==Long.MAX_VALUE)throw precondition();
      db.update("INSERT INTO identity_provider_release_operations(id,environment_id,kind,version_id,preparation_id,provider_jar_sha256,parent_apk_sha256,base_runtime_revision,state,reason_code,actor_key,request_json,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
          input.id(),environment,input.kind(),target.versionId(),input.preparationId(),input.providerJarSha256(),input.parentApkSha256(),revision,"WAITING_EXECUTOR","CONTROLLED_EXECUTION_REQUIRED",actorKey,text(input),clock.millis());
      db.update("UPDATE identity_provider_runtime_heads SET revision=?,active_operation_id=? WHERE environment_id=?",revision+1,input.id(),environment);
      audit(actor,"RELEASE_APPROVED",input.id(),input.versionId(),input.kind());return operation(input.id());
    });
  }
  ReleaseOperationView cancel(String operationId,CancellationInput input,String actor){
    uuid(operationId);if(input==null||input.expectedRuntimeRevision()==null||input.expectedRuntimeRevision()<0)throw invalid();uuid(input.id());
    return tx.execute(status->{
      var head=lockHead();var row=require(operationId);String actorKey=ActorKeys.key(actor);
      var duplicate=db.queryForList("SELECT id FROM identity_provider_release_operations WHERE cancellation_id=?",input.id());
      if(!duplicate.isEmpty()){
        if(!operationId.equals(duplicate.get(0).get("id"))||!actorKey.equals(row.get("cancellation_actor_key"))||number(row,"cancellation_base_revision")!=input.expectedRuntimeRevision())throw conflict("IDENTITY_PROVIDER_ID_CONFLICT");return view(row);
      }
      if(!"WAITING_EXECUTOR".equals(row.get("state"))||!operationId.equals(head.get("active_operation_id"))||row.get("claim_id")!=null)throw conflict("IDENTITY_PROVIDER_RELEASE_ALREADY_CLAIMED");
      if(number(head,"revision")!=input.expectedRuntimeRevision()||number(head,"revision")==Long.MAX_VALUE)throw precondition();
      db.update("UPDATE identity_provider_release_operations SET state='CANCELLED',reason_code='CANCELLED_BEFORE_EXECUTION',cancellation_id=?,cancellation_actor_key=?,cancellation_base_revision=? WHERE id=?",input.id(),actorKey,input.expectedRuntimeRevision(),operationId);
      db.update("UPDATE identity_provider_runtime_heads SET revision=?,active_operation_id=NULL WHERE environment_id=?",number(head,"revision")+1,environment);
      audit(actor,"RELEASE_CANCELLED",operationId,String.valueOf(row.get("version_id")),"CANCELLED_BEFORE_EXECUTION");return operation(operationId);
    });
  }
  RuntimeCheckView check(String operationId,String requestId,String actor){
    uuid(operationId);uuid(requestId);String actorKey=ActorKeys.key(actor);
    CheckStart start=tx.execute(status->{
      var head=lockHead();var existing=checkRow(requestId);
      if(existing!=null){if(!operationId.equals(existing.get("operation_id"))||!actorKey.equals(existing.get("actor_key")))throw conflict("IDENTITY_PROVIDER_ID_CONFLICT");return new CheckStart(false,require(operationId));}
      var row=require(operationId);if(!operationId.equals(head.get("active_operation_id"))||!"EXECUTION_UNKNOWN".equals(row.get("state")))throw conflict("IDENTITY_PROVIDER_RUNTIME_CHECK_NOT_AVAILABLE");
      db.update("INSERT INTO identity_provider_runtime_checks(id,environment_id,operation_id,version_id,actor_key,state,reason_code,instances_json,created_at) VALUES(?,?,?,?,?,'CHECKING','RUNTIME_CHECK_PENDING','[]',?)",requestId,environment,operationId,row.get("version_id"),actorKey,clock.millis());
      audit(actor,"RUNTIME_CHECK_STARTED",requestId,String.valueOf(row.get("version_id")),"RUNTIME_CHECK_PENDING");return new CheckStart(true,row);
    });
    if(!start.fresh())return runtimeCheck(requestId);
    var target=configurations.releaseTarget(String.valueOf(start.operation().get("version_id")));
    List<RuntimeInstanceView> instances=probe.observe(operationId,target.versionId(),String.valueOf(start.operation().get("provider_jar_sha256")),number(start.operation(),"created_at"),target.settings(),target.credentials());
    return tx.execute(status->{
      var head=lockHead();var row=require(operationId);var check=checkRow(requestId);if(!"CHECKING".equals(check.get("state")))return runtimeCheck(requestId);
      boolean confirmed=!instances.isEmpty()&&instances.stream().allMatch(i->"CONFIRMED".equals(i.state()));
      boolean available=instances.stream().anyMatch(i->"MISMATCH".equals(i.state()));String state=confirmed?"CONFIRMED":available?"MISMATCH":"UNAVAILABLE";
      String reason=confirmed?"RUNTIME_CONFIGURATION_CONFIRMED":available?"RUNTIME_CONFIGURATION_MISMATCH":"RUNTIME_OBSERVATION_UNAVAILABLE";
      if(!operationId.equals(head.get("active_operation_id"))||!"EXECUTION_UNKNOWN".equals(row.get("state"))){state="MISMATCH";reason="RUNTIME_OPERATION_SUPERSEDED";confirmed=false;}
      long now=clock.millis();db.update("UPDATE identity_provider_runtime_checks SET state=?,reason_code=?,instances_json=?,completed_at=? WHERE id=?",state,reason,text(instances),now,requestId);
      if(confirmed){
        if(number(head,"revision")==Long.MAX_VALUE)throw precondition();
        db.update("UPDATE identity_provider_release_operations SET state='APPLIED_CLOSED',reason_code='RUNTIME_CONFIGURATION_CONFIRMED',confirmed_at=? WHERE id=?",now,operationId);
        db.update("UPDATE identity_provider_runtime_heads SET revision=?,active_operation_id=NULL,confirmed_operation_id=? WHERE environment_id=?",number(head,"revision")+1,operationId,environment);
      }
      audit(actor,"RUNTIME_CHECK_COMPLETED",requestId,target.versionId(),reason);return runtimeCheck(requestId);
    });
  }
  RuntimeCheckView runtimeCheck(String id){
    uuid(id);
    return tx.execute(status->{
      lockHead();var row=checkRow(id);if(row==null)throw missing();long now=clock.millis();
      // A crashed process must not leave the browser's original-operation journal pending forever.
      if("CHECKING".equals(row.get("state"))&&now-number(row,"created_at")>=120000){
        int changed=db.update("UPDATE identity_provider_runtime_checks SET state='UNAVAILABLE',reason_code='RUNTIME_CHECK_INTERRUPTED',completed_at=? WHERE id=? AND environment_id=? AND state='CHECKING' AND created_at=?",now,id,environment,number(row,"created_at"));
        if(changed==1)audit("identity-provider-runtime-recovery","RUNTIME_CHECK_EXPIRED",id,String.valueOf(row.get("version_id")),"RUNTIME_CHECK_INTERRUPTED");
        row=checkRow(id);
      }
      return checkView(id,row);
    });
  }
  private RuntimeCheckView checkView(String id,Map<String,Object> row){
    String version=String.valueOf(row.get("version_id"));
    try{return new RuntimeCheckView(id,String.valueOf(row.get("operation_id")),version,String.valueOf(row.get("state")),String.valueOf(row.get("reason_code")),number(row,"created_at"),nullable(row,"completed_at"),json.readValue(String.valueOf(row.get("instances_json")),INSTANCES),"CONFIRMED".equals(row.get("state"))?"APPLIED_CLOSED":"APPLY_REQUIRED",false);}
    catch(DomainException failure){throw failure;}catch(Exception unavailable){throw unavailable("IDENTITY_PROVIDER_STATE_UNAVAILABLE");}
  }
  ExecutorView machine(String action,ExecutorInput input){
    authenticate(action,input);
    MachineResult result=tx.execute(status->{
      var head=lockHead();consumeNonce(input);var row=require(input.operationId());boolean active=input.operationId().equals(head.get("active_operation_id"));boolean execution=false,probeAfter=false;
      if("QUERY".equals(action)){
        if(!input.claimId().equals(row.get("claim_id")))throw conflict("IDENTITY_PROVIDER_EXECUTOR_CLAIM_CONFLICT");return new MachineResult(executor(row,false,head),false);
      }
      if(!active)throw conflict("IDENTITY_PROVIDER_EXECUTOR_STALE_OPERATION");
      if("CLAIM".equals(action)){
        if("WAITING_EXECUTOR".equals(row.get("state"))&&row.get("claim_id")==null){
          db.update("UPDATE identity_provider_release_operations SET state='CLAIMED',reason_code='EXECUTOR_CLAIMED',claim_id=? WHERE id=?",input.claimId(),input.operationId());
          audit(EXECUTOR,"EXECUTOR_CLAIMED",input.operationId(),String.valueOf(row.get("version_id")),"EXECUTOR_CLAIMED");
        }else if(!input.claimId().equals(row.get("claim_id")))throw conflict("IDENTITY_PROVIDER_EXECUTOR_CLAIM_CONFLICT");
      }else{
        if(!input.claimId().equals(row.get("claim_id")))throw conflict("IDENTITY_PROVIDER_EXECUTOR_CLAIM_CONFLICT");
        if("BEGIN".equals(action)){
          if("CLAIMED".equals(row.get("state"))){
            db.update("UPDATE identity_provider_release_operations SET state='EXECUTION_UNKNOWN',reason_code='RUNTIME_CONFIRMATION_REQUIRED',claim_started_at=? WHERE id=?",clock.millis(),input.operationId());execution=true;
            audit(EXECUTOR,"EXECUTOR_BEGIN",input.operationId(),String.valueOf(row.get("version_id")),"RUNTIME_CONFIRMATION_REQUIRED");
          }
        }else if("ABANDON_BEFORE_BEGIN".equals(action)){
          if(!"CLAIMED".equals(row.get("state"))||row.get("claim_started_at")!=null)throw conflict("IDENTITY_PROVIDER_RELEASE_ALREADY_STARTED");
          if(number(head,"revision")==Long.MAX_VALUE)throw precondition();
          db.update("UPDATE identity_provider_release_operations SET state='CANCELLED',reason_code='EXECUTOR_ABANDONED_BEFORE_BEGIN' WHERE id=?",input.operationId());
          db.update("UPDATE identity_provider_runtime_heads SET revision=?,active_operation_id=NULL WHERE environment_id=?",number(head,"revision")+1,environment);
          audit(EXECUTOR,"EXECUTOR_ABANDONED",input.operationId(),String.valueOf(row.get("version_id")),"EXECUTOR_ABANDONED_BEFORE_BEGIN");
        }else if("REPORT".equals(action)){
          if(!"EXECUTION_UNKNOWN".equals(row.get("state")))throw conflict("IDENTITY_PROVIDER_EXECUTOR_NOT_STARTED");
          if(row.get("last_report")==null){
            db.update("UPDATE identity_provider_release_operations SET last_report=? WHERE id=?",input.outcome(),input.operationId());probeAfter="FINISHED".equals(input.outcome());
            audit(EXECUTOR,"EXECUTOR_OUTCOME_REPORTED",input.operationId(),String.valueOf(row.get("version_id")),input.outcome());
          }else if(!input.outcome().equals(row.get("last_report")))throw conflict("IDENTITY_PROVIDER_EXECUTOR_OUTCOME_CONFLICT");
        }
      }
      // Mutations such as ABANDON change the fence; permissions must use the new locked head.
      var currentHead=db.queryForMap("SELECT * FROM identity_provider_runtime_heads WHERE environment_id=? FOR UPDATE",environment);
      return new MachineResult(executor(require(input.operationId()),execution,currentHead),probeAfter);
    });
    if(result.probeAfter()){
      check(input.operationId(),UUID.randomUUID().toString(),EXECUTOR);
      return tx.execute(status->{var head=lockHead();return executor(require(input.operationId()),false,head);});
    }
    return result.view();
  }
  private void authenticate(String action,ExecutorInput input){
    if(input==null||executorKey==null)throw unauthorized();
    try{
      uuid(input.operationId());uuid(input.claimId());
      if(!environment.equals(input.environmentId())||!ProviderRuntimeCrypto.token(input.nonce())||input.issuedAt()==null||input.issuedAt()<clock.instant().getEpochSecond()-30||input.issuedAt()>clock.instant().getEpochSecond()+30
          ||("REPORT".equals(action)?!Set.of("UNKNOWN","FAILED","FINISHED").contains(input.outcome()):input.outcome()!=null))throw unauthorized();
      String expected=ProviderRuntimeCrypto.mac(executorKey,List.of("family-identity-executor-request-v1",action,environment,input.operationId(),input.claimId(),input.nonce(),Long.toString(input.issuedAt()),input.outcome()==null?"":input.outcome()));
      if(!ProviderRuntimeCrypto.same(expected,input.proof()))throw unauthorized();
    }catch(DomainException invalid){throw unauthorized();}catch(Exception invalid){throw unauthorized();}
  }
  private void consumeNonce(ExecutorInput input){
    db.update("DELETE FROM identity_provider_executor_nonces WHERE environment_id=? AND occurred_at<?",environment,clock.millis()-120000);
    try{db.update("INSERT INTO identity_provider_executor_nonces(environment_id,nonce,occurred_at) VALUES(?,?,?)",environment,input.nonce(),clock.millis());}
    catch(DuplicateKeyException replay){throw unauthorized();}
  }
  private List<ReleaseTargetView> rollbackTargets(String current){
    var rows=db.queryForList("SELECT version_id,preparation_id,provider_jar_sha256,parent_apk_sha256,MAX(confirmed_at) confirmed_at FROM identity_provider_release_operations WHERE environment_id=? AND state='APPLIED_CLOSED' AND version_id<>? GROUP BY version_id,preparation_id,provider_jar_sha256,parent_apk_sha256 ORDER BY confirmed_at DESC LIMIT 20",environment,current);
    var result=new ArrayList<ReleaseTargetView>();Set<String> seen=new HashSet<>();for(var row:rows){String version=String.valueOf(row.get("version_id"));if(!seen.add(version)||!compatible(current,version))continue;result.add(new ReleaseTargetView(version,String.valueOf(row.get("preparation_id")),String.valueOf(row.get("provider_jar_sha256")),String.valueOf(row.get("parent_apk_sha256")),number(row,"confirmed_at")));}return List.copyOf(result);
  }
  private boolean compatible(String current,String target){
    var first=configurations.releaseTarget(current);var second=configurations.releaseTarget(target);
    return first.settings().wechatAppId().equals(second.settings().wechatAppId())&&MessageDigest.isEqual(first.credentials().get("CONSUMER_OTP_HMAC_KEY").getBytes(java.nio.charset.StandardCharsets.UTF_8),second.credentials().get("CONSUMER_OTP_HMAC_KEY").getBytes(java.nio.charset.StandardCharsets.UTF_8));
  }
  private Map<String,Object> lockHead(){
    db.update("INSERT INTO identity_provider_runtime_heads(environment_id,revision) VALUES(?,0) ON DUPLICATE KEY UPDATE environment_id=environment_id",environment);
    return db.queryForMap("SELECT * FROM identity_provider_runtime_heads WHERE environment_id=? FOR UPDATE",environment);
  }
  private Map<String,Object> find(String id){var rows=db.queryForList("SELECT * FROM identity_provider_release_operations WHERE environment_id=? AND id=?",environment,id);return rows.isEmpty()?null:rows.get(0);}
  private Map<String,Object> require(String id){var row=find(id);if(row==null)throw missing();return row;}
  private Map<String,Object> checkRow(String id){var rows=db.queryForList("SELECT * FROM identity_provider_runtime_checks WHERE environment_id=? AND id=?",environment,id);return rows.isEmpty()?null:rows.get(0);}
  private ReleaseOperationView reference(Object id){return id==null?null:view(require(String.valueOf(id)));}
  private ReleaseOperationView view(Map<String,Object> row){String state=String.valueOf(row.get("state")),version=String.valueOf(row.get("version_id"));
    return new ReleaseOperationView(String.valueOf(row.get("id")),String.valueOf(row.get("kind")),version,String.valueOf(row.get("preparation_id")),String.valueOf(row.get("provider_jar_sha256")),String.valueOf(row.get("parent_apk_sha256")),number(row,"base_runtime_revision"),state,String.valueOf(row.get("reason_code")),number(row,"created_at"),nullable(row,"confirmed_at"),"EXECUTION_UNKNOWN".equals(state),"WAITING_EXECUTOR".equals(state),"APPLIED_CLOSED".equals(state)?"APPLIED_CLOSED":"APPLY_REQUIRED",false);
  }
  private ExecutorView executor(Map<String,Object> row,boolean execute,Map<String,Object> head){
    boolean finalize="APPLIED_CLOSED".equals(row.get("state"))&&row.get("id").equals(head.get("confirmed_operation_id"))&&head.get("active_operation_id")==null;
    boolean clear="CANCELLED".equals(row.get("state"))&&row.get("claim_started_at")==null&&head.get("confirmed_operation_id")==null&&head.get("active_operation_id")==null;
    return new ExecutorView(String.valueOf(row.get("id")),(String)row.get("claim_id"),String.valueOf(row.get("state")),execute,finalize,(String)head.get("confirmed_operation_id"),clear,environment,String.valueOf(row.get("version_id")),String.valueOf(row.get("preparation_id")),String.valueOf(row.get("provider_jar_sha256")),String.valueOf(row.get("parent_apk_sha256")),String.valueOf(row.get("kind")));
  }
  private void normalize(ReleaseInput input){
    if(input==null||input.expectedRuntimeRevision()==null||input.expectedRuntimeRevision()<0||!Set.of("PUBLISH","ROLLBACK").contains(input.kind()))throw invalid();
    uuid(input.id());uuid(input.versionId());uuid(input.preparationId());if(!sha(input.providerJarSha256())||!sha(input.parentApkSha256()))throw invalid();
  }
  private static long number(Map<String,Object> row,String name){return ((Number)row.get(name)).longValue();}
  private static Long nullable(Map<String,Object> row,String name){return row.get(name)==null?null:number(row,name);}
  private static String uuid(String value){if(value==null||!value.matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"))throw invalid();return value;}
  private static boolean sha(String value){return value!=null&&value.matches("[a-f0-9]{64}");}
  private String text(Object value){try{return json.writeValueAsString(value);}catch(Exception unavailable){throw unavailable("IDENTITY_PROVIDER_STATE_UNAVAILABLE");}}
  private void audit(String actor,String action,String resource,String version,String result){String correlation=MDC.get("correlationId");db.update("INSERT INTO identity_provider_audit_events(id,environment_id,actor_key,action,resource_id,version_id,result_code,correlation_id,occurred_at) VALUES(?,?,?,?,?,?,?,?,?)",UUID.randomUUID().toString(),environment,ActorKeys.key(actor),action,resource,version,result,correlation==null?UUID.randomUUID().toString():correlation,clock.millis());}
  private static DomainException invalid(){return DomainException.invalid("IDENTITY_PROVIDER_INVALID_INPUT");}
  private static DomainException missing(){return new DomainException(HttpStatus.NOT_FOUND,"IDENTITY_PROVIDER_NOT_FOUND");}
  private static DomainException unauthorized(){return new DomainException(HttpStatus.UNAUTHORIZED,"IDENTITY_PROVIDER_EXECUTOR_UNAUTHORIZED");}
  private static DomainException conflict(String code){return new DomainException(HttpStatus.CONFLICT,code);}
  private static DomainException precondition(){return new DomainException(HttpStatus.PRECONDITION_FAILED,"IDENTITY_PROVIDER_RUNTIME_VERSION_CONFLICT");}
  private static DomainException unavailable(String code){return new DomainException(HttpStatus.SERVICE_UNAVAILABLE,code);}
  private record CheckStart(boolean fresh,Map<String,Object> operation) {}
  private record MachineResult(ExecutorView view,boolean probeAfter) {}
}
