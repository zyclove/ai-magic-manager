package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway.PolicyDocument;
import com.aimanager.managedandroid.ManagedDesiredPolicy;
import com.aimanager.managedandroid.ManagedDeviceExecutionVerifier;
import com.aimanager.managedandroid.ManagedPolicyDocumentCompiler;
import java.util.Set;
import org.springframework.stereotype.Component;

/** Google format adapter only; registering it does not enable the Google gateway or writes. */
@Component
class GoogleManagedPolicyDocumentCompiler implements ManagedPolicyDocumentCompiler {
  @Override
  public String providerCode() {
    return "GOOGLE_AMAPI";
  }

  @Override
  public String adapterRevision() {
    return GoogleCompletePolicyCompiler.REVISION;
  }

  @Override
  public PolicyDocument compile(
      ManagedDesiredPolicy desired,
      String agentPackage,
      ManagedDeviceExecutionVerifier.Verified profile,
      Set<String> protectedPackages) {
    var compiled =
        new GoogleCompletePolicyCompiler(agentPackage, protectedPackages)
            .compileDesired(profile.apiLevel(), profile.managementMode(), desired);
    return new PolicyDocument(
        compiled.documentJson(),
        compiled.sha256(),
        agentPackage,
        profile.apiLevel(),
        profile.managementMode());
  }
}
