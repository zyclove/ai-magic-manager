package com.aimanager.managedandroid;

import static org.assertj.core.api.Assertions.assertThat;

import com.aimanager.managedandroid.internal.GoogleManagedAndroidGateway;
import com.google.api.client.http.javanet.NetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Set;
import org.junit.jupiter.api.Test;

/** 串联实际 SDK JSON 读取与作用域核验；不模拟提供方客户端解析，不访问外部设备。 */
class ManagedApplicationIdentitySdkJourneyTest {
  @Test
  void officialSdkReportFeedsCurrentRegistrationVerifierWithoutBindingFeedback() throws Exception {
    var server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext("/", exchange -> {
      byte[] body = """
          {"name":"enterprises/e1/devices/d1","managementMode":"DEVICE_OWNER",
           "lastStatusReportTime":"2026-10-16T07:59:30Z",
           "applicationReports":[{"packageName":"example.learning.app","state":"INSTALLED",
             "signingKeyCerts":[{"signingKeyCertFingerprintSha256":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}]}]}
          """.getBytes(StandardCharsets.UTF_8);
      exchange.getResponseHeaders().set("Content-Type", "application/json");
      exchange.sendResponseHeaders(200, body.length);
      try (var output = exchange.getResponseBody()) {
        output.write(body);
      } finally {
        exchange.close();
      }
    });
    server.start();
    try {
      var gateway = new GoogleManagedAndroidGateway(new AndroidManagement.Builder(
          new NetHttpTransport(), GsonFactory.getDefaultInstance(), request -> {})
          .setRootUrl("http://127.0.0.1:" + server.getAddress().getPort() + "/")
          .setApplicationName("local-application-identity-journey").build());
      var report = gateway.readApplicationReport("e1", "d1", "example.learning.app").orElseThrow();
      Instant now = Instant.parse("2026-10-16T08:00:00Z");
      var context = ManagedApplicationIdentityVerifierTest.context(Set.of("00".repeat(32)));
      var verifier = new ManagedApplicationIdentityVerifier(Clock.fixed(now, ZoneOffset.UTC),
          Duration.ofMinutes(10), Duration.ofMinutes(2), Duration.ofSeconds(30));
      var verified = verifier.verify(context, context, report, now);
      assertThat(verified.context().scope().registrationId()).isEqualTo("registration-1");
      assertThat(verified.signingCertificates()).containsExactly("00".repeat(32));
      assertThat(verified.expiresAt()).isEqualTo(now.plusSeconds(120));
      assertThat(verified.profileScope()).isEqualTo(ManagedApplicationIdentityVerifier.ProfileScope.UNKNOWN);
    } finally {
      server.stop(0);
    }
  }
}
