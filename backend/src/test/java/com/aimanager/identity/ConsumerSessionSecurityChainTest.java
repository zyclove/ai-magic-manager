package com.aimanager.identity;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.MapPropertySource;
import org.springframework.mock.web.MockServletContext;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.web.FilterChainProxy;
import org.springframework.security.oauth2.server.resource.web.authentication.BearerTokenAuthenticationFilter;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.context.support.AnnotationConfigWebApplicationContext;
import org.springframework.web.servlet.config.annotation.EnableWebMvc;

/** 真实签名通过生产安全链，验证当前会话检查位于验签之后和控制器之前。 */
class ConsumerSessionSecurityChainTest {
    private static final String ISSUER = "https://identity.example.test/realms/family";
    private static final AtomicInteger IDENTITY_CALLS = new AtomicInteger();
    private static HttpServer identity;
    private static RSAKey signingKey;
    private static AnnotationConfigWebApplicationContext context;
    private static MockMvc mvc;

    @BeforeAll
    static void start() throws Exception {
        signingKey = new RSAKeyGenerator(2048).generate();
        identity = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        identity.createContext("/realms/family/consumer-account/status", exchange -> {
            IDENTITY_CALLS.incrementAndGet();
            String bearer = exchange.getRequestHeaders().getFirst("Authorization");
            JWTClaimsSet claims;
            try {
                claims = SignedJWT.parse(bearer.substring("Bearer ".length())).getJWTClaimsSet();
            } catch (java.text.ParseException malformed) {
                throw new java.io.IOException("Invalid test identity bearer", malformed);
            }
            long revision = ((Number) claims.getClaim("consumer_identity_revision")).longValue();
            byte[] body = ("{\"subject\":\"adult-1\",\"identityRevision\":" + revision
                + ",\"sessionCurrent\":" + (revision == 2) + ",\"phoneVerified\":true}")
                .getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, body.length);
            try (var output = exchange.getResponseBody()) { output.write(body); }
        });
        identity.start();
        context = new AnnotationConfigWebApplicationContext();
        context.setServletContext(new MockServletContext());
        context.getEnvironment().getPropertySources().addFirst(new MapPropertySource("consumer-test", Map.of(
            "manager.consumer-security.enabled", "true",
            "manager.consumer-security.status-url", "http://127.0.0.1:" + identity.getAddress().getPort()
                + "/realms/family/consumer-account/status",
            "manager.security.allowed-origins", "https://parent.example.test")));
        context.register(WebConfiguration.class, SecurityConfiguration.class);
        context.refresh();
        mvc = MockMvcBuilders.webAppContextSetup(context).apply(springSecurity()).build();
    }

    @AfterAll
    static void close() {
        if (context != null) { context.close(); }
        if (identity != null) { identity.stop(0); }
    }

    @Test
    void invalidSignatureNeverReachesIdentityOrController() throws Exception {
        int before = IDENTITY_CALLS.get();
        mvc.perform(get("/api/probe").header("Authorization", "Bearer " + signed(2, new RSAKeyGenerator(2048).generate())))
            .andExpect(status().isUnauthorized()).andExpect(jsonPath("$.errorCode").value("UNAUTHENTICATED"));
        assertThat(IDENTITY_CALLS.get()).isEqualTo(before);
    }

    @Test
    void validCurrentSignatureIsCheckedExactlyOnceBeforeController() throws Exception {
        int before = IDENTITY_CALLS.get();
        mvc.perform(get("/api/probe").header("Authorization", "Bearer " + signed(2, signingKey)))
            .andExpect(status().isOk()).andExpect(jsonPath("$.reached").value(true));
        assertThat(IDENTITY_CALLS.get()).isEqualTo(before + 1);
    }

    @Test
    void validSignatureWithRevokedSessionIsRejectedBeforeController() throws Exception {
        mvc.perform(get("/api/probe").header("Authorization", "Bearer " + signed(1, signingKey)))
            .andExpect(status().isUnauthorized()).andExpect(jsonPath("$.errorCode").value("ACCOUNT_SESSION_STALE"));
    }

    @Test
    void gateIsRegisteredOnlyOnceAndAfterBearerVerification() {
        var filters = context.getBean(FilterChainProxy.class).getFilterChains().get(0).getFilters();
        assertThat(filters.stream().filter(ConsumerSessionGate.class::isInstance).count()).isEqualTo(1);
        int gateIndex = -1;
        int bearerIndex = -1;
        for (int i = 0; i < filters.size(); i++) {
            if (filters.get(i) instanceof ConsumerSessionGate) { gateIndex = i; }
            if (filters.get(i) instanceof BearerTokenAuthenticationFilter) { bearerIndex = i; }
        }
        assertThat(gateIndex).isGreaterThan(bearerIndex);
        assertThat(context.getBeansOfType(ConsumerSessionGate.class)).isEmpty();
    }

    private static String signed(int revision, RSAKey key) throws Exception {
        var claims = new JWTClaimsSet.Builder().issuer(ISSUER).subject("adult-1").audience("ai-manager-api")
            .issueTime(Date.from(Instant.now())).expirationTime(Date.from(Instant.now().plusSeconds(300)))
            .claim("azp", "ai-manager-parent").claim("phone_number", "+8613812341234")
            .claim("phone_number_verified", true).claim("consumer_identity_revision", revision)
            .claim("amr", List.of("sms")).build();
        var signed = new SignedJWT(new JWSHeader(JWSAlgorithm.RS256), claims);
        signed.sign(new RSASSASigner(key));
        return signed.serialize();
    }

    @Configuration(proxyBeanMethods = false)
    @EnableWebSecurity
    @EnableWebMvc
    static class WebConfiguration {
        @Bean ObjectMapper mapper() { return new ObjectMapper(); }
        @Bean Probe probe() { return new Probe(); }
        @Bean JwtDecoder decoder() throws Exception {
            var decoder = NimbusJwtDecoder.withPublicKey(signingKey.toRSAPublicKey()).build();
            decoder.setJwtValidator(IdentityTokenValidators.forIssuerAndAudience(ISSUER, "ai-manager-api"));
            return decoder;
        }
    }

    @RestController
    static class Probe {
        @GetMapping("/api/probe") Map<String, Boolean> probe() { return Map.of("reached", true); }
    }
}
