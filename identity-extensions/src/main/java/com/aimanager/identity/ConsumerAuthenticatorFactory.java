package com.aimanager.identity;

import org.keycloak.Config;
import org.keycloak.authentication.*;
import org.keycloak.models.*;
import org.keycloak.provider.ProviderConfigProperty;
import java.util.List;

public final class ConsumerAuthenticatorFactory implements AuthenticatorFactory {
  public static final String ID="consumer-cn-phone-wechat";
  public Authenticator create(KeycloakSession session){return new ConsumerAuthenticator(ConsumerProviderRuntime.current().configuration());}
  public String getId(){return ID;}
  public String getDisplayType(){return "China consumer phone / native WeChat";}
  public String getReferenceCategory(){return "consumer-cn";}
  public boolean isConfigurable(){return false;}
  public AuthenticationExecutionModel.Requirement[] getRequirementChoices(){return new AuthenticationExecutionModel.Requirement[]{AuthenticationExecutionModel.Requirement.REQUIRED,AuthenticationExecutionModel.Requirement.DISABLED};}
  public boolean isUserSetupAllowed(){return false;}
  public String getHelpText(){return "China SMS verification and native mobile WeChat OAuth. Requires protected phone attributes and server environment credentials.";}
  public List<ProviderConfigProperty> getConfigProperties(){return List.of();}
  public void init(Config.Scope config){ConsumerProviderRuntime.current();}
  public void postInit(KeycloakSessionFactory factory){}
  public void close(){}
}
