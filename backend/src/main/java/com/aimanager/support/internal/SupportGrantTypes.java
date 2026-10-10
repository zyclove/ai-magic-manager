package com.aimanager.support.internal;

import com.aimanager.shared.DomainException;
import java.util.*;
import org.springframework.http.HttpStatus;

final class SupportGrantTypes {
  static final int STATUS = 1, CAPABILITIES = 2, CONFIGURATIONS = 4;
  private static final List<String> TYPES =
      List.of("DEVICE_STATUS", "CAPABILITIES", "CONFIGURATION_METADATA");

  private SupportGrantTypes() {}

  static int mask(List<String> input) {
    if (input == null
        || input.isEmpty()
        || input.size() > 3
        || new HashSet<>(input).size() != input.size()
        || !TYPES.containsAll(input))
      throw DomainException.invalid("INVALID_SUPPORT_DIAGNOSTIC_TYPES");
    int value = 0;
    for (String type : input) value |= 1 << TYPES.indexOf(type);
    return value;
  }

  static List<String> list(int mask) {
    if (mask < 1 || mask > 7)
      throw new DomainException(HttpStatus.BAD_GATEWAY, "SUPPORT_GRANT_INVALID");
    var values = new ArrayList<String>();
    for (int i = 0; i < TYPES.size(); i++) if ((mask & (1 << i)) != 0) values.add(TYPES.get(i));
    return List.copyOf(values);
  }

  static boolean has(int mask, int type) {
    list(mask);
    return (mask & type) != 0;
  }
}
