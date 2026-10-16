package com.aimanager.managedandroid.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.commerce.CommercialCapacity;
import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.fleet.Device;
import com.aimanager.fleet.FleetPolicyAccess;
import com.aimanager.fleet.RegistrationKeys;
import com.aimanager.managedandroid.ManagedAgentEvidence;
import com.aimanager.managedandroid.ManagedAgentProofVerifier;
import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedEnterpriseAuthority;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.subject.SubjectAccess;
import com.aimanager.tenant.TenantAccess;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.util.Optional;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

/** 关联账本与短事务。远端读取由编排层执行，事务内再次核验所有可撤销授权。 */
@Service
@Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
class ManagedAgentBindingStore {
  private final JdbcTemplate db;
  private final TenantAccess access;
  private final ManagedEnrollmentStore enrollments;
  private final ManagedEnterpriseAuthority enterprises;
  private final SubjectAccess subjects;
  private final FleetPolicyAccess fleet;
  private final RegistrationKeys keys;
  private final DeviceCredentials credentials;
  private final CommercialCapacity capacity;
  private final AuditService audit;
  private final Clock clock;
  private final ManagedAgentBindingSettings settings;
  private final ManagedAndroidGateway gateway;
  private final ManagedAgentProofVerifier verifier;

  ManagedAgentBindingStore(
      JdbcTemplate db,
      TenantAccess access,
      ManagedEnrollmentStore enrollments,
      ManagedEnterpriseAuthority enterprises,
      SubjectAccess subjects,
      FleetPolicyAccess fleet,
      RegistrationKeys keys,
      DeviceCredentials credentials,
      CommercialCapacity capacity,
      AuditService audit,
      Clock clock,
      ManagedAgentBindingSettings settings,
      ManagedAndroidGateway gateway) {
    this.db = db;
    this.access = access;
    this.enrollments = enrollments;
    this.enterprises = enterprises;
    this.subjects = subjects;
    this.fleet = fleet;
    this.keys = keys;
    this.credentials = credentials;
    this.capacity = capacity;
    this.audit = audit;
    this.clock = clock;
    this.settings = settings;
    this.gateway = gateway;
    this.verifier = new ManagedAgentProofVerifier(clock);
  }

