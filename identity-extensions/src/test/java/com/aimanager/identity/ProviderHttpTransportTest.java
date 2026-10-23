package com.aimanager.identity;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.ProxySelector;
import java.net.SocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpHeaders;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Flow;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;

/** 新契约测试源码；尚未运行，不改写原 4 MiB 行为反例。 */
class ProviderHttpTransportTest {
    private static final URI SYNTHETIC_URI = URI.create("https://provider.invalid/body");

    @Test void smallUtf8BodyMayCrossBuffersWithoutLosingCharacters() throws Exception {
        byte[] value = "{\"name\":\"中文\"}".getBytes(StandardCharsets.UTF_8);
        HttpClient client = scripted((request, handler) -> {
            var subscriber = handler.apply(info(Map.of()));
            subscriber.onSubscribe(new Subscription());
            subscriber.onNext(List.of(ByteBuffer.wrap(value, 0, 11),
                    ByteBuffer.wrap(value, 11, value.length - 11)));
            subscriber.onComplete();
            return result(subscriber);
        });
        assertEquals("{\"name\":\"中文\"}", send(client).body());
    }

    @Test void exactly65536ReceivedBytesAreAccepted() throws Exception {
        HttpClient client = scripted((request, handler) -> {
            var subscriber = handler.apply(info(Map.of("Content-Length", List.of("65536"))));
            subscriber.onSubscribe(new Subscription());
            subscriber.onNext(List.of(ByteBuffer.wrap(new byte[65536])));
            subscriber.onComplete();
            return result(subscriber);
        });
        assertEquals(65536, send(client).body().length());
    }

    @Test void declaredOversizeCancelsLateSubscriptionWithoutBodyDemand() throws Exception {
        Subscription subscription = new Subscription();
        HttpClient client = scripted((request, handler) -> {
            var subscriber = handler.apply(info(Map.of("Content-Length", List.of("65537"))));
            subscriber.onSubscribe(subscription);
            subscriber.onComplete();
            return result(subscriber);
        });
        assertThrows(IOException.class, () -> send(client));
        assertTrue(subscription.cancelled.get());
        assertEquals(0, subscription.requested.get());
    }

    @Test void unknownLengthCannotExceedLimitAcrossMultipleBuffers() throws Exception {
        Subscription subscription = new Subscription();
        ByteBuffer excess = ByteBuffer.wrap(new byte[7]);
        HttpClient client = scripted((request, handler) -> {
            var subscriber = handler.apply(info(Map.of()));
            subscriber.onSubscribe(subscription);
            subscriber.onNext(List.of(ByteBuffer.wrap(new byte[65530]), excess));
            subscriber.onComplete();
            return result(subscriber);
        });
        assertThrows(IOException.class, () -> send(client));
        assertTrue(subscription.cancelled.get());
        assertEquals(0, excess.position(), "Reject before copying the overflowing buffer");
    }

    @Test void byteLimitCountsMultibyteUtf8InsteadOfDecodedCharacterCount() throws Exception {
        byte[] bytes = "中".repeat(21846).getBytes(StandardCharsets.UTF_8);
        assertEquals(65538, bytes.length);
        HttpClient client = scripted((request, handler) -> {
            var subscriber = handler.apply(info(Map.of()));
            subscriber.onSubscribe(new Subscription());
            subscriber.onNext(List.of(ByteBuffer.wrap(bytes)));
            subscriber.onComplete();
            return result(subscriber);
        });
        assertThrows(IOException.class, () -> send(client));
    }

    @Test void invalidOrNegativeLengthRejectsWithoutRequestingBody() throws Exception {
        for (String length : List.of("-1", "invalid")) {
            Subscription subscription = new Subscription();
            HttpClient client = scripted((request, handler) -> {
                var subscriber = handler.apply(info(Map.of("Content-Length", List.of(length))));
                subscriber.onSubscribe(subscription);
                return result(subscriber);
            });
            assertThrows(IOException.class, () -> send(client));
            assertTrue(subscription.cancelled.get());
            assertEquals(0, subscription.requested.get());
        }
    }

