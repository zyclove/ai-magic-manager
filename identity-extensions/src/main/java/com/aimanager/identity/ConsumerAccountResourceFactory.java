package com.aimanager.identity;

import org.keycloak.Config;
import org.keycloak.models.*;
import org.keycloak.services.resource.*;

/** 仅挂载身份事实接口；不开放管理端 API 或客户端资料修改权限。 */
public final class ConsumerAccountResourceFactory implements RealmResourceProviderFactory {
  public String getId(){return "consumer-account";}
  public RealmResourceProvider create(KeycloakSession session){return new RealmResourceProvider(){public Object getResource(){return new ConsumerAccountResource(session,ConsumerProviderRuntime.current().configuration());}public void close(){}};}
  public void init(Config.Scope config){ConsumerProviderRuntime.current();}public void postInit(KeycloakSessionFactory factory){}public void close(){}
}
