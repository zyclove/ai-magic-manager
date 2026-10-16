package com.aimanager.managedandroid.internal;

import com.google.api.client.http.HttpHeaders;
import com.google.api.client.http.HttpResponseException;
import com.google.api.client.util.Data;
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

/** 官方 SDK 读取共用边界：限制体积、校验设备及目标唯一性、规范化 SHA-256。 */
final class GoogleApplicationReportReader {
  private static final int MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
  private static final int MAX_APPLICATIONS = 3000;
  private static final int MAX_SIGNERS = 8;

  private GoogleApplicationReportReader() {}

  static Device readDevice(AndroidManagement client, String deviceName, String fields)
      throws IOException {
    var request =
        client.enterprises().devices().get(deviceName).setFields(fields).buildHttpRequest();
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
    return device;
  }

  /** 缺少目标只代表暂无报告；身份冲突及重复报告必须拒绝。 */
  static ApplicationReport findApplication(Device device, String packageName) {
    var applications = device.getApplicationReports();
    if (applications == null) return null;
    if (applications.size() > MAX_APPLICATIONS) throw invalid();
    ApplicationReport target = null;
    for (var app : applications) {
      // SDK 将显式 JSON null 解析为占位对象，不能只判断 Java null。
      if (app == null || Data.isNull(app)) throw invalid();
      if (packageName.equals(app.getPackageName())) {
        if (target != null) throw invalid();
        target = app;
      }
    }
    return target;
  }

  static List<String> certificates(ApplicationReport app) {
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
