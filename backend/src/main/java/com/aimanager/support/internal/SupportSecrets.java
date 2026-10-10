package com.aimanager.support.internal;

import com.aimanager.shared.DomainException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.HexFormat;

/** Raw pairing codes are returned once; only their domain-separated digest is retained. */
final class SupportSecrets {
  private static final SecureRandom RANDOM = new SecureRandom();

  private SupportSecrets() {}

  static String issue() {
    byte[] bytes = new byte[32];
    RANDOM.nextBytes(bytes);
    return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
  }

  static String hash(String code) {
    if (code == null || !code.matches("[A-Za-z0-9_-]{43}"))
      throw DomainException.invalid("INVALID_SUPPORT_PAIRING_CODE");
    try {
      return HexFormat.of()
          .formatHex(
              MessageDigest.getInstance("SHA-256")
                  .digest(("support-pairing\0" + code).getBytes(StandardCharsets.UTF_8)));
    } catch (NoSuchAlgorithmException unavailable) {
      throw new IllegalStateException("SHA-256 unavailable", unavailable);
    }
  }
}
