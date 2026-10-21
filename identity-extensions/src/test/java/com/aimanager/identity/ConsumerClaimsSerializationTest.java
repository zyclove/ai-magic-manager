package com.aimanager.identity;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.representations.AccessToken;
import org.keycloak.representations.IDToken;
import org.keycloak.util.JsonSerialization;

class ConsumerClaimsSerializationTest {
  private static final String PHONE = "+8613800138000";
  private static final long AUTH_TIME = 1700000000L;
  private static final ObjectMapper STRICT_JSON = new ObjectMapper()
      .enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION);

  @Test void accessTokenStandardClaimsReplaceEarlierValuesWithoutDuplicateJsonFields() throws Exception {
    var fixture = new Fixture();
    var token = fixture.accessToken();
    seedEarlierClaims(token);
    ConsumerClaimsMapper.apply(token, fixture.active);
    String serialized = JsonSerialization.writeValueAsString(token);
    JsonNode json = assertDoesNotThrow(() -> STRICT_JSON.readTree(serialized));
    assertTrustedJson(json);
    var read = JsonSerialization.readValue(serialized, AccessToken.class);
    assertEquals(PHONE, read.getPhoneNumber());
    assertEquals(Boolean.TRUE, read.getPhoneNumberVerified());
    assertEquals(AUTH_TIME, read.getAuth_time());
    assertEquals(List.of("sms"), read.getOtherClaims().get("amr"));
    assertEquals("retained", read.getOtherClaims().get("unrelated"));
    assertNoStandardOtherClaims(token);
    assertNoStandardOtherClaims(read);
  }

  @Test void idTokenStandardClaimsReplaceEarlierValuesWithoutDuplicateJsonFields() throws Exception {
    var fixture = new Fixture();
    var token = new IDToken();
    seedEarlierClaims(token);
    ConsumerClaimsMapper.apply(token, fixture.active);
    String serialized = JsonSerialization.writeValueAsString(token);
    assertTrustedJson(assertDoesNotThrow(() -> STRICT_JSON.readTree(serialized)));
    var read = JsonSerialization.readValue(serialized, IDToken.class);
    assertEquals(PHONE, read.getPhoneNumber());
    assertEquals(Boolean.TRUE, read.getPhoneNumberVerified());
    assertEquals(AUTH_TIME, read.getAuth_time());
    assertNoStandardOtherClaims(token);
  }

  @Test void accountEvidenceAcceptsTheActualKeycloakSerializedToken() throws Exception {
    var fixture = new Fixture();
    var token = fixture.accessToken();
    ConsumerClaimsMapper.apply(token, fixture.active);
    var read = JsonSerialization.readValue(JsonSerialization.writeValueAsBytes(token), AccessToken.class);
    var status = assertDoesNotThrow(() -> fixture.resource.evidence(fixture.user, fixture.active, read));
    assertTrue(status.sessionCurrent());
    assertTrue(status.phoneVerified());
    assertEquals(1, status.identityRevision());
  }

  @Test void otherClaimsCannotSubstituteForMissingStandardPhoneFields() {
    var fixture = new Fixture();
    var token = fixture.accessToken();
    token.setOtherClaims("phone_number", PHONE);
    token.setOtherClaims("phone_number_verified", true);
    assertThrows(ConsumerAccountResource.Stale.class,
        () -> fixture.resource.evidence(fixture.user, fixture.active, token));
  }

  @Test void otherClaimsCannotOverrideConflictingStandardPhoneFields() {
    var fixture = new Fixture();
    var token = fixture.accessToken();
    token.setPhoneNumber("+8613900139000");
    token.setPhoneNumberVerified(false);
    token.setOtherClaims("phone_number", PHONE);
    token.setOtherClaims("phone_number_verified", true);
    assertThrows(ConsumerAccountResource.Stale.class,
        () -> fixture.resource.evidence(fixture.user, fixture.active, token));
    token.setPhoneNumber(PHONE);
    assertThrows(ConsumerAccountResource.Stale.class,
        () -> fixture.resource.evidence(fixture.user, fixture.active, token));
  }

  private static void seedEarlierClaims(IDToken token) {
    token.setPhoneNumber("+8613900139000");
    token.setPhoneNumberVerified(false);
    token.setAuth_time(1600000000L);
    token.setOtherClaims("phone_number", "+8613900139000");
    token.setOtherClaims("phone_number_verified", false);
    token.setOtherClaims("auth_time", 1600000000L);
    token.setOtherClaims("unrelated", "retained");
  }

  private static void assertTrustedJson(JsonNode json) {
    assertEquals(PHONE, json.path("phone_number").textValue());
    assertTrue(json.path("phone_number_verified").isBoolean());
    assertTrue(json.path("phone_number_verified").booleanValue());
    assertTrue(json.path("auth_time").isIntegralNumber());
    assertEquals(AUTH_TIME, json.path("auth_time").longValue());
    assertEquals(1, json.path("consumer_identity_revision").intValue());
  }

  private static void assertNoStandardOtherClaims(IDToken token) {
    for (String name : List.of("phone_number", "phone_number_verified", "auth_time")) {
      assertFalse(token.getOtherClaims().containsKey(name), name);
    }
  }

  private static final class Fixture {
    final ConsumerAccountFlowTest.Fixture storage = new ConsumerAccountFlowTest.Fixture();
    final UserModel user = storage.user("serialized-actor", PHONE, 1);
    final UserSessionModel active = ConsumerAccountStatusTest.active(user, PHONE, "1");
    final ConsumerAccountResource resource = new ConsumerAccountResource(storage.session, storage.config);

    Fixture() {
      when(active.getNote("consumer_amr")).thenReturn("sms");
      when(active.getNote("consumer_auth_time")).thenReturn(Long.toString(AUTH_TIME));
    }

    AccessToken accessToken() {
      var token = new AccessToken();
      token.subject(user.getId());
      token.issuedFor("ai-manager-parent");
      token.setSessionId(active.getId());
      token.setOtherClaims("consumer_identity_revision", 1);
      return token;
    }
  }
}
