package com.aimanager.policy.internal;

import com.aimanager.shared.DomainException;
import java.net.IDN;
import java.util.Arrays;
import java.util.Locale;

/** DNS names only; performs no DNS lookup and does not accept URLs or IP literals. */
final class DomainNames {
  private DomainNames() {}

  static String canonical(String value) {
    try {
      String domain = IDN.toASCII(value, IDN.USE_STD3_ASCII_RULES).toLowerCase(Locale.ROOT);
      if (domain.length() > 253
          || !domain.contains(".")
          || domain.endsWith(".")
          || domain.matches("[0-9.]+")
          || Arrays.stream(domain.split("\\.", -1))
              .anyMatch(label -> label.isEmpty() || label.length() > 63))
        throw DomainException.invalid("INVALID_DOMAIN");
      return domain;
    } catch (IllegalArgumentException failure) {
      throw DomainException.invalid("INVALID_DOMAIN");
    }
  }
}