    @Test void upstreamFailureCannotBecomeLatePartialSuccess() throws Exception {
        IOException expected = new IOException("Synthetic body failure");
        HttpClient client = scripted((request, handler) -> {
            var subscriber = handler.apply(info(Map.of()));
            subscriber.onSubscribe(new Subscription());
            subscriber.onNext(List.of(ByteBuffer.wrap(new byte[]{'O'})));
            subscriber.onError(expected);
            subscriber.onComplete();
            return result(subscriber);
        });
        assertSame(expected, assertThrows(IOException.class, () -> send(client)));
    }

    @Test void duplicateSubscriptionIsCancelledWithoutReplacingTheOwnedOne() throws Exception {
        Subscription first = new Subscription();
        Subscription duplicate = new Subscription();
        HttpClient client = scripted((request, handler) -> {
            var subscriber = handler.apply(info(Map.of()));
            subscriber.onSubscribe(first);
            subscriber.onSubscribe(duplicate);
            subscriber.onNext(List.of(ByteBuffer.wrap(new byte[]{'O', 'K'})));
            subscriber.onComplete();
            return result(subscriber);
        });
        assertEquals("OK", send(client).body());
        assertTrue(duplicate.cancelled.get());
        assertFalse(first.cancelled.get());
    }

    @Test void timeoutCancelsOriginalFutureAndAStillUnpublishedSubscription() throws Exception {
        TimeoutFuture pending = new TimeoutFuture();
        AtomicReference<HttpResponse.BodyHandler<byte[]>> captured = new AtomicReference<>();
        HttpClient client = scripted((request, handler) -> {
            captured.set(handler);
            return pending;
        });
        assertThrows(HttpTimeoutException.class, () -> send(client));
        assertTrue(pending.isCancelled(), "Cancel the exact future returned by sendAsync");
        var subscriber = captured.get().apply(info(Map.of()));
        Subscription late = new Subscription();
        subscriber.onSubscribe(late);
        ByteBuffer ignored = ByteBuffer.wrap(new byte[65537]);
        subscriber.onNext(List.of(ignored));
        subscriber.onComplete();
        assertTrue(late.cancelled.get());
        assertEquals(0, late.requested.get());
        assertEquals(0, ignored.position());
        assertThrows(ExecutionException.class, () -> subscriber.getBody().toCompletableFuture().get());
    }

    @Test void existingCallerInterruptPreventsAnyNewDispatch() throws Exception {
        HttpClient client = mock(HttpClient.class);
        Thread.currentThread().interrupt();
        try {
            assertThrows(IOException.class, () -> send(client));
            assertTrue(Thread.currentThread().isInterrupted());
            verifyNoInteractions(client);
        } finally {
            Thread.interrupted();
        }
    }

    @Test void interruptionWhileWaitingCancelsOriginalFutureAndPreservesFlag() throws Exception {
        CompletableFuture<HttpResponse<byte[]>> pending = new CompletableFuture<>() {
            @Override public HttpResponse<byte[]> get(long timeout, TimeUnit unit)
                    throws InterruptedException {
                throw new InterruptedException("Synthetic boundary interruption");
            }
        };
        HttpClient client = scripted((request, handler) -> pending);
        try {
            assertThrows(IOException.class, () -> send(client));
            assertTrue(pending.isCancelled());
            assertTrue(Thread.currentThread().isInterrupted());
        } finally {
            Thread.interrupted();
        }
    }

    @Test void interruptedCallerCannotAcceptAnAlreadyCompletedFuture() throws Exception {
        HttpClient client = scripted((request, handler) -> {
            Thread.currentThread().interrupt();
            return CompletableFuture.completedFuture(response(new byte[]{'O', 'K'}));
        });
        try {
            assertThrows(IOException.class, () -> send(client));
            assertTrue(Thread.currentThread().isInterrupted());
        } finally {
            Thread.interrupted();
        }
    }

