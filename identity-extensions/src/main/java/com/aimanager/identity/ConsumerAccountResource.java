package com.aimanager.identity;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.ext.Provider;
import java.util.Map;
import java.util.Set;
import org.keycloak.models.*;
import org.keycloak.representations.AccessToken;
import org.keycloak.services.managers.AppAuthManager;
import org.keycloak.userprofile.UserProfileProvider;

/** 身份服务当前事实：令牌验签以外还核验当前登录会话、手机号与身份版本。 */
@Provider
public final class ConsumerAccountResource {
  private final KeycloakSession session;private final Map<String,String> config;
  /** CDI 扫描只创建关闭的实例；实际 realm 请求仍由 Factory 显式传入身份上下文和配置。 */
  public ConsumerAccountResource(){this(null,Map.of());}
  ConsumerAccountResource(KeycloakSession session,Map<String,String> config){this.session=session;this.config=Map.copyOf(config);}
  @POST @Path("runtime-observation") @Produces(MediaType.APPLICATION_JSON)
  public Response runtimeObservation(ConsumerProviderRuntime.Request request){
    try{return response(200,ConsumerProviderRuntime.current().observe(request));}
    catch(ConsumerProviderRuntime.Denied failure){return response(401,Map.of("errorCode","IDENTITY_RUNTIME_REQUEST_DENIED"));}
    catch(ConsumerProviderRuntime.Unavailable failure){return response(503,Map.of("errorCode","IDENTITY_RUNTIME_UNAVAILABLE"));}
  }
  @GET @Path("status") @Produces(MediaType.APPLICATION_JSON)
  public Response status(){
    try{
      requireAvailable();
      var profile=session.getProvider(UserProfileProvider.class);
      if(profile==null||!ConsumerIdentity.protectedProfile(profile.getConfiguration()))throw new Unavailable();
      var authentication=new AppAuthManager.BearerTokenAuthenticator(session).authenticate();
      if(authentication==null||authentication.getToken()==null||authentication.getUser()==null)throw new Stale();
      AccessToken token=authentication.getToken();var realm=session.getContext().getRealm();
      if(token.getSessionId()==null)throw new Stale();
      // 只接受在线会话，不能以离线令牌绕过换绑后的会话撤销。
      var active=session.sessions().getUserSession(realm,token.getSessionId());
      var current=ConsumerIdentity.currentUsers(session).getUserById(realm,token.getSubject());
      return response(200,evidence(current,active,token));
    }catch(Unavailable failure){return response(503,Map.of("errorCode","ACCOUNT_SECURITY_UNAVAILABLE"));}
    catch(Stale|IllegalArgumentException|IllegalStateException failure){return response(401,Map.of("errorCode","ACCOUNT_SESSION_STALE"));}
  }
  Status evidence(UserModel user,UserSessionModel active,AccessToken token){
    requireAvailable();
    if(token==null||!"ai-manager-parent".equals(token.getIssuedFor())||!ConsumerIdentity.currentSession(user,active)||!user.getId().equals(token.getSubject())||!active.getId().equals(token.getSessionId())||!Boolean.TRUE.equals(token.getPhoneNumberVerified())||!ConsumerIdentity.verifiedPhone(user).equals(token.getPhoneNumber()))throw new Stale();
    int revision=ConsumerIdentity.revision(user);Object claimed=token.getOtherClaims().get(ConsumerIdentity.REVISION);
    if(claimed==null){if(revision!=1||user.getFirstAttribute(ConsumerIdentity.LAST_ID)!=null)throw new Stale();}
    else if(!(claimed instanceof Integer||claimed instanceof Long)||((Number)claimed).longValue()!=revision)throw new Stale();
    String appId=config.get("WECHAT_NATIVE_APP_ID");boolean wechatConfigured="true".equals(config.get("CONSUMER_WECHAT_ENABLED"))&&appId!=null&&!appId.isBlank()&&config.get("WECHAT_NATIVE_APP_SECRET")!=null&&!config.get("WECHAT_NATIVE_APP_SECRET").isBlank();
    boolean bound=appId!=null&&!appId.isBlank()&&ConsumerIdentity.currentUsers(session).getFederatedIdentity(session.getContext()==null?null:session.getContext().getRealm(),user,"wechat-native:"+appId)!=null;
    String phone=ConsumerIdentity.verifiedPhone(user);String lastId=user.getFirstAttribute(ConsumerIdentity.LAST_ID),lastAction=user.getFirstAttribute(ConsumerIdentity.LAST_ACTION),lastAt=user.getFirstAttribute(ConsumerIdentity.LAST_AT);Long operatedAt=null;
    if(lastId!=null){if(!ConsumerAccountFlow.uuid(lastId)||lastAction==null||!Set.of("CHANGE_PHONE","RECOVER_PHONE","BIND_WECHAT","UNBIND_WECHAT").contains(lastAction)||lastAt==null||!lastAt.matches("[0-9]{1,16}"))throw new Stale();try{operatedAt=Long.valueOf(lastAt);}catch(NumberFormatException e){throw new Stale();}}
    return new Status(user.getId(),phone.substring(3,6)+"****"+phone.substring(10),true,bound,revision,true,true,true,!bound&&wechatConfigured,bound,bound&&wechatConfigured,lastId,lastId==null?null:lastAction,operatedAt);
  }
  private void requireAvailable(){
    if(!"true".equals(config.get("CONSUMER_ACCOUNT_SECURITY_ENABLED"))||!ConsumerConfiguration.phoneAvailable(config))throw new Unavailable();
  }
  private Response response(int code,Object body){return Response.status(code).type(MediaType.APPLICATION_JSON_TYPE).header("Cache-Control","no-store").header("Pragma","no-cache").entity(body).build();}
  public record Status(String subject,String phoneMasked,boolean phoneVerified,boolean wechatBound,int identityRevision,boolean sessionCurrent,boolean accountSecurityAvailable,boolean canChangePhone,boolean canBindWechat,boolean canUnbindWechat,boolean canRecoverByWechat,String lastOperationId,String lastOperationAction,Long lastOperationAt){}
  static final class Stale extends RuntimeException {}static final class Unavailable extends RuntimeException {}
}
