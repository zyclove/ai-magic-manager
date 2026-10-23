package com.aimanager.identity;

import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.Authenticator;
import java.net.CookieHandler;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.ProxySelector;
import java.net.SocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import org.junit.jupiter.api.Test;

/**
 * 原供应商 transport 的本机 HTTP/1.1 行为实验，不调用短信或微信入口。
 *
 * <p>仅验证当前固定 JDK 的真实行为；不把其他 JDK 的源码、Future 状态或 fixture
 * 关闭后的异常当作整个请求时限、网络取消或正式供应商兼容性的证明。
 */
class ProviderHttpBodyDeadlineTest {
    private static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(5);
    private static final long SCHEDULING_ALLOWANCE_MILLIS = 1_000;
    private static final long DELAYED_BODY_MILLIS = 6_500;
    private static final long DRIP_INTERVAL_MILLIS = 800;
    private static final int DRIP_BYTES = 10;
    private static final int BULK_BYTES = 4 * 1024 * 1024;
    private static final int WRITE_CHUNK_BYTES = 32 * 1024;
    private static final ObjectMapper JSON = new ObjectMapper();

    @Test void smsHttp11BodyMustRespectWholeRequestDeadline() throws Exception {
        assertBodyDeadline("sms-delayed-body", Scenario.DELAYED, true);
    }

    @Test void wechatHttp11DripBodyMustRespectWholeRequestDeadline() throws Exception {
        assertBodyDeadline("wechat-drip-body", Scenario.DRIP, false);
    }

