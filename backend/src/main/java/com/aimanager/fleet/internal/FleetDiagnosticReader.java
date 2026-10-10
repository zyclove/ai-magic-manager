package com.aimanager.fleet.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.fleet.Device;
import com.aimanager.fleet.FleetDiagnosticSource;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import java.util.List;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

@Service
class FleetDiagnosticReader implements FleetDiagnosticSource {
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final FleetReads fleet;

  FleetDiagnosticReader(JdbcTemplate jdbc, TenantAccess access, FleetReads fleet) {
    this.jdbc = jdbc;
    this.access = access;
    this.fleet = fleet;
  }

  @Override
  @Transactional(propagation = Propagation.MANDATORY)
  public Snapshot snapshot(String tenant, String actor, String device) {
    return snapshot(tenant, actor, device, true);
  }

  @Override
  @Transactional(propagation = Propagation.MANDATORY)
  public Device lockDevice(String tenant, String actor, String device) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    var rows =
        jdbc.queryForList(
            "SELECT id FROM devices WHERE tenant_id=? AND id=? FOR UPDATE",
            String.class,
            tenant,
            device);
    if (rows.size() != 1) throw DomainException.denied();
    return fleet.rawDevice(tenant, device);
  }

  @Override
  @Transactional(propagation = Propagation.MANDATORY)
  public Snapshot snapshot(
      String tenant, String actor, String device, boolean includeCapabilities) {
    var current = lockDevice(tenant, actor, device);
    // A bounded current read avoids an old REPEATABLE READ count and bounds materialization.
    if (includeCapabilities) {
      var keys =
          jdbc.queryForList(
              "SELECT capability_key FROM device_capabilities WHERE tenant_id=?"
                  + " AND device_id=? ORDER BY capability_key LIMIT 65 FOR UPDATE",
              String.class,
              tenant,
              device);
      if (keys.size() > 64)
        throw new DomainException(HttpStatus.PAYLOAD_TOO_LARGE, "DIAGNOSTIC_TOO_LARGE");
    }
    var capabilities =
        includeCapabilities
            ? fleet.snapshot(tenant, actor, device, true).capabilities()
            : List.<com.aimanager.fleet.CapabilityView>of();
    String agent =
        jdbc.queryForObject(
            "SELECT agent_version FROM devices WHERE tenant_id=? AND id=?"
                + " AND registration_id=? FOR UPDATE",
            String.class,
            tenant,
            device,
            current.registrationId());
    return new Snapshot(current, agent, capabilities);
  }
}
