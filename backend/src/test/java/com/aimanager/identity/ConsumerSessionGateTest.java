package com.aimanager.identity;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;

class ConsumerSessionGateTest {
    private static final String CURRENT = """
        {"subject":"adult-1","identityRevision":2,"sessionCurrent":true,"phoneVerified":true,
         "phoneMasked":"138****1234","wechatBound":true,"accountSecurityAvailable":true}
        """;
    private final ObjectMapper mapper = new ObjectMapper();
    private final AtomicInteger calls = new AtomicInteger();
    private final AtomicReference<String> authorization = new AtomicReference<>();
    private HttpServer server;
    private volatile int remoteStatus;
    private volatile String remoteBody;

    @BeforeEach
    void start() throws IOException {
        remoteStatus = 200;
        remoteBody = CURRENT;
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/realms/family/consumer-account/status", this::respond);
        server.start();
    }

    @AfterEach
    void stop() {
        SecurityContextHolder.clearContext();
        server.stop(0);
    }

    @Test
    void disabledGateDoesNotContactIdentityAndPreservesExistingAccess() throws Exception {
        remoteStatus = 503;
        var response = invoke(false, consumer(Map.of()), 2000);
        assertThat(response.getStatus()).isEqualTo(204);
        assertThat(calls.get()).isZero();
    }

    @Test
    void institutionalMfaSessionDoesNotDependOnConsumerIdentityService() throws Exception {
        var response = invoke(true, token(Map.of("azp", "ai-manager-parent", "amr", List.of("pwd", "otp"))), 2000);
        assertThat(response.getStatus()).isEqualTo(204);
        assertThat(calls.get()).isZero();
    }

    @Test
    void otherClientIsUnaffectedEvenWhenItHasPhoneClaims() throws Exception {
        var response = invoke(true, consumer(Map.of("azp", "ai-manager-console")), 2000);
        assertThat(response.getStatus()).isEqualTo(204);
        assertThat(calls.get()).isZero();
    }

    @Test
    void currentConsumerSessionReachesControllerUsingOnlyValidatedBearer() throws Exception {
        var response = invoke(true, consumer(Map.of()), 2000);
        assertThat(response.getStatus()).isEqualTo(204);
        assertThat(authorization.get()).isEqualTo("Bearer signed-token-value");
        assertThat(calls.get()).isEqualTo(1);
    }

    @Test
    void everyRequestIsRevalidatedSoRevocationTakesEffectImmediately() throws Exception {
        assertThat(invoke(true, consumer(Map.of()), 2000).getStatus()).isEqualTo(204);
        remoteStatus = 401;
        assertStale(invoke(true, consumer(Map.of()), 2000));
        assertThat(calls.get()).isEqualTo(2);
    }

    @ParameterizedTest
    @ValueSource(ints = {401, 403})
    void revokedOrRejectedIdentitySessionCannotReachController(int status) throws Exception {
        remoteStatus = status;
        assertStale(invoke(true, consumer(Map.of()), 2000));
    }

    @ParameterizedTest
    @ValueSource(strings = {
        "{\"subject\":\"other-adult\",\"identityRevision\":2,\"sessionCurrent\":true,\"phoneVerified\":true}",
        "{\"subject\":\"adult-1\",\"identityRevision\":3,\"sessionCurrent\":true,\"phoneVerified\":true}",
        "{\"subject\":\"adult-1\",\"identityRevision\":2,\"sessionCurrent\":false,\"phoneVerified\":true}",
        "{\"subject\":\"adult-1\",\"identityRevision\":2,\"sessionCurrent\":true,\"phoneVerified\":false}"
    })
    void validButNonCurrentIdentityStatusIsStale(String body) throws Exception {
        remoteBody = body;
        assertStale(invoke(true, consumer(Map.of()), 2000));
    }

    @ParameterizedTest
    @ValueSource(strings = {
        "{}", "[]", "not-json", "null",
        "{\"subject\":\"adult-1\",\"identityRevision\":\"2\",\"sessionCurrent\":true,\"phoneVerified\":true}",
        "{\"subject\":\"adult-1\",\"identityRevision\":2.0,\"sessionCurrent\":true,\"phoneVerified\":true}",
        "{\"subject\":\"adult-1\",\"identityRevision\":true,\"sessionCurrent\":true,\"phoneVerified\":true}",
        "{\"subject\":\"adult-1\",\"identityRevision\":0,\"sessionCurrent\":true,\"phoneVerified\":true}",
        "{\"subject\":\"adult-1\",\"identityRevision\":2,\"sessionCurrent\":\"true\",\"phoneVerified\":true}",
        "{\"subject\":\"adult-1\",\"identityRevision\":2,\"sessionCurrent\":true,\"phoneVerified\":\"true\"}",
        "{\"subject\":\"adult-1\",\"identityRevision\":2,\"identityRevision\":2,\"sessionCurrent\":true,\"phoneVerified\":true}",
        "{\"subject\":\"adult-1\",\"identityRevision\":2,\"sessionCurrent\":true,\"phoneVerified\":true} {}"
    })
    void malformedIdentityResponseFailsClosedWithoutClaimCoercion(String body) throws Exception {
        remoteBody = body;
        assertUnavailable(invoke(true, consumer(Map.of()), 2000));
    }

