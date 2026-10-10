package com.aimanager.observation;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.fleet.Device;
import java.util.List;

/** Current authorized observations for reports; never grants new access to private usage. */
public interface UsageReportSource {
  Snapshot read(String tenant, String actor, List<String> deviceIds, long from);

  /** Locks current scope/consent without loading observation payloads, for durable report jobs. */
  Snapshot authorize(String tenant, String actor, List<String> deviceIds);

  /** Revalidates the authenticated device, subject lifecycle and active credential under locks. */
  Snapshot readDevice(DeviceContext identity, long from);

  record Application(
      String packageName, String displayName, long start, long end, long foregroundMillis) {}

  record Batch(
      long sequence,
      String profile,
      long queryStart,
      long queryEnd,
      long observedAt,
      String timeZone,
      long receivedAt,
      List<Application> applications) {
    public Batch {
      applications = List.copyOf(applications);
    }
  }

  record DeviceData(
      Device device, ObservationSettings settings, long retentionFrom, List<Batch> batches) {
    public DeviceData {
      batches = List.copyOf(batches);
    }
  }

  record Snapshot(long generatedAt, List<DeviceData> devices) {
    public Snapshot {
      devices = List.copyOf(devices);
    }
  }
}
