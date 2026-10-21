package com.aimanager.identity;
import java.util.Map;
import org.keycloak.authentication.*;
import org.keycloak.models.*;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.userprofile.UserProfileProvider;
import java.time.Clock;
import java.time.Instant;
import java.io.IOException;
public final class ConsumerAuthenticator implements Authenticator {
  private final Map<String,String> config;
  private final PhoneOtp.Sender sender;
  private final WechatNative.Transport wechatTransport;
  private static final String PHONE="consumer.pending.phone",CHALLENGE="consumer.pending.challenge",OPENID="consumer.pending.wechat";
  public ConsumerAuthenticator(Map<String,String> config){this(config,null);}
  ConsumerAuthenticator(Map<String,String> config,PhoneOtp.Sender sender){this(config,sender,WechatNative.httpTransport());}
  ConsumerAuthenticator(Map<String,String> config,PhoneOtp.Sender sender,WechatNative.Transport wechatTransport){this.config=Map.copyOf(config);this.sender=sender;this.wechatTransport=wechatTransport;}
  private boolean enabled(){return ConsumerConfiguration.phoneAvailable(config);}
  private boolean present(String...keys){for(String key:keys)if(config.get(key)==null||config.get(key).isBlank())return false;return true;}
  private boolean allowed(AuthenticationFlowContext context){
    if(!enabled()){form(context,"手机号服务暂未开放，请稍后再试");return false;}
    if(!"ai-manager-parent".equals(context.getAuthenticationSession().getClient().getClientId())){context.failure(AuthenticationFlowError.ACCESS_DENIED);return false;}
    if(!ConsumerIdentity.protectedProfile(context.getSession().getProvider(UserProfileProvider.class).getConfiguration())){form(context,"登录配置未就绪，请联系服务支持");return false;}
    return true;
  }
  public void authenticate(AuthenticationFlowContext context){
    if(!allowed(context))return;
    if(ConsumerAccountFlow.requested(context)){new ConsumerAccountFlow(config,otp(context),wechatTransport).authenticate(context);return;}
    var auth=context.getAuthenticationSession();
    // A code is accepted only at OIDC authorization entry, never from a login form.
    String code=context.getUriInfo().getQueryParameters().getFirst("family_wechat_code");
    if(code!=null&&auth.getAuthNote(OPENID)==null){
      if(!"true".equals(config.get("CONSUMER_WECHAT_ENABLED"))||!present("WECHAT_NATIVE_APP_ID","WECHAT_NATIVE_APP_SECRET")){form(context,"微信登录暂未开放，请使用手机号");return;}
      try{
        String openId=new WechatNative(config.get("WECHAT_NATIVE_APP_ID"),config.get("WECHAT_NATIVE_APP_SECRET"),wechatTransport).exchange(code);
        auth.setAuthNote(OPENID,openId);
        var identity=ConsumerIdentity.wechatIdentity(config.get("WECHAT_NATIVE_APP_ID"),openId);
        ConsumerIdentityTransactions.lockRealm(context.getSession(),context.getRealm());
        UserModel linked=ConsumerIdentityTransactions.byWechat(context.getSession(),context.getRealm(),config.get("WECHAT_NATIVE_APP_ID"),openId);
        if(linked!=null){
          ConsumerIdentity.requireConsumer(linked);
          String phone=ConsumerIdentity.verifiedPhone(linked);int revision=ConsumerIdentity.revision(linked);boolean initializeRevision=linked.getFirstAttribute(ConsumerIdentity.REVISION)==null;
          UserModel user=context.getSession().users().getUserById(context.getRealm(),linked.getId());
          if(user==null)throw new IllegalStateException("Consumer user unavailable");
          if(initializeRevision)user.setSingleAttribute(ConsumerIdentity.REVISION,"1");
          trustedNotes(auth,phone,"wechat",Instant.now().getEpochSecond(),revision);context.setUser(user);auth.removeAuthNote(OPENID);context.success();return;
        }
      }catch(IOException|IllegalArgumentException|IllegalStateException e){form(context,"微信授权未完成，请重试或使用手机号");return;}
    }
    form(context,null);
  }
  private PhoneOtp otp(AuthenticationFlowContext context){
    var sms=new AliyunSms(config.get("ALIYUN_SMS_ACCESS_KEY_ID"),config.get("ALIYUN_SMS_ACCESS_KEY_SECRET"),config.get("ALIYUN_SMS_SIGN_NAME"),config.get("ALIYUN_SMS_TEMPLATE_CODE"),config.get("ALIYUN_SMS_SECURITY_TOKEN"),AliyunSms.httpTransport());
    return new PhoneOtp(context.getSession().singleUseObjects(),config.get("CONSUMER_OTP_HMAC_KEY"),Clock.systemUTC(),sender==null?sms:sender);
  }
  private String binding(AuthenticationFlowContext context){var auth=context.getAuthenticationSession();return "login:"+context.getRealm().getId()+":"+auth.getParentSession().getId()+":"+auth.getTabId();}
  public void action(AuthenticationFlowContext context){
    if(!allowed(context))return;
    if(context.getAuthenticationSession().getAuthNote("consumer.account.action")!=null||context.getAuthenticationSession().getAuthNote("consumer.account.blocked")!=null){new ConsumerAccountFlow(config,otp(context),wechatTransport).action(context);return;}
    var params=context.getHttpRequest().getDecodedFormParameters();var auth=context.getAuthenticationSession();String action=params.getFirst("action");
    if("send".equals(action)){
      try{
        String phone=PhoneOtp.canonicalPhone(params.getFirst("phone"));
        String challenge=otp(context).send(binding(context),phone,context.getConnection().getRemoteAddr());
        String previous=auth.getAuthNote(CHALLENGE);if(previous!=null)context.getSession().singleUseObjects().remove("consumer:otp:"+previous);
        auth.setAuthNote(PHONE,phone);auth.setAuthNote(CHALLENGE,challenge);form(context,null);
      }catch(PhoneOtp.RateLimited e){form(context,"发送较频繁，请稍后重试");}
      catch(IllegalArgumentException e){form(context,"请输入正确的中国大陆手机号");}
      catch(IOException e){form(context,"短信暂时发送失败，请稍后重试");}
      return;
    }
    String phone=auth.getAuthNote(PHONE);
    if(!"verify".equals(action)||phone==null){form(context,"验证码错误或已过期，请重新获取后重试");return;}
    String openId=auth.getAuthNote(OPENID);
    try{
    if(!otp(context).verify(auth.getAuthNote(CHALLENGE),binding(context),phone,params.getFirst("code"))){form(context,"验证码错误或已过期，请重新获取后重试");return;}
    ConsumerIdentityTransactions.lockRealm(context.getSession(),context.getRealm());
    var users=context.getSession().users();var raw=ConsumerIdentity.currentUsers(context.getSession());String username="cn-phone-"+phone;
    UserModel user=ConsumerIdentityTransactions.byUsername(context.getSession(),context.getRealm(),username);
    int revision=user==null?1:ConsumerIdentity.revision(user);boolean initializeRevision=user==null||user.getFirstAttribute(ConsumerIdentity.REVISION)==null;
    if(user!=null&&(!user.isEnabled()||!phone.equals(user.getFirstAttribute("consumer_phone_number"))||!"true".equals(user.getFirstAttribute("consumer_phone_verified")))){context.failure(AuthenticationFlowError.ACCESS_DENIED);return;}
    if(openId!=null){
      var linked=ConsumerIdentityTransactions.byWechat(context.getSession(),context.getRealm(),config.get("WECHAT_NATIVE_APP_ID"),openId);
      if(linked!=null&&(user==null||!linked.getId().equals(user.getId()))){form(context,"微信已绑定其他手机号，请使用原账号登录");return;}
    }
    if(user==null){
      user=users.addUser(context.getRealm(),username);user.setEnabled(true);
      user.setSingleAttribute("consumer_phone_number",phone);user.setSingleAttribute("consumer_phone_verified","true");
    }else user=users.getUserById(context.getRealm(),user.getId());
    if(initializeRevision)user.setSingleAttribute(ConsumerIdentity.REVISION,"1");
    if(openId!=null){try{ConsumerIdentityTransactions.linkWechat(context.getSession(),context.getRealm(),user,config.get("WECHAT_NATIVE_APP_ID"),openId);}catch(ConsumerIdentity.LinkConflict e){context.getSession().getTransactionManager().setRollbackOnly();context.failure(AuthenticationFlowError.ACCESS_DENIED);return;}}
    trustedNotes(auth,phone,"sms",Instant.now().getEpochSecond(),revision);auth.removeAuthNote(CHALLENGE);auth.removeAuthNote(PHONE);auth.removeAuthNote(OPENID);context.setUser(user);context.success();
    }catch(IllegalArgumentException|IllegalStateException e){context.getSession().getTransactionManager().setRollbackOnly();context.failure(AuthenticationFlowError.ACCESS_DENIED);}
  }
  private void form(AuthenticationFlowContext context,String error){
    var builder=context.form();var auth=context.getAuthenticationSession();
    if(auth!=null)builder.setAttribute("phone",auth.getAuthNote(PHONE)).setAttribute("codeSent",auth.getAuthNote(CHALLENGE)!=null).setAttribute("wechatBinding",auth.getAuthNote(OPENID)!=null);
    builder.setAttribute("phoneAvailable",enabled());if(error!=null)builder.setError(error);
    context.challenge(builder.createForm("consumer-phone.ftl"));
  }
  static void trustedNotes(AuthenticationSessionModel auth,String phone,String method,long time){
    auth.setUserSessionNote("consumer_phone_number",phone);auth.setUserSessionNote("consumer_phone_verified","true");auth.setUserSessionNote("consumer_amr",method);auth.setUserSessionNote("consumer_auth_time",Long.toString(time));
  }
  static void trustedNotes(AuthenticationSessionModel auth,String phone,String method,long time,int revision){if(revision<1)throw new IllegalArgumentException("Invalid consumer revision");trustedNotes(auth,phone,method,time);auth.setUserSessionNote(ConsumerIdentity.REVISION,Integer.toString(revision));}
  public boolean requiresUser(){return false;}
  public boolean configuredFor(KeycloakSession s,RealmModel r,UserModel u){return true;}
  public void setRequiredActions(KeycloakSession s,RealmModel r,UserModel u){}
  public void close(){}
}
