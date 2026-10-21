package com.aimanager.identityproviders.internal;

import static com.aimanager.identityproviders.internal.ProviderContracts.*;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Clock;
import java.util.*;
import org.slf4j.MDC;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** 配置草稿、加密交付及真实验收准备；此服务不发送供应商请求或执行部署。 */
@Service
class ProviderConfigurationService {
  static final String VAULT="family-identity-provider-vault-v1",REQUEST="family-identity-provider-request-v1",RELEASE="family-identity-provider-release-v1";
  static final String HMAC="CONSUMER_OTP_HMAC_KEY",STS="ALIYUN_SMS_SECURITY_TOKEN";
  static final Map<String,String> REPLACEMENTS=Map.of("smsAccessKeyId","ALIYUN_SMS_ACCESS_KEY_ID",
      "smsAccessKeySecret","ALIYUN_SMS_ACCESS_KEY_SECRET","smsSecurityToken",STS,"wechatAppSecret","WECHAT_NATIVE_APP_SECRET");
  private static final Set<String> CREDENTIAL_KEYS=Set.of(HMAC,"ALIYUN_SMS_ACCESS_KEY_ID","ALIYUN_SMS_ACCESS_KEY_SECRET",STS,"WECHAT_NATIVE_APP_SECRET");
  private static final TypeReference<Map<String,String>> STRINGS=new TypeReference<>(){};
  private static final TypeReference<Map<String,Boolean>> BOOLEANS=new TypeReference<>(){};
  private final JdbcTemplate db;private final ObjectMapper json;private final Clock clock;private final ProviderVault vault;
  private final String environment;private final String releaseDirectory;
  ProviderConfigurationService(JdbcTemplate db,ObjectMapper json,Clock clock,ProviderVault vault,
      @Value("${manager.identity-providers.environment-id:family-cn-pilot}") String environment,
      @Value("${manager.identity-providers.release-directory:}") String directory){
    if(!environment.matches("[A-Za-z][A-Za-z0-9_-]{2,63}"))throw new IllegalStateException("Invalid identity provider environment configuration");
    this.db=db;this.json=json;this.clock=clock;this.vault=vault;this.environment=environment;releaseDirectory=directory;
  }
  StatusView status(boolean read,boolean manage,boolean test){
    var heads=db.queryForList("SELECT version,latest_version_id FROM identity_provider_heads WHERE environment_id=?",environment);
    long version=heads.isEmpty()?0:((Number)heads.get(0).get("version")).longValue();
    VersionView latest=version==0?null:view(requireRow((String)heads.get(0).get("latest_version_id")));
    return new StatusView(environment,new Capabilities(read,manage,test,vault.available(),vault.available()&&releaseDirectoryReady()),version,latest,
        checks(latest),latest==null?"APPLY_REQUIRED":runtimeStatus(latest.id()),false);
  }
  VersionView version(String id){return view(requireRow(uuid(id)));}

