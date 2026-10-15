package com.aimanager.managedandroid;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.managedandroid.internal.GoogleManagedAndroidGateway;
import com.aimanager.managedandroid.internal.UnavailableManagedAndroidGateway;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.google.api.client.http.javanet.NetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/** 本地 HTTP 驱动现有官方生成客户端，检查字段投影、真实 JSON 类型和异常脱敏。 */
class GoogleManagedAgentEvidenceTest {
  private static final ObjectMapper JSON = new ObjectMapper();
  private static final String APP = "com.aimanager.child";
  private static final String CERT = Base64.getEncoder().encodeToString(new byte[32]);
  private HttpServer server;
  private ManagedAndroidGateway gateway;
  private final AtomicReference<String> response = new AtomicReference<>();
  private final AtomicReference<String> path = new AtomicReference<>();
  private int status = 200;

  @BeforeEach
  void prepare() throws Exception {
    response.set(JSON.writeValueAsString(device(List.of(app()))));
    server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext(
        "/",
        exchange -> {
          path.set(exchange.getRequestURI().toString());
          byte[] bytes = response.get().getBytes(StandardCharsets.UTF_8);
          exchange.getResponseHeaders().set("Content-Type", "application/json");
          exchange.sendResponseHeaders(status, bytes.length);
          try (var output = exchange.getResponseBody()) {
            output.write(bytes);
          }
        });
    server.start();
    gateway =
        new GoogleManagedAndroidGateway(
            new AndroidManagement.Builder(
                    new NetHttpTransport(), GsonFactory.getDefaultInstance(), request -> {})
                .setRootUrl("http://127.0.0.1:" + server.getAddress().getPort() + "/")
                .setApplicationName("local-managed-agent-proof-test")
                .build());
  }

  @AfterEach
  void close() {
    server.stop(0);
  }

  private Map<String, Object> feedback() {
    return new HashMap<>(
        Map.of(
            "key",
            ManagedAgentEvidence.FEEDBACK_KEY,
            "data",
            "local-private-proof",
            "severity",
            "INFO",
            "lastUpdateTime",
            "2026-10-15T10:00:00Z"));
  }

  private Map<String, Object> app() {
    return new HashMap<>(
        Map.of(
            "packageName",
            APP,
            "state",
            "INSTALLED",
            "signingKeyCerts",
            List.of(Map.of("signingKeyCertFingerprintSha256", CERT)),
            "keyedAppStates",
            List.of(feedback())));
  }

  private Map<String, Object> device(List<?> applications) {
    return new HashMap<>(
        Map.of(
            "name",
            "enterprises/e1/devices/d1",
            "managementMode",
            "DEVICE_OWNER",
            "lastStatusReportTime",
            "2026-10-15T10:00:01Z",
            "applicationReports",
            applications));
  }

  @Test
  void readsExactApplicationAndModernSha256ThroughOfficialClient() {
    var evidence = gateway.readAgentEvidence("e1", "d1", APP).orElseThrow();
    assertThat(evidence.signingCertificateSha256()).containsExactly("00".repeat(32));
    assertThat(evidence.proof()).isEqualTo("local-private-proof");
    assertThat(evidence.deviceReportedAt()).isEqualTo("2026-10-15T10:00:01Z");
    assertThat(evidence.toString())
        .doesNotContain("local-private-proof", "enterprises/e1/devices/d1");
    String query = URLDecoder.decode(path.get(), StandardCharsets.UTF_8);
    assertThat(query)
        .contains("/devices/d1?fields=", "signingKeyCerts", "lastStatusReportTime")
        .doesNotContain("enrollmentTokenData", "message", "signingKeyCertFingerprints");
  }

  @Test
  void acceptsTheOfficialSdkBytesEncodingAndBothProtoJsonAlphabets() throws Exception {
    byte[] fingerprint = new byte[32];
    java.util.Arrays.fill(fingerprint, (byte) 0xfb);
    var sdkCert =
        new com.google.api.services.androidmanagement.v1.model.ApplicationSigningKeyCert()
            .encodeSigningKeyCertFingerprintSha256(fingerprint);
    for (String value :
        List.of(
            sdkCert.getSigningKeyCertFingerprintSha256(),
            Base64.getEncoder().encodeToString(fingerprint),
            Base64.getEncoder().withoutPadding().encodeToString(fingerprint),
            Base64.getUrlEncoder().encodeToString(fingerprint))) {
      var application = app();
      application.put("signingKeyCerts", List.of(Map.of("signingKeyCertFingerprintSha256", value)));
      response.set(JSON.writeValueAsString(device(List.of(application))));
      assertThat(
              gateway.readAgentEvidence("e1", "d1", APP).orElseThrow().signingCertificateSha256())
          .containsExactly("fb".repeat(32));
    }
  }

