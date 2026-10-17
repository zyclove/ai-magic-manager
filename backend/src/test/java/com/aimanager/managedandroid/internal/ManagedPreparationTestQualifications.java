package com.aimanager.managedandroid.internal;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.ManagedControlOperation;
import java.util.List;

/**
 * Explicit fixture for tests focused on compilation or publication authority, not qualification.
 */
final class ManagedPreparationTestQualifications {
  private ManagedPreparationTestQualifications() {}

  static ManagedPolicyControlAdmission allow() {
    var admission = mock(ManagedPolicyControlAdmission.class);
    when(admission.check(any(), any()))
        .thenReturn(
            new ManagedPolicyControlAdmission.Checked(List.of(), List.of(), Long.MAX_VALUE));
    return admission;
  }

  static List<ManagedControlOperation> launchAndCamera() {
    return List.of(
        new ManagedControlOperation(
            ManagedControlOperation.Kind.APP_LAUNCH, ManagedControlOperation.Effect.DENY, null),
        new ManagedControlOperation(
            ManagedControlOperation.Kind.RUNTIME_PERMISSION,
            ManagedControlOperation.Effect.DENY,
            "android.permission.CAMERA"));
  }
}
