package com.aimanager.approval.internal;

import com.aimanager.approval.AccessRequest;
import com.aimanager.deviceidentity.*;
import com.aimanager.fleet.*;
import com.aimanager.policy.*;
import com.aimanager.shared.*;
import com.aimanager.subject.SubjectAccess;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Device scope never grants a user role. Authentication is rechecked inside each transaction. */
@Service
class DeviceAccessSubmissionService {
  private final ApprovalService approvals;
  private final DevicePolicyExceptionAccess policies;
  private final DeviceAccess devices;
  private final SubjectAccess subjects;
  private final DeviceCredentials credentials;

  DeviceAccessSubmissionService(
      ApprovalService approvals,
      DevicePolicyExceptionAccess policies,
      DeviceAccess devices,
      SubjectAccess subjects,
      DeviceCredentials credentials) {
    this.approvals = approvals;
    this.policies = policies;
    this.devices = devices;
    this.subjects = subjects;
    this.credentials = credentials;
  }

  @Transactional(timeout = 10)
  public AccessRequest create(
      DeviceContext identity, DeviceAccessSubmissionController.Create input, String key) {
    var target = policies.lockRequestTarget(identity, input.policyId());
    credentials.requireActive(identity);
    return approvals.createForDevice(
        identity, target.subjectId(), input.forDevice(identity.deviceId()), key);
  }

  @Transactional(timeout = 10)
  public ItemPage<PolicyExceptionAccess.WindowOptions> options(
      DeviceContext identity, int limit, String cursor) {
    authenticate(identity);
    return policies.requestOptions(identity, limit, cursor);
  }

  @Transactional(timeout = 10)
  public ItemPage<AccessRequest> list(DeviceContext identity, int limit, String cursor) {
    var target = authenticate(identity);
    return approvals.listForDevice(identity, target.subjectId(), limit, cursor);
  }

  @Transactional(timeout = 10)
  public AccessRequest get(DeviceContext identity, String id) {
    var target = authenticate(identity);
    return approvals.getForDevice(identity, target.subjectId(), id);
  }

  @Transactional(timeout = 10)
  public AccessRequest cancel(DeviceContext identity, String id, String etag, String key) {
    var target = authenticate(identity);
    return approvals.cancelForDevice(identity, target.subjectId(), id, etag, key);
  }

  private Device authenticate(DeviceContext identity) {
    var observed = devices.observeActive(identity);
    boolean active = subjects.lockForDevice(identity.tenantId(), observed.subjectId());
    var current = devices.lockActive(identity);
    if (!current.subjectId().equals(observed.subjectId()))
      throw new DomainException(HttpStatus.CONFLICT, "ACCESS_TARGET_CHANGED");
    credentials.requireActive(identity);
    if (!active) throw DomainException.denied();
    return current;
  }
}
