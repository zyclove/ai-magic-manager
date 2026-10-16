package com.aimanager.managedandroid;

import static org.assertj.core.api.Assertions.*;

import com.aimanager.managedandroid.ManagedAndroidGateway.AppControl;
import com.aimanager.managedandroid.ManagedAndroidGateway.AppRestriction;
import com.aimanager.managedandroid.ManagedAndroidGateway.ApplicationPolicyState;
import com.aimanager.managedandroid.internal.GoogleManagedAndroidGateway;
import com.aimanager.managedandroid.internal.UnavailableManagedAndroidGateway;
import com.google.api.client.http.javanet.NetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.zip.GZIPOutputStream;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/** Real generated SDK against a bounded loopback fixture, never a live enterprise. */
class GoogleManagedApplicationPolicyContentTest {
  private HttpServer server;
  private ManagedAndroidGateway gateway;
  private final AtomicInteger writes = new AtomicInteger();
  private final AtomicInteger reads = new AtomicInteger();
  private final AtomicReference<String> stored = new AtomicReference<>(policy("[]"));
  private final AtomicReference<String> written = new AtomicReference<>(policy("[]"));
  private int readStatus = 200;
  private int writeStatus = 200;
  private boolean gzip;
  private static final String BLOCKED =
      "[{\"packageName\":\"org.example.reader\",\"disabled\":true}]";

  @BeforeEach
  void setup() throws IOException {
    server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext("/", this::respond);
    server.start();
    gateway =
        new GoogleManagedAndroidGateway(
            new AndroidManagement.Builder(
                    new NetHttpTransport(),
                    GsonFactory.getDefaultInstance(),
                    request -> {
                      // The adapter must override an eager retry/redirect initializer on every
                      // request.
                      request.setNumberOfRetries(3).setFollowRedirects(true);
                      request.setUnsuccessfulResponseHandler(
                          (ignored, response, supportsRetry) -> true);
                    })
                .setRootUrl("http://127.0.0.1:" + server.getAddress().getPort() + "/")
                .setApplicationName("local-policy-content-contract")
                .build());
  }

  @AfterEach
  void close() {
    server.stop(0);
  }