  View create(
      String tenant,
      String actor,
      String request,
      String enrollment,
      String device,
      String registration) {
    id(request);
    id(enrollment);
    id(device);
    id(registration);
    settings.requireEnabled(gateway);
    var context = context(tenant, actor, enrollment, device, registration);
    var previous =
        db.query(
            "SELECT * FROM managed_agent_bindings WHERE tenant_id=? AND request_key=?",
            (r, n) -> row(r),
            tenant,
            request);
    if (!previous.isEmpty()) {
      var old = previous.get(0);
      if (!old.requestedBy().equals(actor)
          || !old.enrollmentId().equals(enrollment)
          || !old.deviceId().equals(device)
          || !old.registrationId().equals(registration))
        throw conflict("MANAGED_BINDING_REQUEST_REUSED");
      return view(old);
    }
    // 企业行锁串行化同租户发起；数据库唯一槽同时保护多副本及意外重复写入。
    var occupied =
        db.query(
            "SELECT * FROM managed_agent_bindings WHERE tenant_id=?"
                + " AND (active_device_id=? OR active_enrollment_id=?) FOR UPDATE",
            (r, n) -> row(r),
            tenant,
            device,
            enrollment);
    for (var old : occupied) {
      if ("PENDING".equals(old.state()) && old.expiresAt() <= clock.millis()) expire(old);
      else throw conflict("MANAGED_BINDING_ALREADY_EXISTS");
    }
    long recent =
        db.queryForObject(
            "SELECT COUNT(*) FROM managed_agent_bindings WHERE tenant_id=?"
                + " AND device_id=? AND created_at>?",
            Long.class,
            tenant,
            device,
            clock.millis() - 3_600_000L);
    if (recent >= 10)
      throw new DomainException(HttpStatus.TOO_MANY_REQUESTS, "MANAGED_BINDING_RATE_LIMITED");
    long pending =
        db.queryForObject(
            "SELECT COUNT(*) FROM managed_agent_bindings WHERE tenant_id=?"
                + " AND state='PENDING' AND expires_at>?",
            Long.class,
            tenant,
            clock.millis());
    if (pending >= 1000) throw conflict("MANAGED_BINDING_PENDING_LIMIT");
    var intent = context.intent();
    long now = clock.millis();
    String binding = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO managed_agent_bindings(tenant_id,id,subject_id,enrollment_id,device_id,"
            + "registration_id,key_thumbprint,provider,enterprise_id,enterprise_binding_version,provider_device_id,"
            + "package_name,request_key,requested_by,nonce,state,version,active_device_id,active_enrollment_id,created_at,expires_at,updated_at,next_verification_at)"
            + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'PENDING',1,?,?,?,?,?,0)",
        tenant,
        binding,
        intent.subjectId(),
        enrollment,
        device,
        registration,
        context.key().thumbprint(),
        intent.provider(),
        intent.enterpriseId(),
        intent.bindingVersion(),
        intent.providerDeviceId(),
        settings.packageName,
        request,
        actor,
        SecretMaterial.token(),
        device,
        enrollment,
        now,
        now + 600_000L,
        now);
    audit.record(tenant, actor, "MANAGED_AGENT_BINDING_REQUESTED", binding);
    return view(required(tenant, binding, false));
  }

  /** 获取远端读取所需的受信上下文，并对轮询做每请求限流；不在事务内访问网络。 */
  Row capture(String tenant, String actor, String binding, long version) {
    access.requireWriteRole(tenant, actor, OWNER, ORG_ADMIN);
    var before = required(tenant, binding, false);
    var context =
        context(tenant, actor, before.enrollmentId(), before.deviceId(), before.registrationId());
    var current = required(tenant, binding, true);
    checkPending(current, version);
    match(current, context);
    if (current.nextVerificationAt() > clock.millis())
      throw new DomainException(
          HttpStatus.TOO_MANY_REQUESTS, "MANAGED_BINDING_VERIFY_RATE_LIMITED");
    db.update(
        "UPDATE managed_agent_bindings SET next_verification_at=? WHERE tenant_id=? AND id=?",
        clock.millis() + 5000L,
        tenant,
        binding);
    return current;
  }

  /** 确认使用当前注册公钥，消费、摘要及审计在同一事务提交，旧证据不能复活已撤销请求。 */
  View complete(
      String tenant,
      String actor,
      String binding,
      long version,
      ManagedAndroidGateway.ManagedEnrollmentIdentity first,
      ManagedAndroidGateway.ManagedEnrollmentIdentity last,
      ManagedAgentEvidence evidence) {
    access.requireWriteRole(tenant, actor, OWNER, ORG_ADMIN);
    var before = required(tenant, binding, false);
    var context =
        context(tenant, actor, before.enrollmentId(), before.deviceId(), before.registrationId());
    var current = required(tenant, binding, true);
    checkPending(current, version);
    match(current, context);
    var intent = context.intent();
    ManagedEnrollmentStore.requireProvenance(intent, current.providerDeviceId(), first);
    ManagedEnrollmentStore.requireProvenance(intent, current.providerDeviceId(), last);
    var verified =
        verifier.verify(
            new ManagedAgentProofVerifier.Expected(
                current.id(),
                current.nonce(),
                current.createdAt(),
                current.expiresAt(),
                "enterprises/" + current.enterpriseId() + "/devices/" + current.providerDeviceId(),
                current.packageName(),
                context.key().publicJwk(),
                settings.certificates),
            evidence);
    if (!current.keyThumbprint().equals(verified.keyThumbprint()))
      throw conflict("MANAGED_BINDING_REGISTRATION_CHANGED");
    db.update(
        "UPDATE managed_agent_bindings SET"
            + " state='VERIFIED',version=version+1,nonce=NULL,agent_trust_revision=?,proof_sha256=?,proof_id=?,feedback_at=?,reported_at=?,verified_at=?,updated_at=?"
            + " WHERE tenant_id=? AND id=?",
        settings.trustRevision(),
        verified.proofSha256(),
        verified.proofId(),
        verified.feedbackAt(),
        verified.reportedAt(),
        clock.millis(),
        clock.millis(),
        tenant,
        binding);
    audit.record(tenant, actor, "MANAGED_AGENT_BINDING_VERIFIED", binding);
    return view(required(tenant, binding, false));
  }

  View revoke(String tenant, String actor, String binding, long version) {
    access.requireWriteRole(tenant, actor, OWNER, ORG_ADMIN);
    var current = required(tenant, binding, true);
    ResourceVersions.check(version, current.version());
    if ("REVOKED".equals(current.state())) return view(current);
    db.update(
        "UPDATE managed_agent_bindings SET"
            + " state='REVOKED',version=version+1,nonce=NULL,active_device_id=NULL,active_enrollment_id=NULL,revoked_at=?,updated_at=?"
            + " WHERE tenant_id=? AND id=?",
        clock.millis(),
        clock.millis(),
        tenant,
        binding);
    audit.record(tenant, actor, "MANAGED_AGENT_BINDING_REVOKED", binding);
    return view(required(tenant, binding, false));
  }

  View get(String tenant, String actor, String binding) {
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN, AUDITOR);
    return view(required(tenant, binding, false));
  }

  /** 供应用证据工作流读取当前绑定；不是系统执行授权或面向客户端的 DTO。 */
  VerifiedBindingContext requireVerifiedContext(
      String tenant, String actor, String binding, long version) {
    long authorityVersion = access.requireWriteVersion(tenant, actor, OWNER, ORG_ADMIN);
    var before = required(tenant, binding, false);
    var context =
        context(tenant, actor, before.enrollmentId(), before.deviceId(), before.registrationId());
    // 与创建/消费流程保持相同的领域锁顺序，不先锁绑定再等待企业或设备。
    var current = required(tenant, binding, true);
    ResourceVersions.check(version, current.version());
    if (!"VERIFIED".equals(current.state())) throw conflict("MANAGED_BINDING_NOT_VERIFIED");
    match(current, context);
    var intent = context.intent();
    if (!current.subjectId().equals(intent.subjectId()))
      throw conflict("MANAGED_BINDING_CONTEXT_CHANGED");
    if (!current.provider().equals(gateway.providerCode()))
      throw conflict("MANAGED_BINDING_PROVIDER_CHANGED");
    if (!"DEVICE_OWNER".equals(intent.providerMode()))
      throw conflict("MANAGED_BINDING_MODE_UNSUPPORTED");
    if (current.verifiedAt() == null
        || current.verifiedAt() < current.createdAt()
        || current.verifiedAt() > clock.millis()
        || current.nonce() != null
        || !current.deviceId().equals(current.activeDeviceId())
        || !current.enrollmentId().equals(current.activeEnrollmentId()))
      throw conflict("MANAGED_BINDING_VERIFICATION_INVALID");
    if (!settings.trustRevision().equals(current.agentTrustRevision()))
      throw conflict("MANAGED_BINDING_RELEASE_TRUST_CHANGED");
    return new VerifiedBindingContext(
        tenant,
        actor,
        authorityVersion,
        current.subjectId(),
        current.deviceId(),
        current.registrationId(),
        current.keyThumbprint(),
        current.id(),
        current.version(),
        current.enrollmentId(),
        intent.version(),
        current.provider(),
        current.enterpriseId(),
        current.enterpriseVersion(),
        current.providerDeviceId(),
        intent.providerMode(),
        current.verifiedAt(),
        current.packageName(),
        current.agentTrustRevision());
  }

  ItemPage<View> list(String tenant, String actor, int limit, String cursor) {
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN, AUDITOR);
    ItemPage.validate(limit, cursor);
    var rows =
        db.query(
            "SELECT * FROM managed_agent_bindings WHERE tenant_id=? AND id>? ORDER BY id LIMIT ?",
            (r, n) -> view(row(r)),
            tenant,
            cursor == null ? "" : cursor,
            limit + 1);
    return ItemPage.from(rows, limit, View::id);
  }

  /** 一次读取选择流程所需的非秘密资料；不做远端调用，也不代表写操作获得授权。 */
  ContextView selectionContext(
      String tenant, String actor, String enrollment, int limit, String cursor) {
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN, AUDITOR);
    id(enrollment);
    ItemPage.validate(limit, cursor);
    var intent = enrollments.get(tenant, enrollment, actor);
    String reason = "READY";
    if (!"VERIFIED".equals(intent.state())) reason = "ENROLLMENT_NOT_VERIFIED";
    else if (!subjects.active(tenant, intent.subjectId())) reason = "SUBJECT_INACTIVE";
    else if (settings.packageName.isEmpty() || settings.certificates.isEmpty())
      reason = "RELEASE_TRUST_REQUIRED";
    else if (!gateway.available()) reason = "EMM_UNAVAILABLE";
    else if (!gateway.supportsAgentBindingEvidence()) reason = "PROVIDER_EVIDENCE_UNSUPPORTED";
    else {
      try {
        enrollments.forProviderStatus(tenant, enrollment, actor);
      } catch (DomainException failure) {
        if (!java.util.Set.of(
                "ENTERPRISE_BINDING_NOT_ACTIVE",
                "MANAGED_ANDROID_CONTRACT_REQUIRED",
                "MANAGED_ENTERPRISE_CHANGED",
                "EMM_PROVIDER_MISMATCH",
                "EMM_UNAVAILABLE",
                "ENTERPRISE_BINDING_NOT_FOUND")
            .contains(failure.errorCode())) throw failure;
        reason = failure.errorCode();
      }
    }
    var current =
        db.query(
            "SELECT * FROM managed_agent_bindings WHERE tenant_id=? AND active_enrollment_id=?",
            (r, n) -> view(row(r)),
            tenant,
            enrollment);
    if (current.size() > 1) throw conflict("MANAGED_BINDING_AMBIGUOUS");
    return new ContextView(
        enrollment,
        intent.subjectId(),
        "READY".equals(reason),
        reason,
        current.isEmpty() ? null : current.get(0),
        fleet.activeForSubject(tenant, actor, intent.subjectId(), limit, cursor));
  }

  Optional<Challenge> challenge(DeviceContext identity) {
    credentials.requireActive(identity);
    if (!settings.enabled(gateway)) return Optional.empty();
    var rows =
        db.query(
            "SELECT * FROM managed_agent_bindings WHERE tenant_id=? AND active_device_id=?"
                + " AND registration_id=? AND state='PENDING' AND expires_at>?",
            (r, n) -> row(r),
            identity.tenantId(),
            identity.deviceId(),
            identity.registrationId(),
            clock.millis());
    if (rows.isEmpty()) return Optional.empty();
    if (rows.size() != 1) throw conflict("MANAGED_BINDING_AMBIGUOUS");
    var current = rows.get(0);
    var key = keys.key(identity.tenantId(), identity.deviceId(), identity.registrationId());
    var enterprise = enterprises.requireActive(identity.tenantId());
    if (key.state() != Device.State.ACTIVE
        || !key.thumbprint().equals(current.keyThumbprint())
        || !subjects.active(identity.tenantId(), current.subjectId())
        || !current.packageName().equals(settings.packageName)
        || !current.provider().equals(enterprise.provider())
        || !current.enterpriseId().equals(enterprise.enterpriseId())
        || current.enterpriseVersion() != enterprise.bindingVersion())
      throw DomainException.denied();
    return Optional.of(
        new Challenge(
            current.id(),
            current.nonce(),
            ManagedAgentProofVerifier.AUDIENCE,
            current.createdAt(),
            current.expiresAt()));
  }

  /** 配置化有界批次，终态更新串行化，多副本重复清理不会重复写审计。 */
  int expireBatch(int limit) {
    if (limit < 1 || limit > 1000)
      throw new IllegalArgumentException("Invalid managed binding expiry batch");
    var candidates =
        db.query(
            "SELECT * FROM managed_agent_bindings WHERE state='PENDING' AND expires_at<=?"
                + " ORDER BY expires_at,id LIMIT ?",
            (r, n) -> row(r),
            clock.millis(),
            limit);
    int count = 0;
    for (var candidate : candidates) {
      var current = required(candidate.tenantId(), candidate.id(), true);
      if ("PENDING".equals(current.state()) && current.expiresAt() <= clock.millis()) {
        expire(current);
        count++;
      }
    }
    return count;
  }

  private void expire(Row row) {
    db.update(
        "UPDATE managed_agent_bindings SET"
            + " state='EXPIRED',version=version+1,nonce=NULL,active_device_id=NULL,active_enrollment_id=NULL,updated_at=?"
            + " WHERE tenant_id=? AND id=?",
        clock.millis(),
        row.tenantId(),
        row.id());
    audit.record(
        row.tenantId(), "system:managed-agent-expiry", "MANAGED_AGENT_BINDING_EXPIRED", row.id());
  }

  private Context context(
      String tenant, String actor, String enrollment, String device, String registration) {
    access.requireWriteRole(tenant, actor, OWNER, ORG_ADMIN);
    settings.requireEnabled(gateway);
    var enterpriseRows =
        db.queryForList(
            "SELECT version FROM managed_enterprise_bindings WHERE tenant_id=? FOR UPDATE", tenant);
    if (enterpriseRows.size() != 1) throw DomainException.denied();
    var intent = enrollments.forProviderStatus(tenant, enrollment, actor);
    if (!subjects.lockForDevice(tenant, intent.subjectId()))
      throw conflict("MANAGED_BINDING_SUBJECT_INACTIVE");
    var target = fleet.snapshot(tenant, actor, device, true).device();
    if (target.state() != Device.State.ACTIVE
        || !registration.equals(target.registrationId())
        || !intent.subjectId().equals(target.subjectId()))
      throw conflict("MANAGED_BINDING_DEVICE_MISMATCH");
    var key = keys.key(tenant, device, registration);
    if (key.state() != Device.State.ACTIVE || !key.thumbprint().equals(target.keyThumbprint()))
      throw conflict("MANAGED_BINDING_REGISTRATION_CHANGED");
    // 合同容量锁与撤销串行化；之后重新读取机构合同资格，避免网络期间的资格变化。
    if (capacity.currentForUpdate(tenant) <= 0) throw conflict("MANAGED_ANDROID_CONTRACT_REQUIRED");
    var current = enterprises.requireActive(tenant);
    if (!intent.provider().equals(current.provider())
        || !intent.enterpriseId().equals(current.enterpriseId())
        || intent.bindingVersion() != current.bindingVersion())
      throw conflict("MANAGED_ENTERPRISE_CHANGED");
    return new Context(intent, key);
  }

  private void match(Row row, Context context) {
    var intent = context.intent();
    if (!row.provider().equals(intent.provider())
        || !row.enterpriseId().equals(intent.enterpriseId())
        || row.enterpriseVersion() != intent.bindingVersion()
        || !row.providerDeviceId().equals(intent.providerDeviceId())
        || !row.keyThumbprint().equals(context.key().thumbprint())
        || !row.packageName().equals(settings.packageName))
      throw conflict("MANAGED_BINDING_CONTEXT_CHANGED");
  }

  private void checkPending(Row row, long version) {
    ResourceVersions.check(version, row.version());
    if (!"PENDING".equals(row.state())) throw conflict("MANAGED_BINDING_NOT_PENDING");
    if (row.expiresAt() <= clock.millis()) throw conflict("MANAGED_BINDING_EXPIRED");
  }

  private Row required(String tenant, String binding, boolean lock) {
    id(binding);
    var rows =
        db.query(
            "SELECT * FROM managed_agent_bindings WHERE tenant_id=? AND id=?"
                + (lock ? " FOR UPDATE" : ""),
            (r, n) -> row(r),
            tenant,
            binding);
    if (rows.size() != 1)
      throw new DomainException(HttpStatus.NOT_FOUND, "MANAGED_BINDING_NOT_FOUND");
    return rows.get(0);
  }

  private View view(Row row) {
    String state =
        "PENDING".equals(row.state()) && row.expiresAt() <= clock.millis()
            ? "EXPIRED"
            : row.state();
    return new View(
        row.id(),
        row.enrollmentId(),
        row.deviceId(),
        row.registrationId(),
        state,
        row.version(),
        row.createdAt(),
        row.expiresAt(),
        row.verifiedAt(),
        false);
  }

  static void id(String value) {
    try {
      if (value == null || !UUID.fromString(value).toString().equals(value))
        throw new IllegalArgumentException();
    } catch (IllegalArgumentException failure) {
      throw DomainException.invalid("INVALID_MANAGED_BINDING_ID");
    }
  }

  private static DomainException conflict(String code) {
    return new DomainException(HttpStatus.CONFLICT, code);
  }

  private static Row row(ResultSet r) throws SQLException {
    return new Row(
        r.getString("tenant_id"),
        r.getString("id"),
        r.getString("subject_id"),
        r.getString("enrollment_id"),
        r.getString("device_id"),
        r.getString("registration_id"),
        r.getString("key_thumbprint"),
        r.getString("provider"),
        r.getString("enterprise_id"),
        r.getLong("enterprise_binding_version"),
        r.getString("provider_device_id"),
        r.getString("package_name"),
        r.getString("requested_by"),
        r.getString("nonce"),
        r.getString("state"),
        r.getLong("version"),
        r.getLong("created_at"),
        r.getLong("expires_at"),
        r.getLong("next_verification_at"),
        r.getObject("verified_at", Long.class),
        r.getString("active_device_id"),
        r.getString("active_enrollment_id"),
        r.getString("agent_trust_revision"));
  }

  private record Context(ManagedEnrollmentStore.Intent intent, RegistrationKeys.Key key) {}

  /** 最小服务端快照；不携带挑战、证明、注册公钥或提供方注册令牌。 */
  record VerifiedBindingContext(
      String tenantId,
      String actorId,
      long authorityVersion,
      String subjectId,
      String deviceId,
      String registrationId,
      String keyThumbprint,
      String bindingId,
      long bindingVersion,
      String enrollmentId,
      long enrollmentVersion,
      String provider,
      String enterpriseId,
      long enterpriseBindingVersion,
      String providerDeviceId,
      String managementMode,
      long bindingVerifiedAt,
      String agentPackageName,
      String agentTrustRevision) {
    @Override
    public String toString() {
      return "VerifiedManagedBindingContext[REDACTED]";
    }
  }

  record ContextView(
      String enrollmentId,
      String subjectId,
      boolean ready,
      String reasonCode,
      View currentBinding,
      ItemPage<Device> candidates) {}

  record Row(
      String tenantId,
      String id,
      String subjectId,
      String enrollmentId,
      String deviceId,
      String registrationId,
      String keyThumbprint,
      String provider,
      String enterpriseId,
      long enterpriseVersion,
      String providerDeviceId,
      String packageName,
      String requestedBy,
      String nonce,
      String state,
      long version,
      long createdAt,
      long expiresAt,
      long nextVerificationAt,
      Long verifiedAt,
      String activeDeviceId,
      String activeEnrollmentId,
      String agentTrustRevision) {
    @Override
    public String toString() {
      return "ManagedAgentBinding[REDACTED]";
    }
  }

  record View(
      String id,
      String enrollmentId,
      String deviceId,
      String registrationId,
      String state,
      long version,
      long createdAt,
      long expiresAt,
      Long verifiedAt,
      boolean systemControlAvailable) {}

  record Challenge(
      String challengeId, String nonce, String audience, long createdAt, long expiresAt) {
    @Override
    public String toString() {
      return "ManagedAgentChallenge[REDACTED]";
    }
  }
}
