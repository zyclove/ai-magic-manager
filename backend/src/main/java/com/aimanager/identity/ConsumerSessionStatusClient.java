package com.aimanager.identity;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.math.BigInteger;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.ByteBuffer;
import java.time.Duration;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Flow;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import org.springframework.security.oauth2.jwt.Jwt;

/** 在业务事务之外校验身份服务中的当前账号版本，不缓存允许结果。 */
final class ConsumerSessionStatusClient {
    private static final int MAX_RESPONSE_BYTES = 8192;
    private static final Set<String> INTERNAL_HTTP_HOSTS = Set.of("identity", "keycloak", "localhost", "127.0.0.1", "::1", "[::1]");
    private final URI endpoint;
    private final int deadlineMillis;
    private final ObjectMapper mapper;
    private final HttpClient http;

    enum Result { CURRENT, STALE, UNAVAILABLE }

    ConsumerSessionStatusClient(String endpoint, int deadlineMillis, ObjectMapper mapper) {
        this.endpoint = trustedEndpoint(endpoint);
        if (deadlineMillis < 100 || deadlineMillis > 5000) {
            throw new IllegalArgumentException("Consumer identity deadline must be between 100 and 5000 milliseconds");
        }
        this.deadlineMillis = deadlineMillis;
        this.mapper = mapper.copy().enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION)
            .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS);
        this.http = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER)
            .connectTimeout(Duration.ofMillis(deadlineMillis)).version(HttpClient.Version.HTTP_1_1).build();
    }

    Result check(Jwt jwt) {
        Long revision = revision(jwt.getClaims().get("consumer_identity_revision"));
        boolean legacy = !jwt.getClaims().containsKey("consumer_identity_revision");
        Object subject = jwt.getClaims().get("sub");
        Object phone = jwt.getClaims().get("phone_number");
        if (!(subject instanceof String actor) || actor.isBlank() || actor.length() > 255
                || !(phone instanceof String number) || !number.matches("\\+861[3-9][0-9]{9}")
                || !Boolean.TRUE.equals(jwt.getClaims().get("phone_number_verified"))
                || (!legacy && revision == null)) {
            return Result.STALE;
        }
        var request = HttpRequest.newBuilder(endpoint).timeout(Duration.ofMillis(deadlineMillis))
            .header("Authorization", "Bearer " + jwt.getTokenValue())
            .header("Accept", "application/json").header("Cache-Control", "no-store").GET().build();
        CompletableFuture<HttpResponse<byte[]>> pending = http.sendAsync(request, response -> {
            if (response.headers().firstValueAsLong("Content-Length").orElse(0) > MAX_RESPONSE_BYTES) {
                throw new IllegalStateException("Consumer identity response is too large");
            }
            return new LimitedBodySubscriber();
        });
        HttpResponse<byte[]> response;
        try {
            // 包含读取正文的总期限，防止缓慢持续传输绕过单次读取超时。
            response = pending.get(deadlineMillis, TimeUnit.MILLISECONDS);
        } catch (InterruptedException interrupted) {
            pending.cancel(true);
            Thread.currentThread().interrupt();
            return Result.UNAVAILABLE;
        } catch (ExecutionException | TimeoutException failure) {
            pending.cancel(true);
            return Result.UNAVAILABLE;
        }
        if (response.statusCode() == 401 || response.statusCode() == 403) {
            return Result.STALE;
        }
        if (response.statusCode() != 200 || !response.headers().firstValue("Content-Type")
                .orElse("").split(";", 2)[0].trim().equalsIgnoreCase("application/json")) {
            return Result.UNAVAILABLE;
        }
        return currentStatus(response.body(), actor, legacy ? 1L : revision);
    }

    private Result currentStatus(byte[] body, String actor, long revision) {
        JsonNode status;
        try {
            status = mapper.readTree(body);
        } catch (IOException malformed) {
            return Result.UNAVAILABLE;
        }
        if (status == null || !status.isObject() || !status.path("subject").isTextual()
                || status.path("subject").textValue().isBlank() || status.path("subject").textValue().length() > 255
                || !status.path("identityRevision").isIntegralNumber()
                || !status.path("identityRevision").canConvertToLong() || status.path("identityRevision").longValue() <= 0
                || !status.path("sessionCurrent").isBoolean() || !status.path("phoneVerified").isBoolean()) {
            return Result.UNAVAILABLE;
        }
        return actor.equals(status.path("subject").textValue())
            && revision == status.path("identityRevision").longValue()
            && status.path("sessionCurrent").booleanValue() && status.path("phoneVerified").booleanValue()
            ? Result.CURRENT : Result.STALE;
    }

    private static Long revision(Object value) {
        if (value instanceof Byte || value instanceof Short || value instanceof Integer || value instanceof Long) {
            long revision = ((Number) value).longValue();
            return revision > 0 ? revision : null;
        }
        if (value instanceof BigInteger integer && integer.signum() > 0 && integer.bitLength() < Long.SIZE) {
            return integer.longValue();
        }
        return null;
    }

    private static URI trustedEndpoint(String configured) {
        URI uri;
        try {
            uri = URI.create(configured == null ? "" : configured);
        } catch (IllegalArgumentException malformed) {
            throw new IllegalArgumentException("Invalid consumer identity status endpoint");
        }
        String host = uri.getHost();
        boolean https = "https".equalsIgnoreCase(uri.getScheme());
        boolean internalHttp = "http".equalsIgnoreCase(uri.getScheme()) && host != null
            && INTERNAL_HTTP_HOSTS.contains(host.toLowerCase(Locale.ROOT));
        if ((!https && !internalHttp) || host == null || uri.getUserInfo() != null || uri.getQuery() != null
                || uri.getFragment() != null || uri.getPort() == 0 || uri.getPort() > 65535
                || uri.getPath() == null || !uri.getPath().endsWith("/consumer-account/status")
                || !uri.getPath().equals(uri.getRawPath()) || !uri.normalize().equals(uri)) {
            throw new IllegalArgumentException("Consumer identity status endpoint must be a trusted direct identity URL");
        }
        return uri;
    }

    /** 流式上限约束实际收到的字节数，即使上游省略或伪造 Content-Length 也会取消。 */
    private static final class LimitedBodySubscriber implements HttpResponse.BodySubscriber<byte[]> {
        private final ByteArrayOutputStream body = new ByteArrayOutputStream();
        private final CompletableFuture<byte[]> completed = new CompletableFuture<>();
        private Flow.Subscription subscription;

        @Override
        public CompletionStage<byte[]> getBody() {
            return completed;
        }

        @Override
        public void onSubscribe(Flow.Subscription subscription) {
            this.subscription = subscription;
            subscription.request(1);
        }

        @Override
        public void onNext(List<ByteBuffer> buffers) {
            for (var buffer : buffers) {
                if (buffer.remaining() > MAX_RESPONSE_BYTES - body.size()) {
                    subscription.cancel();
                    completed.completeExceptionally(new IOException("Consumer identity response is too large"));
                    return;
                }
                byte[] bytes = new byte[buffer.remaining()];
                buffer.get(bytes);
                body.writeBytes(bytes);
            }
            subscription.request(1);
        }

        @Override
        public void onError(Throwable failure) {
            completed.completeExceptionally(failure);
        }

        @Override
        public void onComplete() {
            completed.complete(body.toByteArray());
        }
    }
}
