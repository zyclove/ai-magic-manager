package com.aimanager.policy;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.fleet.Device;
import com.aimanager.shared.ItemPage;
import java.util.List;

/**
 * Device-only policy references. Caller must recheck the active credential after lifecycle locks.
 */
public interface DevicePolicyExceptionAccess {
  /** Policy -> subject -> device. No device-selected tenant or user membership is accepted. */
  Device lockRequestTarget(DeviceContext identity, String policyId);

  PolicyExceptionAccess.Baseline accessWindow(
      DeviceContext identity,
      String policyId,
      String versionId,
      String applicationId,
      List<String> ruleIds);

  ItemPage<PolicyExceptionAccess.WindowOptions> requestOptions(
      DeviceContext identity, int limit, String cursor);
}