  @Transactional(timeout=10)
  VersionView save(SaveVersion raw,String actor){
    SaveVersion input=normalize(raw);vault.requireAvailable();lockHead();
    Row previous=findRow(input.id());String actorKey=ActorKeys.key(actor);
    if(previous!=null){
      if(!actorKey.equals(previous.actorKey())||!MessageDigest.isEqual(bytes(input),vault.open(REQUEST,environment,input.id(),previous.protectedRequest())))throw conflict("IDENTITY_PROVIDER_ID_CONFLICT");
      return view(previous);
    }
    var head=db.queryForMap("SELECT version,latest_version_id FROM identity_provider_heads WHERE environment_id=? FOR UPDATE",environment);
    long current=((Number)head.get("version")).longValue();
    if(input.baseVersion()!=current)throw new DomainException(HttpStatus.PRECONDITION_FAILED,"IDENTITY_PROVIDER_VERSION_CONFLICT");
    if(current==Long.MAX_VALUE)throw conflict("IDENTITY_PROVIDER_VERSION_CONFLICT");
    Map<String,String> credentials=new TreeMap<>();for(String key:CREDENTIAL_KEYS)credentials.put(key,"");
    if(current>0)credentials.putAll(credentials(requireRow((String)head.get("latest_version_id"))));
    if(credentials.get(HMAC).isEmpty()){
      byte[] random=new byte[32];new SecureRandom().nextBytes(random);credentials.put(HMAC,Base64.getUrlEncoder().withoutPadding().encodeToString(random));
    }
    input.replacements().forEach((key,value)->credentials.put(REPLACEMENTS.get(key),value));
    if(input.clearSmsSecurityToken())credentials.put(STS,"");
    long now=clock.millis();Map<String,Boolean> presence=presence(credentials);
    db.update("INSERT INTO identity_provider_versions(id,environment_id,version,base_version,settings_json,credential_presence_json,protected_payload,protected_request,actor_key,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
        input.id(),environment,current+1,current,text(input.settings()),text(presence),vault.seal(VAULT,environment,input.id(),bytes(credentials)),
        vault.seal(REQUEST,environment,input.id(),bytes(input)),actorKey,now);
    if(db.update("UPDATE identity_provider_heads SET version=?,latest_version_id=? WHERE environment_id=? AND version=?",current+1,input.id(),environment,current)!=1)throw conflict("IDENTITY_PROVIDER_VERSION_CONFLICT");
    audit(actor,"VERSION_CREATED",input.id(),input.id(),"DRAFT_SAVED");return version(input.id());
  }
  @Transactional(timeout=10)
  ValidationView validate(String id,String actor){
    VersionView current=version(id);List<Check> checks=checks(current);audit(actor,"VALIDATION_REQUESTED",id,id,ready(checks)?"CONFIGURATION_READY":"CONFIGURATION_INCOMPLETE");
    return new ValidationView(id,ready(checks)?"READY":"BLOCKED",checks,runtimeStatus(id),false);
  }

  @Transactional(timeout=10)
  PreparationView prepare(String versionId,String requestId,String actor){
    uuid(versionId);uuid(requestId);lockHead();Row row=requireRow(versionId);
    var old=db.queryForList("SELECT * FROM identity_provider_release_preparations WHERE id=? AND environment_id=?",requestId,environment);
    if(!old.isEmpty()){
      if(!versionId.equals(old.get(0).get("version_id"))||!ActorKeys.key(actor).equals(old.get(0).get("actor_key")))throw conflict("IDENTITY_PROVIDER_ID_CONFLICT");
      return preparation(old.get(0));
    }
    String state="BLOCKED",reason="CONFIGURATION_INCOMPLETE";
    if(ready(checks(view(row)))){
      try{writeRelease(requestId,row);state="PREPARED";reason="CONTROLLED_APPLY_REQUIRED";}
      catch(DomainException unavailable){reason="RELEASE_PREPARATION_UNAVAILABLE";}
    }else if(!vault.available())reason="IDENTITY_PROVIDER_VAULT_UNAVAILABLE";
    else if(!releaseDirectoryReady())reason="RELEASE_DIRECTORY_UNAVAILABLE";
    db.update("INSERT INTO identity_provider_release_preparations(id,environment_id,version_id,status,reason_code,actor_key,created_at) VALUES(?,?,?,?,?,?,?)",
        requestId,environment,versionId,state,reason,ActorKeys.key(actor),clock.millis());
    audit(actor,"RELEASE_PREPARATION",requestId,versionId,reason);return preparation(requestId);
  }
  PreparationView preparation(String id){
    uuid(id);var rows=db.queryForList("SELECT * FROM identity_provider_release_preparations WHERE id=? AND environment_id=?",id,environment);
    if(rows.size()!=1)throw missing();return preparation(rows.get(0));
  }
  PreparationListView preparations(String versionId){
    requireRow(uuid(versionId));var rows=db.queryForList("SELECT * FROM identity_provider_release_preparations WHERE environment_id=? AND version_id=? AND status='PREPARED' ORDER BY created_at DESC,id DESC LIMIT 5",environment,versionId);
    return new PreparationListView(rows.stream().map(this::preparation).toList());
  }
  private PreparationView preparation(Map<String,Object> row){return new PreparationView((String)row.get("id"),(String)row.get("version_id"),
      (String)row.get("status"),(String)row.get("reason_code"),runtimeStatus((String)row.get("version_id")),false);}

