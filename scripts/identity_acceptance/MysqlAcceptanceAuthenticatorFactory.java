package com.aimanager.identity;

import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.*;
import org.keycloak.Config;
import org.keycloak.authentication.*;
import org.keycloak.models.*;
import org.keycloak.provider.ProviderConfigProperty;

/** Delegates to the production authenticator; only supplier transport is simulated. No production registration. */
public final class MysqlAcceptanceAuthenticatorFactory implements AuthenticatorFactory {
  public String getId(){return "mysql-acceptance-authenticator";}
  public Authenticator create(KeycloakSession session){return new ConsumerAuthenticator(MysqlAcceptanceFactory.settings(),
      (phone,code)->{if(!phone.matches("\\+861380000[1-9][0-9]{3}"))throw new java.io.IOException("Fixture phone only");MysqlAcceptanceFactory.CODES.put(phone,code);},
      uri->{
        String code=Arrays.stream(uri.getRawQuery().split("&")).filter(p->p.startsWith("code=")).map(p->URLDecoder.decode(p.substring(5),StandardCharsets.UTF_8)).findFirst().orElse("");
        if(!code.matches("fixture_[a-z]+_[a-f0-9]{32}"))return new AliyunSms.Response(400,"{}");
        String openid=code.substring(0,code.lastIndexOf('_'));
        return new AliyunSms.Response(200,"{\"openid\":\""+openid+"\",\"access_token\":\"fixture-only\"}");
      });}
  public String getDisplayType(){return "PRIVATE acceptance fixture";}public String getReferenceCategory(){return "fixture";}
  public boolean isConfigurable(){return false;}public boolean isUserSetupAllowed(){return false;}
  public String getHelpText(){return "Never deploy this separately packaged test fixture.";}
  public List<ProviderConfigProperty> getConfigProperties(){return List.of();}
  public AuthenticationExecutionModel.Requirement[] getRequirementChoices(){return new AuthenticationExecutionModel.Requirement[]{AuthenticationExecutionModel.Requirement.REQUIRED};}
  public void init(Config.Scope c){}public void postInit(KeycloakSessionFactory f){}public void close(){}
}
