package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway.PolicyDocument;
import com.aimanager.managedandroid.ManagedDesiredPolicy;
import com.aimanager.managedandroid.ManagedDeviceExecutionVerifier;
import com.aimanager.managedandroid.ManagedPolicyDocumentCompiler;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

/** Immutable, unambiguous provider selection and the shared durable document envelope boundary. */
@Component
class ManagedPolicyDocumentCompilers {
  private static final int MAX_BYTES = 65536;
  private static final ObjectMapper JSON =
      new ObjectMapper(
              JsonFactory.builder().enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION).build())
          .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
          .enable(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS);
  private final Map<String, Entry> entries;

  ManagedPolicyDocumentCompilers(List<ManagedPolicyDocumentCompiler> compilers) {
    var configured = new HashMap<String, Entry>();
    try {
      for (var compiler : Objects.requireNonNull(compilers)) {
        String provider = compiler.providerCode(), revision = compiler.adapterRevision();
        if (provider == null
            || !provider.matches("[A-Z][A-Z0-9_]{2,31}")
            || revision == null
            || !revision.matches("[A-Za-z0-9._:-]{1,128}")
            || configured.putIfAbsent(provider, new Entry(provider, revision, compiler)) != null)
          throw new IllegalArgumentException();
      }
    } catch (RuntimeException invalid) {
      throw new IllegalArgumentException("Invalid managed policy compiler configuration");
    }
    entries = Map.copyOf(configured);
  }

  boolean supports(String provider) {
    return provider != null && entries.containsKey(provider);
  }

  /** Stable registered semantics for compatibility qualification and evidence invalidation. */
  String revision(String provider) {
    if (!supports(provider)) return null;
    try {
      var entry = entries.get(provider);
      entry.requireStable();
      return entry.revision();
    } catch (RuntimeException invalid) {
      throw new IllegalArgumentException("Invalid managed policy compiler configuration");
    }
  }

  PolicyDocument compile(
      String provider,
      String agentPackage,
      ManagedDeviceExecutionVerifier.Verified profile,
      ManagedDesiredPolicy desired,
      Set<String> protectedPackages) {
    if (!supports(provider))
      throw new DomainException(
          HttpStatus.SERVICE_UNAVAILABLE, "MANAGED_PREPARATION_COMPILER_UNAVAILABLE");
    var entry = entries.get(provider);
    try {
      if (agentPackage == null
          || !agentPackage.matches("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+")
          || profile == null
          || profile.apiLevel() < 30
          || !"DEVICE_OWNER".equals(profile.managementMode())
          || desired == null) throw new IllegalArgumentException();
      entry.requireStable();
      var document =
          entry.compiler().compile(desired, agentPackage, profile, Set.copyOf(protectedPackages));
      entry.requireStable();
      if (document == null
          || !agentPackage.equals(document.agentPackage())
          || profile.apiLevel() != document.apiLevel()
          || !Objects.equals(profile.managementMode(), document.managementMode())
          || document.documentJson() == null
          || document.documentJson().length() > MAX_BYTES
          || document.documentJson().getBytes(StandardCharsets.UTF_8).length > MAX_BYTES
          || document.sha256() == null
          || !document.sha256().matches("[0-9a-f]{64}")
          || !SecretMaterial.hash(document.documentJson()).equals(document.sha256()))
        throw new IllegalArgumentException();
      Map<?, ?> envelope = JSON.readValue(document.documentJson(), Map.class);
      if (envelope == null
          || !envelope.keySet().equals(Set.of("schemaVersion", "adapterRevision", "policy"))
          || !Integer.valueOf(1).equals(envelope.get("schemaVersion"))
          || !entry.revision().equals(envelope.get("adapterRevision"))
          || !(envelope.get("policy") instanceof Map<?, ?>)
          || !JSON.writeValueAsString(envelope).equals(document.documentJson()))
        throw new IllegalArgumentException();
      return document;
    } catch (Exception invalid) {
      // Plugin messages may contain private policy/provider data. Preserve neither body nor cause.
      throw new IllegalArgumentException("Invalid managed policy compiler output");
    }
  }

  private record Entry(String provider, String revision, ManagedPolicyDocumentCompiler compiler) {
    void requireStable() {
      if (!provider.equals(compiler.providerCode()) || !revision.equals(compiler.adapterRevision()))
        throw new IllegalArgumentException();
    }
  }
}
