package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.google.api.client.http.javanet.NetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/** Malformed provider responses cannot grant a capability or be mistaken for a missing device. */
class GoogleManagedDeviceProfileBoundaryTest {
  static final String NAME = "enterprises/e1/devices/d1";
  final ObjectMapper json = new ObjectMapper();
  final AtomicInteger reads = new AtomicInteger();
  final AtomicInteger writes = new AtomicInteger();
  HttpServer server;
  AndroidManagement client;
  String query;
  String response =
      """
      {"name":"enterprises/e1/devices/d1","managementMode":"DEVICE_OWNER",
       "apiLevel":30,"state":"ACTIVE","appliedState":"ACTIVE",
       "lastStatusReportTime":"2026-10-16T10:00:00Z"}
      """;
  int status = 200;
  boolean compressed;

  @BeforeEach
  void setup() throws Exception {
    server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext(
        "/",
        exchange -> {
          if (exchange.getRequestMethod().equals("GET")) reads.incrementAndGet();
          else writes.incrementAndGet();
          query = exchange.getRequestURI().getRawQuery();
          byte[] body = response.getBytes(StandardCharsets.UTF_8);
          if (compressed) {
            var buffer = new java.io.ByteArrayOutputStream();
            try (var gzip = new java.util.zip.GZIPOutputStream(buffer)) {
              gzip.write(body);
            }
            body = buffer.toByteArray();
            exchange.getResponseHeaders().set("Content-Encoding", "gzip");
          }
          if (status >= 300 && status < 400)
            exchange
                .getResponseHeaders()
                .set(
                    "Location",
                    "http://127.0.0.1:" + server.getAddress().getPort() + "/redirected");
          exchange.getResponseHeaders().set("Content-Type", "application/json");
          exchange.sendResponseHeaders(status, body.length);
          exchange.getResponseBody().write(body);
          exchange.close();
        });
    server.start();
    client =
        new AndroidManagement.Builder(
                new NetHttpTransport(),
                GsonFactory.getDefaultInstance(),
                request -> {
                  request.setNumberOfRetries(3).setFollowRedirects(true);
                  request.setUnsuccessfulResponseHandler((ignored, res, retry) -> true);
                })
            .setRootUrl("http://127.0.0.1:" + server.getAddress().getPort() + "/")
            .setApplicationName("device-profile-boundary-contract")
            .build();
  }

  @AfterEach
  void close() {
    if (server != null) server.stop(0);
  }

  @Test
  void selectsOnlyProfileFieldsAndRedactsDiagnosticOutput() {
    var result = GoogleManagedDeviceProfileReader.read(client, NAME);
    assertThat(URLDecoder.decode(query, StandardCharsets.UTF_8))
        .isEqualTo("fields=name,managementMode,apiLevel,state,appliedState,lastStatusReportTime");
    assertThat(result.toString()).doesNotContain(NAME, "2026-10-16");
    assertThat(writes.get()).isZero();
  }

  @Test
  void onlyConfirmed404MeansNoProfile() {
    status = 404;
    response = "provider-private-body";
    assertThat(GoogleManagedDeviceProfileReader.read(client, NAME)).isNull();
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isZero();
  }

  @Test
  void connectorCapabilityIsExplicitAndUnavailableDefaultsStayClosed() {
    var gateway = new GoogleManagedAndroidGateway(client);
    assertThat(gateway.supportsExecutionProfiles()).isTrue();
    assertThat(gateway.readExecutionProfile("e1", "d1"))
        .get()
        .extracting(com.aimanager.managedandroid.ManagedDeviceExecutionProfile::deviceName)
        .isEqualTo(NAME);
    status = 404;
    assertThat(gateway.readExecutionProfile("e1", "d1")).isEmpty();
    var unavailable = new UnavailableManagedAndroidGateway();
    assertThat(unavailable.supportsExecutionProfiles()).isFalse();
    assertThatThrownBy(() -> unavailable.readExecutionProfile("e1", "d1"))
        .isInstanceOf(com.aimanager.managedandroid.ManagedAndroidUnavailableException.class);
    assertThat(writes.get()).isZero();
  }

