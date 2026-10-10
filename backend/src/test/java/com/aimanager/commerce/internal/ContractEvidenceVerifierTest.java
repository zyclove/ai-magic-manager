package com.aimanager.commerce.internal;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.aimanager.shared.DomainException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.interfaces.RSAPrivateKey;
import java.security.interfaces.RSAPublicKey;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;

class ContractEvidenceVerifierTest {
  private static final Instant NOW = Instant.parse("2026-10-11T08:00:00Z");
  private static final String ISSUER = "https://contracts.example.test";
  private static final String AUDIENCE = "ai-manager-contracts";
  private static final String TENANT = "f4c107d6-d1d8-423a-9acc-e0473d186e01";
  private static final String OFFER = "1f535a7b-691d-49c5-84bf-2d279fbd35bb";
  private RSAPrivateKey privateKey;
  private ContractEvidenceVerifier verifier;

  @BeforeEach
  void keys() throws Exception {
    KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
    generator.initialize(2048);
    KeyPair pair = generator.generateKeyPair();
    privateKey = (RSAPrivateKey) pair.getPrivate();
    verifier =
        new JwtContractEvidenceVerifier(
            NimbusJwtDecoder.withPublicKey((RSAPublicKey) pair.getPublic()).build(),
            ISSUER,
            AUDIENCE,
            Clock.fixed(NOW, ZoneOffset.UTC));
  }

  @Test
  void validShortLivedSignedContractNormalizesFactsWithoutGrantingEntitlement() throws Exception {
    ContractEvidence evidence = verifier.verify(signed(Map.of()));
    assertEquals(TENANT, evidence.tenantId());
    assertEquals(OFFER, evidence.offerId());
    assertEquals(3, evidence.offerRevision());
    assertEquals("CN-PO-2026-001", evidence.contractReference());
    assertEquals(1, evidence.sourceRevision());
    assertEquals(100, evidence.deviceCapacity());
    assertTrue(evidence.features().contains(CommercialFact.Feature.ORG_BULK));
    assertEquals(64, evidence.evidenceHash().length());
  }

  @Test
  void rejectsTamperingWrongTrustScopeAndExpiredOrStaleAssertions() throws Exception {
    String valid = signed(Map.of());
    String[] parts = valid.split("\\.");
    String tampered =
        parts[0]
            + "."
            + parts[1].substring(0, parts[1].length() - 1)
            + (parts[1].endsWith("A") ? "B" : "A")
            + "."
            + parts[2];
    reject(tampered);
    reject(signed(Map.of("iss", "https://wrong.example.test")));
    reject(signed(Map.of("aud", "other-audience")));
    reject(signed(Map.of("exp", Date.from(NOW.minusSeconds(1)))));
    reject(signed(Map.of("iat", Date.from(NOW.minusSeconds(601)))));
    reject(signed(Map.of("iat", Date.from(NOW.plusSeconds(31)))));
  }

  @Test
  void rejectsMissingOrContradictoryContractAssertions() throws Exception {
    reject(signed(Map.of("region", "US")));
    reject(signed(Map.of("channel", "APP_STORE")));
    reject(signed(Map.of("source_revision", 0)));
    reject(signed(Map.of("offer_revision", 0)));
    reject(signed(Map.of("kid", "")));
    reject(signed(Map.of("capacity_kind", "BASE", "device_capacity", 0)));
    reject(signed(Map.of("features", List.of("ORG_BULK", "ORG_BULK"))));
    reject(signed(Map.of("buyer_signature_ref", "sig:same", "seller_signature_ref", "sig:same")));
  }

  @Test
  void disabledConnectorFailsClosedWithoutReadingEvidence() {
    var unavailable =
        new ContractEvidenceConfiguration()
            .contractEvidenceVerifier(false, "", "", "", Clock.fixed(NOW, ZoneOffset.UTC));
    DomainException error =
        assertThrows(DomainException.class, () -> unavailable.verify("anything"));
    assertEquals("CONTRACT_PROVIDER_UNAVAILABLE", error.errorCode());
    assertThrows(
        IllegalStateException.class,
        () ->
            new ContractEvidenceConfiguration()
                .contractEvidenceVerifier(
                    true,
                    "http://insecure.example.test",
                    AUDIENCE,
                    "https://keys.example.test/jwks",
                    Clock.fixed(NOW, ZoneOffset.UTC)));
  }

  private void reject(String compactJws) {
    DomainException error = assertThrows(DomainException.class, () -> verifier.verify(compactJws));
    assertEquals("INVALID_CONTRACT_EVIDENCE", error.errorCode());
  }

  private String signed(Map<String, Object> overrides) throws Exception {
    JWTClaimsSet.Builder claims =
        new JWTClaimsSet.Builder()
            .issuer(ISSUER)
            .audience(AUDIENCE)
            .jwtID(UUID.randomUUID().toString())
            .issueTime(Date.from(NOW.minusSeconds(30)))
            .expirationTime(Date.from(NOW.plusSeconds(300)))
            .claim("tenant_id", TENANT)
            .claim("offer_id", OFFER)
            .claim("offer_revision", 3)
            .claim("contract_ref", "CN-PO-2026-001")
            .claim("buyer_ref", "school-001")
            .claim("source_revision", 1)
            .claim("region", "CN")
            .claim("channel", "CONTRACT")
            .claim("capacity_kind", "BASE")
            .claim("device_capacity", 100)
            .claim("features", List.of("ORG_BULK", "ADVANCED_SCHEDULES"))
            .claim("active_from", NOW.toEpochMilli())
            .claim("expires_at", NOW.plusSeconds(86400L * 365).toEpochMilli())
            .claim("state", "ACTIVE")
            .claim("executed_at", NOW.minusSeconds(60).toEpochMilli())
            .claim("buyer_signature_ref", "sig:buyer-001")
            .claim("seller_signature_ref", "sig:seller-001");
    for (var override : overrides.entrySet()) {
      switch (override.getKey()) {
        case "iss" -> claims.issuer((String) override.getValue());
        case "aud" -> claims.audience((String) override.getValue());
        case "exp" -> claims.expirationTime((Date) override.getValue());
        case "iat" -> claims.issueTime((Date) override.getValue());
        case "kid" -> {
          /* Header override is applied below. */
        }
        default -> claims.claim(override.getKey(), override.getValue());
      }
    }
    JWSHeader.Builder header = new JWSHeader.Builder(JWSAlgorithm.RS256);
    if (!overrides.containsKey("kid")) header.keyID("contract-key-1");
    SignedJWT signed = new SignedJWT(header.build(), claims.build());
    signed.sign(new RSASSASigner(privateKey));
    return signed.serialize();
  }
}