    @Test void requestPreparationConsumesTheSameFiveSecondBudget() throws Exception {
        HttpClient client = mock(HttpClient.class);
        assertThrows(HttpTimeoutException.class, () -> ProviderHttpTransport.send(client, () -> {
            pause(5100);
            return request();
        }));
        verifyNoInteractions(client);
    }

    @Test void lateAlreadyCompletedResponseAfterSubmissionIsNotSuccess() throws Exception {
        HttpClient client = scripted((request, handler) -> {
            pause(5100);
            return CompletableFuture.completedFuture(response(new byte[]{'O', 'K'}));
        });
        assertThrows(HttpTimeoutException.class, () -> send(client));
    }

    @Test void lateResultReturnedByGetCannotBypassTheFinalDeadlineCheck() throws Exception {
        HttpClient client = scripted((request, handler) -> new CompletableFuture<>() {
            @Override public HttpResponse<byte[]> get(long timeout, TimeUnit unit) {
                pause(5100);
                return response(new byte[]{'O', 'K'});
            }
        });
        assertThrows(HttpTimeoutException.class, () -> send(client));
    }

    @Test void remainingWaitBudgetDeductsSynchronousSubmissionTime() throws Exception {
        AtomicLong waitNanos = new AtomicLong();
        HttpClient client = scripted((request, handler) -> {
            pause(250);
            return new CompletableFuture<>() {
                @Override public HttpResponse<byte[]> get(long timeout, TimeUnit unit) {
                    waitNanos.set(unit.toNanos(timeout));
                    return response(new byte[]{'O', 'K'});
                }
            };
        });
        assertEquals("OK", send(client).body());
        assertTrue(waitNanos.get() > 0);
        assertTrue(waitNanos.get() < TimeUnit.MILLISECONDS.toNanos(4900),
                "Do not grant a new five seconds after sendAsync returns");
    }

    @Test void transportFailureNeverRetriesOrReturnsPartialBody() throws Exception {
        AtomicInteger submissions = new AtomicInteger();
        HttpClient client = scripted((request, handler) -> {
            submissions.incrementAndGet();
            return CompletableFuture.failedFuture(new IOException("Synthetic transport failure"));
        });
        assertThrows(IOException.class, () -> send(client));
        assertEquals(1, submissions.get());
    }

    @Test void smsSlowBodyWithinLimitTimesOutBeforeAnyCancellationProbe() throws Exception {
        assertRealDeadline(Scenario.SLOW, true);
    }

    @Test void wechatDripWithinLimitTimesOutBeforeAnyCancellationProbe() throws Exception {
        assertRealDeadline(Scenario.DRIP, false);
    }

    @Test void realChunkedOversizeIsRejectedAndWriterStopsBeforeFixtureCleanup() throws Exception {
        try (LocalServer fixture = new LocalServer(Scenario.OVERSIZE)) {
            ObservedClient observed = new ObservedClient(fixture);
            IOException failure = assertThrows(IOException.class,
                    () -> WechatNative.httpTransport(observed.client).send(fixture.uri()));
            assertFalse(failure instanceof HttpTimeoutException,
                    "This is the size contract, separate from the total deadline contract");
            assertTrue(fixture.handlerEnded.await(3, TimeUnit.SECONDS));
            assertTrue(fixture.writerFailedBeforeCleanup.get());
            assertNull(fixture.failure.get());
            assertFalse(fixture.closing.get());
            assertEquals(1, observed.submissions.get());
        }
    }

