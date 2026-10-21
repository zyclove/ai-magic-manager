package com.aimanager.identityproviders.internal;

import static com.aimanager.identityproviders.internal.ProviderContracts.*;
import java.time.Clock;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** 按当前运行版本解释验收准备；旧清单和配置加载证明均不计入真实通过。 */
@Service
class ProviderAcceptanceService {
  private final ProviderConfigurationService configurations;private final boolean salesRequested;
  private final JdbcTemplate db;private final Clock clock;private final String environment;
  ProviderAcceptanceService(ProviderConfigurationService configurations,JdbcTemplate db,Clock clock,
      @Value("${manager.identity-providers.environment-id:family-cn-pilot}") String environment,
      @Value("${manager.family.sales-enabled:false}") boolean salesRequested){
    this.configurations=configurations;this.db=db;this.clock=clock;this.environment=environment;this.salesRequested=salesRequested;
  }
  @Transactional(timeout=10)
  AcceptanceStatusView status(){
    // MySQL RR 的首次一致性读取必须位于运行版本锁之后。
    var head=configurations.lockRuntimeHead();var configuration=configurations.status(false,false,false);var version=configuration.version();
    boolean ready=version!=null&&configuration.readinessChecks().stream().allMatch(check->"READY".equals(check.status()));
    String confirmed=(String)head.get("confirmed_operation_id");long revision=((Number)head.get("revision")).longValue();
    var operations=confirmed==null?List.<Map<String,Object>>of():db.queryForList("SELECT * FROM identity_provider_release_operations WHERE environment_id=? AND id=?",environment,confirmed);
    Map<String,Object> operation=operations.size()==1?operations.get(0):Map.of();
    var runs=configurations.runs().items();AcceptanceView run=runs.isEmpty()?null:runs.get(0);
    boolean active=head.get("active_operation_id")!=null;
    boolean runtime=version!=null&&!active&&"APPLIED_CLOSED".equals(operation.get("state"))&&version.id().equals(operation.get("version_id"));
    long now=clock.millis();
    boolean bound=run!=null&&run.releaseOperationId()!=null&&run.runtimeRevision()!=null&&run.expiresAt()!=null;
    boolean current=bound&&ready&&runtime&&confirmed.equals(run.releaseOperationId())&&revision==run.runtimeRevision()
        &&version.id().equals(run.versionId())&&run.providerJarSha256().equals(operation.get("provider_jar_sha256"))
        &&run.parentApkSha256().equals(operation.get("parent_apk_sha256"))&&run.createdAt()<=now&&run.expiresAt()>now;
    String status=current?"PENDING":bound?"STALE":"BLOCKED";
    String next=version==null?"CONFIGURE":!ready?"CHECK_CONFIGURATION":active?"CHECK_RUNTIME":!runtime?"PUBLISH_CONFIGURATION":!current?"REGISTER_RUN":"PREPARE_PILOT";
    var readiness=new ArrayList<>(configuration.readinessChecks());
    readiness.add(new Check("CURRENT_RUNTIME","当前运行配置","验收准备",runtime?"READY":"BLOCKED",runtime?"RUNTIME_CONFIGURATION_CONFIRMED":"CURRENT_RUNTIME_REQUIRED",
        runtime?"当前配置已在关闭消费者入口的身份实例中确认。":"先完成当前版本的受控发布与生效核对。"));
    readiness.add(new Check("ACCEPTANCE_BINDING","本次验收登记","验收准备",current?"READY":"BLOCKED",current?"ACCEPTANCE_PREPARED":bound?"ACCEPTANCE_STALE":"ACCEPTANCE_RUN_REQUIRED",
        current?"准备独立成人试点环境，再在正式签名真机完成十二项联调。":"为当前确认版本建立新的验收登记；旧记录保留供查阅。"));
    return new AcceptanceStatusView(environment,version==null?null:version.id(),confirmed,revision,status,next,0,12,run,List.copyOf(readiness),configurations.realChecks(),ProviderFamilySalesGate.view(salesRequested));
  }
}