    @ParameterizedTest
    @ValueSource(strings = {"2", "true", "2.0", "-1", "0"})
    void malformedTrustedRevisionCannotBypassGate(String revision) throws Exception {
        Object claim = switch (revision) {
            case "true" -> Boolean.TRUE;
            case "2.0" -> 2.0;
            case "-1" -> -1;
            case "0" -> 0;
            default -> revision;
        };
        assertStale(invoke(true, consumer(Map.of("consumer_identity_revision", claim)), 2000));
        assertThat(calls.get()).isZero();
    }

    @Test
    void missingRevisionIsOnlyAcceptedWhenIdentityExplicitlyConfirmsLegacyOne() throws Exception {
        var jwt = token(Map.of("azp", "ai-manager-parent", "phone_number", "+8613812341234",
            "phone_number_verified", true, "amr", List.of("sms")));
        assertStale(invoke(true, jwt, 2000));
        remoteBody = CURRENT.replace("\"identityRevision\":2", "\"identityRevision\":1");
        assertThat(invoke(true, jwt, 2000).getStatus()).isEqualTo(204);
    }

    @Test
    void consumerMethodMarkerWithoutVerifiedPhoneCannotBecomeInstitutionalSession() throws Exception {
        assertStale(invoke(true, token(Map.of("azp", "ai-manager-parent", "amr", List.of("wechat"))), 2000));
        assertThat(calls.get()).isZero();
    }

    @Test
    void falseOrStringPhoneVerificationIsNotAcceptedAsVerified() throws Exception {
        assertStale(invoke(true, consumer(Map.of("phone_number_verified", false)), 2000));
        assertStale(invoke(true, consumer(Map.of("phone_number_verified", "true")), 2000));
        assertThat(calls.get()).isZero();
    }

    @Test
    void unverifiedAuthenticationNeverForwardsItsCredentials() throws Exception {
        var authentication = new JwtAuthenticationToken(consumer(Map.of()));
        authentication.setAuthenticated(false);
        SecurityContextHolder.getContext().setAuthentication(authentication);
        var response = run(new ConsumerSessionGate(true, client(2000), mapper));
        assertThat(response.getStatus()).isEqualTo(204);
        assertThat(calls.get()).isZero();
    }

    @ParameterizedTest
    @ValueSource(ints = {302, 404, 429, 500, 503})
    void providerErrorIsUnavailableAndNeverFollowsRedirect(int status) throws Exception {
        remoteStatus = status;
        assertUnavailable(invoke(true, consumer(Map.of()), 2000));
        assertThat(calls.get()).isEqualTo(1);
    }

    @Test
    void oversizedIdentityBodyIsRejectedBeforeParsing() throws Exception {
        remoteBody = CURRENT.substring(0, CURRENT.lastIndexOf('}')) + ",\"padding\":\"" + "x".repeat(9000) + "\"}";
        assertUnavailable(invoke(true, consumer(Map.of()), 2000));
    }