  @Test
  void missingAppOrFeedbackIsPendingNotSuccess() throws Exception {
    response.set(JSON.writeValueAsString(device(List.of())));
    assertThat(gateway.readAgentEvidence("e1", "d1", APP)).isEmpty();
    var application = app();
    application.remove("keyedAppStates");
    response.set(JSON.writeValueAsString(device(List.of(application))));
    assertThat(gateway.readAgentEvidence("e1", "d1", APP)).isEmpty();
  }

  @Test
  void legacySha1IsNeverPromotedToSha256Trust() throws Exception {
    var application = app();
    application.remove("signingKeyCerts");
    application.put("signingKeyCertFingerprints", List.of("ab".repeat(20)));
    response.set(JSON.writeValueAsString(device(List.of(application))));
    assertThat(gateway.readAgentEvidence("e1", "d1", APP).orElseThrow().signingCertificateSha256())
        .isEmpty();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "device",
        "duplicate-app",
        "duplicate-key",
        "bad-cert",
        "short-cert",
        "duplicate-cert",
        "large-proof",
        "null-proof",
        "many-apps",
        "oversized-body",
        "malformed"
      })
  void rejectsAmbiguousMalformedAndUnboundedResponses(String change) throws Exception {
    var application = app();
    var root = device(List.of(application));
    switch (change) {
      case "device" -> root.put("name", "enterprises/e2/devices/d1");
      case "duplicate-app" -> root.put("applicationReports", List.of(application, application));
      case "duplicate-key" -> application.put("keyedAppStates", List.of(feedback(), feedback()));
      case "bad-cert" ->
          application.put(
              "signingKeyCerts",
              List.of(Map.of("signingKeyCertFingerprintSha256", "#".repeat(44))));
      case "short-cert" ->
          application.put(
              "signingKeyCerts", List.of(Map.of("signingKeyCertFingerprintSha256", "abcd")));
      case "duplicate-cert" ->
          application.put(
              "signingKeyCerts",
              List.of(
                  Map.of("signingKeyCertFingerprintSha256", CERT),
                  Map.of("signingKeyCertFingerprintSha256", CERT)));
      case "large-proof", "null-proof" -> {
        var state = feedback();
        state.put("data", change.equals("large-proof") ? "private".repeat(200) : null);
        application.put("keyedAppStates", List.of(state));
      }
      case "many-apps" ->
          root.put(
              "applicationReports",
              java.util.Collections.nCopies(3001, Map.of("packageName", "com.other.app")));
      case "oversized-body" -> root.put("unexpected", "private".repeat(350_000));
      case "malformed" -> {
        response.set("{\"private\":broken-json");
      }
      default -> throw new AssertionError(change);
    }
    if (!change.equals("malformed")) response.set(JSON.writeValueAsString(root));
    assertThatThrownBy(() -> gateway.readAgentEvidence("e1", "d1", APP))
        .isInstanceOf(IllegalStateException.class)
        .hasNoCause()
        .satisfies(error -> assertThat(error.getMessage()).doesNotContain("private"));
  }

  @Test
  void inputValidationDoesNotSendNetworkRequest() {
    assertThatThrownBy(() -> gateway.readAgentEvidence("../bad", "d1", APP))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> gateway.readAgentEvidence("e1", "d1", "https://bad"))
        .isInstanceOf(IllegalArgumentException.class);
    assertThat(path.get()).isNull();
  }

  @Test
  void providerFailureAndUnavailableConnectorRemainClosed() {
    status = 403;
    response.set("{\"error\":{\"message\":\"private-marker\"}}");
    assertThatThrownBy(() -> gateway.readAgentEvidence("e1", "d1", APP))
        .isInstanceOf(IllegalStateException.class)
        .hasNoCause()
        .satisfies(error -> assertThat(error.getMessage()).doesNotContain("private-marker"));
    assertThatThrownBy(
            () -> new UnavailableManagedAndroidGateway().readAgentEvidence("e1", "d1", APP))
        .isInstanceOf(ManagedAndroidUnavailableException.class);
  }

  @Test
  void malformedLargeErrorResponseIsNotDecodedOrEchoed() {
    status = 403;
    response.set("private-error-body-not-json".repeat(100_000));
    assertThatThrownBy(() -> gateway.readAgentEvidence("e1", "d1", APP))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageContaining("HTTP 403")
        .hasNoCause()
        .satisfies(error -> assertThat(error.getMessage()).doesNotContain("private-error"));
  }
}