    @Test void realCallerInterruptStopsOnlyItsExchangeBeforeFixtureCleanup() throws Exception {
        try (LocalServer fixture = new LocalServer(Scenario.SLOW)) {
            ObservedClient observed = new ObservedClient(fixture);
            AtomicReference<IOException> failure = new AtomicReference<>();
            AtomicBoolean interruptPreserved = new AtomicBoolean();
            CountDownLatch callerEnded = new CountDownLatch(1);
            Thread caller = new Thread(() -> {
                try {
                    AliyunSms.httpTransport(observed.client)
                            .send(new AliyunSms.Request(fixture.uri(), Map.of(), ""));
                } catch (IOException rejected) {
                    failure.set(rejected);
                    interruptPreserved.set(Thread.currentThread().isInterrupted());
                } finally {
                    callerEnded.countDown();
                }
            }, "identity-contract-interrupted-caller");
            caller.start();
            try {
                assertTrue(observed.headers.await(3, TimeUnit.SECONDS));
                caller.interrupt();
                assertTrue(callerEnded.await(3, TimeUnit.SECONDS));
                assertNotNull(failure.get());
                assertTrue(interruptPreserved.get());
                fixture.releaseProbe.countDown();
                assertTrue(fixture.handlerEnded.await(3, TimeUnit.SECONDS));
                assertTrue(fixture.writerFailedBeforeCleanup.get());
                assertNull(fixture.failure.get());
                assertEquals("{\"Code\":\"OK\"}",
                        WechatNative.httpTransport(observed.client).send(fixture.fastUri()).body());
            } finally {
                if (caller.isAlive()) {
                    caller.interrupt();
                }
                caller.join(3000);
                assertFalse(caller.isAlive());
            }
        }
    }

