package com.aimanager.identity;

import java.io.IOException;
import java.time.Clock;
import java.util.*;
import org.keycloak.authentication.*;
import org.keycloak.models.*;
import org.keycloak.sessions.AuthenticationSessionModel;

/** 所有账号操作在身份服务中证明手机号/微信持有权，客户端参数仅限定预期账号。 */
final class ConsumerAccountFlow {
  private static final String PREFIX="consumer.account.",ACTION=PREFIX+"action",OP=PREFIX+"operation",ACTOR=PREFIX+"actor",REV=PREFIX+"revision",PHONE=PREFIX+"phone",OPENID=PREFIX+"openid",START=PREFIX+"startedAt",PHASE=PREFIX+"phase",CHALLENGE=PREFIX+"challenge",NEW=PREFIX+"newPhone",PROVED=PREFIX+"provedAt",BLOCKED=PREFIX+"blocked";
  private static final Set<String> ACTIONS=Set.of("CHANGE_PHONE","RECOVER_PHONE","BIND_WECHAT","UNBIND_WECHAT");
  private final Map<String,String> config;private final PhoneOtp otp;private final WechatNative.Transport transport;private final Clock clock;
  ConsumerAccountFlow(Map<String,String> config,PhoneOtp otp,WechatNative.Transport transport){this(config,otp,transport,Clock.systemUTC());}
  ConsumerAccountFlow(Map<String,String> config,PhoneOtp otp,WechatNative.Transport transport,Clock clock){this.config=config;this.otp=otp;this.transport=transport;this.clock=clock;}
  static boolean requested(AuthenticationFlowContext context){return context.getAuthenticationSession().getAuthNote(ACTION)!=null||context.getAuthenticationSession().getAuthNote(BLOCKED)!=null||context.getUriInfo().getQueryParameters().containsKey("family_account_action");}
  void authenticate(AuthenticationFlowContext context){
    var auth=context.getAuthenticationSession();
    if(!available()){auth.setAuthNote(BLOCKED,"true");form(context,"账号安全服务暂未开放，请稍后再试");return;}
    if(auth.getAuthNote(BLOCKED)!=null){form(context,"本次操作已结束，请回到 App 重新开始");return;}
    if(auth.getAuthNote(ACTION)!=null){if(!unexpired(auth)){block(context,"本次操作已过期，请回到 App 重新开始");return;}form(context,null);return;}
    try{
      var params=context.getUriInfo().getQueryParameters();String action=params.getFirst("family_account_action"),operation=params.getFirst("family_account_operation");
      if(action==null||!ACTIONS.contains(action)||!uuid(operation))throw new Rejected();
      auth.setAuthNote(START,Long.toString(clock.millis()));auth.setAuthNote(ACTION,action);auth.setAuthNote(OP,operation);
      String openId=null;
      if(action.equals("RECOVER_PHONE")||action.equals("BIND_WECHAT")){
        if(!"true".equals(config.get("CONSUMER_WECHAT_ENABLED")))throw new Rejected();
        // 网络交换在任何身份锁之外；之后只保存短期 openid 作为固定操作证据。
        openId=new WechatNative(config.get("WECHAT_NATIVE_APP_ID"),config.get("WECHAT_NATIVE_APP_SECRET"),transport).exchange(params.getFirst("family_wechat_code"));
      }
      var users=ConsumerIdentity.currentUsers(context.getSession());UserModel user;
      if(action.equals("RECOVER_PHONE")){
        user=users.getUserByFederatedIdentity(context.getRealm(),ConsumerIdentity.wechatIdentity(config.get("WECHAT_NATIVE_APP_ID"),openId));
        if(user==null)throw new Rejected();
        String expectedActor=params.getFirst("family_account_actor"),expectedRevision=params.getFirst("family_account_revision");
        if((expectedActor!=null||expectedRevision!=null)&&(!user.getId().equals(expectedActor)||!Integer.toString(ConsumerIdentity.revision(user)).equals(expectedRevision)))throw new Rejected();
      }else{
        String actor=params.getFirst("family_account_actor"),revision=params.getFirst("family_account_revision");
        if(!uuid(actor)||revision==null||!revision.matches("[1-9][0-9]{0,9}"))throw new Rejected();
        user=users.getUserById(context.getRealm(),actor);
        if(user==null||!revision.equals(Integer.toString(ConsumerIdentity.revision(user))))throw new Rejected();
      }
      ConsumerIdentity.requireConsumer(user);
      if(operation.equals(user.getFirstAttribute(ConsumerIdentity.LAST_ID)))throw new Rejected();
      auth.setAuthNote(ACTOR,user.getId());auth.setAuthNote(REV,Integer.toString(ConsumerIdentity.revision(user)));auth.setAuthNote(PHONE,ConsumerIdentity.verifiedPhone(user));
      if(openId!=null)auth.setAuthNote(OPENID,openId);
      if(action.equals("UNBIND_WECHAT")){
        var link=users.getFederatedIdentity(context.getRealm(),user,"wechat-native:"+config.get("WECHAT_NATIVE_APP_ID"));
        if(link==null)throw new Rejected();auth.setAuthNote(OPENID,link.getUserId());
      }
      auth.setAuthNote(PHASE,action.equals("RECOVER_PHONE")?"NEW":"CURRENT");form(context,null);
    }catch(IOException|IllegalArgumentException|IllegalStateException|Rejected failure){block(context,"无法完成本次账号操作，请核对账号后重新开始；旧手机不可用时需使用已绑定微信找回");}
  }
  void action(AuthenticationFlowContext context){
    var auth=context.getAuthenticationSession();
    if(!available()||auth.getAuthNote(BLOCKED)!=null||!unexpired(auth)||auth.getAuthNote(ACTOR)==null){block(context,"本次操作已结束或过期，请回到 App 重新开始");return;}
    var params=context.getHttpRequest().getDecodedFormParameters();String action=params.getFirst("action");
    try{
      if("send".equals(action)){
        current(context);
        String phone=PhoneOtp.canonicalPhone(params.getFirst("phone"));
        if(!"NEW".equals(auth.getAuthNote(PHASE))&&!phone.equals(auth.getAuthNote(PHONE))){form(context,"请输入此账号当前使用的手机号");return;}
        if("NEW".equals(auth.getAuthNote(PHASE))){if(phone.equals(auth.getAuthNote(PHONE)))throw new Rejected();auth.setAuthNote(NEW,phone);}
        String challenge=otp.send(binding(context),phone,context.getConnection().getRemoteAddr());
        String previous=auth.getAuthNote(CHALLENGE);if(previous!=null)context.getSession().singleUseObjects().remove("consumer:otp:"+previous);
        auth.setAuthNote(CHALLENGE,challenge);form(context,null);return;
      }
      if(!"verify".equals(action)){form(context,"请获取并输入短信验证码");return;}
      // 无效验证码只访问原子验证码缓存，不能占用 realm 的串行事务窗口。
      String phase=auth.getAuthNote(PHASE),phone="NEW".equals(phase)?auth.getAuthNote(NEW):auth.getAuthNote(PHONE);
      if(phone==null){form(context,"请先获取验证码");return;}
      if(!otp.verify(auth.getAuthNote(CHALLENGE),binding(context),phone,params.getFirst("code"))){form(context,"验证码错误或已过期，请重新获取后重试");return;}
      auth.removeAuthNote(CHALLENGE);
      // 最终 CAS 仍在数据库锁内重新核对账号、手机号及版本；锁失败时必须重新验证。
      ConsumerIdentityTransactions.lockRealm(context.getSession(),context.getRealm());
      UserModel raw=ConsumerIdentity.currentUsers(context.getSession()).getUserById(context.getRealm(),auth.getAuthNote(ACTOR));
      ConsumerIdentityTransactions.refreshUser(context.getSession(),context.getRealm(),raw);
      UserModel user=current(context,true);
      String operation=auth.getAuthNote(ACTION);
      if("CURRENT".equals(phase)&&"CHANGE_PHONE".equals(operation)){auth.setAuthNote(PROVED,Long.toString(clock.millis()));auth.setAuthNote(PHASE,"NEW");form(context,null);return;}
      if("CHANGE_PHONE".equals(operation)&&(auth.getAuthNote(PROVED)==null||clock.millis()-Long.parseLong(auth.getAuthNote(PROVED))>=300_000))throw new Rejected();
      if("RECOVER_PHONE".equals(operation)&&clock.millis()-Long.parseLong(auth.getAuthNote(START))>=300_000)throw new Rejected();
      mutate(context,user,phone);
    }catch(PhoneOtp.RateLimited failure){form(context,"发送较频繁，请稍后重试");}
    catch(IOException failure){form(context,"短信暂时发送失败，请稍后重试");}
    catch(IllegalArgumentException failure){form(context,"请输入正确的中国大陆手机号");}
    catch(IllegalStateException|Rejected|ConsumerIdentity.LinkConflict failure){context.getSession().getTransactionManager().setRollbackOnly();block(context,"账号状态已变化或本次验证已过期，请回到 App 核对后重新开始");}
    catch(RuntimeException failure){context.getSession().getTransactionManager().setRollbackOnly();block(context,"本次操作未完成，请回到 App 核对当前账号状态");}
  }
  private UserModel current(AuthenticationFlowContext context){return current(context,false);}
  private UserModel current(AuthenticationFlowContext context,boolean locked){
    var auth=context.getAuthenticationSession();var users=ConsumerIdentity.currentUsers(context.getSession());var user=users.getUserById(context.getRealm(),auth.getAuthNote(ACTOR));
    ConsumerIdentity.requireConsumer(user);
    if(!auth.getAuthNote(REV).equals(Integer.toString(ConsumerIdentity.revision(user)))||!auth.getAuthNote(PHONE).equals(ConsumerIdentity.verifiedPhone(user))||auth.getAuthNote(OP).equals(user.getFirstAttribute(ConsumerIdentity.LAST_ID)))throw new Rejected();
    if("RECOVER_PHONE".equals(auth.getAuthNote(ACTION))||"UNBIND_WECHAT".equals(auth.getAuthNote(ACTION))){
      var linked=locked?ConsumerIdentityTransactions.byWechat(context.getSession(),context.getRealm(),config.get("WECHAT_NATIVE_APP_ID"),auth.getAuthNote(OPENID)):users.getUserByFederatedIdentity(context.getRealm(),ConsumerIdentity.wechatIdentity(config.get("WECHAT_NATIVE_APP_ID"),auth.getAuthNote(OPENID)));
      if(linked==null||!linked.getId().equals(user.getId()))throw new Rejected();
    }
    return user;
  }
  private void mutate(AuthenticationFlowContext context,UserModel current,String verifiedPhone){
    var auth=context.getAuthenticationSession();var raw=ConsumerIdentity.currentUsers(context.getSession());var users=context.getSession().users();String action=auth.getAuthNote(ACTION);int revision=ConsumerIdentity.revision(current);
    if(revision==Integer.MAX_VALUE)throw new Rejected();
    String appId=config.get("WECHAT_NATIVE_APP_ID"),openId=auth.getAuthNote(OPENID);
    if(action.equals("CHANGE_PHONE")||action.equals("RECOVER_PHONE")){
      var owner=ConsumerIdentityTransactions.byUsername(context.getSession(),context.getRealm(),"cn-phone-"+verifiedPhone);if(owner!=null&&!owner.getId().equals(current.getId()))throw new Rejected();
    }else if(action.equals("BIND_WECHAT")){
      var owner=ConsumerIdentityTransactions.byWechat(context.getSession(),context.getRealm(),appId,openId);var existing=ConsumerIdentityTransactions.wechatForUser(context.getSession(),context.getRealm(),current,appId);
      if(owner!=null&&!owner.getId().equals(current.getId())||existing!=null&&!existing.getUserId().equals(openId))throw new Rejected();
    }
    // 通过缓存感知的模型写入，Keycloak 在事务结束后广播用户/联邦身份失效。
    UserModel user=users.getUserById(context.getRealm(),current.getId());if(user==null)throw new Rejected();
    if(action.equals("CHANGE_PHONE")||action.equals("RECOVER_PHONE")){user.setUsername("cn-phone-"+verifiedPhone);user.setSingleAttribute("consumer_phone_number",verifiedPhone);user.setSingleAttribute("consumer_phone_verified","true");}
    else if(action.equals("BIND_WECHAT")){ConsumerIdentityTransactions.linkWechat(context.getSession(),context.getRealm(),user,appId,openId);}
    else if(!users.removeFederatedIdentity(context.getRealm(),user,"wechat-native:"+appId))throw new Rejected();
    user.setSingleAttribute(ConsumerIdentity.REVISION,Integer.toString(revision+1));user.setSingleAttribute(ConsumerIdentity.LAST_ID,auth.getAuthNote(OP));user.setSingleAttribute(ConsumerIdentity.LAST_ACTION,action);user.setSingleAttribute(ConsumerIdentity.LAST_AT,Long.toString(clock.millis()));
    var sessions=context.getSession().sessions();var offline=sessions.getOfflineUserSessionsStream(context.getRealm(),user).toList();
    sessions.removeUserSessions(context.getRealm(),user);for(var old:offline)sessions.removeOfflineUserSession(context.getRealm(),old);
    String committedPhone=action.equals("CHANGE_PHONE")||action.equals("RECOVER_PHONE")?verifiedPhone:auth.getAuthNote(PHONE);
    ConsumerAuthenticator.trustedNotes(auth,committedPhone,"sms",clock.instant().getEpochSecond(),revision+1);
    auth.setAuthNote(BLOCKED,"true");auth.removeAuthNote(OPENID);auth.removeAuthNote(NEW);context.setUser(user);context.success();
  }
  private String binding(AuthenticationFlowContext context){var a=context.getAuthenticationSession();return "account:"+context.getRealm().getId()+":"+a.getParentSession().getId()+":"+a.getTabId()+":"+a.getAuthNote(OP)+":"+a.getAuthNote(ACTION)+":"+a.getAuthNote(ACTOR)+":"+a.getAuthNote(REV)+":"+a.getAuthNote(PHASE);}
  private boolean available(){return "true".equals(config.get("CONSUMER_ACCOUNT_SECURITY_ENABLED"));}
  private boolean unexpired(AuthenticationSessionModel auth){try{long start=Long.parseLong(auth.getAuthNote(START));return clock.millis()>=start&&clock.millis()-start<1_800_000;}catch(NumberFormatException e){return false;}}
  private void block(AuthenticationFlowContext context,String error){context.getAuthenticationSession().setAuthNote(BLOCKED,"true");String challenge=context.getAuthenticationSession().getAuthNote(CHALLENGE);if(challenge!=null)context.getSession().singleUseObjects().remove("consumer:otp:"+challenge);context.getAuthenticationSession().removeAuthNote(CHALLENGE);form(context,error);}
  private void form(AuthenticationFlowContext context,String error){var a=context.getAuthenticationSession();var f=context.form();String action=a.getAuthNote(ACTION),phone=a.getAuthNote(PHONE);boolean disclose="NEW".equals(a.getAuthNote(PHASE));f.setAttribute("accountAction",action==null?"UNAVAILABLE":action).setAttribute("accountStep",a.getAuthNote(PHASE)).setAttribute("accountBlocked",a.getAuthNote(BLOCKED)!=null).setAttribute("accountPhoneMasked",!disclose||phone==null?"":phone.substring(3,6)+"****"+phone.substring(10)).setAttribute("accountNewPhone",a.getAuthNote(NEW)).setAttribute("codeSent",a.getAuthNote(CHALLENGE)!=null).setAttribute("phoneAvailable",available());if(error!=null)f.setError(error);context.challenge(f.createForm("consumer-phone.ftl"));}
  static boolean uuid(String value){try{return value!=null&&UUID.fromString(value).toString().equals(value)&&UUID.fromString(value).version()==4;}catch(IllegalArgumentException e){return false;}}
  private static final class Rejected extends RuntimeException {}
}
