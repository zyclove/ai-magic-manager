package com.aimanager.identity;

import org.junit.jupiter.api.Test;
import org.keycloak.models.*;
import org.keycloak.representations.userprofile.config.*;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class ConsumerIdentityTest {
    @Test void refusesWritableOrMissingServerPhoneAttributes(){
        UPConfig profile=new UPConfig();profile.setAttributes(new ArrayList<>());
        assertFalse(ConsumerIdentity.protectedProfile(profile));
        for(String name:List.of("consumer_phone_number","consumer_phone_verified","consumer_identity_revision","consumer_last_operation_id","consumer_last_operation_action","consumer_last_operation_at"))
            profile.addOrReplaceAttribute(new UPAttribute(name,new UPAttributePermissions(Set.of("admin"),Set.of("admin"))));
        assertTrue(ConsumerIdentity.protectedProfile(profile));
        profile.getAttribute("consumer_phone_verified").getPermissions().setEdit(Set.of("admin","user"));
        assertFalse(ConsumerIdentity.protectedProfile(profile));
    }
    @Test void refusesWechatIdentityAlreadyLinkedToAnotherPhoneAccount(){
        UserProvider users=mock(UserProvider.class);RealmModel realm=mock(RealmModel.class);
        UserModel phone=mock(UserModel.class);UserModel other=mock(UserModel.class);
        when(phone.getId()).thenReturn("phone-a");when(other.getId()).thenReturn("phone-b");
        when(users.getUserByFederatedIdentity(eq(realm),any())).thenReturn(other);
        assertThrows(ConsumerIdentity.LinkConflict.class,()->ConsumerIdentity.linkWechat(users,realm,phone,"wx-app","openid-a"));
        verify(users,never()).addFederatedIdentity(any(),any(),any());
    }
    @Test void linksOnlyExactAppIdOpenIdAndNeverUnionId(){
        UserProvider users=mock(UserProvider.class);RealmModel realm=mock(RealmModel.class);UserModel phone=mock(UserModel.class);
        ConsumerIdentity.linkWechat(users,realm,phone,"wx-approved-app","openid-a");
        var captor=org.mockito.ArgumentCaptor.forClass(FederatedIdentityModel.class);
        verify(users).addFederatedIdentity(eq(realm),eq(phone),captor.capture());
        assertEquals("wechat-native:wx-approved-app",captor.getValue().getIdentityProvider());
        assertEquals("openid-a",captor.getValue().getUserId());
    }
    @Test void rejectsMissingOrUnverifiedStoredPhoneForWechatLogin(){
        UserModel user=mock(UserModel.class);
        assertThrows(IllegalStateException.class,()->ConsumerIdentity.verifiedPhone(user));
        when(user.getFirstAttribute("consumer_phone_number")).thenReturn("+8613800138000");
        when(user.getFirstAttribute("consumer_phone_verified")).thenReturn("false");
        assertThrows(IllegalStateException.class,()->ConsumerIdentity.verifiedPhone(user));
        when(user.getFirstAttribute("consumer_phone_verified")).thenReturn("true");
        assertEquals("+8613800138000",ConsumerIdentity.verifiedPhone(user));
    }
    @Test void wechatExchangePinsNativeAppAndRejectsErrorsOrMissingOpenId() throws Exception {
        List<java.net.URI> urls=new ArrayList<>();
        WechatNative client=new WechatNative("wx-app","secret",uri->{urls.add(uri);return new AliyunSms.Response(200,"{\"access_token\":\"mock-token\",\"expires_in\":7200,\"refresh_token\":\"mock-refresh\",\"openid\":\"native-openid\",\"scope\":\"snsapi_userinfo\",\"unionid\":\"ignored\"}");});
        assertEquals("native-openid",client.exchange("native-code"));
        assertEquals("api.weixin.qq.com",urls.get(0).getHost());
        assertTrue(urls.get(0).getQuery().contains("appid=wx-app"));
        assertThrows(java.io.IOException.class,()->new WechatNative("wx-app","secret",uri->new AliyunSms.Response(200,"{\"errcode\":40029,\"errmsg\":\"invalid code\"}")).exchange("bad-code"));
        assertThrows(java.io.IOException.class,()->new WechatNative("wx-app","secret",uri->new AliyunSms.Response(200,"{\"access_token\":\"token\"}")).exchange("bad-code"));
    }
}
