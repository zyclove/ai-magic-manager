package com.aimanager.identity;
import org.keycloak.models.*;
import org.keycloak.representations.userprofile.config.UPConfig;
public final class ConsumerIdentity {
  static final String REVISION="consumer_identity_revision",LAST_ID="consumer_last_operation_id",LAST_ACTION="consumer_last_operation_action",LAST_AT="consumer_last_operation_at";
  static final java.util.List<String> PROTECTED_ATTRIBUTES=java.util.List.of("consumer_phone_number","consumer_phone_verified",REVISION,LAST_ID,LAST_ACTION,LAST_AT);
  public static class LinkConflict extends RuntimeException {}
  public static boolean protectedProfile(UPConfig config){
    if(config==null||config.getAttributes()==null)return false;
    for(String name:PROTECTED_ATTRIBUTES){
      var attribute=config.getAttribute(name);
      if(attribute==null||attribute.getPermissions()==null||attribute.getPermissions().getEdit()==null||attribute.getPermissions().getEdit().contains("user")||!attribute.getPermissions().getEdit().stream().allMatch("admin"::equals))return false;
    }
    return true;
  }
  public static String verifiedPhone(UserModel user){
    if(!"true".equals(user.getFirstAttribute("consumer_phone_verified")))throw new IllegalStateException("Verified phone is required");
    return PhoneOtp.canonicalPhone(user.getFirstAttribute("consumer_phone_number"));
  }
  /** 旧账号没有版本时仅视作版本 1；任何已执行过的操作都必须有正式版本。 */
  static int revision(UserModel user){
    String value=user.getFirstAttribute(REVISION);
    if(value==null&&user.getFirstAttribute(LAST_ID)==null)return 1;
    if(value==null||!value.matches("[1-9][0-9]{0,9}"))throw new IllegalStateException("Invalid consumer revision");
    try{int revision=Integer.parseInt(value);if(revision<1)throw new IllegalStateException("Invalid consumer revision");return revision;}
    catch(NumberFormatException e){throw new IllegalStateException("Invalid consumer revision");}
  }
  static void requireConsumer(UserModel user){
    if(user==null||!user.isEnabled()||!("cn-phone-"+verifiedPhone(user)).equals(user.getUsername()))throw new IllegalStateException("Consumer identity is unavailable");
    revision(user);
  }
  static boolean currentSession(UserModel user,UserSessionModel session){
    try{
      requireConsumer(user);
      if(session==null||session.getUser()==null||!user.getId().equals(session.getUser().getId())||!verifiedPhone(user).equals(session.getNote("consumer_phone_number"))||!"true".equals(session.getNote("consumer_phone_verified")))return false;
      String value=session.getNote(REVISION);
      return value==null?revision(user)==1&&user.getFirstAttribute(LAST_ID)==null:Integer.toString(revision(user)).equals(value);
    }catch(IllegalArgumentException|IllegalStateException e){return false;}
  }
  /** 26.8 本地用户存储读取，避免把跨节点缓存中的旧手机号当作当前事实。 */
  static UserProvider currentUsers(KeycloakSession session){
    UserProvider users=session.getProvider(UserProvider.class,"jpa");
    if(users==null)throw new IllegalStateException("Local consumer storage is unavailable");
    return users;
  }
  static FederatedIdentityModel wechatIdentity(String appId,String openId){return new FederatedIdentityModel("wechat-native:"+appId,openId,openId);}
  public static void linkWechat(UserProvider users,RealmModel realm,UserModel phone,String appId,String openId){
    var identity=wechatIdentity(appId,openId);
    UserModel linked=users.getUserByFederatedIdentity(realm,identity);
    if(linked!=null){if(!linked.getId().equals(phone.getId()))throw new LinkConflict();return;}
    var existing=users.getFederatedIdentity(realm,phone,identity.getIdentityProvider());
    if(existing!=null&&!existing.getUserId().equals(openId))throw new LinkConflict();
    if(existing==null)users.addFederatedIdentity(realm,phone,identity);
  }
}
