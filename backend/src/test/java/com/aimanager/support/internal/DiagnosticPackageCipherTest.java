package com.aimanager.support.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.shared.DomainException;
import com.nimbusds.jose.*;
import com.nimbusds.jose.jwk.*;
import java.nio.file.*;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class DiagnosticPackageCipherTest {
  @TempDir Path directory;

  Path ring(String id) throws Exception {
    byte[] key = new byte[32];
    new java.security.SecureRandom().nextBytes(key);
    var jwk =
        new OctetSequenceKey.Builder(key)
            .keyID(id)
            .keyUse(KeyUse.ENCRYPTION)
            .algorithm(JWEAlgorithm.DIR)
            .build();
    var path = directory.resolve(id + ".json");
    Files.writeString(path, new JWKSet(jwk).toString(false));
    return path;
  }

  @Test
  void authenticatedRoundTripBindsPurposeTenantJobAndScope() throws Exception {
    var cipher = new DiagnosticPackageCipher(ring("current").toString(), "current");
    byte[] plain =
        "{\"diagnostic\":\"PRIVATE_FIXTURE\"}".getBytes(java.nio.charset.StandardCharsets.UTF_8);
    var sealed = cipher.seal("tenant", "job", "scope", plain);
    assertFalse(sealed.contains("PRIVATE_FIXTURE"));
    assertArrayEquals(plain, cipher.open("tenant", "job", "scope", sealed));
    assertThrows(DomainException.class, () -> cipher.open("other", "job", "scope", sealed));
    assertThrows(DomainException.class, () -> cipher.open("tenant", "other", "scope", sealed));
    assertThrows(DomainException.class, () -> cipher.open("tenant", "job", "other", sealed));
    assertEquals(
        "device-diagnostic-v1", JWEObject.parse(sealed).getHeader().getCustomParam("purpose"));
    var parts = sealed.split("\\.", -1);
    parts[3] = (parts[3].startsWith("A") ? "B" : "A") + parts[3].substring(1);
    assertThrows(
        DomainException.class,
        () -> cipher.open("tenant", "job", "scope", String.join(".", parts)));
  }

  @Test
  void rejectsMissingKeysOversizeAndWrongPurposeWithoutSecretErrors() throws Exception {
    var absent = new DiagnosticPackageCipher("", "");
    assertFalse(absent.available());
    assertEquals(
        "DIAGNOSTIC_PACKAGE_UNAVAILABLE",
        assertThrows(DomainException.class, absent::requireAvailable).errorCode());
    var path = ring("key");
    var cipher = new DiagnosticPackageCipher(path.toString(), "");
    assertThrows(DomainException.class, () -> cipher.seal("t", "j", "b", new byte[512 * 1024 + 1]));
    assertThrows(DomainException.class, () -> cipher.open("t", "j", "b", "a".repeat(800000)));
    var key =
        ((OctetSequenceKey) JWKSet.parse(Files.readString(path)).getKeys().get(0)).toByteArray();
    var header =
        new JWEHeader.Builder(JWEAlgorithm.DIR, EncryptionMethod.A256GCM)
            .keyID("key")
            .customParam("purpose", "usage-report-v1")
            .customParam("tenant", "t")
            .customParam("job", "j")
            .customParam("binding", "b")
            .build();
    var jwe = new JWEObject(header, new Payload("{}"));
    jwe.encrypt(new com.nimbusds.jose.crypto.DirectEncrypter(key));
    assertThrows(DomainException.class, () -> cipher.open("t", "j", "b", jwe.serialize()));
  }

  @Test
  void rejectsInvalidConfigurationAndAmbiguousActiveKeys() throws Exception {
    Path invalid = directory.resolve("invalid.json");
    Files.writeString(invalid, "PRIVATE_BAD_KEY");
    var failure =
        assertThrows(
            IllegalStateException.class, () -> new DiagnosticPackageCipher(invalid.toString(), ""));
    assertFalse(failure.getMessage().contains("PRIVATE_BAD_KEY"));
    assertThrows(
        IllegalStateException.class, () -> new DiagnosticPackageCipher(directory.toString(), ""));
    var first = JWKSet.parse(Files.readString(ring("one"))).getKeys().get(0);
    var second = JWKSet.parse(Files.readString(ring("two"))).getKeys().get(0);
    Path both = directory.resolve("both.json");
    Files.writeString(both, new JWKSet(List.of(first, second)).toString(false));
    assertThrows(
        IllegalStateException.class, () -> new DiagnosticPackageCipher(both.toString(), ""));
    assertTrue(new DiagnosticPackageCipher(both.toString(), "two").available());
    assertThrows(
        IllegalStateException.class, () -> new DiagnosticPackageCipher(both.toString(), "missing"));
  }

  @Test
  void keyRotationRetainsOldArtifactsAndNeverUsesRetiredKeyForNewArtifacts() throws Exception {
    Path oldPath = ring("old"), newPath = ring("new");
    var old = new DiagnosticPackageCipher(oldPath.toString(), "old");
    byte[] plain = new byte[512 * 1024];
    new java.security.SecureRandom().nextBytes(plain);
    String artifact = old.seal("t", "j", "b", plain);
    Path both = directory.resolve("rotation.json");
    Files.writeString(
        both,
        new JWKSet(
                List.of(
                    JWKSet.parse(Files.readString(oldPath)).getKeys().get(0),
                    JWKSet.parse(Files.readString(newPath)).getKeys().get(0)))
            .toString(false));
    var rotated = new DiagnosticPackageCipher(both.toString(), "new");
    assertArrayEquals(plain, rotated.open("t", "j", "b", artifact));
    String next = rotated.seal("t", "j", "b", plain);
    assertEquals("new", JWEObject.parse(next).getHeader().getKeyID());
    assertThrows(DomainException.class, () -> old.open("t", "j", "b", next));
    var retired = new DiagnosticPackageCipher(newPath.toString(), "new");
    assertThrows(DomainException.class, () -> retired.open("t", "j", "b", artifact));
  }

  @Test
  void rejectsCompressedCiphertextEvenWhenAuthenticationIsValid() throws Exception {
    Path path = ring("compressed");
    var key =
        ((OctetSequenceKey) JWKSet.parse(Files.readString(path)).getKeys().get(0)).toByteArray();
    var header =
        new JWEHeader.Builder(JWEAlgorithm.DIR, EncryptionMethod.A256GCM)
            .keyID("compressed")
            .contentType("application/json")
            .compressionAlgorithm(CompressionAlgorithm.DEF)
            .customParam("purpose", "device-diagnostic-v1")
            .customParam("tenant", "t")
            .customParam("job", "j")
            .customParam("binding", "b")
            .build();
    var object = new JWEObject(header, new Payload("x".repeat(600000)));
    object.encrypt(new com.nimbusds.jose.crypto.DirectEncrypter(key));
    var cipher = new DiagnosticPackageCipher(path.toString(), "compressed");
    assertThrows(DomainException.class, () -> cipher.open("t", "j", "b", object.serialize()));
  }
}
