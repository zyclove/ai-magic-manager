package com.aimanager.commerce.internal;

import com.aimanager.commerce.internal.CommercialFact.CapacityKind;
import com.aimanager.commerce.internal.CommercialFact.Feature;
import com.aimanager.commerce.internal.CommercialFact.State;
import com.aimanager.shared.DomainException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.time.Instant;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;
import org.springframework.http.HttpStatus;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtException;

/**
 * Validates short-lived, issuer-signed institutional contract assertions. Nimbus/Spring verifies
 * the JWS signature and accepted algorithm; this layer pins issuer, audience, freshness and exact
 * claims.
 */
final class JwtContractEvidenceVerifier implements ContractEvidenceVerifier {
  private static final Pattern REFERENCE = Pattern.compile("[A-Za-z0-9._:/-]{1,200}");
  private static final long MAX_ASSERTION_AGE_SECONDS = 600;
  private final JwtDecoder decoder;
  private final String issuer;
  private final String audience;
  private final Clock clock;

  JwtContractEvidenceVerifier(JwtDecoder decoder, String issuer, String audience, Clock clock) {
    if (decoder == null
        || issuer == null
        || issuer.isBlank()
        || audience == null
        || audience.isBlank()
        || clock == null) {
      throw new IllegalArgumentException("Contract evidence trust configuration is incomplete");
    }
    this.decoder = decoder;
    this.issuer = issuer;
    this.audience = audience;
    this.clock = clock;
  }

  @Override
  public ContractEvidence verify(String compactJws) {
    if (compactJws == null
        || compactJws.length() > 16_384
        || !compactJws.matches("[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+")) {
      throw invalid();
    }
    final Jwt jwt;
    try {
      jwt = decoder.decode(compactJws);
    } catch (JwtException | IllegalArgumentException failure) {
      throw invalid();
    }
    Instant now = clock.instant();
    if (!(jwt.getHeaders().get("kid") instanceof String keyId) || keyId.isBlank()) {
      throw invalid();
    }
    Instant issued = jwt.getIssuedAt();
    Instant expiry = jwt.getExpiresAt();
    Instant notBefore;
    try {
      notBefore = jwt.getClaimAsInstant("nbf");
    } catch (RuntimeException malformed) {
      throw invalid();
    }
    if (!issuer.equals(jwt.getClaimAsString("iss"))
        || !jwt.getAudience().contains(audience)
        || issued == null
        || issued.isAfter(now.plusSeconds(30))
        || issued.isBefore(now.minusSeconds(MAX_ASSERTION_AGE_SECONDS))
        || expiry == null
        || !expiry.isAfter(now)
        || expiry.isAfter(now.plusSeconds(MAX_ASSERTION_AGE_SECONDS))
        || (notBefore != null && notBefore.isAfter(now))) {
      throw invalid();
    }
    Map<String, Object> claims = jwt.getClaims();
    String eventId = uuid(claims.get("jti"));
    String tenantId = uuid(claims.get("tenant_id"));
    String offerId = uuid(claims.get("offer_id"));
    long offerRevision = number(claims.get("offer_revision"), 1, Long.MAX_VALUE);
    String contractReference = reference(claims.get("contract_ref"));
    String buyerReference = reference(claims.get("buyer_ref"));
    String buyerSignature = reference(claims.get("buyer_signature_ref"));
    String sellerSignature = reference(claims.get("seller_signature_ref"));
    if (buyerSignature.equals(sellerSignature)) throw invalid();
    long revision = number(claims.get("source_revision"), 1, Long.MAX_VALUE);
    int capacity = (int) number(claims.get("device_capacity"), 0, 1_000_000);
    long activeFrom = number(claims.get("active_from"), 0, Long.MAX_VALUE);
    long expiresAt = number(claims.get("expires_at"), 1, Long.MAX_VALUE);
    long executedAt = number(claims.get("executed_at"), 1, now.toEpochMilli());
    if (!"CN".equals(claims.get("region"))
        || !"CONTRACT".equals(claims.get("channel"))
        || expiresAt <= activeFrom
        || expiresAt - activeFrom > 86400000L * 3650) {
      throw invalid();
    }
    CapacityKind capacityKind = enumeration(CapacityKind.class, claims.get("capacity_kind"));
    State state = enumeration(State.class, claims.get("state"));
    if (capacityKind == CapacityKind.BASE && capacity == 0) throw invalid();
    Set<Feature> features = features(claims.get("features"));
    return new ContractEvidence(
        eventId,
        tenantId,
        offerId,
        offerRevision,
        contractReference,
        revision,
        buyerReference,
        capacityKind,
        capacity,
        features,
        activeFrom,
        expiresAt,
        state,
        executedAt,
        buyerSignature,
        sellerSignature,
        sha256(compactJws));
  }

  private static String uuid(Object value) {
    if (!(value instanceof String text)) throw invalid();
    try {
      if (!UUID.fromString(text).toString().equals(text)) throw invalid();
      return text;
    } catch (IllegalArgumentException failure) {
      throw invalid();
    }
  }

  private static String reference(Object value) {
    if (!(value instanceof String text) || !REFERENCE.matcher(text).matches()) throw invalid();
    return text;
  }

  private static long number(Object value, long minimum, long maximum) {
    if (!(value instanceof Integer || value instanceof Long)) throw invalid();
    long parsed = ((Number) value).longValue();
    if (parsed < minimum || parsed > maximum) throw invalid();
    return parsed;
  }

  private static <T extends Enum<T>> T enumeration(Class<T> type, Object value) {
    if (!(value instanceof String text)) throw invalid();
    try {
      return Enum.valueOf(type, text);
    } catch (IllegalArgumentException failure) {
      throw invalid();
    }
  }

  private static Set<Feature> features(Object value) {
    if (!(value instanceof List<?> list) || list.size() > Feature.values().length) throw invalid();
    Set<Feature> result = new HashSet<>();
    for (Object raw : list) {
      if (!result.add(enumeration(Feature.class, raw))) throw invalid();
    }
    return Set.copyOf(result);
  }

  private static String sha256(String text) {
    try {
      return HexFormat.of()
          .formatHex(
              MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)));
    } catch (NoSuchAlgorithmException unavailable) {
      throw new IllegalStateException("SHA-256 unavailable", unavailable);
    }
  }

  private static DomainException invalid() {
    return new DomainException(HttpStatus.BAD_REQUEST, "INVALID_CONTRACT_EVIDENCE");
  }
}
