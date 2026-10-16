package com.aimanager.managedandroid;

import static org.assertj.core.api.Assertions.*;

import com.aimanager.managedandroid.ManagedAndroidGateway.ApplyState;
import com.aimanager.managedandroid.internal.GoogleManagedAndroidGateway;
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
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/** Checks the actual generated SDK response path using only a loopback HTTP server. */
class GoogleManagedPolicyReceiptTest {
  private HttpServer server;
  private ManagedAndroidGateway gateway;
  private final AtomicInteger writes = new AtomicInteger();
  private final AtomicReference<String> policy =
      new AtomicReference<>("{\"name\":\"enterprises/e1/policies/p1\",\"version\":\"7\"}");
  private final AtomicReference<String> device =
      new AtomicReference<>(
          "{\"name\":\"enterprises/e1/devices/d1\",\"policyName\":\"enterprises/e1/policies/p1\"}");

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
                .setApplicationName("local-receipt-contract-test")
                .build());
  }

  @AfterEach
  void close() {
    server.stop(0);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "{\"name\":\"enterprises/other/policies/p1\",\"version\":\"7\"}",
        "{\"name\":\"enterprises/e1/policies/other\",\"version\":\"7\"}",
        "{\"version\":\"7\"}",
        "{\"name\":\"enterprises/e1/policies/p1\",\"version\":\"0\"}",
        "{\"name\":\"enterprises/e1/policies/p1\"}",
        "{}"
      })
  void policyWriteMustReturnTheExactResourceAndPositiveVersion(String response) {
    policy.set(response);
    assertThatThrownBy(() -> gateway.putApplicationPolicy("e1", "p1", List.of()))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageNotContaining("enterprises/other")
        .hasMessageNotContaining(response);
    assertThat(writes.get())
        .isEqualTo(1); // An uncertain result never triggers an automatic write retry.
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "{\"name\":\"enterprises/other/devices/d1\",\"policyName\":\"enterprises/e1/policies/p1\"}",
        "{\"name\":\"enterprises/e1/devices/other\",\"policyName\":\"enterprises/e1/policies/p1\"}",
        "{\"name\":\"enterprises/e1/devices/d1\",\"policyName\":\"enterprises/other/policies/p1\"}",
        "{\"name\":\"enterprises/e1/devices/d1\",\"policyName\":\"enterprises/e1/policies/other\"}",
        "{\"name\":\"enterprises/e1/devices/d1\"}",
        "{\"policyName\":\"enterprises/e1/policies/p1\"}",
        "{}"
      })
  void assignmentMustReturnTheExactDeviceAndRequestedPolicy(String response) {
    device.set(response);
    assertThatThrownBy(() -> gateway.assignPolicy("e1", "d1", "p1"))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageNotContaining("enterprises/other")
        .hasMessageNotContaining(response);
    assertThat(writes.get()).isEqualTo(1);
  }

  @Test
  void matchingWriteReceiptsAreNotAppliedDeviceEvidence() {
    var receipt = gateway.putApplicationPolicy("e1", "p1", List.of());
    assertThat(receipt.policyName()).isEqualTo("enterprises/e1/policies/p1");
    assertThat(receipt.providerVersion()).isEqualTo(7);
    var assignment = gateway.assignPolicy("e1", "d1", "p1");
    assertThat(assignment.deviceName()).isEqualTo("enterprises/e1/devices/d1");
    assertThat(assignment.requestedPolicyName()).isEqualTo("enterprises/e1/policies/p1");
    assertThat(gateway.readDeviceState("e1", "d1", "p1", 7).state()).isEqualTo(ApplyState.PENDING);
    assertThat(writes.get()).isEqualTo(2);
  }

  @ParameterizedTest
  @ValueSource(longs = {1, 6, 8, Long.MAX_VALUE})
  void anotherAppliedVersionCannotProveThisPublication(long version) {
    device.set(applied(version, ""));
    var evidence = gateway.readDeviceState("e1", "d1", "p1", 7);
    assertThat(evidence.state()).isEqualTo(ApplyState.PENDING);
    assertThat(evidence.appliedPolicyVersion()).isEqualTo(version);
    assertThat(writes.get()).isZero();
  }

  @Test
  void exactVersionAndComplianceCanBeReportedApplied() {
    device.set(applied(7, ""));
    assertThat(gateway.readDeviceState("e1", "d1", "p1", 7).state()).isEqualTo(ApplyState.APPLIED);
  }

  @Test
  void nonComplianceDetailsCannotBeReportedAsApplied() {
    device.set(
        applied(7, ",\"nonComplianceDetails\":[{\"nonComplianceReason\":\"APP_NOT_INSTALLED\"}]"));
    var evidence = gateway.readDeviceState("e1", "d1", "p1", 7);
    assertThat(evidence.state()).isEqualTo(ApplyState.NON_COMPLIANT);
    assertThat(evidence.nonComplianceReasons()).containsExactly("APP_NOT_INSTALLED");
  }

  private String applied(long version, String extra) {
    return "{\"name\":\"enterprises/e1/devices/d1\",\"policyName\":\"enterprises/e1/policies/p1\","
               + "\"appliedPolicyName\":\"enterprises/e1/policies/p1\",\"managementMode\":\"DEVICE_OWNER\","
               + "\"policyCompliant\":true,\"appliedPolicyVersion\":\""
        + version
        + "\""
        + extra
        + "}";
  }

  private void respond(HttpExchange exchange) throws IOException {
    exchange.getRequestBody().readAllBytes();
    boolean read = exchange.getRequestMethod().equals("GET");
    if (!read) writes.incrementAndGet();
    String response =
        exchange.getRequestURI().getPath().contains("/devices/")
            ? device.get()
            : read
                ? "{\"name\":\"enterprises/e1/policies/p1\",\"version\":\"6\",\"playStoreMode\":\"BLACKLIST\"}"
                : policy.get();
    byte[] bytes = response.getBytes(StandardCharsets.UTF_8);
    exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
    exchange.sendResponseHeaders(200, bytes.length);
    try (var output = exchange.getResponseBody()) {
      output.write(bytes);
    }
  }
}
