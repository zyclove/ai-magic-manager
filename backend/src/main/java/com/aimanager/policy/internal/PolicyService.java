package com.aimanager.policy.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.catalog.ApplicationCatalog;
import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.fleet.AccessRequestDeviceScope;
import com.aimanager.fleet.Device;
import com.aimanager.fleet.DeviceAccess;
import com.aimanager.fleet.FleetPolicyAccess;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.ActorKeys;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.policy.*;
import com.aimanager.schedule.ScheduleCatalog;
import com.aimanager.schedule.ScheduleEntry;
import com.aimanager.shared.*;
import com.aimanager.subject.SubjectAccess;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import java.time.Clock;
import java.util.*;
import org.slf4j.MDC;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
class PolicyService
    implements PolicyReadAccess, PolicyExceptionAccess, DevicePolicyExceptionAccess {
  @org.springframework.context.event.EventListener
  @org.springframework.core.annotation.Order(-200)
  @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
  public void ownershipTransferred(com.aimanager.tenant.OwnershipTransferred event) {
    invalidatePreviews(
        event.tenantId(),
        event.formerOwnerActorKey(),
        event.occurredAt(),
        "POLICY_PREVIEWS_OWNERSHIP_INVALIDATED");
  }

  @org.springframework.context.event.EventListener
  @org.springframework.core.annotation.Order(-200)
  @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
  public void membershipAccessChanged(com.aimanager.tenant.MembershipAccessChanged event) {
    invalidatePreviews(
        event.tenantId(),
        event.actorKey(),
        event.occurredAt(),
        "POLICY_PREVIEWS_ACCESS_INVALIDATED");
  }

  private void invalidatePreviews(String tenant, String actorKey, long now, String action) {
    // Legacy previews have no creator: require a new review instead of guessing attribution.
    int changed =
        jdbc.update(
            "UPDATE policy_previews SET expires_at=? WHERE tenant_id=? AND expires_at>? AND"
                + " (creator_actor_key=? OR creator_actor_key IS NULL) AND NOT EXISTS (SELECT 1"
                + " FROM policy_versions v WHERE v.tenant_id=policy_previews.tenant_id AND"
                + " v.preview_id=policy_previews.id)",
            now,
            tenant,
            now,
            actorKey);
    if (changed > 0) audit.record(tenant, "system:membership", action, actorKey);
  }

  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final AuditService audit;
  private final ObjectMapper mapper;
  private final Clock clock;
  private final IdempotencyService idempotency;
  private final RecentAuthentication recent;
  private final ApplicationCatalog catalog;
  private final ScheduleCatalog schedules;
  private final FleetPolicyAccess fleet;
  private final DeviceAccess devices;
  private final AccessRequestDeviceScope requestDevices;
  private final SubjectAccess subjects;
  private final RuleCompiler compiler;
  private final long previewTtlMillis;
  private final ApplicationEventPublisher events;

  PolicyService(
      JdbcTemplate jdbc,
      TenantAccess access,
      AuditService audit,
      ObjectMapper mapper,
      Clock clock,
      IdempotencyService idempotency,
      RecentAuthentication recent,
      ApplicationCatalog catalog,
      ScheduleCatalog schedules,
      FleetPolicyAccess fleet,
      DeviceAccess devices,
      AccessRequestDeviceScope requestDevices,
      SubjectAccess subjects,
      RuleCompiler compiler,
      ApplicationEventPublisher events,
      @Value("${manager.policies.preview-ttl-seconds:300}") long previewTtl) {
    if (previewTtl < 30 || previewTtl > 900)
      throw new IllegalArgumentException("Invalid preview lifetime");
    this.jdbc = jdbc;
    this.access = access;
    this.audit = audit;
    this.mapper = mapper;
    this.clock = clock;
    this.idempotency = idempotency;
    this.recent = recent;
    this.catalog = catalog;
    this.schedules = schedules;
    this.fleet = fleet;
    this.compiler = compiler;
    this.previewTtlMillis = previewTtl * 1000;
    this.devices = devices;
    this.requestDevices = requestDevices;
    this.subjects = subjects;
    this.events = events;
  }

  @Transactional(timeout = 10)
  public PolicyDraft create(
      String tenant, String actor, PolicyController.CreateDraft input, String key) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    resolve(tenant, actor, input.rules());
    return idempotency.execute(
        tenant,
        actor,
        "policy.create",
        key,
        Map.of("input", input),
        PolicyDraft.class,
        () -> insertDraft(tenant, actor, input.name(), input.kind(), input.rules(), null));
  }

  private PolicyDraft insertDraft(
      String tenant,
      String actor,
      String name,
      PolicyDraft.Kind kind,
      List<PolicyRule> rules,
      String sourceVersion) {
    String id = UUID.randomUUID().toString();
    jdbc.update(
        "INSERT INTO"
            + " policy_drafts(tenant_id,id,name,kind,rules_json,source_version_id,created_at,updated_at)"
            + " VALUES(?,?,?,?,?,?,?,?)",
        tenant,
        id,
        name.strip(),
        kind.name(),
        json(rules),
        sourceVersion,
        clock.millis(),
        clock.millis());
    audit.record(
        tenant,
        actor,
        sourceVersion == null ? "POLICY_DRAFT_CREATED" : "POLICY_ROLLBACK_DRAFT_CREATED",
        id);
    return new PolicyDraft(id, name.strip(), kind, 0, List.copyOf(rules), sourceVersion);
  }

  PolicyDraft get(String tenant, String actor, String id) {
    access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
    return readDraft(tenant, id, false);
  }

  ItemPage<PolicyDraft> list(
      String tenant, String actor, int limit, String cursor, PolicyDraft.Kind kind) {
    access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
    ItemPage.validate(limit, cursor);
    String filter = kind == null ? "" : " AND kind=?";
    Object[] args =
        kind == null
            ? new Object[] {tenant, cursor == null ? "" : cursor, limit + 1}
            : new Object[] {tenant, cursor == null ? "" : cursor, kind.name(), limit + 1};
    return ItemPage.from(
        jdbc.query(
            "SELECT * FROM policy_drafts WHERE tenant_id=? AND id>?"
                + filter
                + " ORDER BY id LIMIT ?",
            (row, index) ->
                new PolicyDraft(
                    row.getString("id"),
                    row.getString("name"),
                    PolicyDraft.Kind.valueOf(row.getString("kind")),
                    row.getLong("revision"),
                    readRules(row.getString("rules_json")),
                    row.getString("source_version_id")),
            args),
        limit,
        PolicyDraft::id);
  }

  private PolicyDraft readDraft(String tenant, String id, boolean lock) {
    var rows =
        jdbc.query(
            "SELECT * FROM policy_drafts WHERE tenant_id=? AND id=?" + (lock ? " FOR UPDATE" : ""),
            (row, index) ->
                new PolicyDraft(
                    row.getString("id"),
                    row.getString("name"),
                    PolicyDraft.Kind.valueOf(row.getString("kind")),
                    row.getLong("revision"),
                    readRules(row.getString("rules_json")),
                    row.getString("source_version_id")),
            tenant,
            id);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  @Transactional(timeout = 10)
  public PolicyDraft update(
      String tenant, String actor, String id, PolicyController.EditDraft input, String ifMatch) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    long expected = ResourceVersions.require(ifMatch);
    var existing = readDraft(tenant, id, true);
    ResourceVersions.check(expected, existing.revision());
    resolve(tenant, actor, input.rules());
    jdbc.update(
        "UPDATE policy_drafts SET name=?,rules_json=?,revision=revision+1,updated_at=? WHERE"
            + " tenant_id=? AND id=? AND revision=?",
        input.name().strip(),
        json(input.rules()),
        clock.millis(),
        tenant,
        id,
        expected);
    audit.record(tenant, actor, "POLICY_DRAFT_UPDATED", id);
    return new PolicyDraft(
        id,
        input.name().strip(),
        existing.kind(),
        expected + 1,
        List.copyOf(input.rules()),
        existing.sourceVersionId());
  }

  /**
   * Copy a template without sharing mutable rules; subsequent template edits do not change the
   * copy.
   */
  @Transactional(timeout = 10)
  public PolicyDraft copyTemplate(
      String tenant, String actor, String id, String name, String ifMatch, String key) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    long expected = ResourceVersions.require(ifMatch);
    return idempotency.execute(
        tenant,
        actor,
        "policy.template.copy",
        key,
        Map.of("id", id, "name", name, "revision", expected),
        PolicyDraft.class,
        () -> {
          var template = readDraft(tenant, id, true);
          ResourceVersions.check(expected, template.revision());
          if (template.kind() != PolicyDraft.Kind.TEMPLATE)
            throw DomainException.invalid("NOT_POLICY_TEMPLATE");
          resolve(tenant, actor, template.rules());
          return insertDraft(tenant, actor, name, PolicyDraft.Kind.POLICY, template.rules(), null);
        });
  }

  @Transactional(timeout = 10)
  public PolicyPreview preview(
      String tenant, String actor, String id, String ifMatch, List<String> deviceIds) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    if (deviceIds.stream().distinct().count() != deviceIds.size())
      throw DomainException.invalid("DUPLICATE_DEVICE_TARGET");
    var draft = readDraft(tenant, id, true);
    ResourceVersions.check(ResourceVersions.require(ifMatch), draft.revision());
    if (draft.kind() == PolicyDraft.Kind.TEMPLATE)
      throw DomainException.invalid("TEMPLATE_REQUIRES_COPY");
    var snapshot = snapshot(tenant, actor, draft, deviceIds);
    if (snapshot.targets().stream().anyMatch(t -> t.state() != Device.State.ACTIVE))
      throw new DomainException(HttpStatus.CONFLICT, "DEVICE_NOT_ACTIVE");
    String previewId = UUID.randomUUID().toString(), hash = fingerprint(tenant, draft, snapshot);
    long expires = clock.millis() + previewTtlMillis;
    jdbc.update(
        "INSERT INTO"
            + " policy_previews(tenant_id,id,policy_id,draft_revision,hash,snapshot_json,created_at,expires_at,creator_actor_key)"
            + " VALUES(?,?,?,?,?,?,?,?,?)",
        tenant,
        previewId,
        id,
        draft.revision(),
        hash,
        json(snapshot),
        clock.millis(),
        expires,
        ActorKeys.key(actor));
    audit.record(tenant, actor, "POLICY_PREVIEW_CREATED", previewId);
    return new PolicyPreview(
        previewId,
        id,
        draft.revision(),
        "PREVIEW",
        hash,
        expires,
        enforceable(snapshot),
        snapshot.targets(),
        snapshot);
  }

  /**
   * A signed/transport-ready ENFORCE path is intentionally unavailable until delivery adapters
   * exist.
   */
  @Transactional(timeout = 10)
  public PolicyPublication publish(
      String tenant,
      Jwt actor,
      String id,
      PolicyController.Publish input,
      String ifMatch,
      String key) {
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
    recent.require(actor);
    long expected = ResourceVersions.require(ifMatch);
    if (key == null) throw DomainException.invalid("IDEMPOTENCY_KEY_REQUIRED");
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "policy.publish",
        key,
        Map.of("policyId", id, "revision", expected, "input", input),
        PolicyPublication.class,
        () -> {
          var draft = readDraft(tenant, id, true);
          ResourceVersions.check(expected, draft.revision());
          var rows =
              jdbc.query(
                  "SELECT policy_id,draft_revision,hash,snapshot_json,expires_at FROM"
                      + " policy_previews WHERE tenant_id=? AND id=? FOR UPDATE",
                  (row, index) ->
                      new StoredPreview(
                          row.getString(1),
                          row.getLong(2),
                          row.getString(3),
                          read(row.getString(4), PolicySnapshot.class),
                          row.getLong(5)),
                  tenant,
                  input.previewId());
          if (rows.isEmpty()) throw DomainException.denied();
          var reviewed = rows.get(0);
          if (!id.equals(reviewed.policyId())
              || expected != reviewed.revision()
              || reviewed.expiresAt() <= clock.millis()
              || !reviewed.hash().equals(input.previewHash()))
            throw new DomainException(HttpStatus.CONFLICT, "PREVIEW_STALE");
          var current =
              snapshot(
                  tenant,
                  actor.getSubject(),
                  draft,
                  reviewed.snapshot().targets().stream()
                      .map(PolicySnapshot.Target::deviceId)
                      .toList());
          if (!reviewed.hash().equals(fingerprint(tenant, draft, current)))
            throw new DomainException(HttpStatus.CONFLICT, "PREVIEW_STALE");
          if (input.mode() == PolicyPublication.Mode.ENFORCE) {
            if (!enforceable(current))
              throw new DomainException(
                  HttpStatus.UNPROCESSABLE_ENTITY, "REQUIRED_RULE_UNSUPPORTED");
            throw new DomainException(
                HttpStatus.SERVICE_UNAVAILABLE, "DELIVERY_ADAPTER_NOT_CONFIGURED");
          }
          return recordConfiguration(tenant, actor.getSubject(), draft, input, reviewed.snapshot());
        });
  }

  private PolicyPublication recordConfiguration(
      String tenant,
      String actor,
      PolicyDraft draft,
      PolicyController.Publish input,
      PolicySnapshot snapshot) {
    // The locked draft serializes sequence allocation, even when multiple replicas publish
    // concurrently.
    long sequence =
        jdbc.queryForObject(
                "SELECT next_sequence FROM policy_drafts WHERE tenant_id=? AND id=? FOR UPDATE",
                Long.class,
                tenant,
                draft.id())
            + 1;
    jdbc.update(
        "UPDATE policy_drafts SET next_sequence=? WHERE tenant_id=? AND id=?",
        sequence,
        tenant,
        draft.id());
    String version = UUID.randomUUID().toString(), operation = UUID.randomUUID().toString();
    long now = clock.millis();
    jdbc.update(
        "INSERT INTO"
            + " policy_versions(tenant_id,id,policy_id,draft_revision,sequence_number,preview_id,preview_hash,mode,snapshot_json,source_version_id,created_at)"
            + " VALUES(?,?,?,?,?,?,?,?,?,?,?)",
        tenant,
        version,
        draft.id(),
        draft.revision(),
        sequence,
        input.previewId(),
        input.previewHash(),
        input.mode().name(),
        json(snapshot),
        draft.sourceVersionId(),
        now);
    var result =
        new PolicyPublication(
            operation, version, sequence, input.mode(), "CONFIGURED_NOT_ENFORCED", now);
    jdbc.update(
        "INSERT INTO policy_publications(tenant_id,id,version_id,state,created_at)"
            + " VALUES(?,?,?,?,?)",
        tenant,
        operation,
        version,
        result.state(),
        now);
    jdbc.update(
        "INSERT INTO policy_outbox(tenant_id,id,publication_id,event_type,payload_json,created_at)"
            + " VALUES(?,?,?,?,?,?)",
        tenant,
        UUID.randomUUID().toString(),
        operation,
        "policy.configuration.recorded.v1",
        json(Map.of("publicationId", operation, "versionId", version)),
        now);
    audit.record(tenant, actor, "POLICY_CONFIGURATION_RECORDED", version);
    var previous =
        sequence == 1
            ? List.<PolicySnapshot.Target>of()
            : jdbc.query(
                    "SELECT snapshot_json FROM policy_versions WHERE tenant_id=? AND policy_id=?"
                        + " AND sequence_number=? FOR UPDATE",
                    (row, index) -> read(row.getString(1), PolicySnapshot.class).targets(),
                    tenant,
                    draft.id(),
                    sequence - 1)
                .get(0);
    events.publishEvent(
        new PolicyConfigurationRecorded(
            tenant,
            operation,
            new PolicyVersion(
                version,
                draft.id(),
                draft.revision(),
                sequence,
                input.previewHash(),
                input.mode(),
                snapshot,
                draft.sourceVersionId(),
                now),
            previous,
            MDC.get("correlationId")));
    return result;
  }

  PolicyVersion version(String tenant, String actor, String policyId, String versionId) {
    access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
    return readVersion(tenant, policyId, versionId);
  }

  ItemPage<PolicyVersion> versions(
      String tenant, String actor, String policyId, int limit, String cursor) {
    get(tenant, actor, policyId);
    ItemPage.validate(limit, cursor);
    long before =
        cursor == null ? Long.MAX_VALUE : readVersion(tenant, policyId, cursor).sequence();
    return ItemPage.from(
        jdbc.query(
            "SELECT * FROM policy_versions WHERE tenant_id=? AND policy_id=? AND sequence_number<?"
                + " ORDER BY sequence_number DESC LIMIT ?",
            (row, index) ->
                new PolicyVersion(
                    row.getString("id"),
                    row.getString("policy_id"),
                    row.getLong("draft_revision"),
                    row.getLong("sequence_number"),
                    row.getString("preview_hash"),
                    PolicyPublication.Mode.valueOf(row.getString("mode")),
                    read(row.getString("snapshot_json"), PolicySnapshot.class),
                    row.getString("source_version_id"),
                    row.getLong("created_at")),
            tenant,
            policyId,
            before,
            limit + 1),
        limit,
        PolicyVersion::id);
  }

  private PolicyVersion readVersion(String tenant, String policyId, String versionId) {
    var rows =
        jdbc.query(
            "SELECT * FROM policy_versions WHERE tenant_id=? AND policy_id=? AND id=?",
            (row, index) ->
                new PolicyVersion(
                    row.getString("id"),
                    policyId,
                    row.getLong("draft_revision"),
                    row.getLong("sequence_number"),
                    row.getString("preview_hash"),
                    PolicyPublication.Mode.valueOf(row.getString("mode")),
                    read(row.getString("snapshot_json"), PolicySnapshot.class),
                    row.getString("source_version_id"),
                    row.getLong("created_at")),
            tenant,
            policyId,
            versionId);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  @Override
  public PolicyPublication publication(String tenant, String actor, String id) {
    access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
    var rows =
        jdbc.query(
            "SELECT p.*,v.sequence_number,v.mode FROM policy_publications p JOIN policy_versions v"
                + " ON v.tenant_id=p.tenant_id AND v.id=p.version_id WHERE p.tenant_id=? AND"
                + " p.id=?",
            (row, index) ->
                new PolicyPublication(
                    id,
                    row.getString("version_id"),
                    row.getLong("sequence_number"),
                    PolicyPublication.Mode.valueOf(row.getString("mode")),
                    row.getString("state"),
                    row.getLong("created_at")),
            tenant,
            id);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  /** Membership -> policy -> subject -> device; no child receives unrelated rules or targets. */
  @Override
  @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
  public PolicyExceptionAccess.Baseline accessWindow(
      String tenant,
      String actor,
      String deviceId,
      String policyId,
      String versionId,
      String applicationId,
      List<String> ruleIds) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, CHILD, TEACHER);
    readDraft(tenant, policyId, true);
    var visible = requestDevices.observeRequestTarget(tenant, actor, deviceId);
    if (!subjects.lockForDevice(tenant, visible.subjectId())) throw DomainException.denied();
    var device = requestDevices.lockRequestTarget(tenant, actor, deviceId);
    if (!device.subjectId().equals(visible.subjectId())
        || !device.registrationId().equals(visible.registrationId()))
      throw new DomainException(HttpStatus.CONFLICT, "ACCESS_TARGET_CHANGED");
    return validateAccessWindow(tenant, device, policyId, versionId, applicationId, ruleIds);
  }

  @Override
  @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
  public Device lockRequestTarget(
      com.aimanager.deviceidentity.DeviceContext identity, String policyId) {
    readDraft(identity.tenantId(), policyId, true);
    var observed = devices.observeActive(identity);
    if (!subjects.lockForDevice(identity.tenantId(), observed.subjectId()))
      throw DomainException.denied();
    var current = devices.lockActive(identity);
    if (!current.subjectId().equals(observed.subjectId()))
      throw new DomainException(HttpStatus.CONFLICT, "ACCESS_TARGET_CHANGED");
    return current;
  }

  @Override
  @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
  public PolicyExceptionAccess.Baseline accessWindow(
      com.aimanager.deviceidentity.DeviceContext identity,
      String policyId,
      String versionId,
      String applicationId,
      List<String> ruleIds) {
    var device = lockRequestTarget(identity, policyId);
    return validateAccessWindow(
        identity.tenantId(), device, policyId, versionId, applicationId, ruleIds);
  }

  private PolicyExceptionAccess.Baseline validateAccessWindow(
      String tenant,
      Device device,
      String policyId,
      String versionId,
      String applicationId,
      List<String> ruleIds) {
    String deviceId = device.id();
    var current =
        jdbc.query(
            "SELECT * FROM policy_versions WHERE tenant_id=? AND policy_id=? ORDER BY"
                + " sequence_number DESC LIMIT 1 FOR UPDATE",
            (row, index) ->
                new ExceptionVersion(
                    row.getString("id"),
                    row.getLong("sequence_number"),
                    read(row.getString("snapshot_json"), PolicySnapshot.class)),
            tenant,
            policyId);
    if (current.isEmpty()) throw DomainException.denied();
    var base = current.get(0);
    if (!base.id().equals(versionId))
      throw new DomainException(HttpStatus.CONFLICT, "BASELINE_CHANGED");
    boolean target =
        base.snapshot().targets().stream()
            .anyMatch(
                t ->
                    deviceId.equals(t.deviceId())
                        && device.registrationId().equals(t.registrationId()));
    if (!target) throw DomainException.denied();
    var application =
        base.snapshot().applications().stream()
            .filter(a -> applicationId.equals(a.id()))
            .findFirst()
            .orElseThrow(DomainException::denied);
    if (application.platform() != device.platform()) throw DomainException.denied();
    if (base.snapshot()
        .protectedPackageExemptions()
        .contains(application.packageName().toLowerCase(Locale.ROOT)))
      throw new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, "SAFETY_BASELINE_PROTECTED");
    if (ruleIds.isEmpty() || ruleIds.stream().distinct().count() != ruleIds.size())
      throw DomainException.invalid("EXCEPTION_RULE_INVALID");
    for (String id : ruleIds) {
      var rule =
          base.snapshot().sourceRules().stream()
              .filter(r -> id.equals(r.id()))
              .findFirst()
              .orElseThrow(() -> DomainException.invalid("EXCEPTION_RULE_INVALID"));
      if (rule.applicationId() != null && !applicationId.equals(rule.applicationId()))
        throw DomainException.invalid("EXCEPTION_RULE_INVALID");
      boolean window = rule.kind() == PolicyRule.Kind.TIME_WINDOW;
      boolean launch =
          rule.kind() == PolicyRule.Kind.APP_LAUNCH && rule.effect() == PolicyRule.Effect.DENY;
      if (!window && !launch)
        throw new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, "EXCEPTION_KIND_UNSUPPORTED");
    }
    return new PolicyExceptionAccess.Baseline(
        device.subjectId(),
        device.id(),
        device.registrationId(),
        policyId,
        base.id(),
        base.sequence(),
        applicationId,
        ruleIds.stream().sorted().toList());
  }

  private record ExceptionVersion(String id, long sequence, PolicySnapshot snapshot) {}

  /** Bounded scan of current versions. Only this device's eligible rule identities leave policy. */
  @Override
  @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
  public ItemPage<PolicyExceptionAccess.WindowOptions> requestOptions(
      String tenant, String actor, String deviceId, int limit, String cursor) {
    access.requireWriteRole(tenant, actor, CHILD, TEACHER);
    ItemPage.validate(limit, cursor);
    var device = requestDevices.observeRequestTarget(tenant, actor, deviceId);
    if (!subjects.active(tenant, device.subjectId())) throw DomainException.denied();
    return optionsForDevice(tenant, device, limit, cursor);
  }

  @Override
  @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
  public ItemPage<PolicyExceptionAccess.WindowOptions> requestOptions(
      com.aimanager.deviceidentity.DeviceContext identity, int limit, String cursor) {
    ItemPage.validate(limit, cursor);
    var device = devices.observeActive(identity);
    if (!subjects.active(identity.tenantId(), device.subjectId())) throw DomainException.denied();
    return optionsForDevice(identity.tenantId(), device, limit, cursor);
  }

  private ItemPage<PolicyExceptionAccess.WindowOptions> optionsForDevice(
      String tenant, Device device, int limit, String cursor) {
    var versions =
        jdbc.query(
            "SELECT v.* FROM policy_versions v WHERE v.tenant_id=? AND v.policy_id>? AND NOT EXISTS"
                + " (SELECT 1 FROM policy_versions newer WHERE newer.tenant_id=v.tenant_id AND"
                + " newer.policy_id=v.policy_id AND newer.sequence_number>v.sequence_number) ORDER"
                + " BY v.policy_id LIMIT ?",
            (row, index) ->
                new OptionVersion(
                    row.getString("policy_id"),
                    row.getString("id"),
                    read(row.getString("snapshot_json"), PolicySnapshot.class)),
            tenant,
            cursor == null ? "" : cursor,
            limit + 1);
    var page = ItemPage.from(versions, limit, OptionVersion::policy);
    var result = new ArrayList<PolicyExceptionAccess.WindowOptions>();
    for (var version : page.items()) {
      var snapshot = version.snapshot();
      if (snapshot.targets().stream()
          .noneMatch(
              t ->
                  device.id().equals(t.deviceId())
                      && device.registrationId().equals(t.registrationId()))) continue;
      var eligible =
          snapshot.sourceRules().stream()
              .filter(
                  r ->
                      r.kind() == PolicyRule.Kind.TIME_WINDOW
                          || r.kind() == PolicyRule.Kind.APP_LAUNCH
                              && r.effect() == PolicyRule.Effect.DENY)
              .toList();
      var common =
          eligible.stream()
              .filter(r -> r.applicationId() == null)
              .map(r -> new PolicyExceptionAccess.RuleOption(r.id(), r.kind()))
              .toList();
      var apps = new ArrayList<PolicyExceptionAccess.ApplicationOption>();
      for (var app : snapshot.applications()) {
        if (app.platform() != device.platform()
            || snapshot
                .protectedPackageExemptions()
                .contains(app.packageName().toLowerCase(Locale.ROOT))) continue;
        var rules =
            eligible.stream()
                .filter(r -> app.id().equals(r.applicationId()))
                .map(r -> new PolicyExceptionAccess.RuleOption(r.id(), r.kind()))
                .toList();
        if (!rules.isEmpty() || !common.isEmpty())
          apps.add(new PolicyExceptionAccess.ApplicationOption(app.id(), app.displayName(), rules));
      }
      if (!apps.isEmpty())
        result.add(
            new PolicyExceptionAccess.WindowOptions(
                version.policy(), snapshot.name(), version.id(), common, List.copyOf(apps)));
    }
    // An empty filtered page can still have a cursor. Consumers must preserve it.
    return new ItemPage<>(List.copyOf(result), page.nextCursor());
  }

  private record OptionVersion(String policy, String id, PolicySnapshot snapshot) {}

  /**
   * Rollback creates a draft revision in the original policy stream; immutable versions stay
   * untouched.
   */
  @Transactional(timeout = 10)
  public PolicyDraft rollbackDraft(
      String tenant,
      Jwt actor,
      String policyId,
      String versionId,
      String name,
      String ifMatch,
      String key) {
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
    recent.require(actor);
    long expected = ResourceVersions.require(ifMatch);
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "policy.rollback-draft",
        key,
        Map.of("policyId", policyId, "versionId", versionId, "name", name, "revision", expected),
        PolicyDraft.class,
        () -> {
          var current = readDraft(tenant, policyId, true);
          ResourceVersions.check(expected, current.revision());
          var source = readVersion(tenant, policyId, versionId);
          resolve(tenant, actor.getSubject(), source.snapshot().sourceRules());
          jdbc.update(
              "UPDATE policy_drafts SET"
                  + " name=?,rules_json=?,source_version_id=?,revision=revision+1,updated_at=?"
                  + " WHERE tenant_id=? AND id=? AND revision=?",
              name.strip(),
              json(source.snapshot().sourceRules()),
              source.id(),
              clock.millis(),
              tenant,
              policyId,
              expected);
          audit.record(tenant, actor.getSubject(), "POLICY_ROLLBACK_DRAFT_CREATED", policyId);
          return new PolicyDraft(
              policyId,
              name.strip(),
              current.kind(),
              expected + 1,
              source.snapshot().sourceRules(),
              source.id());
        });
  }

  private Resolved resolve(String tenant, String actor, List<PolicyRule> rules) {
    var apps = new TreeMap<String, ApplicationDefinition>();
    var plans = new TreeMap<String, ScheduleEntry>();
    for (var rule : rules) {
      if (rule.applicationId() != null)
        apps.computeIfAbsent(
            rule.applicationId(), id -> catalog.requireDeclared(tenant, actor, id));
      if (rule.scheduleId() != null)
        plans.computeIfAbsent(
            rule.scheduleId(), id -> schedules.requireDefinition(tenant, actor, id));
    }
    compiler.validate(rules, apps);
    return new Resolved(apps, plans);
  }

  private PolicySnapshot snapshot(
      String tenant, String actor, PolicyDraft draft, List<String> deviceIds) {
    var inputs = resolve(tenant, actor, draft.rules());
    var targets = new ArrayList<PolicySnapshot.Target>();
    for (var id : deviceIds.stream().sorted().toList()) {
      var target = fleet.snapshot(tenant, actor, id, true);
      var device = target.device();
      targets.add(
          new PolicySnapshot.Target(
              id,
              device.registrationId(),
              device.platform(),
              device.state(),
              device.managementMode(),
              device.osVersion(),
              device.version(),
              device.observationStatus(),
              target.capabilities(),
              compiler.compile(draft.rules(), inputs.apps(), target)));
    }
    return new PolicySnapshot(
        1,
        draft.name(),
        draft.rules(),
        List.copyOf(inputs.apps().values()),
        List.copyOf(inputs.plans().values()),
        compiler.protectedPackageExemptions(),
        List.copyOf(targets));
  }

  private boolean enforceable(PolicySnapshot snapshot) {
    boolean hasExecutable =
        snapshot.targets().stream()
            .flatMap(t -> t.rules().stream())
            .anyMatch(r -> "SUPPORTED_PENDING".equals(r.status()));
    return hasExecutable
        && snapshot.targets().stream()
            .allMatch(
                t ->
                    t.state() == Device.State.ACTIVE
                        && t.rules().stream()
                            .filter(PolicySnapshot.RuleEvaluation::required)
                            .allMatch(r -> "SUPPORTED_PENDING".equals(r.status())));
  }

  private String fingerprint(String tenant, PolicyDraft draft, PolicySnapshot snapshot) {
    return SecretMaterial.hash(
        json(
            Map.of(
                "tenantId",
                tenant,
                "policyId",
                draft.id(),
                "revision",
                draft.revision(),
                "snapshot",
                snapshot)));
  }

  private String json(Object value) {
    try {
      return mapper
          .writer()
          .with(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS)
          .writeValueAsString(value);
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Policy serialization failed", failure);
    }
  }

  private <T> T read(String value, Class<T> type) {
    try {
      return mapper.readValue(value, type);
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Policy snapshot unreadable", failure);
    }
  }

  private List<PolicyRule> readRules(String value) {
    try {
      return mapper.readValue(value, new TypeReference<List<PolicyRule>>() {});
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Policy rules unreadable", failure);
    }
  }

  private record Resolved(
      Map<String, ApplicationDefinition> apps, Map<String, ScheduleEntry> plans) {}

  private record StoredPreview(
      String policyId, long revision, String hash, PolicySnapshot snapshot, long expiresAt) {}
}