  @Test
  void matchingResourceAndVersionCannotCertifyWrongApplicationContents() {
    written.set(
        policy(
            "[{\"packageName\":\"org.example.reader\",\"installType\":\"AVAILABLE\",\"disabled\":false}]"));
    assertThatThrownBy(() -> gateway.putApplicationPolicy("e1", "p1", launchBlocked()))
        .as("policy receipt must confirm requested application contents")
        .isInstanceOf(IllegalStateException.class);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isEqualTo(1);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "[]",
        "[{\"packageName\":\"org.example.other\",\"disabled\":true}]",
        "[{\"packageName\":\"org.example.reader\",\"installType\":\"BLOCKED\"}]",
        "[{\"packageName\":\"org.example.reader\",\"disabled\":true},{\"packageName\":\"org.example.extra\"}]",
        "[{\"packageName\":\"org.example.reader\",\"disabled\":true,\"defaultPermissionPolicy\":\"GRANT\"}]",
        "[{\"packageName\":\"org.example.reader\",\"disabled\":true,\"managedConfiguration\":{\"secret\":true}}]"
      })
  void differentWholeApplicationProjectionIsNotAReceipt(String apps) {
    written.set(policy(apps));
    assertThatThrownBy(() -> gateway.putApplicationPolicy("e1", "p1", launchBlocked()))
        .isInstanceOf(IllegalStateException.class);
    assertThat(writes.get()).isEqualTo(1);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "[{\"packageName\":\"org.example.reader\",\"permissionGrants\":[{\"permission\":\"android.permission.CAMERA\",\"policy\":\"DENY\"}]}]",
        "[{\"packageName\":\"org.example.reader\",\"managedConfiguration\":{\"keep\":true}}]",
        "[{\"packageName\":\"org.example.reader\",\"managedConfigurationTemplate\":{\"templateId\":\"keep\"}}]",
        "[{\"packageName\":\"org.example.reader\",\"delegatedScopes\":[\"CERT_INSTALL\"]}]",
        "[{\"packageName\":\"org.example.reader\",\"defaultPermissionPolicy\":\"PROMPT\"}]",
        "[{\"packageName\":\"org.example.reader\",\"installType\":\"FORCE_INSTALLED\"}]",
        "[{\"packageName\":\"org.example.reader\",\"futurePolicyField\":[]}]"
      })
  void unsupportedExistingConfigurationIsNeverErased(String apps) {
    stored.set(policy(apps));
    assertThatThrownBy(() -> gateway.putApplicationPolicy("e1", "p1", launchBlocked()))
        .isInstanceOf(IllegalStateException.class);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "null",
        "[null]",
        "[{\"packageName\":null}]",
        "[{\"packageName\":\"org.example.reader\",\"disabled\":null}]",
        "[{\"packageName\":\"org.example.reader\",\"installType\":null}]",
        "[{\"packageName\":\"org.example.reader\",\"disabled\":true,\"disabled\":false}]",
        "[{\"packageName\":\"org.example.reader\"},{\"packageName\":\"org.example.reader\"}]",
        "[{\"packageName\":\"invalid package\"}]"
      })
  void malformedApplicationDataCannotBecomeAnObservation(String apps) {
    stored.set(policy(apps));
    assertThatThrownBy(() -> gateway.inspectApplicationPolicy("e1", "p1", launchBlocked(), 6L))
        .isInstanceOf(IllegalStateException.class);
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "{}",
        "null",
        "[]",
        "{\"name\":\"enterprises/other/policies/p1\",\"version\":\"7\",\"playStoreMode\":\"BLACKLIST\"}",
        "{\"name\":\"enterprises/e1/policies/p1\",\"version\":null,\"playStoreMode\":\"BLACKLIST\"}",
        "{\"name\":\"enterprises/e1/policies/p1\",\"version\":\"7\",\"version\":\"8\"}",
        "{\"name\":\"enterprises/e1/policies/p1\",\"version\":\"7\"} {}"
      })
  void malformedResourceIsNotNotFoundOrVersionMismatch(String json) {
    stored.set(json);
    assertThatThrownBy(() -> gateway.inspectApplicationPolicy("e1", "p1", List.of(), 6L))
        .isInstanceOf(IllegalStateException.class);
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(strings = {"\"true\"", "\"false\"", "\"garbage\"", "0", "{}", "[]", "null"})
  void sdkBooleanCoercionCannotAuthorizeWriteOrConfirmContent(String value) {
    stored.set(
        policy("[]")
            .replace(
                "\"applications\":", "\"installAppsDisabled\":" + value + ",\"applications\":"));
    assertThatThrownBy(() -> gateway.putApplicationPolicy("e1", "p1", List.of()))
        .isInstanceOf(IllegalStateException.class);
    stored.set(policy("[{\"packageName\":\"org.example.reader\",\"disabled\":" + value + "}]"));
    assertThatThrownBy(() -> gateway.inspectApplicationPolicy("e1", "p1", launchBlocked(), 7L))
        .isInstanceOf(IllegalStateException.class);
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "[{\"packageName\":7}]",
        "[{\"packageName\":\"org.example.reader\",\"installType\":true}]",
        "[{\"packageName\":\"org.example.reader\",\"permissionGrants\":{}}]",
        "[{\"packageName\":\"org.example.reader\",\"managedConfiguration\":[]}]"
      })
  void sdkCoercionOfOtherFieldsIsRejected(String apps) {
    stored.set(policy(apps));
    assertThatThrownBy(() -> gateway.inspectApplicationPolicy("e1", "p1", List.of(), null))
        .isInstanceOf(IllegalStateException.class);
    assertThat(writes.get()).isZero();
  }

  @Test
  void stringBooleanInWriteResponseCannotCertifyAnAlreadyIssuedWrite() {
    written.set(policy("[{\"packageName\":\"org.example.reader\",\"disabled\":\"true\"}]"));
    assertThatThrownBy(() -> gateway.putApplicationPolicy("e1", "p1", launchBlocked()))
        .isInstanceOf(IllegalStateException.class);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isEqualTo(1);
  }

  @Test
  void defaultsAndOrderAreNormalizedWithoutCertifyingGlobalPermissions() {
    String apps =
        "[{\"packageName\":\"org.example.store\",\"installType\":\"BLOCKED\"},"
            + "{\"packageName\":\"org.example.reader\",\"installType\":\"INSTALL_TYPE_UNSPECIFIED\","
            + "\"permissionGrants\":[],\"delegatedScopes\":[],\"managedConfiguration\":{},"
            + "\"defaultPermissionPolicy\":\"PERMISSION_POLICY_UNSPECIFIED\",\"autoUpdateMode\":\"AUTO_UPDATE_DEFAULT\"}]";
    var desired =
        List.of(
            new AppRestriction("org.example.reader", AppControl.ALLOW),
            new AppRestriction("org.example.store", AppControl.BLOCK_INSTALL));
    stored.set(
        policy(apps)
            .replace(
                "\"applications\":", "\"defaultPermissionPolicy\":\"DENY\",\"applications\":"));
    written.set(stored.get());
    assertThat(gateway.inspectApplicationPolicy("e1", "p1", desired, 7L).state())
        .isEqualTo(ApplicationPolicyState.MATCHED);
    assertThat(gateway.putApplicationPolicy("e1", "p1", desired).providerVersion()).isEqualTo(7);
    assertThat(writes.get()).isEqualTo(1);
  }

  @Test
  void compressedMatchingLaunchBlockReturnsOnlyPolicyReceipt() {
    gzip = true;
    written.set(policy(BLOCKED));
    var receipt = gateway.putApplicationPolicy("e1", "p1", launchBlocked());
    assertThat(receipt.policyName()).isEqualTo("enterprises/e1/policies/p1");
    assertThat(receipt.providerVersion()).isEqualTo(7);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isEqualTo(1);
  }

  @Test
  void missingPreflightPolicyDoesNotCreateAReplacement() {
    readStatus = 404;
    assertThatThrownBy(() -> gateway.putApplicationPolicy("e1", "p1", List.of()))
        .isInstanceOf(IllegalStateException.class);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isZero();
  }

  @Test
  void inspectionIsReadOnlyAndDistinguishesContentVersionAndAbsence() {
    stored.set(policy(BLOCKED));
    var contentOnly = gateway.inspectApplicationPolicy("e1", "p1", launchBlocked(), null);
    assertThat(contentOnly.state()).isEqualTo(ApplicationPolicyState.MATCHED);
    assertThat(contentOnly.providerVersion()).isEqualTo(7);
    assertThat(contentOnly.toString()).doesNotContain("enterprises/");
    assertThat(gateway.inspectApplicationPolicy("e1", "p1", launchBlocked(), 6L).state())
        .isEqualTo(ApplicationPolicyState.VERSION_MISMATCH);
    assertThat(gateway.inspectApplicationPolicy("e1", "p1", List.of(), 7L).state())
        .isEqualTo(ApplicationPolicyState.CONTENT_MISMATCH);
    readStatus = 404;
    stored.set("private error body");
    var absent = gateway.inspectApplicationPolicy("e1", "p1", launchBlocked(), null);
    assertThat(absent.state()).isEqualTo(ApplicationPolicyState.NOT_FOUND);
    assertThat(absent.providerVersion()).isNull();
    assertThat(reads.get()).isEqualTo(4);
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(strings = {"WHITELIST", "PLAY_STORE_MODE_UNSPECIFIED", ""})
  void unsafeStoreModeCannotBeReplacedOrMatched(String mode) {
    stored.set(policy(BLOCKED).replace("BLACKLIST", mode));
    assertThat(gateway.inspectApplicationPolicy("e1", "p1", launchBlocked(), 7L).state())
        .isEqualTo(ApplicationPolicyState.CONTENT_MISMATCH);
    assertThatThrownBy(() -> gateway.putApplicationPolicy("e1", "p1", launchBlocked()))
        .isInstanceOf(IllegalStateException.class);
    assertThat(writes.get()).isZero();
  }

  @Test
  void globalInstallBlockCannotBeReportedAsAllowingInstallation() {
    stored.set(
        policy("[]")
            .replace("\"applications\":", "\"installAppsDisabled\":true,\"applications\":"));
    assertThat(gateway.inspectApplicationPolicy("e1", "p1", List.of(), 7L).state())
        .isEqualTo(ApplicationPolicyState.CONTENT_MISMATCH);
    assertThatThrownBy(() -> gateway.putApplicationPolicy("e1", "p1", List.of()))
        .isInstanceOf(IllegalStateException.class);
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(ints = {301, 302, 307, 401, 403, 429, 503})
  void readErrorsAreNotRetriedRedirectedOrLeaked(int status) {
    readStatus = status;
    stored.set("provider-private-body".repeat(100000));
    assertThatThrownBy(() -> gateway.inspectApplicationPolicy("e1", "p1", List.of(), null))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageNotContaining("provider-private-body");
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(ints = {307, 404, 429, 503})
  void uncertainWriteIsNeverAutomaticallyRetried(int status) {
    writeStatus = status;
    written.set("provider-private-body");
    assertThatThrownBy(() -> gateway.putApplicationPolicy("e1", "p1", launchBlocked()))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageNotContaining("provider-private-body");
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isEqualTo(1);
  }

  @ParameterizedTest
  @ValueSource(booleans = {false, true})
  void expandedSuccessBodyIsBoundedBeforeParsing(boolean compressed) {
    gzip = compressed;
    stored.set(
        policy("[]")
            .replace(
                "\"applications\":",
                "\"padding\":\"" + "x".repeat(1024 * 1024) + "\",\"applications\":"));
    assertThatThrownBy(() -> gateway.inspectApplicationPolicy("e1", "p1", List.of(), null))
        .isInstanceOf(IllegalStateException.class);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isZero();
  }

  @Test
  void oversizedWriteResponseRemainsUncertainWithoutRetry() {
    written.set(
        policy(BLOCKED)
            .replace(
                "\"applications\":",
                "\"padding\":\"" + "x".repeat(1024 * 1024) + "\",\"applications\":"));
    assertThatThrownBy(() -> gateway.putApplicationPolicy("e1", "p1", launchBlocked()))
        .isInstanceOf(IllegalStateException.class);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isEqualTo(1);
  }

  @Test
  void invalidInputAndUnavailableAdapterDoNotContactProvider() {
    assertThatThrownBy(() -> gateway.inspectApplicationPolicy("e1", "p1", List.of(), 0L))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> gateway.inspectApplicationPolicy("../e1", "p1", List.of(), null))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(
            () ->
                gateway.putApplicationPolicy(
                    "e1",
                    "p1",
                    List.of(
                        new AppRestriction("org.example.reader", AppControl.ALLOW),
                        new AppRestriction("org.example.reader", AppControl.BLOCK_INSTALL))))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(
            () ->
                new UnavailableManagedAndroidGateway()
                    .inspectApplicationPolicy("e1", "p1", List.of(), null))
        .isInstanceOf(ManagedAndroidUnavailableException.class);
    assertThat(reads.get()).isZero();
    assertThat(writes.get()).isZero();
  }

  @Test
  void oversizedApplicationCollectionsAreRejectedOnBothSides() {
    var rules =
        java.util.stream.IntStream.range(0, 3001)
            .mapToObj(i -> new AppRestriction("org.example.app" + i, AppControl.ALLOW))
            .toList();
    assertThatThrownBy(() -> gateway.putApplicationPolicy("e1", "p1", rules))
        .isInstanceOf(IllegalArgumentException.class);
    assertThat(reads.get()).isZero();
    String apps =
        rules.stream()
            .map(r -> "{\"packageName\":\"" + r.packageName() + "\"}")
            .collect(java.util.stream.Collectors.joining(",", "[", "]"));
    stored.set(policy(apps));
    assertThatThrownBy(() -> gateway.inspectApplicationPolicy("e1", "p1", List.of(), null))
        .isInstanceOf(IllegalStateException.class);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isZero();
  }

  private static List<AppRestriction> launchBlocked() {
    return List.of(new AppRestriction("org.example.reader", AppControl.BLOCK_LAUNCH));
  }

  private static String policy(String apps) {
    return "{\"name\":\"enterprises/e1/policies/p1\",\"version\":\"7\",\"playStoreMode\":\"BLACKLIST\",\"applications\":"
        + apps
        + "}";
  }

  private void respond(HttpExchange exchange) throws IOException {
    exchange.getRequestBody().readAllBytes();
    boolean read = exchange.getRequestMethod().equals("GET");
    if (read) reads.incrementAndGet();
    else writes.incrementAndGet();
    byte[] bytes = (read ? stored.get() : written.get()).getBytes(StandardCharsets.UTF_8);
    if (gzip) {
      var compressed = new ByteArrayOutputStream();
      try (var stream = new GZIPOutputStream(compressed)) {
        stream.write(bytes);
      }
      bytes = compressed.toByteArray();
      exchange.getResponseHeaders().set("Content-Encoding", "gzip");
    }
    exchange.getResponseHeaders().set("Content-Type", "application/json");
    exchange
        .getResponseHeaders()
        .set("Location", "http://127.0.0.1:" + server.getAddress().getPort() + "/redirected");
    exchange.sendResponseHeaders(read ? readStatus : writeStatus, bytes.length);
    try (var output = exchange.getResponseBody()) {
      output.write(bytes);
    } catch (IOException disconnectedAfterBoundedRead) {
      /* Client intentionally closes unread bodies. */
    }
  }
}
