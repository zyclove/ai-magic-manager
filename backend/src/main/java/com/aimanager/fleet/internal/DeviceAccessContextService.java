package com.aimanager.fleet.internal;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.fleet.DeviceAccess;
import com.aimanager.shared.DomainException;
import com.aimanager.subject.SubjectAccess;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Reuses the lifecycle/credential lock order used by device access delivery.
 * An authenticated principal alone is insufficient after concurrent revocation.
 */
@Service
class DeviceAccessContextService {
  private final DeviceAccess devices;
  private final SubjectAccess subjects;
  private final DeviceCredentials credentials;

  DeviceAccessContextService(DeviceAccess devices, SubjectAccess subjects, DeviceCredentials credentials) {
    this.devices = devices;
    this.subjects = subjects;
    this.credentials = credentials;
  }

  @Transactional(timeout = 10)
  public Binding current(DeviceContext identity) {
    var observed = devices.observeActive(identity);
    boolean subjectActive = subjects.lockForDevice(identity.tenantId(), observed.subjectId());
    var current = devices.lockActive(identity);
    if (!current.subjectId().equals(observed.subjectId())) {
      throw new DomainException(HttpStatus.CONFLICT, "ACCESS_TARGET_CHANGED");
    }
    credentials.requireActive(identity);
    if (!subjectActive) throw DomainException.denied();
    return new Binding(identity.tenantId(), current.subjectId(), current.id(), current.registrationId());
  }

  /** Only scope facts; no profile, keys, issuer configuration or execution claims. */
  record Binding(String tenantId, String subjectId, String deviceId, String registrationId) {
    @Override public String toString() { return "Binding[authenticated-scope]"; }
  }
}
