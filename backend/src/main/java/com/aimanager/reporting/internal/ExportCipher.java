package com.aimanager.reporting.internal;

import com.aimanager.shared.DomainException;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.*;
import com.nimbusds.jose.jwk.*;
import java.nio.file.*;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

/** Standard authenticated JWE with a bounded local key ring. Never logs secret parsing failures. */
@Component
final class ExportCipher {
  private final Map<String, byte[]> keys;
  private final String active;

  ExportCipher(
      @Value("${manager.exports.key-file:}") String file,
      @Value("${manager.exports.active-key-id:}") String activeId) {
    if (file.isBlank()) {
      keys = Map.of();
      active = null;
      return;
    }
    try {
      Path path = Path.of(file);
      if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) || Files.size(path) > 65536)
        throw new IllegalArgumentException();
      var parsed = JWKSet.parse(Files.readString(path));
      var ring = new HashMap<String, byte[]>();
      for (var key : parsed.getKeys()) {
        if (!(key instanceof OctetSequenceKey oct)
            || oct.size() != 256
            || key.getKeyID() == null
            || !key.getKeyID().matches("[A-Za-z0-9._-]{1,64}")
            || !KeyUse.ENCRYPTION.equals(key.getKeyUse())
            || !JWEAlgorithm.DIR.equals(key.getAlgorithm())
            || ring.putIfAbsent(key.getKeyID(), oct.toByteArray()) != null)
          throw new IllegalArgumentException();
      }
      if (ring.isEmpty() || ring.size() > 8) throw new IllegalArgumentException();
      active = activeId.isBlank() && ring.size() == 1 ? ring.keySet().iterator().next() : activeId;
      if (!ring.containsKey(active)) throw new IllegalArgumentException();
      keys = Map.copyOf(ring);
    } catch (Exception invalid) {
      throw new IllegalStateException("Invalid audit export key configuration");
    }
  }

  boolean available() {
    return active != null;
  }

  void requireAvailable() {
    if (!available()) throw unavailable();
  }

  String seal(String tenant, String job, String binding, byte[] plaintext) {
    return sealPurpose("audit-export-v1", tenant, job, binding, plaintext);
  }

  String sealUsage(String tenant, String job, String binding, byte[] plaintext) {
    return sealPurpose("usage-report-v1", tenant, job, binding, plaintext);
  }

  private String sealPurpose(
      String purpose, String tenant, String job, String binding, byte[] plaintext) {
    requireAvailable();
    try {
      var header =
          new JWEHeader.Builder(JWEAlgorithm.DIR, EncryptionMethod.A256GCM)
              .keyID(active)
              .contentType("application/json")
              .customParam("purpose", purpose)
              .customParam("tenant", tenant)
              .customParam("job", job)
              .customParam("binding", binding)
              .build();
      var jwe = new JWEObject(header, new Payload(plaintext));
      jwe.encrypt(new DirectEncrypter(keys.get(active)));
      return jwe.serialize();
    } catch (JOSEException failure) {
      throw unavailable();
    }
  }

  byte[] open(String tenant, String job, String binding, String encrypted) {
    return openPurpose("audit-export-v1", tenant, job, binding, encrypted);
  }

  byte[] openUsage(String tenant, String job, String binding, String encrypted) {
    return openPurpose("usage-report-v1", tenant, job, binding, encrypted);
  }

  private byte[] openPurpose(
      String purpose, String tenant, String job, String binding, String encrypted) {
    requireAvailable();
    try {
      if (encrypted == null || encrypted.length() > 12 * 1024 * 1024)
        throw new IllegalArgumentException();
      var jwe = JWEObject.parse(encrypted);
      var h = jwe.getHeader();
      if (!JWEAlgorithm.DIR.equals(h.getAlgorithm())
          || !EncryptionMethod.A256GCM.equals(h.getEncryptionMethod())
          || h.getCompressionAlgorithm() != null
          || h.getCriticalParams() != null
          || !purpose.equals(h.getCustomParam("purpose"))
          || !tenant.equals(h.getCustomParam("tenant"))
          || !job.equals(h.getCustomParam("job"))
          || !binding.equals(h.getCustomParam("binding"))
          || !keys.containsKey(h.getKeyID())) throw new IllegalArgumentException();
      jwe.decrypt(new DirectDecrypter(keys.get(h.getKeyID())));
      return jwe.getPayload().toBytes();
    } catch (Exception invalid) {
      throw unavailable();
    }
  }

  private static DomainException unavailable() {
    return new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "EXPORT_ARTIFACT_UNAVAILABLE");
  }
}
