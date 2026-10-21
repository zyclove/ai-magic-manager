package com.aimanager.family;

import com.aimanager.shared.DomainException;
import com.aimanager.shared.SafetyCriticalPackages;
import java.util.HashSet;
import java.util.List;

/** Family assistance only: never confers device-owner or managed enforcement capability. */
public record FamilyRuleSpec(boolean enabled, int dailyAllowanceSeconds, String timeZoneId,
    List<String> meteredPackages, List<Window> allowedWindows) {
  public record Window(List<Integer> daysOfWeek, int startMinute, int endMinute) {}
  public FamilyRuleSpec validated() {
    if (!"Asia/Shanghai".equals(timeZoneId) || dailyAllowanceSeconds < 0 || dailyAllowanceSeconds > 86400
        || meteredPackages == null || meteredPackages.size() > 100 || allowedWindows == null || allowedWindows.size() > 14)
      throw DomainException.invalid("INVALID_FAMILY_RULES");
    var seen = new HashSet<String>();
    for (String pkg : meteredPackages) {
      if (pkg == null || !pkg.matches("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+")
          || pkg.length()>255 || !seen.add(pkg) || SafetyCriticalPackages.withAdditional("").contains(pkg)
          || pkg.startsWith("com.aimanager.") || pkg.endsWith(".launcher") || pkg.contains(".launcher3"))
        throw DomainException.invalid("UNSAFE_FAMILY_APPLICATION");
    }
    if (enabled && meteredPackages.isEmpty()) throw DomainException.invalid("FAMILY_APPLICATION_REQUIRED");
    for (Window window : allowedWindows) {
      if (window == null || window.daysOfWeek() == null || window.daysOfWeek().isEmpty() || window.daysOfWeek().size()>7
          || new HashSet<>(window.daysOfWeek()).size()!=window.daysOfWeek().size()
          || window.daysOfWeek().stream().anyMatch(day -> day==null || day<1 || day>7)
          || window.startMinute()<0 || window.startMinute()>1439 || window.endMinute()<0 || window.endMinute()>1439
          || window.startMinute()==window.endMinute()) throw DomainException.invalid("INVALID_FAMILY_WINDOW");
    }
    return new FamilyRuleSpec(enabled,dailyAllowanceSeconds,timeZoneId,List.copyOf(meteredPackages),
        allowedWindows.stream().map(w->new Window(List.copyOf(w.daysOfWeek()),w.startMinute(),w.endMinute())).toList());
  }
}
