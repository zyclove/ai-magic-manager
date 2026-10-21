package com.aimanager.identity;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.keycloak.models.*;
import org.keycloak.representations.AccessToken;

class ConsumerAccountStatusTest {
  @Test void cdiCanConstructAnUnconfiguredProviderWithoutInjectingSecrets()throws Exception{
    var resource=ConsumerAccountResource.class.getConstructor().newInstance();
    assertThrows(ConsumerAccountResource.Unavailable.class,()->resource.evidence(null,null,null));
  }
  @Test void malformedReceiptFailsClosedWithoutAnInternalError(){
    var f=new ConsumerAccountFlowTest.Fixture();var user=f.user(ConsumerAccountFlowTest.ACTOR,ConsumerAccountFlowTest.OLD,2);user.setSingleAttribute("consumer_last_operation_id",ConsumerAccountFlowTest.OPERATION);
    assertThrows(ConsumerAccountResource.Stale.class,()->new ConsumerAccountResource(f.session,f.config).evidence(user,active(user,ConsumerAccountFlowTest.OLD,"2"),token(user,ConsumerAccountFlowTest.OLD,2)));
  }
  @Test void currentStatusExposesOnlyMaskedPhoneAndRealBindingCapabilities(){
    var f=new ConsumerAccountFlowTest.Fixture();var user=f.user(ConsumerAccountFlowTest.ACTOR,ConsumerAccountFlowTest.OLD,1);f.links.put("wechat-a",user);
    var session=active(user,"+8613800138000","1");var token=token(user,"+8613800138000",1);
    var status=new ConsumerAccountResource(f.session,f.config).evidence(user,session,token);
    assertEquals(ConsumerAccountFlowTest.ACTOR,status.subject());assertEquals("138****8000",status.phoneMasked());assertTrue(status.phoneVerified());assertTrue(status.wechatBound());assertTrue(status.canUnbindWechat());assertFalse(status.canBindWechat());assertEquals(1,status.identityRevision());assertNull(status.lastOperationId());
  }
  @Test void oldPhoneOldRevisionAndOtherClientsAreRejected(){
    var f=new ConsumerAccountFlowTest.Fixture();var user=f.user(ConsumerAccountFlowTest.ACTOR,ConsumerAccountFlowTest.NEW,2);var resource=new ConsumerAccountResource(f.session,f.config);
    assertThrows(ConsumerAccountResource.Stale.class,()->resource.evidence(user,active(user,ConsumerAccountFlowTest.OLD,"1"),token(user,ConsumerAccountFlowTest.OLD,1)));
    var current=token(user,ConsumerAccountFlowTest.NEW,2);current.issuedFor("ai-manager-guardian");
    assertThrows(ConsumerAccountResource.Stale.class,()->resource.evidence(user,active(user,ConsumerAccountFlowTest.NEW,"2"),current));
  }
  @Test void legacyTokenWorksOnlyWhileCurrentUserStillHasRevisionOne(){
    var f=new ConsumerAccountFlowTest.Fixture();var user=f.user(ConsumerAccountFlowTest.ACTOR,ConsumerAccountFlowTest.OLD,1);var resource=new ConsumerAccountResource(f.session,f.config);var token=token(user,ConsumerAccountFlowTest.OLD,null);
    assertEquals(1,resource.evidence(user,active(user,ConsumerAccountFlowTest.OLD,null),token).identityRevision());
    user.setSingleAttribute("consumer_identity_revision","2");
    assertThrows(ConsumerAccountResource.Stale.class,()->resource.evidence(user,active(user,ConsumerAccountFlowTest.OLD,null),token));
  }
  @Test void disabledUserAndDisabledProviderCannotReturnCurrentEvidence(){
    var f=new ConsumerAccountFlowTest.Fixture();var user=f.user(ConsumerAccountFlowTest.ACTOR,ConsumerAccountFlowTest.OLD,1);when(user.isEnabled()).thenReturn(false);
    assertThrows(ConsumerAccountResource.Stale.class,()->new ConsumerAccountResource(f.session,f.config).evidence(user,active(user,ConsumerAccountFlowTest.OLD,"1"),token(user,ConsumerAccountFlowTest.OLD,1)));
    f.config.remove("CONSUMER_ACCOUNT_SECURITY_ENABLED");
    assertThrows(ConsumerAccountResource.Unavailable.class,()->new ConsumerAccountResource(f.session,f.config).evidence(user,active(user,ConsumerAccountFlowTest.OLD,"1"),token(user,ConsumerAccountFlowTest.OLD,1)));
  }
  static UserSessionModel active(UserModel user,String phone,String revision){var session=mock(UserSessionModel.class);when(session.getUser()).thenReturn(user);when(session.getId()).thenReturn("active-session");when(session.getNote("consumer_phone_number")).thenReturn(phone);when(session.getNote("consumer_phone_verified")).thenReturn("true");when(session.getNote("consumer_identity_revision")).thenReturn(revision);return session;}
  static AccessToken token(UserModel user,String phone,Integer revision){var token=new AccessToken();token.subject(user.getId());token.issuedFor("ai-manager-parent");token.setSessionId("active-session");token.setPhoneNumber(phone);token.setPhoneNumberVerified(true);if(revision!=null)token.setOtherClaims("consumer_identity_revision",revision);return token;}
}
