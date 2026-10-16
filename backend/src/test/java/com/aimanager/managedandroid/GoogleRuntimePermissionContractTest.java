package com.aimanager.managedandroid;

import static org.assertj.core.api.Assertions.*;

import com.aimanager.managedandroid.ManagedAndroidGateway.PermissionDecision;
import com.aimanager.managedandroid.ManagedAndroidGateway.RuntimePermissionDecision;
import com.aimanager.managedandroid.internal.GoogleManagedAndroidGateway;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.google.api.client.http.javanet.NetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.zip.GZIPInputStream;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/** Actual generated SDK serialization and response parsing, against a loopback-only provider. */
class GoogleRuntimePermissionContractTest {
  private static final String POLICY = "enterprises/e1/policies/p1";
  private static final String PACKAGE = "org.example.reader";
  private static final String CAMERA = "android.permission.CAMERA";
  private static final String AUDIO = "android.permission.RECORD_AUDIO";
  private static final String DENY_CAMERA =
      "{\"permission\":\"android.permission.CAMERA\",\"policy\":\"DENY\"}";
  private final ObjectMapper json = new ObjectMapper();
  private final AtomicInteger reads = new AtomicInteger();
  private final AtomicInteger writes = new AtomicInteger();
  private final AtomicReference<String> writeBody = new AtomicReference<>();
  private final AtomicReference<String> writePath = new AtomicReference<>();
  private final AtomicReference<String> before =
      new AtomicReference<>(
          "{\"name\":\""
              + POLICY
              + "\",\"version\":\"7\",\"playStoreMode\":\"BLACKLIST\","
              + "\"applications\":[{\"packageName\":\""
              + PACKAGE
              + "\",\"installType\":\"FORCE_INSTALLED\",\"disabled\":false}]}");
  private final AtomicReference<String> response =
      new AtomicReference<>(
          updated(
              "[{\"packageName\":\""
                  + PACKAGE
                  + "\",\"permissionGrants\":["
                  + DENY_CAMERA
                  + "]}]"));
  private HttpServer server;
  private ManagedAndroidGateway gateway;

  @BeforeEach
  void setup() throws IOException {
    server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext("/", this::respond);
    server.start();
    gateway =
        new GoogleManagedAndroidGateway(
            new AndroidManagement.Builder(
                    new NetHttpTransport(), GsonFactory.getDefaultInstance(), request -> {})
                .setRootUrl("http://127.0.0.1:" + server.getAddress().getPort() + "/")
                .setApplicationName("local-runtime-permission-contract-test")
                .build());
  }

  @AfterEach
  void close() {
    server.stop(0);
  }

  @Test
  void changesOnlyTheSelectedAppsPermissionFieldWithCanonicalOrder() throws Exception {
    response.set(
        updated(
            "[{\"packageName\":\""
                + PACKAGE
                + "\",\"permissionGrants\":["
                + "{\"permission\":\""
                + AUDIO
                + "\",\"policy\":\"PROMPT\"},"
                + DENY_CAMERA
                + "]}]"));
    var receipt =
        gateway.putRuntimePermissionDecisions(
            "e1",
            "p1",
            PACKAGE,
            List.of(
                new RuntimePermissionDecision(AUDIO, PermissionDecision.PROMPT),
                new RuntimePermissionDecision(CAMERA, PermissionDecision.DENY)));
    assertThat(receipt.policyName()).isEqualTo(POLICY);
    assertThat(receipt.providerVersion()).isEqualTo(8);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isEqualTo(1);
    assertThat(writePath.get()).isEqualTo("/v1/" + POLICY + ":modifyPolicyApplications");
    JsonNode actual = json.readTree(writeBody.get());
    assertThat(actual)
        .isEqualTo(
            json.readTree(
                """
                {"changes":[{"updateMask":"permissionGrants","application":{
                  "packageName":"org.example.reader","permissionGrants":[
                    {"permission":"android.permission.CAMERA","policy":"DENY"},
                    {"permission":"android.permission.RECORD_AUDIO","policy":"PROMPT"}]}}]}
                """));
  }

