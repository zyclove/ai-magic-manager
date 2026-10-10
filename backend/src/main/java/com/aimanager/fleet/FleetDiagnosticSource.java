package com.aimanager.fleet;

import java.util.List;

/** Internal module boundary; never serialize Snapshot directly into a diagnostic response. */
public interface FleetDiagnosticSource {
  /** Caller must hold current administrator membership and active subject lifecycle locks. */
  Snapshot snapshot(String tenantId, String actorId, String deviceId);

  /** Allows a scoped support grant to omit capability reads entirely. */
  Snapshot snapshot(String tenantId, String actorId, String deviceId, boolean includeCapabilities);

  /** Same caller authority/lifecycle requirements; locks only device metadata. */
  Device lockDevice(String tenantId, String actorId, String deviceId);

  record Snapshot(Device device, String agentVersion, List<CapabilityView> capabilities) {
    public Snapshot {
      capabilities = List.copyOf(capabilities);
    }
  }
}
