package com.aimanager.identity;

import jakarta.ws.rs.*;
import jakarta.ws.rs.ext.Provider;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import org.keycloak.Config;
import org.keycloak.connections.jpa.JpaConnectionProvider;
import org.keycloak.models.*;
import org.keycloak.services.resource.*;

/** PRIVATE TEST FIXTURE. Packaged separately, mounted only in a fresh internal-network test container. */
public final class MysqlAcceptanceFactory implements RealmResourceProviderFactory {
  static final String HMAC="isolated-fixture-hmac-key-at-least-32-bytes";
  static final Map<String,String> CODES=new ConcurrentHashMap<>();
  static final AtomicBoolean HOLDING=new AtomicBoolean();
  static final AtomicBoolean RR_PRIMED=new AtomicBoolean(),RR_RELEASE=new AtomicBoolean();
  static final AtomicBoolean USER_RR_PRIMED=new AtomicBoolean(),USER_RR_RELEASE=new AtomicBoolean();
  record FidRound(String mode,AtomicBoolean primed,AtomicBoolean release){}
  static final Map<String,FidRound> FID_ROUNDS=new ConcurrentHashMap<>();
  static Map<String,String> settings(){return Map.ofEntries(
      Map.entry("CONSUMER_PHONE_ENABLED","true"),Map.entry("CONSUMER_WECHAT_ENABLED","true"),
      Map.entry("CONSUMER_ACCOUNT_SECURITY_ENABLED","true"),Map.entry("CONSUMER_OTP_HMAC_KEY",HMAC),
      Map.entry("ALIYUN_SMS_ACCESS_KEY_ID","fixture-only"),Map.entry("ALIYUN_SMS_ACCESS_KEY_SECRET","fixture-only"),
      Map.entry("ALIYUN_SMS_SIGN_NAME","fixture-only"),Map.entry("ALIYUN_SMS_TEMPLATE_CODE","fixture-only"),
      Map.entry("WECHAT_NATIVE_APP_ID","wx-fixture"),Map.entry("WECHAT_NATIVE_APP_SECRET","fixture-only"));}
  public String getId(){return "mysql-acceptance-fixture";}
  public RealmResourceProvider create(KeycloakSession session){return new RealmResourceProvider(){
    public Object getResource(){return new Resource(session);}public void close(){}};}
  public void init(Config.Scope c){}public void postInit(KeycloakSessionFactory f){}public void close(){}
  @Provider public static final class Resource {
    private final KeycloakSession session;
    public Resource(){this(null);}public Resource(KeycloakSession s){session=s;}
    private static String phone(String raw){String value=PhoneOtp.canonicalPhone(raw);if(!value.matches("\\+861380000[1-9][0-9]{3}"))throw new BadRequestException();return value;}
    @POST @Path("reset/{phone}") @Produces("application/json")
    public Map<String,Object> reset(@PathParam("phone")String raw){
      String p=phone(raw),digest=PhoneOtp.hmac(HMAC.getBytes(StandardCharsets.UTF_8),"phone:"+p);
      session.singleUseObjects().remove("consumer:cooldown:"+digest);CODES.remove(p);return Map.of("passed",true);
    }
    @GET @Path("proof/{phone}") @Produces("application/json")
    public Map<String,String> proof(@PathParam("phone")String raw){String code=CODES.remove(phone(raw));if(code==null)throw new NotFoundException();return Map.of("code",code);}
    @GET @Path("facts") @Produces("application/json")
    public Map<String,Object> facts(){
      var em=session.getProvider(JpaConnectionProvider.class).getEntityManager();
      return Map.of("databaseVersion",em.createNativeQuery("select version()").getSingleResult(),
          "isolation",em.createNativeQuery("select @@transaction_isolation").getSingleResult(),"holding",HOLDING.get(),"rrPrimed",RR_PRIMED.get(),"userRrPrimed",USER_RR_PRIMED.get());
    }
    @POST @Path("fid-prime/{mode}/{phone}/{round}") @Produces("application/json")
    public Map<String,Object> fidPrime(@PathParam("mode")String mode,@PathParam("phone")String raw,@PathParam("round")String round){
      if(!Set.of("owner","actor").contains(mode)||!round.matches("[a-f0-9]{32}"))throw new BadRequestException();
      var rendezvous=new FidRound(mode,new AtomicBoolean(),new AtomicBoolean());
      if(FID_ROUNDS.putIfAbsent(round,rendezvous)!=null)throw new BadRequestException();
      var realm=session.getContext().getRealm();var user=ConsumerIdentity.currentUsers(session).getUserByUsername(realm,"cn-phone-"+phone(raw));
      if(user==null)throw new IllegalStateException("Fixture FID actor missing");user.getAttributes();
      rendezvous.primed().set(true);long deadline=System.nanoTime()+8_000_000_000L;
      try{while(!rendezvous.release().get()&&System.nanoTime()<deadline)Thread.sleep(20);}catch(InterruptedException failure){Thread.currentThread().interrupt();throw new IllegalStateException();}
      if(!rendezvous.release().get())throw new IllegalStateException("Fixture FID rendezvous timeout");ConsumerIdentityTransactions.lockRealm(session,realm);
      if("owner".equals(mode)){
        var owner=ConsumerIdentityTransactions.byWechat(session,realm,"wx-fixture","fixture_ownerprobe");
        if(owner==null||!owner.getId().equals(user.getId()))throw new IllegalStateException("Current FID owner is stale");
      }else{
        var link=ConsumerIdentityTransactions.wechatForUser(session,realm,user,"wx-fixture");
        if(link==null||!"fixture_actorprobe".equals(link.getUserId()))throw new IllegalStateException("Current actor FID is stale");
      }
      return Map.of("passed",true);
    }
    @GET @Path("fid-ready/{round}") @Produces("application/json")
    public Map<String,Object> fidReady(@PathParam("round")String round){
      var rendezvous=FID_ROUNDS.get(round);return Map.of("primed",rendezvous!=null&&rendezvous.primed().get());
    }
    @POST @Path("fid-release/{round}") @Produces("application/json")
    public Map<String,Object> fidRelease(@PathParam("round")String round){
      var rendezvous=FID_ROUNDS.get(round);if(rendezvous==null)throw new BadRequestException();rendezvous.release().set(true);return Map.of("passed",true);
    }
    @POST @Path("rr-user-prime/{phone}") @Produces("application/json")
    public Map<String,Object> rrUserPrime(@PathParam("phone")String raw){
      var realm=session.getContext().getRealm();var user=ConsumerIdentity.currentUsers(session).getUserByUsername(realm,"cn-phone-"+phone(raw));
      if(user==null||!user.isEnabled()||ConsumerIdentity.revision(user)!=1)throw new IllegalStateException("Fixture initial user row");
      user.getAttributes();USER_RR_PRIMED.set(true);long deadline=System.nanoTime()+8_000_000_000L;
      try{while(!USER_RR_RELEASE.get()&&System.nanoTime()<deadline)Thread.sleep(20);}catch(InterruptedException failure){Thread.currentThread().interrupt();throw new IllegalStateException();}
      if(!USER_RR_RELEASE.get())throw new IllegalStateException("Fixture user row rendezvous timeout");
      ConsumerIdentityTransactions.lockRealm(session,realm);var fresh=ConsumerIdentityTransactions.byUsername(session,realm,"cn-phone-"+phone(raw));
      if(fresh==null||fresh.isEnabled()||ConsumerIdentity.revision(fresh)!=1)throw new IllegalStateException("RR current locked user enabled remains stale");
      return Map.of("passed",true);
    }
    @POST @Path("rr-user-update/{phone}") @Produces("application/json")
    public Map<String,Object> rrUserUpdate(@PathParam("phone")String raw){
      var realm=session.getContext().getRealm();ConsumerIdentityTransactions.lockRealm(session,realm);
      var current=ConsumerIdentityTransactions.byUsername(session,realm,"cn-phone-"+phone(raw));
      if(current==null)throw new IllegalStateException("Fixture user row is missing");
      session.users().getUserById(realm,current.getId()).setEnabled(false);return Map.of("passed",true);
    }
    @POST @Path("rr-user-release") @Produces("application/json")
    public Map<String,Object> rrUserRelease(){USER_RR_RELEASE.set(true);return Map.of("passed",true);}
    @POST @Path("rr-prime/{phone}") @Produces("application/json")
    public Map<String,Object> rrPrime(@PathParam("phone")String raw){
      var realm=session.getContext().getRealm();var user=ConsumerIdentity.currentUsers(session).getUserByUsername(realm,"cn-phone-"+phone(raw));
      if(user==null||ConsumerIdentity.revision(user)!=1)throw new IllegalStateException("Fixture revision");
      user.getAttributes();RR_PRIMED.set(true);long deadline=System.nanoTime()+8_000_000_000L;
      try{while(!RR_RELEASE.get()&&System.nanoTime()<deadline)Thread.sleep(20);}catch(InterruptedException failure){Thread.currentThread().interrupt();throw new IllegalStateException();}
      if(!RR_RELEASE.get())throw new IllegalStateException("Fixture rendezvous timeout");
      ConsumerIdentityTransactions.lockRealm(session,realm);
      // Query acquires the user lock before refresh, matching a production already-locked lookup.
      var fresh=ConsumerIdentityTransactions.byUsername(session,realm,"cn-phone-"+phone(raw));
      if(fresh==null||fresh.isEnabled()||ConsumerIdentity.revision(fresh)!=2||!"present-after-snapshot".equals(fresh.getFirstAttribute("fixture_new_attribute")))throw new IllegalStateException("RR stale user row or attribute collection");
      return Map.of("passed",true);
    }
    @POST @Path("rr-update/{phone}") @Produces("application/json")
    public Map<String,Object> rrUpdate(@PathParam("phone")String raw){
      var realm=session.getContext().getRealm();ConsumerIdentityTransactions.lockRealm(session,realm);
      var current=ConsumerIdentityTransactions.byUsername(session,realm,"cn-phone-"+phone(raw));
      var user=session.users().getUserById(realm,current.getId());user.setEnabled(false);user.setSingleAttribute(ConsumerIdentity.REVISION,"2");user.setSingleAttribute("fixture_new_attribute","present-after-snapshot");return Map.of("passed",true);
    }
    @POST @Path("rr-release") @Produces("application/json")
    public Map<String,Object> rrRelease(){RR_RELEASE.set(true);return Map.of("passed",true);}
    @POST @Path("pending-refresh/{phone}") @Produces("application/json")
    public Map<String,Object> pendingRefresh(@PathParam("phone")String raw){
      var realm=session.getContext().getRealm();ConsumerIdentityTransactions.lockRealm(session,realm);
      var current=ConsumerIdentity.currentUsers(session).getUserByUsername(realm,"cn-phone-"+phone(raw));
      if(current==null)throw new IllegalStateException("Fixture actor is missing");current.getAttributes();
      var actor=session.users().getUserById(realm,current.getId());
      var other=session.users().getUserByUsername(realm,"cn-phone-+8613800001012");
      if(other==null)throw new IllegalStateException("Fixture secondary actor is missing");actor.getAttributes();other.getAttributes();
      actor.setSingleAttribute("fixture_pending_before","must-survive");other.setSingleAttribute("fixture_unrelated_before","must-survive");
      var fresh=ConsumerIdentityTransactions.refreshUser(session,realm,current);
      if(!"must-survive".equals(fresh.getFirstAttribute("fixture_pending_before"))||!"must-survive".equals(other.getFirstAttribute("fixture_unrelated_before")))throw new IllegalStateException("Refresh lost pending writes");
      // Keep using the exact cache-aware references created before refresh.
      actor.setSingleAttribute("fixture_pending_after","must-survive");other.setSingleAttribute("fixture_unrelated_after","must-survive");
      return Map.of("passed",true);
    }
    @POST @Path("hold") @Produces("application/json")
    public Map<String,Object> hold(@QueryParam("milliseconds")@DefaultValue("1200")long milliseconds,
        @QueryParam("rollback")@DefaultValue("false")boolean rollback){
      if(milliseconds<0||milliseconds>6000)throw new BadRequestException();
      ConsumerIdentityTransactions.lockRealm(session,session.getContext().getRealm());HOLDING.set(true);
      try{Thread.sleep(milliseconds);}catch(InterruptedException failure){Thread.currentThread().interrupt();throw new IllegalStateException();}finally{HOLDING.set(false);}
      if(rollback){session.users().addUser(session.getContext().getRealm(),"fixture-rollback-user");session.getTransactionManager().setRollbackOnly();}
      return Map.of("passed",true);
    }
    @GET @Path("user/{phone}") @Produces("application/json")
    public Map<String,Object> user(@PathParam("phone")String raw){
      var realm=session.getContext().getRealm();var user=ConsumerIdentity.currentUsers(session).getUserByUsername(realm,"cn-phone-"+phone(raw));
      if(user==null)return Map.of("exists",false);
      var result=new LinkedHashMap<String,Object>();result.put("exists",true);result.put("subject",user.getId());result.put("revision",ConsumerIdentity.revision(user));
      result.put("enabled",user.isEnabled());result.put("newAttributePresent","present-after-snapshot".equals(user.getFirstAttribute("fixture_new_attribute")));
      result.put("pendingBefore","must-survive".equals(user.getFirstAttribute("fixture_pending_before")));
      result.put("pendingAfter","must-survive".equals(user.getFirstAttribute("fixture_pending_after")));
      result.put("unrelatedBefore","must-survive".equals(user.getFirstAttribute("fixture_unrelated_before")));
      result.put("unrelatedAfter","must-survive".equals(user.getFirstAttribute("fixture_unrelated_after")));
      result.put("wechatBound",ConsumerIdentity.currentUsers(session).getFederatedIdentity(realm,user,"wechat-native:wx-fixture")!=null);
      result.put("online",session.sessions().getUserSessionsStream(realm,user).count());result.put("offline",session.sessions().getOfflineUserSessionsStream(realm,user).count());
      result.put("rollbackAbsent",ConsumerIdentity.currentUsers(session).getUserByUsername(realm,"fixture-rollback-user")==null);
      return result;
    }
    @POST @Path("grant-offline/{phone}") @Produces("application/json")
    public Map<String,Object> offline(@PathParam("phone")String raw){
      var realm=session.getContext().getRealm();var user=session.users().getUserByUsername(realm,"cn-phone-"+phone(raw));
      if(user==null)throw new NotFoundException();var role=realm.getRole("offline_access");if(role==null)role=realm.addRole("offline_access");user.grantRole(role);return Map.of("passed",true);
    }
  }
}
