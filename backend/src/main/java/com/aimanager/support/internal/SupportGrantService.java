package com.aimanager.support.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.fleet.*;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.*;
import com.aimanager.shared.*;
import com.aimanager.subject.SubjectAccess;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

@Service
class SupportGrantService {
  private final TenantAccess access;
  private final RecentAuthentication recent;
  private final DeviceAccess devices;
  private final SubjectAccess subjects;
  private final FleetDiagnosticSource fleet;
  private final SupportGrantStore store;
  private final SupportPairingService pairings;
  private final IdempotencyService idempotency;
  private final AuditService audit;
  private final SupportDiagnosticReader diagnostics;
  private final Clock clock;

  SupportGrantService(
      TenantAccess access,
      RecentAuthentication recent,
      DeviceAccess devices,
      SubjectAccess subjects,
      FleetDiagnosticSource fleet,
      SupportGrantStore store,
      SupportPairingService pairings,
      IdempotencyService idempotency,
      AuditService audit,
      SupportDiagnosticReader diagnostics,
      Clock clock) {
    this.access = access;
    this.recent = recent;
    this.devices = devices;
    this.subjects = subjects;
    this.fleet = fleet;
    this.store = store;
    this.pairings = pairings;
    this.idempotency = idempotency;
    this.audit = audit;
    this.diagnostics = diagnostics;
    this.clock = clock;
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public SupportGrantStore.Grant create(
      String tenant, String device, Jwt actor, Create input, String etag, String key) {
    long memberVersion =
        access.requireWriteVersion(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
    recent.require(actor);
    key(key);
    int types = SupportGrantTypes.mask(input.diagnosticTypes());
    if (input.durationMinutes() < 5 || input.durationMinutes() > 1440)
      throw DomainException.invalid("INVALID_SUPPORT_GRANT_DURATION");
    long expected = ResourceVersions.require(etag);
    String codeHash = SupportSecrets.hash(input.pairingCode());
    store.head(tenant);
    var observed = devices.requireVisible(tenant, actor.getSubject(), device);
    subjects.lockActiveForScope(tenant, actor.getSubject(), observed.subjectId());
    var current = fleet.lockDevice(tenant, actor.getSubject(), device);
    if (!current.subjectId().equals(observed.subjectId())
        || !current.registrationId().equals(input.registrationId()))
      throw new DomainException(HttpStatus.CONFLICT, "SUPPORT_DEVICE_SCOPE_CHANGED");
    if (current.state() != Device.State.ACTIVE) throw DomainException.denied();
    var ref =
        idempotency.execute(
            tenant,
            actor.getSubject(),
            "support-grant.create",
            key,
            Map.of(
                "device",
                device,
                "registration",
                input.registrationId(),
                "pairingHash",
                codeHash,
                "recipient",
                input.recipientActorId(),
                "types",
                types,
                "minutes",
                input.durationMinutes(),
                "deviceVersion",
                expected),
            SupportGrantStore.Reference.class,
            () -> {
              ResourceVersions.check(expected, current.version());
              var active =
                  store.db.queryForList(
                      "SELECT id,device_id FROM support_grants WHERE tenant_id=? AND state='ACTIVE'"
                          + " AND expires_at>? ORDER BY id LIMIT 201 FOR UPDATE",
                      tenant,
                      clock.millis());
              if (active.size() >= 200
                  || active.stream().filter(r -> device.equals(r.get("device_id"))).count() >= 20)
                throw new DomainException(HttpStatus.CONFLICT, "SUPPORT_GRANT_CAPACITY_REACHED");
              var pairing =
                  pairings.consume(
                      input.pairingCode(), input.recipientActorId(), actor.getSubject());
              String id = UUID.randomUUID().toString();
              long now = clock.millis();
              store.db.update(
                  "INSERT INTO"
                      + " support_grants(id,tenant_id,device_id,subject_id,registration_id,creator_actor_id,creator_key,creator_member_version,recipient_actor_id,recipient_key,recipient_display_name,recipient_verified_email,pairing_id,type_mask,state,created_at,expires_at,updated_at)"
                      + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,'ACTIVE',?,?,?)",
                  id,
                  tenant,
                  device,
                  current.subjectId(),
                  current.registrationId(),
                  actor.getSubject(),
                  ActorKeys.key(actor.getSubject()),
                  memberVersion,
                  pairing.recipientActorId(),
                  ActorKeys.key(pairing.recipientActorId()),
                  pairing.displayName(),
                  pairing.verifiedEmail(),
                  pairing.id(),
                  types,
                  now,
                  now + input.durationMinutes() * 60000L,
                  now);
              audit.record(tenant, actor.getSubject(), "SUPPORT_GRANT_CREATED", id);
              return new SupportGrantStore.Reference(id);
            });
    return store.view(store.customer(tenant, ref.id(), false));
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public SupportGrantStore.Grant revoke(
      String tenant, String id, Jwt actor, String etag, String key) {
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
    recent.require(actor);
    key(key);
    var current = store.customer(tenant, id, true);
    long expected = ResourceVersions.require(etag);
    var ref =
        idempotency.execute(
            tenant,
            actor.getSubject(),
            "support-grant.revoke",
            key,
            Map.of("id", id, "version", expected),
            SupportGrantStore.Reference.class,
            () -> {
              ResourceVersions.check(expected, current.version());
              if (!current.state().equals("REVOKED")) {
                store.db.update(
                    "UPDATE support_grants SET state='REVOKED',version=version+1,updated_at=? WHERE"
                        + " tenant_id=? AND id=?",
                    clock.millis(),
                    tenant,
                    id);
                audit.record(tenant, actor.getSubject(), "SUPPORT_GRANT_REVOKED", id);
              }
              return new SupportGrantStore.Reference(id);
            });
    return store.view(store.customer(tenant, ref.id(), false));
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public ItemPage<SupportGrantStore.Grant> customerList(
      String tenant, Jwt actor, int limit, String cursor) {
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
    recent.require(actor);
    ItemPage.validate(limit, cursor);
    var rows =
        store.db.query(
            "SELECT * FROM support_grants WHERE tenant_id=? AND id>? ORDER BY id LIMIT ?",
            store::map,
            tenant,
            cursor == null ? "" : cursor,
            limit + 1);
    return ItemPage.from(
        rows.stream().map(store::view).toList(), limit, SupportGrantStore.Grant::id);
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public SupportGrantStore.Grant customerGet(String tenant, String id, Jwt actor) {
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
    recent.require(actor);
    return store.view(store.customer(tenant, id, false));
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public ItemPage<SupportGrantStore.Grant> recipientList(
      Jwt actor, boolean adult, int limit, String cursor) {
    recipient(actor, adult);
    ItemPage.validate(limit, cursor);
    var rows =
        store.db.query(
            "SELECT * FROM support_grants WHERE recipient_key=? AND id>? ORDER BY id LIMIT ?",
            store::map,
            ActorKeys.key(actor.getSubject()),
            cursor == null ? "" : cursor,
            limit + 1);
    return ItemPage.from(
        rows.stream().map(store::view).toList(), limit, SupportGrantStore.Grant::id);
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public SupportGrantStore.Grant recipientGet(String id, Jwt actor, boolean adult) {
    recipient(actor, adult);
    return store.view(store.recipient(id, actor.getSubject(), false));
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public byte[] preview(String id, Jwt actor, boolean adult) {
    recipient(actor, adult);
    var observed = store.recipient(id, actor.getSubject(), false);
    active(observed);
    long version =
        access.requireWriteVersion(
            observed.tenantId(), observed.creatorActorId(), OWNER, GUARDIAN, ORG_ADMIN);
    if (version != observed.creatorMemberVersion()) throw DomainException.denied();
    subjects.lockActiveForScope(
        observed.tenantId(), observed.creatorActorId(), observed.subjectId());
    var source =
        fleet.snapshot(
            observed.tenantId(),
            observed.creatorActorId(),
            observed.deviceId(),
            SupportGrantTypes.has(observed.typeMask(), SupportGrantTypes.CAPABILITIES));
    if (source.device().state() != Device.State.ACTIVE
        || !source.device().registrationId().equals(observed.registrationId())
        || !source.device().subjectId().equals(observed.subjectId()))
      throw DomainException.denied();
    var current = store.recipient(id, actor.getSubject(), true);
    if (!current.creatorActorId().equals(observed.creatorActorId())
        || current.creatorMemberVersion() != version
        || !current.registrationId().equals(observed.registrationId())
        || !current.deviceId().equals(observed.deviceId())
        || !current.subjectId().equals(observed.subjectId())
        || !current.tenantId().equals(observed.tenantId())
        || current.typeMask() != observed.typeMask()) throw DomainException.denied();
    active(current);
    byte[] bytes = diagnostics.read(current, source);
    active(current);
    audit.record(current.tenantId(), actor.getSubject(), "SUPPORT_DIAGNOSTIC_PREVIEWED", id);
    return bytes;
  }

  private void active(SupportGrantStore.Row row) {
    if (!row.state().equals("ACTIVE") || row.expiresAt() <= clock.millis())
      throw DomainException.denied();
  }

  private void recipient(Jwt actor, boolean adult) {
    if (!adult) throw DomainException.denied();
    recent.require(actor);
  }

  private void key(String key) {
    if (key == null || key.isBlank() || key.length() > 128)
      throw DomainException.invalid("INVALID_IDEMPOTENCY_KEY");
  }

  record Create(
      String pairingCode,
      String recipientActorId,
      String registrationId,
      List<String> diagnosticTypes,
      int durationMinutes) {}
}
