package com.aimanager.support.internal;

import com.aimanager.shared.DomainException;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.*;
import com.nimbusds.jose.jwk.*;
import java.nio.file.*;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

/** Independent key ring and fixed JWE purpose for bounded, authenticated diagnostic artifacts. */
@Component
class DiagnosticPackageCipher {
  static final int MAX_BYTES = 512 * 1024;
  private final Map<String, byte[]> keys;
  private final String active;

  DiagnosticPackageCipher(
      @Value("${manager.diagnostic-packages.key-file:}") String file,
      @Value("${manager.diagnostic-packages.active-key-id:}") String activeId) {
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
      throw new IllegalStateException("Invalid diagnostic package key configuration");
    }
  }

  boolean available() {
    return active != null;
  }

  void requireAvailable() {
    if (!available()) throw unavailable();
  }

  String seal(String tenant, String job, String binding, byte[] plaintext) {
    requireAvailable();
    if (plaintext == null || plaintext.length == 0 || plaintext.length > MAX_BYTES)
      throw unavailable();
    try {
      var header =
          new JWEHeader.Builder(JWEAlgorithm.DIR, EncryptionMethod.A256GCM)
              .keyID(active)
              .contentType("application/json")
              .customParam("purpose", "device-diagnostic-v1")
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
    requireAvailable();
    try {
      if (encrypted == null || encrypted.length() > 768 * 1024)
        throw new IllegalArgumentException();
      var jwe = JWEObject.parse(encrypted);
      var header = jwe.getHeader();
      if (!JWEAlgorithm.DIR.equals(header.getAlgorithm())
          || !EncryptionMethod.A256GCM.equals(header.getEncryptionMethod())
          || header.getCompressionAlgorithm() != null
          || header.getCriticalParams() != null
          || !"application/json".equals(header.getContentType())
          || !"device-diagnostic-v1".equals(header.getCustomParam("purpose"))
          || !tenant.equals(header.getCustomParam("tenant"))
          || !job.equals(header.getCustomParam("job"))
          || !binding.equals(header.getCustomParam("binding"))
          || !keys.containsKey(header.getKeyID())) throw new IllegalArgumentException();
      jwe.decrypt(new DirectDecrypter(keys.get(header.getKeyID())));
      byte[] bytes = jwe.getPayload().toBytes();
      if (bytes.length == 0 || bytes.length > MAX_BYTES) throw new IllegalArgumentException();
      return bytes;
    } catch (Exception invalid) {
      throw unavailable();
    }
  }

  private static DomainException unavailable() {
    return new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "DIAGNOSTIC_PACKAGE_UNAVAILABLE");
  }
}
