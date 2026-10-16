package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import java.util.Arrays;
import java.util.Set;
import java.util.stream.Collectors;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

/** 发布签名由受控部署配置维护；空配置保持功能关闭，不采信设备自报的信任根。 */
@Component
final class ManagedAgentBindingSettings {
  final String packageName;
  final Set<String> certificates;

  ManagedAgentBindingSettings(
      @Value("${manager.emm.agent-binding.package-name:}") String packageName,
      @Value("${manager.emm.agent-binding.signing-certificates:}") String certificates) {
    this.packageName = packageName.trim();
    this.certificates =
        Arrays.stream(certificates.split(","))
            .map(String::trim)
            .filter(s -> !s.isEmpty())
            .collect(Collectors.toUnmodifiableSet());
    if ((!this.packageName.isEmpty()
            && (this.packageName.length() > 255
                || !this.packageName.matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+")))
        || this.certificates.size() > 8
        || this.certificates.stream().anyMatch(s -> !s.matches("[0-9a-f]{64}")))
      throw new IllegalArgumentException("Invalid managed agent release trust configuration");
  }

  boolean enabled(ManagedAndroidGateway gateway) {
    return !packageName.isEmpty()
        && !certificates.isEmpty()
        && gateway.available()
        && gateway.supportsAgentBindingEvidence();
  }

  /** 绑定成功时固定信任配置；排序消除配置排列差异，增删发布签名必须重新核验。 */
  String trustRevision() {
    return SecretMaterial.hash(
        packageName + "\n" + String.join("\n", certificates.stream().sorted().toList()));
  }

  void requireEnabled(ManagedAndroidGateway gateway) {
    if (!enabled(gateway))
      throw new DomainException(
          HttpStatus.SERVICE_UNAVAILABLE, "MANAGED_AGENT_BINDING_UNAVAILABLE");
  }
}
