package com.aimanager.identity;
import org.keycloak.models.UserSessionModel;
import org.keycloak.representations.IDToken;
import org.keycloak.models.*;
import org.keycloak.protocol.oidc.mappers.*;
import org.keycloak.provider.ProviderConfigProperty;
import java.util.List;
public final class ConsumerClaimsMapper extends AbstractOIDCProtocolMapper implements OIDCAccessTokenMapper,OIDCIDTokenMapper,UserInfoTokenMapper {
  public static final String ID="consumer-trusted-claims";
  public String getId(){return ID;}
  public String getDisplayType(){return "Verified consumer phone and method";}
  public String getDisplayCategory(){return TOKEN_MAPPER_CATEGORY;}
  public String getHelpText(){return "Claims from successful consumer authenticators only; SMS is not MFA.";}
  public int getPriority(){return 1000;}
  public List<ProviderConfigProperty> getConfigProperties(){var props=new java.util.ArrayList<ProviderConfigProperty>();OIDCAttributeMapperHelper.addIncludeInTokensConfig(props,ConsumerClaimsMapper.class);return props;}
  protected void setClaim(IDToken token,ProtocolMapperModel mapping,UserSessionModel session,KeycloakSession keycloakSession,ClientSessionContext client){
    if(!"true".equals(session.getNote("consumer_phone_verified")))return;
    var current=ConsumerIdentity.currentUsers(keycloakSession).getUserById(keycloakSession.getContext().getRealm(),session.getUser().getId());apply(token,session,current);
  }
  static void apply(IDToken token,UserSessionModel session){
    apply(token,session,session.getUser());
  }
  static void apply(IDToken token,UserSessionModel session,UserModel current){
    if(!"true".equals(session.getNote("consumer_phone_verified")))return;
    if(!ConsumerIdentity.currentSession(current,session))throw new IllegalStateException("Consumer session is stale");
    String method=session.getNote("consumer_amr"),phone=session.getNote("consumer_phone_number"),time=session.getNote("consumer_auth_time");
    if(!("sms".equals(method)||"wechat".equals(method))||phone==null||!phone.matches("\\+861[3-9][0-9]{9}")||time==null||!time.matches("[0-9]{1,12}"))throw new IllegalStateException("Consumer session evidence is incomplete");
    // 标准字段使用 Keycloak 的类型化属性，清除早期映射器残留，避免序列化产生重复字段。
    for(String claim:List.of(IDToken.PHONE_NUMBER,IDToken.PHONE_NUMBER_VERIFIED,IDToken.AUTH_TIME))token.getOtherClaims().remove(claim);
    token.setPhoneNumber(phone);token.setPhoneNumberVerified(true);token.setAuth_time(Long.parseLong(time));
    token.setOtherClaims("amr",List.of(method));
    token.setOtherClaims(ConsumerIdentity.REVISION,ConsumerIdentity.revision(current));
  }
}