  @Test
  void currentProviderFactsFeedCompilationAfterFreshnessVerification() {
    var gateway = new GoogleManagedAndroidGateway(client);
    var profile = gateway.readExecutionProfile("e1", "d1").orElseThrow();
    var now = java.time.Instant.parse("2026-10-16T10:00:00Z");
    var settings =
        new ManagedDeviceProfileSettings(
            java.time.Clock.fixed(now, java.time.ZoneOffset.UTC), 600, 120, 15);
    var verified = settings.verifier.verify(NAME, now.minusSeconds(60), profile, now);
    var document =
        new GoogleCompletePolicyCompiler("com.aimanager.child", java.util.Set.of())
            .compile(
                verified.apiLevel(),
                verified.managementMode(),
                java.util.List.of(
                    new com.aimanager.managedandroid.ManagedAndroidGateway.AppRestriction(
                        "com.example.lesson",
                        com.aimanager.managedandroid.ManagedAndroidGateway.AppControl
                            .BLOCK_LAUNCH)),
                java.util.List.of());
    assertThat(document.requestBody().getApplications())
        .anySatisfy(
            app -> {
              assertThat(app.getPackageName()).isEqualTo("com.example.lesson");
              assertThat(app.getDisabled()).isTrue();
            });
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(ints = {301, 307, 400, 401, 403, 429, 500, 503})
  void failedReadNeverFakesMissingOrFollowsRedirects(int code) {
    status = code;
    response = "provider-private-body";
    assertInvalid();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "name",
        "managementMode",
        "apiLevel",
        "state",
        "appliedState",
        "lastStatusReportTime"
      })
  void missingFieldsAreNotExecutionFacts(String field) throws Exception {
    var node = (ObjectNode) json.readTree(response);
    node.remove(field);
    response = json.writeValueAsString(node);
    assertInvalid();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "name",
        "managementMode",
        "apiLevel",
        "state",
        "appliedState",
        "lastStatusReportTime"
      })
  void explicitNullFieldsAreNotExecutionFacts(String field) throws Exception {
    var node = (ObjectNode) json.readTree(response);
    node.putNull(field);
    response = json.writeValueAsString(node);
    assertInvalid();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "foreignName",
        "apiString",
        "apiFloat",
        "apiWholeFloat",
        "apiBoolean",
        "apiZero",
        "apiNegative",
        "apiOverflow",
        "stateObject",
        "modeNumber",
        "blankState",
        "timeNumber",
        "badTime"
      })
  void invalidFieldsNeverBecomeTrustedCapabilities(String change) throws Exception {
    var node = (ObjectNode) json.readTree(response);
    switch (change) {
      case "foreignName" -> node.put("name", "enterprises/foreign/devices/d1");
      case "apiString" -> node.put("apiLevel", "30");
      case "apiFloat" -> node.put("apiLevel", 30.5);
      case "apiWholeFloat" -> node.put("apiLevel", 30.0);
      case "apiBoolean" -> node.put("apiLevel", true);
      case "apiZero" -> node.put("apiLevel", 0);
      case "apiNegative" -> node.put("apiLevel", -1);
      case "apiOverflow" -> node.put("apiLevel", 2147483648L);
      case "stateObject" -> node.putObject("state");
      case "modeNumber" -> node.put("managementMode", 1);
      case "blankState" -> node.put("appliedState", " ");
      case "timeNumber" -> node.put("lastStatusReportTime", 1);
      case "badTime" -> node.put("lastStatusReportTime", "2026-99-99T00:00:00Z");
    }
    response = json.writeValueAsString(node);
    assertInvalid();
  }

  @ParameterizedTest
  @ValueSource(strings = {"{}", "null", "[]"})
  void malformedJsonNeverBecomesFacts(String body) {
    response = body;
    assertInvalid();
  }

  @ParameterizedTest
  @ValueSource(strings = {"duplicate", "trailing"})
  void otherwiseValidFactsRejectDuplicateKeysAndTrailingJson(String change) {
    String body = response.stripTrailing();
    response =
        change.equals("duplicate")
            ? body.substring(0, body.length() - 1) + ",\"apiLevel\":31}"
            : body + " {}";
    assertInvalid();
  }

  @ParameterizedTest
  @ValueSource(booleans = {false, true})
  void decodedPayloadIsBounded(boolean gzip) throws Exception {
    compressed = gzip;
    response = paddedResponse(128 * 1024 + 1);
    assertInvalid();
  }

  @ParameterizedTest
  @ValueSource(booleans = {false, true})
  void validPayloadAtDecodedLimitIsAccepted(boolean gzip) throws Exception {
    compressed = gzip;
    response = paddedResponse(128 * 1024);
    assertThat(GoogleManagedDeviceProfileReader.read(client, NAME).deviceName()).isEqualTo(NAME);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isZero();
  }

  String paddedResponse(int totalBytes) throws Exception {
    var node = (ObjectNode) json.readTree(response);
    node.put("padding", "");
    int overhead = json.writeValueAsBytes(node).length;
    node.put("padding", "x".repeat(totalBytes - overhead));
    String body = json.writeValueAsString(node);
    assertThat(body.getBytes(StandardCharsets.UTF_8)).hasSize(totalBytes);
    return body;
  }

  @Test
  void returnedStateIsAnObservationNotExecutionAuthorization() throws Exception {
    var node = (ObjectNode) json.readTree(response);
    node.put("managementMode", "PROFILE_OWNER")
        .put("apiLevel", 29)
        .put("state", "DISABLED")
        .put("lastStatusReportTime", "2020-01-01T00:00:00Z");
    response = json.writeValueAsString(node);
    var result = GoogleManagedDeviceProfileReader.read(client, NAME);
    assertThat(result.managementMode()).isEqualTo("PROFILE_OWNER");
    assertThat(result.apiLevel()).isEqualTo(29);
    assertThat(result.state()).isEqualTo("DISABLED");
    assertThat(result.lastStatusReportTime()).isEqualTo("2020-01-01T00:00:00Z");
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "",
        "enterprises/e1/devices/../d1",
        "enterprises/e1/policies/p1",
        "enterprises/e1/devices/d1?fields=all"
      })
  void invalidResourceIsRejectedBeforeNetwork(String name) {
    assertThatThrownBy(() -> GoogleManagedDeviceProfileReader.read(client, name))
        .isInstanceOf(IllegalArgumentException.class);
    assertThat(reads.get()).isZero();
    assertThat(writes.get()).isZero();
  }

  void assertInvalid() {
    assertThatThrownBy(() -> GoogleManagedDeviceProfileReader.read(client, NAME))
        .isInstanceOf(IllegalStateException.class)
        .hasNoCause()
        .hasMessageNotContaining("provider-private-body")
        .hasMessageNotContaining(NAME);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isZero();
  }
}
