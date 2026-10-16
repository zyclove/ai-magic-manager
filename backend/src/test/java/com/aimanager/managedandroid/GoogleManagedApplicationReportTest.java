package com.aimanager.managedandroid;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.managedandroid.internal.GoogleManagedAndroidGateway;
import com.aimanager.managedandroid.internal.UnavailableManagedAndroidGateway;
import com.google.api.client.http.javanet.NetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/** 官方 SDK 通过本地 HTTP 读取真实 JSON；不模拟客户端解析，也不连接商业提供方。 */
class GoogleManagedApplicationReportTest {
  private static final String APP = "example.learning.app";
  private HttpServer server;
  private ManagedAndroidGateway gateway;
  private final AtomicReference<String> path = new AtomicReference<>();

  @BeforeEach
  void prepare() throws Exception {
    server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext("/", exchange -> {
      path.set(exchange.getRequestURI().toString());
      byte[] bytes = """
          {"name":"enterprises/e1/devices/d1","managementMode":"DEVICE_OWNER",
           "lastStatusReportTime":"2026-10-16T04:00:00Z",
           "applicationReports":[{"packageName":"example.learning.app","state":"INSTALLED",
             "signingKeyCerts":[{"signingKeyCertFingerprintSha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}]}]}
          """.getBytes(StandardCharsets.UTF_8);
      exchange.getResponseHeaders().set("Content-Type", "application/json");
      exchange.sendResponseHeaders(200, bytes.length);
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
            .setApplicationName("local-application-report-test")
            .build());
  }

  @AfterEach
  void close() {
    if (server != null) server.stop(0);
  }

  @Test
  void readsInstalledApplicationWithoutBindingFeedback() {
    var captured = new AtomicReference<ManagedApplicationReport>();
    assertThatCode(() -> captured.set(gateway.readApplicationReport("e1", "d1", APP).orElseThrow()))
        .doesNotThrowAnyException();
    var report = captured.get();
    assertThat(report.deviceName()).isEqualTo("enterprises/e1/devices/d1");
    assertThat(report.packageName()).isEqualTo(APP);
    assertThat(report.applicationState()).isEqualTo("INSTALLED");
    assertThat(report.signingCertificateSha256()).containsExactly("00".repeat(32));
    assertThat(report.deviceReportedAt()).isEqualTo("2026-10-16T04:00:00Z");
    assertThat(gateway.supportsApplicationReports()).isTrue();
    assertThat(URLDecoder.decode(path.get(), StandardCharsets.UTF_8))
        .startsWith("/v1/enterprises/e1/devices/d1?fields=")
        .contains("signingKeyCerts", "lastStatusReportTime")
        .doesNotContain("keyedAppStates", "enrollmentToken", "displayName", "events");
    assertThat(report.toString()).doesNotContain(APP, "enterprises/e1");
  }

  @Test
  void unconfiguredConnectorDoesNotClaimToReadApplicationReports() {
    var unavailable = new UnavailableManagedAndroidGateway();
    assertThat(unavailable.supportsApplicationReports()).isFalse();
    assertThatThrownBy(() -> unavailable.readApplicationReport("e1", "d1", APP))
        .isInstanceOf(ManagedAndroidUnavailableException.class);
  }
}
