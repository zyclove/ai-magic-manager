package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAgentEvidence;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import java.io.IOException;
import java.util.Optional;

/** 官方客户端的最小字段读取，限制响应大小；不抓取完整清单、应用消息或注册令牌。 */
final class GoogleManagedAgentEvidenceReader {
  private static final int MAX_FEEDBACK_STATES = 1024;
  private static final int MAX_PROOF_CHARACTERS = 1000;
  private static final String FIELDS =
      "name,managementMode,lastStatusReportTime,"
          + "applicationReports(packageName,state,signingKeyCerts(signingKeyCertFingerprintSha256),"
          + "keyedAppStates(key,severity,data,lastUpdateTime))";

  private GoogleManagedAgentEvidenceReader() {}

  static Optional<ManagedAgentEvidence> read(
      AndroidManagement client, String deviceName, String packageName) throws IOException {
    var device = GoogleApplicationReportReader.readDevice(client, deviceName, FIELDS);
    var target = GoogleApplicationReportReader.findApplication(device, packageName);
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
            GoogleApplicationReportReader.certificates(target),
            feedback.getKey(),
            feedback.getSeverity(),
            feedback.getData(),
            feedback.getLastUpdateTime(),
            device.getLastStatusReportTime()));
  }

  private static IllegalStateException invalid() {
    return new IllegalStateException("Invalid managed application evidence response");
  }
}
