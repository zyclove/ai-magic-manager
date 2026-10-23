package com.aimanager.identity;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.HttpTimeoutException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.CancellationException;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Flow;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.Supplier;

/** 借用工厂客户端，只拥有本次交换的期限、正文与取消句柄。 */
final class ProviderHttpTransport {
    private static final long REQUEST_NANOS = TimeUnit.SECONDS.toNanos(5);
    private static final int MAX_RESPONSE_BYTES = 65536;

    private ProviderHttpTransport() { }

    static AliyunSms.Response send(HttpClient client, Supplier<HttpRequest> requestFactory) throws IOException {
        Objects.requireNonNull(client);
        Objects.requireNonNull(requestFactory);
        requireNotInterrupted();
        long started = System.nanoTime();
        LimitedBodySubscriber body = new LimitedBodySubscriber();
        CompletableFuture<HttpResponse<byte[]>> pending = null;
        boolean succeeded = false;
        try {
            HttpRequest request = Objects.requireNonNull(requestFactory.get());
            requireNotInterrupted();
            remainingNanos(started);
            pending = client.sendAsync(request, body::receiveHeaders);
            requireNotInterrupted();
            HttpResponse<byte[]> response = pending.get(remainingNanos(started), TimeUnit.NANOSECONDS);
            requireNotInterrupted();
            remainingNanos(started);
            AliyunSms.Response result = new AliyunSms.Response(response.statusCode(),
                    new String(response.body(), StandardCharsets.UTF_8));
            remainingNanos(started);
            succeeded = true;
            return result;
        } catch (TimeoutException expired) {
            throw new HttpTimeoutException("Provider request exceeded its total deadline");
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IOException("Provider request interrupted", interrupted);
        } catch (ExecutionException failed) {
            if (failed.getCause() instanceof IOException ioFailure) {
                throw ioFailure;
            }
            throw new IOException("Provider request failed", failed.getCause());
        } catch (CancellationException cancelled) {
            throw new IOException("Provider request cancelled", cancelled);
        } finally {
            if (!succeeded) {
                // 先取消仍未完成的原 Future；先完成正文异常会令底层取消句柄失效。
                try {
                    if (pending != null) {
                        pending.cancel(true);
                    }
                } finally {
                    body.abort(new IOException("Provider exchange closed"));
                }
            }
        }
    }

    private static void requireNotInterrupted() throws IOException {
        if (Thread.currentThread().isInterrupted()) {
            throw new IOException("Provider request interrupted");
        }
    }

    private static long remainingNanos(long started) throws HttpTimeoutException {
        long remaining = REQUEST_NANOS - (System.nanoTime() - started);
        if (remaining <= 0) {
            throw new HttpTimeoutException("Provider request exceeded its total deadline");
        }
        return remaining;
    }

    /** 状态在锁内只结束一次；上游回调及 Future 完成均在锁外执行。 */
    private static final class LimitedBodySubscriber implements HttpResponse.BodySubscriber<byte[]> {
        private final ByteArrayOutputStream received = new ByteArrayOutputStream(1024);
        private final CompletableFuture<byte[]> completed = new CompletableFuture<>();
        private Flow.Subscription subscription;
        private boolean terminal;

        HttpResponse.BodySubscriber<byte[]> receiveHeaders(HttpResponse.ResponseInfo response) {
            try {
                long declared = response.headers().firstValueAsLong("Content-Length").orElse(0);
                if (declared < 0 || declared > MAX_RESPONSE_BYTES) {
                    abort(new IOException("Provider response exceeds the byte limit"));
                }
            } catch (NumberFormatException malformed) {
                abort(new IOException("Provider response has an invalid length"));
            }
            return this;
        }

        @Override public CompletionStage<byte[]> getBody() {
            return completed;
        }

        @Override public void onSubscribe(Flow.Subscription incoming) {
            Objects.requireNonNull(incoming);
            boolean reject;
            synchronized (this) {
                reject = terminal || subscription != null;
                if (!reject) {
                    subscription = incoming;
                }
            }
            if (reject) {
                incoming.cancel();
            } else {
                incoming.request(1);
            }
        }

        @Override public void onNext(List<ByteBuffer> buffers) {
            Flow.Subscription upstream;
            IOException failure = null;
            synchronized (this) {
                if (terminal) {
                    return;
                }
                upstream = subscription;
                for (ByteBuffer buffer : buffers) {
                    if (buffer.remaining() > MAX_RESPONSE_BYTES - received.size()) {
                        terminal = true;
                        received.reset();
                        failure = new IOException("Provider response exceeds the byte limit");
                        break;
                    }
                    byte[] chunk = new byte[buffer.remaining()];
                    buffer.get(chunk);
                    received.writeBytes(chunk);
                }
            }
            if (failure != null) {
                finishFailure(failure, upstream);
            } else if (upstream != null) {
                upstream.request(1);
            }
        }

        @Override public void onError(Throwable failure) {
            abort(Objects.requireNonNull(failure));
        }

        @Override public void onComplete() {
            byte[] value;
            synchronized (this) {
                if (terminal) {
                    return;
                }
                terminal = true;
                value = received.toByteArray();
                received.reset();
            }
            completed.complete(value);
        }

        void abort(Throwable failure) {
            Flow.Subscription upstream;
            synchronized (this) {
                if (terminal) {
                    return;
                }
                terminal = true;
                received.reset();
                upstream = subscription;
            }
            finishFailure(failure, upstream);
        }

        private void finishFailure(Throwable failure, Flow.Subscription upstream) {
            try {
                if (upstream != null) {
                    upstream.cancel();
                }
            } finally {
                completed.completeExceptionally(failure);
            }
        }
    }
}