    private static void assertBodyDeadline(String name, Scenario scenario, boolean sms) throws Exception {
        Fixture fixture = new Fixture(scenario);
        ObservingClient client = null;
        IOException failure = null;
        AliyunSms.Response response = null;
        long started = 0;
        long elapsedMillis = -1;
        boolean handlerEndedBeforeCleanup = false;
        boolean writeFailedBeforeCleanup = false;
        try (Fixture owned = fixture) {
            client = new ObservingClient(owned.uri());
            started = System.nanoTime();
            try {
                try {
                    response = sms
                            ? AliyunSms.httpTransport(client).send(
                                    new AliyunSms.Request(owned.uri(), Map.of(), ""))
                            : WechatNative.httpTransport(client).send(owned.uri());
                } catch (IOException observed) {
                    failure = observed;
                }
            } finally {
                elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);
            }
            // 即使调用方已抛 timeout，也必须在清理之前观察真实 I/O 停止。
            owned.releaseBody.countDown();
            handlerEndedBeforeCleanup = owned.handlerEnded.await(3, TimeUnit.SECONDS);
            writeFailedBeforeCleanup = owned.writeFailedBeforeCleanup.get();
        } finally {
            if (client != null && started != 0) {
                emit(name, client, started, elapsedMillis, failure, response, fixture,
                        Map.of("handlerEndedBeforeCleanup", handlerEndedBeforeCleanup,
                                "writeFailedBeforeCleanup", writeFailedBeforeCleanup));
            }
        }
        long headerMillis = client.headerMillisAfter(started);
        assertTrue(headerMillis >= 0 && headerMillis < REQUEST_TIMEOUT.toMillis(),
                "The real client must receive headers before its configured deadline");
        assertEquals(REQUEST_TIMEOUT, client.observedTimeout.get(),
                "The unmodified transport must actually configure the five-second timeout");
        assertNull(fixture.handlerFailure.get(), "The local fixture failed before cleanup");
        assertInstanceOf(HttpTimeoutException.class, failure,
                "WHOLE_BODY_DEADLINE_REQUIRED: successful late body completion is not a timeout");
        assertTrue(elapsedMillis <= REQUEST_TIMEOUT.toMillis() + SCHEDULING_ALLOWANCE_MILLIS,
                "WHOLE_BODY_DEADLINE_REQUIRED: blocking beyond the deadline is not accepted");
        assertTrue(handlerEndedBeforeCleanup, "Body transfer remained live after the timeout");
        assertTrue(writeFailedBeforeCleanup,
                "A timeout must stop real I/O before fixture cleanup, not just complete a Future");
    }

    @Test void smsCallerInterruptionClosesOwnedExchangeBeforeFixtureCleanup() throws Exception {
        Fixture fixture = new Fixture(Scenario.BLOCKED_BULK);
        ObservingClient client = null;
        CountDownLatch callerExited = new CountDownLatch(1);
        AtomicReference<IOException> failure = new AtomicReference<>();
        AtomicBoolean interruptPreserved = new AtomicBoolean();
        Thread caller = null;
        long started = System.nanoTime();
        boolean exitedBeforeBodyRelease = false;
        boolean handlerEndedBeforeCleanup = false;
        boolean writeFailedBeforeCleanup = false;
        try (Fixture owned = fixture) {
            ObservingClient activeClient = new ObservingClient(owned.uri());
            client = activeClient;
            caller = new Thread(() -> {
                try {
                    AliyunSms.httpTransport(activeClient).send(
                            new AliyunSms.Request(owned.uri(), Map.of(), ""));
                } catch (IOException observed) {
                    failure.set(observed);
                    interruptPreserved.set(Thread.currentThread().isInterrupted());
                } finally {
                    callerExited.countDown();
                }
            }, "identity-owned-body-caller");
            caller.start();
            assertTrue(client.headersObserved.await(5, TimeUnit.SECONDS),
                    "The real client must reach the body phase before interruption");
            caller.interrupt();
            exitedBeforeBodyRelease = callerExited.await(3, TimeUnit.SECONDS);
            // 验收观察发生在 stop/close 之前；fixture 清理不能伪造网络已取消。
            fixture.releaseBody.countDown();
            handlerEndedBeforeCleanup = fixture.handlerEnded.await(3, TimeUnit.SECONDS);
            writeFailedBeforeCleanup = fixture.writeFailedBeforeCleanup.get();
        } finally {
            if (caller != null) {
                if (caller.isAlive()) {
                    caller.interrupt();
                }
                caller.join(3_000);
                emit("sms-caller-interruption", client, started,
                        TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started),
                        failure.get(), null, fixture,
                        Map.of("callerExitedBeforeBodyRelease", exitedBeforeBodyRelease,
                                "handlerEndedBeforeCleanup", handlerEndedBeforeCleanup,
                                "writeFailedBeforeCleanup", writeFailedBeforeCleanup,
                                "interruptPreserved", interruptPreserved.get(),
                                "ownedCallerAliveAfterCleanup", caller.isAlive()));
                assertFalse(caller.isAlive(), "Owned caller did not terminate after its server closed");
            }
        }
        assertTrue(exitedBeforeBodyRelease, "Interrupt must end the actual owned caller");
        assertNotNull(failure.get(), "Interrupted transport cannot report success");
        assertTrue(interruptPreserved.get(), "The transport must preserve the interrupt flag");
        assertNull(fixture.handlerFailure.get(), "The local fixture failed before cleanup");
        assertTrue(handlerEndedBeforeCleanup, "Owned server write did not finish before cleanup");
        assertTrue(writeFailedBeforeCleanup,
                "Peer I/O closure must be observed before fixture stop; Future state is insufficient");
    }

    private static void emit(String name, ObservingClient client, long started, long elapsedMillis,
            IOException failure, AliyunSms.Response response, Fixture fixture,
            Map<String, Object> additional) throws IOException {
        Map<String, Object> observation = new LinkedHashMap<>();
        observation.put("case", name);
        observation.put("javaRuntimeVersion", Runtime.version().toString());
        observation.put("scope", "loopback-http11-original-transport-only");
        observation.put("requestTimeoutMillis",
                client.observedTimeout.get() == null ? null : client.observedTimeout.get().toMillis());
        observation.put("headersAfterStartMillis", client.headerMillisAfter(started));
        observation.put("elapsedMillis", elapsedMillis);
        observation.put("exceptionType", failure == null ? null : failure.getClass().getName());
        observation.put("returnedStatus", response == null ? null : response.status());
        observation.put("returnedBodyLength", response == null ? null : response.body().length());
        observation.put("fixtureCleanupVerified", fixture.cleanupVerified);
        observation.put("fixtureWriteFailedBeforeCleanup", fixture.writeFailedBeforeCleanup.get());
        observation.put("fixtureHandlerFailure", fixture.handlerFailure.get());
        observation.putAll(additional);
        // 只有固定标签、类型和时序；不输出 URL、正文、配置或异常消息。
        System.out.println("BODY_DEADLINE_OBSERVATION " + JSON.writeValueAsString(observation));
    }

    private enum Scenario { DELAYED, DRIP, BLOCKED_BULK }

    private static final class Fixture implements AutoCloseable {
        private final Scenario scenario;
        private final HttpServer server;
        private final List<Thread> threads = new ArrayList<>();
        private final ExecutorService executor;
        private final CountDownLatch releaseBody = new CountDownLatch(1);
        private final CountDownLatch handlerEnded = new CountDownLatch(1);
        private final AtomicBoolean closing = new AtomicBoolean();
        private final AtomicBoolean writeFailedBeforeCleanup = new AtomicBoolean();
        private final AtomicReference<String> handlerFailure = new AtomicReference<>();
        private boolean cleanupVerified;

        Fixture(Scenario scenario) throws IOException {
            this.scenario = scenario;
            executor = new ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS,
                    new ArrayBlockingQueue<>(1), task -> {
                Thread thread = new Thread(task, "identity-owned-body-server");
                synchronized (threads) {
                    threads.add(thread);
                }
                return thread;
            }, new ThreadPoolExecutor.AbortPolicy());
            try {
                server = HttpServer.create(new InetSocketAddress(
                        InetAddress.getByAddress(new byte[]{127, 0, 0, 1}), 0), 1);
            } catch (IOException | RuntimeException failure) {
                executor.shutdownNow();
                throw failure;
            }
            try {
                server.setExecutor(executor);
                server.createContext("/body", this::handle);
                server.start();
            } catch (RuntimeException failure) {
                server.stop(0);
                executor.shutdownNow();
                throw failure;
            }
        }

        URI uri() {
            return URI.create("http://127.0.0.1:" + server.getAddress().getPort() + "/body");
        }

        private void handle(HttpExchange exchange) {
            OutputStream body = null;
            try {
                exchange.getRequestBody().close();
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(200, BULK_BYTES);
                body = exchange.getResponseBody();
                body.flush();
                try {
                    int written = 0;
                    if (scenario == Scenario.DELAYED) {
                        releaseBody.await(DELAYED_BODY_MILLIS, TimeUnit.MILLISECONDS);
                    } else if (scenario == Scenario.DRIP) {
                        for (int index = 0; index < DRIP_BYTES; index++) {
                            if (index > 0 && releaseBody.await(DRIP_INTERVAL_MILLIS, TimeUnit.MILLISECONDS)) {
                                break;
                            }
                            body.write('x');
                            body.flush();
                            written++;
                        }
                    } else if (!releaseBody.await(8, TimeUnit.SECONDS)) {
                        handlerFailure.set("BODY_RELEASE_DEADLINE_EXCEEDED");
                        return;
                    }
                    byte[] chunk = new byte[WRITE_CHUNK_BYTES];
                    while (written < BULK_BYTES) {
                        int count = Math.min(chunk.length, BULK_BYTES - written);
                        body.write(chunk, 0, count);
                        body.flush();
                        written += count;
                    }
                } catch (IOException writeFailure) {
                    // 不将 close() 的短写异常、fixture.stop 或中断造成的异常当作证据。
                    if (!closing.get() && !Thread.currentThread().isInterrupted()) {
                        writeFailedBeforeCleanup.set(true);
                    }
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                if (!closing.get()) {
                    handlerFailure.set("UNEXPECTED_HANDLER_INTERRUPTION");
                }
            } catch (IOException failure) {
                if (!closing.get()) {
                    handlerFailure.set("HEADER_OR_BODY_IO_FAILURE");
                }
            } finally {
                if (body != null) {
                    try {
                        body.close();
                    } catch (IOException ignored) {
                        // 关闭流时的 Content-Length 检查不证明对端关闭。
                    }
                }
                try {
                    exchange.close();
                } catch (RuntimeException failure) {
                    handlerFailure.set("EXCHANGE_CLOSE_FAILURE");
                } finally {
                    handlerEnded.countDown();
                }
            }
        }

        @Override
        public void close() throws InterruptedException {
            closing.set(true);
            releaseBody.countDown();
            server.stop(0);
            executor.shutdownNow();
            assertTrue(executor.awaitTermination(3, TimeUnit.SECONDS),
                    "Owned server executor did not terminate");
            synchronized (threads) {
                for (Thread thread : threads) {
                    thread.join(1_000);
                    assertFalse(thread.isAlive(), "Owned server thread is still live");
                }
            }
            cleanupVerified = true;
        }
    }

    /** 只增加观察点；响应、正文读取和阻塞行为全部由真实 JDK 客户端处理。 */
    private static final class ObservingClient extends HttpClient {
        private final HttpClient delegate;
        private final URI onlyUri;
        private final AtomicLong headerNanos = new AtomicLong();
        private final AtomicReference<Duration> observedTimeout = new AtomicReference<>();
        private final CountDownLatch headersObserved = new CountDownLatch(1);

        ObservingClient(URI onlyUri) {
            this.onlyUri = onlyUri;
            ProxySelector direct = new ProxySelector() {
                @Override public List<Proxy> select(URI uri) {
                    return List.of(Proxy.NO_PROXY);
                }
                @Override public void connectFailed(URI uri, SocketAddress address, IOException failure) {
                    // 本测试不使用代理，也不记录异常或机器配置。
                }
            };
            delegate = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3))
                    .followRedirects(Redirect.NEVER).version(Version.HTTP_1_1).proxy(direct).build();
        }

        long headerMillisAfter(long started) {
            long observed = headerNanos.get();
            return observed == 0 ? -1 : TimeUnit.NANOSECONDS.toMillis(observed - started);
        }

        @Override public <T> HttpResponse<T> send(HttpRequest request,
                HttpResponse.BodyHandler<T> handler) throws IOException, InterruptedException {
            accept(request);
            return delegate.send(request, observe(handler));
        }

        private void accept(HttpRequest request) throws IOException {
            if (!onlyUri.equals(request.uri()) || !"127.0.0.1".equals(request.uri().getHost())
                    || request.headers().firstValue("Authorization").isPresent()) {
                throw new IOException("Non-loopback or credential-bearing test request refused");
            }
            observedTimeout.set(request.timeout().orElse(null));
        }

        private <T> HttpResponse.BodyHandler<T> observe(HttpResponse.BodyHandler<T> handler) {
            return info -> {
                headerNanos.compareAndSet(0, System.nanoTime());
                headersObserved.countDown();
                return handler.apply(info);
            };
        }

        @Override public <T> CompletableFuture<HttpResponse<T>> sendAsync(HttpRequest request,
                HttpResponse.BodyHandler<T> handler) {
            try {
                accept(request);
                return delegate.sendAsync(request, observe(handler));
            } catch (IOException refused) {
                return CompletableFuture.failedFuture(refused);
            }
        }
        @Override public <T> CompletableFuture<HttpResponse<T>> sendAsync(HttpRequest request,
                HttpResponse.BodyHandler<T> handler, HttpResponse.PushPromiseHandler<T> pushHandler) {
            try {
                accept(request);
                return delegate.sendAsync(request, observe(handler), pushHandler);
            } catch (IOException refused) {
                return CompletableFuture.failedFuture(refused);
            }
        }
        @Override public Optional<CookieHandler> cookieHandler() { return delegate.cookieHandler(); }
        @Override public Optional<Duration> connectTimeout() { return delegate.connectTimeout(); }
        @Override public Redirect followRedirects() { return delegate.followRedirects(); }
        @Override public Optional<ProxySelector> proxy() { return delegate.proxy(); }
        @Override public SSLContext sslContext() { return delegate.sslContext(); }
        @Override public SSLParameters sslParameters() { return delegate.sslParameters(); }
        @Override public Optional<Authenticator> authenticator() { return delegate.authenticator(); }
        @Override public Version version() { return delegate.version(); }
        @Override public Optional<Executor> executor() { return delegate.executor(); }
    }
}