    @Test void timingOutAConcurrentRequestDoesNotCancelSharedClientsOtherRequest() throws Exception {
        try (LocalServer fixture = new LocalServer(Scenario.SLOW)) {
            ObservedClient observed = new ObservedClient(fixture);
            ExecutorService caller = ownedPool("identity-contract-concurrent", 2);
            AtomicLong slowStarted = new AtomicLong();
            try {
                var slow = caller.submit(() -> {
                    slowStarted.set(System.nanoTime());
                    return WechatNative.httpTransport(observed.client).send(fixture.uri());
                });
                assertTrue(observed.headers.await(3, TimeUnit.SECONDS));

                // B约在A预算第4秒开始，仍保留自身完整5秒；正文必须跨过A的实际取消。
                long untilLateStart = TimeUnit.SECONDS.toNanos(4) - (System.nanoTime() - slowStarted.get());
                if (untilLateStart > 0) {
                    TimeUnit.NANOSECONDS.sleep(untilLateStart);
                }
                assertFalse(slow.isDone(), "A must still be in flight when B starts");
                var held = caller.submit(() ->
                        WechatNative.httpTransport(observed.client).send(fixture.heldUri()));
                assertTrue(observed.heldHeaders.await(1, TimeUnit.SECONDS));
                assertFalse(slow.isDone(), "B must have received headers before A times out");
                assertFalse(held.isDone());
                assertEquals(1, fixture.releaseHeldBody.getCount());

                ExecutionException failure = assertThrows(ExecutionException.class,
                        () -> slow.get(3, TimeUnit.SECONDS));
                assertInstanceOf(HttpTimeoutException.class, failure.getCause());
                long elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - slowStarted.get());
                assertTrue(elapsedMillis >= 4500 && elapsedMillis <= 6000);
                assertEquals(0, fixture.preProbeBodyBytes.get());
                fixture.releaseProbe.countDown();
                assertTrue(fixture.handlerEnded.await(2, TimeUnit.SECONDS));
                assertTrue(fixture.writerFailedBeforeCleanup.get());
                assertNull(fixture.failure.get());
                assertFalse(fixture.closing.get());

                assertEquals(1, fixture.releaseHeldBody.getCount());
                assertNotNull(observed.heldPending.get());
                assertFalse(observed.heldPending.get().isDone(), "The original B HTTP Future is still live");
                assertFalse(held.isDone(), "B must remain in flight throughout A cancellation");
                assertFalse(fixture.heldBodyWritten.get());
                fixture.releaseHeldBody.countDown();
                AliyunSms.Response result = held.get(2, TimeUnit.SECONDS);
                assertEquals(200, result.status());
                assertEquals("{\"Code\":\"OK\"}", result.body());
                assertTrue(fixture.heldHandlerEnded.await(1, TimeUnit.SECONDS));
                assertTrue(fixture.heldBodyWritten.get());
                assertNull(fixture.heldFailure.get());
                assertFalse(fixture.closing.get());
                assertEquals(2, observed.submissions.get());
            } finally {
                fixture.releaseProbe.countDown();
                fixture.releaseHeldBody.countDown();
                caller.shutdownNow();
                assertTrue(caller.awaitTermination(3, TimeUnit.SECONDS));
            }
        }
    }

    private static void assertRealDeadline(Scenario scenario, boolean sms) throws Exception {
        try (LocalServer fixture = new LocalServer(scenario)) {
            ObservedClient observed = new ObservedClient(fixture);
            long started = System.nanoTime();
            assertThrows(HttpTimeoutException.class, () -> {
                if (sms) {
                    AliyunSms.httpTransport(observed.client)
                            .send(new AliyunSms.Request(fixture.uri(), Map.of(), ""));
                } else {
                    WechatNative.httpTransport(observed.client).send(fixture.uri());
                }
            });
            long elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);
            assertTrue(elapsedMillis >= 4500 && elapsedMillis <= 6000,
                    "A five-second total deadline has only a finite scheduling allowance");
            assertTrue(observed.headerNanos.get() > started);
            assertTrue(observed.headerNanos.get() - started < TimeUnit.SECONDS.toNanos(5));
            assertTrue(fixture.preProbeBodyBytes.get() <= 10,
                    "The deadline must fail while the actual body is below 64 KiB");
            assertFalse(fixture.probeStarted.get(), "No size probe may cause this timeout");
            fixture.releaseProbe.countDown();
            assertTrue(fixture.handlerEnded.await(3, TimeUnit.SECONDS));
            assertTrue(fixture.writerFailedBeforeCleanup.get(),
                    "Real network closure must be observed before fixture stop");
            assertNull(fixture.failure.get());
            assertFalse(fixture.closing.get());
            assertEquals(1, observed.submissions.get());
        }
    }

    private static AliyunSms.Response send(HttpClient client) throws IOException {
        return ProviderHttpTransport.send(client, ProviderHttpTransportTest::request);
    }

    private static HttpRequest request() {
        return HttpRequest.newBuilder(SYNTHETIC_URI).timeout(Duration.ofSeconds(5)).GET().build();
    }

    private static HttpResponse.ResponseInfo info(Map<String, List<String>> headers) {
        HttpResponse.ResponseInfo info = mock(HttpResponse.ResponseInfo.class);
        when(info.statusCode()).thenReturn(200);
        when(info.headers()).thenReturn(HttpHeaders.of(headers, (name, value) -> true));
        return info;
    }

    @SuppressWarnings("unchecked")
    private static HttpResponse<byte[]> response(byte[] body) {
        HttpResponse<byte[]> response = mock(HttpResponse.class);
        when(response.statusCode()).thenReturn(200);
        when(response.body()).thenReturn(body);
        return response;
    }

    private static CompletableFuture<HttpResponse<byte[]>> result(
            HttpResponse.BodySubscriber<byte[]> subscriber) {
        return subscriber.getBody().toCompletableFuture().thenApply(ProviderHttpTransportTest::response);
    }

    private interface Script {
        CompletableFuture<HttpResponse<byte[]>> submit(HttpRequest request,
                HttpResponse.BodyHandler<byte[]> handler) throws Exception;
    }

    private static HttpClient scripted(Script script) throws Exception {
        HttpClient client = mock(HttpClient.class);
        when(client.sendAsync(any(HttpRequest.class),
                org.mockito.ArgumentMatchers.<HttpResponse.BodyHandler<byte[]>>any()))
                .thenAnswer(call -> script.submit(call.getArgument(0), call.getArgument(1)));
        return client;
    }

    private static void pause(long milliseconds) {
        try {
            Thread.sleep(milliseconds);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new AssertionError("Unexpected interruption in synthetic setup", interrupted);
        }
    }

    private static final class Subscription implements Flow.Subscription {
        private final AtomicBoolean cancelled = new AtomicBoolean();
        private final AtomicLong requested = new AtomicLong();
        @Override public void request(long count) { requested.addAndGet(count); }
        @Override public void cancel() { cancelled.set(true); }
    }

    private static final class TimeoutFuture extends CompletableFuture<HttpResponse<byte[]>> {
        @Override public HttpResponse<byte[]> get(long timeout, TimeUnit unit) throws TimeoutException {
            throw new TimeoutException("Synthetic wait boundary");
        }
    }

    private enum Scenario { SLOW, DRIP, OVERSIZE }

    private static ExecutorService ownedPool(String name, int threads) {
        return new ThreadPoolExecutor(threads, threads, 0, TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(4), runnable -> new Thread(runnable, name),
                new ThreadPoolExecutor.AbortPolicy());
    }

    /** 测试只允许自有 loopback；保留真实 JDK Future，不包一层影响取消的 Future。 */
    private static final class ObservedClient {
        private final HttpClient client;
        private final CountDownLatch headers = new CountDownLatch(1);
        private final CountDownLatch heldHeaders = new CountDownLatch(1);
        private final AtomicReference<CompletableFuture<HttpResponse<byte[]>>> heldPending =
                new AtomicReference<>();
        private final AtomicLong headerNanos = new AtomicLong();
        private final AtomicInteger submissions = new AtomicInteger();

        ObservedClient(LocalServer fixture) throws Exception {
            ProxySelector direct = new ProxySelector() {
                @Override public List<Proxy> select(URI uri) { return List.of(Proxy.NO_PROXY); }
                @Override public void connectFailed(URI uri, SocketAddress address, IOException failure) { }
            };
            HttpClient real = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3))
                    .followRedirects(HttpClient.Redirect.NEVER).version(HttpClient.Version.HTTP_1_1)
                    .proxy(direct).build();
            client = scripted((request, handler) -> {
                boolean held = request.uri().equals(fixture.heldUri());
                assertTrue(request.uri().equals(fixture.uri()) || request.uri().equals(fixture.fastUri()) || held);
                assertTrue(request.headers().firstValue("Authorization").isEmpty());
                submissions.incrementAndGet();
                CompletableFuture<HttpResponse<byte[]>> pending = real.sendAsync(request, response -> {
                    headerNanos.compareAndSet(0, System.nanoTime());
                    headers.countDown();
                    if (held) {
                        heldHeaders.countDown();
                    }
                    return handler.apply(response);
                });
                if (held) {
                    heldPending.set(pending);
                }
                return pending;
            });
        }
    }

    /** 大流仅在已记录超时之后用于探测关闭；不参与限内正文的期限判定。 */
    private static final class LocalServer implements AutoCloseable {
        private final Scenario scenario;
        private final HttpServer server;
        private final ExecutorService executor = ownedPool("identity-contract-http-server", 2);
        private final CountDownLatch releaseProbe = new CountDownLatch(1);
        private final CountDownLatch handlerEnded = new CountDownLatch(1);
        private final CountDownLatch releaseHeldBody = new CountDownLatch(1);
        private final CountDownLatch heldHandlerEnded = new CountDownLatch(1);
        private final AtomicBoolean heldBodyWritten = new AtomicBoolean();
        private final AtomicReference<String> heldFailure = new AtomicReference<>();
        private final AtomicBoolean probeStarted = new AtomicBoolean();
        private final AtomicInteger preProbeBodyBytes = new AtomicInteger();
        private final AtomicBoolean writerFailedBeforeCleanup = new AtomicBoolean();
        private final AtomicBoolean closing = new AtomicBoolean();
        private final AtomicReference<String> failure = new AtomicReference<>();

        LocalServer(Scenario scenario) throws IOException {
            this.scenario = scenario;
            HttpServer created = null;
            try {
                created = HttpServer.create(new InetSocketAddress(
                        InetAddress.getByAddress(new byte[]{127, 0, 0, 1}), 0), 2);
                server = created;
                server.setExecutor(executor);
                server.createContext("/body", this::body);
                server.createContext("/held", this::held);
                server.createContext("/ok", exchange -> {
                    try (exchange) {
                        exchange.getRequestBody().close();
                        byte[] value = "{\"Code\":\"OK\"}".getBytes(StandardCharsets.UTF_8);
                        exchange.sendResponseHeaders(200, value.length);
                        exchange.getResponseBody().write(value);
                    }
                });
                server.start();
            } catch (IOException | RuntimeException rejected) {
                if (created != null) {
                    created.stop(0);
                }
                executor.shutdownNow();
                throw rejected;
            }
        }

        URI uri() { return URI.create("http://127.0.0.1:" + server.getAddress().getPort() + "/body"); }
        URI fastUri() { return URI.create("http://127.0.0.1:" + server.getAddress().getPort() + "/ok"); }
        URI heldUri() { return URI.create("http://127.0.0.1:" + server.getAddress().getPort() + "/held"); }

        private void held(HttpExchange exchange) {
            try (exchange) {
                exchange.getRequestBody().close();
                byte[] value = "{\"Code\":\"OK\"}".getBytes(StandardCharsets.UTF_8);
                exchange.sendResponseHeaders(200, value.length);
                exchange.getResponseBody().flush();
                if (!releaseHeldBody.await(7, TimeUnit.SECONDS)) {
                    heldFailure.set("HELD_BODY_NOT_RELEASED");
                    return;
                }
                exchange.getResponseBody().write(value);
                exchange.getResponseBody().flush();
                heldBodyWritten.set(true);
            } catch (IOException closed) {
                if (!closing.get()) {
                    heldFailure.set("HELD_BODY_IO_FAILED");
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                if (!closing.get()) {
                    heldFailure.set("UNEXPECTED_HELD_HANDLER_INTERRUPT");
                }
            } finally {
                heldHandlerEnded.countDown();
            }
        }

        private void body(HttpExchange exchange) {
            try (exchange) {
                exchange.getRequestBody().close();
                exchange.getResponseHeaders().set("Content-Type", "application/json");
                exchange.sendResponseHeaders(200, 0);
                OutputStream output = exchange.getResponseBody();
                output.flush();
                try {
                    if (scenario == Scenario.DRIP) {
                        for (int index = 0; index < 10; index++) {
                            if (index > 0 && releaseProbe.await(800, TimeUnit.MILLISECONDS)) {
                                break;
                            }
                            output.write(' ');
                            output.flush();
                            preProbeBodyBytes.incrementAndGet();
                        }
                    }
                    if (scenario != Scenario.OVERSIZE && !releaseProbe.await(8, TimeUnit.SECONDS)) {
                        failure.set("PROBE_NOT_RELEASED");
                        return;
                    }
                    probeStarted.set(true);
                    byte[] chunk = new byte[16384];
                    for (int index = 0; index < 256; index++) {
                        output.write(chunk);
                        output.flush();
                    }
                } catch (IOException writeFailure) {
                    if (!closing.get() && !Thread.currentThread().isInterrupted()) {
                        writerFailedBeforeCleanup.set(true);
                    }
                }
            } catch (IOException headerOrCloseFailure) {
                if (!closing.get()) {
                    failure.set("HEADER_OR_CLOSE_FAILED");
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                if (!closing.get()) {
                    failure.set("UNEXPECTED_HANDLER_INTERRUPT");
                }
            } finally {
                handlerEnded.countDown();
            }
        }

        @Override public void close() throws InterruptedException {
            closing.set(true);
            releaseProbe.countDown();
            releaseHeldBody.countDown();
            server.stop(0);
            executor.shutdownNow();
            assertTrue(executor.awaitTermination(3, TimeUnit.SECONDS));
        }
    }
}
