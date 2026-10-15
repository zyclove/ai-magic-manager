package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAgentEvidence;
import com.google.api.client.http.HttpHeaders;
import com.google.api.client.http.HttpResponseException;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import com.google.api.services.androidmanagement.v1.model.ApplicationReport;
import com.google.api.services.androidmanagement.v1.model.Device;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.List;
import java.util.Optional;

/** 官方客户端的最小字段读取，限制响应大小；不抓取完整清单、应用消息或注册令牌。 */
final class GoogleManagedAgentEvidenceReader {
  private static final int MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
  private static final int MAX_APPLICATIONS = 3000;
  private static final int MAX_SIGNERS = 8;
  private static final int MAX_FEEDBACK_STATES = 1024;
  private static final int MAX_PROOF_CHARACTERS = 1000;
  private static final String FIELDS =
      "name,managementMode,lastStatusReportTime,"
          + "applicationReports(packageName,state,signingKeyCerts(signingKeyCertFingerprintSha256),"
          + "keyedAppStates(key,severity,data,lastUpdateTime))";

  private GoogleManagedAgentEvidenceReader() {}

  static Optional<ManagedAgentEvidence> read(
      AndroidManagement client, String deviceName, String packageName) throws IOException {
    var request =
        client.enterprises().devices().get(deviceName).setFields(FIELDS).buildHttpRequest();
    // 不让官方客户端先把未受限的错误响应解析进异常；保留其认证和传输设置。
    request.setThrowExceptionOnExecuteError(false);
    var response = request.execute();
    final Device device;
    try {
      if (!response.isSuccessStatusCode()) {
        throw new HttpResponseException.Builder(
                response.getStatusCode(),
                "Managed application evidence request failed",
                new HttpHeaders())
            .build();
      }
      try (var input = response.getContent()) {
        if (input == null) throw invalid();
        byte[] bytes = input.readNBytes(MAX_RESPONSE_BYTES + 1);
        if (bytes.length > MAX_RESPONSE_BYTES) throw invalid();
        device =
            client
                .getJsonFactory()
                .fromInputStream(
                    new ByteArrayInputStream(bytes), StandardCharsets.UTF_8, Device.class);
      }
    } finally {
      response.disconnect();
    }
    if (device == null || !deviceName.equals(device.getName())) throw invalid();
    var applications = device.getApplicationReports();
    if (applications == null) return Optional.empty();
    if (applications.size() > MAX_APPLICATIONS) throw invalid();
    ApplicationReport target = null;
    for (var app : applications) {
      if (app == null) throw invalid();
      if (packageName.equals(app.getPackageName())) {
        if (target != null) throw invalid();
        target = app;
      }
    }
    if (target == null || target.getKeyedAppStates() == null) return Optional.empty();
    var states = target.getKeyedAppStates();
    if (states.size() > MAX_FEEDBACK_STATES) throw invalid();
    com.google.api.services.androidmanagement.v1.model.KeyedAppState feedback = null;
    for (var state : states) {
      if (state == null) throw invalid();
      if (ManagedAgentEvidence.FEEDBACK_KEY.equals(state.getKey())) {
        if (feedback != null) throw invalid();
        feedback = state;
      }
    }
    if (feedback == null) return Optional.empty();
    if (feedback.getData() == null
        || feedback.getData().isEmpty()
        || feedback.getData().length() > MAX_PROOF_CHARACTERS) throw invalid();
    return Optional.of(
        new ManagedAgentEvidence(
            deviceName,
            device.getManagementMode(),
            packageName,
            target.getState(),
            certificates(target),
            feedback.getKey(),
            feedback.getSeverity(),
            feedback.getData(),
            feedback.getLastUpdateTime(),
            device.getLastStatusReportTime()));
  }

  private static List<String> certificates(ApplicationReport app) {
    var certificates = app.getSigningKeyCerts();
    if (certificates == null) return List.of();
    if (certificates.size() > MAX_SIGNERS) throw invalid();
    var result = new ArrayList<String>();
    var seen = new HashSet<String>();
    for (var cert : certificates) {
      if (cert == null || cert.getSigningKeyCertFingerprintSha256() == null) throw invalid();
      String encoded = cert.getSigningKeyCertFingerprintSha256();
      if (!encoded.matches("[A-Za-z0-9+/_-]{43}=?")) throw invalid();
      final byte[] decoded;
      try {
        decoded = cert.decodeSigningKeyCertFingerprintSha256();
      } catch (IllegalArgumentException malformed) {
        throw invalid();
      }
      // ProtoJSON accepts standard / URL-safe Base64 with or without padding.
      // The generated SDK itself emits URL-safe encoding; reject noncanonical pad bits.
      String unpadded = encoded.endsWith("=") ? encoded.substring(0, 43) : encoded;
      if (decoded.length != 32
          || (!Base64.getEncoder().withoutPadding().encodeToString(decoded).equals(unpadded)
              && !Base64.getUrlEncoder()
                  .withoutPadding()
                  .encodeToString(decoded)
                  .equals(unpadded))) {
        throw invalid();
      }
      String hash = HexFormat.of().formatHex(decoded);
      if (!seen.add(hash)) throw invalid();
      result.add(hash);
    }
    return List.copyOf(result);
  }

  private static IllegalStateException invalid() {
    return new IllegalStateException("Invalid managed application evidence response");
  }
}
