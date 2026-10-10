package com.aimanager.managedandroid;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.managedandroid.ManagedAndroidGateway.AppControl;
import com.aimanager.managedandroid.ManagedAndroidGateway.AppRestriction;
import com.aimanager.managedandroid.ManagedAndroidGateway.ApplyState;
import com.aimanager.managedandroid.internal.GoogleManagedAndroidGateway;
import com.aimanager.managedandroid.internal.UnavailableManagedAndroidGateway;
import com.google.api.client.http.javanet.NetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;
import java.util.zip.GZIPInputStream;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * Local wire contract check against the official generated client; no Google project or secrets are
 * used.
 */
class GoogleManagedAndroidGatewayTest {
  private HttpServer server;
  private ManagedAndroidGateway gateway;
  private final AtomicReference<String> method = new AtomicReference<>();
  private final AtomicReference<String> path = new AtomicReference<>();
  private final AtomicReference<String> body = new AtomicReference<>();
  private final AtomicReference<String> methodOverride = new AtomicReference<>();
  private final AtomicReference<String> deviceResponse =
      new AtomicReference<>(
          "{\"name\":\"enterprises/e1/devices/d1\",\"policyName\":\"enterprises/e1/policies/p1\",\"managementMode\":\"DEVICE_OWNER\"}");

  @BeforeEach
  void setUp() throws IOException {
    server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext("/", this::respond);
    server.start();
    AndroidManagement client =
        new AndroidManagement.Builder(
                new NetHttpTransport(), GsonFactory.getDefaultInstance(), request -> {})
            .setRootUrl("http://127.0.0.1:" + server.getAddress().getPort() + "/")
            .setApplicationName("local-contract-test")
            .build();
    gateway = new GoogleManagedAndroidGateway(client);
  }

  @AfterEach
  void tearDown() {
    server.stop(0);
  }

