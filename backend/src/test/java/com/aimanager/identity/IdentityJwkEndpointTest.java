package com.aimanager.identity;

import com.aimanager.ManagerApplication;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.*;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.*;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Date;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.security.oauth2.jwt.*;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import static org.assertj.core.api.Assertions.*;

/** A real local JWKS endpoint with an unreachable public issuer proves deployment separation. */
@SpringBootTest(classes = ManagerApplication.class, properties = {
    "spring.datasource.url=jdbc:h2:mem:jwkendpoint;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
    "spring.datasource.username=sa", "spring.datasource.password=",
    "manager.security.issuer-uri=https://public-issuer.invalid/realms/ai-manager",
    "manager.security.audience=ai-manager-api"
})
class IdentityJwkEndpointTest {
    private static final String ISSUER = "https://public-issuer.invalid/realms/ai-manager";
    private static final RSAKey KEY;
    private static final HttpServer SERVER;
    static {
        try {
            KEY = new RSAKeyGenerator(2048).keyID("deployment-jwk").generate();
            SERVER = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
            SERVER.createContext("/certs", exchange -> {
                byte[] body = new JWKSet(KEY.toPublicJWK()).toString().getBytes(StandardCharsets.UTF_8);
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(200, body.length);
                try (var output = exchange.getResponseBody()) { output.write(body); }
            });
            SERVER.start();
        } catch (Exception failure) { throw new ExceptionInInitializerError(failure); }
    }
    @DynamicPropertySource static void properties(DynamicPropertyRegistry registry) {
        registry.add("manager.security.jwk-set-uri", () -> "http://127.0.0.1:" + SERVER.getAddress().getPort() + "/certs");
    }
    @Autowired JwtDecoder decoder;
    @AfterAll static void close() { SERVER.stop(0); }

    private String token(String issuer, String audience) throws Exception {
        var claims = new JWTClaimsSet.Builder().issuer(issuer).audience(audience).subject("deployment-adult")
            .issueTime(Date.from(Instant.now())).expirationTime(Date.from(Instant.now().plusSeconds(300))).build();
        var token = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(KEY.getKeyID()).build(), claims);
        token.sign(new RSASSASigner(KEY));
        return token.serialize();
    }
    @Test void internalKeysAuthenticateTheConfiguredPublicIssuer() throws Exception {
        assertThat(decoder.decode(token(ISSUER, "ai-manager-api")).getSubject()).isEqualTo("deployment-adult");
    }
    @Test void keysDoNotAuthorizeAnotherIssuer() throws Exception {
        String value = token("https://other.invalid", "ai-manager-api");
        assertThatThrownBy(() -> decoder.decode(value)).isInstanceOf(JwtException.class);
    }
    @Test void keysDoNotAuthorizeAnotherAudience() throws Exception {
        String value = token(ISSUER, "other-api");
        assertThatThrownBy(() -> decoder.decode(value)).isInstanceOf(JwtException.class);
    }
}