    @Test
    void chunkedOversizedBodyCannotBypassDeclaredLengthLimit() throws Exception {
        server.removeContext("/realms/family/consumer-account/status");
        server.createContext("/realms/family/consumer-account/status", exchange -> {
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, 0);
            try (var output = exchange.getResponseBody()) { output.write(" ".repeat(10000).getBytes()); }
            catch (IOException cancelled) { /* 字节上限触发的连接关闭。 */ }
        });
        assertUnavailable(invoke(true, consumer(Map.of()), 2000));
    }

    @ParameterizedTest
    @ValueSource(strings = {"", "http://outside.example.test/consumer-account/status",
        "https://user:secret@identity.example.test/consumer-account/status",
        "https://identity.example.test/consumer-account/status?token=secret",
        "https://identity.example.test/consumer-account/status#fragment",
        "https://identity.example.test/different-path", "https://identity.example.test/a/../consumer-account/status",
        "https://identity.example.test:0/consumer-account/status", "https://identity.example.test:65536/consumer-account/status"})
    void unsafeStatusEndpointsAreRejectedBeforeAnyCredentialCanBeSent(String endpoint) {
        assertThatThrownBy(() -> new ConsumerSessionStatusClient(endpoint, 2000, mapper))
            .isInstanceOf(IllegalArgumentException.class).hasMessageNotContaining("secret");
        assertThat(calls.get()).isZero();
    }

    @Test
    void disconnectedProviderIsUnavailable() throws Exception {
        var statusClient = client(2000);
        server.stop(0);
        SecurityContextHolder.getContext().setAuthentication(new JwtAuthenticationToken(consumer(Map.of()), List.of()));
        assertUnavailable(run(new ConsumerSessionGate(true, statusClient, mapper)));
    }

    @Test
    void slowResponseBodyHasTotalDeadlineInsteadOfPerByteDeadline() throws Exception {
        server.removeContext("/realms/family/consumer-account/status");
        server.createContext("/realms/family/consumer-account/status", exchange -> {
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, 0);
            try (var output = exchange.getResponseBody()) {
                for (int i = 0; i < 15; i++) {
                    output.write(' ');
                    output.flush();
                    try { Thread.sleep(50); } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                }
            } catch (IOException cancelled) { /* 已超时的请求允许关闭。 */ }
        });
        long start = System.nanoTime();
        assertUnavailable(invoke(true, consumer(Map.of()), 150));
        assertThat((System.nanoTime() - start) / 1_000_000).isLessThan(1500);
    }

    private MockHttpServletResponse invoke(boolean enabled, Jwt jwt, int deadlineMillis) throws Exception {
        SecurityContextHolder.getContext().setAuthentication(new JwtAuthenticationToken(jwt, List.of()));
        return run(new ConsumerSessionGate(enabled, enabled ? client(deadlineMillis) : null, mapper));
    }

    private MockHttpServletResponse run(ConsumerSessionGate gate) throws Exception {
        var request = new MockHttpServletRequest("POST", "/api/v1/tenants/family/phone-invitations");
        request.addHeader("Authorization", "Bearer never-forward-unvalidated-request-header");
        var response = new MockHttpServletResponse();
        gate.doFilter(request, response, (ignoredRequest, servletResponse) ->
            ((jakarta.servlet.http.HttpServletResponse) servletResponse).setStatus(204));
        return response;
    }

    private ConsumerSessionStatusClient client(int deadlineMillis) {
        return new ConsumerSessionStatusClient("http://127.0.0.1:" + server.getAddress().getPort()
            + "/realms/family/consumer-account/status", deadlineMillis, mapper);
    }

    private static Jwt consumer(Map<String, Object> overrides) {
        var claims = new java.util.HashMap<String, Object>(Map.of("azp", "ai-manager-parent",
            "consumer_identity_revision", 2, "phone_number", "+8613812341234",
            "phone_number_verified", true, "amr", List.of("sms")));
        claims.putAll(overrides);
        return token(claims);
    }

    private static Jwt token(Map<String, Object> claims) {
        return Jwt.withTokenValue("signed-token-value").header("alg", "RS256")
            .subject("adult-1").issuedAt(Instant.now().minusSeconds(60)).expiresAt(Instant.now().plusSeconds(60))
            .claims(target -> target.putAll(claims)).build();
    }

    private void respond(HttpExchange exchange) throws IOException {
        calls.incrementAndGet();
        authorization.set(exchange.getRequestHeaders().getFirst("Authorization"));
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.getResponseHeaders().set("Location", "/realms/family/consumer-account/status");
        byte[] bytes = remoteBody.getBytes(java.nio.charset.StandardCharsets.UTF_8);
        exchange.sendResponseHeaders(remoteStatus, bytes.length);
        try (var output = exchange.getResponseBody()) { output.write(bytes); }
    }

    private void assertStale(MockHttpServletResponse response) throws Exception {
        assertThat(response.getStatus()).isEqualTo(401);
        assertThat(mapper.readTree(response.getContentAsByteArray()).path("errorCode").asText())
            .isEqualTo("ACCOUNT_SESSION_STALE");
        assertSafe(response);
    }

    private void assertUnavailable(MockHttpServletResponse response) throws Exception {
        assertThat(response.getStatus()).isEqualTo(503);
        assertThat(mapper.readTree(response.getContentAsByteArray()).path("errorCode").asText())
            .isEqualTo("ACCOUNT_SECURITY_UNAVAILABLE");
        assertSafe(response);
    }

    private static void assertSafe(MockHttpServletResponse response) throws Exception {
        assertThat(response.getHeader("Cache-Control")).isEqualTo("no-store");
        assertThat(response.getContentAsString()).doesNotContain("signed-token-value", "+8613812341234", "adult-1");
    }
}
