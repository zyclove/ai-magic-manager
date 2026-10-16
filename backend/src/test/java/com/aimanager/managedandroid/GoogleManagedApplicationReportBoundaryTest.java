package com.aimanager.managedandroid;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.managedandroid.internal.GoogleManagedAndroidGateway;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.google.api.client.http.javanet.NetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/** 通过官方 SDK 与本地 HTTP 验证原始报告边界；不把这些事实直接升级为执行授权。 */
class GoogleManagedApplicationReportBoundaryTest {
  private static final ObjectMapper JSON = new ObjectMapper();
  private static final String APP = "example.learning.app";
  private static final String CERT = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  private HttpServer server;
  private ManagedAndroidGateway gateway;
  private volatile String response;
  private volatile int status = 200;
  private final AtomicInteger requests = new AtomicInteger();

  @BeforeEach
  void prepare() throws Exception {
    respond(device(List.of(application())));
    server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext("/", exchange -> {
      requests.incrementAndGet();
      byte[] bytes = response.getBytes(StandardCharsets.UTF_8);
      exchange.getResponseHeaders().set("Content-Type", "application/json");
      exchange.sendResponseHeaders(status, bytes.length);
      try (var output = exchange.getResponseBody()) {
        output.write(bytes);
      } finally {
        exchange.close();
      }
    });
    server.start();
    gateway = new GoogleManagedAndroidGateway(
        new AndroidManagement.Builder(new NetHttpTransport(), GsonFactory.getDefaultInstance(), request -> {})
            .setRootUrl("http://127.0.0.1:" + server.getAddress().getPort() + "/")
            .setApplicationName("local-application-report-boundary-test")
            .build());
  }

  @AfterEach
  void close() {
    if (server != null) server.stop(0);
  }

  @ParameterizedTest
  @ValueSource(strings = {"absent", "null", "empty", "different-app"})
  void missingTargetReportDoesNotMeanUninstalled(String change) throws Exception {
    var root = device(List.of());
    switch (change) {
      case "absent" -> root.remove("applicationReports");
      case "null" -> root.put("applicationReports", null);
      case "empty" -> { }
      case "different-app" -> root.put("applicationReports", List.of(Map.of("packageName", "example.other")));
      default -> throw new AssertionError(change);
    }
    respond(root);
    assertThat(gateway.readApplicationReport("e1", "d1", APP)).isEmpty();
    assertThat(requests.get()).isEqualTo(1);
  }

  @ParameterizedTest
  @ValueSource(strings = {"REMOVED", "APPLICATION_STATE_UNSPECIFIED"})
  void preservesExplicitProviderStateWithoutClaimingInstalled(String state) throws Exception {
    var app = application();
    app.put("state", state);
    respond(device(List.of(app)));
    assertThat(gateway.readApplicationReport("e1", "d1", APP).orElseThrow().applicationState())
        .isEqualTo(state);
  }

  @Test
  void missingMetadataRemainsUnknown() throws Exception {
    var app = application();
    app.remove("state");
    app.remove("signingKeyCerts");
    var root = device(List.of(app));
    root.remove("managementMode");
    root.remove("lastStatusReportTime");
    respond(root);
    var report = gateway.readApplicationReport("e1", "d1", APP).orElseThrow();
    assertThat(report.applicationState()).isNull();
    assertThat(report.managementMode()).isNull();
    assertThat(report.deviceReportedAt()).isNull();
    assertThat(report.signingCertificateSha256()).isEmpty();
  }

  @Test
  void legacySha1FingerprintsAreNotPromotedToSha256() throws Exception {
    var app = application();
    app.remove("signingKeyCerts");
    app.put("signingKeyCertFingerprints", List.of("ab".repeat(20)));
    respond(device(List.of(app)));
    assertThat(gateway.readApplicationReport("e1", "d1", APP).orElseThrow().signingCertificateSha256())
        .isEmpty();
  }

  @ParameterizedTest
  @ValueSource(strings = {"standard", "standard-unpadded", "url", "sdk"})
  void normalizesProtoJsonSha256Encodings(String encoding) throws Exception {
    byte[] bytes = new byte[32];
    Arrays.fill(bytes, (byte) 0xfb);
    String digest = switch (encoding) {
      case "standard" -> Base64.getEncoder().encodeToString(bytes);
      case "standard-unpadded" -> Base64.getEncoder().withoutPadding().encodeToString(bytes);
      case "url" -> Base64.getUrlEncoder().encodeToString(bytes);
      case "sdk" -> new com.google.api.services.androidmanagement.v1.model.ApplicationSigningKeyCert()
          .encodeSigningKeyCertFingerprintSha256(bytes).getSigningKeyCertFingerprintSha256();
      default -> throw new AssertionError(encoding);
    };
    var app = application();
    app.put("signingKeyCerts", List.of(cert(digest)));
    respond(device(List.of(app)));
    assertThat(gateway.readApplicationReport("e1", "d1", APP).orElseThrow().signingCertificateSha256())
        .containsExactly("fb".repeat(32));
  }

