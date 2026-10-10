package com.aimanager.reporting.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.fleet.DeviceAccess;
import com.aimanager.observation.UsageReportSource;
import com.aimanager.shared.DomainException;
import com.aimanager.subject.SubjectAccess;
import com.aimanager.tenant.OrganizationRoster;
import com.aimanager.tenant.TenantAccess;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

/** Membership -> class (if selected) -> sorted subjects -> sorted devices. */
@Component
class UsageReportScope {
  private final TenantAccess access;
  private final DeviceAccess devices;
  private final SubjectAccess subjects;
  private final OrganizationRoster roster;

  UsageReportScope(
      TenantAccess access,
      DeviceAccess devices,
      SubjectAccess subjects,
      OrganizationRoster roster) {
    this.access = access;
    this.devices = devices;
    this.subjects = subjects;
    this.roster = roster;
  }

  record Selection(String kind, String id, Long version) {
    Selection {
      if (kind == null
          || !Set.of("DEVICES", "SUBJECT", "CLASS").contains(kind)
          || (kind.equals("DEVICES")
              ? (id != null || version != null)
              : (id == null
                  || !id.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")))
          || (kind.equals("CLASS")
              ? (version == null || version < 0 || version > 9007199254740991L)
              : version != null)) throw DomainException.invalid("INVALID_REPORT_SCOPE");
    }
  }

  Map<String, String> prepare(
      String tenant, String actor, List<String> deviceIds, Selection selection) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, CHILD);
    Set<String> allowed =
        selection.kind().equals("DEVICES")
            ? null
            : selection.kind().equals("SUBJECT")
                ? Set.of(selection.id())
                : roster
                    .lockForPrivateReport(tenant, actor, selection.id(), selection.version())
                    .subjectIds();
    var bindings = new TreeMap<String, String>();
    // Observe first, then acquire subject lifecycle locks before device locks.
    // The locked source snapshot below must match these exact bindings.
    for (var id : deviceIds) {
      var device = devices.requireVisible(tenant, actor, id);
      if (allowed != null && !allowed.contains(device.subjectId())) throw changed();
      bindings.put(id, device.subjectId());
    }
    for (var subject : new TreeSet<>(bindings.values()))
      subjects.lockActiveForScope(tenant, actor, subject);
    return Map.copyOf(bindings);
  }

  void verify(Map<String, String> bindings, UsageReportSource.Snapshot snapshot) {
    if (bindings.isEmpty()) return;
    if (snapshot.devices().size() != bindings.size()) throw changed();
    for (var data : snapshot.devices())
      if (!Objects.equals(bindings.get(data.device().id()), data.device().subjectId()))
        throw changed();
  }

  private DomainException changed() {
    return new DomainException(HttpStatus.CONFLICT, "REPORT_SCOPE_CHANGED");
  }
}
