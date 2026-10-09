package com.aimanager.identity;

import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtValidators;

/** One validation contract for discovery-based production decoding and local signed-token regression. */
public final class IdentityTokenValidators {
    private IdentityTokenValidators() {}

    public static OAuth2TokenValidator<Jwt> forIssuerAndAudience(String issuer, String audience) {
        OAuth2TokenValidator<Jwt> identity = token -> {
            String subject = token.getSubject();
            var audiences = token.getAudience();
            return audiences != null && audiences.contains(audience) && token.getExpiresAt() != null
                && subject != null && !subject.isBlank() && subject.length() <= 255
                ? OAuth2TokenValidatorResult.success()
                : OAuth2TokenValidatorResult.failure(new OAuth2Error("invalid_token"));
        };
        return new DelegatingOAuth2TokenValidator<>(JwtValidators.createDefaultWithIssuer(issuer), identity);
    }
}