  @ParameterizedTest
  @ValueSource(strings = {"", ",\"permissionGrants\":[]"})
  void emptyDecisionsExplicitlyClearTheFieldAndAcceptOmittedEmptyResponse(String field)
      throws Exception {
    response.set(updated("[{\"packageName\":\"" + PACKAGE + "\"" + field + "}]"));
    gateway.putRuntimePermissionDecisions("e1", "p1", PACKAGE, List.of());
    var change = json.readTree(writeBody.get()).path("changes").get(0);
    assertThat(change.path("updateMask").asText()).isEqualTo("permissionGrants");
    assertThat(change.path("application").path("permissionGrants").isArray()).isTrue();
    assertThat(change.path("application").path("permissionGrants").size()).isZero();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "[]",
        "[{\"packageName\":\"org.example.other\",\"permissionGrants\":[{\"permission\":\"android.permission.CAMERA\",\"policy\":\"DENY\"}]}]",
        "[{\"packageName\":\"org.example.reader\"}]",
        "[{\"packageName\":\"org.example.reader\",\"permissionGrants\":[]}]",
        "[{\"packageName\":\"org.example.reader\",\"permissionGrants\":[{\"permission\":\"android.permission.CAMERA\",\"policy\":\"GRANT\"}]}]",
        "[{\"packageName\":\"org.example.reader\",\"permissionGrants\":[{\"permission\":\"android.permission.CAMERA\"}]}]",
        "[{\"packageName\":\"org.example.reader\",\"permissionGrants\":[{\"permission\":\"android.permission.RECORD_AUDIO\",\"policy\":\"DENY\"}]}]",
        "[{\"packageName\":\"org.example.reader\",\"permissionGrants\":[{\"permission\":\"android.permission.CAMERA\",\"policy\":\"DENY\"},{\"permission\":\"android.permission.RECORD_AUDIO\",\"policy\":\"DENY\"}]}]",
        "[{\"packageName\":\"org.example.reader\",\"permissionGrants\":[{\"permission\":\"android.permission.CAMERA\",\"policy\":\"DENY\"},{\"permission\":\"android.permission.CAMERA\",\"policy\":\"DENY\"}]}]",
        "[{\"packageName\":\"org.example.reader\",\"permissionGrants\":[{\"permission\":\"android.permission.CAMERA\",\"policy\":\"DENY\"}]},{\"packageName\":\"org.example.reader\"}]"
      })
  void doesNotAcceptAnotherAppMissingDecisionOrContradictoryDecision(String applications) {
    response.set(updated(applications));
    assertThatThrownBy(this::denyCamera)
        .isInstanceOf(IllegalStateException.class)
        .hasMessageNotContaining(PACKAGE)
        .hasMessageNotContaining(CAMERA);
    assertThat(writes.get()).isEqualTo(1); // Never retry an uncertain provider write.
  }

  @Test
  void clearingCannotSucceedWhileTheProviderStillReportsAnExplicitDecision() {
    assertThatThrownBy(() -> gateway.putRuntimePermissionDecisions("e1", "p1", PACKAGE, List.of()))
        .isInstanceOf(IllegalStateException.class);
    assertThat(writes.get()).isEqualTo(1);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "{}",
        "{\"policy\":{}}",
        "{\"policy\":{\"name\":\"enterprises/other/policies/p1\",\"version\":\"8\"}}",
        "{\"policy\":{\"name\":\"enterprises/e1/policies/p1\",\"version\":\"0\"}}",
        "{\"policy\":{\"name\":\"enterprises/e1/policies/p1\"}}"
      })
  void rejectsMissingOrMismatchedPolicyReceipt(String body) {
    response.set(body);
    assertThatThrownBy(this::denyCamera).isInstanceOf(IllegalStateException.class);
    assertThat(writes.get()).isEqualTo(1);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "{}",
        "{\"name\":\"enterprises/e1/policies/p1\",\"playStoreMode\":\"WHITELIST\"}",
        "{\"name\":\"enterprises/e1/policies/p1\",\"playStoreMode\":\"BLACKLIST\",\"applications\":[]}",
        "{\"name\":\"enterprises/e1/policies/p1\",\"playStoreMode\":\"BLACKLIST\",\"installAppsDisabled\":true,\"applications\":[{\"packageName\":\"org.example.reader\"}]}"
      })
  void rejectsUnsafeOrMissingTargetBeforeAnyWrite(String policy) {
    before.set(policy);
    assertThatThrownBy(this::denyCamera).isInstanceOf(IllegalStateException.class);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isZero();
  }

  @Test
  void rejectsInvalidDuplicateAndRecoveryAppDenialsBeforeProviderAccess() {
    assertThatThrownBy(
            () ->
                gateway.putRuntimePermissionDecisions(
                    "e1",
                    "p1",
                    PACKAGE,
                    List.of(
                        new RuntimePermissionDecision(
                            "android.permission.SYSTEM_ALERT_WINDOW", PermissionDecision.DENY))))
        .isInstanceOf(IllegalArgumentException.class);
    var duplicate = new RuntimePermissionDecision(CAMERA, PermissionDecision.DENY);
    assertThatThrownBy(
            () ->
                gateway.putRuntimePermissionDecisions(
                    "e1", "p1", PACKAGE, List.of(duplicate, duplicate)))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(
            () ->
                gateway.putRuntimePermissionDecisions(
                    "e1", "p1", "com.android.settings", List.of(duplicate)))
        .isInstanceOf(IllegalArgumentException.class);
    assertThat(reads.get()).isZero();
    assertThat(writes.get()).isZero();
  }

  private void denyCamera() {
    gateway.putRuntimePermissionDecisions(
        "e1",
        "p1",
        PACKAGE,
        List.of(new RuntimePermissionDecision(CAMERA, PermissionDecision.DENY)));
  }

  private static String updated(String applications) {
    return "{\"policy\":{\"name\":\""
        + POLICY
        + "\",\"version\":\"8\",\"applications\":"
        + applications
        + "}}";
  }

  private void respond(HttpExchange exchange) throws IOException {
    String body;
    if (exchange.getRequestMethod().equals("GET")) {
      reads.incrementAndGet();
      body = before.get();
    } else {
      writes.incrementAndGet();
      writePath.set(exchange.getRequestURI().getPath());
      // The generated client compresses POST bodies by default; inspect the real decoded payload.
      try (var input =
          "gzip".equalsIgnoreCase(exchange.getRequestHeaders().getFirst("Content-Encoding"))
              ? new GZIPInputStream(exchange.getRequestBody())
              : exchange.getRequestBody()) {
        writeBody.set(new String(input.readAllBytes(), StandardCharsets.UTF_8));
      }
      body = response.get();
    }
    byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
    exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
    exchange.sendResponseHeaders(200, bytes.length);
    try (var output = exchange.getResponseBody()) {
      output.write(bytes);
    }
  }
}
