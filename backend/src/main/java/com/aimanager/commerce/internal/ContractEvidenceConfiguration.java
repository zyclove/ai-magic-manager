package com.aimanager.commerce.internal;

import com.aimanager.shared.DomainException;
import java.net.URI;
import java.time.Clock;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpStatus;
import org.springframework.security.oauth2.jose.jws.SignatureAlgorithm;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;

/**
 * External contract assertions are disabled until an independently governed issuer and HTTPS JWKS
 * are configured. A test can construct the verifier with a local public key without enabling it in
 * any deployed environment.
 */
@Configuration(proxyBeanMethods = false)
class ContractEvidenceConfiguration {
  @Bean
  @ConditionalOnMissingBean(ContractEvidenceVerifier.class)
  ContractEvidenceVerifier contractEvidenceVerifier(
      @Value("${manager.contract.evidence-enabled:false}") boolean enabled,
      @Value("${manager.contract.issuer:}") String issuer,
      @Value("${manager.contract.audience:}") String audience,
      @Value("${manager.contract.jwk-set-uri:}") String jwkSetUri,
      Clock clock) {
    if (!enabled) {
      return token -> {
        throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "CONTRACT_PROVIDER_UNAVAILABLE");
      };
    }
    if (!secureHttps(issuer) || !secureHttps(jwkSetUri) || audience.isBlank()) {
      throw new IllegalStateException("Contract issuer, audience and HTTPS JWKS are required");
    }
    var decoder =
        NimbusJwtDecoder.withJwkSetUri(jwkSetUri).jwsAlgorithm(SignatureAlgorithm.RS256).build();
    return new JwtContractEvidenceVerifier(decoder, issuer, audience, clock);
  }

  private static boolean secureHttps(String value) {
    try {
      URI uri = URI.create(value);
      return "https".equals(uri.getScheme())
          && uri.getHost() != null
          && uri.getRawUserInfo() == null
          && uri.getFragment() == null;
    } catch (IllegalArgumentException malformed) {
      return false;
    }
  }
}