  @ParameterizedTest
  @ValueSource(strings = {"wrong-device", "missing-device", "duplicate-app", "null-app", "null-cert",
      "missing-digest", "short-digest", "bad-digest", "pad-bits", "duplicate-digest", "many-signers",
      "many-apps", "oversized", "malformed"})
  void rejectsAmbiguousMalformedOrUnboundedReports(String change) throws Exception {
    var app = application();
    var root = device(List.of(app));
    switch (change) {
      case "wrong-device" -> root.put("name", "enterprises/private-marker/devices/d1");
      case "missing-device" -> root.remove("name");
      case "duplicate-app" -> root.put("applicationReports", List.of(app, app));
      case "null-app" -> root.put("applicationReports", Collections.singletonList(null));
      case "null-cert" -> app.put("signingKeyCerts", Collections.singletonList(null));
      case "missing-digest" -> app.put("signingKeyCerts", List.of(Map.of()));
      case "short-digest" -> app.put("signingKeyCerts", List.of(cert("abcd")));
      case "bad-digest" -> app.put("signingKeyCerts", List.of(cert("#".repeat(44))));
      case "pad-bits" -> app.put("signingKeyCerts", List.of(cert("A".repeat(42) + "B=")));
      case "duplicate-digest" -> app.put("signingKeyCerts", List.of(cert(CERT), cert(CERT.substring(0, 43))));
      case "many-signers" -> {
        var certificates = new ArrayList<Map<String, String>>();
        for (int index = 0; index < 9; index++) {
          byte[] digest = new byte[32];
          digest[0] = (byte) index;
          certificates.add(cert(Base64.getEncoder().encodeToString(digest)));
        }
        app.put("signingKeyCerts", certificates);
      }
      case "many-apps" -> root.put("applicationReports", java.util.stream.IntStream.range(0, 3001)
          .mapToObj(index -> Map.of("packageName", "example.other.p" + index)).toList());
      case "oversized" -> root.put("unexpected", "private-marker".repeat(180_000));
      case "malformed" -> response = "{\"private-marker\":invalid-json";
      default -> throw new AssertionError(change);
    }
    if (!change.equals("malformed")) respond(root);
    assertThatThrownBy(() -> gateway.readApplicationReport("e1", "d1", APP))
        .isExactlyInstanceOf(IllegalStateException.class)
        .hasNoCause()
        .satisfies(error -> assertThat(error.getMessage()).doesNotContain("private-marker"));
  }

  @ParameterizedTest
  @ValueSource(strings = {"enterprise", "device", "package", "large-package"})
  void invalidIdentifiersNeverSendRequests(String change) {
    assertThatThrownBy(() -> gateway.readApplicationReport(
        change.equals("enterprise") ? "../bad" : "e1",
        change.equals("device") ? "../bad" : "d1",
        change.equals("package") ? "https://bad" : change.equals("large-package") ? "a." + "b".repeat(254) : APP))
        .isInstanceOf(IllegalArgumentException.class);
    assertThat(requests.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(ints = {403, 404})
  void errorBodiesAreNotExposedOrTreatedAsMissingReports(int httpStatus) {
    status = httpStatus;
    response = "private-marker-invalid-json".repeat(100_000);
    assertThatThrownBy(() -> gateway.readApplicationReport("e1", "d1", APP))
        .isExactlyInstanceOf(IllegalStateException.class)
        .hasMessageContaining("HTTP " + httpStatus)
        .hasNoCause()
        .satisfies(error -> assertThat(error.getMessage()).doesNotContain("private-marker"));
  }

  @Test
  void returnedSignerListCannotBeChangedByTheConsumer() {
    var report = gateway.readApplicationReport("e1", "d1", APP).orElseThrow();
    assertThatThrownBy(() -> report.signingCertificateSha256().clear())
        .isInstanceOf(UnsupportedOperationException.class);
    assertThat(report.signingCertificateSha256()).containsExactly("00".repeat(32));
  }

  private static Map<String, Object> device(List<?> applications) {
    return new HashMap<>(Map.of("name", "enterprises/e1/devices/d1", "managementMode", "DEVICE_OWNER",
        "lastStatusReportTime", "2026-10-16T04:00:00Z", "applicationReports", applications));
  }

  private static Map<String, Object> application() {
    return new HashMap<>(Map.of("packageName", APP, "state", "INSTALLED", "signingKeyCerts", List.of(cert(CERT))));
  }

  private static Map<String, String> cert(String encoded) {
    return Map.of("signingKeyCertFingerprintSha256", encoded);
  }

  private void respond(Map<String, Object> body) throws Exception {
    response = JSON.writeValueAsString(body);
  }
}