  @Transactional(timeout=10)
  AcceptanceView createRun(AcceptanceInput input,String actor){
    if(input==null)throw invalid();uuid(input.id());uuid(input.versionId());
    if(!environment.equals(input.environmentId()))throw invalid();String jar=sha(input.providerJarSha256()),apk=sha(input.parentApkSha256());
    boolean bound=input.releaseOperationId()!=null||input.expectedRuntimeRevision()!=null;
    if(bound&&(input.releaseOperationId()==null||input.expectedRuntimeRevision()==null||input.expectedRuntimeRevision()<0))throw invalid();
    if(bound)uuid(input.releaseOperationId());
    // Acquire the fence before the first consistent read, including on MySQL REPEATABLE READ.
    lockHead();var runtime=lockRuntimeHead();requireRow(input.versionId());var old=db.queryForList("SELECT * FROM identity_provider_acceptance_runs WHERE id=? AND environment_id=?",input.id(),environment);
    if(!old.isEmpty()){
      var row=old.get(0);if(!input.versionId().equals(row.get("version_id"))||!jar.equals(row.get("provider_jar_sha256"))||!apk.equals(row.get("parent_apk_sha256"))
          ||!ActorKeys.key(actor).equals(row.get("actor_key"))||!Objects.equals(input.releaseOperationId(),row.get("release_operation_id"))
          ||!Objects.equals(input.expectedRuntimeRevision(),nullableLong(row,"runtime_revision")))throw conflict("IDENTITY_PROVIDER_ID_CONFLICT");return run(input.id());
    }
    if(bound){
      if(((Number)runtime.get("revision")).longValue()!=input.expectedRuntimeRevision())throw new DomainException(HttpStatus.PRECONDITION_FAILED,"IDENTITY_PROVIDER_VERSION_CONFLICT");
      String latest=db.queryForObject("SELECT latest_version_id FROM identity_provider_heads WHERE environment_id=?",String.class,environment);
      if(!input.versionId().equals(latest)||!ready(checks(version(input.versionId()))))throw conflict("IDENTITY_PROVIDER_ACCEPTANCE_TARGET_MISMATCH");
      if(runtime.get("active_operation_id")!=null||!input.releaseOperationId().equals(runtime.get("confirmed_operation_id")))throw conflict("IDENTITY_PROVIDER_ACCEPTANCE_TARGET_MISMATCH");
      var operations=db.queryForList("SELECT * FROM identity_provider_release_operations WHERE environment_id=? AND id=?",environment,input.releaseOperationId());
      if(operations.size()!=1)throw conflict("IDENTITY_PROVIDER_ACCEPTANCE_TARGET_MISMATCH");var operation=operations.get(0);
      if(!"APPLIED_CLOSED".equals(operation.get("state"))||!input.versionId().equals(operation.get("version_id"))
          ||!jar.equals(operation.get("provider_jar_sha256"))||!apk.equals(operation.get("parent_apk_sha256")))throw conflict("IDENTITY_PROVIDER_ACCEPTANCE_TARGET_MISMATCH");
    }
    long now=clock.millis();
    db.update("INSERT INTO identity_provider_acceptance_runs(id,environment_id,version_id,provider_jar_sha256,parent_apk_sha256,actor_key,created_at,release_operation_id,runtime_revision,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
        input.id(),environment,input.versionId(),jar,apk,ActorKeys.key(actor),now,input.releaseOperationId(),input.expectedRuntimeRevision(),bound?Math.addExact(now,86_400_000):null);
    audit(actor,"ACCEPTANCE_RUN_CREATED",input.id(),input.versionId(),"REAL_VALIDATION_REQUIRED");return run(input.id());
  }
  AcceptanceListView runs(){
    var rows=db.queryForList("SELECT id FROM identity_provider_acceptance_runs WHERE environment_id=? ORDER BY created_at DESC,id DESC LIMIT 5",String.class,environment);
    return new AcceptanceListView(rows.stream().map(this::run).toList());
  }
  AcceptanceView run(String id){
    uuid(id);var rows=db.queryForList("SELECT * FROM identity_provider_acceptance_runs WHERE id=? AND environment_id=?",id,environment);
    if(rows.size()!=1)throw missing();var row=rows.get(0);
    return new AcceptanceView(id,(String)row.get("version_id"),environment,(String)row.get("provider_jar_sha256"),(String)row.get("parent_apk_sha256"),
        ((Number)row.get("created_at")).longValue(),"BLOCKED",realChecks(),runtimeStatus((String)row.get("version_id")),false,false,
        (String)row.get("release_operation_id"),nullableLong(row,"runtime_revision"),nullableLong(row,"expires_at"));
  }
  String runtimeStatus(String versionId){
    Integer count=db.queryForObject("SELECT COUNT(*) FROM identity_provider_runtime_heads h JOIN identity_provider_release_operations o ON o.id=h.confirmed_operation_id WHERE h.environment_id=? AND h.active_operation_id IS NULL AND o.version_id=? AND o.state='APPLIED_CLOSED'",Integer.class,environment,versionId);
    return count!=null&&count>0?"APPLIED_CLOSED":"APPLY_REQUIRED";
  }
  ReleaseTarget releaseTarget(String versionId){Row row=requireRow(uuid(versionId));return new ReleaseTarget(row.id(),row.settings(),Map.copyOf(credentials(row)));}
  record ReleaseTarget(String versionId,Settings settings,Map<String,String> credentials) {}
  List<Check> realChecks(){
    return List.of(
        real("LOG_REDACTION","核对日志脱敏","先核对入口、代理和出站日志，确保不记录手机号、验证码、code 或 token。"),
        real("SIGNED_DEVICE_BUILD","正式签名真机","核对实际安装包、微信开放平台包名、证书和 AppID。"),
        real("REAL_SMS_DELIVERY","真实短信收码","在已授权成人测试手机上，使用 App 正常登录并由本人输入实际收到的验证码。"),
        real("REAL_WECHAT_NATIVE_AUTH","微信原生授权","在正式签名真机使用原生微信授权；不得复制或粘贴微信 code。"),
        real("CHANGE_PHONE_E2E","手机号换绑","在 App 验证原号及新号，核对家庭、设备、会员仍属于同一账号。"),
        real("RECOVER_PHONE_E2E","账号恢复","使用已绑定微信和新手机号，在 App 找回原账号。"),
        real("BIND_WECHAT_E2E","微信绑定","验证手机号后绑定微信，再确认该微信登录原账号。"),
        real("UNBIND_WECHAT_E2E","微信解绑","验证手机号后解绑，确认手机号可登录且旧微信不可登录原账号。"),
        real("IDENTITY_CONFLICTS","身份冲突","核对被占用号码、他人微信、旧版本和重放均被明确拒绝。"),
        real("OLD_SESSION_REVOKED","旧会话失效","在第二台设备验证旧业务会话、刷新及离线会话全部失效。"),
        real("INTERRUPTION_RECOVERY","中断恢复","取消浏览器、掉网和丢回调后回到 App 核对事实，不自动重放更改。"),
        real("MYSQL_CONCURRENCY_ROLLBACK","数据库并发与回滚","在目标 MySQL、Keycloak 和节点组合复测并发、回滚及缓存失效。"));
  }
  private static Check real(String id,String label,String action){return new Check(id,label,"真实联调","PENDING","REAL_VALIDATION_REQUIRED",action);}
  private List<Check> checks(VersionView version){
    Settings s=version==null?new Settings("","","","",""):version.settings();Map<String,Boolean> c=version==null?Map.of():version.credentials();
    return List.of(check("SECRET_STORAGE","安全密钥存储",vault.available(),"VAULT_UNAVAILABLE","先配置独立的服务端加密密钥。"),
        check("SMS_CONFIGURATION","短信配置",!s.smsSignName().isEmpty()&&!s.smsTemplateCode().isEmpty()&&yes(c,"smsAccessKeyId")&&yes(c,"smsAccessKeySecret")&&yes(c,"otpHmacKey"),"SMS_CONFIGURATION_INCOMPLETE","补齐中国站短信签名、模板和访问密钥；配置齐全不代表已送达。"),
        check("WECHAT_CONFIGURATION","微信移动应用配置",!s.wechatAppId().isEmpty()&&yes(c,"wechatAppSecret"),"WECHAT_CONFIGURATION_INCOMPLETE","补齐已审核移动应用 AppID 和 AppSecret。"),
        check("SIGNED_BUILD_REGISTRATION","正式安装包登记","com.aimanager.parent".equals(s.parentPackageName())&&!s.parentCertificateSha256().isEmpty(),"SIGNED_BUILD_REGISTRATION_INCOMPLETE","登记正式包名和证书摘要，随后在真机核对实际安装包。"),
        check("RELEASE_DIRECTORY","受控交付目录",releaseDirectoryReady(),"RELEASE_DIRECTORY_UNAVAILABLE","先由部署负责人准备受限的固定交付目录。"));
  }
  private static boolean yes(Map<String,Boolean> values,String key){return Boolean.TRUE.equals(values.get(key));}
  private static Check check(String id,String label,boolean ready,String code,String action){return new Check(id,label,"配置准备",ready?"READY":"BLOCKED",ready?"CONFIGURATION_READY":code,ready?"继续核对版本并完成真实联调。":action);}
  private static boolean ready(List<Check> checks){return checks.stream().allMatch(c->"READY".equals(c.status()));}
  private boolean releaseDirectoryReady(){
    try{if(releaseDirectory.isBlank())return false;Path root=Path.of(releaseDirectory);ProviderVault.noLinks(root);
      return root.isAbsolute()&&Files.isDirectory(root,LinkOption.NOFOLLOW_LINKS)&&Files.isWritable(root);
    }catch(Exception unavailable){return false;}
  }
  private void writeRelease(String requestId,Row row){
    Path temporary=null;
    try{
      if(!releaseDirectoryReady())throw new IllegalArgumentException();Path root=Path.of(releaseDirectory).toAbsolutePath().normalize();
      Path target=root.resolve(requestId+".json");ProviderVault.noLinks(target);var payload=new ReleasePayload(1,row.id(),row.settings(),credentials(row));
      if(Files.exists(target,LinkOption.NOFOLLOW_LINKS)){
        if(!Files.isRegularFile(target,LinkOption.NOFOLLOW_LINKS)||Files.size(target)>196608)throw new IllegalArgumentException();
        var existing=json.readValue(Files.readAllBytes(target),ReleaseBundle.class);
        if(existing.schemaVersion()!=1||!environment.equals(existing.environmentId())||!row.id().equals(existing.versionId())
            ||!json.readTree(vault.open(RELEASE,environment,row.id(),existing.protectedPayload())).equals(json.valueToTree(payload)))throw new IllegalArgumentException();
        return; // A committed file can outlive a rolled-back receipt; never replace it.
      }
      var bundle=new ReleaseBundle(1,environment,row.id(),vault.seal(RELEASE,environment,row.id(),bytes(payload)));byte[] encoded=bytes(bundle);
      temporary=root.resolve(requestId+".tmp-"+UUID.randomUUID());
      try(var channel=FileChannel.open(temporary,StandardOpenOption.CREATE_NEW,StandardOpenOption.WRITE,LinkOption.NOFOLLOW_LINKS)){
        ByteBuffer buffer=ByteBuffer.wrap(encoded);while(buffer.hasRemaining())channel.write(buffer);channel.force(true);
      }
      // The database head lock serializes writers; no REPLACE_EXISTING or mutable release file.
      Files.move(temporary,target,StandardCopyOption.ATOMIC_MOVE);temporary=null;
    }catch(Exception unavailable){throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE,"IDENTITY_PROVIDER_RELEASE_UNAVAILABLE");}
    finally{if(temporary!=null)try{Files.deleteIfExists(temporary);}catch(Exception ignored){/* No secret plaintext is written, even in the temporary file. */}}
  }
  private void lockHead(){
    db.update("INSERT INTO identity_provider_heads(environment_id,version) VALUES(?,0) ON DUPLICATE KEY UPDATE environment_id=environment_id",environment);
    db.queryForObject("SELECT version FROM identity_provider_heads WHERE environment_id=? FOR UPDATE",Long.class,environment);
  }
  Map<String,Object> lockRuntimeHead(){
    db.update("INSERT INTO identity_provider_runtime_heads(environment_id,revision) VALUES(?,0) ON DUPLICATE KEY UPDATE environment_id=environment_id",environment);
    return db.queryForMap("SELECT * FROM identity_provider_runtime_heads WHERE environment_id=? FOR UPDATE",environment);
  }
  private static Long nullableLong(Map<String,Object> row,String name){return row.get(name)==null?null:((Number)row.get(name)).longValue();}
  private Row findRow(String id){
    var rows=db.query("SELECT * FROM identity_provider_versions WHERE id=? AND environment_id=?",(r,n)->new Row(r.getString("id"),r.getLong("version"),r.getLong("base_version"),r.getLong("created_at"),
        parse(r.getString("settings_json"),Settings.class),parseBooleans(r.getString("credential_presence_json")),r.getString("protected_payload"),r.getString("protected_request"),r.getString("actor_key")),id,environment);
    return rows.isEmpty()?null:rows.get(0);
  }
  private Row requireRow(String id){Row row=findRow(id);if(row==null)throw missing();return row;}
  private VersionView view(Row row){
    Settings s=row.settings();Map<String,Boolean> c=row.presence();boolean complete=!s.smsSignName().isEmpty()&&!s.smsTemplateCode().isEmpty()&&!s.wechatAppId().isEmpty()
        &&"com.aimanager.parent".equals(s.parentPackageName())&&!s.parentCertificateSha256().isEmpty()&&yes(c,"otpHmacKey")&&yes(c,"smsAccessKeyId")&&yes(c,"smsAccessKeySecret")&&yes(c,"wechatAppSecret");
    return new VersionView(row.id(),row.version(),row.baseVersion(),row.createdAt(),s,c,complete?"READY":"BLOCKED");
  }
  private Map<String,String> credentials(Row row){
    try{Map<String,String> values=json.readValue(vault.open(VAULT,environment,row.id(),row.protectedPayload()),STRINGS);
      if(!values.keySet().equals(CREDENTIAL_KEYS)||values.values().stream().anyMatch(Objects::isNull))throw new IllegalArgumentException();return new TreeMap<>(values);
    }catch(Exception unavailable){throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE,"IDENTITY_PROVIDER_VAULT_UNAVAILABLE");}
  }
  private static Map<String,Boolean> presence(Map<String,String> values){
    var result=new TreeMap<String,Boolean>();result.put("otpHmacKey",!values.get(HMAC).isEmpty());
    REPLACEMENTS.forEach((key,name)->result.put(key,!values.get(name).isEmpty()));return Map.copyOf(result);
  }
  private SaveVersion normalize(SaveVersion input){
    if(input==null||input.settings()==null||input.baseVersion()==null||input.baseVersion()<0)throw invalid();uuid(input.id());Settings s=input.settings();
    String sign=value(s.smsSignName()),template=value(s.smsTemplateCode()),app=value(s.wechatAppId()),pkg=value(s.parentPackageName()),cert=value(s.parentCertificateSha256()).toLowerCase(Locale.ROOT);
    if(sign.length()>32||!sign.equals(sign.strip())||sign.chars().anyMatch(ch->Character.isISOControl(ch)||ch==0xfeff||"\"'`$;&|<>".indexOf(ch)>=0)
        ||!optional(template,"SMS_[0-9]{1,32}")||!optional(app,"wx[0-9a-fA-F]{16}")||!pkg.isEmpty()&&!"com.aimanager.parent".equals(pkg)||!optional(cert,"[a-f0-9]{64}"))throw invalid();
    Map<String,String> replacements=new TreeMap<>();
    if(input.replacements()!=null)input.replacements().forEach((key,secret)->{
      if(!REPLACEMENTS.containsKey(key)||!validSecret(key,secret))throw invalid();replacements.put(key,secret);
    });
    if(input.clearSmsSecurityToken()&&replacements.containsKey("smsSecurityToken"))throw invalid();
    return new SaveVersion(input.id(),input.baseVersion(),new Settings(sign,template,app,pkg,cert),replacements,input.clearSmsSecurityToken());
  }
  private static boolean validSecret(String key,String value){
    if(value==null||value.getBytes(StandardCharsets.UTF_8).length>8192||value.chars().anyMatch(c->c=='\r'||c=='\n'||c==0||c==0xfeff)
        ||value.matches("(?i)^(not[-_ ]?real|change[-_ ]?me|your[-_ ]|replace[-_ ]|example|test-secret).*"))return false;
    return switch(key){case "smsAccessKeyId"->value.matches("[A-Za-z0-9._-]{16,128}");case "smsAccessKeySecret"->value.matches("[A-Za-z0-9+/=_-]{16,128}");
      case "smsSecurityToken"->value.matches("[A-Za-z0-9+/=._-]{16,8192}");case "wechatAppSecret"->value.matches("[0-9a-fA-F]{32}");default->false;};
  }
  private static boolean optional(String value,String pattern){return value.isEmpty()||value.matches(pattern);}
  private static String value(String value){return value==null?"":value;}
  private static String uuid(String value){
    if(value==null||!value.matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}"))throw invalid();
    return value;
  }
  private static String sha(String value){if(value==null||!value.matches("[a-fA-F0-9]{64}"))throw invalid();return value.toLowerCase(Locale.ROOT);}
  private void audit(String actor,String action,String resource,String version,String result){
    String correlation=MDC.get("correlationId");db.update("INSERT INTO identity_provider_audit_events(id,environment_id,actor_key,action,resource_id,version_id,result_code,correlation_id,occurred_at) VALUES(?,?,?,?,?,?,?,?,?)",
        UUID.randomUUID().toString(),environment,ActorKeys.key(actor),action,resource,version,result,correlation==null?UUID.randomUUID().toString():correlation,clock.millis());
  }
  private byte[] bytes(Object value){try{return json.writeValueAsBytes(value);}catch(Exception invalid){throw stateUnavailable();}}
  private String text(Object value){return new String(bytes(value),StandardCharsets.UTF_8);}
  private <T>T parse(String value,Class<T> type){try{return json.readValue(value,type);}catch(Exception invalid){throw stateUnavailable();}}
  private Map<String,Boolean> parseBooleans(String value){try{var result=json.readValue(value,BOOLEANS);
    if(!result.keySet().equals(Set.of("otpHmacKey","smsAccessKeyId","smsAccessKeySecret","smsSecurityToken","wechatAppSecret"))||result.values().stream().anyMatch(Objects::isNull))throw new IllegalArgumentException();return Map.copyOf(result);
  }catch(Exception invalid){throw stateUnavailable();}}
  private static DomainException stateUnavailable(){return new DomainException(HttpStatus.SERVICE_UNAVAILABLE,"IDENTITY_PROVIDER_STATE_UNAVAILABLE");}
  private static DomainException invalid(){return DomainException.invalid("IDENTITY_PROVIDER_INVALID_INPUT");}
  private static DomainException missing(){return new DomainException(HttpStatus.NOT_FOUND,"IDENTITY_PROVIDER_NOT_FOUND");}
  private static DomainException conflict(String code){return new DomainException(HttpStatus.CONFLICT,code);}
  private record Row(String id,long version,long baseVersion,long createdAt,Settings settings,Map<String,Boolean> presence,String protectedPayload,String protectedRequest,String actorKey) {}
}
