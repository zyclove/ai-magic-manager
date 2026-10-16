package com.aimanager.managedandroid;

import java.util.List;

/**
 * 提供方返回的单个应用事实，不代表租户授权、当前注册、用户空间或应用身份已核验。
 * 调用方须结合当前绑定及报告时间验证；字段缺失不允许推断为安装成功。
 * 该对象只用于服务端连接器，不接受设备客户端上传作为受信证据。
 */
public record ManagedApplicationReport(
    String deviceName,
    String managementMode,
    String packageName,
    String applicationState,
    List<String> signingCertificateSha256,
    String deviceReportedAt) {
  public ManagedApplicationReport {
    signingCertificateSha256 =
        signingCertificateSha256 == null ? List.of() : List.copyOf(signingCertificateSha256);
  }

  /** 避免普通诊断日志携带稳定设备标识、包名及证书。 */
  @Override
  public String toString() {
    return "ManagedApplicationReport[REDACTED]";
  }
}
