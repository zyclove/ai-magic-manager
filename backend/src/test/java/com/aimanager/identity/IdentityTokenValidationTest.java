package com.aimanager.identity;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import java.time.Instant;
import java.util.Date;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.jwt.JwtException;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import static org.assertj.core.api.Assertions.*;

/** Real RSA signatures and the production validator; no external IdP or mocked JWT in these cases. */
class IdentityTokenValidationTest {
    private static final String ISSUER = "https://identity.example.test/realms/manager";
    private static final String AUDIENCE = "ai-manager-api";
    private static RSAKey key;
    private static NimbusJwtDecoder decoder;

    @BeforeAll static void configure() throws JOSEException {
        key = new RSAKeyGenerator(2048).generate();
        decoder = NimbusJwtDecoder.withPublicKey(key.toRSAPublicKey()).build();
        decoder.setJwtValidator(IdentityTokenValidators.forIssuerAndAudience(ISSUER, AUDIENCE));
    }

    private JWTClaimsSet.Builder claims() {
        return new JWTClaimsSet.Builder().issuer(ISSUER).audience(AUDIENCE).subject("exact-Subject")
            .issueTime(Date.from(Instant.now())).expirationTime(Date.from(Instant.now().plusSeconds(300)));
    }

    private String signed(JWTClaimsSet claims, RSAKey signer) throws JOSEException {
        var token = new SignedJWT(new JWSHeader(JWSAlgorithm.RS256), claims);
        token.sign(new RSASSASigner(signer));
        return token.serialize();
    }

    @Test void validSignatureAndClaimsAreAccepted() throws JOSEException {
        assertThat(decoder.decode(signed(claims().build(), key)).getSubject()).isEqualTo("exact-Subject");
    }

    @Test void invalidSignatureIsRejected() throws JOSEException {
        String token = signed(claims().build(), new RSAKeyGenerator(2048).generate());
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test void anotherIssuerIsRejected() throws JOSEException {
        String token = signed(claims().issuer("https://attacker.example.test").build(), key);
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test void wrongAudienceIsRejected() throws JOSEException {
        String token = signed(claims().audience("other-api").build(), key);
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test void missingAudienceIsRejectedAsInvalidToken() throws JOSEException {
        String token = signed(claims().audience((String) null).build(), key);
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test void expiredTokenIsRejected() throws JOSEException {
        String token = signed(claims().issueTime(Date.from(Instant.now().minusSeconds(600)))
            .expirationTime(Date.from(Instant.now().minusSeconds(120))).build(), key);
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test void missingSubjectIsRejected() throws JOSEException {
        String token = signed(claims().subject(null).build(), key);
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test void tokenWithoutExpirationIsRejected() throws JOSEException {
        String token = signed(claims().expirationTime(null).build(), key);
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test void notYetValidTokenIsRejected() throws JOSEException {
        String token = signed(claims().notBeforeTime(Date.from(Instant.now().plusSeconds(180))).build(), key);
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test void oversizedSubjectIsRejectedBeforeDatabaseLookup() throws JOSEException {
        String token = signed(claims().subject("x".repeat(256)).build(), key);
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }
}
