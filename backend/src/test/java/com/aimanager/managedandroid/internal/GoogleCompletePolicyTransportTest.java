package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedAndroidGateway.*;
import com.aimanager.managedandroid.ManagedPolicyWriteException;
import com.aimanager.managedandroid.ManagedPolicyWriteException.Outcome;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.google.api.client.http.javanet.NetHttpTransport;
import com.google.api.client.json.gson.GsonFactory;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/** Generated Google SDK with a loopback HTTP server. No production enterprise or device. */
class GoogleCompletePolicyTransportTest {
  static final String ID = "aim_0123456789abcdef0123456789abcdef";
  static final String NAME = "enterprises/e1/policies/" + ID;
  HttpServer server;
  ManagedAndroidGateway gateway;
  PolicyDocument document;
  final ObjectMapper json = new ObjectMapper();
  final AtomicInteger reads = new AtomicInteger(), writes = new AtomicInteger();
  String response, sent, query;
  boolean gzip, dropWrite;
  int readStatus = 404, writeStatus = 200;

  @BeforeEach
  void setup() throws Exception {
    var compiled =
        new GoogleCompletePolicyCompiler("com.aimanager.child", Set.of())
            .compile(
                30,
                "DEVICE_OWNER",
                List.of(new AppRestriction("com.example.lesson", AppControl.BLOCK_LAUNCH)),
                List.of(
                    new GoogleCompletePolicyCompiler.AppPermissions(
                        "com.example.lesson",
                        List.of(
                            new RuntimePermissionDecision(
                                "android.permission.CAMERA", PermissionDecision.DENY)))));
    document =
        new PolicyDocument(
            compiled.documentJson(), compiled.sha256(), "com.aimanager.child", 30, "DEVICE_OWNER");
    var policy = (ObjectNode) json.readTree(compiled.documentJson()).path("policy");
    policy.put("name", NAME).put("version", "1");
    response = json.writeValueAsString(policy);
    server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext(
        "/",
        exchange -> {
          boolean write = !exchange.getRequestMethod().equals("GET");
          if (write) {
            writes.incrementAndGet();
            query = exchange.getRequestURI().getRawQuery();
            var input = exchange.getRequestBody();
            if ("gzip".equalsIgnoreCase(exchange.getRequestHeaders().getFirst("Content-Encoding")))
              input = new java.util.zip.GZIPInputStream(input);
            sent = new String(input.readAllBytes(), StandardCharsets.UTF_8);
          } else reads.incrementAndGet();
          if (write && dropWrite) {
            exchange.close();
            return;
          }
          int status = write ? writeStatus : readStatus;
          byte[] bytes = (status == 404 ? "{}" : response).getBytes(StandardCharsets.UTF_8);
          if (gzip) {
            var compressed = new java.io.ByteArrayOutputStream();
            try (var stream = new java.util.zip.GZIPOutputStream(compressed)) {
              stream.write(bytes);
            }
            bytes = compressed.toByteArray();
            exchange.getResponseHeaders().set("Content-Encoding", "gzip");
          }
          if (status >= 300 && status < 400)
            exchange
                .getResponseHeaders()
                .set(
                    "Location",
                    "http://127.0.0.1:" + server.getAddress().getPort() + "/redirected");
          exchange.getResponseHeaders().set("Content-Type", "application/json");
          exchange.sendResponseHeaders(status, bytes.length);
          exchange.getResponseBody().write(bytes);
          exchange.close();
        });
    server.start();
    gateway =
        new GoogleManagedAndroidGateway(
            new AndroidManagement.Builder(
                    new NetHttpTransport(),
                    GsonFactory.getDefaultInstance(),
                    request -> {
                      request.setNumberOfRetries(3).setFollowRedirects(true);
                      request.setUnsuccessfulResponseHandler((ignored, res, supportsRetry) -> true);
                    })
                .setRootUrl("http://127.0.0.1:" + server.getAddress().getPort() + "/")
                .setApplicationName("complete-policy-local-contract")
                .build());
  }

  @AfterEach
  void close() {
    if (server != null) server.stop(0);
  }

