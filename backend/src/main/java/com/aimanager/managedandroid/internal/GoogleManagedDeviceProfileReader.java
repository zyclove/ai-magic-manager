package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedDeviceExecutionProfile;
import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.google.api.client.http.HttpHeaders;
import com.google.api.client.http.HttpResponseException;
import com.google.api.services.androidmanagement.v1.AndroidManagement;
import java.io.IOException;
import java.time.Instant;

/** Minimal provider facts. Only an actual HTTP 404 returns null; no write is ever sent. */
final class GoogleManagedDeviceProfileReader {
  private static final org.slf4j.Logger LOG =
      org.slf4j.LoggerFactory.getLogger(GoogleManagedDeviceProfileReader.class);
  private static final int MAX_BYTES = 128 * 1024;
  private static final String FIELDS =
      "name,managementMode,apiLevel,state,appliedState,lastStatusReportTime";
  private static final ObjectMapper JSON =
      new ObjectMapper(
              JsonFactory.builder().enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION).build())
          .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS);

  private GoogleManagedDeviceProfileReader() {}

  static ManagedDeviceExecutionProfile read(AndroidManagement client, String deviceName) {
    if (deviceName == null
        || !deviceName.matches("enterprises/[A-Za-z0-9_-]{1,128}/devices/[A-Za-z0-9_-]{1,128}"))
      throw new IllegalArgumentException("Invalid managed device resource");
    try {
      var request =
          client.enterprises().devices().get(deviceName).setFields(FIELDS).buildHttpRequest();
      request
          .setNumberOfRetries(0)
          .setFollowRedirects(false)
          .setThrowExceptionOnExecuteError(false);
      request.setIOExceptionHandler(null).setUnsuccessfulResponseHandler(null);
      request.setLoggingEnabled(false).setCurlLoggingEnabled(false);
      request.setConnectTimeout(boundedTimeout(request.getConnectTimeout(), 10000));
      request.setReadTimeout(boundedTimeout(request.getReadTimeout(), 15000));
      var response = request.execute();
      try {
        if (response.getStatusCode() == 404) return null;
        if (!response.isSuccessStatusCode())
          throw new HttpResponseException.Builder(
                  response.getStatusCode(), "Managed device profile read failed", new HttpHeaders())
              .build();
        try (var input = response.getContent()) {
          if (input == null) throw invalid();
          byte[] bytes = input.readNBytes(MAX_BYTES + 1);
          if (bytes.length > MAX_BYTES) throw invalid();
          var body = JSON.readTree(bytes);
          if (body == null || !body.isObject() || !deviceName.equals(text(body, "name", 512)))
            throw invalid();
          var api = body.get("apiLevel");
          if (api == null
              || !api.isIntegralNumber()
              || !api.canConvertToInt()
              || api.intValue() < 1) throw invalid();
          String mode = enumeration(body, "managementMode");
          String state = enumeration(body, "state");
          String appliedState = enumeration(body, "appliedState");
          String reportedAt = text(body, "lastStatusReportTime", 64);
          Instant.parse(reportedAt);
          return new ManagedDeviceExecutionProfile(
              deviceName, mode, api.intValue(), state, appliedState, reportedAt);
        }
      } finally {
        response.disconnect();
      }
    } catch (IOException | RuntimeException failure) {
      int status = failure instanceof HttpResponseException http ? http.getStatusCode() : 0;
      LOG.warn(
          "Managed device profile read failed: status={}, errorType={}",
          status,
          failure.getClass().getSimpleName());
      throw invalid();
    }
  }

  private static String enumeration(JsonNode object, String key) {
    String value = text(object, key, 64);
    if (!value.matches("[A-Z][A-Z0-9_]*")) throw invalid();
    return value;
  }

  private static String text(JsonNode object, String key, int maximum) {
    var value = object.get(key);
    if (value == null
        || !value.isTextual()
        || value.textValue().isBlank()
        || value.textValue().length() > maximum) throw invalid();
    return value.textValue();
  }

  private static int boundedTimeout(int configured, int maximum) {
    return configured <= 0 ? maximum : Math.min(configured, maximum);
  }

  private static IllegalStateException invalid() {
    return new IllegalStateException("Invalid or unavailable managed device execution profile");
  }
}
