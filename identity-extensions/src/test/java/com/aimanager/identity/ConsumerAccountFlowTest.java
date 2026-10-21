package com.aimanager.identity;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import jakarta.ws.rs.core.MultivaluedHashMap;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.keycloak.authentication.AuthenticationFlowContext;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.models.*;
import org.keycloak.representations.userprofile.config.*;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.userprofile.UserProfileProvider;

class ConsumerAccountFlowTest {
  static final String ACTOR="11111111-1111-4111-8111-111111111111";
  static final String OPERATION="22222222-2222-4222-8222-222222222222";
  static final String OLD="+8613800138000",NEW="+8613900139000";
  @Test void missingActionCannotFallThroughToNormalRegistration(){
    Fixture f=new Fixture();f.user(ACTOR,OLD,1);assertDoesNotThrow(()->f.start(null,ACTOR,"1",null));f.send(NEW);assertTrue(f.sentPhones.isEmpty());assertEquals(0,f.successes);
  }
  @Test void changingPhoneProvesBothNumbersAndKeepsOriginalSubject() {
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,1);
    f.start("CHANGE_PHONE",ACTOR,"1",null);
    f.send(NEW);assertTrue(f.sentPhones.isEmpty(),"仅凭 actor 参数不能发送原号短信");f.send(OLD);assertEquals(OLD,f.sentPhones.get(0),"原手机号证明不能由表单替换");
    f.verifyLast();assertEquals(OLD,user.getFirstAttribute("consumer_phone_number"));
    f.send(NEW);f.verifyLast();
    assertEquals(NEW,user.getFirstAttribute("consumer_phone_number"));
    assertEquals("cn-phone-+8613900139000",user.getUsername());
    assertEquals("2",user.getFirstAttribute("consumer_identity_revision"));
    assertEquals(OPERATION,user.getFirstAttribute("consumer_last_operation_id"));
    assertEquals("CHANGE_PHONE",user.getFirstAttribute("consumer_last_operation_action"));
    assertEquals(ACTOR,f.succeeded.getId());assertEquals(1,f.successes);
    assertEquals("2",f.trusted.get("consumer_identity_revision"));
    assertEquals(1,f.revokedOnline);assertEquals(1,f.revokedOffline);
    assertEquals(1,f.users.size());
  }
  @Test void recoveryRequiresExistingWechatAndUpdatesItsOriginalAccount() {
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,1);f.links.put("wechat-a",user);
    f.start("RECOVER_PHONE",null,null,"code-a");f.send(NEW);f.verifyLast();
    assertEquals(List.of(NEW),f.sentPhones);assertEquals(NEW,user.getFirstAttribute("consumer_phone_number"));
    assertEquals(ACTOR,f.succeeded.getId());assertEquals(1,f.users.size());
  }
  @Test void unlinkedWechatCannotCreateAnAccountThroughRecovery() {
    Fixture f=new Fixture();f.start("RECOVER_PHONE",null,null,"code-a");f.send(NEW);f.verify("000000");
    assertEquals(0,f.successes);assertTrue(f.users.isEmpty());assertTrue(f.sentPhones.isEmpty());
  }
  @Test void bindingThenUnbindingKeepsPhoneAndRejectsAnotherAccountsWechat() {
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,1);
    f.start("BIND_WECHAT",ACTOR,"1","code-a");f.send(OLD);f.verifyLast();
    assertEquals(ACTOR,f.links.get("wechat-a").getId());assertEquals(OLD,user.getFirstAttribute("consumer_phone_number"));
    Fixture unlink=f.next();unlink.start("UNBIND_WECHAT",ACTOR,"2",null);unlink.send(OLD);unlink.verifyLast();
    assertTrue(f.links.isEmpty());assertEquals(OLD,user.getFirstAttribute("consumer_phone_number"));
    assertEquals("3",user.getFirstAttribute("consumer_identity_revision"));
  }
  @Test void staleRevisionAndOccupiedTargetNeverChangeIdentity() {
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,2);f.start("CHANGE_PHONE",ACTOR,"1",null);f.send(NEW);
    assertTrue(f.sentPhones.isEmpty());assertEquals("2",user.getFirstAttribute("consumer_identity_revision"));
    Fixture g=new Fixture();user=g.user(ACTOR,OLD,1);g.user("33333333-3333-4333-8333-333333333333",NEW,1);
    g.start("CHANGE_PHONE",ACTOR,"1",null);g.send(OLD);g.verifyLast();g.send(NEW);g.verifyLast();
    assertEquals(OLD,user.getFirstAttribute("consumer_phone_number"));assertEquals(0,g.successes);assertEquals(2,g.users.size());
  }
  @Test void repeatedOperationDoesNotTurnConsumedOtpIntoNewAuthentication() {
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,1);
    user.setSingleAttribute("consumer_last_operation_id",OPERATION);
    user.setSingleAttribute("consumer_last_operation_action","UNBIND_WECHAT");
    f.start("UNBIND_WECHAT",ACTOR,"1",null);f.send(NEW);f.verify("000000");
    assertEquals(0,f.successes);assertTrue(f.sentPhones.isEmpty());
  }
  @Test void disablingAccountSecurityLeavesIdentityUntouched() {
    Fixture f=new Fixture();f.config.remove("CONSUMER_ACCOUNT_SECURITY_ENABLED");f.rebuild();UserModel user=f.user(ACTOR,OLD,1);
    f.start("CHANGE_PHONE",ACTOR,"1",null);f.send(NEW);
    assertTrue(f.sentPhones.isEmpty());assertEquals(OLD,user.getFirstAttribute("consumer_phone_number"));assertEquals(0,f.successes);
  }
  @Test void recoveryRejectsDifferentExpectedActorBeforeSendingNewNumberSms(){
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,1);f.links.put("wechat-a",user);
    f.start("RECOVER_PHONE","33333333-3333-4333-8333-333333333333","1","code-a");f.send(NEW);
    assertTrue(f.sentPhones.isEmpty());assertEquals(OLD,user.getFirstAttribute("consumer_phone_number"));assertEquals(0,f.successes);
  }
  @Test void thirtyMinuteDeadlineDoesNotExtendWhenAuthenticationIsRenderedAgain(){
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,1);f.start("CHANGE_PHONE",ACTOR,"1",null);
    String expired=Long.toString(System.currentTimeMillis()-1_800_001);f.notes.put("consumer.account.startedAt",expired);
    f.authenticator.authenticate(f.context);f.send(OLD);
    assertEquals(expired,f.notes.get("consumer.account.startedAt"));assertTrue(f.sentPhones.isEmpty());assertEquals(OLD,user.getFirstAttribute("consumer_phone_number"));
  }
  @Test void oldPhoneProofExpiresBeforeNewPhoneCanBeCommitted(){
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,1);f.start("CHANGE_PHONE",ACTOR,"1",null);f.send(OLD);f.verifyLast();f.send(NEW);
    f.notes.put("consumer.account.provedAt",Long.toString(System.currentTimeMillis()-300_001));f.verifyLast();
    assertEquals(OLD,user.getFirstAttribute("consumer_phone_number"));assertEquals("1",user.getFirstAttribute("consumer_identity_revision"));assertEquals(0,f.successes);
  }
  @Test void unableToAcquireDatabaseFenceCannotChangeTheUser(){
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,1);f.start("CHANGE_PHONE",ACTOR,"1",null);f.send(OLD);String challenge=f.notes.get("consumer.account.challenge");
    when(f.session.getProvider(org.keycloak.connections.jpa.JpaConnectionProvider.class)).thenReturn(null);f.verifyLast();
    assertEquals(OLD,user.getFirstAttribute("consumer_phone_number"));assertEquals(0,f.successes);assertTrue(f.session.getTransactionManager().getRollbackOnly());
  }
  @Test void wrongAndExhaustedOtpNeverAcquireTheGlobalDatabaseFence(){
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,1);f.start("CHANGE_PHONE",ACTOR,"1",null);f.send(OLD);
    when(f.session.getProvider(org.keycloak.connections.jpa.JpaConnectionProvider.class)).thenThrow(new AssertionError("Invalid OTP must not acquire realm lock"));
    String wrong=f.lastCode.equals("000000")?"111111":"000000";
    for(int i=0;i<7;i++)f.verify(wrong);
    assertEquals(0,f.successes);assertEquals(OLD,user.getFirstAttribute("consumer_phone_number"));assertFalse(f.session.getTransactionManager().getRollbackOnly());
  }
  @Test void anotherAccountsWechatIsNeverReassigned(){
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,1);UserModel other=f.user("33333333-3333-4333-8333-333333333333",NEW,1);f.links.put("wechat-a",other);
    f.start("BIND_WECHAT",ACTOR,"1","code-a");f.send(OLD);f.verifyLast();
    assertEquals(other.getId(),f.links.get("wechat-a").getId());assertEquals("1",user.getFirstAttribute("consumer_identity_revision"));assertEquals(0,f.successes);
  }
  @Test void aLoginOtpCannotApproveAnAccountSecurityOperation(){
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,1);f.send(OLD);String loginCode=f.lastCode;
    f.start("CHANGE_PHONE",ACTOR,"1",null);f.verify(loginCode);
    assertEquals(0,f.successes);assertEquals(OLD,user.getFirstAttribute("consumer_phone_number"));assertNull(f.notes.get("consumer.account.provedAt"));
  }
  @Test void changingTheNewNumberDoesNotReuseThePreviousNumbersProof(){
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,1);f.start("CHANGE_PHONE",ACTOR,"1",null);f.send(OLD);f.verifyLast();f.send(NEW);String firstCode=f.lastCode;
    f.send("+8613700137000");f.verify(firstCode.equals(f.lastCode)?(firstCode.equals("000000")?"111111":"000000"):firstCode);
    assertEquals(0,f.successes);assertEquals(OLD,user.getFirstAttribute("consumer_phone_number"));
  }
  @Test void concurrentIdentityChangeInvalidatesTheInFlightOperation(){
    Fixture f=new Fixture();UserModel user=f.user(ACTOR,OLD,1);f.start("CHANGE_PHONE",ACTOR,"1",null);f.send(OLD);f.verifyLast();f.send(NEW);user.setSingleAttribute("consumer_identity_revision","2");f.verifyLast();
    assertEquals(0,f.successes);assertEquals(OLD,user.getFirstAttribute("consumer_phone_number"));assertNull(user.getFirstAttribute("consumer_last_operation_id"));
  }

  static final class Fixture {
    final AuthenticationFlowContext context=mock(AuthenticationFlowContext.class);
    final KeycloakSession session=mock(KeycloakSession.class);final RealmModel realm=mock(RealmModel.class);
    final AuthenticationSessionModel auth=mock(AuthenticationSessionModel.class);final UserProvider provider=mock(UserProvider.class);
    final PhoneOtpTest.Store store=new PhoneOtpTest.Store();final Map<String,String> notes=new HashMap<>(),trusted=new HashMap<>();
    final Map<String,UserModel> users=new HashMap<>(),links=new HashMap<>();final List<String> sentPhones=new ArrayList<>();
    final Map<String,String> config=new HashMap<>(Map.ofEntries(Map.entry("CONSUMER_PHONE_ENABLED","true"),Map.entry("CONSUMER_ACCOUNT_SECURITY_ENABLED","true"),Map.entry("CONSUMER_WECHAT_ENABLED","true"),Map.entry("CONSUMER_OTP_HMAC_KEY",PhoneOtpTest.SECRET),Map.entry("ALIYUN_SMS_ACCESS_KEY_ID","test"),Map.entry("ALIYUN_SMS_ACCESS_KEY_SECRET","test"),Map.entry("ALIYUN_SMS_SIGN_NAME","test"),Map.entry("ALIYUN_SMS_TEMPLATE_CODE","test"),Map.entry("WECHAT_NATIVE_APP_ID","wx-app"),Map.entry("WECHAT_NATIVE_APP_SECRET","test")));
    final org.keycloak.http.HttpRequest request=mock(org.keycloak.http.HttpRequest.class);
    final org.keycloak.models.KeycloakUriInfo uri=mock(org.keycloak.models.KeycloakUriInfo.class);
    final UserSessionProvider sessions=mock(UserSessionProvider.class);
    ConsumerAuthenticator authenticator;String lastCode;String operationId=OPERATION;UserModel succeeded;int successes,revokedOnline,revokedOffline;
    Fixture() {
      when(context.getSession()).thenReturn(session);when(context.getRealm()).thenReturn(realm);when(context.getAuthenticationSession()).thenReturn(auth);
      when(context.getHttpRequest()).thenReturn(request);when(context.getUriInfo()).thenReturn(uri);when(realm.getId()).thenReturn("realm-a");
      when(session.users()).thenReturn(provider);when(session.getProvider(UserProvider.class,"jpa")).thenReturn(provider);when(session.singleUseObjects()).thenReturn(store);
      configureJpa(session,users,links);
      var sessionContext=mock(KeycloakContext.class);when(session.getContext()).thenReturn(sessionContext);when(sessionContext.getRealm()).thenReturn(realm);
      when(session.sessions()).thenReturn(sessions);when(sessions.getOfflineUserSessionsStream(any(),any())).thenAnswer(i->Stream.of(mock(UserSessionModel.class)));
      doAnswer(i->{revokedOnline++;return null;}).when(sessions).removeUserSessions(any(RealmModel.class),any(UserModel.class));
      doAnswer(i->{revokedOffline++;return null;}).when(sessions).removeOfflineUserSession(any(),any());
      var client=mock(ClientModel.class);when(client.getClientId()).thenReturn("ai-manager-parent");when(auth.getClient()).thenReturn(client);
      var root=mock(org.keycloak.sessions.RootAuthenticationSessionModel.class);when(auth.getParentSession()).thenReturn(root);when(root.getId()).thenReturn("root");when(auth.getTabId()).thenReturn(UUID.randomUUID().toString());
      when(auth.getAuthNote(anyString())).thenAnswer(i->notes.get(i.getArgument(0)));
      doAnswer(i->{notes.put(i.getArgument(0),i.getArgument(1));return null;}).when(auth).setAuthNote(anyString(),anyString());
      doAnswer(i->{notes.remove(i.getArgument(0));return null;}).when(auth).removeAuthNote(anyString());
      doAnswer(i->{trusted.put(i.getArgument(0),i.getArgument(1));return null;}).when(auth).setUserSessionNote(anyString(),anyString());
      var forms=mock(LoginFormsProvider.class,RETURNS_SELF);when(context.form()).thenReturn(forms);
      var profile=mock(UserProfileProvider.class);when(session.getProvider(UserProfileProvider.class)).thenReturn(profile);
      UPConfig up=new UPConfig();up.setAttributes(new ArrayList<>());
      for(String name:List.of("consumer_phone_number","consumer_phone_verified","consumer_identity_revision","consumer_last_operation_id","consumer_last_operation_action","consumer_last_operation_at"))up.addOrReplaceAttribute(new UPAttribute(name,new UPAttributePermissions(Set.of("admin"),Set.of("admin"))));
      when(profile.getConfiguration()).thenReturn(up);
      var connection=mock(org.keycloak.common.ClientConnection.class);when(context.getConnection()).thenReturn(connection);when(connection.getRemoteAddr()).thenReturn("203.0.113.1");
      when(provider.getUserById(eq(realm),anyString())).thenAnswer(i->users.get(i.getArgument(1)));
      when(provider.getUserByUsername(eq(realm),anyString())).thenAnswer(i->users.values().stream().filter(u->u.getUsername().equals(i.getArgument(1))).findFirst().orElse(null));
      when(provider.getUserByFederatedIdentity(eq(realm),any())).thenAnswer(i->links.get(((FederatedIdentityModel)i.getArgument(1)).getUserId()));
      when(provider.getFederatedIdentity(eq(realm),any(),anyString())).thenAnswer(i->links.entrySet().stream().filter(e->e.getValue().getId().equals(((UserModel)i.getArgument(1)).getId())).map(e->new FederatedIdentityModel("wechat-native:wx-app",e.getKey(),e.getKey())).findFirst().orElse(null));
      doAnswer(i->{links.put(((FederatedIdentityModel)i.getArgument(2)).getUserId(),i.getArgument(1));return null;}).when(provider).addFederatedIdentity(any(),any(),any());
      when(provider.removeFederatedIdentity(eq(realm),any(),anyString())).thenAnswer(i->links.entrySet().removeIf(e->e.getValue().getId().equals(((UserModel)i.getArgument(1)).getId())));
      doAnswer(i->{succeeded=i.getArgument(0);return null;}).when(context).setUser(any());doAnswer(i->{successes++;return null;}).when(context).success();
      when(session.getTransactionManager()).thenReturn(new TestTransactions());rebuild();
    }
    void rebuild(){authenticator=new ConsumerAuthenticator(config,(p,c)->{sentPhones.add(p);lastCode=c;},u->new AliyunSms.Response(200,"{\"access_token\":\"test-token\",\"openid\":\"wechat-a\"}"));}
    UserModel user(String id,String phone,int revision){var u=mock(UserModel.class);Map<String,String> attrs=new HashMap<>();attrs.put("consumer_phone_number",phone);attrs.put("consumer_phone_verified","true");attrs.put("consumer_identity_revision",Integer.toString(revision));var name=new AtomicReference<>("cn-phone-"+phone);when(u.getId()).thenReturn(id);when(u.isEnabled()).thenReturn(true);when(u.getUsername()).thenAnswer(i->name.get());doAnswer(i->{name.set(i.getArgument(0));return null;}).when(u).setUsername(anyString());when(u.getFirstAttribute(anyString())).thenAnswer(i->attrs.get(i.getArgument(0)));doAnswer(i->{attrs.put(i.getArgument(0),i.getArgument(1));return null;}).when(u).setSingleAttribute(anyString(),anyString());users.put(id,u);return u;}
    void start(String action,String actor,String revision,String code){var p=new MultivaluedHashMap<String,String>();p.putSingle("family_account_action",action);p.putSingle("family_account_operation",operationId);if(actor!=null)p.putSingle("family_account_actor",actor);if(revision!=null)p.putSingle("family_account_revision",revision);if(code!=null)p.putSingle("family_wechat_code",code);when(uri.getQueryParameters()).thenReturn(p);authenticator.authenticate(context);finish();}
    void send(String phone){var p=new MultivaluedHashMap<String,String>();p.putSingle("action","send");p.putSingle("phone",phone);when(request.getDecodedFormParameters()).thenReturn(p);authenticator.action(context);finish();}
    void verifyLast(){verify(lastCode);}
    void verify(String code){var p=new MultivaluedHashMap<String,String>();p.putSingle("action","verify");p.putSingle("code",code);when(request.getDecodedFormParameters()).thenReturn(p);authenticator.action(context);finish();}
    void finish(){session.getTransactionManager().commit();}
    Fixture next(){store.entries.clear();notes.clear();trusted.clear();successes=0;operationId=UUID.randomUUID().toString();return this;}
  }
  static void configureJpa(KeycloakSession session){
    configureJpa(session,Map.of(),Map.of());
  }
  static void configureJpa(KeycloakSession session,Map<String,UserModel> users,Map<String,UserModel> links){
    var provider=mock(org.keycloak.connections.jpa.JpaConnectionProvider.class);var em=mock(jakarta.persistence.EntityManager.class);
    when(session.getProvider(org.keycloak.connections.jpa.JpaConnectionProvider.class)).thenReturn(provider);when(provider.getEntityManager()).thenReturn(em);
    when(em.createQuery(anyString())).thenAnswer(call->{String jpql=call.getArgument(0);var query=mock(jakarta.persistence.Query.class,RETURNS_SELF);Map<String,Object> params=new HashMap<>();when(query.setParameter(anyString(),any())).thenAnswer(i->{params.put(i.getArgument(0),i.getArgument(1));return query;});when(query.getSingleResult()).thenReturn(new Object());when(query.getResultList()).thenAnswer(i->{
      if(jpql.startsWith("select u"))return users.values().stream().filter(u->u.getUsername().equals(params.get("username"))).map(u->entity(u.getId())).toList();
      if(jpql.startsWith("select f"))return links.entrySet().stream().filter(e->params.containsKey("openId")?e.getKey().equals(params.get("openId")):e.getValue().getId().equals(params.get("actor"))).map(e->{var link=mock(org.keycloak.models.jpa.entities.FederatedIdentityEntity.class);var owner=entity(e.getValue().getId());when(link.getUser()).thenReturn(owner);when(link.getIdentityProvider()).thenReturn("wechat-native:wx-app");when(link.getUserId()).thenReturn(e.getKey());when(link.getUserName()).thenReturn(e.getKey());return link;}).toList();return List.of();});return query;});
    when(em.createNativeQuery(anyString())).thenAnswer(call->{String sql=call.getArgument(0);var query=mock(jakarta.persistence.Query.class,RETURNS_SELF);Map<String,Object> params=new HashMap<>();when(query.setParameter(anyString(),any())).thenAnswer(i->{params.put(i.getArgument(0),i.getArgument(1));return query;});when(query.getResultList()).thenAnswer(i->{
      if(sql.contains("FEDERATED_IDENTITY"))return links.entrySet().stream().filter(e->params.containsKey("openId")?e.getKey().equals(params.get("openId")):e.getValue().getId().equals(params.get("actor"))).map(e->new Object[]{e.getValue().getId(),params.get("realm"),params.get("provider"),e.getKey(),e.getKey()}).toList();
      if(!sql.contains("USER_ENTITY"))return List.of();
      var user=users.get(params.get("actor"));if(user==null)return List.of();
      return java.util.Collections.singletonList(new Object[]{user.getId(),user.getUsername(),null,null,null,null,null,user.isEnabled(),false,"fixture-constraint",params.get("realm"),null,null,0});
    });return query;});
    when(em.find(eq(org.keycloak.models.jpa.entities.UserEntity.class),any())).thenAnswer(i->entity(i.getArgument(1)));
  }
  static org.keycloak.models.jpa.entities.UserEntity entity(String id){var entity=mock(org.keycloak.models.jpa.entities.UserEntity.class);when(entity.getId()).thenReturn(id);when(entity.getAttributes()).thenReturn(new ArrayList<>());return entity;}
  static final class TestTransactions implements KeycloakTransactionManager {
    final List<KeycloakTransaction> callbacks=new ArrayList<>();boolean rollback;
    public JTAPolicy getJTAPolicy(){return JTAPolicy.NOT_SUPPORTED;}public void setJTAPolicy(JTAPolicy p){}
    public void enlist(KeycloakTransaction t){t.begin();callbacks.add(t);}public void enlistAfterCompletion(KeycloakTransaction t){enlist(t);}public void enlistPrepare(KeycloakTransaction t){enlist(t);}
    public void begin(){}public void commit(){callbacks.forEach(KeycloakTransaction::commit);callbacks.clear();}public void rollback(){callbacks.forEach(KeycloakTransaction::rollback);callbacks.clear();}public void setRollbackOnly(){rollback=true;}public boolean getRollbackOnly(){return rollback;}public boolean isActive(){return true;}
  }
}
