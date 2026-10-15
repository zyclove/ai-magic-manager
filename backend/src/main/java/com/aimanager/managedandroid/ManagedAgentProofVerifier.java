package com.aimanager.managedandroid;

import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.json.JsonMapper;
import com.nimbusds.jose.JOSEObjectType;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.crypto.ECDSAVerifier;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.ECKey;
import com.nimbusds.jose.jwk.JWK;
import com.nimbusds.jose.jwk.KeyOperation;
import com.nimbusds.jose.jwk.KeyUse;
import com.nimbusds.jwt.SignedJWT;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Clock;
import java.time.Instant;
import java.util.Base64;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.springframework.http.HttpStatus;

/**
 * 使用 Nimbus 验证提供方反馈中的注册密钥证明，不查询数据库、不授予系统能力。 调用方必须从受信提供方获取 evidence，从已锁定的当前注册/挑战记录构造 expected，
 * 并在同一绑定事务内检查租户、注册和企业有效性及原子消费挑战。验签本身不防重复消费。
 */
public final class ManagedAgentProofVerifier {
  public static final String AUDIENCE = "ai-manager:managed-agent-binding";
  private static final long MAX_LIFETIME_MILLIS = 600_000L;
  private static final long CLOCK_SKEW_MILLIS = 30_000L;
  private static final int MAX_PROOF_CHARACTERS = 1000;
  private static final Set<String> CLAIMS = Set.of("sub", "nonce", "aud", "iat", "exp", "jti");
  private static final JsonMapper JSON =
      JsonMapper.builder()
          .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION)
          .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
          .build();
  private final Clock clock;

  public ManagedAgentProofVerifier(Clock clock) {
    this.clock = java.util.Objects.requireNonNull(clock);
  }

  /** 无效/缺失证据统一拒绝，异常不携带令牌、响应体或底层密码库异常。 */
  public Verified verify(Expected expected, ManagedAgentEvidence evidence) {
    try {
      validateExpected(expected);
      if (evidence == null
          || !expected.deviceName().equals(evidence.deviceName())
          || !"DEVICE_OWNER".equals(evidence.managementMode())
          || !expected.packageName().equals(evidence.packageName())
          || !"INSTALLED".equals(evidence.applicationState())
          || !ManagedAgentEvidence.FEEDBACK_KEY.equals(evidence.feedbackKey())
          || !"INFO".equals(evidence.severity())
          || evidence.signingCertificateSha256().isEmpty()
          || evidence.signingCertificateSha256().size() > 8
          || !expected.trustedSigningCertificates().containsAll(evidence.signingCertificateSha256())
          || new HashSet<>(evidence.signingCertificateSha256()).size()
              != evidence.signingCertificateSha256().size()) throw invalid();

      String serialized = evidence.proof();
      if (serialized == null || serialized.length() > MAX_PROOF_CHARACTERS) throw invalid();
      String[] parts = serialized.split("\\.", -1);
      if (parts.length != 3) throw invalid();
      byte[] signature = Base64.getUrlDecoder().decode(parts[2]);
      if (signature.length != 64
          || !Base64.getUrlEncoder().withoutPadding().encodeToString(signature).equals(parts[2]))
        throw invalid();
      JsonNode headerJson = strictJson(parts[0]);
      JsonNode claimsJson = strictJson(parts[1]);
      if (headerJson.size() != 2
          || !"ES256".equals(headerJson.path("alg").textValue())
          || !"JWT".equals(headerJson.path("typ").textValue())
          || claimsJson.size() != CLAIMS.size()) throw invalid();
      var names = claimsJson.fieldNames();
      while (names.hasNext()) {
        if (!CLAIMS.contains(names.next())) throw invalid();
      }
      if (!claimsJson.path("iat").isIntegralNumber()
          || !claimsJson.path("exp").isIntegralNumber()
          || !claimsJson.path("iat").canConvertToLong()
          || !claimsJson.path("exp").canConvertToLong()) {
        throw invalid();
      }
      var parsedKey = JWK.parse(expected.publicKeyJwk());
      if (!(parsedKey instanceof ECKey key)
          || key.isPrivate()
          || !Curve.P_256.equals(key.getCurve())
          || (key.getAlgorithm() != null && !JWSAlgorithm.ES256.equals(key.getAlgorithm()))
          || (key.getKeyUse() != null && !KeyUse.SIGNATURE.equals(key.getKeyUse()))
          || (key.getKeyOperations() != null
              && !Set.of(KeyOperation.VERIFY).equals(key.getKeyOperations()))) {
        throw invalid();
      }
      var proof = SignedJWT.parse(serialized);
      if (!JWSAlgorithm.ES256.equals(proof.getHeader().getAlgorithm())
          || !JOSEObjectType.JWT.equals(proof.getHeader().getType())
          || !proof.verify(new ECDSAVerifier(key))) throw invalid();
      var claims = proof.getJWTClaimsSet();
      if (!expected.challengeId().equals(claims.getSubject())
          || !expected.nonce().equals(claims.getStringClaim("nonce"))
          || !List.of(AUDIENCE).equals(claims.getAudience())
          || !uuid(claims.getJWTID())) throw invalid();

      long issuedAt = Math.multiplyExact(claimsJson.get("iat").longValue(), 1000L);
      long expiresAt = Math.multiplyExact(claimsJson.get("exp").longValue(), 1000L);
      long now = clock.millis();
      long feedbackAt = Instant.parse(evidence.feedbackUpdatedAt()).toEpochMilli();
      long reportedAt = Instant.parse(evidence.deviceReportedAt()).toEpochMilli();
      if (now < expected.createdAt() - CLOCK_SKEW_MILLIS
          || now >= expected.expiresAt()
          || issuedAt < expected.createdAt() - CLOCK_SKEW_MILLIS
          || issuedAt > now + CLOCK_SKEW_MILLIS
          || expiresAt <= now
          || expiresAt <= issuedAt
          || expiresAt > expected.expiresAt()
          || expiresAt - issuedAt > MAX_LIFETIME_MILLIS
          || feedbackAt < expected.createdAt()
          || feedbackAt > now + CLOCK_SKEW_MILLIS
          || feedbackAt < issuedAt - CLOCK_SKEW_MILLIS
          || feedbackAt >= expiresAt
          || reportedAt < expected.createdAt()
          || reportedAt < feedbackAt - CLOCK_SKEW_MILLIS
          || reportedAt > now + CLOCK_SKEW_MILLIS) throw invalid();
      String hash =
          HexFormat.of()
              .formatHex(
                  MessageDigest.getInstance("SHA-256")
                      .digest(serialized.getBytes(StandardCharsets.US_ASCII)));
      return new Verified(
          hash, claims.getJWTID(), key.computeThumbprint().toString(), feedbackAt, reportedAt);
    } catch (Exception failure) {
      // Fail closed even for malformed dates, keys and provider values; no raw cause escapes.
      throw invalid();
    }
  }

  private static JsonNode strictJson(String encoded) throws java.io.IOException {
    if (encoded.isEmpty() || !encoded.matches("[A-Za-z0-9_-]+")) throw invalid();
    byte[] bytes = Base64.getUrlDecoder().decode(encoded);
    if (!Base64.getUrlEncoder().withoutPadding().encodeToString(bytes).equals(encoded))
      throw invalid();
    var result = JSON.readTree(bytes);
    if (result == null || !result.isObject()) throw invalid();
    return result;
  }

  private static void validateExpected(Expected expected) {
    if (expected == null
        || !uuid(expected.challengeId())
        || expected.nonce() == null
        || !expected.nonce().matches("[A-Za-z0-9_-]{43}")
        || !Base64.getUrlEncoder()
            .withoutPadding()
            .encodeToString(Base64.getUrlDecoder().decode(expected.nonce()))
            .equals(expected.nonce())
        || expected.createdAt() < 0
        || expected.expiresAt() <= expected.createdAt()
        || expected.expiresAt() - expected.createdAt() > MAX_LIFETIME_MILLIS
        || expected.deviceName() == null
        || !expected
            .deviceName()
            .matches("enterprises/[A-Za-z0-9_-]{1,128}/devices/[A-Za-z0-9_-]{1,128}")
        || expected.packageName() == null
        || expected.packageName().length() > 255
        || !expected.packageName().matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+")
        || expected.publicKeyJwk() == null
        || expected.publicKeyJwk().length() > 4096
        || expected.trustedSigningCertificates().isEmpty()
        || expected.trustedSigningCertificates().size() > 8
        || expected.trustedSigningCertificates().stream()
            .anyMatch(value -> !value.matches("[0-9a-f]{64}"))) {
      throw invalid();
    }
  }

  private static boolean uuid(String value) {
    if (value == null) return false;
    var parsed = UUID.fromString(value);
    return parsed.version() == 4 && parsed.variant() == 2 && parsed.toString().equals(value);
  }

  private static DomainException invalid() {
    return new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, "MANAGED_AGENT_PROOF_INVALID");
  }

  /** 仅从服务端已授权的注册/挑战记录构造，不能由请求体直接绑定。 */
  public record Expected(
      String challengeId,
      String nonce,
      long createdAt,
      long expiresAt,
      String deviceName,
      String packageName,
      String publicKeyJwk,
      Set<String> trustedSigningCertificates) {
    public Expected {
      trustedSigningCertificates =
          trustedSigningCertificates == null ? Set.of() : Set.copyOf(trustedSigningCertificates);
    }

    @Override
    public String toString() {
      return "ManagedAgentProofExpected[REDACTED]";
    }
  }

  /** 只保存最小证据摘要；禁止将验签结果直接解释为设备具备系统策略能力。 */
  public record Verified(
      String proofSha256, String proofId, String keyThumbprint, long feedbackAt, long reportedAt) {
    @Override
    public String toString() {
      return "ManagedAgentProofVerified[REDACTED]";
    }
  }
}
