package com.aimanager.commerce.internal;

import com.aimanager.commerce.FamilyDeviceAccess;
import com.aimanager.tenant.FamilyCollaborationAdmission;
import java.util.List;
import org.springframework.stereotype.Service;

@Service
class FamilyCollaborationAdmissionService implements FamilyCollaborationAdmission {
  private final FamilyDeviceAccess devices;
  FamilyCollaborationAdmissionService(FamilyDeviceAccess devices) { this.devices=devices; }
  @Override public void requireNewGuardian(String tenantId) {
    devices.requireAdvancedService(tenantId,List.of());
  }
}