  @Test
  void writesCompleteDocumentAndConfirmsBothControlsAndPermissions() throws Exception {
    var receipt = gateway.writePolicyCandidate("e1", ID, document);
    assertThat(receipt)
        .as("complete document transport must confirm applications and permissions")
        .isNotNull();
    assertThat(gateway.supportsCompletePolicyDocuments()).isTrue();
    assertThat(receipt.policyName()).isEqualTo(NAME);
    assertThat(receipt.providerVersion()).isEqualTo(1L);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isEqualTo(1);
    assertThat(json.readTree(sent))
        .isEqualTo(json.readTree(document.documentJson()).path("policy"));
    assertThat(java.net.URLDecoder.decode(query, StandardCharsets.UTF_8))
        .contains(
            "updateMask=applications,defaultPermissionPolicy,playStoreMode,statusReportingSettings");
  }

  @Test
  void knownExistingResourceIsNeverOverwrittenEvenWhenContentsMatch() {
    readStatus = 200;
    assertWriteFailure(Outcome.NOT_DISPATCHED);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(ints = {301, 307, 401, 403, 429, 503})
  void preflightFailureDoesNotDispatchOrFollowRedirects(int status) {
    readStatus = status;
    response = "provider-private-body";
    assertWriteFailure(Outcome.NOT_DISPATCHED);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(ints = {301, 307, 400, 401, 403, 404, 409, 429, 500, 503})
  void dispatchedFailureStaysUnknownAndNeverRetries(int status) {
    writeStatus = status;
    response = "provider-private-body";
    assertWriteFailure(Outcome.OUTCOME_UNKNOWN);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isEqualTo(1);
  }

  @Test
  void inspectionChecksExactVersionAndDoesNotWrite() {
    readStatus = 200;
    assertThat(gateway.inspectCompletePolicy("e1", ID, document, 1L).state())
        .isEqualTo(CompletePolicyState.MATCHED);
    assertThat(gateway.inspectCompletePolicy("e1", ID, document, 2L).state())
        .isEqualTo(CompletePolicyState.VERSION_MISMATCH);
    assertThat(gateway.inspectCompletePolicy("e1", ID, document, null).state())
        .isEqualTo(CompletePolicyState.MATCHED);
    assertThat(writes.get()).isZero();
    assertThat(reads.get()).isEqualTo(3);
  }

  @Test
  void onlyConfirmed404MeansNotFound() {
    var result = gateway.inspectCompletePolicy("e1", ID, document, null);
    assertThat(result.state()).isEqualTo(CompletePolicyState.NOT_FOUND);
    assertThat(result.providerVersion()).isNull();
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(ints = {301, 307, 400, 401, 403, 429, 500, 503})
  void inspectionErrorsNeverBecomeNotFound(int status) {
    readStatus = status;
    response = "provider-private-body";
    assertThatThrownBy(() -> gateway.inspectCompletePolicy("e1", ID, document, null))
        .isInstanceOf(IllegalStateException.class)
        .hasNoCause()
        .hasMessageNotContaining("provider-private-body")
        .hasMessageNotContaining(NAME);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(strings = {"malformed", "oversized", "compressedOversized"})
  void invalidPreflightResponseNeverDispatches(String kind) {
    readStatus = 200;
    gzip = kind.equals("compressedOversized");
    response = kind.equals("malformed") ? "{" : "x".repeat(1024 * 1024 + 1);
    assertWriteFailure(Outcome.NOT_DISPATCHED);
    assertThat(reads.get()).isEqualTo(1);
    assertThat(writes.get()).isZero();
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "playStoreMode",
        "defaultPermissionPolicy",
        "reports",
        "disabled",
        "permission",
        "extraGrant",
        "extraApplication",
        "agentControl",
        "extraRoot",
        "extraApp"
      })
  void semanticDifferencesCannotConfirmTheWrite(String change) throws Exception {
    changePolicy(change);
    assertWriteFailure(Outcome.OUTCOME_UNKNOWN);
    readStatus = 200;
    assertThat(gateway.inspectCompletePolicy("e1", ID, document, null).state())
        .isEqualTo(CompletePolicyState.CONTENT_MISMATCH);
    assertThat(writes.get()).isEqualTo(1);
  }

  void changePolicy(String change) throws Exception {
    var node = (ObjectNode) json.readTree(response);
    var app = (ObjectNode) node.path("applications").get(1);
    switch (change) {
      case "playStoreMode" -> node.put("playStoreMode", "WHITELIST");
      case "defaultPermissionPolicy" -> node.put("defaultPermissionPolicy", "GRANT");
      case "reports" ->
          ((ObjectNode) node.path("statusReportingSettings"))
              .put("applicationReportsEnabled", false);
      case "disabled" -> app.put("disabled", false);
      case "permission" ->
          ((ObjectNode) app.path("permissionGrants").get(0)).put("policy", "GRANT");
      case "extraGrant" ->
          ((com.fasterxml.jackson.databind.node.ArrayNode) app.path("permissionGrants"))
              .addObject()
              .put("permission", "android.permission.RECORD_AUDIO")
              .put("policy", "DENY");
      case "extraApplication" ->
          ((com.fasterxml.jackson.databind.node.ArrayNode) node.path("applications"))
              .addObject()
              .put("packageName", "com.example.extra")
              .put("installType", "AVAILABLE");
      case "agentControl" ->
          ((ObjectNode) node.path("applications").get(0))
              .put("userControlSettings", "USER_CONTROL_ALLOWED");
      case "extraRoot" -> node.put("factoryResetDisabled", true);
      case "extraApp" -> app.put("minimumVersionCode", 123);
    }
    response = json.writeValueAsString(node);
  }

  @Test
  void omittedDefaultsAndReorderedApplicationsRemainEquivalent() throws Exception {
    var node = (ObjectNode) json.readTree(response);
    var apps = (com.fasterxml.jackson.databind.node.ArrayNode) node.path("applications");
    var agent = (ObjectNode) apps.get(0);
    agent.remove("disabled");
    agent.remove("permissionGrants");
    var lesson = (ObjectNode) apps.get(1);
    lesson.put("installType", "INSTALL_TYPE_UNSPECIFIED");
    apps.removeAll().add(lesson).add(agent);
    response = json.writeValueAsString(node);
    assertThat(gateway.writePolicyCandidate("e1", ID, document).providerVersion()).isEqualTo(1L);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "name",
        "floatVersion",
        "zeroVersion",
        "overflowVersion",
        "nullVersion",
        "numericBoolean",
        "stringBoolean",
        "nullBoolean",
        "duplicateApp",
        "duplicateGrant",
        "nullPolicy"
      })
  void malformedRepliesAreNotReceiptsOrOrdinaryMismatches(String field) throws Exception {
    var node = (ObjectNode) json.readTree(response);
    var app = (ObjectNode) node.path("applications").get(1);
    switch (field) {
      case "name" -> node.put("name", "enterprises/other/policies/" + ID);
      case "floatVersion" -> node.put("version", 1.5);
      case "zeroVersion" -> node.put("version", 0);
      case "overflowVersion" -> node.put("version", "9223372036854775808");
      case "nullVersion" -> node.putNull("version");
      case "numericBoolean" -> app.put("disabled", 1);
      case "stringBoolean" -> app.put("disabled", "true");
      case "nullBoolean" -> app.putNull("disabled");
      case "duplicateApp" ->
          ((com.fasterxml.jackson.databind.node.ArrayNode) node.path("applications"))
              .add(app.deepCopy());
      case "duplicateGrant" ->
          ((com.fasterxml.jackson.databind.node.ArrayNode) app.path("permissionGrants"))
              .add(app.path("permissionGrants").get(0).deepCopy());
      case "nullPolicy" -> ((ObjectNode) app.path("permissionGrants").get(0)).putNull("policy");
    }
    response = json.writeValueAsString(node);
    assertWriteFailure(Outcome.OUTCOME_UNKNOWN);
    readStatus = 200;
    assertThatThrownBy(() -> gateway.inspectCompletePolicy("e1", ID, document, null))
        .isInstanceOf(IllegalStateException.class);
    assertThat(writes.get()).isEqualTo(1);
  }

  @ParameterizedTest
  @ValueSource(strings = {"{}", "null", "[]", "{} {}", "{\"name\":\"first\",\"name\":\"second\"}"})
  void brokenJsonIsNeverAReceipt(String body) {
    response = body;
    assertWriteFailure(Outcome.OUTCOME_UNKNOWN);
    assertThat(writes.get()).isEqualTo(1);
  }

  @ParameterizedTest
  @ValueSource(booleans = {false, true})
  void decodedBodyIsBoundedIncludingGzip(boolean compressed) throws Exception {
    gzip = compressed;
    var node = (ObjectNode) json.readTree(response);
    node.put("padding", "x".repeat(1024 * 1024));
    response = json.writeValueAsString(node);
    assertWriteFailure(Outcome.OUTCOME_UNKNOWN);
    assertThat(writes.get()).isEqualTo(1);
  }

  @Test
  void invalidInputNeverContactsProviderAndUnavailableDefaultsRemainClosed() {
    assertThatThrownBy(() -> gateway.writePolicyCandidate("e1", "existing", document))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> gateway.writePolicyCandidate("../other", ID, document))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(
            () ->
                gateway.writePolicyCandidate(
                    "e1",
                    ID,
                    new PolicyDocument(
                        document.documentJson(),
                        "0".repeat(64),
                        document.agentPackage(),
                        30,
                        "DEVICE_OWNER")))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(
            () ->
                gateway.writePolicyCandidate(
                    "e1",
                    ID,
                    new PolicyDocument(
                        document.documentJson(),
                        document.sha256(),
                        document.agentPackage(),
                        29,
                        "DEVICE_OWNER")))
        .isInstanceOf(IllegalArgumentException.class);
    assertThatThrownBy(() -> gateway.inspectCompletePolicy("e1", ID, document, 0L))
        .isInstanceOf(IllegalArgumentException.class);
    var unavailable = new UnavailableManagedAndroidGateway();
    assertThat(unavailable.supportsCompletePolicyDocuments()).isFalse();
    assertThatThrownBy(() -> unavailable.writePolicyCandidate("e1", ID, document))
        .isInstanceOf(com.aimanager.managedandroid.ManagedAndroidUnavailableException.class);
    assertThatThrownBy(() -> unavailable.inspectCompletePolicy("e1", ID, document, null))
        .isInstanceOf(com.aimanager.managedandroid.ManagedAndroidUnavailableException.class);
    assertThat(reads.get()).isZero();
    assertThat(writes.get()).isZero();
    assertThat(document.toString())
        .doesNotContain(document.documentJson(), document.agentPackage());
  }

  @Test
  void lostWriteResponseIsUncertainWithoutAnotherWrite() {
    dropWrite = true;
    assertWriteFailure(Outcome.OUTCOME_UNKNOWN);
    assertThat(writes.get()).isEqualTo(1);
  }

  @Test
  void permissionOrderIsIrrelevantButEveryDecisionIsRequired() throws Exception {
    var compiled =
        new GoogleCompletePolicyCompiler("com.aimanager.child", Set.of())
            .compile(
                30,
                "DEVICE_OWNER",
                List.of(),
                List.of(
                    new GoogleCompletePolicyCompiler.AppPermissions(
                        "com.example.lesson",
                        List.of(
                            new RuntimePermissionDecision(
                                "android.permission.CAMERA", PermissionDecision.DENY),
                            new RuntimePermissionDecision(
                                "android.permission.RECORD_AUDIO", PermissionDecision.PROMPT)))));
    document =
        new PolicyDocument(
            compiled.documentJson(), compiled.sha256(), "com.aimanager.child", 30, "DEVICE_OWNER");
    var policy = (ObjectNode) json.readTree(compiled.documentJson()).path("policy");
    policy.put("name", NAME).put("version", 1);
    var grants =
        (com.fasterxml.jackson.databind.node.ArrayNode)
            policy.path("applications").get(1).path("permissionGrants");
    var first = grants.get(0);
    var second = grants.get(1);
    grants.removeAll().add(second).add(first);
    response = json.writeValueAsString(policy);
    assertThat(gateway.writePolicyCandidate("e1", ID, document).providerVersion()).isEqualTo(1L);
    grants.remove(0);
    response = json.writeValueAsString(policy);
    readStatus = 200;
    assertThat(gateway.inspectCompletePolicy("e1", ID, document, 1L).state())
        .isEqualTo(CompletePolicyState.CONTENT_MISMATCH);
    assertThat(writes.get()).isEqualTo(1);
  }

  void assertWriteFailure(Outcome outcome) {
    assertThatThrownBy(() -> gateway.writePolicyCandidate("e1", ID, document))
        .isInstanceOfSatisfying(
            ManagedPolicyWriteException.class,
            error -> assertThat(error.outcome()).isEqualTo(outcome))
        .hasNoCause()
        .hasMessageNotContaining("provider-private-body")
        .hasMessageNotContaining(NAME);
  }
}
