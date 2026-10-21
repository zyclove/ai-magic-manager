package com.aimanager.identity;

import org.junit.jupiter.api.Test;
import org.keycloak.authentication.*;
import org.keycloak.forms.login.LoginFormsProvider;
import org.keycloak.models.*;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.userprofile.UserProfileProvider;
import org.keycloak.representations.userprofile.config.*;
import jakarta.ws.rs.core.MultivaluedHashMap;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class ConsumerAuthenticatorTest {
    @Test void incompleteConsumerMethodCannotDowngradeIntoAnUnmarkedInstitutionToken(){
        var f=new ConsumerAccountFlowTest.Fixture();var user=f.user(ConsumerAccountFlowTest.ACTOR,ConsumerAccountFlowTest.OLD,1);
        var session=ConsumerAccountStatusTest.active(user,ConsumerAccountFlowTest.OLD,"1");when(session.getNote("consumer_amr")).thenReturn("unknown");when(session.getNote("consumer_auth_time")).thenReturn("1700000000");
        assertThrows(IllegalStateException.class,()->ConsumerClaimsMapper.apply(new org.keycloak.representations.AccessToken(),session));
    }
    @Test void currentRawRevisionCannotBeResetByAnOlderCacheAwareUser(){
        var f=new ConsumerAccountFlowTest.Fixture();var raw=f.user(ConsumerAccountFlowTest.ACTOR,ConsumerAccountFlowTest.OLD,2);f.links.put("wechat-a",raw);
        String actor=raw.getId();var cached=mock(UserModel.class);when(cached.getId()).thenReturn(actor);
        doAnswer(i->{raw.setSingleAttribute(i.getArgument(0),i.getArgument(1));return null;}).when(cached).setSingleAttribute(anyString(),anyString());
        var aware=mock(UserProvider.class);when(aware.getUserById(f.realm,raw.getId())).thenReturn(cached);when(f.session.users()).thenReturn(aware);
        var query=new MultivaluedHashMap<String,String>();query.putSingle("family_wechat_code","code-a");when(f.uri.getQueryParameters()).thenReturn(query);
        f.authenticator.authenticate(f.context);f.finish();
        assertEquals("2",raw.getFirstAttribute("consumer_identity_revision"));assertEquals("2",f.trusted.get("consumer_identity_revision"));assertEquals(1,f.successes);
    }
    @Test void changedPhoneCannotBeResignedFromAnOlderRefreshSession() {
        var user=mock(UserModel.class);when(user.isEnabled()).thenReturn(true);
        when(user.getFirstAttribute("consumer_phone_number")).thenReturn("+8613900139000");
        when(user.getFirstAttribute("consumer_phone_verified")).thenReturn("true");
        when(user.getFirstAttribute("consumer_identity_revision")).thenReturn("2");when(user.getUsername()).thenReturn("cn-phone-+8613900139000");when(user.getId()).thenReturn("actor");
        var session=mock(UserSessionModel.class);when(session.getUser()).thenReturn(user);
        when(session.getNote("consumer_phone_verified")).thenReturn("true");
        when(session.getNote("consumer_phone_number")).thenReturn("+8613800138000");
        when(session.getNote("consumer_amr")).thenReturn("sms");
        when(session.getNote("consumer_auth_time")).thenReturn("1700000000");
        when(session.getNote("consumer_identity_revision")).thenReturn("1");
        var token=new org.keycloak.representations.AccessToken();
        assertThrows(IllegalStateException.class,()->ConsumerClaimsMapper.apply(token,session));
        assertFalse(token.getOtherClaims().containsKey("phone_number_verified"));
    }
    @Test void newPhoneAccountIsCreatedOnlyAfterRealOtpVerificationAndEmitsSmsClaims() throws Exception {
        var context=mock(AuthenticationFlowContext.class);var session=mock(KeycloakSession.class);
        var realm=mock(RealmModel.class);var auth=mock(AuthenticationSessionModel.class);
        var root=mock(org.keycloak.sessions.RootAuthenticationSessionModel.class);var client=mock(ClientModel.class);
        var form=mock(LoginFormsProvider.class,RETURNS_SELF);var profile=mock(UserProfileProvider.class);
        var request=mock(org.keycloak.http.HttpRequest.class);var connection=mock(org.keycloak.common.ClientConnection.class);
        var users=mock(UserProvider.class);var user=mock(UserModel.class);var store=new PhoneOtpTest.Store();
        Map<String,String> notes=new HashMap<>(),attributes=new HashMap<>(),trusted=new HashMap<>();
        doAnswer(i->{notes.put(i.getArgument(0),i.getArgument(1));return null;}).when(auth).setAuthNote(anyString(),anyString());
        when(auth.getAuthNote(anyString())).thenAnswer(i->notes.get(i.getArgument(0)));
        doAnswer(i->{notes.remove(i.getArgument(0));return null;}).when(auth).removeAuthNote(anyString());
        doAnswer(i->{trusted.put(i.getArgument(0),i.getArgument(1));return null;}).when(auth).setUserSessionNote(anyString(),anyString());
        doAnswer(i->{attributes.put(i.getArgument(0),i.getArgument(1));return null;}).when(user).setSingleAttribute(anyString(),anyString());
        when(context.getSession()).thenReturn(session);when(context.getRealm()).thenReturn(realm);when(context.getAuthenticationSession()).thenReturn(auth);
        when(context.form()).thenReturn(form);when(context.getHttpRequest()).thenReturn(request);when(context.getConnection()).thenReturn(connection);
        when(connection.getRemoteAddr()).thenReturn("203.0.113.1");when(realm.getId()).thenReturn("realm");when(auth.getParentSession()).thenReturn(root);when(root.getId()).thenReturn("root");when(auth.getTabId()).thenReturn("tab");
        when(auth.getClient()).thenReturn(client);when(client.getClientId()).thenReturn("ai-manager-parent");when(session.singleUseObjects()).thenReturn(store);when(session.users()).thenReturn(users);when(session.getProvider(UserProvider.class,"jpa")).thenReturn(users);when(session.getTransactionManager()).thenReturn(new ConsumerAccountFlowTest.TestTransactions());ConsumerAccountFlowTest.configureJpa(session);
        when(session.getProvider(UserProfileProvider.class)).thenReturn(profile);
        UPConfig up=new UPConfig();up.setAttributes(new ArrayList<>());
        for(String name:List.of("consumer_phone_number","consumer_phone_verified","consumer_identity_revision","consumer_last_operation_id","consumer_last_operation_action","consumer_last_operation_at"))up.addOrReplaceAttribute(new UPAttribute(name,new UPAttributePermissions(Set.of("admin"),Set.of("admin"))));
        when(profile.getConfiguration()).thenReturn(up);when(users.addUser(eq(realm),eq("cn-phone-+8613800138000"))).thenReturn(user);
        String[] code={null};
        var authenticator=new ConsumerAuthenticator(Map.of("CONSUMER_PHONE_ENABLED","true","CONSUMER_OTP_HMAC_KEY",PhoneOtpTest.SECRET,"ALIYUN_SMS_ACCESS_KEY_ID","not-real","ALIYUN_SMS_ACCESS_KEY_SECRET","not-real","ALIYUN_SMS_SIGN_NAME","not-real","ALIYUN_SMS_TEMPLATE_CODE","not-real"),(p,c)->code[0]=c,uri->{throw new AssertionError("Unexpected WeChat request");});
        var send=new MultivaluedHashMap<String,String>();send.putSingle("action","send");send.putSingle("phone","13800138000");when(request.getDecodedFormParameters()).thenReturn(send);
        authenticator.action(context);
        assertNotNull(code[0],"SMS dispatch is missing");verify(users,never()).addUser(any(),anyString());
        var verifyForm=new MultivaluedHashMap<String,String>();verifyForm.putSingle("action","verify");verifyForm.putSingle("code",code[0]);when(request.getDecodedFormParameters()).thenReturn(verifyForm);
        authenticator.action(context);
        assertEquals("+8613800138000",attributes.get("consumer_phone_number"));assertEquals("true",attributes.get("consumer_phone_verified"));
        when(user.getFirstAttribute(anyString())).thenAnswer(i->attributes.get(i.getArgument(0)));when(user.getUsername()).thenReturn("cn-phone-+8613800138000");when(user.getId()).thenReturn("actor");when(user.isEnabled()).thenReturn(true);
        UserSessionModel loggedIn=mock(UserSessionModel.class);when(loggedIn.getUser()).thenReturn(user);when(loggedIn.getNote(anyString())).thenAnswer(i->trusted.get(i.getArgument(0)));
        var token=new org.keycloak.representations.AccessToken();ConsumerClaimsMapper.apply(token,loggedIn);
        assertEquals(List.of("sms"),token.getOtherClaims().get("amr"));assertEquals(true,token.getPhoneNumberVerified());
        verify(context).success();
    }
    @Test void missingProviderConfigCannotAuthenticateOrCreateUser(){
        AuthenticationFlowContext context=mock(AuthenticationFlowContext.class);
        KeycloakSession session=mock(KeycloakSession.class);when(context.getSession()).thenReturn(session);
        LoginFormsProvider form=mock(LoginFormsProvider.class,RETURNS_SELF);when(context.form()).thenReturn(form);
        new ConsumerAuthenticator(Map.of(),(phone,code)->{throw new AssertionError("Unexpected SMS request");},uri->{throw new AssertionError("Unexpected WeChat request");}).authenticate(context);
        verify(context,never()).success();verify(context,never()).setUser(any());verify(context).challenge(any());
    }
    @Test void verifiedPhoneSetsTrustedNotesAndDoesNotClaimMfa(){
        var auth=mock(AuthenticationSessionModel.class);
        ConsumerAuthenticator.trustedNotes(auth,"+8613800138000","sms",1700000000L);
        verify(auth).setUserSessionNote("consumer_phone_number","+8613800138000");
        verify(auth).setUserSessionNote("consumer_phone_verified","true");
        verify(auth).setUserSessionNote("consumer_amr","sms");
        verify(auth).setUserSessionNote("consumer_auth_time","1700000000");
    }
    @Test void tokenClaimsComeOnlyFromTrustedSessionNotesWithAccurateWechatAmr(){
        UserSessionModel userSession=mock(UserSessionModel.class);
        UserModel user=mock(UserModel.class);when(userSession.getUser()).thenReturn(user);when(user.isEnabled()).thenReturn(true);when(user.getId()).thenReturn("actor");when(user.getUsername()).thenReturn("cn-phone-+8613800138000");when(user.getFirstAttribute("consumer_phone_number")).thenReturn("+8613800138000");when(user.getFirstAttribute("consumer_phone_verified")).thenReturn("true");
        when(userSession.getNote("consumer_phone_number")).thenReturn("+8613800138000");
        when(userSession.getNote("consumer_phone_verified")).thenReturn("true");
        when(userSession.getNote("consumer_amr")).thenReturn("wechat");
        when(userSession.getNote("consumer_auth_time")).thenReturn("1700000000");
        var token=new org.keycloak.representations.AccessToken();
        ConsumerClaimsMapper.apply(token,userSession);
        assertEquals("+8613800138000",token.getPhoneNumber());
        assertEquals(true,token.getPhoneNumberVerified());
        assertEquals(List.of("wechat"),token.getOtherClaims().get("amr"));
        assertEquals(1700000000L,token.getAuth_time());
        var missing=new org.keycloak.representations.AccessToken();
        ConsumerClaimsMapper.apply(missing,mock(UserSessionModel.class));
        assertNull(missing.getPhoneNumberVerified());
    }
    @Test void incompleteTrustedSessionCannotEmitVerifiedClaimsOrCrashTokenIssuance(){
        var session=mock(UserSessionModel.class);
        when(session.getNote("consumer_phone_verified")).thenReturn("true");
        var token=new org.keycloak.representations.AccessToken();
        assertThrows(IllegalStateException.class,()->ConsumerClaimsMapper.apply(token,session));
        assertFalse(token.getOtherClaims().containsKey("phone_number_verified"));
    }
}