  @Test
  void policyPatchTouchesOnlyApplicationsAndRejectsUnsafeInputs() {
    var receipt =
        gateway.putApplicationPolicy(
            "e1",
            "p1",
            List.of(
                new AppRestriction("com.example.reader", AppControl.ALLOW),
                new AppRestriction("com.example.game", AppControl.BLOCK_LAUNCH),
                new AppRestriction("com.example.store", AppControl.BLOCK_INSTALL)));
    assertThat(receipt.policyName()).isEqualTo("enterprises/e1/policies/p1");
    // The official client tunnels PATCH over POST when its transport does not support PATCH.
    assertThat(method.get()).isEqualTo("POST");
    assertThat(methodOverride.get()).isEqualTo("PATCH");
    assertThat(path.get())
        .contains("enterprises/e1/policies/p1")
        .contains("updateMask=applications");
    assertThat(body.get()).contains("\"disabled\":true").contains("\"installType\":\"BLOCKED\"");
    assertThatThrownBy(() -> gateway.putApplicationPolicy("../evil", "p1", List.of()))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(
            () ->
                gateway.putApplicationPolicy(
                    "e1",
                    "p1",
                    List.of(
                        new AppRestriction("com.example.reader", AppControl.ALLOW),
                        new AppRestriction("com.example.reader", AppControl.BLOCK_LAUNCH))))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void tokenIsOneTimeShortLivedAndRedacted() {
    var token = gateway.createEnrollmentToken("e1", "p1", Duration.ofMinutes(15));
    assertThat(method.get()).isEqualTo("POST");
    assertThat(body.get())
        .contains("\"oneTimeOnly\":true")
        .contains("\"duration\":\"900s\"")
        .contains("enterprises/e1/policies/p1");
    assertThat(token.value()).isEqualTo("local-secret");
    assertThat(token.toString()).doesNotContain("local-secret");
    assertThatThrownBy(() -> gateway.createEnrollmentToken("e1", "p1", Duration.ofHours(2)))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void assignmentIsOnlyRequestedUntilProviderReportsApplication() {
    var assignment = gateway.assignPolicy("e1", "d1", "p1");
    assertThat(assignment.requestedPolicyName()).isEqualTo("enterprises/e1/policies/p1");
    assertThat(body.get()).contains("\"policyName\":\"enterprises/e1/policies/p1\"");
    var state = gateway.readDeviceState("e1", "d1", "p1", 7);
    assertThat(state.state()).isEqualTo(ApplyState.PENDING);
    assertThat(state.appliedPolicyName()).isNull();
    deviceResponse.set(
        "{\"name\":\"enterprises/e1/devices/d1\",\"managementMode\":\"DEVICE_OWNER\",\"policyName\":\"enterprises/e1/policies/p1\",\"appliedPolicyName\":\"enterprises/e1/policies/p1\",\"appliedPolicyVersion\":\"6\",\"policyCompliant\":true}");
    assertThat(gateway.readDeviceState("e1", "d1", "p1", 7).state()).isEqualTo(ApplyState.PENDING);
    deviceResponse.set(
        "{\"name\":\"enterprises/e1/devices/d1\",\"managementMode\":\"DEVICE_OWNER\",\"policyName\":\"enterprises/e1/policies/p1\",\"appliedPolicyName\":\"enterprises/e1/policies/p1\",\"appliedPolicyVersion\":\"7\",\"policyCompliant\":true}");
    assertThat(gateway.readDeviceState("e1", "d1", "p1", 7).state()).isEqualTo(ApplyState.APPLIED);
    deviceResponse.set(
        "{\"name\":\"enterprises/e1/devices/d1\",\"managementMode\":\"DEVICE_OWNER\",\"policyName\":\"enterprises/e1/policies/p1\",\"appliedPolicyName\":\"enterprises/e1/policies/p1\",\"appliedPolicyVersion\":\"7\",\"policyCompliant\":false,\"nonComplianceDetails\":[{\"nonComplianceReason\":\"APP_NOT_INSTALLED\"}]}");
    assertThat(gateway.readDeviceState("e1", "d1", "p1", 7).state())
        .isEqualTo(ApplyState.NON_COMPLIANT);
    deviceResponse.set(
        "{\"name\":\"enterprises/e1/devices/d1\",\"policyName\":\"enterprises/e1/policies/p1\",\"appliedPolicyName\":\"enterprises/e1/policies/p1\",\"appliedPolicyVersion\":\"7\",\"policyCompliant\":true}");
    assertThat(gateway.readDeviceState("e1", "d1", "p1", 7).state()).isEqualTo(ApplyState.PENDING);
  }

  @Test
  void disabledGatewayFailsClosed() {
    ManagedAndroidGateway disabled = new UnavailableManagedAndroidGateway();
    assertThat(disabled.available()).isFalse();
    assertThatThrownBy(() -> disabled.readDeviceState("e1", "d1", "p1", 7))
        .isInstanceOf(ManagedAndroidUnavailableException.class);
  }

  private void respond(HttpExchange exchange) throws IOException {
    method.set(exchange.getRequestMethod());
    path.set(exchange.getRequestURI().toString());
    methodOverride.set(exchange.getRequestHeaders().getFirst("X-HTTP-Method-Override"));
    var raw = exchange.getRequestBody();
    var payload =
        "gzip".equalsIgnoreCase(exchange.getRequestHeaders().getFirst("Content-Encoding"))
            ? new GZIPInputStream(raw)
            : raw;
    body.set(new String(payload.readAllBytes(), StandardCharsets.UTF_8));
    String response;
    if (path.get().contains("enrollmentTokens")) {
      response =
          "{\"name\":\"enterprises/e1/enrollmentTokens/t1\",\"value\":\"local-secret\",\"expirationTimestamp\":\"2026-10-10T00:15:00Z\"}";
    } else if (path.get().contains("/devices/")) {
      response = deviceResponse.get();
    } else {
      response = "{\"name\":\"enterprises/e1/policies/p1\",\"version\":\"7\"}";
    }
    byte[] bytes = response.getBytes(StandardCharsets.UTF_8);
    exchange.getResponseHeaders().set("Content-Type", "application/json");
    exchange.sendResponseHeaders(200, bytes.length);
    try (var output = exchange.getResponseBody()) {
      output.write(bytes);
    }
  }
}
